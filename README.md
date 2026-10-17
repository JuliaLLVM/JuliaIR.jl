# JuliaIR.jl

Julia implementations of the LLVM passes that operate on *Julia's LLVM IR dialect*: the IR
that Julia's code generator emits, with GC-tracked pointers in address spaces 10 to 13,
intrinsics like `julia.gc_alloc_obj` and `julia.gc_preserve_begin`, and Julia-specific
metadata and operand bundles. The passes are ports of the C++ passes in Julia's
`src/llvm-*.cpp`, written against [LLVM.jl](https://github.com/JuliaLLVM/LLVM.jl)'s
custom-pass API, so that they can run on any LLVM library LLVM.jl can use, including one
that does not contain Julia's own passes.

"IR" in the package name refers to that dialect, not to Julia's own SSA IR.

## Status

Work in progress; no passes yet.

## Supported dialects and libraries

- The IR dialect of Julia 1.10 up to the current development version, selected with a
  `julia` version option on every pass (defaulting to the running Julia's `VERSION`).
- Opaque pointers only. Julia 1.10 emits typed pointers by default; its IR is supported
  when parsed into a context with opaque pointers (`Context(; opaque_pointers=true)`),
  which upgrades it.
- Any LLVM library supported by LLVM.jl.
