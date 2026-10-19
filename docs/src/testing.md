# Testing

The passes are tested at three levels.

## Package tests

`Pkg.test()` runs:

- testsets for the API: dialects, option parsing, pass construction and registration, the
  `jlopt` driver, and the passes' Julia-level behaviour;
- a [lit](https://llvm.org/docs/CommandGuide/lit.html) suite in `test/lit`: `.ll` files
  with `RUN:` lines in the format of LLVM's and Julia's own tests, in which `opt` is
  `bin/jlopt`. lit, `FileCheck` and LLVM's other test tools come from
  `LLVM_utils_unified_jll`; `python3` must be available;
- tests of the harness for Julia's own pass tests (below), on a synthetic checkout.

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
Julia's C++ passes). `jlopt --help` lists its options. `JULIAIR_JULIA` sets the default
dialect, `JULIAIR_MAP_PASSES=0` disables the mapping.

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
versions, and the commit of a nightly build for the development version. Every file in the
checkout must be in the manifest, as one of:

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

The Julia that runs the harness must be the one the pin is for (it runs the passes on its
own LLVM, and Julia's C++ passes for the fixtures that combine them). On Julia 1.10 and
1.11, which don't support workspaces, first run
`julia --project=test -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'`.

`--cpp` runs every fixture that does not test the code generator with Julia's own passes
instead of the ports. It checks `jlopt` and the harness against upstream's expectations,
independently of the ports.

When a new patch release is tagged, or the nightly build moves on, update the pin's
`commit` and `julia` in the manifest and the matching `julia_ref` in CI, and account for
new or changed fixtures.
