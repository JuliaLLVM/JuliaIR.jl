# LateLowerGC cleanup

Julia's `LateLowerGCFrame` pass does two things. It places GC roots: values in Julia's
tracked address spaces that are live across a safepoint get stored in a GC frame, which
is pushed onto the task's GC stack. It also cleans up: it rewrites the GC-related
intrinsics, metadata and operand bundles that only make sense before root placement into
plain LLVM IR. Code for GPUs and other targets without Julia's runtime has no GC stack,
so only the cleanup applies to it. GPUCompiler nevertheless runs `LateLowerGCFrame` for
every target, after replacing allocations and removing write barriers itself. Some
back-ends depend on the cleanup (see the Metal example below).

`jl-late-gc-cleanup` (`JuliaIR.LateGCCleanupPass`) ports that cleanup. It is a required
function pass. It does not place roots, so it only accepts functions that need none: the
input contract below says what that means. A function that breaks the contract makes the
pass throw a [`JuliaIR.UnsupportedInputError`](@ref), which lists every offending
construct with its source location, before anything in the function is changed.

## Input contract

The input is a function in the IR dialect of the `julia` version, after the back-end's
own GC lowering (GPUCompiler's `GPULowerGCFrame` and `GPULowerPTLS`). The function must
not contain:

| Construct | Why | Who removes it |
|-----------|-----|----------------|
| `julia.gc_alloc_obj` calls | Julia's allocator and object headers | the back-end's GC lowering (GPUCompiler: calls of `gpu_gc_pool_alloc`) |
| write barriers (`julia.write_barrier`; on Julia master `julia.object_write_barrier` and `julia.field_write_barrier.p11/.p13`) | there is no generational GC | the back-end's GC lowering |
| a GC stack: a `julia.get_pgcstack` or `julia.get_pgcstack_or_new` call, or an argument with the `gcstack` attribute, even if unused | Julia's root placement pushes a frame onto it as soon as a value must be rooted | GPUCompiler's `GPULowerPTLS` removes unused `julia.get_pgcstack` calls; GPU code is compiled without `gcstack` arguments |
| `julia.typeof` calls | reads the type tag from the object header | (not supported on GPUs) |
| `julia.blackbox` calls | lowered to inline assembly for the CPU | (not supported on GPUs) |
| `gc-transition` operand bundles (Julia 1.12 and later) | GC state transitions of `ccall(...; gc_safe=true)` | (not supported on GPUs) |
| `julia.gc_alloc_ptr_offsets` and `julia.gc_alloc_zeroinit` operand bundles (Julia master) | they ask for the fields of a new object to be initialized, which the lowering of `julia.gc_alloc_obj` must do | the back-end's GC lowering |
| `invoke` or `callbr` of Julia's intrinsics, or with Julia's operand bundles | Julia only emits calls, and the rewrites only handle those | |

The function may contain the following, which the pass rewrites:

| Input | Output |
|-------|--------|
| a load through a pointer in address space 10 to 13 with `!invariant.load` | the load without `!invariant.load`: memory is only constant while the GC keeps its object alive, which is not known after GC lowering (JuliaLang/julia#32215) |
| an access with a TBAA tag (4 operands, immutable) whose type derives from `jtbaa_const` (Julia 1.10), from `jtbaa_const`, `jtbaa_memoryptr` or `jtbaa_memorylen` (1.11 to 1.13), or from `jtbaa_const` or `jtbaa_memory` (master) | the same tag without the immutability flag |
| `insertvalue undef, ...` or `insertvalue poison, ...` | `insertvalue zeroinitializer, ...` (SROA starts such chains from `undef`, and the fields of aggregates with tracked pointers must not be) |
| `llvm.julia.gc_preserve_begin`, `llvm.julia.gc_preserve_end`, `julia.gcroot_flush` calls | removed |
| `julia.pointer_from_objref(obj)` | `addrspacecast obj` |
| `julia.gc_loaded(parent, ptr)` (Julia 1.11 and later) | `addrspacecast ptr` |
| `julia.call(fptr, f, args...)`, `julia.call2(fptr, arg1, f, args...)`, `julia.call3(fptr, f, args...)` (1.11 and later) | `fptr(f, frame, nargs)` (or `fptr(f, frame, nargs, arg1)`), with `args` stored in an array (`jlcallframe`) allocated once per function, as large as the largest jlcall needs |
| a call with the `julia.gc_alloc_zeroinit_indirect(offset, size)` operand bundle (Julia master, on `jl_alloc_genericmemory_unchecked`) | the call, followed by a `memset` of `size` bytes at the data pointer stored at `offset` in the new object (nothing for a constant size of 0) |
| a call with Julia's operand bundles (`jl_roots`, ...) | the same call without them; other operand bundles are kept |

Functions with the `"thunk"` attribute are left alone, as on Julia master.

GPUCompiler's IR validator relies on the jlcall lowering: it reports dynamic calls by
finding calls of `jl_apply_generic` and `jl_invoke`, which only exist after it.

## Example: why Metal needs the cleanup

Julia passes immutable aggregates to functions by pointer and marks loads from such
arguments as constant (`!invariant.load` and an immutable `jtbaa_const` tag). That is
only true until the function is inlined into a caller that passes a stack slot: LLVM then
believes the load cannot see the caller's store, and GVN folds it to `undef`
(JuliaLang/julia#44285):

```llvm
define internal i64 @getfield(ptr addrspace(11) %agg) {
  %v = load i64, ptr addrspace(11) %agg, !tbaa !const, !invariant.load !{}
  ret i64 %v
}

define i64 @kernel(i64 %x) {
  %slot = alloca i64
  store i64 %x, ptr %slot
  %p = addrspacecast ptr %slot to ptr addrspace(11)
  %r = call i64 @getfield(ptr addrspace(11) %p)   ; inline, then GVN: ret i64 undef
  ret i64 %r
}
```

GPUCompiler's Metal back-end inlines device code after optimization, so it relies on the
cleanup having removed this metadata first. `test/lit/late-gc-cleanup.ll` checks both
outcomes.

## Differences with Julia's C++ pass

- The C++ pass also places GC roots, and lowers allocations, write barriers,
  `julia.typeof`, `julia.blackbox` and `gc-transition` bundles for Julia's runtime; the
  port rejects these (see the contract).
- Operand bundles that are not Julia's are kept. The C++ pass removes every operand
  bundle from a call that has one, including, e.g., `align` assumptions and convergence
  control tokens.
- What Julia master added is applied to the IR of every version: the
  `julia.gc_alloc_zeroinit_indirect` bundle is discharged and `"thunk"` functions are
  skipped. Neither occurs in the IR of older versions.
- The array of jlcall arguments is named `jlcallframe` for every version (Julia 1.10's
  C++ pass leaves it unnamed), and stores to it and the `memset` of
  `zeroinit_indirect` use the alignment of the data layout's pointer types instead of the
  host's pointer size.
- The C++ pass of Julia 1.12 and later declares `ijl_gc_small_alloc` in every module it
  runs on; the port does not.
