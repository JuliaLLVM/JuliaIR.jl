module JuliaIR

using LLVM, LLVM.IR, LLVM.Build, LLVM.Passes, LLVM.Analysis
using LLVM: API, DataLayout, storage_size, abi_size, intptr

include("dialect.jl")
include("registration.jl")
include("jlopt.jl")
include("irutils.jl")

include("allocations.jl")

include("passes/remove_ni.jl")
include("passes/alloc_opt.jl")
include("passes/propagate_addrspaces.jl")
include("passes/demote_float16.jl")
include("passes/gc_invariant_verifier.jl")

function __init__()
    LEDGER[] = get(ENV, "JULIAIR_LEDGER", "")
end

end
