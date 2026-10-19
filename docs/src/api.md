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
