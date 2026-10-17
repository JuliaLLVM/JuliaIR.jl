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

Work in progress. Ported so far: RemoveNI (`jl-remove-ni`).

## Supported dialects and libraries

- The IR dialect of Julia 1.10 up to the current development version, selected with a
  `julia` version option on every pass (defaulting to the running Julia's `VERSION`).
- Opaque pointers only. Julia 1.10 emits typed pointers by default; its IR is supported
  when parsed into a context with opaque pointers (`Context(; opaque_pointers=true)`),
  which upgrades it.
- Any LLVM library supported by LLVM.jl.

## Usage

The passes are LLVM.jl custom passes. Register them with a pass builder and use them by
name, optionally with options:

```julia
using LLVM, LLVM.IR, LLVM.Passes, JuliaIR

@dispose ctx=Context(; opaque_pointers=true) pb=PassBuilder() begin
    mod = parse(LLVM.Module, ir)
    JuliaIR.register!(pb; julia=v"1.12")
    add!(pb, "jl-remove-ni")
    run!(pb, mod)
end
```

or construct a single pass: `run!(JuliaIR.RemoveNIPass(; julia=v"1.12"), mod)`. The pass
names start with `jl-`, so they never clash with Julia's own C++ passes, which are also
available when running on Julia's LLVM.

## Testing

`Pkg.test()` runs the package's own tests, including a [lit](https://llvm.org/docs/CommandGuide/lit.html)
suite in `test/lit`. Its tests are `.ll` files with `RUN:` lines, like LLVM's and Julia's
own, in which `opt` is `bin/jlopt`: an `opt`-compatible driver that runs the passes of
this package (and maps Julia's pass names, e.g. `AllocOpt`, to their ports). `lit` and
`FileCheck` come from `LLVM_utils_unified_jll`; `python3` must be available (the lit tests
are skipped with a warning if it is not, except on CI).

`bin/jlopt` needs a Julia whose project provides JuliaIR, e.g.
`julia --project=test bin/jlopt -passes=jl-remove-ni -S input.ll` (Julia 1.12 and later;
`test/litsetup.jl`'s `jlopt_bindir(dir)` writes an `opt` wrapper for the current Julia and
project). With such a wrapper, LLVM's `update_test_checks.py --opt-binary=DIR/opt` works on
the tests.
