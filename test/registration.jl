using LLVM, LLVM.IR, LLVM.Passes
using JuliaIR: Dialect, PassOptions, parse_options, options_string

@testset "registration" begin

@testset "option parsing" begin
    # the dialect is the running Julia's, with the policies of the options
    opts = parse_options("fp16=demote")
    @test opts.dialect == Dialect(VERSION; fp16=:demote)
    @test opts.dialect.julia == VERSION
    @test opts.extra == (;)

    # defaults
    @test parse_options("").dialect == Dialect(VERSION)
    @test parse_options(""; fp16=:keep).dialect == Dialect(VERSION; fp16=:keep)
    @test parse_options("fp16=demote"; fp16=:keep).dialect.fp16 === :demote
    @test parse_options("gc-barrier=field-precise").dialect.gc_barrier === :field_precise

    # pass-specific options
    extra = (; strong=false, mode=:fast)
    @test parse_options(""; extra).extra == (; strong=false, mode=:fast)
    @test parse_options("strong"; extra).extra == (; strong=true, mode=:fast)
    @test parse_options("no-strong;mode=slow-ish"; extra).extra == (; strong=false, mode=:slow_ish)
    @test_throws "is a flag" parse_options("strong=1"; extra)
    @test_throws "requires a value" parse_options("mode"; extra)
    @test_throws "requires a value" parse_options("no-mode"; extra)
    let extra = (; size=0, name="")
        @test parse_options("size=264;name=__sigsetjmp"; extra).extra ==
              (; size=264, name="__sigsetjmp")
        @test options_string(parse_options("size=8;name=a_b-c"; extra)) == "size=8;name=a_b-c"
        @test_throws "non-negative integer" parse_options("size=x"; extra)
        @test_throws "non-negative integer" parse_options("size=-1"; extra)
        @test_throws "requires a value" parse_options("name"; extra)
    end
    # options that may be unspecified: signed integers and addresses
    let extra = (; offset=JuliaIR.Optional{Int}(), addr=JuliaIR.Optional{UInt}())
        opts = parse_options(""; extra)
        @test opts.extra == extra
        @test JuliaIR.option_value(opts.extra.offset) === nothing
        @test options_string(opts) == ""
        opts = parse_options("offset=-8;addr=0x4011c0"; extra)
        @test JuliaIR.option_value(opts.extra.offset) === -8
        @test JuliaIR.option_value(opts.extra.addr) === UInt(0x4011c0)
        @test options_string(opts) == "offset=-8;addr=0x4011c0"
        @test parse_options(options_string(opts); extra) == opts
        @test JuliaIR.option_value(parse_options("addr=4198848"; extra).extra.addr) == 0x4011c0
        @test_throws "requires an integer" parse_options("offset=x"; extra)
        @test_throws "requires an address" parse_options("addr=-1"; extra)
        @test_throws "requires a value" parse_options("offset"; extra)
        # only for the integers they can be parsed and printed as
        @test_throws TypeError JuliaIR.Optional{BigInt}()
    end

    # options that can't be given in text, only as keyword arguments
    let extra = (; target=nothing, strong=false)
        @test_throws "can't be given in a pipeline" parse_options("target=x86";
                                                                    extra, keyword_only=(:target,))
        opts = parse_options("strong"; extra=(; target="x86", strong=false),
                             keyword_only=(:target,))
        @test opts.extra == (; target="x86", strong=true)
        # they have no text form
        @test options_string(opts; keyword_only=(:target,)) == "strong"
    end

    # vector-valued options can't be written in a pipeline
    let extra = (; names=String[], strong=false)
        @test parse_options("strong"; extra).extra == (; names=String[], strong=true)
        @test parse_options(""; extra=(; names=["a"])).extra == (; names=["a"])
        @test_throws "can't be given in a pipeline" parse_options("names=a"; extra)
        @test_throws "can't be given in a pipeline" parse_options("names"; extra)
        @test options_string(parse_options(""; extra)) == "no-strong"
    end

    # round trip
    for str in ["", "fp16=demote", "fp16=keep;bf16=demote",
                "gc-barrier=snapshot-field-precise"]
        @test options_string(parse_options(str)) == str
        @test parse_options(options_string(parse_options(str))) == parse_options(str)
    end
    @test options_string(parse_options(""; extra)) == "no-strong;mode=fast"
    let opts = parse_options("fp16=keep;strong;mode=slow"; extra)
        @test options_string(opts) == "fp16=keep;strong;mode=slow"
        @test parse_options(options_string(opts); extra) == opts
    end

    # rejections
    @test_throws "unknown option frobnicate" parse_options("frobnicate")
    @test_throws "unknown option strong" parse_options("strong")
    # the dialect isn't an option: it is the running Julia's
    @test_throws "unknown option julia; expected one of fp16, bf16, gc-barrier" parse_options("julia=1.12")
    @test_throws "unknown option julia" parse_options("julia")
    @test_throws "more than once" parse_options("fp16=keep;fp16=demote")
    @test_throws "more than once" parse_options("strong;no-strong"; extra)
    @test_throws "more than once" parse_options("foo-bar;no-foo_bar"; extra=(; foo_bar=false))
    @test_throws "invalid fp16 policy" parse_options("fp16=maybe")
    @test_throws "invalid bf16 policy" parse_options("bf16=maybe")
    @test_throws "requires a value" parse_options("bf16")
    @test parse_options(""; bf16=:keep).dialect == Dialect(VERSION; bf16=:keep)
    @test_throws "invalid fp16 policy" parse_options(""; fp16=:maybe)
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
        run!(JuliaIR.custom_pass(test_pass), mod)
        @test calls == [("test", PassOptions(Dialect(VERSION), (; strong=false)))]

        # options in the pipeline override the defaults of the pass
        empty!(calls)
        @dispose pb=PassBuilder() begin
            LLVM.register!(pb, JuliaIR.custom_pass(test_pass; bf16=:demote, strong=true))
            add!(pb, "jl-test<fp16=keep>,jl-test<no-strong;bf16=keep>")
            run!(pb, mod)
        end
        @test calls == [("test", PassOptions(Dialect(VERSION; fp16=:keep, bf16=:demote), (; strong=true))),
                        ("test", PassOptions(Dialect(VERSION; bf16=:keep), (; strong=false)))]

        # invalid option text in a pipeline
        @dispose pb=PassBuilder() begin
            LLVM.register!(pb, JuliaIR.custom_pass(test_pass))
            add!(pb, "jl-test<julia=1.12>")
            @test_throws PassException run!(pb, mod)
        end

        # invalid defaults are reported when the pass is created
        @test_throws "invalid fp16 policy" JuliaIR.custom_pass(test_pass; fp16=:maybe)
        @test_throws "unknown option julia" JuliaIR.custom_pass(test_pass; julia=v"1.12")
        @test_throws "unknown option" JuliaIR.custom_pass(test_pass; frobnicate=true)
        @test_throws "must be a Bool" JuliaIR.custom_pass(test_pass; strong=:no)

        # keyword arguments of optional options take a value or `nothing`
        optional_pass = JuliaIR.PassDefinition("jl-test-optional", :module, false, record_pass,
                                               (; offset=JuliaIR.Optional{Int}(),
                                                  addr=JuliaIR.Optional{UInt}()))
        empty!(calls)
        run!(JuliaIR.custom_pass(optional_pass; offset=-8, addr=Ptr{Cvoid}(UInt(0x10))), mod)
        run!(JuliaIR.custom_pass(optional_pass; offset=nothing, addr=16), mod)
        @test [c[2].extra for c in calls] ==
              [(; offset=JuliaIR.Optional{Int}(-8), addr=JuliaIR.Optional{UInt}(0x10)),
               (; offset=JuliaIR.Optional{Int}(), addr=JuliaIR.Optional{UInt}(0x10))]
        @test_throws "must be an address or `nothing`" JuliaIR.custom_pass(optional_pass; addr=-1)
        @test_throws "must be an integer or `nothing`" JuliaIR.custom_pass(optional_pass; offset="x")

        # options whose default is `nothing` are keyword-only, of any type
        kw_pass = JuliaIR.PassDefinition("jl-test", :module, false, record_pass,
                                         (; target=nothing))
        empty!(calls)
        run!(JuliaIR.custom_pass(kw_pass; target=:x86), mod)
        @test calls == [("test", PassOptions(Dialect(VERSION), (; target=:x86)))]
        @dispose pb=PassBuilder() begin
            LLVM.register!(pb, JuliaIR.custom_pass(kw_pass))
            add!(pb, "jl-test<target=x86>")
            @test_throws PassException run!(pb, mod)
        end

        # a definition's check validates them when the pass is created
        checked_pass = JuliaIR.PassDefinition("jl-test", :module, false, record_pass,
                                              (; target=nothing), "",
                                              extra -> extra.target isa Union{Nothing,Symbol} ||
                                                  throw(ArgumentError("target must be a Symbol")))
        @test !JuliaIR.custom_pass(checked_pass; target=:x86).required
        @test_throws "target must be a Symbol" JuliaIR.custom_pass(checked_pass; target="x86")

        # vector-valued options are set by keyword arguments only
        vector_pass = JuliaIR.PassDefinition("jl-test", :module, false, record_pass,
                                             (; names=String[]))
        empty!(calls)
        run!(JuliaIR.custom_pass(vector_pass; names=Any["a", "b"]), mod)
        @test calls == [("test", PassOptions(Dialect(VERSION), (; names=["a", "b"])))]
        @test_throws "must be a vector of String" JuliaIR.custom_pass(vector_pass; names=[1])
        @test_throws "must be a vector of String" JuliaIR.custom_pass(vector_pass; names="a")
    end
