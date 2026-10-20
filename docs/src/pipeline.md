# Julia's optimization pipeline

Julia optimizes the code it generates with a pipeline of LLVM's passes and its own,
built by `buildPipeline` in Julia's `src/pipeline.cpp` and available to `opt` as the
pipeline element `julia<level=N;...>`. JuliaIR rebuilds this pipeline for each Julia
version, with the ports of Julia's passes in place of the C++ ones:

```julia
using JuliaIR, LLVM

JuliaIR.optimize!(mod; level=2)                  # optimize a module like Julia does
JuliaIR.pipeline(; level=3)                      # the pipeline, as text
JuliaIR.build_pipeline!(pb; level=2)             # add it to a PassBuilder
JuliaIR.pipeline(; level=2, ports=false)         # with Julia's C++ passes instead
```

`jlopt` replaces `julia` and `julia<...>` elements of its pipeline by the rebuilt pipeline
(unless `-map-julia-passes=0`), so the upstream fixtures that run Julia's pipeline test
the ports.

## Options

The options are those of Julia's `OptimizationOptions` (`src/jitlayers.h`), with the same
defaults, and the pipeline element's syntax: `julia<level=3;no_cleanup;dump_native>`.
Julia 1.10 has `lower_intrinsics`, `dump_native`, `external_use` and `llvm_only`; 1.11
adds `always_inline`, `enable_early_simplifications`, `enable_early_optimizations`,
`enable_scalar_optimizations`, `enable_loop_optimizations`, `enable_vector_pipeline`,
`remove_ni`, `cleanup` and `warn_missed_transformations`; 1.14 adds the sanitizer
options. Unlike Julia, JuliaIR rejects:

- options that the running Julia's pipeline doesn't have, and `no_level`;
- `sanitize_memory`, `sanitize_thread` and `sanitize_address` set to true (only stock
  Julia builds are supported, which have none of the sanitizers);
- `no_remove_ni` while lowering intrinsics, which fails an assertion in Julia's C++.

The level is clamped to 0–3, like Julia does.

## Alias analyses

The pipeline text doesn't say which alias analyses the passes use. Julia uses LLVM's
basic, scoped no-alias and type-based alias analyses from level 2 on, and the target
machine's at every level; `JuliaIR.alias_analyses!(pb, level)` sets up the same, and
`JuliaIR.optimize!` uses it. A pass builder without it (as in `opt` and `jlopt`) uses
LLVM's default alias analyses at every level.

## Target

From Julia 1.14 on, Julia's JIT gives CPUFeatures the target machine it compiles for,
whereas `opt -passes=julia` gives it none (so a function without a `target-cpu` is taken
to be for the generic CPU). `JuliaIR.optimize!(mod, tm)` does the former (with the port:
Julia's C++ pass, with `ports=false`, can't be given a target machine); the pipeline's
text does the latter, except that in `jlopt`, `-mcpu` and `-mattr` also set the target of
CPUFeatures (see [CPUFeatures](cpu_features.md)).

## Recipes

Each Julia version has its own recipe (`src/pipeline/julia-1.*.jl`), written stage by
stage like that version's `pipeline.cpp`; a stage that a version didn't change is the
previous version's. The recipe is chosen by the running Julia's version:

| Julia | Recipe | Changes to the stages, compared with the previous recipe |
|:------|:-------|:-------------------------------------------------------|
| 1.10 | `Recipe{10}` | FinalLowerGC is a module pass; no GlobalsAA or GlobalDCE in the early optimizations; no RemoveJuliaAddrspaces; `sroa<preserve-cfg>` at level 1 |
| 1.11 | `Recipe{11}` | the options of 1.11; GlobalsAA and GlobalDCE; FinalLowerGC is a function pass; RemoveJuliaAddrspaces after LowerPTLS; `sroa<modify-cfg>` at level 1 |
| 1.12 | `Recipe{12}` | InferFunctionAttrs; no level-1 scalar optimizations; DSE before GVN after the GC lowering; no CombineMulAdd |
| 1.13 | `Recipe{13}` | SROA modifying the CFG, EarlyCSE and GlobalOpt in the early simplifications; eagerly invalidating function pass manager; a single loop pass manager with MemorySSA; `vector-combine<early>`; ExpandAtomicModify |
| 1.14, 1.15 | `Recipe{14}` | no CGSCC pass manager; IRCE with cleanup; CancellationLowering; EarlyCSE instead of GVN after the GC lowering; float2int and lower-constant-intrinsics in the vectorization; no sanitizers (stock builds) |

Julia 1.15 (master) has the same pipeline as 1.14, and uses 1.14's dialect. A Julia newer
than the newest recipe uses it until its pipeline changes.

How a pass is written in pipeline text depends on the LLVM that is loaded; spelling
helpers take care of that (for example, LLVM 15 has no CFG option for SROA, and
InstCombine verifies its fixpoint from LLVM 18 on unless told not to).

## Marker passes

Julia's pipeline brackets its stages by marker passes that do nothing, such as
`BeforeLICM` or `AfterVectorization`, so that LLVM's instrumentation can name them
(`-print-before=BeforeLICM`). `JuliaIR.register!` registers them under the same names.

## Passes without a port

Every pass of Julia's pipelines up to 1.15 is ported, so the rebuilt pipeline runs on any
LLVM that JuliaIR supports. A pass that a newer Julia adds can be named in a recipe by
its future port name before the port exists, with an entry in `JuliaIR.CPP_FALLBACKS`
that makes Julia's C++ pass run in its place (only on Julia's own LLVM).

## Differences from Julia's pipeline

The rebuilt pipeline prints like Julia's (as `print_pipeline` shows them), except:

- Julia adds pass managers that are empty (a CGSCC pass manager below level 2 up to
  1.13), which pipeline text can't express; the rebuilt pipeline leaves them out. Julia
  1.13 also builds a function pass manager that it never adds.
- Julia 1.14's IRCE with cleanup is a pass of its own, `jl-irce-with-cleanup`, where
  Julia's has no name.
- Julia's loop pass managers don't use BlockFrequencyInfo. Written as pipeline text
  (`loop-mssa(...)`), a loop pass manager that runs SimpleLoopUnswitch does on the LLVM
  versions whose pipeline parser enables it for that pass; this only makes a difference
  for code with profile data. And the target library info comes from the module's triple
  rather than the target machine's.
- `vector-combine<early>` (Julia's `VectorCombinePass(/*TryEarlyFoldsOnly=*/true)`)
  prints like the other `vector-combine`.
- Julia's pipeline invokes the callbacks of LLVM's extension points; JuliaIR's doesn't,
  as Julia registers none for its pipeline element.

## Testing

`test/pipeline.jl` compares the printed pipeline with Julia's `julia<...>` element at
every level, alone and with each option toggled, both with Julia's C++ passes and with
the ports, and checks on a few functions that the rebuilt pipeline with Julia's C++ passes optimizes exactly
like Julia's. The upstream fixture `pipeline-prints.ll` runs in `jlopt`, as do derived
copies of `pipeline-o*.jl`, which run the pipeline on the unoptimized IR of Julia's code
generator in `jlopt` (for the host CPU, like Julia's JIT) instead of in Julia. The
differential test compares the whole pipeline at every level with Julia's on the modules
of its corpus.
