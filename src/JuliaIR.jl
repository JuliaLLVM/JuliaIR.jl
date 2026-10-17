module JuliaIR

using LLVM, LLVM.IR, LLVM.Build, LLVM.Passes, LLVM.Analysis
using LLVM: API

include("dialect.jl")
include("registration.jl")
include("jlopt.jl")

include("passes/remove_ni.jl")

function __init__()
    LEDGER[] = get(ENV, "JULIAIR_LEDGER", "")
end

end
