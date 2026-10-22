# JuliaIR.jl

JuliaIR.jl ports Julia's C++ LLVM passes to Julia using
[LLVM.jl](https://github.com/JuliaLLVM/LLVM.jl)'s custom-pass API. The passes operate
on *Julia's LLVM IR dialect*: GC pointers in address spaces 10 to 13, intrinsics such
as `julia.gc_alloc_obj`, and Julia-specific metadata and operand bundles. They can run
on LLVM libraries other than the one Julia bundles.

"IR" in the package name refers to that dialect, not to Julia's own SSA IR.

Julia's C++ passes live in `libjulia-codegen` and are built against Julia's bundled
LLVM. The ports let consumers such as GPUCompiler process Julia's IR with a newer
LLVM, while following the pass behavior of the Julia version that produced the IR.
Intentional differences are documented for each pass.

## Status

Every pass of Julia's optimization pipelines, Julia 1.10 to 1.15, is ported (see the
table on the documentation's home page), and the pipeline itself is rebuilt from the
ports for each Julia version. The package is not registered yet; it needs LLVM.jl 10.4 or
later.

## What is supported

- **The running Julia's IR.** Passes select their dialect from `VERSION`. Julia 1.10
  through 1.15 are supported; there is no option to process another Julia version's IR.
- **Julia's LLVM, or a newer one.** The passes work with LLVM.jl on the LLVM library that
  Julia bundles, and on newer LLVM versions, e.g. a separately built library like
  libLLVMGPU. CI tests every supported Julia version on both its bundled LLVM and
  standalone LLVM 23.
- **Opaque pointers only.** Julia 1.10 emits typed pointers by default; its IR is
  supported when parsed into a context with opaque pointers
  (`Context(; opaque_pointers=true)`), which upgrades it.
- **Julia's stock GC.** MMTk builds are not supported.

Some passes need facts about Julia's runtime that the IR doesn't state, such as the
offsets of fields in the current task or the size of an exception handler. They take
these from the running Julia or explicit pass options. GPU code without Julia runtime
operations does not need these facts.

## Usage

The passes are LLVM.jl custom passes. Register them with a pass builder and use them by
name, optionally with options:

```julia
using LLVM, LLVM.IR, LLVM.Passes, JuliaIR

@dispose ctx=Context(; opaque_pointers=true) pb=PassBuilder() begin
    @dispose mod=parse(LLVM.Module, ir) begin
        JuliaIR.register!(pb)
        add!(pb, "jl-remove-ni")
        run!(pb, mod)
    end
end
```

or construct a single pass: `run!(JuliaIR.RemoveNIPass(), mod)`. The pass
names start with `jl-`, so they never clash with Julia's own C++ passes, which are also
available when running on Julia's LLVM.

Julia's whole optimization pipeline is available as `JuliaIR.optimize!(mod; level=2)`,
or `JuliaIR.build_pipeline!(pb; level=2)` to add it to a pass builder.

To use another LLVM library next to Julia's, e.g. a standalone build of a newer LLVM,
register it with LLVM.jl and select it for the whole transformation, by creating the
context with it:

```julia
lib = LLVM.register_library!(:other, "/path/to/libLLVM-standalone.so")
Context(; library=lib, opaque_pointers=true) do ctx
    @dispose mod=parse(LLVM.Module, ir) begin
        run!(JuliaIR.RemoveNIPass(), mod)
    end
end
```

For an existing context, `context!(ctx) do ... end` selects it and its library.
Intrinsic IDs and LLVM compatibility checks use the selected library.

GPUCompiler runs the ports instead of Julia's C++ passes with `julia_passes = :ports` in
its `CompilerConfig` (or its `julia_passes` preference set to `"ports"`) and JuliaIR.jl
loaded. This integration is proposed in
[GPUCompiler.jl#1026](https://github.com/JuliaGPU/GPUCompiler.jl/pull/1026).

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

`test/upstream/run.jl` runs Julia's own pass tests (`test/llvmpasses`) at pinned commits
(and, for nightly builds, at the commit they were built from), with the ports;
`test/upstream/manifest.toml` records which apply. See the documentation's "Testing" page.
