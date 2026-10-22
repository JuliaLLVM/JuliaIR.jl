# JuliaIR.jl

JuliaIR.jl provides Julia implementations of the LLVM passes that operate on *Julia's
LLVM IR dialect*: the IR that Julia's code generator emits, with GC-tracked pointers in
address spaces 10 to 13, intrinsics like `julia.gc_alloc_obj` and
`julia.gc_preserve_begin`, and Julia-specific metadata and operand bundles. "IR" in the
package name refers to that dialect, not to Julia's own SSA IR.

The passes are ports of the C++ passes in Julia's `src/llvm-*.cpp` (and of the pipeline
in `src/pipeline.cpp` that runs them), written against
[LLVM.jl](https://github.com/JuliaLLVM/LLVM.jl)'s custom-pass API.

## Why

Julia's own passes are compiled into Julia's copy of libLLVM, so they only exist in that
library. Code that processes Julia's IR with another LLVM can't use them. The main case is
GPUCompiler, which can load a standalone, newer libLLVM next to Julia's (e.g. to target a
GPU that Julia's LLVM doesn't support yet), and still has to lower Julia's GC intrinsics,
address spaces and so on before handing the IR to the back-end. The ports run on any
LLVM library that LLVM.jl can load, so they work in either configuration, and they behave
like the C++ passes of the Julia version that produced the IR.

## What is supported

- **The IR of the running Julia.** The passes process the IR that the running Julia
  generates: Julia 1.12 processes Julia 1.12's IR, not that of an older or newer Julia.
  Julia 1.10 up to the current development version (1.15) are supported. What the IR of
  each Julia version looks like is described by its *dialect*, `JuliaIR.Dialect`, and the
  passes use the running Julia's (`JuliaIR.Dialect(VERSION)`).
- **Julia's LLVM, or a newer one.** The passes work with LLVM.jl on the LLVM library that
  Julia bundles, and on newer LLVM versions (e.g. a separately built library like
  libLLVMGPU). They are tested on both: on the LLVM of each supported Julia version, and
  with each version's IR on the newest LLVM (a standalone LLVM 23).
- **Opaque pointers only.** Julia 1.10 emits typed pointers by default; its IR is
  supported when parsed into a context with opaque pointers
  (`Context(; opaque_pointers=true)`), which upgrades it.

JuliaIR.jl is not registered yet. It needs LLVM.jl 10.4 or later.

## Using the passes

