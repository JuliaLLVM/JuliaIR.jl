using LLVM, LLVM.IR, LLVM.Passes
using JuliaIR: Dialect, PassOptions, parse_options, options_string, option

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

    # pass-specific options, declared by their defaults
    options = (; strong=false, mode=:fast)
    @test parse_options(""; options).extra == (; strong=false, mode=:fast)
    @test parse_options("strong"; options).extra == (; strong=true, mode=:fast)
    @test parse_options("no-strong;mode=slow-ish"; options).extra == (; strong=false, mode=:slow_ish)
    @test_throws "is a flag" parse_options("strong=1"; options)
    @test_throws "requires a value" parse_options("mode"; options)
    @test_throws "requires a value" parse_options("no-mode"; options)
    # values for the options not given
    @test parse_options("strong"; options, values=(; strong=false, mode=:slow)).extra ==
          (; strong=true, mode=:slow)

    # integers and strings
    let options = (; size=option(Int, 0; valid=(>=(0)), requirement="a non-negative integer"),
                     offset=0, name="")
        @test parse_options("size=264;offset=-8;name=__sigsetjmp"; options).extra ==
              (; size=264, offset=-8, name="__sigsetjmp")
        opts = parse_options("size=8;offset=-1;name=a_b-c"; options)
        @test options_string(opts, options) == "size=8;offset=-1;name=a_b-c"
        @test parse_options(options_string(opts, options); options) == opts
        @test_throws "option size requires a non-negative integer" parse_options("size=x"; options)
        @test_throws "option size requires a non-negative integer" parse_options("size=-1"; options)
        @test_throws "option offset requires an integer" parse_options("offset=x"; options)
        @test_throws "requires a value" parse_options("name"; options)
    end

    # options that may be unspecified, and addresses
    let options = (; offset=option(Union{Nothing,Int}, nothing),
                     addr=option(Union{Nothing,UInt}, nothing),
                     elf=option(Union{Nothing,Bool}, nothing))
        opts = parse_options(""; options)
        @test opts.extra == (; offset=nothing, addr=nothing, elf=nothing)
        @test options_string(opts, options) == ""
        opts = parse_options("offset=-8;addr=0x4011c0;elf=no"; options)
        @test opts.extra == (; offset=-8, addr=UInt(0x4011c0), elf=false)
        @test options_string(opts, options) == "offset=-8;addr=0x4011c0;elf=no"
        @test parse_options(options_string(opts, options); options) == opts
        @test parse_options("addr=4198848;elf=yes"; options).extra.addr === UInt(0x4011c0)
        @test parse_options("elf=yes"; options).extra.elf === true
        @test_throws "requires an integer" parse_options("offset=x"; options)
        @test_throws "requires an address (a non-negative integer)" parse_options("addr=-1"; options)
        @test_throws "requires yes or no" parse_options("elf=auto"; options)
        @test_throws "requires a value" parse_options("offset"; options)
        @test_throws "requires a value" parse_options("elf"; options)
    end

    # keyword-only options can't be given in text, and have no text form
    let options = (; target=option(Union{Nothing,String}, nothing; text=false), strong=false,
                     names=option(Vector{String}, String[]; text=false))
        @test_throws "option target can't be given in a pipeline" parse_options("target=x86"; options)
        @test_throws "option names can't be given in a pipeline" parse_options("names=a"; options)
        @test_throws "option names can't be given in a pipeline" parse_options("names"; options)
        opts = parse_options("strong"; options,
                             values=(; target="x86", strong=false, names=["a"]))
        @test opts.extra == (; target="x86", strong=true, names=["a"])
        @test options_string(opts, options) == "strong"
    end

    # declarations
    @test_throws "have no text form" option(Vector{String}, String[])
    @test_throws "have no text form" option(Float64, 1.0)
    @test_throws "the default of the option must be an integer" option(Int, 1.0)
    @test_throws "must be a non-negative integer" option(Int, -1; valid=(>=(0)),
                                                         requirement="a non-negative integer")
    @test_throws "have no text form" JuliaIR.PassDefinition("jl-test", :module, false,
                                                            identity, (; target=nothing))
    @test option(Union{Nothing,Int}, nothing).default === nothing

    # round trip
    for str in ["", "fp16=demote", "fp16=keep;bf16=demote",
                "gc-barrier=snapshot-field-precise"]
        @test options_string(parse_options(str)) == str
        @test parse_options(options_string(parse_options(str))) == parse_options(str)
    end
    @test options_string(parse_options(""; options), options) == "no-strong;mode=fast"
    let opts = parse_options("fp16=keep;strong;mode=slow"; options)
        @test options_string(opts, options) == "fp16=keep;strong;mode=slow"
        @test parse_options(options_string(opts, options); options) == opts
    end

    # rejections
    @test_throws "unknown option frobnicate" parse_options("frobnicate")
    @test_throws "unknown option strong" parse_options("strong")
    # the dialect isn't an option: it is the running Julia's
    @test_throws "unknown option julia; expected one of fp16, bf16, gc-barrier" parse_options("julia=1.12")
    @test_throws "unknown option julia" parse_options("julia")
    @test_throws "more than once" parse_options("fp16=keep;fp16=demote")
    @test_throws "more than once" parse_options("strong;no-strong"; options)
    @test_throws "more than once" parse_options("foo-bar;no-foo_bar"; options=(; foo_bar=false))
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
        @test_throws "option strong of pass jl-test must be a Bool" JuliaIR.custom_pass(test_pass; strong=:no)

        # keyword arguments are converted to the types of the options where that loses
        # nothing, and options that may be unspecified take `nothing`
        typed_pass = JuliaIR.PassDefinition("jl-test-typed", :module, false, record_pass,
                                            (; offset=option(Union{Nothing,Int}, nothing),
                                               addr=option(Union{Nothing,UInt}, nothing),
                                               name=""))
        empty!(calls)
        run!(JuliaIR.custom_pass(typed_pass; offset=Int32(-8), addr=Ptr{Cvoid}(UInt(0x10)),
                                 name=SubString("abc", 1, 2)), mod)
        run!(JuliaIR.custom_pass(typed_pass; offset=nothing, addr=16), mod)
        @test [c[2].extra for c in calls] ==
              [(; offset=-8, addr=UInt(0x10), name="ab"),
               (; offset=nothing, addr=UInt(0x10), name="")]
        @test calls[1][2].extra.name isa String
        @test_throws "must be an address or `nothing`" JuliaIR.custom_pass(typed_pass; addr=-1)
        @test_throws "must be an integer or `nothing`" JuliaIR.custom_pass(typed_pass; offset="x")
        @test_throws "must be an integer or `nothing`" JuliaIR.custom_pass(typed_pass; offset=typemax(UInt))
        @test_throws "option name of pass jl-test-typed must be a string" JuliaIR.custom_pass(typed_pass; name=nothing)

        # keyword-only options can only be given as keyword arguments
        kw_pass = JuliaIR.PassDefinition("jl-test", :module, false, record_pass,
                                         (; target=option(Union{Nothing,Symbol}, nothing;
                                                          text=false)))
        empty!(calls)
        run!(JuliaIR.custom_pass(kw_pass; target=:x86), mod)
        @test calls == [("test", PassOptions(Dialect(VERSION), (; target=:x86)))]
        @test_throws "must be a Symbol or `nothing`" JuliaIR.custom_pass(kw_pass; target="x86")
        @dispose pb=PassBuilder() begin
            LLVM.register!(pb, JuliaIR.custom_pass(kw_pass))
            add!(pb, "jl-test<target=x86>")
            @test_throws PassException run!(pb, mod)
        end

        # a definition's check validates the combination of the values, whether they come
        # from keyword arguments or the pipeline
        checked_pass = JuliaIR.PassDefinition("jl-test", :module, false, record_pass,
                                              (; a=false, b=false), "",
                                              values -> values.a && values.b &&
                                                  throw(ArgumentError("a and b can't be combined")))
        @test !JuliaIR.custom_pass(checked_pass; a=true).required
        @test_throws "a and b can't be combined" JuliaIR.custom_pass(checked_pass; a=true, b=true)
        @test_throws "a and b can't be combined" parse_options(checked_pass, "a;b")
        @dispose pb=PassBuilder() begin
            LLVM.register!(pb, JuliaIR.custom_pass(checked_pass; a=true))
            add!(pb, "jl-test<b>")
            @test_throws PassException run!(pb, mod)
        end

        # vectors of any element type the option's
        vector_pass = JuliaIR.PassDefinition("jl-test", :module, false, record_pass,
                                             (; names=option(Vector{String}, String[];
                                                             text=false)))
        empty!(calls)
        run!(JuliaIR.custom_pass(vector_pass; names=Any["a", "b"]), mod)
        @test calls == [("test", PassOptions(Dialect(VERSION), (; names=["a", "b"])))]
        @test calls[1][2].extra.names isa Vector{String}
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
