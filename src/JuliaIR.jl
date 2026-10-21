module JuliaIR

using LLVM, LLVM.IR, LLVM.Build, LLVM.Passes, LLVM.Analysis
import InteractiveUtils
using LLVM: API, DataLayout, bit_size, storage_size, abi_size, abi_alignment,
            preferred_alignment, offsetof, intptr

include("dialect.jl")
include("registration.jl")
include("runtime.jl")
include("jlopt.jl")
# `@main` is new in Julia 1.11
isdefined(Base, Symbol("@main")) && include("app.jl")
include("irutils.jl")
include("type_lowering.jl")

include("allocations.jl")
include("gc.jl")

include("passes/remove_ni.jl")
include("passes/alloc_opt.jl")
include("passes/propagate_addrspaces.jl")
include("passes/demote_float16.jl")
include("passes/gc_invariant_verifier.jl")
include("passes/late_lower_gc_frame.jl")
include("passes/late_gc_cleanup.jl")
include("passes/combine_muladd.jl")
include("passes/lower_exc_handlers.jl")
include("passes/lower_simdloop.jl")
include("passes/expand_atomic_modify.jl")
include("passes/cancellation_lowering.jl")
include("passes/remove_addrspaces.jl")
include("passes/final_lower_gc.jl")
include("passes/lower_ptls.jl")
include("passes/cpu_features.jl")
include("passes/multiversioning.jl")
include("passes/julia_licm.jl")

include("pipeline/pipeline.jl")
include("pipeline/julia-1.10.jl")
include("pipeline/julia-1.11.jl")
include("pipeline/julia-1.12.jl")
include("pipeline/julia-1.13.jl")
include("pipeline/julia-1.14.jl")

function __init__()
    LEDGER[] = get(ENV, "JULIAIR_LEDGER", "")
    empty!(NATIVE_FACTS)
    empty!(POOL_CLASSES)
end

end