Each pass is an LLVM.jl custom pass named after Julia's pass with a `jl-` prefix (see
[the table below](#Passes)), so that it never clashes with Julia's C++ pass, which is also
available when running on Julia's LLVM. Register them with a pass builder and use them by
name, optionally with options:

```julia
using LLVM, LLVM.IR, LLVM.Passes, JuliaIR

@dispose ctx=Context(; opaque_pointers=true) pb=PassBuilder() begin
    mod = parse(LLVM.Module, ir)
    JuliaIR.register!(pb)
    add!(pb, "jl-alloc-opt,jl-late-lower-gc-frame,jl-final-lower-gc")
    run!(pb, mod)
end
```

or run a single pass: `run!(JuliaIR.RemoveNIPass(), mod)`. Julia's whole optimization
pipeline, rebuilt from the ports for the running Julia's version, is available too (see
[Julia's optimization pipeline](pipeline.md)):

```julia
JuliaIR.optimize!(mod; level=2)           # optimize a module like Julia does
JuliaIR.build_pipeline!(pb; level=2)      # or add the pipeline to a PassBuilder
```

To use another LLVM library next to Julia's, e.g. a standalone build of a newer LLVM,
register it with LLVM.jl and select it for the whole transformation, by creating the
context with it:

```julia
lib = LLVM.register_library!(:other, "/path/to/libLLVM-standalone.so")
Context(; library=lib, opaque_pointers=true) do ctx
    @dispose mod=parse(LLVM.Module, ir) begin
        run!(JuliaIR.RemoveNIPass(), mod)
    end
end
```

For an existing context, `context!(ctx) do ... end` selects it and its library. The passes
look up intrinsics and decide what depends on the LLVM version in the library they run
with, not in the one the package was loaded with.

From the command line, `jlopt` is an `opt`-compatible driver that runs the ports, and
maps Julia's pass names (`-passes=AllocOpt`, `-passes='julia<level=2>'`) to them; see
[`jlopt`](testing.md#jlopt) for how to run or install it.

GPUCompiler uses the ports instead of Julia's C++ passes when its `CompilerConfig` has
`julia_passes = :ports` (or GPUCompiler's `julia_passes` preference is `"ports"`) and
JuliaIR.jl is loaded; the compilation then needs a context with opaque pointers, which
GPUCompiler's `JuliaContext()` creates for that setting. This
is not merged in GPUCompiler yet (JuliaGPU/GPUCompiler.jl#1026).

## Terms

- *Port*: the Julia implementation of one of Julia's C++ passes, e.g. `jl-alloc-opt` for
  `AllocOpt`. A port does what the C++ pass of the running Julia's version does, except
  for the deviations listed on this page and on the passes' own pages.
- *Dialect*: what the IR of a Julia version looks like, and which passes and behaviours
  that version has (`JuliaIR.Dialect`). A pass's options cover what the version doesn't
  determine, like DemoteFloat16's `fp16` and `bf16` policies or the GC write-barrier
  configuration Julia was built with (`gc-barrier`).
- *Required*: a required pass also runs on `optnone` functions, which LLVM's pass
  managers skip for the others. Each port is required exactly when Julia's C++ pass is.
- *Runtime facts*: facts about the Julia runtime that the IR doesn't state, like the
  offset of a field in the current task, which some passes need (see
  [below](#Facts-about-the-Julia-runtime)). IR for GPUs doesn't need them.

## Passes

| Pass | Julia's name | Required |
|------|--------------|----------|
| `jl-remove-ni` | `RemoveNI` | yes |
| `jl-alloc-opt` | `AllocOpt` | no |
| `jl-propagate-addrspaces` | `PropagateJuliaAddrspaces` | yes |
| `jl-demote-float16` | `DemoteFloat16` | yes |
| `jl-gc-invariant-verifier` | `GCInvariantVerifier` | yes |
| `jl-combine-muladd` | `CombineMulAdd` (Julia 1.10 and 1.11) | no |
| `jl-late-lower-gc-frame` | `LateLowerGCFrame` | yes |
| `jl-final-lower-gc` | `FinalLowerGC` (a module pass on Julia 1.10, a function pass later, see [FinalLowerGC](final_lower_gc.md)) | yes |
| `jl-late-gc-cleanup` | (`LateLowerGCFrame` on functions without a GC frame, for GPUs) | yes |
| `jl-lower-exc-handlers` | `LowerExcHandlers` (Julia 1.10 to 1.12) | yes |
| `jl-lower-simdloop` | `LowerSIMDLoop` (a loop pass) | no |
| `jl-licm` | `JuliaLICM` (a loop pass, see [JuliaLICM](julia_licm.md)) | no |
| `jl-lower-ptls` | `LowerPTLSPass` (a module pass, see [LowerPTLS](lower_ptls.md)) | yes |
| `jl-expand-atomic-modify` | `ExpandAtomicModify` (Julia 1.13 and later) | no |
| `jl-cancellation-lowering` | `CancellationLowering` (Julia 1.14 and later) | yes |
| `jl-remove-addrspaces` | `RemoveJuliaAddrspaces` | yes |
| `jl-remove-all-addrspaces` | `RemoveAddrspaces` | yes |
| `jl-cpu-features` | `CPUFeatures` | yes |
| `jl-multiversioning` | `JuliaMultiVersioning` (a module pass, see [JuliaMultiVersioning](multiversioning.md)) | yes |

## Passes that exist in some Julia versions only

A pass that Julia doesn't have in some versions does nothing on the IR of those
versions: LowerExcHandlers only exists in Julia 1.10 to 1.12 (later versions emit
exception handlers directly), so `jl-lower-exc-handlers` leaves the IR of Julia 1.13 and
later alone, and CombineMulAdd only in Julia 1.10 and 1.11. ExpandAtomicModify only
exists from Julia 1.13 on, whose code generator emits the `julia.atomicmodify` calls it
lowers; for the IR of earlier versions, `jl-expand-atomic-modify` does nothing. Likewise,
CancellationLowering only exists from Julia 1.14 on, whose code generator emits the
`julia.cancellation_point` calls it lowers.

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

Besides the passes, JuliaIR.jl ports how Julia's code generator lowers Julia types to LLVM
types, for code that builds Julia's IR in contexts of another LLVM library; see
[Type lowering](type_lowering.md).

Differences with Julia's C++ passes:

- Fixes from later Julia versions are applied to the IR of every version: for AllocOpt,
  the handling of write barriers that have the allocation as one of several children
  (Julia 1.14), `julia.gc_loaded` (Julia 1.12), and null-initialized reference slots
  (Julia 1.13), and Julia 1.13's escape analysis: fields that don't overlap are not
  merged (JuliaLang/julia#62166), allocations with references can be split or moved to
  the stack (#61131), a field accessed by a `cmpxchg` or `atomicrmw` counts as read
  (#62752; without it, the C++ pass can crash), and storing the allocation's address
  with one is an escape (#61131). Like 1.13's, the port also makes the `cmpxchg` and
  `atomicrmw` it moves to the slots of a split allocation non-atomic. So for 1.10 to
  1.12 IR the port removes or splits allocations that the C++ pass of those versions
  keeps. The layout and initialization of stack memory follow the Julia version.
  For PropagateJuliaAddrspaces, lifting into the common address space of the leaves
  instead of the alloca address space (Julia 1.14), and not walking the uses of
  constant data (Julia 1.14).
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
- DemoteFloat16's `fp16` and `bf16` options override the Julia version's rule, and its
  `jit_features=false` option ignores the JIT's features for functions without
  `target-features` (Julia 1.10, 1.11), like the C++ pass in `opt`. It leaves alone
  instructions that have no operand to demote (the C++ pass recreates every instruction
  with a 16-bit result, dropping its name), and names the replacement like the original.
- GCInvariantVerifier throws a `JuliaIR.GCInvariantError` listing every violation
  instead of printing them and aborting (`jlopt` prints the error and aborts, like
  `opt`). It reads the address space of vectors of pointers from their elements on
  every Julia version (the C++ pass of Julia 1.10 and 1.11 assumes scalar pointers in
  address space casts), and names `ptrtoint` violations as Julia 1.14 does.
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
  (Julia 1.14): older versions create a uniqued node and then make it refer to itself,
  which also changes every other use of an identical node, e.g. `!{null}`, the type
  array of a subroutine type, when the loop ID has no other operands. The remark about
  a loop's flags is attached to the header's terminator (with the location of the start
  of the loop) instead of the header block.
- CPUFeatures throws a `JuliaIR.CPUFeaturesError` for uses of its intrinsics it can't
  fold (not called, passed as an argument, called with `invoke`), where the C++ pass
  crashes or corrupts the IR. Up to Julia 1.13, it reads the JIT's answers from the code
  Julia generates for `have_fma` rather than from the JIT's feature string; from Julia
  1.14 on, its `target_cpu` and `target_features` options create a subtarget without a
  target machine. See [CPUFeatures](cpu_features.md).
- ExpandAtomicModify places the `atomicrmw xchg` that replaces an operation that ignores
  the old value after the inlined code that computes the new one, for the IR of every
  Julia version (Julia 1.14): Julia 1.13 places it before that code, which is invalid
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
- CancellationLowering reports the control-flow graph as changed when it splits blocks,
  rejects cancellation points it can't lower, and uses the data layout's pointer
  alignment; see [CancellationLowering](@ref).
- RemoveJuliaAddrspaces and RemoveAddrspaces keep the compile units for every Julia
  version (Julia 1.13 added this) and the debug info of global variables consistent with
  them, map the metadata of global variables after the rest, and keep the
  metadata of global variable declarations, the types of `inalloca` and `preallocated`
  attributes, and indirect functions, which the C++ passes drop, leave unmapped or
  corrupt; see [RemoveJuliaAddrspaces](@ref).
- FinalLowerGC, LowerPTLS, JuliaLICM and JuliaMultiVersioning record their differences on
  their own pages: [FinalLowerGC](final_lower_gc.md), [LowerPTLS](lower_ptls.md),
  [JuliaLICM](julia_licm.md) and [JuliaMultiVersioning](multiversioning.md).
