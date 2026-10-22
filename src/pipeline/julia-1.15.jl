# Julia 1.15's pipeline (`src/pipeline.cpp` on master at 1.15.0-DEV.77, 82e07fcb36), which
# is 1.14's: Julia 1.15 has a dialect of its own for its IR, not for its pipeline.

aggressive_simplifycfg(::Recipe{15}) = aggressive_simplifycfg(Recipe{14}())

for stage in (:early_simplification!, :early_optimization!, :loop_optimization!,
              :scalar_optimization!, :vectorization!, :intrinsic_lowering!, :cleanup!)
    @eval $stage(pm, p::JuliaPipeline, ::Recipe{15}) = $stage(pm, p, Recipe{14}())
end
