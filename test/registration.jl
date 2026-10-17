using LLVM, LLVM.IR, LLVM.Passes
using JuliaIR: Dialect, PassOptions, parse_options, options_string

@testset "registration" begin

@testset "option parsing" begin
    opts = parse_options("julia=1.12;fp16=demote")
    @test opts.dialect == Dialect(v"1.12"; fp16=:demote)
    @test opts.extra == (;)

    # defaults
    @test parse_options("").dialect == Dialect(VERSION)
    @test parse_options(""; julia=v"1.11").dialect == Dialect(v"1.11")
    @test parse_options("julia=1.13"; julia=v"1.11").dialect == Dialect(v"1.13")
    @test parse_options("gc-barrier=field-precise").dialect.gc_barrier === :field_precise

    # pass-specific options
    extra = (; strong=false, mode=:fast)
    @test parse_options(""; extra).extra == (; strong=false, mode=:fast)
    @test parse_options("strong"; extra).extra == (; strong=true, mode=:fast)
    @test parse_options("no-strong;mode=slow-ish"; extra).extra == (; strong=false, mode=:slow_ish)
    @test_throws "is a flag" parse_options("strong=1"; extra)
    @test_throws "requires a value" parse_options("mode"; extra)
    @test_throws "requires a value" parse_options("no-mode"; extra)

    # round trip
    for str in ["julia=1.12.0", "julia=1.14.0-DEV.3782;fp16=demote",
                "julia=1.10.12;gc-barrier=snapshot-field-precise"]
        @test options_string(parse_options(str)) == str
        @test parse_options(options_string(parse_options(str))) == parse_options(str)
    end
    let opts = parse_options("julia=1.12.0;fp16=keep;strong;mode=slow"; extra)
        @test options_string(opts) == "julia=1.12.0;fp16=keep;strong;mode=slow"
        @test parse_options(options_string(opts); extra) == opts
    end

    # rejections
    @test_throws "unknown option frobnicate" parse_options("frobnicate")
    @test_throws "unknown option strong" parse_options("strong")
    @test_throws "more than once" parse_options("julia=1.11;julia=1.12")
    @test_throws "requires a version" parse_options("julia")
    @test_throws "not supported" parse_options("julia=1.9")
    @test_throws "newer than" parse_options("julia=1.15")
    @test_throws "invalid Julia version" parse_options("julia=latest")
    @test_throws "invalid fp16 policy" parse_options("fp16=maybe")
end

# a pass that records what it was called with, without being registered globally
calls = Any[]
function record_pass(ir, am, opts)
    push!(calls, (ir.name, opts))
    return PreservedAnalyses(AllAnalyses)
end
test_pass = JuliaIR.PassDefinition("jl-test", :module, false, record_pass, (; strong=false))

test_ir = """
    define void @f() {
      ret void
    }"""

@testset "custom passes" begin
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, test_ir) begin
        mod.name = "test"

        empty!(calls)
        run!(JuliaIR.custom_pass(test_pass; julia=v"1.11"), mod)
        @test calls == [("test", PassOptions(Dialect(v"1.11"), (; strong=false)))]

        # options in the pipeline override the defaults of the pass
        empty!(calls)
        @dispose pb=PassBuilder() begin
            LLVM.register!(pb, JuliaIR.custom_pass(test_pass; julia=v"1.11", strong=true))
            add!(pb, "jl-test<julia=1.13;fp16=keep>,jl-test<no-strong>")
            run!(pb, mod)
        end
        @test calls == [("test", PassOptions(Dialect(v"1.13"; fp16=:keep), (; strong=true))),
                        ("test", PassOptions(Dialect(v"1.11"), (; strong=false)))]

        # invalid option text in a pipeline
        @dispose pb=PassBuilder() begin
            LLVM.register!(pb, JuliaIR.custom_pass(test_pass))
            add!(pb, "jl-test<julia=1.9>")
            @test_throws PassException run!(pb, mod)
        end

        # invalid defaults are reported when the pass is created
        @test_throws "not supported" JuliaIR.custom_pass(test_pass; julia=v"1.9")
        @test_throws "unknown option" JuliaIR.custom_pass(test_pass; frobnicate=true)
    end
end

@testset "typed pointers are rejected" begin
    if LLVM.version() < v"17"
        @dispose ctx=Context(; opaque_pointers=false) mod=parse(LLVM.Module, test_ir) begin
            empty!(calls)
            err = try
                run!(JuliaIR.custom_pass(test_pass), mod)
                nothing
            catch err
                err
            end
            @test err isa PassException
            @test err.ex isa ArgumentError
            @test occursin("opaque pointers", sprint(showerror, err.ex))
            # the pass did not run
            @test isempty(calls)
        end
    end
    @dispose ctx=Context() begin
        if LLVM.supports_typed_pointers(ctx)
            @test_throws ArgumentError JuliaIR.require_opaque(ctx)
        else
            @test JuliaIR.require_opaque(ctx) === nothing
        end
    end
end

@testset "library facts" begin
    @dispose ctx=Context() begin
        facts = JuliaIR.library_facts(ctx)
        @test facts.llvm == LLVM.version()
        @test facts.lifetime_size == (LLVM.version() < v"22")
    end
end

@testset "ledger" begin
    old = JuliaIR.LEDGER[]
    try
        mktemp() do path, io
            close(io)
            @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, test_ir) begin
                # off
                JuliaIR.LEDGER[] = ""
                run!(JuliaIR.custom_pass(test_pass; julia=v"1.12"), mod)
                @test isempty(read(path, String))

                # on
                JuliaIR.LEDGER[] = path
                run!(JuliaIR.custom_pass(test_pass; julia=v"1.12"), mod)
                run!(JuliaIR.custom_pass(test_pass; julia=v"1.13"), mod)
                lines = readlines(path)
                @test lines == ["$(getpid())\tpass\tjl-test\tjulia=1.12.0\tllvm=$(LLVM.version())",
                                "$(getpid())\tpass\tjl-test\tjulia=1.13.0\tllvm=$(LLVM.version())"]
            end
        end
    finally
        JuliaIR.LEDGER[] = old
    end

    # the environment variable is read when the package is loaded
    mktemp() do path, io
        close(io)
        script = """
            using JuliaIR
            print(JuliaIR.LEDGER[])
            """
        cmd = addenv(`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $script`,
                     "JULIAIR_LEDGER" => path)
        @test read(cmd, String) == path
    end
end

@testset "pass registry" begin
    @test JuliaIR.passes() isa Vector{String}
    @test all(startswith("jl-"), JuliaIR.passes())
    @dispose pb=PassBuilder() begin
        @test JuliaIR.register!(pb; julia=v"1.12") === pb
        @test length(pb.custom_passes) == length(JuliaIR.passes())
    end
end

end
