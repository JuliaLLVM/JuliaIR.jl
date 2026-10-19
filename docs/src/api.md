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
JuliaIR.CombineMulAddPass
JuliaIR.UnsupportedInputError
JuliaIR.UnsupportedConstruct
JuliaIR.LowerExcHandlersPass
JuliaIR.HandlerNestingError
JuliaIR.LowerSIMDLoopPass
JuliaIR.ExpandAtomicModifyPass
JuliaIR.AtomicModifyError
JuliaIR.CancellationLoweringPass
JuliaIR.CancellationLoweringError
JuliaIR.RemoveJuliaAddrspacesPass
JuliaIR.RemoveAddrspacesPass
```


## Dialects and options

```@docs
JuliaIR.Dialect
JuliaIR.PassOptions
JuliaIR.parse_options
```

## Runtime facts

```@docs
JuliaIR.runtime_layout
JuliaIR.runtime_fact
JuliaIR.RuntimeFacts
JuliaIR.runtime_options
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
