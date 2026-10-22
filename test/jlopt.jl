using LLVM, LLVM.IR, LLVM.Passes
using JuliaIR: jlopt, JloptError, parse_jlopt_args, legacy_pipeline, map_pipeline

@testset "jlopt" begin

@testset "arguments" begin
    opts = parse_jlopt_args(["-passes=foo", "-S", "in.ll", "-o", "out.ll"])
    @test opts.pipeline == "foo"
    @test opts.text
    @test opts.input == "in.ll"
    @test opts.output == "out.ll"
    @test parse_jlopt_args(["--passes=foo"]).pipeline == "foo"
    @test parse_jlopt_args(["-p", "foo"]).pipeline == "foo"
    @test parse_jlopt_args(["-passes=foo", "-oout.bc"]).output == "out.bc"
    @test parse_jlopt_args(["-mtriple=nvptx64-nvidia-cuda"]).triple == "nvptx64-nvidia-cuda"
    opts = parse_jlopt_args(["-mcpu=haswell", "--mattr=+avx2,-fma"])
    @test (opts.cpu, opts.features) == ("haswell", "+avx2,-fma")
    @test parse_jlopt_args(["-mattr="]).features == ""
    @test parse_jlopt_args(String[]).features === nothing
    @test parse_jlopt_args(["-mattr=-avx512f", "-mattr=+avx2,+fma"]).features ==
          "-avx512f,+avx2,+fma"
    @test parse_jlopt_args(["-verify-memoryssa"]).llvm_options == ["-verify-memoryssa"]
    @test parse_jlopt_args(["--print-before=BeforeLICM", "-print-before-all", "-force-vector-width=2"]).llvm_options ==
          ["-print-before=BeforeLICM", "-print-before-all", "-force-vector-width=2"]
    @test_throws "unknown option" parse_jlopt_args(["-force-vector-width=two"])
    @test !parse_jlopt_args(["-map-julia-passes=0"]).map_passes
    @test parse_jlopt_args(String[]).map_passes
    withenv("JULIAIR_MAP_PASSES" => "0") do
        @test !parse_jlopt_args(String[]).map_passes
        @test parse_jlopt_args(["-map-julia-passes=1"]).map_passes
    end

    # Julia's plugin is accepted, others are not
    @test parse_jlopt_args(["--load-pass-plugin=libjulia-codegen.so"]).pipeline === nothing
    @test parse_jlopt_args(["-load", "/path/to/libjulia-codegen.dylib"]).pipeline === nothing
    @test_throws "cannot load plugin" parse_jlopt_args(["--load-pass-plugin=libfoo.so"])

    @test_throws "typed pointers" parse_jlopt_args(["--opaque-pointers=0"])
    @test parse_jlopt_args(["--opaque-pointers=1"]).pipeline === nothing
    @test_throws "unknown option -frobnicate" parse_jlopt_args(["-frobnicate"])
    @test_throws "more than one input" parse_jlopt_args(["a.ll", "b.ll"])
    @test_throws "missing value" parse_jlopt_args(["-o"])
    # the passes process the running Julia's IR; there is no option for another version
    @test_throws "unknown option -julia=1.12" parse_jlopt_args(["-julia=1.12"])
    @test_throws JloptError jlopt(String[]; stdin=IOBuffer(""))
end

@testset "legacy pass manager" begin
    opts = parse_jlopt_args(["-enable-new-pm=0", "-AllocOpt", "-LateLowerGCFrame", "-FinalLowerGC"])
    @test opts.pipeline == "function(AllocOpt,LateLowerGCFrame),FinalLowerGC"
    @test legacy_pipeline(["JuliaLICM"]) == "function(loop(JuliaLICM))"
    @test legacy_pipeline(["LowerSIMDLoop", "JuliaLICM", "AllocOpt", "RemoveNI"]) ==
          "function(loop(LowerSIMDLoop,JuliaLICM),AllocOpt),RemoveNI"
    @test legacy_pipeline(["PropagateJuliaAddrspaces", "dce"]) ==
          "function(PropagateJuliaAddrspaces,dce)"
    @test_throws "require -enable-new-pm=0" parse_jlopt_args(["-AllocOpt"])
    @test_throws "cannot be combined" parse_jlopt_args(["-enable-new-pm=0", "-AllocOpt", "-passes=foo"])
end

