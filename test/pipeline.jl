using LLVM, LLVM.IR, LLVM.Passes, LLVM.Analysis
using InteractiveUtils: code_llvm
using JuliaIR: JuliaPipeline, PIPELINE_OPTIONS, pipeline_option_names,
               parse_pipeline_options, split_pipeline, expand_julia_pipeline

const PIPELINE_MINOR = JuliaIR.dialect_minor(VERSION)

# a pipeline as LLVM parses it, with this package's passes
function printed(text)
    @dispose ctx=Context() pb=PassBuilder() begin
        JuliaIR.register!(pb)
        add!(pb, text)
        sprint(print_pipeline, pb)
    end
end

# What can't be told apart in a printed pipeline: the C++ adds pass managers that are
# empty, which pipeline text can't express, 1.14's IRCE with cleanup is a pass of the
# C++ pipeline without a name of its own, and the early-only `vector-combine` (tested
# below) is printed as the other.
function normalize_cpp(s)
    s = replace(s, "{anonymous}::IRCEWithCleanupPass" => "jl-irce-with-cleanup")
    while true
        t = replace(s, r"(^|,)(cgscc|function)\(\)(?=,|\)|$)" => "")
        t = replace(t, r"^," => "", "(," => "(")
        t == s && return s
        s = t
    end
end
normalize_rebuilt(s) = replace(s, "vector-combine<early>" => "vector-combine")

# every level, alone and with each option toggled, and the combinations of options that
# only matter together
function configurations()
    configs = NamedTuple[]
    for level in 0:3
        push!(configs, (; level))
        for name in pipeline_option_names(PIPELINE_MINOR)
            startswith(string(name), "sanitize_") && continue
            name === :remove_ni && continue  # only when not lowering intrinsics, below
            push!(configs, (; level, name => !PIPELINE_OPTIONS[name]))
        end
        push!(configs, (; level, dump_native=true, external_use=true))
        PIPELINE_MINOR >= v"1.11" &&
            push!(configs, (; level, lower_intrinsics=false, remove_ni=false))
    end
    return configs
end

julia_element(config) =
    "julia<" * join([k === :level ? "level=$v" : v ? "$k" : "no_$k"
                     for (k, v) in pairs(config)], ";") * ">"

# the IR of a function before optimization (Julia numbers its globals differently each time)
unoptimized_ir(f, types) =
    sprint(io -> code_llvm(io, f, types; raw=true, optimize=false, dump_module=true,
                           debuginfo=:none))

sum_loop(x) = sum(x)
function boxed(n)
    v = Any[]
    for i in 1:n
        push!(v, string(i))
    end
    return v
end

@testset "pipeline" begin

@testset "structure: $(julia_element(config))" for config in configurations()
    # with the ports, which take the place of the C++ passes (except for those in
    # `CPP_FALLBACKS`), on any LLVM
    ports = printed(JuliaIR.pipeline(; config...))
    @test !any(name -> occursin(Regex("\\b$name\\b"), ports),
               setdiff(keys(JuliaIR.cpp_mapping()), values(JuliaIR.CPP_FALLBACKS)))

    # the C++ pipeline and its rebuilt version with Julia's C++ passes, which only Julia's
    # LLVM has
    if julia_llvm_in_use()
        cpp = normalize_cpp(printed(julia_element(config)))
        rebuilt = normalize_rebuilt(printed(JuliaIR.pipeline(; ports=false, config...)))
        @test cpp == rebuilt
        cpp_names = Dict(def.name => def.cpp_name for def in JuliaIR.PASSES
                         if !isempty(def.cpp_name))
        unported = replace(ports, r"jl-[a-z0-9-]+(<[^>]*>)?" => function (s)
            get(cpp_names, match(r"jl-[a-z0-9-]+", s).match, s)
        end)
        @test normalize_rebuilt(unported) == rebuilt
    end
end

