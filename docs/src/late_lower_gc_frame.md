# LateLowerGCFrame

Julia's `LateLowerGCFrame` pass makes the garbage collector's roots explicit. Julia's code
generator keeps objects in tracked pointers (address space 10) and pointers derived from
them (11 to 13), and leaves it to this pass to make sure that every object that is still
needed at a *safepoint* (a call that may run the GC) is in a GC frame, an array of roots
that the function pushes onto its task's GC stack. The pass

1. scans each function for the definitions and uses of tracked values and for the
   safepoints (calls that may allocate or otherwise reach the GC), numbering every
   tracked value, and lifting `select`s and `phi`s of derived pointers to selects and phis
   of their base objects;
2. computes which values are live at each safepoint, and leaves out the ones kept alive
   by other live values (a value loaded from immutable memory of a live object, a
   constant, an argument);
3. colours the values that are live at the same safepoints with different frame slots;
4. creates the frame (`julia.new_gc_frame`, `julia.push_gc_frame`, `julia.pop_gc_frame`),
   stores the values to their slots before the safepoints they need to survive, and
   moves allocas of tracked pointers into the frame (`julia.get_gc_frame_slot`);
5. cleans up: lowers allocations (`julia.gc_alloc_obj` to `julia.gc_alloc_bytes` and a
   store of the type tag), `julia.typeof`, write barriers, jlcalls (`julia.call*`),
   calls with a `gc-transition` bundle (switching the thread to the GC-safe state around
   them), `julia.pointer_from_objref` and `julia.gc_loaded`, and removes the metadata,
   intrinsics and operand bundles that only hold before this pass.

`FinalLowerGC` (not ported yet) then lowers the frame intrinsics and
`julia.gc_alloc_bytes` to Julia's runtime.

`jl-late-lower-gc-frame` (`JuliaIR.LateLowerGCFramePass`) ports the pass for the IR of
every Julia version from 1.10 on, and `jlopt` runs it for Julia's name of the pass
(`LateLowerGCFrame`). It is a required function pass. The code keeps the names and the
structure of the C++ (`local_scan` for `LocalScan`, `compute_liveness!` for
`ComputeLiveness`, `color_roots` for `ColorRoots`, `place_roots_and_update_calls!` for
`PlaceRootsAndUpdateCalls`, `cleanup_ir!` for `CleanupIR`, ...), so that both can be read
side by side.

