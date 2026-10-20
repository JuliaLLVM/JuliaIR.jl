# Runtime facts

Some of Julia's passes lower the IR to code that works with Julia's runtime directly: they
load the thread-local state from the current task, or set up exception handlers. To do
so, they need facts that the IR doesn't spell out: the offsets of fields in the runtime's
task and thread-local state, the size of an exception handler (which contains the C
library's `jmp_buf`), the name of the runtime's `setjmp`, and where the runtime keeps
the current task's GC stack in thread-local storage. Julia's C++ passes compile these
facts in from Julia's headers, or read them from the process they run in.

JuliaIR.jl processes the IR of the Julia version it runs on, so the ports take these
facts from the running Julia. Like the C++ passes, they use them whatever target the
module is for: IR for targets without Julia's runtime, like GPUs, doesn't need them.
What the C++ passes take from the module stays a property of the module: whether `setjmp`
takes a `savemask` argument, for instance, follows the module's triple (none on Windows),
not the running Julia. A pass reads the facts through [`JuliaIR.runtime_layout`](@ref):

```julia
rt = JuliaIR.runtime_layout(dialect, mod)
rt.task_ptls      # 168 on Julia 1.12 on a 64-bit machine
rt.handler_size   # 264 on Julia 1.12 on x86-64 Linux
```

## Where the facts come from

A fact is looked up when a pass reads it, so IR that doesn't need it (e.g. a function
without exception handlers) is processed without:

1. A pass option of the same name gives the fact explicitly, e.g.
   `jl-lower-exc-handlers<handler-size=264;setjmp=__sigsetjmp>` or
   `jl-lower-ptls<tls-offset=-8>` (see [`JuliaIR.Optional`](@ref) for the options that
   can be negative or are addresses).
2. Otherwise, the fact is read from the running Julia, whose IR the passes process.
3. When the running Julia doesn't have the fact (e.g. the reset context of cancellation
   points before Julia 1.14) or it can't be read, the pass throws a
   [`JuliaIR.RuntimeError`](@ref) that names the fact and the option that gives it. So
   does `JuliaIR.runtime_layout` for a fact of another Julia version's dialect that isn't
   given explicitly.

## How they are read

Julia doesn't export most of these facts: `jl_task_t`'s runtime fields and
`jl_tls_states_t` aren't Julia types, so `fieldoffset` doesn't reach them. Each fact is
read the first time a pass needs it, once per process:

| Facts | Read from |
|-------|-----------|
| `task_gcstack` | the task's `pgcstack` (`jl_get_pgcstack`) relative to the current task |
| `task_eh` | the field of the current task that changes inside a `try` and is restored after it |
| `tls_gc_state` | the byte of the thread-local state that becomes `JL_GC_STATE_SAFE` across `jl_gc_safe_enter` |
| `tls_elf_support`, `tls_offset` | the runtime's `jl_tls_elf_support` and `jl_tls_offset` |
| `pgcstack_getter`, `pgcstack_key` | the runtime's `jl_pgcstack_getkey` |
| `task_ptls`, `tls_safepoint` | the code Julia generates for `GC.safepoint()`: the load of the thread-local state from the task and the safepoint load from it |
| `handler_size`, `handler_align`, `setjmp` | the code Julia generates for a `try`: the stack buffer that `setjmp` is called on (lowered by Julia's LowerExcHandlers up to Julia 1.12, emitted by its code generator later) |
| `task_reset_ctx`, `reset_ctx_*` | the code Julia generates for `Base.@cancel_check` (Julia 1.14 and later) |
| `smalltag_shift` | the header of a boxed `Int64`, whose small type tag is a field of `Int64.flags` |
| `max_small_tag` | the code Julia generates for `typeof` of an object of unknown type: the bound below which a tag indexes `jl_small_typeof` |
| `task_world_age` | the field of the current task that `Core._call_in_world` sets to the world it calls in |
| `cfunction_cache`, `cfuncdata_size` | the code Julia generates for a `@cfunction` (Julia 1.12 and later): the arguments of its call of `jl_get_abi_converter` |

The generated code is the text that `code_llvm` prints for a small function, parsed
into a context of the LLVM library that LLVM.jl uses, which may be newer than Julia's
own. If that code doesn't have the expected shape, reading the fact throws a
`RuntimeError` that shows it.

FinalLowerGC also needs the pool that an allocation of a given size comes from, which the
runtime computes (`jl_gc_classify_pools`) rather than stores. It is not a field of
`RuntimeFacts`: [`JuliaIR.gc_pool_class`](@ref) asks the running Julia for each size, with
the same rules (only for the running Julia's dialect, once per process; see
[FinalLowerGC](final_lower_gc.md#Pool-size-classes)).

The package tests compare every fact with an independent check where one exists (the
runtime's `jl_get_ptls_states`, the C library's `setjmp`, the pool offsets Julia emits for
an allocation against `jl_gc_classify_pools`, ...), and with the values measured on
x86-64 Linux at each Julia version.

`tls_offset`, `pgcstack_getter` and `pgcstack_key` are properties of the process rather
than of the Julia version: the offset depends on where the runtime library was loaded
(-1 where code can't read the thread-local variable directly, as on macOS and Windows),
and the getter and key are addresses in the process. Code that embeds them, like
[LowerPTLS](lower_ptls.md)'s JIT mode, only works in the process that compiled it. Like
every fact, they are read when a pass first needs them, never while the package is
precompiled.

## The JIT's target

What Julia's JIT compiles for is not a runtime fact, but CPUFeatures needs it as the
default target: its answers up to Julia 1.13 (read from the code Julia generates for
`Core.Intrinsics.have_fma`), and its CPU, features and triple from Julia 1.14 on
(`jl_get_llvm_target` and `JLJITGetTripleString`, see [`JuliaIR.jit_target`](@ref)). They
are read the same way, once per process. The pass options that replace them describe a
target rather than name a fact (`target_cpu`, `target_features`, `target_machine`); see
[CPUFeatures](cpu_features.md).