@testset "options" begin
    p = JuliaPipeline()
    @test p.level == 2 && p.ports && p.options == PIPELINE_OPTIONS
    @test JuliaPipeline(; level=7).level == 3
    @test JuliaPipeline(; level=-1).level == 0
    @test_throws "unknown option frobnicate" JuliaPipeline(; frobnicate=true)
    @test_throws ArgumentError("option dump_native of Julia's pipeline must be a Bool") JuliaPipeline(; dump_native=1)
    if PIPELINE_MINOR == v"1.10"
        @test_throws "has no option cleanup" JuliaPipeline(; cleanup=false)
    else
        @test !JuliaPipeline(; cleanup=false).options.cleanup
        @test_throws "can't be turned off" JuliaPipeline(; remove_ni=false)
    end
    if PIPELINE_MINOR >= v"1.14"
        @test_throws "only stock Julia builds" JuliaPipeline(; sanitize_address=true)
        @test JuliaPipeline(; sanitize_address=false).options == PIPELINE_OPTIONS
    else
        @test_throws "has no option sanitize_address" JuliaPipeline(; sanitize_address=false)
    end

    # the text of Julia's pipeline element
    @test parse_pipeline_options("") == (;)
    @test parse_pipeline_options("level=3;dump_native;no_lower_intrinsics") ==
          (; level=3, dump_native=true, lower_intrinsics=false)
    @test_throws "must be an integer" parse_pipeline_options("level=x")
    @test_throws "unknown option frobnicate" parse_pipeline_options("frobnicate")
    @test_throws "unknown option no_level" parse_pipeline_options("no_level=2")
    @test JuliaPipeline("level=1").level == 1
end

@testset "spelling" begin
    # where the C++ uses `VectorCombinePass(/*TryEarlyFoldsOnly=*/true)`, which prints
    # like the other one
    scalar = JuliaIR.scalar_optimization!(FunctionPassManager(), JuliaPipeline())
    @test ("vector-combine<early>" in scalar.passes) == (PIPELINE_MINOR >= v"1.13")
    @test !("vector-combine" in scalar.passes)

    # LLVM 15 has no CFG option for SROA, and keeps the CFG
    @test JuliaIR.sroa_preserve_cfg() ==
          (LLVM.version() < v"16" ? "sroa" : "sroa<preserve-cfg>")
end

@testset "pipeline text" begin
    @test split_pipeline("a,function(b,c<x;y>),d<e,f>") == ["a", "function(b,c<x;y>)", "d<e,f>"]
    @test split_pipeline("a") == ["a"]

    full = JuliaIR.pipeline(; level=3)
    @test expand_julia_pipeline("julia<level=3>") == full
    @test expand_julia_pipeline("julia") == JuliaIR.pipeline()
    @test expand_julia_pipeline("dce,julia<level=3>,module(julia<level=3>)") ==
          "dce,$full,module($full)"
    @test expand_julia_pipeline("julia<level=0>"; ports=false) ==
          JuliaIR.pipeline(; level=0, ports=false)
    # names that merely start with `julia` are left alone
    @test expand_julia_pipeline("julia-frob,function(julia)") == "julia-frob,function(julia)"
    @test_throws "unknown option" expand_julia_pipeline("julia<frob>")
end

