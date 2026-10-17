# Hand-off: JuliaIR.jl

State of the implementation of `~/Julia/plans/llvm-middleend/PLAN.passes.md` (the plan;
read it first, including its Log). This file says where things are and how to continue.

## State per item

| Item | State | Commits |
|------|-------|---------|
| S0 skeleton, CI, docs | done | 7807051, 3a6e8d8 |
| S1 dialect descriptor, registration | done | 5dbe95f, ee09d37, 0ccc23a |
| S2 jlopt, lit suite, ledger, RemoveNI | done | 11db665, 335d996, e52f565, 83f7263 |
| S3 upstream harness, manifest (mode A) | done | b97b57a, e39a309, 3614dd5, 33ad510 |
| S4 AllocOpt | port done; open: E1, S12, S13 | f728275, 5df7c8c |

S4 details: `src/allocations.jl` (escape analysis, shared with the future JuliaLICM port)
and `src/passes/alloc_opt.jl`. Every upstream AllocOpt fixture passes in mode A on every
pin. Not done: `PromoteMemToReg` on the reference slots of split allocations (LLVM.jl has
no wrapper; plan item E1). Until then `test/upstream/derived/{1.13,1.14}/alloc-opt-pass.ll.patch`
weakens the one CHECK that depends on it; once E1 lands, call it in `finish_split!` and the
harness will report those overrides as stale. The design choices (which historical
behaviours are kept per Julia version, which fixes are applied to every version) are in
the plan's Log entry for S4 and in `docs/src/index.md`.

Nothing is pushed; there is no remote. Tim creates `JuliaLLVM/JuliaIR.jl` and pushes.

## Layout

- `src/dialect.jl`: `Dialect` (what each Julia version's IR looks like; passes branch on
  its fields). `src/registration.jl`: option parsing (`jl-x<julia=1.12;fp16=demote>`),
  `PassDefinition`/`define_pass`, `custom_pass` (the LLVM.jl pass with defaults),
  `register!`, `require_opaque`, `library_facts`, the ledger (`JULIAIR_LEDGER`).
  `src/jlopt.jl`: the `opt`-compatible driver. `src/passes/<pass>.jl`: one file per pass,
  each ending with `define_pass(...)` and its `JuliaIR.<Name>Pass` constructor.
- `bin/jlopt`: executable wrapper (`using JuliaIR; exit(JuliaIR.jlopt_main(ARGS))`).
- `test/lit/`: the package's lit tests (`.ll` with RUN lines), `lit.cfg.py`, the shared
  `common.cfg.py` (PATH, library path, env passthrough, Windows substitution), and
  `juliair_lit.py` (per-test ledger format, used by the upstream harness).
- `test/litsetup.jl`: finds Python, writes the `opt` wrapper, runs lit.
- `test/upstream/`: `run.jl` (harness), `manifest.toml` (pins + every fixture),
  `derived/<minor>/*.patch` (overrides).

## How to run each test tier (pegasus)

- Package tests: `julia +<ver> --project -e 'using Pkg; Pkg.test()'` (1.10, 1.11, 1.12,
  1.13, nightly). Each ~1 min. Test from a copy of the tree when running several versions
  at once (Manifest.toml is shared between versions, and Pkg.test must not run on a tree
  you edit): rsync the tree (without `.git`, `Manifest*.toml`) to a scratch dir per
  version. At most 3 suites at once on pegasus.
- Iteration: `jld --test eval 'using Test, JuliaIR'` then `jld --test run test/<file>.jl`
  (Julia 1.13 daemon, test workspace). `jld --test restart` after adding files/includes.
- Lit suite alone: `include("test/litsetup.jl")`, then `run_lit("test/lit"; python=find_python(),
  params=lit_params(; exec_root=mktempdir(), bindir=jlopt_bindir(mktempdir())))`.