@testset "pass names" begin
    mapping = Dict("AllocOpt" => "jl-alloc-opt", "GCInvariantVerifier" => "jl-gc-invariant-verifier")
    @test map_pipeline("function(AllocOpt,LateLowerGCFrame),FinalLowerGC", mapping) ==
          "function(jl-alloc-opt,LateLowerGCFrame),FinalLowerGC"
    @test map_pipeline("function(GCInvariantVerifier<strong>,GCInvariantVerifier<no-strong>)", mapping) ==
          "function(jl-gc-invariant-verifier<strong>,jl-gc-invariant-verifier<no-strong>)"
    # only whole names
    @test map_pipeline("AllocOptX,XAllocOpt,jl-alloc-opt", mapping) == "AllocOptX,XAllocOpt,jl-alloc-opt"
    # every ported pass is mapped from the name of the C++ pass
    @test JuliaIR.cpp_mapping()["RemoveNI"] == "jl-remove-ni"

    # FinalLowerGC is a function pass from Julia 1.11 on, so a pipeline that starts with
    # it is a function pipeline, though the port is also registered as a module pass
    if !JuliaIR.Dialect(VERSION).gc_final_module
        ir = """
            define void @f() {
              ret void
            }"""
        out = sprint() do io
            jlopt(["-passes=FinalLowerGC,AllocOpt", "-S"]; stdin=IOBuffer(ir), stdout=io)
        end
        @test occursin("define void @f()", out)
    end
end

ir = """
    target datalayout = "e-i64:64-ni:10:11:12:13"
    define void @f() {
      ret void
    }"""

@testset "in-process" begin
    out = sprint() do io
        jlopt(["-passes=RemoveNI", "-S"]; stdin=IOBuffer(ir), stdout=io)
    end
    @test occursin("target datalayout = \"e-i64:64\"\n", out)
    @test occursin("; ModuleID = '<stdin>'", out)
    @test occursin("source_filename = \"<stdin>\"", out)

    # with the mapping disabled, Julia's C++ pass of that name runs instead of the port
    mktemp() do ledger, io
        close(io)
        old = JuliaIR.LEDGER[]
        JuliaIR.LEDGER[] = ledger
        try
            jlopt(["-passes=RemoveNI", "-S"]; stdin=IOBuffer(ir), stdout=devnull)
            @test count(contains("\tpass\tjl-remove-ni\t"), readlines(ledger)) == 1
            # (only Julia's LLVM has Julia's passes)
            if julia_llvm_in_use()
                jlopt(["-map-julia-passes=0", "-passes=RemoveNI", "-S"]; stdin=IOBuffer(ir),
                      stdout=devnull)
                @test count(contains("\tpass\tjl-remove-ni\t"), readlines(ledger)) == 1
            end

            # and the same for Julia's pipeline, which is rebuilt with the ports
            jlopt(["-passes=julia<level=0>", "-S"]; stdin=IOBuffer(ir), stdout=devnull)
            @test count(contains("\tpass\tjl-remove-ni\t"), readlines(ledger)) == 2
            if julia_llvm_in_use()
                jlopt(["-map-julia-passes=0", "-passes=julia<level=0>", "-S"];
                      stdin=IOBuffer(ir), stdout=devnull)
                @test count(contains("\tpass\tjl-remove-ni\t"), readlines(ledger)) == 2
            end
        finally
            JuliaIR.LEDGER[] = old
        end
    end

    # the CPU and features: of the target machine, and of the functions (as `opt`, which
    # appends the features to those a function has)
    @test JuliaIR.resolve_cpu(nothing, "+avx") == (nothing, "+avx")
    # (LLVM doesn't know the host's features everywhere, e.g. on macOS on ARM)
    host = LLVM.host_cpu_features()
    cpu, features = JuliaIR.resolve_cpu("native", "-avx")
    @test cpu == LLVM.host_cpu_name()
    @test features == (isempty(host) ? "-avx" : "$host,-avx")
    @test JuliaIR.resolve_cpu("native", nothing)[2] == LLVM.host_cpu_features()
    @dispose ctx=Context() mod=parse(LLVM.Module, ir) begin
        LLVM.triple!(mod, LLVM.default_triple())
        @dispose tm=JuliaIR.target_machine(mod) begin
            @test LLVM.cpu(tm) in ("", "generic")
        end
        @dispose tm=JuliaIR.target_machine(mod; cpu) begin
            @test LLVM.cpu(tm) == LLVM.host_cpu_name()
        end
    end
    attributed = """
        define void @f() #0 {
          ret void
        }
        define void @g() {
          ret void
        }
        attributes #0 = { "target-cpu"="x86-64" "target-features"="+avx2" }"""
    if :X86 in LLVM.backends()
        out = sprint() do io
            jlopt(["-mtriple=x86_64-unknown-linux-gnu", "-mcpu=skylake", "-mattr=-avx2",
                   "-passes=jl-remove-ni", "-S"]; stdin=IOBuffer(attributed), stdout=io)
        end
        @test occursin("\"target-cpu\"=\"x86-64\" \"target-features\"=\"+avx2,-avx2\"", out)
        @test occursin("\"target-cpu\"=\"skylake\" \"target-features\"=\"-avx2\"", out)
    end
    # the same without a target machine, when LLVM lacks the module's target
    if :Sparc ∉ LLVM.backends()
        out = sprint() do io
            redirect_stderr(devnull) do
                jlopt(["-mtriple=sparcv9-unknown-linux-gnu", "-mcpu=v9", "-mattr=-avx2",
                       "-passes=jl-remove-ni", "-S"]; stdin=IOBuffer(attributed), stdout=io)
            end
        end
        @test occursin("\"target-cpu\"=\"x86-64\" \"target-features\"=\"+avx2,-avx2\"", out)
        @test occursin("\"target-cpu\"=\"v9\" \"target-features\"=\"-avx2\"", out)
    end

    # output to a file, from the API with the standard output discarded
    mktemp() do path, io
        close(io)
        jlopt(["-passes=jl-remove-ni", "-S", "-o", path];
              stdin=IOBuffer(ir), stdout=devnull)
        @test occursin("target datalayout", read(path, String))
    end

    # input that does not verify
    broken = """
        define i32 @f() {
          ret void
        }"""
    @test_throws JloptError jlopt(["-passes=jl-remove-ni", "-S"]; stdin=IOBuffer(broken), stdout=devnull)