@testset "behaviour" begin
    # the rebuilt pipeline does what Julia's does, with the alias analyses Julia uses
    @testset "$(nameof(f)) at level $level" for (f, types) in ((sum_loop, (Vector{Float64},)),
                                                              (boxed, (Int,))),
                                                level in 0:3
        ir = unoptimized_ir(f, types)
        @dispose ctx=Context(; opaque_pointers=true) begin
            function optimized(text)
                mod = parse(LLVM.Module, ir)
                @dispose pb=PassBuilder() begin
                    JuliaIR.register!(pb)
                    JuliaIR.alias_analyses!(pb, level)
                    add!(pb, text)
                    run!(pb, mod)
                end
                verify(mod)
                string(mod)
            end
            # LateLowerGCFrame's order of GC frame slots varies between runs (it iterates
            # over pointer-keyed containers), so a difference is retried a few times
            julia_llvm_in_use() && @test any(1:10) do _
                optimized(julia_element((; level))) ==
                    optimized(JuliaIR.pipeline(; level, ports=false))
            end

            # with the ports, everything of Julia's is lowered
            mod = parse(LLVM.Module, ir)
            JuliaIR.optimize!(mod; level)
            verify(mod)
            @test !occursin(r"call [^@]*@julia\.", string(mod))
        end
    end
end

@testset "target of CPUFeatures" begin
    # Julia's JIT gives CPUFeatures its target machine from Julia 1.14 on
    ir = """
        target triple = "x86_64-unknown-linux-gnu"
        declare i1 @julia.cpu.have_fma.f64()
        define i1 @f() {
          %fma = call i1 @julia.cpu.have_fma.f64()
          ret i1 %fma
        }
        """
    if :X86 in LLVM.backends() && JuliaIR.Dialect(VERSION).cpu_features_rule === :subtarget
        @dispose ctx=Context(; opaque_pointers=true) begin
            answers = map(("x86-64", "haswell")) do cpu
                mod = parse(LLVM.Module, ir)
                tm = JuliaIR.target_machine(mod; cpu)
                try
                    JuliaIR.optimize!(mod, tm; level=0)
                    occursin("ret i1 true", string(mod))
                finally
                    dispose(tm)
                    dispose(mod)
                end
            end
            @test answers == (false, true)
        end
    end
end

@testset "IRCE with cleanup" begin
    ir = """
        define void @changed(ptr %arr, ptr %len_ptr, i32 %n) {
        entry:
          %len = load i32, ptr %len_ptr, !range !0
          %first = icmp sgt i32 %n, 0
          br i1 %first, label %loop, label %exit
        loop:
          %idx = phi i32 [ 0, %entry ], [ %idx.next, %in.bounds ]
          %idx.next = add i32 %idx, 1
          %abc = icmp slt i32 %idx, %len
          br i1 %abc, label %in.bounds, label %out.of.bounds, !prof !1
        in.bounds:
          %addr = getelementptr i32, ptr %arr, i32 %idx
          store i32 0, ptr %addr
          %next = icmp slt i32 %idx.next, %n
          br i1 %next, label %loop, label %exit
        out.of.bounds:
          ret void
        exit:
          ret void
        }

        define i32 @unchanged(i32 %x) {
        entry:
          br i1 true, label %a, label %b
        a:
          ret i32 %x
        b:
          ret i32 0
        }

        !0 = !{i32 0, i32 2147483647}
        !1 = !{!"branch_weights", i32 64, i32 4}
        """
    run_pipeline(text, name) = @dispose ctx=Context(; opaque_pointers=true) begin
        mod = parse(LLVM.Module, ir)
        @dispose pb=PassBuilder() begin
            JuliaIR.register!(pb)
            add!(pb, text)
            run!(pb, mod)
        end
        verify(mod)
        string(LLVM.functions(mod)[name])
    end
    cleanup = "function(irce,$(JuliaIR.basic_simplifycfg()),$(InstCombinePass()))"
    # when IRCE changes the function, it is cleaned up
    changed = run_pipeline("function(jl-irce-with-cleanup)", "changed")
    @test changed != run_pipeline("function(irce)", "changed")
    @test changed == run_pipeline(cleanup, "changed")
    # otherwise it isn't (which would fold the branch)
    @test run_pipeline("function(jl-irce-with-cleanup)", "unchanged") ==
          run_pipeline("function(irce)", "unchanged")
    @test run_pipeline("function(jl-irce-with-cleanup)", "unchanged") !=
          run_pipeline(cleanup, "unchanged")
end

end
