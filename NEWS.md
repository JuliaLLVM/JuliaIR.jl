# JuliaIR.jl release notes

## v0.1.1

- Follow Julia 1.13.4, which backported the zeroing of new objects in LateLowerGCFrame
  and IRCE with cleanup in the pipeline (from 1.13.4 on).
- Follow Julia 1.14.0-beta1: cancellation (CancellationLowering, reset regions and the
  reset-safe allocation functions) is now a feature of Julia 1.15, as 1.14 reverted it;
  the `julia.gc_alloc_memory` intrinsic, the elision of write barriers on fresh objects
  and the alignment inference after the GC lowering are now features of 1.14.
- Port the changes of Julia 1.14 and master to the passes: AllocOpt's search for the
  last use, a variable zeroing flag of `julia.gc_alloc_memory`, LateLowerGCFrame's
  coalesced slot resets and local slot addresses, LowerPTLS's thread-local storage on
  RISC-V and macOS, and on 1.15 FinalLowerGC's write barriers for permanent objects,
  LowerPTLS's lowering of JIT code through the runtime's variables, CancellationLowering's
  relaxed region closing and pure intrinsics, the store forwarding before IndVarSimplify
  in the pipeline, and RemoveJuliaAddrspaces's order of uses (Julia moves function bodies
  instead of cloning them).
- Pin the upstream fixtures of Julia 1.10.13, 1.13.4 and 1.14.0-beta1.

## v0.1.0

- Port Julia's LLVM passes and optimization pipelines for Julia 1.10 through 1.15
  using LLVM.jl, including support for standalone LLVM libraries and opaque pointers.
- Provide `jl-late-gc-cleanup` for code without Julia's runtime, with explicit input
  validation, and Julia-to-LLVM type lowering for independent LLVM contexts.
- Provide the `jlopt` driver, upstream pass fixtures, and differential comparisons
  against Julia's C++ passes. Document intentional differences for each pass.
