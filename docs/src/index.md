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
| `jl-alloc-opt` | `AllocOpt` | no |

Differences with Julia's C++ passes:

- Fixes from later Julia versions are applied to the IR of every version: for AllocOpt,
  the handling of write barriers that have the allocation as one of several children
  (Julia master), `julia.gc_loaded` (Julia 1.12), and null-initialized reference slots
  (Julia 1.13). The layout and initialization of stack memory follow the Julia version.
