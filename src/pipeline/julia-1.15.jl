# Julia 1.15's pipeline (`src/pipeline.cpp` on master at 1.15.0-DEV.818, cca11c33b7), which
# is 1.14's except for CancellationLowering, which 1.14 reverted before its release, and
# the forwarding of stores into hoisted loads before IndVarSimplify (#64810).

aggressive_simplifycfg(::Recipe{15}) = aggressive_simplifycfg(Recipe{14}())

for stage in (:early_simplification!, :early_optimization!, :scalar_optimization!,
              :vectorization!, :cleanup!)
    @eval $stage(pm, p::JuliaPipeline, ::Recipe{15}) = $stage(pm, p, Recipe{14}())
end

function loop_optimization!(fpm, p::JuliaPipeline, ::Recipe{15})
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
        if p.level >= 2
            add!(fpm, LoopPassManager()) do lpm
                add!(lpm, LoopFullUnrollPass())
            end
            # forward stores into the loads that LICM hoisted, with a fresh MemorySSA
            add!(fpm, INVALIDATE_MEMORYSSA)
            add!(fpm, EarlyCSEPass(; memssa=true))
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

function intrinsic_lowering!(mpm, p::JuliaPipeline, r::Recipe{15})
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
            add!(fpm, INFER_ALIGNMENT)
        end
    elseif !p.options.remove_ni
        julia_pass!(mpm, p, "jl-remove-ni")
    end
    add!(mpm, "AfterIntrinsicLowering")
end