- Upstream fixtures: sparse clone of JuliaLang/julia at the pin (see docs/src/testing.md;
  locally: `git clone -q --shared --no-checkout ~/Julia/src/julia DIR`,
  `git -C DIR sparse-checkout set --cone test/llvmpasses test/testhelpers`,
  `git -C DIR checkout <commit>`; this doesn't modify ~/Julia/src/julia), then
  `julia +<ver> --project=test test/upstream/run.jl DIR` (ports) and `... --cpp` (Julia's
  passes; checks jlopt/harness) and `... --report`. On 1.10/1.11 first
  `julia --project=test -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'`
  (in a tree copy; it writes test/Manifest.toml).
- Docs: `julia +1.12 --project=docs docs/make.jl`.
- update_test_checks.py: not in any JLL; copy `llvm/utils/update_test_checks.py` and
  `UpdateTestChecks/` from an LLVM source tree, write a wrapper with `jlopt_bindir(dir)`,
  run `python3 update_test_checks.py --opt-binary=dir/opt test.ll`.

## Next steps

1. E1 in LLVM.jl (worktree `~/Julia/pkg/LLVM-alloc-opt-api`, branch `tb/alloc-opt-api`,
   `PR.md`, never push): `PromoteMemToReg(allocas, domtree)`; the other E1 items are
   optional (alloca AS and allockind/retalign are read in Julia; intrinsic redeclaration
   uses `LLVM.Function(mod, intr, ft)`, which exists).
2. S5 (PropagateJuliaAddrspaces, DemoteFloat16, GCInvariantVerifier), then S6.
3. A differential check like the one used for S4 (C++ pass vs port, in-process, on every
   pinned fixture plus `code_llvm(...; optimize=false)` output) is cheap and found the
   only real differences; S12 should formalize it with GPUCompiler's kernels.

## Traps

- LLVM.jl 10 exports little: `using LLVM, LLVM.IR, LLVM.Build, LLVM.Passes, LLVM.Analysis`
  and `using LLVM: API`; `LLVM.Target`/`LLVM.TargetMachine` are not exported anywhere.
  Properties: `mod.datalayout`, `mod.triple`, `mod.name`, `v.name`.
- `JuliaIR.register!` is not `LLVM.register!` (different arity; don't extend LLVM's).
- `ignorestatus(pipeline(...))` fails before Julia 1.13: use `pipeline(ignorestatus(cmd); ...)`.
- lit test formats must live in an importable module (`juliair_lit.py`): classes defined
  in a lit config can't be pickled to lit's workers. Run lit with `python -I -B`, or
  Python 3.14's forkserver workers write `__pycache__` into the source tree.
- LLVM_utils_unified_jll has `lit.py` but not `update_test_checks.py`.
- jlopt must create a TargetMachine for modules with a triple (as opt does): x86 fixtures'
  outputs depend on TTI.
- In-process, Julia's `julia` pipeline prints unnamed blocks where upstream's opt keeps
  names (`pipeline-prints.ll`); not investigated (not ported).
- Julia 1.10's fixtures without `--opaque-pointers` rely on LLVM 15's opt parsing typed
  IR into a typed context; jlopt always uses opaque contexts.
- Nightly moves daily; the harness warns (doesn't fail) when it differs from the pinned
  build. Refresh the master pin (manifest + CI `julia_ref`) when fixtures change.
- `LLVM.clopts` options set by jlopt (`-verify-memoryssa`, ...) are process-wide.
- LLVM.jl 10: `bb.successors`/`bb.predecessors` are properties (no exported functions);
  `inst.prev`/`inst.next`; `call.called_function.intrinsic`; `LLVM.constant_offset(gep, dl)`
  for one GEP; `DataLayout`, `storage_size`, `abi_size`, `intptr` are public, not exported.
- C++ `IRBuilder<>(inst)` also takes `inst`'s debug location; `CallInst::Create(...)` and
  `GetElementPtrInst::Create(...)` take none. Mirror this (`position_at!` in alloc_opt.jl)
  or outputs differ in `!dbg`.
- C++'s "prolog builder" keeps inserting before the *original* first instruction of the
  entry block; re-reading `first(entry.instructions)` reverses the order of allocas.
- LLVM's `NextPowerOf2(x)` is strictly greater than `x`.
- A pass with `required=false` is skipped on `optnone` functions, so its callback (and the
  ledger) doesn't see them.
- Overrides adapt fixtures to the ports; `run.jl --cpp` runs pristine fixtures.

## Open questions for Tim

1. Package name and GitHub repo (JuliaIR.jl under JuliaLLVM assumed).
2. Versions newer than the development minor (1.14) are rejected by `Dialect`; a new
   Julia minor then needs a JuliaIR release. Alternative: map unknown newer versions to the
   development dialect with a warning.
3. The nightly CI `upstream` job warns on drift instead of failing (setup-julia can't
   install a specific nightly). OK?
4. The CI workflows have not run on GitHub; Windows and macOS were never run locally.

## Peer conversations (pegasus)

- `llvm-middleend-passes-astra`: the design discussion behind the plan.
- `llvm-middleend-passes-sol`: reviews of S0–S4; `peer log` to read. Verdicts: S0 one
  minor, S1 three, S2 two, S3 three, S4 one finding, all fixed.
