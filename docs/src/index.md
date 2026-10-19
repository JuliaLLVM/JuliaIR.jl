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

What the IR of each Julia version looks like is described by `JuliaIR.Dialect`, and the
passes use the running Julia's (`JuliaIR.Dialect(VERSION)`). Their options cover what
the version doesn't determine, like DemoteFloat16's `fp16` and `bf16` policies or the
GC write-barrier configuration Julia was built with (`gc-barrier`). Facts about Julia's
runtime that some passes need (see below) are taken from the running Julia too; IR for
GPUs doesn't need them.

A required pass also runs on `optnone` functions, which LLVM's pass managers skip for
the others; each port is required exactly when Julia's C++ pass is.

| Pass | Julia's name | Required |
|------|--------------|----------|
| `jl-remove-ni` | `RemoveNI` | yes |
| `jl-alloc-opt` | `AllocOpt` | no |
| `jl-propagate-addrspaces` | `PropagateJuliaAddrspaces` | yes |
| `jl-demote-float16` | `DemoteFloat16` | yes |
| `jl-gc-invariant-verifier` | `GCInvariantVerifier` | yes |
| `jl-combine-muladd` | `CombineMulAdd` (Julia 1.10 and 1.11) | no |
| `jl-late-lower-gc-frame` | `LateLowerGCFrame` | yes |
| `jl-late-gc-cleanup` | (`LateLowerGCFrame` on functions without a GC frame, for GPUs) | yes |
| `jl-lower-exc-handlers` | `LowerExcHandlers` (Julia 1.10 to 1.12) | yes |
| `jl-lower-simdloop` | `LowerSIMDLoop` (a loop pass) | no |
| `jl-expand-atomic-modify` | `ExpandAtomicModify` (Julia 1.13 and later) | no |

## Passes that exist in some Julia versions only

A pass that Julia doesn't have in some versions does nothing on the IR of those
versions: LowerExcHandlers only exists in Julia 1.10 to 1.12 (later versions emit
exception handlers directly), so `jl-lower-exc-handlers` leaves the IR of Julia 1.13 and
later alone, and CombineMulAdd only in Julia 1.10 and 1.11. ExpandAtomicModify only
exists from Julia 1.13 on, whose code generator emits the `julia.atomicmodify` calls it
lowers; for the IR of earlier versions, `jl-expand-atomic-modify` does nothing.

## Facts about the Julia runtime

Some passes need facts that the IR doesn't state, about the Julia runtime the code will
run with: LowerExcHandlers allocates stack buffers of the size of the runtime's exception
handler (`jl_handler_t`, which contains the C library's `jmp_buf`) and calls the
runtime's `setjmp`, whose name depends on the OS; LateLowerGCFrame lowers allocations
and GC state transitions with the offsets of the thread-local state in the task and of
the safepoint page and GC state in it. Like Julia's own passes, the ports take these
facts from the running Julia, or from pass options that give them explicitly; what the
C++ passes derive from the module, like whether `setjmp` takes a `savemask` argument
(not for a Windows triple), the ports derive from it too. See
[Runtime facts](runtime.md) for what these facts are and how they are read.

Differences with Julia's C++ passes:

- Fixes from later Julia versions are applied to the IR of every version: for AllocOpt,
  the handling of write barriers that have the allocation as one of several children
  (Julia master), `julia.gc_loaded` (Julia 1.12), and null-initialized reference slots
  (Julia 1.13). The layout and initialization of stack memory follow the Julia version.
  For PropagateJuliaAddrspaces, lifting into the common address space of the leaves
  instead of the alloca address space (Julia master), and not walking the uses of
  constant data (Julia master).
- AllocOpt takes the size and alignment of the reference slots of split allocations
  from the module's data layout (the store size and ABI alignment of a pointer in
  address space 10), where the C++ pass uses the host's pointer size. For IR that Julia
  generates for its own host the result is the same; for IR of a target with another
  pointer size (e.g. a 32-bit target processed by a 64-bit Julia) the port is correct
  where the C++ pass is not.
- Bugs that no Julia version has fixed yet: PropagateJuliaAddrspaces declares
  `llvm.memset` overloaded on the type of the length (the C++ pass uses the type of the
  value, which makes the call invalid), and keeps `llvm.memset.inline` (the C++ pass
  turns it into `llvm.memset`).
- DemoteFloat16 never uses the host's CPU features (on Julia 1.10 and 1.11, the C++ pass
  falls back to them for functions without `target-features`); the `fp16` and `bf16`
  options override the Julia version's rule. It leaves alone instructions that have no
  operand to demote (the C++ pass recreates every instruction with a 16-bit result,
  dropping its name), and names the replacement like the original.
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
- LowerSIMDLoop makes the loop ID it creates distinct, for the IR of every Julia version
  (Julia master): older versions create a uniqued node and then make it refer to itself,
  which also changes every other use of an identical node, e.g. `!{null}`, the type
  array of a subroutine type, when the loop ID has no other operands. The remark about
  a loop's flags is attached to the header's terminator (with the location of the start
  of the loop) instead of the header block.
- ExpandAtomicModify places the `atomicrmw xchg` that replaces an operation that ignores
  the old value after the inlined code that computes the new one, for the IR of every
  Julia version (Julia master): Julia 1.13 places it before that code, which is invalid
  IR. Where the C++ pass crashes or emits invalid IR, the port throws a
  `JuliaIR.AtomicModifyError` instead: for values other than integers, floating-point
  numbers and pointers, a non-constant ordering, a compare-exchange loop for a pointer
  without alignment, an operation that returns the old value unchanged for a
  non-integer value (the C++ pass emits `atomicrmw or` on it), and an operation that
  inlining turned into something `atomicrmw` doesn't support (e.g., `fadd` inlined into
  a `strictfp` function becomes a constrained intrinsic). It positions new instructions
  relative to the `julia.atomicmodify` call, also after inlining a modify function with
  several blocks (the C++ pass keeps inserting into the block that the call was in
  before inlining split it, which corrupts the function; it doesn't terminate on such
  input). Like the C++ pass, it is not required, so it is skipped on
  `optnone` functions, whose `julia.atomicmodify` calls then remain.
- LateLowerGCFrame keeps operand bundles that are not Julia's, accesses the GC state
  byte with a valid alignment, and orders the frame slots of allocas deterministically;
  see [LateLowerGCFrame](@ref) for these and the fixes of later Julia versions it applies.
  `jl-late-gc-cleanup` runs it on functions without a GC frame after checking an input
  contract (on the same page); `jlopt` does not map Julia's pass name to it.
