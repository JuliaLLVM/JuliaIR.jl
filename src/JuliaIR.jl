module JuliaIR

using LLVM, LLVM.IR, LLVM.Build, LLVM.Passes, LLVM.Analysis

include("dialect.jl")
include("registration.jl")

function __init__()
    LEDGER[] = get(ENV, "JULIAIR_LEDGER", "")
end

end
