# Julia 1.11's pipeline (`src/pipeline.cpp` at v1.11.9).

aggressive_simplifycfg(::Recipe{11}) =
    SimplifyCFGPass(; forward_switch_cond=true, switch_range_to_icmp=true,
                    switch_to_lookup=true, hoist_common_insts=true)

function early_simplification!(mpm, p::JuliaPipeline, ::Recipe{11})
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
            p.level >= 1 && add!(fpm, sroa_preserve_cfg())
        end
    end
    add!(mpm, "AfterEarlySimplification")
end

function early_optimization!(mpm, p::JuliaPipeline, r::Recipe{11})
    add!(mpm, "BeforeEarlyOptimization")
    if p.options.enable_early_optimizations
        # an empty CGSCC pass manager (below level 2) can't be written as pipeline text
        add!(mpm, CGSCCPassManager()) do cgpm
            p.level >= 2 && add!(cgpm, FunctionPassManager()) do fpm
                julia_pass!(fpm, p, "jl-alloc-opt")
                add!(fpm, Float2IntPass())
                add!(fpm, LowerConstantIntrinsicsPass())
            end
        end
        p.level >= 2 && add!(mpm, REQUIRE_GLOBALS_AA)
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
        add!(mpm, GlobalDCEPass())
    end
    add!(mpm, "AfterEarlyOptimization")
end

function loop_optimization!(fpm, p::JuliaPipeline, ::Recipe{11})
    add!(fpm, "BeforeLoopOptimization")
    if p.options.enable_loop_optimizations
        add!(fpm, LoopPassManager()) do lpm
            add!(lpm, julia_pass(p, "jl-lower-simdloop"))
            p.level >= 2 && add!(lpm, LoopRotatePass())
        end
        p.level >= 2 && add!(fpm, LoopPassManager(; use_memory_ssa=true)) do lpm
            add!(lpm, "BeforeLICM")
            add!(lpm, LICMPass())
            add!(lpm, julia_pass(p, "jl-licm"))
            add!(lpm, SimpleLoopUnswitchPass(; nontrivial=true, trivial=true))
            add!(lpm, LICMPass())
            add!(lpm, julia_pass(p, "jl-licm"))
            add!(lpm, "AfterLICM")
        end
        p.level >= 2 && add!(fpm, IRCEPass())
        add!(fpm, LoopPassManager()) do lpm
            add!(lpm, "BeforeLoopSimplification")
            if p.level >= 2
                add!(lpm, LoopInstSimplifyPass())
                add!(lpm, LoopIdiomRecognizePass())
                add!(lpm, IndVarSimplifyPass())
                add!(lpm, LoopDeletionPass())
                add!(lpm, LoopFullUnrollPass())
            end
            add!(lpm, "AfterLoopSimplification")
        end
    end
    add!(fpm, "AfterLoopOptimization")
end

function scalar_optimization!(fpm, p::JuliaPipeline, r::Recipe{11})
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
        elseif p.level >= 1
            julia_pass!(fpm, p, "jl-alloc-opt")
            add!(fpm, sroa_modify_cfg())
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
    end
    add!(fpm, "AfterScalarOptimization")
end

function vectorization!(fpm, p::JuliaPipeline, r::Recipe{11})
    add!(fpm, "BeforeVectorization")
    if p.options.enable_vector_pipeline
        add!(fpm, InjectTLIMappings())
        add!(fpm, LoopVectorizePass())
        add!(fpm, LoopLoadEliminationPass())
        add!(fpm, InstCombinePass())
        add!(fpm, aggressive_simplifycfg(r))
        add!(fpm, SLPVectorizerPass())
        add!(fpm, VectorCombinePass())
        add!(fpm, ADCEPass())
        add!(fpm, LoopUnrollPass(; opt_level=p.level))
    end
    add!(fpm, "AfterVectorization")
end

function intrinsic_lowering!(mpm, p::JuliaPipeline, r::Recipe{11})
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

function cleanup!(mpm, p::JuliaPipeline, ::Recipe{11})
    add!(mpm, "BeforeCleanup")
    if p.options.cleanup
        p.level >= 2 && add!(mpm, FunctionPassManager()) do fpm
            julia_pass!(fpm, p, "jl-combine-muladd")
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
