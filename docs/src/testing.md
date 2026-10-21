# Testing

CI checks two contracts for every Julia version in `test/upstream/manifest.toml`:

| Contract | Configuration | Checks |
| --- | --- | --- |
| The ports behave like that Julia's C++ passes | JuliaIR and Julia's C++ passes on Julia's bundled LLVM | Upstream fixtures and differential comparisons on fixtures and generated IR |
| The ports process that Julia's IR on a newer LLVM | The same Julia dialect, with standalone LLVM 23 | Package tests, upstream fixtures, and generated IR through all optimization levels |

The `native` jobs run package tests on Linux, macOS and Windows. Linux also runs the
C++ comparisons for every version. The `compatibility` jobs run every version on
standalone LLVM, including library switching after JuliaIR has loaded. Released versions
use pinned binaries and fixture commits; nightlies use the fixtures from their build
commit. The workflow and local comparison script read the same version manifest.

Exact output matching is only meaningful with the same LLVM. Differences caused by
nondeterminism or backported improvements need narrow, documented exceptions; a passing
verifier alone does not establish equivalence. On newer LLVM, upstream expectations are
adapted for LLVM changes, and the generated-IR checks establish that the pipeline accepts
and produces valid IR. They do not establish identical optimization or runtime behaviour.

## Package tests

`Pkg.test()` runs:

- testsets for the API: dialects, option parsing, pass construction and registration, the
  `jlopt` driver, and the passes' Julia-level behaviour;
