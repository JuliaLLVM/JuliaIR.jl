# JuliaIR.jl

Julia implementations of the LLVM passes that operate on Julia's LLVM IR dialect.

The passes are ports of the C++ passes in Julia's `src/llvm-*.cpp`, written against
[LLVM.jl](https://github.com/JuliaLLVM/LLVM.jl)'s custom-pass API.

What is supported:

- The passes process the IR that the running Julia generates: a Julia version handles
  its own version's IR, not that of an older or newer Julia. Julia 1.10 up to the current
  development version are supported.
- They work with LLVM.jl on the LLVM library that Julia bundles, and on newer LLVM
  versions (e.g. a separately built library like libLLVMGPU).
- Only IR with opaque pointers is supported.

Every pass has a `julia` option, the Julia version whose IR it processes. It defaults to
the running Julia's version and exists for testing: the package's tests run the passes on
the IR of every Julia version, on any Julia. Facts about Julia's runtime that some passes
need (see below) are taken from the running Julia; IR for GPUs doesn't need them.

| Pass | Julia's name | Required |
|------|--------------|----------|
| `jl-remove-ni` | `RemoveNI` | yes |
| `jl-alloc-opt` | `AllocOpt` | no |
| `jl-propagate-addrspaces` | `PropagateJuliaAddrspaces` | no |
| `jl-demote-float16` | `DemoteFloat16` | yes |
| `jl-gc-invariant-verifier` | `GCInvariantVerifier` | yes |
| `jl-combine-muladd` | `CombineMulAdd` (Julia 1.10 and 1.11) | no |
| `jl-late-gc-cleanup` | `LateLowerGCFrame` (the cleanup, for functions without a GC frame) | yes |
| `jl-lower-exc-handlers` | `LowerExcHandlers` (Julia 1.10 to 1.12) | yes |

## Passes that exist in some Julia versions only

A pass that Julia doesn't have in some versions does nothing on the IR of those
versions: LowerExcHandlers only exists in Julia 1.10 to 1.12 (later versions emit
exception handlers directly), so `jl-lower-exc-handlers` leaves the IR of Julia 1.13 and
later alone, and CombineMulAdd only in Julia 1.10 and 1.11.

## Facts about the Julia runtime

Some passes need facts that the IR doesn't state, about the build of the Julia runtime
the code will run with: LowerExcHandlers allocates stack buffers of the size of the
runtime's exception handler (`jl_handler_t`, which contains a `jmp_buf` and so depends on
the OS, the C library and the architecture) and calls the runtime's `setjmp` (whose name
and signature depend on the OS). A triple doesn't determine them. These passes take them
as options, as a [`JuliaIR.RuntimeProfile`](@ref):

- explicitly, e.g. `jl-lower-exc-handlers<handler-size=264;handler-align=16;setjmp=__sigsetjmp>`
  (the values of Julia 1.12 on x86-64 Linux with glibc);
- or from the running Julia, for a module whose target triple is the host's, and with
  `runtime=native` also for a module without a triple. This is only possible for the
  running Julia's own dialect: the facts of an older Julia are never taken from a newer
  one, nor those of the host for another target. `jlopt`, which stands in for `opt` with
  the running Julia's passes loaded, uses `runtime=native` by default.

The running Julia's values aren't exported by its runtime, so they are read from what
Julia's own LowerExcHandlers emits for a small probe function. Passes only ask for these
facts when they need them, i.e. when a function has exception handlers, and throw a
[`JuliaIR.RuntimeError`](@ref) when they are unknown.

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
- CombineMulAdd only exists in Julia 1.10 and 1.11; for the IR of later versions it does
  nothing.
- LowerExcHandlers declares the runtime functions and lifetime intrinsics only in
  modules where it lowers handlers (the C++ pass declares them, and reports a change, for
  every function of a module that declares `julia.except_enter`, which also lets the
  port process modules without handlers without knowing the runtime). Leaving more
  handlers than were entered, or a non-constant number of them, is rejected with a
  `JuliaIR.HandlerNestingError` (undefined behaviour in the C++ pass). On LLVM 22 and
  later, the lifetime markers take only the pointer.
- LateGCCleanup only ports the part of `LateLowerGCFrame` that applies to functions
  without a GC frame, and rejects the others; see [LateLowerGC cleanup](@ref) for its
  input contract and its other differences. Unlike the other ports, `jlopt` does not map
  Julia's pass name to it.