end

@testset "module facts" begin
    # computed on the first function of a run, reused for the others
    computed = String[]
    seen = Tuple{String,Int}[]
    function facts_pass(f, am, opts)
        mod = LLVM.parent(f)
        n = JuliaIR.module_facts(opts, mod, Int) do
            push!(computed, mod.name)
            length(computed)
        end
        push!(seen, (LLVM.name(f), n))
        return PreservedAnalyses(AllAnalyses)
    end
    facts_def = JuliaIR.PassDefinition("jl-test-facts", :function, false, facts_pass)
    @dispose ctx=Context(; opaque_pointers=true) begin
        mod = parse(LLVM.Module, """
            define void @f() {
              ret void
            }
            define void @g() {
              ret void
            }""")
        mod.name = "first"
        run!(JuliaIR.custom_pass(facts_def), mod)
        @test computed == ["first"]
        @test seen == [("f", 1), ("g", 1)]
        # every run parses the pipeline, creating new options
        run!(JuliaIR.custom_pass(facts_def), mod)
        @test computed == ["first", "first"]
        @test seen[3:4] == [("f", 2), ("g", 2)]
        dispose(mod)
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
                run!(JuliaIR.custom_pass(test_pass), mod)
                @test isempty(read(path, String))

                # on
                JuliaIR.LEDGER[] = path
                run!(JuliaIR.custom_pass(test_pass), mod)
                run!(JuliaIR.custom_pass(test_pass; fp16=:keep), mod)
                line = "$(getpid())\tpass\tjl-test\tjulia=$VERSION\tllvm=$(LLVM.version())"
                @test readlines(path) == [line, line]
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

    # processes appending concurrently neither lose nor garble lines
    mktempdir() do dir
        path = joinpath(dir, "ledger.tsv")
        go = joinpath(dir, "go")
        nprocs, nlines = 4, 2000
        # each process signals that it loaded the package, then waits for the others
        script = """
            using JuliaIR
            touch(joinpath($(repr(dir)), "ready-\$(getpid())"))
            while !isfile($(repr(go)))
                sleep(0.01)
            end
            for i in 1:$nlines
                JuliaIR.ledger_write("pass", "jl-test", i, "x"^(i % 100))
            end
            """
        cmd = addenv(`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $script`,
                     "JULIAIR_LEDGER" => path)
        procs = Base.Process[]
        try
            for _ in 1:nprocs
                push!(procs, run(cmd; wait=false))
            end
            deadline = time() + 600
            while count(startswith("ready-"), readdir(dir)) < nprocs &&
                  !any(process_exited, procs) && time() < deadline
                sleep(0.01)
            end
            touch(go)
            while !all(process_exited, procs) && time() < deadline
                sleep(0.01)
            end
        finally
            foreach(kill, filter(process_running, procs))
            foreach(wait, procs)
        end
        @test all(success, procs)

        lines = readlines(path)
        @test length(lines) == nprocs * nlines
        seen = Dict{Int,Vector{Int}}()
        garbled = String[]
        for line in lines
            m = match(r"^(\d+)\tpass\tjl-test\t(\d+)\t(x*)$", line)
            if m === nothing || length(m[3]) != parse(Int, m[2]) % 100
                push!(garbled, line)
            else
                push!(get!(seen, parse(Int, m[1]), Int[]), parse(Int, m[2]))
            end
        end
        @test isempty(garbled)
        @test length(seen) == nprocs
        @test all(==(1:nlines), values(seen))
    end
end

@testset "pass registry" begin
    @test JuliaIR.passes() isa Vector{String}
    @test all(startswith("jl-"), JuliaIR.passes())
    @dispose pb=PassBuilder() begin
        @test JuliaIR.register!(pb; fp16=:keep) === pb
        # FinalLowerGC is registered as a module and as a function pass, and the marker
        # passes of Julia's pipeline are registered too
        @test length(pb.custom_passes) ==
              length(JuliaIR.PASSES) + length(JuliaIR.marker_passes())
        @test count(p -> p.name == "jl-final-lower-gc", pb.custom_passes) == 2
    end
    # defaults for the options of a pass
    @dispose pb=PassBuilder() begin
        options = Dict("jl-gc-invariant-verifier" => (; strong=true))
        @test JuliaIR.register!(pb; options) === pb
    end
    @dispose pb=PassBuilder() begin
        @test_throws "must be a Bool" JuliaIR.register!(pb;
            options=Dict("jl-gc-invariant-verifier" => (; strong=:yes)))
    end
    @dispose pb=PassBuilder() begin
        @test_throws "options for unknown pass" JuliaIR.register!(pb;
            options=Dict("jl-nonexistent" => (; strong=true)))
    end
end

end