- a [lit](https://llvm.org/docs/CommandGuide/lit.html) suite in `test/lit`: `.ll` files
  with `RUN:` lines in the format of LLVM's and Julia's own tests, in which `opt` is
  `bin/jlopt`. lit comes from `LLVM_utils_unified_jll`, and so do `FileCheck` and LLVM's
  other test tools when the passes run on Julia's LLVM (with another library, see below);
  `python3` must be available;
- tests of the harness for Julia's own pass tests (below), on a synthetic checkout.

Each Julia version tests its own dialect, `JuliaIR.Dialect(VERSION)`. CI runs the
package tests on every supported version. In lit, `julia-1.X` selects a dialect's minor
version and `julia-ge-1.X` selects that version and later. Nightlies newer than the
known dialects use the newest known one. Restrict a test with
`REQUIRES: julia-1.10 || julia-1.11`, or select RUN lines and check prefixes with `%if`:

```
; RUN: %if julia-1.12 %{ opt -passes=jl-lower-exc-handlers -S %s | FileCheck %s %}
; RUN: opt -passes=jl-lower-simdloop -S %s | FileCheck %s --check-prefixes=CHECK,%if julia-ge-1.12 %{COMBINE%} %else %{NOCOMBINE%}
```

A misspelled feature would skip its lines silently, so a testset checks that every
`julia-*` feature under `test/lit` names a known version.

Set `JULIAIR_LEDGER` to a file to record which ports ran. Each invocation appends its
process ID, `pass`, pass name, Julia version and LLVM version. `jlopt` also records the
pipeline. This lets a RUN line verify that it used the port:

```
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=RemoveNI -S %s -o /dev/null
; RUN: FileCheck --check-prefix=LEDGER %s < %t.ledger
; LEDGER: pass jl-remove-ni julia=
```

Several processes may share a ledger, e.g. the workers of a test suite: each line is
appended with a single write to a file opened in append mode, so lines of concurrent
processes neither interleave nor overwrite each other on a local file system. Network file
systems such as NFS don't guarantee this.

## `jlopt`

`bin/jlopt` is an `opt`-compatible driver: it parses its input into a context with opaque
pointers, runs a pipeline that may contain this package's passes, and writes the result.
The names of Julia's C++ passes that this package ports (e.g. `AllocOpt`) are mapped to
the ports, other names are left to LLVM (including, when running on Julia's own LLVM,
Julia's C++ passes). `jlopt --help` lists its options. `JULIAIR_MAP_PASSES=0` disables
the mapping.

To use it outside the test suite, run it with a project that provides JuliaIR, e.g.
`julia --project=test bin/jlopt -passes=jl-remove-ni -S input.ll` (Julia 1.12 and later,
where `test` is a workspace of the package), or install it as an app (below).
`jlopt_bindir(dir)` in `test/litsetup.jl` writes an `opt` wrapper for the running Julia
and project into `dir`, which LLVM's `update_test_checks.py --opt-binary=dir/opt` can use
to (re)generate the checks of a test.

### Installing `jlopt` as an app

On Julia 1.12 and later, `jlopt` can also be installed as a [Pkg
app](https://pkgdocs.julialang.org/v1/apps/), a command on the `PATH` like `opt`. Apps
are experimental in Pkg, and their commands and behaviour may still change. JuliaIR isn't
registered yet, so add it by URL, or develop a checkout:

```
pkg> app add https://github.com/JuliaLLVM/JuliaIR.jl
pkg> app develop /path/to/JuliaIR.jl
```

Pkg writes the `jlopt` command into `~/.julia/bin`, which you need to add to your `PATH`
yourself. `app add` installs the package into an environment of its own,
`~/.julia/environments/apps/JuliaIR`; `app develop` runs the checkout, with its
`Project.toml` and manifest. `app develop` instantiates the checkout first, which with
JuliaIR's workspace also installs the dependencies of the tests and the docs.

The command runs the Julia that installed it, and `jlopt` processes IR of the running
Julia's version: an app installed with Julia 1.12 is a driver for the IR of 1.12. To
work on another version's IR, install it again with that Julia (the command of the last
installation wins). The command that Pkg 1.12 and 1.13 write also runs the Julia that
the environment variable `JULIA_APPS_JULIA_CMD` names, if it is set, which picks the
version per run instead (the environment the app runs in must then work with that
Julia too, e.g. a checkout with a manifest per Julia version).

That command passes the arguments before a `--` to Julia rather than to `jlopt`, e.g.
`jlopt --threads=4 -- -passes=jl-remove-ni -S in.ll`; to give `jlopt` itself a `--`,
write another one before it. Both behaviours are Pkg's and may change with it.

To run the passes on a standalone LLVM, as described below, set LLVM.jl's `libLLVM`
preference in the `LocalPreferences.toml` of the environment the app runs in: of
`~/.julia/environments/apps/JuliaIR` after `app add`, of the checkout after
`app develop`.

## Julia's own pass tests

`test/upstream/run.jl` runs the tests in `test/llvmpasses` of a JuliaLang/julia checkout
with `jlopt` standing in for `opt`. Most fixtures run unchanged; deviations have patches. Which fixtures are relevant to this package,
and how they run, is recorded in `test/upstream/manifest.toml`. Released versions pin
a release commit. Nightlies use their build commit (`Base.GIT_VERSION_INFO.commit`) so
the binary and fixtures match. A prerelease newer than every pin uses the newest pin's
rules if that pin has no fixed commit.
Every file in the checkout must be in the manifest, as one of:

- `run`: the fixture runs, with Julia's pass names mapped to the ports. The harness checks
  in each test's ledger that every port in its pipelines ran;
- `skip`: it will run once the ports listed under `missing` exist (the harness fails once
  they do, so that it is enabled);
- `exclude`: it tests something this package does not port (Julia's code generator,
  or Julia's pipeline as a whole on code that Julia compiles itself);
- `override`: a derived copy runs, with a reviewed patch from `test/upstream/derived`
  applied. The harness fails if the pristine fixture passes too;
- `derived`: a copy runs that tests a port instead of what the fixture tests, with a
  patch from `test/upstream/derived` applied, e.g. `pipeline-o*.jl`, which run Julia's
  pipeline, rebuilt from the ports, in `jlopt` instead of in Julia's JIT. The copy must
  run a port.

RUN lines that use typed pointers (`--opaque-pointers=0`) are always skipped; legacy pass
manager lines with opaque pointers (Julia 1.10) are translated.

```
git clone --filter=blob:none --no-checkout https://github.com/JuliaLang/julia julia-src
git -C julia-src sparse-checkout set --cone test/llvmpasses test/testhelpers
git -C julia-src checkout <commit from the manifest>
julia +1.12 --project=test test/upstream/run.jl julia-src            # the ports
julia +1.12 --project=test test/upstream/run.jl julia-src --reference      # Julia's passes
julia +1.12 --project=test test/upstream/run.jl julia-src --report   # coverage table
```

For a nightly build (`nightly` for master, `1.14-nightly` for the release branch),
check out the commit it reports instead:

```
git -C julia-src checkout $(julia +nightly -e 'print(Base.GIT_VERSION_INFO.commit)')
julia +nightly --project=test test/upstream/run.jl julia-src
```

The Julia executable must match the fixture pin. By default the ports run on its
bundled LLVM; selecting another library changes the LLVM version, not the dialect. On Julia 1.10 and
1.11, which don't support workspaces, first run
`julia --project=test -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'`.

`--reference` runs every fixture that does not test the code generator with Julia's own passes
instead of the ports. It checks `jlopt` and the harness against upstream's expectations,
independently of the ports.

When updating a release pin, change its `commit`, `julia` and `llvm` fields, then account
for new or changed fixtures. CI reads these fields directly. A minor version's first
release needs these fields too.

Nightly pins have no fixed commit. New fixtures, stale overrides and other changes
that the manifest does not cover make the harness fail. After master bumps its version,
it can use the newest nightly pin until it gets its own; the release branch follows
`1.X-nightly` until its first release. Add a version to `JuliaIR.KNOWN_MINORS` when its
IR first differs from its predecessor's.

## Processing older dialects with standalone LLVM

The Julia executable selects the dialect and produces the input IR. LLVM.jl selects the
library that runs the ports, and the upstream harness adapts to the library it finds.
Set LLVM.jl's preference in each environment that loads it (`.`, `test`, and
`test/differential` for these commands):

```toml
[LLVM]
libLLVM = "/path/to/libLLVM-standalone-23.so"
```

Set `JULIAIR_LLVM_TOOLS` to the matching LLVM tools directory, then run the same tests:

```
julia --project -e 'using Pkg; Pkg.test()'
julia --project=test test/upstream/run.jl julia-src
```

Tests requiring Julia's C++ passes or type lowering skip when those are unavailable.
The harness also lists skipped RUN lines that require an unported C++ pass. On a
different LLVM version, it skips upstream whole-pipeline output checks: LLVM's own
optimizations change too. Unknown pass names still fail.

The generated corpus fills part of that pipeline coverage gap:

```
julia --project=test/differential test/differential/corpus.jl corpus
julia --project=test test/compatibility/run.jl corpus
```

`corpus.jl` obtains IR from the running Julia. The compatibility driver runs the ports'
whole pipeline at levels 0 through 3 and verifies the results. It restores the source
data layout after parsing, as required when carrying Julia IR to a newer LLVM. CI
creates the corpus before selecting standalone LLVM, keeping input generation separate
from processing it.

GPUCompiler selects another library after JuliaIR has loaded with Julia's LLVM. Test
that path separately, before setting preferences:

```
JULIAIR_TEST_LIBRARY=/path/to/libLLVM-standalone-23.so julia --project -e 'using Pkg; Pkg.test()'
```

This runs the in-process tests after switching libraries, catching cached intrinsic IDs
and other state tied to the original LLVM. The preference-selected suite also tests
subprocesses, lit, and IR crossing between libraries. CI runs both configurations.

### LLVM compatibility patches

Newer LLVM versions upgrade old constructs and print some constants differently.
`test/upstream/llvm-compat/llvm<major>/<minor>` contains the corresponding fixture
patches. They apply after any port-specific patch in `test/upstream/derived`. A
`<fixture>.after-port.patch` applies to that already-patched fixture; the plain
`<fixture>.patch` applies to its pristine upstream form.

The harness checks that each patch is needed by running the fixture without it.
An unnecessary patch or a patch for an absent fixture fails the run. Generate the LLVM
patches from reviewed rules rather than editing them by hand:

```
julia --project=test test/upstream/derive.jl julia-src --llvm 23
julia --project=test test/upstream/derive.jl julia-src --llvm 23 --check
```

The clone must contain all pinned commits. Patches are generated for pins whose bundled
LLVM is older than the requested version.

The script applies a list of rules, one per change of LLVM. Each rule names the LLVM
change (the version, the upstream pull request) and how Julia's own fixtures were adapted
to it when Julia moved to that LLVM, which the rule reproduces; it lists the fixtures it
applies to and how many lines it changes in each, at each pin, and any other count is an
error. Rules rewrite only the FileCheck lines of the check prefixes that RUN lines with
opaque pointers use, except for input repairs, which say so. For LLVM 23:

| rule | LLVM | change |
|---|---|---|
| `memoryssa-alias` | 16 | `print<memoryssa>` no longer prints the alias result of an access (`MayAlias`) |
| `lifetime-size` | 22 | `llvm.lifetime.start/end` lost their size argument |
| `masked-align` | 22 | the alignment of `llvm.masked.load/gather` became an `align` attribute |
| `target-features-sign` | 22 | the verifier requires `+`/`-` in `"target-features"`; an input repair of `multiversioning-clone-only.ll` |
| `splat` | 20 | vector constants of equal elements print as `splat (...)` |
| `null-pointer-splat` | 23 | vectors of null pointers print as `splat (ptr null)` instead of `zeroinitializer` |
| `decimal-fp` | 23 | `half` and `bfloat` constants print in decimal |

What the passes produce is never rewritten: the rules change what the fixtures expect,
the same way upstream changed them.

### Checking the LLVM adaptations independently

Before selecting standalone LLVM, run:

```
julia --project=test test/upstream/run.jl julia-src --reference-llvm /path/to/newer/opt
```

This runs Julia's C++ passes on their bundled LLVM, then reprints their output with the
newer `opt` and checks it with the adjacent `FileCheck`. Only the LLVM compatibility
patches apply, so a port-specific bug cannot justify changing an upstream expectation.
The `compatibility` job runs this check for every Julia version before testing the ports.

Bitcode passes through unchanged for the newer LLVM to read. Stderr diagnostics are
not reprinted. The harness lists patches affecting only stderr as unvalidated by this
check; the standalone fixture run still checks those expectations. This check validates
representation changes, not the newer LLVM's optimizations.

## Differential test against Julia's C++ passes

`test/differential/run.jl` compares each port with the C++ pass it ports, both running in
the same process on the running Julia's LLVM, on many modules: for every module and pass,
it runs the C++ pass and the port on independent copies of the module, behind the same
pipeline of Julia's C++ passes (a *prefix*: e.g. none, or what precedes the pass in
Julia's pipeline), and compares the results. Since the passes process the running
Julia's IR, each Julia version compares its own C++ passes with the ports, on IR it
generated itself. The C++ passes are built against Julia's own LLVM (in
`libjulia-codegen`), so the differential can't compare the ports on a newer LLVM.

The comparison covers printed IR, verification results, errors and optimization
remarks. It removes local value names and substitutes attribute group contents for
their numbers. Both implementations run in a worker process that restarts after a
crash or timeout. For GCInvariantVerifier, it compares the C++ abort diagnostic with
the port's exception.

Each comparison is one of:

- *identical*;
- *excepted*: the outputs differ only in ways recorded in
  `test/differential/exceptions.toml`. An entry there names the pass, optionally the
  inputs (a glob), dialects (Julia minor versions; a newer Julia has the newest known
  one's, so `julia = ["1.14"]` also applies to 1.15) and prefix it applies to, the
  reason, a documentation or upstream reference, and a rewrite of one side's output.
  The rewrite matches lines with a regex, including status lines for errors and invalid
  IR, and replaces the matched text or deletes the line. The outputs must be identical
  after all applicable rewrites; the rest of the module is still compared. A deviation that a
  regex can't describe, like the order of GC frame slots, can have a named
  canonicalization of both outputs instead (`CANONICALIZATIONS` in `run.jl`);
- *accepted*: not compared, for the few inputs where a recorded deviation changes too
  much to be rewritten away (the C++ pass produces invalid IR, or the port's analysis
  differs by decision). Such an entry names its inputs and accepts the difference when a
  line of the C++ output matches (e.g. the verifier's message, or the allocation the C++
  keeps) and the port's output is a module that verifies;
- *different*: a finding, reported with the diff, which makes the run fail.

Inputs that don't parse or verify, inputs on which the prefix pipeline fails (listed with
the error), and, for passes that return early without them, inputs in which (after the
prefix) nothing names what the pass works on, are counted but not compared. A pass that
was compared on no input at all fails the run. The report also counts how often the C++
pass changed the module at all, and lists entries of `exceptions.toml` that matched
nothing.

The inputs are `.ll` files or directories of them:

- Julia's own pass tests (`test/llvmpasses` of the checkout pinned for the Julia version
  in `test/upstream/manifest.toml`, or of the nightly build's commit), every one that
  parses;
- `test/differential/corpus.jl` writes the unoptimized IR that the running Julia
  generates (`code_llvm(...; optimize=false, raw=true, dump_module=true)`) for a list of
  functions with GC stacks, allocations and write barriers, `@simd` loops,
  `GC.@preserve`, atomics, exceptions, `Float16` arithmetic, closures and (from Julia
  1.14) cancellation points, with and without debug information;
- `test/differential/gpucompiler/corpus.jl` writes GPUCompiler's modules for PTX, GCN,
  SPIR-V, Metal and native code without the Julia runtime, before optimization
  (`GPUCompiler.compile(:llvm, job)` with `optimize=false, cleanup=false`): the IR on
  which GPUCompiler runs Julia's passes, except that the target's final IR fixups
  (`finish_ir!`), which follow the optimizer, have run too. Kernels that GPUCompiler
  can't compile for a target are skipped (all.sh reports the number of modules per
  target), and since GPUCompiler can crash for one target (GCN on Julia 1.10 and 1.11),
  each target is best generated in its own process. The script has its own environment,
  `test/differential/gpucompiler`, as GPUCompiler brings its own LLVM.jl; only the IR
  text crosses over;
