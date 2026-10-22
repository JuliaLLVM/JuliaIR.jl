# FinalLowerGC

Julia's `FinalLowerGC` pass runs after [LateLowerGCFrame](late_lower_gc_frame.md) and
lowers what that pass leaves behind to code for Julia's runtime:

| Intrinsic | Lowered to |
|-----------|------------|
| `julia.new_gc_frame(n)` | a stack array of `n` roots plus the frame's two header words, zeroed by a `memset` |
| `julia.push_gc_frame(frame, n)` | stores of the root count and of the task's current GC stack into the frame's header, and of the frame into the task's GC stack |
| `julia.pop_gc_frame(frame)` | a store of the previous frame back into the task's GC stack |
| `julia.get_gc_frame_slot(frame, i)` | the address of root `i`, after the header |
| `julia.gc_alloc_bytes(ptls, size[, tag])` | a call of the runtime's allocator: for a constant size, the pool allocator of its size class, or the big-object allocator; otherwise the typed allocator |
| `julia.queue_gc_root(v)` | a call of `ijl_gc_queue_root` |
| `julia.safepoint(page)` | a volatile load of the safepoint page, which the runtime protects to stop the thread |
| `julia.object_write_barrier`, `julia.field_write_barrier.*` (Julia 1.14 and later) | the write barrier: a check of the parent's and the children's GC bits, and a call of `julia.queue_gc_root` on the slow path |

`jl-final-lower-gc` (`JuliaIR.FinalLowerGCPass`) ports the pass for the IR of every Julia
version from 1.10 on, and `jlopt` runs it for Julia's name of the pass (`FinalLowerGC`). It
is a required pass, so it also runs on `optnone` functions. Like Julia's, it only lowers
functions with a GC stack: a `julia.get_pgcstack` or `julia.get_pgcstack_or_new` call
in the entry block, or from Julia 1.13 on an argument with the `gcstack` attribute.
Other functions keep their intrinsics.

## A module pass and a function pass

Julia 1.10 uses a module pass; later versions use a function pass. `jl-final-lower-gc` is
registered as both: in a pipeline, the name at the top level is the module pass
(`-passes=jl-final-lower-gc`) and the name in a function pass manager the function pass
(`-passes='function(jl-final-lower-gc)'`). Both lower each function the same way:

- the module pass on Julia 1.10's IR does what Julia 1.10 does: it declares the runtime
  functions in every module, also one without Julia code, and keeps them in
  `llvm.compiler.used` while it runs (which moves an existing `llvm.compiler.used` to the
  end of the module's globals);
- the module pass on the IR of later versions runs the function pass on every function;
- the function pass on Julia 1.10's IR declares the runtime functions like later
  versions do, in the module of each function that it lowers.

As the name at the top level is the module pass, a pipeline that starts with it is a module
pipeline, in which function passes have to be nested: `jl-final-lower-gc,jl-alloc-opt` doesn't
parse, `function(jl-final-lower-gc,jl-alloc-opt)` does. From Julia 1.11 on, LLVM nests a
pipeline that starts with Julia's (function) pass, such as `FinalLowerGC,AllocOpt`, in a
function pass manager; `jlopt` keeps that nesting when it maps the names to the ports.

`JuliaIR.FinalLowerGCPass(; kind)` selects one of them for `run!`; by default, the kind of
the running Julia's pass.

## What changes between Julia versions

The pass follows the C++ pass of the running Julia's version. The differences between
versions are fields of `JuliaIR.Dialect`:

| Behaviour | 1.10 | 1.11 | 1.12 | 1.13 | 1.14 and later |
|-----------|------|------|------|------|--------|
| Julia's pass | module pass | function pass | function pass | function pass | function pass |
| runtime functions declared | in every module | in modules with a function with a GC stack | same | in modules that use a GC intrinsic | same, also the `_reset_safe` variants |
| frame code placed | after the intrinsics, with the next instruction's debug location | at the intrinsics, with their debug locations | same | same | same |
| names (`frame.nroots`, `frame.prev`, `task.gcstack`) | no | yes | yes | yes | yes |
| pool allocator | `ijl_gc_pool_alloc(ptls, offset, osize)` | `ijl_gc_pool_alloc_instrumented(ptls, offset, osize, tag)` | `ijl_gc_small_alloc(ptls, offset, osize, tag)` | same | same |
| big-object allocator | `ijl_gc_big_alloc(ptls, size)` | `ijl_gc_big_alloc_instrumented(ptls, size, tag)` | `ijl_gc_big_alloc(ptls, size, tag)` | same | same |
| typed allocator | `ijl_gc_alloc_typed(ptls, size, null)` | `ijl_gc_alloc_typed(ptls, size, tag)` | same | same | same |
| alignment of allocations | none | the call's, at least a pointer's | same | same | same |
| allocations and root queuing in a cancellation reset region (`!julia.reset_region`) | | | | | the `_reset_safe` variants of the runtime functions |
| write barriers | | | | | lowered here (LateLowerGCFrame leaves them), without null children |

The size of a big object's allocation includes the type tag; the typed allocator is given
the size of the object without it. The result of an allocation of a constant size is
`dereferenceable` for the object's size, that of an allocation of a dynamic size for a
pointer's size.

## Pool size classes

To lower an allocation of a constant size, the pass asks the running Julia's GC which pool
the size belongs to, like Julia's pass does (`jl_gc_classify_pools`): the offset of the
pool in the thread-local state, and the size of its objects. These depend on the build of
Julia (its page size, for one), so the pass can't know them for another Julia version's
IR, nor for a Julia built with another GC than the stock one: a constant-size allocation
then makes it throw a [`JuliaIR.RuntimeError`](@ref). Nothing else that the pass lowers
needs the runtime, so modules without such allocations (GPU code, for instance) are
lowered on any Julia. [`JuliaIR.gc_pool_class`](@ref) gives the answer for one size; it
is asked when a pass needs it, once per size and process, and never stored in the
precompiled package.

## Differences with Julia's C++ pass

Fixes of later Julia versions, applied to the IR of every version:

- Julia 1.14 and later: the frame is zeroed by a non-volatile `memset` with the frame's
  TBAA tag (JuliaLang/julia#62061). Julia 1.10 to 1.13 pass that tag as the `memset`'s
  volatility flag by mistake, so their `memset` is volatile and has no TBAA tag, which
  keeps LLVM from removing stores to the frame that are overwritten.
- Julia 1.11: the result of an allocation of a constant size is `dereferenceable` for the
  object's size, and not at all for an empty object (JuliaLang/julia#51218). Julia 1.10
  claims the size of the pool's objects, or the size of a big object's allocation, from
  the start of the object, which is a pointer's size more than the object has.
- Julia 1.13: the frame is aligned to what LateLowerGCFrame records on
  `julia.new_gc_frame` (an alloca with an alignment larger than 16 bytes that it moved into
  the frame). This package's LateLowerGCFrame records it on the IR of every version.

Deliberate differences:

- Julia 1.10's module pass preserves existing runtime entries in `llvm.compiler.used`.
  It removes only the entries it added temporarily; the C++ pass removes both.

- An existing runtime declaration with an incompatible type raises
  [`JuliaIR.DeclarationError`](@ref) before the pass changes the module. The same check
  applies to calls of `julia.queue_gc_root`. The C++ pass calls the existing function with the wrong arguments, which
  gives invalid IR. (When a global variable has the name, both declare the function under
  a new one, such as `ijl_gc_queue_root.1`.)
- What the C++ pass takes from the host (`sizeof(void*)`, for the size of frame slots, the
  alignment of the frame's stores and loads, and the header of big objects) comes from the
  module's data layout. This also supports targets with a different pointer size.
- From Julia 1.14 on, the pass reports the control-flow graph as preserved unless it
  lowered a write barrier, like this package's LateLowerGCFrame. The C++ pass of Julia
  1.14 reports every analysis as invalidated.

Behaviours that are kept as they are:

- A function without a GC stack keeps its GC intrinsics. From Julia 1.14 on, this includes
  write barriers, which then call undefined `julia.*` functions; Julia's code generator
  gives every function with write barriers a GC stack.
- The runtime functions are declared where Julia's pass declares them (see the table
  above), even when nothing calls them.
- On Julia 1.10, the frame's allocation and its push get the debug location of the
  instruction after the intrinsic.
- The result of an allocation of a dynamic size is `dereferenceable` for a pointer's size,
  which an empty object doesn't have.