end

@testset "fatal errors abort" begin
    # a pass that reports invalid IR makes bin/jlopt die by a signal, like `opt` when an
    # assertion fails, which `not --crash` checks for
    script = """
        using JuliaIR, LLVM
        crash(ir, am, opts) = throw(JuliaIR.FatalPassError(ErrorException("invalid IR")))
        JuliaIR.define_pass("jl-test-crash", :module, crash; required=true, cpp_name="")
        exit(JuliaIR.jlopt_main(["-passes=jl-test-crash", "-S"]))
        """
    stderr = Pipe()
    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) -e $script`
    # without core dumps: with a core pattern like `%e-pid%p.core`, each run would leave a
    # core file of several hundred MB in the working directory
    sh = Sys.iswindows() ? nothing : Sys.which("sh")
    if sh !== nothing
        cmd = `$sh -c 'ulimit -c 0 && exec "$@"' sh $cmd`
    end
    proc = run(pipeline(ignorestatus(cmd); stdin=IOBuffer(ir), stdout=devnull, stderr);
               wait=false)
    close(stderr.in)
    output = read(stderr, String)
    wait(proc)
    if Sys.iswindows()
        @test proc.exitcode == 3  # abort() on Windows
    else
        @test proc.termsignal == 6  # SIGABRT
    end
    @test occursin("invalid IR", output)

    # other errors exit normally
    script = """
        using JuliaIR, LLVM
        fail(ir, am, opts) = error("pass failed")
        JuliaIR.define_pass("jl-test-fail", :module, fail; required=true, cpp_name="")
        exit(JuliaIR.jlopt_main(["-passes=jl-test-fail", "-S"]))
        """
    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) -e $script`
    proc = run(pipeline(ignorestatus(cmd); stdin=IOBuffer(ir), stdout=devnull, stderr=devnull))
    @test proc.exitcode == 1 && proc.termsignal == 0
end

@testset "app entry point" begin
    # the `jlopt` app of Project.toml runs `JuliaIR.main` (`@main`, Julia 1.11 and later)
    @test isdefined(JuliaIR, :main) == isdefined(Base, Symbol("@main"))
    if isdefined(JuliaIR, :main)
        mktempdir() do dir
            input = joinpath(dir, "input.ll")
            output = joinpath(dir, "output.ll")
            write(input, ir)
            @test JuliaIR.main(["-passes=jl-remove-ni", "-S", input, "-o", output]) == 0
            @test occursin("target datalayout", read(output, String))
            @test redirect_stderr(() -> JuliaIR.main(["-frobnicate"]), devnull) == 1
        end
    end

    # Pkg's shim for the app runs `julia -m JuliaIR` (Julia 1.12 and later)
    if VERSION >= v"1.12"
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project())
               -m JuliaIR -passes=jl-remove-ni -S`
        out = read(pipeline(cmd; stdin=IOBuffer(ir)), String)
        @test occursin("; ModuleID = '<stdin>'", out)
        proc = run(pipeline(ignorestatus(`$cmd -frobnicate`); stdin=devnull, stderr=devnull))
        @test proc.exitcode == 1 && proc.termsignal == 0
    end
end

end
