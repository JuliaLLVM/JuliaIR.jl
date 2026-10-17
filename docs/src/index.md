# JuliaIR.jl

Julia implementations of the LLVM passes that operate on Julia's LLVM IR dialect.

The passes are ports of the C++ passes in Julia's `src/llvm-*.cpp`, written against
[LLVM.jl](https://github.com/JuliaLLVM/LLVM.jl)'s custom-pass API. They take the Julia
version whose IR they process as an option (`julia`, defaulting to the running Julia's
version), so that they can process the IR of any Julia version from 1.10 on, on any LLVM
library supported by LLVM.jl. Only IR with opaque pointers is supported.

| Pass | Julia's name | Required |
|------|--------------|----------|
| `jl-remove-ni` | `RemoveNI` | yes |
