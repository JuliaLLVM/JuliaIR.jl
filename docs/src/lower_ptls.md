# LowerPTLS

Julia's code generator doesn't know how the code it emits will find the current task's
GC stack: it calls `julia.get_pgcstack()`, or `julia.get_pgcstack_or_new()` in a function
that C code may call from a thread Julia doesn't know yet (a `@cfunction`). Julia's
`LowerPTLS` pass replaces these calls with the code that finds the GC stack:

- in a function that receives the GC stack as an argument (the `swiftself` argument up to
  Julia 1.12, the `"gcstack"` one from 1.13 on), that argument;
- in *JIT mode* (the default), code that only works in the process that compiled it:
  - where the runtime keeps the GC stack in ELF TLS at a known offset from the thread
    pointer (`jl_tls_offset`, not -1), a read of the thread pointer with inline assembly
    and a load at that offset;
  - otherwise a call of the runtime's getter: at its address in the process up to Julia
    1.13 (with the key of the thread-local variable as argument on Darwin), through the
    symbol `jl_get_pgcstack_resolved` from Julia 1.14 on;
- in *imaging mode*, for the system image and package images, code that loads the getter
  (and, where the runtime uses ELF TLS, the TLS offset) from variables of the image that
  the loader fills in: `jl_pgcstack_func_slot`, `jl_pgcstack_key_slot` (Darwin) and
  `jl_tls_offset` (`jl_image_tls_offset` from Julia 1.14 on). With ELF TLS, the code
  reads the thread pointer when the offset is nonzero and calls the getter otherwise.

For `julia.get_pgcstack_or_new`, the code then checks whether the thread has a GC stack
(the branch weights make it likely), and if not, calls the runtime to adopt the thread
(`ijl_adopt_thread`, or `ijl_autoinit_and_adopt_thread` from 1.12 on, which also starts
the runtime). A thread that had a GC stack switches to the GC-unsafe state, with a
safepoint if it was GC-safe (on 1.11 always). Unless the function returns tracked
pointers, every return then restores the GC state the thread had on entry, GC-safe for an
adopted thread (followed by a safepoint from 1.12 on). None of this happens for a call
whose result is unused (it is removed) or in a function that receives the GC stack as an
argument.

`jl-lower-ptls` (`JuliaIR.LowerPTLSPass`) ports the pass for the IR of every Julia
version from 1.10 on, and `jlopt` runs it for Julia's name of the pass (`LowerPTLSPass`,
`LowerPTLSPass<imaging>`, `LowerPTLSPass<no-imaging>`). It is a required module pass. The
code keeps the names and the structure of the C++ (`fix_pgcstack_use!`,
`emit_pgcstack_tp!`, `set_pgcstack_attrs!`).

## Options and runtime facts

| Option | Keyword | Meaning |
|--------|---------|---------|
| `imaging` | `imaging` | imaging mode instead of JIT mode |
| `tls-getters` | `tls_getters` | always call the getter in JIT mode (Julia 1.14 and later, like the C++) |
| `tls-elf-support=yes\|no` | `tls_elf_support` | whether the runtime uses ELF TLS (imaging mode) |
| `tls-offset=N` | `tls_offset` | the GC stack's offset from the thread pointer, or -1 (JIT mode) |
| `pgcstack-getter=0x...` | `pgcstack_getter` | the getter's address in the process (JIT mode, up to 1.13) |
| `pgcstack-key=0x...` | `pgcstack_key` | the key of the GC stack's thread-local variable (Darwin) |
| `task-gcstack=N`, `task-ptls=N`, `tls-safepoint=N`, `tls-gc-state=N` | same, with `_` | the offsets of the task and thread-local state fields (`julia.get_pgcstack_or_new`) |

The facts left unspecified are [runtime facts](runtime.md) of the running Julia, read
when a module needs them (never when it doesn't call a getter) and never at precompile
time. The offset and the addresses are [`JuliaIR.Optional`](@ref) options. Like the C++
pass, JIT mode produces code for the process that runs the pass: the addresses and the
offset are the running Julia's, whatever the module's target.

## What changes between Julia versions

The differences between versions are fields of `JuliaIR.Dialect`:

| Behaviour | 1.10 | 1.11 | 1.12 | 1.13 | 1.14 and later |
|-----------|------|------|------|------|--------|
| the GC stack argument (`ptls_stack_argument`) | `swiftself` | `swiftself` | `swiftself` | `"gcstack"` | `"gcstack"` |
| the argument takes the call's name (`ptls_argument_takes_name`) | no | yes | yes | yes | yes |
| `inbounds` thread-pointer GEP, RISC-V thread pointer (`ptls_tp_inbounds`) | no | no | yes | yes | yes |
| thread adoption (`ptls_adopt_thread`) | `ijl_adopt_thread` | `ijl_adopt_thread` | `ijl_autoinit_and_adopt_thread` | same | same |
| the image's TLS offset (`ptls_image_offset_slot`) | `jl_tls_offset` | same | same | same | `jl_image_tls_offset` |
| the JIT getter (`ptls_jit_getter`) | address | address | address | address | `jl_get_pgcstack_resolved` |
| entry safepoint condition (`gc_state_condition`) | `and` | `or` | `old != new` | `old != new` | `old != new` |
| safepoint after restoring the GC state (`ptls_exit_safepoint`) | no | no | yes | yes | yes |

## Differences from the C++ pass

- Julia 1.12's C++ pass skips the entry safepoint exactly when it is needed (when a thread
  enters Julia from the GC-safe state; fixed in 1.13 by JuliaLang/julia#62636). The port
  uses 1.13's condition for 1.12.
- The 1-byte GC state is stored with `align 1`; the C++ claims the alignment of a pointer,
  which the field doesn't have on 1.10 to 1.13.
- Loads and GEPs of the task and thread-local state use the module's data layout
  (pointer size and alignment), where the C++ uses the host's. This matters only for a
  module of another word size than the host's (i686 on x86-64).
- The C++ reaches `llvm_unreachable` for an architecture it can't read the thread
  pointer of (release builds emit x86 assembly instead). The port throws a
  `JuliaIR.LowerPTLSError` naming the triple, only where the code would read the thread
  pointer: the getter works on any target. RISC-V's thread pointer is known from 1.12
  on, like in the C++.
- A module without a triple is for the running Julia's host (the C++ falls into the same
  unreachable).
- A getter used other than as the function of a `call` (as a value, or by an `invoke`),
  which crashes the C++ or makes it emit invalid IR, is rejected before anything changes,
  and so is a `julia.get_pgcstack_or_new` call that doesn't dominate every return of its
  function where the GC state is restored there (functions that don't return tracked
  pointers; the code to restore the state needs it; Julia's code generator always calls
  it in the entry block).
- In imaging mode, a module that declares the image's variables already uses those
  declarations (the C++ adds new ones with suffixed names, which the loader doesn't
  fill in); a declaration of another type or kind (a function, an alias, a thread-local
  variable) is an error, as is a declaration of the function that adopts threads with
  another type than the getter's. New declarations are in
  the data layout's address space for globals, like the C++'s.
- `tls-getters` is rejected before Julia 1.14, which doesn't have it.
