# API reference

The API is not exported; use qualified names (`JuliaIR.register!`).

## Passes

```@docs
JuliaIR.register!
JuliaIR.passes
JuliaIR.RemoveNIPass
JuliaIR.AllocOptPass
JuliaIR.PropagateAddrspacesPass
JuliaIR.DemoteFloat16Pass
JuliaIR.GCInvariantVerifierPass
JuliaIR.GCInvariantError
JuliaIR.GCInvariantViolation
JuliaIR.LateLowerGCFramePass
JuliaIR.LateGCCleanupPass
JuliaIR.FinalLowerGCPass
JuliaIR.DeclarationError
JuliaIR.CombineMulAddPass
JuliaIR.UnsupportedInputError
JuliaIR.UnsupportedConstruct
JuliaIR.LowerExcHandlersPass
JuliaIR.HandlerNestingError
JuliaIR.LowerSIMDLoopPass
JuliaIR.JuliaLICMPass
JuliaIR.ExpandAtomicModifyPass
JuliaIR.AtomicModifyError
JuliaIR.CancellationLoweringPass
JuliaIR.CancellationLoweringError
JuliaIR.RemoveJuliaAddrspacesPass
JuliaIR.RemoveAddrspacesPass
JuliaIR.LowerPTLSPass
JuliaIR.LowerPTLSError
JuliaIR.CPUFeaturesPass
JuliaIR.CPUFeaturesError
JuliaIR.always_have_fma
JuliaIR.jit_target
JuliaIR.MultiVersioningPass
JuliaIR.MultiVersioningTarget
JuliaIR.target_specs
JuliaIR.MultiVersioningError
```


## Julia's pipeline

```@docs
JuliaIR.JuliaPipeline
JuliaIR.build_pipeline!
JuliaIR.pipeline
JuliaIR.optimize!
JuliaIR.alias_analyses!
JuliaIR.parse_pipeline_options
JuliaIR.expand_julia_pipeline
```


## Dialects and options

```@docs
JuliaIR.Dialect
JuliaIR.PassOptions
JuliaIR.option
JuliaIR.OptionSpec
JuliaIR.parse_options
```

## Runtime facts

```@docs
JuliaIR.runtime_layout
JuliaIR.runtime_fact
JuliaIR.RuntimeFacts
JuliaIR.runtime_options
JuliaIR.gc_pool_class
JuliaIR.RuntimeError
```

## Type lowering

```@docs
JuliaIR.julia_type
JuliaIR.isboxed
JuliaIR.julia_struct_type
JuliaIR.deserves_stack
JuliaIR.deserves_argbox
JuliaIR.deserves_retbox
JuliaIR.deserves_sret
JuliaIR.check_layout
JuliaIR.LayoutDivergence
```

## Libraries

```@docs
JuliaIR.require_opaque
JuliaIR.library_facts
```

## The `jlopt` driver

```@docs
JuliaIR.jlopt
JuliaIR.JloptError
```
