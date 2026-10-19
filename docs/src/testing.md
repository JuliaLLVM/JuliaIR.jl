# Testing

The passes are tested at three levels: the package tests, Julia's own pass tests, and a
differential test against Julia's C++ passes, which is not part of `Pkg.test()`.

## Package tests

`Pkg.test()` runs:

- testsets for the API: dialects, option parsing, pass construction and registration, the
  `jlopt` driver, and the passes' Julia-level behaviour;
- a [lit](https://llvm.org/docs/CommandGuide/lit.html) suite in `test/lit`: `.ll` files
  with `RUN:` lines in the format of LLVM's and Julia's own tests, in which `opt` is
  `bin/jlopt`. lit, `FileCheck` and LLVM's other test tools come from
  `LLVM_utils_unified_jll`; `python3` must be available;
- tests of the harness for Julia's own pass tests (below), on a synthetic checkout.

The passes process the IR of the running Julia, so each Julia version tests its own
dialect, and CI runs the tests on every supported version. The testsets expect what the
running Julia's dialect does where that matters (`JuliaIR.Dialect(VERSION)`). In the lit
suite, the lit feature `julia-1.X` names the running Julia's minor version (that of its
dialect: a nightly newer than the newest known version has that version's), and
`julia-ge-1.X` holds for 1.X and later. A test for some versions only says
`REQUIRES: julia-1.10 || julia-1.11`; a RUN line for some versions is wrapped in lit's
`%if`, which also selects the check prefixes of a version:

```
; RUN: %if julia-1.12 %{ opt -passes=jl-lower-exc-handlers -S %s | FileCheck %s %}
; RUN: opt -passes=jl-lower-simdloop -S %s | FileCheck %s --check-prefixes=CHECK,%if julia-ge-1.12 %{COMBINE%} %else %{NOCOMBINE%}
```

A misspelled feature would skip its lines silently, so a testset checks that every
`julia-*` feature under `test/lit` names a known version.

A RUN line can prove that a port ran, rather than Julia's C++ pass of the same name, with
the ledger: when the environment variable `JULIAIR_LEDGER` names a file, every pass
invocation appends a line to it (process id, `pass`, the pass name, the Julia dialect and
the LLVM version), and `jlopt` appends one with the pipeline it runs:

```
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=RemoveNI -S %s -o /dev/null
; RUN: FileCheck --check-prefix=LEDGER %s < %t.ledger
; LEDGER: pass jl-remove-ni julia=
```

## `jlopt`

`bin/jlopt` is an `opt`-compatible driver: it parses its input into a context with opaque
pointers, runs a pipeline that may contain this package's passes, and writes the result.
The names of Julia's C++ passes that this package ports (e.g. `AllocOpt`) are mapped to
the ports, other names are left to LLVM (including, when running on Julia's own LLVM,
Julia's C++ passes). `jlopt --help` lists its options. `JULIAIR_MAP_PASSES=0` disables
the mapping.

To use it outside the test suite, run it with a project that provides JuliaIR, e.g.
`julia --project=test bin/jlopt -passes=jl-remove-ni -S input.ll` (Julia 1.12 and later,
where `test` is a workspace of the package). `jlopt_bindir(dir)` in `test/litsetup.jl`
writes an `opt` wrapper for the running Julia and project into `dir`, which LLVM's
`update_test_checks.py --opt-binary=dir/opt` can use to (re)generate the checks of a test.

## Julia's own pass tests

`test/upstream/run.jl` runs the tests in `test/llvmpasses` of a JuliaLang/julia checkout,
unchanged, with `jlopt` standing in for `opt`. Which fixtures are relevant to this package,
and how they run, is recorded in `test/upstream/manifest.toml`, together with the commit
whose fixtures are used for each Julia minor version: the release tag for released
versions. For the development version, the fixtures are those of the commit that the
running nightly build was built from (`Base.GIT_VERSION_INFO.commit`), so that the binary
and its tests always match. Every file in the checkout must be in the manifest, as one of:

- `run`: the fixture runs, with Julia's pass names mapped to the ports. The harness checks
  in each test's ledger that every port in its pipelines ran;
- `skip`: it will run once the ports listed under `missing` exist (the harness fails once
  they do, so that it is enabled);
- `exclude`: it tests something this package does not port (CPU-only passes not ported
  yet, Julia's code generator);
- `override`: a derived copy runs, with a reviewed patch from `test/upstream/derived`
  applied. The harness fails if the pristine fixture passes too.

RUN lines that use typed pointers (`--opaque-pointers=0`) are always skipped; legacy pass
manager lines with opaque pointers (Julia 1.10) are translated.

```
git clone --filter=blob:none --no-checkout https://github.com/JuliaLang/julia julia-src
git -C julia-src sparse-checkout set --cone test/llvmpasses test/testhelpers
git -C julia-src checkout <commit from the manifest>
julia +1.12 --project=test test/upstream/run.jl julia-src            # the ports
julia +1.12 --project=test test/upstream/run.jl julia-src --cpp      # Julia's passes
julia +1.12 --project=test test/upstream/run.jl julia-src --report   # coverage table
```

For the nightly build, check out the commit it reports instead:

```
git -C julia-src checkout $(julia +nightly -e 'print(Base.GIT_VERSION_INFO.commit)')
julia +nightly --project=test test/upstream/run.jl julia-src
```

The Julia that runs the harness must be the one the pin is for (it runs the passes on its
own LLVM, and Julia's C++ passes for the fixtures that combine them). On Julia 1.10 and
1.11, which don't support workspaces, first run
`julia --project=test -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'`.

`--cpp` runs every fixture that does not test the code generator with Julia's own passes
instead of the ports. It checks `jlopt` and the harness against upstream's expectations,
independently of the ports.

When a new patch release is tagged, update the pin's `commit`, `julia` and `llvm` in the manifest
and the matching `julia_ref` in CI, and account for new or changed fixtures. The
development version's entries apply to whatever master is current: when the nightly
build moves on and a fixture appears or changes in a way the manifest doesn't account for
(an override that no longer applies, a fixture of a port that now passes), the harness
fails, and the manifest needs updating.

## Julia's pass tests on a newer LLVM (mode B)

The passes are meant to run on a newer LLVM than the one of the Julia version whose IR
they process: GPUCompiler can load a standalone, newer libLLVM next to Julia's. Mode B
runs Julia's own pass tests in that configuration: the running Julia is still the one of
the pin (it produces the IR, and its fixtures are used), but the ports run on whatever
library LLVM.jl has loaded.

```
julia +1.12 --project=test test/upstream/run.jl julia-src --mode B
```

Two things differ from mode A, the default run of the previous section:

- A standalone LLVM doesn't have Julia's C++ passes. RUN lines whose pipeline names one
  of them that isn't ported (`FinalLowerGC`, `JuliaMultiVersioning`, `julia`, ...) are
  skipped, and the harness lists them. Mode B skips them on Julia's own LLVM too, so
  that a run there (a dry run of mode B) tests the same lines. A pass name that no LLVM
  knows is not skipped: the line fails.
- A newer LLVM prints the same IR differently: it upgrades old constructs when it reads
  a module, and prints some constants in a new syntax. The fixtures expect the spelling
  of the pin's LLVM, so they get a second layer of patches,
  `test/upstream/derived-B/llvm<major>/<minor>/<fixture>.patch`, for the major version
  of the library that runs. Mode B applies a fixture's mode-A patch first (if it has
  one), then its mode-B patch. For a fixture with a mode-A patch, the mode-B patch is
  `<fixture>.after-A.patch`, which applies on top of the mode-A patch; the plain
  `<fixture>.patch` always applies to the pristine fixture.

As in mode A, every patch must be needed: the harness also runs each patched fixture
without its mode-B patch, and a fixture with a mode-A override with the mode-B patch
alone, and fails if either passes. A patch file for a fixture that the pin doesn't have
is an error.

### Where the mode-B patches come from

The mode-B patches are generated by `test/upstream/derive.jl`, never written by hand,
and committed so that they can be reviewed:

```
julia +1.12 --project=test test/upstream/derive.jl julia-src --llvm 23           # write
julia +1.12 --project=test test/upstream/derive.jl julia-src --llvm 23 --check   # compare
```

`julia-src` is a clone of JuliaLang/julia that has the pinned commits (the sparse clone
above will do). The patches are generated for the pins whose `llvm` (the major version
of the LLVM their Julia uses, in the manifest) is older than the one given.

The script applies a list of rules, one per change of LLVM. Each rule names the LLVM
change (the version, the upstream pull request) and how Julia's own fixtures were adapted
to it when Julia moved to that LLVM, which the rule reproduces; it lists the fixtures it
applies to and how many lines it changes in each, at each pin, and any other count is an
error. Rules rewrite only the FileCheck lines of the check prefixes that RUN lines with
opaque pointers use, except for input repairs, which say so. For LLVM 23:

| rule | LLVM | change |
|---|---|---|
| `lifetime-size` | 22 | `llvm.lifetime.start/end` lost their size argument |
| `masked-align` | 22 | the alignment of `llvm.masked.load/gather` became an `align` attribute |
| `target-features-sign` | 22 | the verifier requires `+`/`-` in `"target-features"`; an input repair of `multiversioning-clone-only.ll` |
| `splat` | 20 | vector constants of equal elements print as `splat (...)` |
| `null-pointer-splat` | 23 | vectors of null pointers print as `splat (ptr null)` instead of `zeroinitializer` |
| `decimal-fp` | 23 | `half` and `bfloat` constants print in decimal |

What the passes produce is never rewritten: the rules change what the fixtures expect,
the same way upstream changed them.

### The upgrade oracle

Whether the patches describe the newer LLVM, and nothing about the ports, is checked
against Julia's own passes:

```
julia +1.12 --project=test test/upstream/run.jl julia-src --cpp --reprint <newer opt>
```

runs the fixtures with Julia's C++ passes on the pin's own LLVM, as `--cpp` does, but
every textual IR that `opt` writes, to stdout or to a file (`-o`), is re-printed by the
given `opt` of the newer LLVM (e.g. from `LLVM_full_jll`), and the fixtures are checked
with the `FileCheck` next to it. The fixtures get their plain mode-B patches, not the
mode-A ones, which are about the ports. Bitcode output is passed on as it is (a newer LLVM
upgrades it when reading it), and so is what `opt` prints on stderr: the harness lists
the RUN lines whose checks read stderr (`print<memoryssa>`, diagnostics), which therefore
see the pin's printing. A patch that isn't needed fails here too.

The oracle passes at every pin with the patches of `derived-B/llvm23`, and the
development version, whose Julia already uses LLVM 23, needs none. Mode B validates the
composed patches against the ports.

## Differential test against Julia's C++ passes

`test/differential/run.jl` compares each port with the C++ pass it ports, both running in
the same process on the running Julia's LLVM, on many modules: for every module and pass,
it runs the C++ pass and the port on independent copies of the module, behind the same
pipeline of Julia's C++ passes (a *prefix*: e.g. none, or what precedes the pass in
Julia's pipeline), and compares the results. Since the passes process the running
Julia's IR, each Julia version compares its own C++ passes with the ports, on IR it
generated itself. The C++ passes exist only in Julia's own LLVM, so unlike mode B, the
differential can't compare the ports on a newer LLVM.

The comparison is of the printed module, after removing the names of local values (so
that LLVM numbers them) and replacing the numbers of attribute groups by their contents;
of whether the module verifies; of the errors either side throws (the C++ passes abort
the process on some inputs, so they run in a worker process that is restarted after a
crash, and a pass that runs for too long counts as hung); and, for the passes that emit
optimization remarks, of the remarks. A pass with a verdict instead of output
(GCInvariantVerifier) is compared by the messages of the C++ pass, which aborts, and of
the port's exception.

Each comparison is one of:

- *identical*;
- *excepted*: the outputs differ only in ways recorded in
  `test/differential/exceptions.toml`. An entry there names the pass, optionally the
  inputs (a glob), Julia versions and prefix it applies to, the reason and the plan
  decision behind it, and a rewrite of one side's output: a regex over its lines (the
  status lines for errors and invalid IR included) and what the matched text becomes,
  or nothing to delete those lines. A difference is excepted only if the outputs are
  identical after the rewrites of the entries that apply, so an entry allows exactly the
  change it describes and the rest of the module is still compared. A deviation that a
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
into the environment first (`Pkg.develop(path=".")`, and LLVM.jl from the package's
`[sources]`).

`test/differential/all.sh WORKDIR` does all of this for every Julia version (juliaup
channels 1.10 to nightly, or those given): it checks out the fixtures, sets up the
environments, generates the corpora and runs the comparison, one version at a time, and
summarizes the counts in `WORKDIR/summary.txt`. While JuliaIR needs an unreleased
LLVM.jl, `LLVMEXTRA_BUILDS` names a directory of `libLLVMExtra` builds per LLVM version,
which it sets as the preference for each run.

CI runs the comparison on Julia 1.12 and on nightly, in the `upstream` job: on the
fixtures that job checks out, a fresh `code_llvm` corpus and `test/differential/inputs`,
without the GPUCompiler modules. Any unexplained difference fails the job.

To compare another port, add a `PassSpec` to `test/differential/passes.jl`: Julia's name
of the pass, whether it is a module, function or loop pass, the prefixes to run it
behind, and, if needed, a regex that finds what the pass works on in a module (only for
a pass whose C++ returns early without it), a preparation of the inputs (e.g. the
GPU-like inputs of `jl-late-gc-cleanup`), the names of its remarks, or that the C++ pass
aborts on rejected input. A pass with options is compared in each configuration by a
`PassSpec` per configuration, each with its own name (the key of its exceptions) and the
pipeline elements of both sides with the options, like `GCInvariantVerifier<strong>`.
