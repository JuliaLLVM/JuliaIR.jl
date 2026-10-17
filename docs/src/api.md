# API reference

The API is not exported; use qualified names (`JuliaIR.register!`).

## Passes

```@docs
JuliaIR.register!
JuliaIR.passes
JuliaIR.RemoveNIPass
JuliaIR.AllocOptPass
JuliaIR.PropagateAddrspacesPass
```

## Dialects and options

```@docs
JuliaIR.Dialect
JuliaIR.PassOptions
JuliaIR.parse_options
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
