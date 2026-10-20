# Julia 1.14's pipeline (`src/pipeline.cpp` at 54d14c8eb9, unchanged on the release-1.14
# branch and on master up to 1.15.0-DEV.14, c4ee9157f9). Julia 1.15 uses 1.14's dialect,
# so this recipe serves it too, until its pipeline changes.

aggressive_simplifycfg(::Recipe{14}) = aggressive_simplifycfg(Recipe{13}())

function early_simplification!(mpm, p::JuliaPipeline, ::Recipe{14})
    add!(mpm, "BeforeEarlySimplification")
    if p.options.enable_early_simplifications
        add!(mpm, ForceFunctionAttrsPass())
        add!(mpm, Annotation2MetadataPass())
        add!(mpm, ConstantMergePass())
        add!(mpm, FunctionPassManager()) do fpm
            add!(fpm, LowerExpectIntrinsicPass())
            p.level >= 2 && julia_pass!(fpm, p, "jl-propagate-addrspaces")
            add!(fpm, DCEPass())
            add!(fpm, basic_simplifycfg())
            if p.level >= 1
                add!(fpm, sroa_modify_cfg())
                add!(fpm, EarlyCSEPass())
            end
        end
        if p.level >= 1
            add!(mpm, GlobalOptPass())
            add!(mpm, FunctionPassManager()) do fpm
                add!(fpm, PromotePass())
                add!(fpm, InstCombinePass())
            end
        end
    end
    add!(mpm, "AfterEarlySimplification")
end

