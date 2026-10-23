# Julia 1.15's pipeline (`src/pipeline.cpp` on master at 1.15.0-DEV.90, fc70f5aed4), which
# is 1.14's except for the alignment inference after the intrinsic lowering (#64020).

aggressive_simplifycfg(::Recipe{15}) = aggressive_simplifycfg(Recipe{14}())

for stage in (:early_simplification!, :early_optimization!, :loop_optimization!,
              :scalar_optimization!, :vectorization!, :cleanup!)
    @eval $stage(pm, p::JuliaPipeline, ::Recipe{15}) = $stage(pm, p, Recipe{14}())
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
