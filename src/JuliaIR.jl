module JuliaIR

using LLVM, LLVM.IR, LLVM.Build, LLVM.Passes, LLVM.Analysis
import InteractiveUtils
using LLVM: API, DataLayout, storage_size, abi_size, abi_alignment, intptr

include("dialect.jl")
include("registration.jl")
include("runtime.jl")
include("jlopt.jl")
include("irutils.jl")
include("codegen_shared.jl")
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
include("gc_transitions.jl")
include("passes/lower_ptls.jl")
include("passes/cpu_features.jl")

function __init__()
    LEDGER[] = get(ENV, "JULIAIR_LEDGER", "")
    empty!(NATIVE_FACTS)
    empty!(POOL_CLASSES)
end

end
