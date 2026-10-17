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
| `jl-propagate-addrspaces` | `PropagateJuliaAddrspaces` | no |
| `jl-demote-float16` | `DemoteFloat16` | yes |
| `jl-gc-invariant-verifier` | `GCInvariantVerifier` | yes |

Differences with Julia's C++ passes:

- Fixes from later Julia versions are applied to the IR of every version: for AllocOpt,
  the handling of write barriers that have the allocation as one of several children
  (Julia master), `julia.gc_loaded` (Julia 1.12), and null-initialized reference slots
  (Julia 1.13). The layout and initialization of stack memory follow the Julia version.
  For PropagateJuliaAddrspaces, lifting into the common address space of the leaves
  instead of the alloca address space (Julia master), and not walking the uses of
  constant data (Julia master).
- Bugs that no Julia version has fixed yet: PropagateJuliaAddrspaces declares
  `llvm.memset` overloaded on the type of the length (the C++ pass uses the type of the
  value, which makes the call invalid), and keeps `llvm.memset.inline` (the C++ pass
  turns it into `llvm.memset`).
- DemoteFloat16 never uses the host's CPU features (on Julia 1.10 and 1.11, the C++ pass
  falls back to them for functions without `target-features`); the `fp16` and `bf16`
  options override the Julia version's rule. It leaves alone instructions that have no
  operand to demote (the C++ pass recreates every instruction with a 16-bit result,
  dropping its name), names the replacement like the original, and runs on `optnone`
  functions (it changes their semantics, so it is a required pass).
- GCInvariantVerifier throws a `JuliaIR.GCInvariantError` listing every violation
  instead of printing them and aborting (`jlopt` prints the error and aborts, like
  `opt`). It reads the address space of vectors of pointers from their elements on
  every Julia version (the C++ pass of Julia 1.10 and 1.11 assumes scalar pointers in
  address space casts), and names `ptrtoint` violations as Julia master does.
