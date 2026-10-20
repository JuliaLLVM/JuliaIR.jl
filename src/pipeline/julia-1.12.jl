# Julia 1.12's pipeline (`src/pipeline.cpp` at v1.12.7).

aggressive_simplifycfg(::Recipe{12}) = aggressive_simplifycfg(Recipe{11}())

function early_simplification!(mpm, p::JuliaPipeline, ::Recipe{12})
    add!(mpm, "BeforeEarlySimplification")
    if p.options.enable_early_simplifications
        add!(mpm, ForceFunctionAttrsPass())
        add!(mpm, Annotation2MetadataPass())
        add!(mpm, InferFunctionAttrsPass())
        add!(mpm, ConstantMergePass())
        add!(mpm, FunctionPassManager()) do fpm
            add!(fpm, LowerExpectIntrinsicPass())
            p.level >= 2 && julia_pass!(fpm, p, "jl-propagate-addrspaces")
            add!(fpm, DCEPass())
            add!(fpm, basic_simplifycfg())
            p.level >= 1 && add!(fpm, sroa_preserve_cfg())
        end
    end
    add!(mpm, "AfterEarlySimplification")
end

early_optimization!(mpm, p::JuliaPipeline, ::Recipe{12}) =
    early_optimization!(mpm, p, Recipe{11}())

loop_optimization!(fpm, p::JuliaPipeline, ::Recipe{12}) =
    loop_optimization!(fpm, p, Recipe{11}())

function scalar_optimization!(fpm, p::JuliaPipeline, r::Recipe{12})
    add!(fpm, "BeforeScalarOptimization")
    if p.options.enable_scalar_optimizations
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
    end
    add!(fpm, "AfterScalarOptimization")
end

vectorization!(fpm, p::JuliaPipeline, ::Recipe{12}) = vectorization!(fpm, p, Recipe{11}())

function intrinsic_lowering!(mpm, p::JuliaPipeline, r::Recipe{12})
    add!(mpm, "BeforeIntrinsicLowering")
    if p.options.lower_intrinsics
        add!(mpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-lower-exc-handlers")
            julia_pass!(fpm, p, "jl-gc-invariant-verifier"; strong=false)
        end
        julia_pass!(mpm, p, "jl-remove-ni")
        add!(mpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-late-lower-gc-frame")
            julia_pass!(fpm, p, "jl-final-lower-gc")
            if p.level >= 2
                add!(fpm, DSEPass())
                add!(fpm, GVNPass())
                add!(fpm, SCCPPass())
                add!(fpm, DCEPass())
            end
        end
        julia_pass!(mpm, p, "jl-lower-ptls"; imaging=p.options.dump_native)
        add!(mpm, julia_pass(p, "jl-remove-addrspaces"))
        p.level >= 1 && add!(mpm, FunctionPassManager()) do fpm
            add!(fpm, InstCombinePass())
            add!(fpm, aggressive_simplifycfg(r))
        end
    elseif !p.options.remove_ni
        julia_pass!(mpm, p, "jl-remove-ni")
    end
    add!(mpm, "AfterIntrinsicLowering")
end

function cleanup!(mpm, p::JuliaPipeline, ::Recipe{12})
    add!(mpm, "BeforeCleanup")
    if p.options.cleanup
        p.level >= 2 && add!(mpm, FunctionPassManager()) do fpm
            add!(fpm, DivRemPairsPass())
        end
        add!(mpm, FunctionPassManager()) do fpm
            add!(fpm, AnnotationRemarksPass())
        end
        add!(mpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-demote-float16")
            p.level >= 2 && add!(fpm, GVNPass())
        end
    end
    add!(mpm, "AfterCleanup")
end