function early_optimization!(mpm, p::JuliaPipeline, ::Recipe{14})
    add!(mpm, "BeforeEarlyOptimization")
    if p.options.enable_early_optimizations
        # Julia only walks the call graph if a plugin registered CGSCC passes, which
        # doesn't happen in its pipeline
        p.level >= 2 && add!(mpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-alloc-opt")
        end
        if p.options.dump_native
            add!(mpm, StripDeadPrototypesPass())
            julia_pass!(mpm, p, "jl-multiversioning"; external=p.options.external_use)
        end
        julia_pass!(mpm, p, "jl-cpu-features")
        p.level >= 1 && add!(mpm, FunctionPassManager()) do fpm
            if p.level >= 2
                add!(fpm, sroa_modify_cfg())
                add!(fpm, EarlyCSEPass(; memssa=true))
                add!(fpm, InstCombinePass())
                add!(fpm, AggressiveInstCombinePass())
                add!(fpm, JumpThreadingPass())
                add!(fpm, CorrelatedValuePropagationPass())
                add!(fpm, ReassociatePass())
                add!(fpm, ConstraintEliminationPass())
                julia_pass!(fpm, p, "jl-alloc-opt")
            else
                add!(fpm, EarlyCSEPass())
                add!(fpm, InstCombinePass())
            end
        end
        add!(mpm, GlobalOptPass())
        add!(mpm, GlobalDCEPass())
    end
    add!(mpm, "AfterEarlyOptimization")
end

function loop_optimization!(fpm, p::JuliaPipeline, ::Recipe{14})
    add!(fpm, "BeforeLoopOptimization")
    if p.options.enable_loop_optimizations
        add!(fpm, LoopPassManager(; use_memory_ssa=true)) do lpm
            add!(lpm, julia_pass(p, "jl-lower-simdloop"))
            if p.level >= 2
                add!(lpm, LoopInstSimplifyPass())
                add!(lpm, LoopSimplifyCFGPass())
                add!(lpm, "BeforeLICM")
                add!(lpm, LICMPass(; allowspeculation=false))
                add!(lpm, julia_pass(p, "jl-licm"))
                add!(lpm, LoopRotatePass())
                add!(lpm, LICMPass())
                add!(lpm, julia_pass(p, "jl-licm"))
                add!(lpm, "AfterLICM")
                add!(lpm, SimpleLoopUnswitchPass(; nontrivial=true, trivial=true))
            end
        end
        p.level >= 2 && add!(fpm, LoopPassManager()) do lpm
            add!(lpm, LoopFullUnrollPass())
        end
        add!(fpm, basic_simplifycfg())
        add!(fpm, InstCombinePass())
        # not one of Julia's passes, but a pass of its pipeline
        p.level >= 2 && add!(fpm, IRCE_WITH_CLEANUP.name)
        add!(fpm, LoopPassManager()) do lpm
            add!(lpm, "BeforeLoopSimplification")
            if p.level >= 2
                add!(lpm, LoopIdiomRecognizePass())
                add!(lpm, IndVarSimplifyPass())
                add!(lpm, SimpleLoopUnswitchPass(; nontrivial=true, trivial=true))
                add!(lpm, LoopDeletionPass())
                add!(lpm, LoopFullUnrollPass())
            end
            add!(lpm, "AfterLoopSimplification")
        end
    end
    add!(fpm, "AfterLoopOptimization")
end

function scalar_optimization!(fpm, p::JuliaPipeline, r::Recipe{14})
    add!(fpm, "BeforeScalarOptimization")
    if p.options.enable_scalar_optimizations
        if p.level >= 2
            julia_pass!(fpm, p, "jl-alloc-opt")
            add!(fpm, sroa_modify_cfg())
            add!(fpm, VectorCombinePass(; early=true))
            add!(fpm, MergedLoadStoreMotionPass())
            add!(fpm, GVNPass())
            add!(fpm, SCCPPass())
            add!(fpm, BDCEPass())
            add!(fpm, InstCombinePass())
            add!(fpm, CorrelatedValuePropagationPass())
            add!(fpm, ADCEPass())
            add!(fpm, MemCpyOptPass())
            add!(fpm, DSEPass())
            add!(fpm, IRCEPass())
            add!(fpm, JumpThreadingPass())
            add!(fpm, ConstraintEliminationPass())
        elseif p.level >= 1
            julia_pass!(fpm, p, "jl-alloc-opt")
            add!(fpm, sroa_modify_cfg())
            add!(fpm, MemCpyOptPass())
            add!(fpm, SCCPPass())
            add!(fpm, BDCEPass())
            add!(fpm, InstCombinePass())
            add!(fpm, ADCEPass())
        end
        if p.level >= 2
            add!(fpm, aggressive_simplifycfg(r))
            julia_pass!(fpm, p, "jl-alloc-opt")
            add!(fpm, LoopPassManager(; use_memory_ssa=true)) do lpm
                add!(lpm, LICMPass())
                add!(lpm, julia_pass(p, "jl-licm"))
            end
            add!(fpm, aggressive_simplifycfg(r))
            add!(fpm, InstCombinePass())
        elseif p.level >= 1
            add!(fpm, aggressive_simplifycfg(r))
        end
    end
    add!(fpm, "AfterScalarOptimization")
end

function vectorization!(fpm, p::JuliaPipeline, r::Recipe{14})
    add!(fpm, "BeforeVectorization")
    if p.level >= 2
        add!(fpm, Float2IntPass())
        add!(fpm, LowerConstantIntrinsicsPass())
    end
    if p.options.enable_vector_pipeline
        add!(fpm, LoopPassManager()) do lpm
            add!(lpm, LoopRotatePass())
            add!(lpm, LoopIdiomRecognizePass())
            add!(lpm, LoopDeletionPass())
        end
        add!(fpm, LoopDistributePass())
        add!(fpm, InjectTLIMappings())
        add!(fpm, LoopVectorizePass())
        add!(fpm, INFER_ALIGNMENT)
        add!(fpm, LoopLoadEliminationPass())
        add!(fpm, aggressive_simplifycfg(r))
        add!(fpm, LoopPassManager(; use_memory_ssa=true)) do lpm
            add!(lpm, LICMPass())
        end
        add!(fpm, EarlyCSEPass())
        add!(fpm, CorrelatedValuePropagationPass())
        add!(fpm, InstCombinePass())
        add!(fpm, aggressive_simplifycfg(r))
        add!(fpm, SLPVectorizerPass())
        add!(fpm, VectorCombinePass())
        add!(fpm, LoopUnrollPass(; opt_level=p.level))
        add!(fpm, sroa_preserve_cfg())
        add!(fpm, INFER_ALIGNMENT)
        add!(fpm, InstSimplifyPass())
    end
    add!(fpm, "AfterVectorization")
end

function intrinsic_lowering!(mpm, p::JuliaPipeline, r::Recipe{14})
    add!(mpm, "BeforeIntrinsicLowering")
    if p.options.lower_intrinsics
        add!(mpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-gc-invariant-verifier"; strong=false)
        end
        julia_pass!(mpm, p, "jl-remove-ni")
        add!(mpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-cancellation-lowering")
            julia_pass!(fpm, p, "jl-late-lower-gc-frame")
            julia_pass!(fpm, p, "jl-final-lower-gc")
            julia_pass!(fpm, p, "jl-expand-atomic-modify")
        end
        # Julia's `tls_getters` option can't be set, and is off
        julia_pass!(mpm, p, "jl-lower-ptls"; imaging=p.options.dump_native)
        add!(mpm, julia_pass(p, "jl-remove-addrspaces"))
        p.level >= 1 && add!(mpm, FunctionPassManager()) do fpm
            if p.level >= 2
                add!(fpm, DSEPass())
                add!(fpm, EarlyCSEPass(; memssa=true))
                add!(fpm, SCCPPass())
                add!(fpm, DCEPass())
            end
            add!(fpm, InstCombinePass())
            add!(fpm, aggressive_simplifycfg(r))
        end
    elseif !p.options.remove_ni
        julia_pass!(mpm, p, "jl-remove-ni")
    end
    add!(mpm, "AfterIntrinsicLowering")
end

function cleanup!(mpm, p::JuliaPipeline, ::Recipe{14})
    add!(mpm, "BeforeCleanup")
    if p.options.cleanup
        p.level >= 2 && add!(mpm, FunctionPassManager()) do fpm
            add!(fpm, DivRemPairsPass())
        end
        add!(mpm, FunctionPassManager()) do fpm
            add!(fpm, AnnotationRemarksPass())
        end
        # the sanitizer passes would go here; only stock builds, without them, are supported
        add!(mpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-demote-float16")
        end
    end
    add!(mpm, "AfterCleanup")
end