`jl-late-gc-cleanup` (`JuliaIR.LateGCCleanupPass`) runs the same code on functions
without a GC frame, as GPU back-ends emit them, after checking an input contract (see
[below](#The-GPU-cleanup:-jl-late-gc-cleanup)).

## What changes between Julia versions

The pass follows the C++ pass of the running Julia's version. The differences between
versions are fields of `JuliaIR.Dialect`:

| Behaviour | 1.10 | 1.11 | 1.12 | 1.13 | master |
|-----------|------|------|------|------|--------|
| loads that are rooted by the object they load from | `!invariant.load`, or TBAA of `jtbaa_immut`, `jtbaa_const`, `jtbaa_datatype` | same, and `jtbaa_memoryptr`, `jtbaa_memorylen`, `jtbaa_memoryown` | same | same | `!invariant.load`, or `!alias.scope` in a `jnoalias` region that is never overwritten |
| loads through an argument (jlcall argument arrays) rooted by the caller | yes | yes | yes | no | no |
| no frame without a safepoint after the first definition | no | no | no | yes | yes |
| roots returned in memory | `sret` arguments and the alloca passed after them | same | same | same | `julia.return_roots` argument attributes |
| frame slots reset to null when their value dies | no | no | yes | yes | yes |
| null stores to rooted allocas in the prologue removed | no | no | yes | yes | yes |
| allocas of single tracked pointers placed first | yes | yes | no | no | no |
| GC stack in a `gcstack` argument | no | no | no | yes | yes |
| names (`jlcallframe`, `gc_slot_addr`, `.tag_addr`, `.tag`), volatile tag loads | no | yes | yes | yes | yes |
| `julia.gc_alloc_bytes(ptls, size)` with the tag and allocation attributes | no | yes | yes | yes | yes |
| extractions simplified (`InstSimplifyFolder`) | no | no | yes | yes | yes |
| task-local state addressed in pointers or bytes | pointers | pointers | bytes | bytes | bytes |
| write barriers | lowered | lowered, named at debug level 2 | lowered, named | lowered, also queuing image objects | elided when unnecessary, otherwise left to FinalLowerGC |
| `gc-transition` bundles | dropped | dropped | lowered through the GC stack's task | lowered through the bundle's state | same |
| `ijl_gc_small_alloc` declared | no | no | yes | yes | yes |

On Julia master, the `gc_barrier` policy of the dialect selects the write-barrier build
configuration: with `:snapshot` (or `:snapshot_field_precise`), barriers are never
elided. Builds with MMTk are not supported.

## Julia's runtime

Lowering allocations and GC state transitions needs the layout of Julia's runtime
structures: where a task keeps its thread-local state (`task_ptls`, and `task_gcstack`
for Julia 1.12's transitions), and where that state keeps the safepoint page
(`tls_safepoint`) and the GC state (`tls_gc_state`). The pass takes them from the
running Julia (see [Runtime facts](runtime.md)), only for functions that need them (the
GPU cleanup never does), or from the pass options of the same names (`task-ptls=168`,
...), which override them. Like the C++ pass, which compiles them in, it uses them
whatever the module's target is.

## The GPU cleanup: `jl-late-gc-cleanup`

Code for GPUs and other targets without Julia's runtime has no GC stack, so only the
cleanup applies to it. GPUCompiler runs `LateLowerGCFrame` for every target, after
replacing allocations and removing write barriers itself, and some back-ends depend on
the cleanup (see the Metal example below). `jl-late-gc-cleanup` checks that a function
only contains what the cleanup handles without Julia's runtime and then runs the general
pass on it; a function that breaks the contract makes it throw a
`JuliaIR.UnsupportedInputError`, which lists every offending construct with its source
location, before anything in the function is changed. Functions that the general pass
skips (thunks) are checked too.

### Input contract

The input is a function in the IR dialect of the running Julia, after the back-end's
own GC lowering (GPUCompiler's `GPULowerGCFrame` and `GPULowerPTLS`). The function must
not contain:

| Construct | Why | Who removes it |
|-----------|-----|----------------|
| `julia.gc_alloc_obj` calls | Julia's allocator and object headers | the back-end's GC lowering (GPUCompiler: calls of `gpu_gc_pool_alloc`) |
| write barriers (`julia.write_barrier`; on Julia master `julia.object_write_barrier` and `julia.field_write_barrier.p11/.p13`) | there is no generational GC | the back-end's GC lowering |
| a GC stack: a `julia.get_pgcstack` or `julia.get_pgcstack_or_new` call, or an argument with the `gcstack` attribute, even if unused | Julia's root placement pushes a frame onto it as soon as a value must be rooted | GPUCompiler's `GPULowerPTLS` removes unused `julia.get_pgcstack` calls; GPU code is compiled without `gcstack` arguments |
| `julia.typeof` calls | reads the type tag from the object header | (not supported on GPUs) |
| `julia.blackbox` calls | lowered to inline assembly for the CPU | (not supported on GPUs) |
| GC frame intrinsics and `julia.gc_alloc_bytes`, `julia.queue_gc_root` | created by `LateLowerGCFrame` for Julia's runtime, lowered by `FinalLowerGC` | |
| `gc-transition` operand bundles (Julia 1.12 and later) | GC state transitions of `ccall(...; gc_safe=true)` | (not supported on GPUs) |
| `julia.gc_alloc_ptr_offsets` and `julia.gc_alloc_zeroinit` operand bundles (Julia master) | they ask for the fields of a new object to be initialized, which the lowering of `julia.gc_alloc_obj` must do | the back-end's GC lowering |
| `invoke` or `callbr` of Julia's intrinsics, or with Julia's operand bundles | Julia only emits calls, and the pass only lowers those | |

The function may contain the following, which the pass rewrites:

| Input | Output |
|-------|--------|
| a load through a pointer in address space 10 to 13 with `!invariant.load` | the load without `!invariant.load`: memory is only constant while the GC keeps its object alive, which is not known after GC lowering (JuliaLang/julia#32215) |
| an access with a TBAA tag (4 operands, immutable) whose type derives from `jtbaa_const` (Julia 1.10), from `jtbaa_const`, `jtbaa_memoryptr` or `jtbaa_memorylen` (1.11 to 1.13), or from `jtbaa_const` or `jtbaa_memory` (master) | the same tag without the immutability flag |
| `insertvalue undef, ...` or `insertvalue poison, ...` | `insertvalue zeroinitializer, ...` (SROA starts such chains from `undef`, and the fields of aggregates with tracked pointers must not be) |
| `llvm.julia.gc_preserve_begin`, `llvm.julia.gc_preserve_end`, `julia.gcroot_flush` calls | removed |
| `julia.pointer_from_objref(obj)` | `addrspacecast obj` |
| `julia.gc_loaded(parent, ptr)` (Julia 1.11 and later) | `addrspacecast ptr` |
| `julia.call(fptr, f, args...)`, `julia.call2(fptr, arg1, f, args...)`, `julia.call3(fptr, f, args...)` (1.11 and later) | `fptr(f, frame, nargs)` (or `fptr(f, frame, nargs, arg1)`), with `args` stored in an array (`jlcallframe` from Julia 1.11 on) allocated once per function, as large as the largest jlcall needs |
| a call with the `julia.gc_alloc_zeroinit_indirect(offset, size)` operand bundle (Julia master, on `jl_alloc_genericmemory_unchecked`) | the call, followed by a `memset` of `size` bytes at the data pointer stored at `offset` in the new object (nothing for a constant size of 0) |
| a call with Julia's operand bundles (`jl_roots`, ...) | the same call without them; other operand bundles are kept |

GPUCompiler's IR validator relies on the jlcall lowering: it reports dynamic calls by
finding calls of `jl_apply_generic` and `jl_invoke`, which only exist after it.

### Example: why Metal needs the cleanup

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

Deliberate differences, on the IR of every Julia version:

- Operand bundles that are not Julia's are kept, also on the calls that replace jlcalls
  and allocations. The C++ pass removes every operand bundle from a call that has one,
  including, e.g., `align` assumptions and convergence control tokens.
- The GC state byte of a thread is accessed with an alignment that holds: the C++ pass
  claims pointer alignment, which the byte at offset 25 of Julia 1.12 and 1.13 doesn't
  have (it does at master's offset 128).
- Allocas that are moved into the GC frame get their slots in the order of the
  function. The C++ pass iterates over a hash map keyed by the allocas' addresses, so its
  order changes from run to run (upstream's tests check these slots with `CHECK-DAG`).
- What the C++ pass takes from the host (`sizeof(void*)`, for alignments and for the
  size of frame slots) comes from the module's data layout; this is the same for every
  target Julia supports.
- The C++ pass declares `ijl_gc_small_alloc` in every module it runs on (Julia 1.12 and
  later); `jl-late-gc-cleanup` does not, since GPU modules don't link Julia's runtime.
- For calls marked `julia.safepoint` (Julia master), the memory effects of the function
  they call are dropped too, not only those of the call: LLVM combines both, so with the
  C++ pass a callee declared `memory(none)` still lets DSE delete the root stored for the
  call (a bug of the C++ pass, reproduced on Julia master with
  `function(LateLowerGCFrame,FinalLowerGC,sroa,dse,instcombine)`).
- Inputs on which the C++ pass crashes or asserts (an unexpected user of an alloca moved
  into the frame, a returned-roots argument that isn't an alloca, an `insertelement` of a
  tracked pointer at a dynamic index) make the port throw an error.
- The pass reports the control-flow graph as preserved unless it lowered a write barrier.
  The C++ pass of Julia 1.12 and older reports whether its cleanup changed something, and
  that of 1.12 and 1.13 reports the control-flow graph as changed whenever
  `julia.gc_alloc_bytes` is used (a hook for MMTk that does nothing in stock builds).

Fixes and features of later Julia versions that are applied to the IR of every version
(none of them changes the output on IR that the older C++ pass handles):

- Julia master: extractelements of tracked or derived pointers at a dynamic index are
  lifted (the C++ pass of 1.13 and older crashes); calls marked `julia.safepoint` are
  safepoints whatever their memory effects claim, and their memory effects are dropped
  (with LLVM 15, the attributes that LLVM 16 replaced by `memory`);
  `julia.blackbox` is lowered; thunks are skipped; `julia.gc_alloc_obj` calls with
  `julia.gc_alloc_ptr_offsets` or `julia.gc_alloc_zeroinit` bundles initialize the new
  object, and keep `julia.reset_region` metadata; `julia.gc_alloc_zeroinit_indirect`
  bundles are discharged.
- Julia 1.13: allocas that rooted pointers are stored to are found through selects and
  phis, as are the allocas of returned roots, and a trampoline that forwards its own
  `sret` argument is accepted (1.12 and older handle direct allocas only, and crash
  otherwise); calls that can return twice are always safepoints (1.12 and older skip the
  ones without memory effects, then fail when colouring); allocas with an alignment
  larger than 16 bytes are moved into the frame at an aligned slot, and the frame is
  aligned accordingly (1.12 and older assert).
- Julia 1.12: `llvm.vector.extract` and `llvm.vector.insert` of tracked pointers are
  handled (1.10 and 1.11 number them as new values).
- Julia 1.11: aggregates that contain pointers in address space 13 are recognized as
  loaded values, and selects and phis of aggregates of derived pointers are lifted (1.10
  only handles vectors).

What depends on the LLVM library rather than on the Julia version follows the library:
the position of the pass-through operand of `llvm.masked.load` and `llvm.masked.gather`
(LLVM 22 dropped their alignment operand), the alignment LLVM infers for a null type tag
(LLVM 22 stopped inferring it), and the spelling of memory effects (attributes before
LLVM 16).
