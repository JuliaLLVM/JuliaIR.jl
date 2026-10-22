# JuliaIR.jl release notes

## Unreleased

- Port Julia's LLVM passes and optimization pipelines for Julia 1.10 through 1.15
  using LLVM.jl, including support for standalone LLVM libraries and opaque pointers.
- Provide `jl-late-gc-cleanup` for code without Julia's runtime, with explicit input
  validation, and Julia-to-LLVM type lowering for independent LLVM contexts.
- Provide the `jlopt` driver, upstream pass fixtures, and differential comparisons
  against Julia's C++ passes. Document intentional differences for each pass.
