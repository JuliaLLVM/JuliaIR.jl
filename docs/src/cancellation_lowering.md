# CancellationLowering

Julia master can cancel a running task at a *cancellation point*: `Base.@cancel_check`,
which the code generator emits as a call `julia.cancellation_point()`. Julia's
`CancellationLowering` pass turns these calls into *reset regions*. At a point, the
function fills a buffer on its stack, a `jl_reset_ctx_t`, and publishes it in its task's
`reset_ctx` field; while it is published, the runtime may deliver a cancellation (or a
preemption) by jumping back to the point. Everything the function does while the region
is open must therefore be safe to abandon and redo, and the pass closes the region
(`reset_ctx = NULL`) before anything that isn't.

`jl-cancellation-lowering` (`JuliaIR.CancellationLoweringPass`) ports the pass, and
`jlopt` runs it for Julia's name (`CancellationLowering`). It is a required function pass,
like Julia's. No Julia release has the pass: for the IR of Julia 1.10 to 1.13, which has
no cancellation points, it does nothing.

## What the pass does

For each function, in this order:

1. It finds the function's GC stack (a `julia.get_pgcstack` or
   `julia.get_pgcstack_or_new` call in the entry block, or an argument with the
   `"gcstack"` attribute) and its cancellation points. A function without points is only
   processed if it has a GC stack and the `"julia.ipo_reset_safe"` attribute (see below).
2. After the GC stack, it computes the addresses of the task's `reset_ctx`, `ptls` and
   `eh` fields (`%reset_ctx_ptr`, `%ptls_field_ptr`, `%eh_field_ptr`).
3. It lowers each point. The first one adds the buffer (`%cancel_ucontext`, an `alloca`
   at the start of the entry block), which all points of the function share. The block
   is split at the point; if this frame's buffer is still published (`%region_live`),
   the point does nothing. Otherwise (`cancel_establish`) it unpublishes the buffer,
   runs a GC safepoint, stamps the buffer with its own address, saves the task's GC stack
   and exception handler in it, calls `setjmp` on its `mctx` field, and publishes it
   (`store atomic volatile ... release`). A point whose value is used becomes a `phi` of 0
   and `setjmp`'s result.
4. It closes the region before every *unsafe point* that a publication can reach:
   stores, atomic read-modify-writes, and volatile loads that the code generator didn't
   mark `!julia.reset_safe`, and calls that are either not marked or are runtime calls
   (callees named `julia.call*`, `jl_*` or `ijl_*`, except `setjmp`). Calls that don't
   need it: lifetime markers, debug intrinsics, `llvm.assume`, `llvm.expect`,
   `llvm.prefetch`, `setjmp`, `julia.safepoint`, `julia.pointer_from_objref`,
   `julia.gc_loaded`, allocations and write barriers. Other intrinsic calls are unsafe
   points, including `llvm.memset` and the `llvm.julia.gc_preserve_*` markers.
5. It closes the region before every return that a publication reaches (before a
   `musttail` call, which must stay next to its return).
6. It marks every allocation (`julia.gc_alloc_obj`) and write barrier that may run with
   the region open with `!julia.reset_region`. FinalLowerGC lowers these to the runtime's
   `*_reset_safe` entry points, which close and reopen the region themselves.

A function with the `"julia.ipo_reset_safe"` attribute (its own effects are reset-safe,
so its callers may keep their region open across a call to it) may run inside its
caller's region, everywhere: its calls get step 4 (but not its stores and loads, which
the caller's contract covers), its allocations and write barriers step 6, and its
returns no teardown (the region is the caller's). The addresses of step 2 are only
computed if a call needs them.

Under ThreadSanitizer (`sanitize_thread`), whose instrumentation runs later and would turn
the region's bookkeeping into runtime calls, a point is only a GC safepoint, and the pass
does nothing else.

## Runtime facts

The offsets of `gcstack`, `ptls`, `eh` and `reset_ctx` in the task, of the safepoint page
in the thread-local state, the size and alignment of `jl_reset_ctx_t` and the offsets of
its `gcstack`, `eh` and `mctx` fields, and the name of the runtime's `setjmp` are
[runtime facts](runtime.md), taken from the running Julia when a function needs them
(only functions with points, or `"julia.ipo_reset_safe"` functions with runtime calls).
The pass options `task-gcstack`, `task-ptls`, `task-eh`, `task-reset-ctx`,
`tls-safepoint`, `reset-ctx-size`, `reset-ctx-align`, `reset-ctx-gcstack`,
`reset-ctx-eh`, `reset-ctx-mctx` and `setjmp` give them explicitly. As in Julia's pass,
`setjmp` takes a second (`savemask`) argument unless the module's triple is for Windows,
read without normalizing it: `x86_64-w64-windows-gnu` is Windows, `x86_64-w64-mingw32` is
not. The `setjmp` name is the running Julia's whatever the triple.

## Differences with Julia's pass

- When the pass splits blocks, it reports the control-flow graph as changed. Julia's pass
  reports it as preserved, which keeps a dominator tree computed before it without the
  new blocks; LateLowerGCFrame (Julia's and the port) then takes blocks missing from the
  tree for unreachable, and doesn't root an object that `GC.@preserve` keeps alive across
  a call after a cancellation point.
- A cancellation point in a function without a GC stack in its entry block, and an
  `invoke` of `julia.cancellation_point`, are rejected with a
  `JuliaIR.CancellationLoweringError` before the function is changed. Julia's pass emits
  instructions with missing operands for the first (invalid IR), and leaves the second
  unlowered. The code generator emits neither.
- Pointers are loaded and stored with the pointer alignment of the module's data layout;
  Julia's pass uses the host's pointer size (8 on 64-bit hosts, also for a 32-bit
  module). For IR that Julia generates for its own host, the result is the same.