- `test/differential/inputs`: hand-written modules for what the generated IR lacks, like
  GC invariant violations for GCInvariantVerifier.

```
julia +1.12 --project=test/differential test/differential/corpus.jl corpus
julia +1.12 --project=test/differential/gpucompiler -e 'using Pkg; Pkg.instantiate()'
for t in ptx gcn spirv metal native; do
    julia +1.12 --project=test/differential/gpucompiler test/differential/gpucompiler/corpus.jl gpu $t
done
julia +1.12 --project=test/differential test/differential/run.jl --out results \
    julia-src/test/llvmpasses corpus gpu test/differential/inputs
```

`run.jl --pass AllocOpt` restricts the run to one pass (Julia's name). Both outputs of
every difference, excepted or not, and their diff are in `results/diffs` (the report
shows what remains of an unexplained one after the exceptions' rewrites); `run.jl
--report --out results ...` reports an earlier run again, e.g. after editing
`exceptions.toml`. On Julia 1.10 and 1.11, which have no workspaces, develop the package
into the environment first (`Pkg.develop(path=".")`).

`test/differential/all.sh WORKDIR` does all of this for every Julia version (juliaup
the pinned releases and nightly channels from the manifest, or those given): it checks out the
fixtures, sets up the environments, generates the corpora and runs the comparison, one
version at a time, and summarizes the counts in `WORKDIR/summary.txt`.

CI runs the comparison for every supported Julia version in the Linux `native` jobs,
on upstream fixtures, a fresh `code_llvm` corpus and `test/differential/inputs`.
GPUCompiler modules are currently generated only by the local comparison script. Any unexplained difference fails the job.

To compare another port, add a `PassSpec` to `test/differential/passes.jl`: Julia's name
of the pass, whether it is a module, function or loop pass, the prefixes to run it
behind, and, if needed, a regex that finds what the pass works on in a module (only for
a pass whose C++ returns early without it), a preparation of the inputs (e.g. the
GPU-like inputs of `jl-late-gc-cleanup`), the names of its remarks, or that the C++ pass
aborts on rejected input. A pass with options is compared in each configuration by a
`PassSpec` per configuration, each with its own name (the key of its exceptions) and the
pipeline elements of both sides with the options, like `GCInvariantVerifier<strong>`.

Julia's whole pipeline is compared the same way, at each level: `julia<level=N>` with
Julia's C++ passes against the pipeline that JuliaIR rebuilds from the ports. The
deviations recorded for the ports it runs apply to it as well (`inherits`); its own
entries in `exceptions.toml` cover those whose rewrite differs once the whole pipeline
ran. Two deviations that would hide everything they touch are aligned instead: modules
without a triple get the host's (LowerPTLS's port reads the host's thread pointer where
the C++ reaches `llvm_unreachable`), and before Julia 1.14, levels 2 and 3 compare with
the rebuilt pipeline of Julia's C++ passes but FinalLowerGC's port (whose non-volatile
frame `memset` lets later passes remove stores to the frame).
