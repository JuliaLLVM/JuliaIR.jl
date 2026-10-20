# Julia 1.10's pipeline (`src/pipeline.cpp` at v1.10.12).
#
# Julia 1.11 added options to leave out stages; the stages that 1.11 didn't change
# otherwise are 1.11's, as these options keep their defaults on Julia 1.10. Julia 1.10's
# `SROAPass()` means `sroa<preserve-cfg>` on the LLVM versions that have that option.

aggressive_simplifycfg(::Recipe{10}) = aggressive_simplifycfg(Recipe{11}())

early_simplification!(mpm, p::JuliaPipeline, ::Recipe{10}) =
    early_simplification!(mpm, p, Recipe{11}())

function early_optimization!(mpm, p::JuliaPipeline, ::Recipe{10})
    add!(mpm, "BeforeEarlyOptimization")
    # an empty CGSCC pass manager (below level 2) can't be written as pipeline text
    add!(mpm, CGSCCPassManager()) do cgpm
        p.level >= 2 && add!(cgpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-alloc-opt")
            add!(fpm, Float2IntPass())
            add!(fpm, LowerConstantIntrinsicsPass())
        end
    end
    if p.options.dump_native
        add!(mpm, StripDeadPrototypesPass())
        julia_pass!(mpm, p, "jl-multiversioning"; external=p.options.external_use)
    end
    julia_pass!(mpm, p, "jl-cpu-features")
    p.level >= 1 && add!(mpm, FunctionPassManager()) do fpm
        if p.level >= 2
            add!(fpm, sroa_preserve_cfg())
            add!(fpm, InstCombinePass())
            add!(fpm, JumpThreadingPass())
            add!(fpm, CorrelatedValuePropagationPass())
            add!(fpm, ReassociatePass())
            add!(fpm, EarlyCSEPass())
            julia_pass!(fpm, p, "jl-alloc-opt")
        else
            add!(fpm, InstCombinePass())
            add!(fpm, EarlyCSEPass())
        end
    end
    add!(mpm, "AfterEarlyOptimization")
end

loop_optimization!(fpm, p::JuliaPipeline, ::Recipe{10}) =
    loop_optimization!(fpm, p, Recipe{11}())

function scalar_optimization!(fpm, p::JuliaPipeline, r::Recipe{10})
    add!(fpm, "BeforeScalarOptimization")
    if p.level >= 2
        julia_pass!(fpm, p, "jl-alloc-opt")
        add!(fpm, sroa_preserve_cfg())
        add!(fpm, InstSimplifyPass())
        add!(fpm, GVNPass())
        add!(fpm, MemCpyOptPass())
        add!(fpm, SCCPPass())
        add!(fpm, CorrelatedValuePropagationPass())
        add!(fpm, DCEPass())
        add!(fpm, IRCEPass())
        add!(fpm, InstCombinePass())
        add!(fpm, JumpThreadingPass())
    elseif p.level >= 1
        julia_pass!(fpm, p, "jl-alloc-opt")
        add!(fpm, sroa_preserve_cfg())
        add!(fpm, MemCpyOptPass())
        add!(fpm, SCCPPass())
        add!(fpm, InstCombinePass())
        add!(fpm, ADCEPass())
    end
    p.level >= 3 && add!(fpm, GVNPass())
    if p.level >= 2
        add!(fpm, DSEPass())
        add!(fpm, aggressive_simplifycfg(r))
        julia_pass!(fpm, p, "jl-alloc-opt")
        add!(fpm, LoopPassManager()) do lpm
            add!(lpm, LoopDeletionPass())
            add!(lpm, LoopInstSimplifyPass())
        end
        add!(fpm, LoopDistributePass())
    end
    add!(fpm, "AfterScalarOptimization")
end

vectorization!(fpm, p::JuliaPipeline, ::Recipe{10}) = vectorization!(fpm, p, Recipe{11}())

function intrinsic_lowering!(mpm, p::JuliaPipeline, r::Recipe{10})
    add!(mpm, "BeforeIntrinsicLowering")
    if p.options.lower_intrinsics
        add!(mpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-lower-exc-handlers")
            julia_pass!(fpm, p, "jl-gc-invariant-verifier"; strong=false)
        end
        julia_pass!(mpm, p, "jl-remove-ni")
        add!(mpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-late-lower-gc-frame")
        end
        # FinalLowerGC is a module pass in Julia 1.10
        julia_pass!(mpm, p, "jl-final-lower-gc")
        p.level >= 2 && add!(mpm, FunctionPassManager()) do fpm
            add!(fpm, GVNPass())
            add!(fpm, SCCPPass())
            add!(fpm, DCEPass())
        end
        julia_pass!(mpm, p, "jl-lower-ptls"; imaging=p.options.dump_native)
        p.level >= 1 && add!(mpm, FunctionPassManager()) do fpm
            add!(fpm, InstCombinePass())
            add!(fpm, aggressive_simplifycfg(r))
        end
    else
        julia_pass!(mpm, p, "jl-remove-ni")
    end
    add!(mpm, "AfterIntrinsicLowering")
end

cleanup!(mpm, p::JuliaPipeline, ::Recipe{10}) = cleanup!(mpm, p, Recipe{11}())
