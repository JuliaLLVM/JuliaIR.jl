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
| S4 AllocOpt | port done; open: S12, S13 | f728275, 5df7c8c, PR #2 |
| E1 PromoteMemToReg (LLVM.jl) | merged in LLVM.jl #669, unreleased | LLVM.jl f6369703 |
| S5 PropagateJuliaAddrspaces, DemoteFloat16, GCInvariantVerifier | done (PR #4, merged); S12 part open | 48e29df, 6f09543, 1d0b5c9 |
| S6 LateLowerGC cleanup (`jl-late-gc-cleanup`) | done as a subset, PR #5; generalized by S6b | e672c86, d11ee73 |
| S18 CombineMulAdd (`jl-combine-muladd`) | done, `tb/s18-combine-muladd` (sibling of S6b/S17 on PR #5) | 1ee4acf |

S4 details: `src/allocations.jl` (escape analysis, shared with the future JuliaLICM port)
and `src/passes/alloc_opt.jl`. Every upstream AllocOpt fixture passes in mode A on every
pin. `finish_split!` promotes the reference slots of split allocations with LLVM.jl's
`promote_mem_to_reg!` (E1; in PR #2), so `alloc-opt-pass.ll` runs without overrides. The design choices (which historical
behaviours are kept per Julia version, which fixes are applied to every version) are in
the plan's Log entry for S4 and in `docs/src/index.md`.

On GitHub: https://github.com/JuliaLLVM/JuliaIR.jl. PRs #1 (CI against LLVM.jl `main`,
`.github/actions/llvm-dev`), #2 (E1 use in AllocOpt) and #4 (S5) are merged; `main` is
4255ff2. S6 is PR #5 (`tb/s6-late-lower-gc`), the bottom of the JuliaIR.jl stack.

Scope and workflow changed on 2026-10-18 (plan decisions S-D12–S-D14, "Operating mode"): all of Julia's
passes get faithful, general ports (CPU paths included), for dialects D ≤ the running Julia and on every
LLVM from the dialect's own on. A coordinator session (kick-off prompt
`~/Julia/plans/llvm-middleend/PROMPT.coordinator.md`) delegates items to subagents, stacks PRs with
`gh stack`, and may push `tb/*` branches and open PRs on JuliaIR.jl and LLVM.jl.

S5 details: one file per pass in `src/passes/`, shared pointer and metadata helpers in
`src/irutils.jl`. Every upstream fixture of the three passes passes in mode A at every
pin, without overrides. Deviations from the C++ (master semantics for every dialect, two
C++ bugs in PropagateJuliaAddrspaces' memset handling, DemoteFloat16 policies and name
keeping, the verifier's error type) are in the plan's Log and `docs/src/index.md`.

S6 details: `src/passes/late_gc_cleanup.jl`, TBAA helpers (`mutable_tbaa_tag`,
`tbaa_derives_from`) and `clone_call!` in `src/irutils.jl`. The input contract (what must
be lowered before, what is rewritten, what is rejected with `UnsupportedInputError`) is
`docs/src/late_gc_cleanup.md`. `cpp_name` is empty: `jlopt` keeps running Julia's
`LateLowerGCFrame` for that name (frame fixtures and `alloc-opt-gcframe.ll` need it). The
upstream harness has a new `derived` status (a patched fixture that tests a port, no
stale check); master's `late-lower-gc-alloc-zeroing.ll` uses it.

S18 details: `src/passes/combine_muladd.jl`, a faithful port of the 1.10/1.11 C++ pass
(identical in both versions), remarks included. `Dialect.has_combine_muladd` says which
dialects have the pass; for 1.12 and later it is a no-op. Not required (skipped on
`optnone`, like the C++). Reads no target information. Upstream `muladd.ll` runs in mode A
at the 1.10 and 1.11 pins; `test/lit/combine-muladd.ll` covers the cases.

## Layout

- `src/dialect.jl`: `Dialect` (what each Julia version's IR looks like; passes branch on
  its fields, and the `fp16`/`bf16`/`gc_barrier` policies). `src/irutils.jl`: helpers
  shared by passes (metadata copy, pointer types by reference, alloca address space). `src/registration.jl`: option parsing (`jl-x<julia=1.12;fp16=demote>`),
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
- `.github/actions/llvm-dev`: develops LLVM.jl from a git ref (`ref`, default `main`) into
  the environments and builds LLVMExtra when the ref has unreleased changes to it (LLVM.jl's
  `deps/build_ci.jl`), then copies the preferences to `.`, `test/`, `docs/`. Used by every
  CI job until the LLVM.jl changes are released; then delete it and its `uses:` lines, and
  raise the LLVM compat bound.

## How to run each test tier (pegasus)

- Package tests: `julia +<ver> --project -e 'using Pkg; Pkg.test()'` (1.10, 1.11, 1.12,
  1.13, nightly). Each ~1 min. Stay in your worktree; give each Julia version its own
  manifest (`touch Manifest-v1.10.toml`, then `Pkg.resolve()`; gitignored). On 1.10 and
  1.11 (no workspaces) use `Pkg.test()` from the root: `--project=test` there loads the
  registered packages, and instantiating it writes a `test/Manifest.toml` that Pkg.test
  then picks up (and, on 1.10, fails to merge with dev'd entries: "can not merge
  projects"). At most 3 suites at once on pegasus.
- Against unreleased LLVM.jl: locally, add (never commit; 1.10 ignores it, CI uses the
  action instead; on 1.10 run `Pkg.add(url="https://github.com/JuliaLLVM/LLVM.jl",
  rev="main")` into `Manifest-v1.10.toml`, and into the test environment before
  `run.jl`) `[sources] LLVM = {url = "https://github.com/JuliaLLVM/LLVM.jl", rev = "main"}`
  to the root and `test/` Project.toml, and put `[LLVM] libLLVMExtra = "<path>"` in a
  `LocalPreferences.toml` in the root and `test/` (gitignored), built by running LLVM.jl's
  `deps/build_local.jl` under the same Julia version (one build per LLVM major, in a shared
  scratch dir). Builds of LLVM.jl `main`'s LLVMExtra (tree a6a5e8ee534a) for LLVM 15, 16,
  18, 20 and 23 are in `~/.julia/scratchspaces/929cbde3-209d-540e-8aea-75f648917ca0/builds/`
  (build from a `git archive origin/main deps` export, not from `~/Julia/pkg/LLVM`). The
  preference is one file for every Julia version: set it per run and test one version at
  a time.
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
  (it writes `test/Manifest.toml`: delete it before running `Pkg.test()` again).
- Docs: `julia +1.12 --project=docs docs/make.jl`.
- update_test_checks.py: not in any JLL; copy `llvm/utils/update_test_checks.py` and
  `UpdateTestChecks/` from an LLVM source tree, write a wrapper with `jlopt_bindir(dir)`,
  run `python3 update_test_checks.py --opt-binary=dir/opt test.ll`.

## Next steps

1. When LLVM.jl is released with `promote_mem_to_reg!` and the LLVMExtra_jll of Yggdrasil
   #15179: in PR #1, replace the action's uses by a raised LLVM compat bound (or drop PR #1
   and add the compat bound to PR #2), merge, and mark E1 done in the plan.
2. S6b: generalize `jl-late-gc-cleanup` into the full LateLowerGCFrame port, stacked on PR #5
   (plan item S6b). Independent: S17, S24 (S18 done); then E2 → S7, L5a → S8, L5b → S9, E3 → S10, the CPU
   passes S15–S21.
   For G4 (GPUCompiler adopting the ports): where the C++ LateLowerGCFrame silently lowered
   `julia.typeof`, or built a GC frame for a live GC stack and left GPUCompiler's validator
   to report it with a backtrace, `jl-late-gc-cleanup` throws `UnsupportedInputError`;
   GPUCompiler should turn that into its IR errors.
3. A differential check like the one used for S4 and S5 (C++ pass vs port, in-process, on
   every pinned fixture plus `code_llvm(...; optimize=false)` output) is cheap and found
   the only real differences, including two C++ bugs; S12 should formalize it with
   GPUCompiler's kernels. For a verifier-like pass that aborts, run the C++ side in a
   `bin/jlopt` subprocess for the inputs the port rejects.
4. Tim's call: report upstream that PropagateJuliaAddrspaces redeclares `llvm.memset`
   with the value operand's type as the length overload (invalid call), on every version.

## Traps

- LLVM.jl 10 exports little: `using LLVM, LLVM.IR, LLVM.Build, LLVM.Passes, LLVM.Analysis`
  and `using LLVM: API`; `LLVM.Target`/`LLVM.TargetMachine` are not exported anywhere.
  Properties: `mod.datalayout`, `mod.triple`, `mod.name`, `v.name`.
- `JuliaIR.register!` is not `LLVM.register!` (different arity; don't extend LLVM's).
- `ignorestatus(pipeline(...))` fails before Julia 1.13: use `pipeline(ignorestatus(cmd); ...)`.
- lit test formats must live in an importable module (`juliair_lit.py`): classes defined
  in a lit config can't be pickled to lit's workers. Run lit with `python -B`, or
  Python 3.14's forkserver workers write `__pycache__` into the source tree. Not with
  `-I`: it drops `lit.py`'s directory from `sys.path`, so the JLL's lit package isn't
  found. That went unnoticed on pegasus, where Arch's system-wide lit was used instead;
  test with a Python without lit (`uv python find 3.12`) to see what CI sees.
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
- The differential for LateGCCleanup forces the C++ pass onto its cleanup-only path by
  renaming `julia.get_pgcstack` and dropping `"gcstack"` attributes in both copies; parse
  the two copies in separate contexts (struct types get `.0` suffixes otherwise) and
  compare metadata by content (numbering shifts when the port rejects functions).
- A pass with `required=false` is skipped on `optnone` functions, so its callback (and the
  ledger) doesn't see them.
- Julia's C++ passes emit remarks through an `OptimizationRemarkEmitter`, which only
  builds them when the diagnostic handler enables the pass's remarks: for LLVM.jl's
  `remarks` callback to see them (e.g. in a differential), set
  `LLVM.clopts("-pass-remarks=<pass>", "-pass-remarks-missed=<pass>")`. The ports'
  `remark!` always reaches the callback. `ore::NV(key, inst)` renders an instruction as
  its opcode name in the message.
- Overrides adapt fixtures to the ports; `run.jl --cpp` runs pristine fixtures.
- `IRBuilder` can't create an alloca in a block that isn't in a function (it needs the
  module's data layout; segfault).
- LLVM.jl has no `eltype(::VectorType)` (use `.element_type`) and can't wrap scalable
  vector types (`value_type` of a `<vscale x ...>` value throws): inspect types that may
  be vectors through `API.LLVMTypeOf` refs (`src/irutils.jl`).
- IRBuilder (C API) constant-folds: a placeholder operand must not be a constant, or a
  "new" GEP/select comes back as a constant (PropagateJuliaAddrspaces uses a temporary
  phi).
- `call.called_function` is `nothing` when the call's function type differs from the
  declaration's (like C++'s `getCalledFunction`); tests must declare matching types.
- Printing differs between LLVM versions in CHECK lines: `half` constants are decimal on
  LLVM 23 (`3.000000e+00`, `0xH4200` before), LLVM 15 omits the value type of
  `atomicrmw xchg` of pointers.
- Julia's libLLVM targets differ per platform (macOS arm64 has no X86, Linux x86 no
  AArch64): lit tests that need a target say `REQUIRES: <target>-registered-target`.

## Decisions (Tim, 2026-10-17)

1. Name and repo: `JuliaLLVM/JuliaIR.jl`.
2. Versions newer than the development minor get its dialect (no error, no warning).
3. Nightly pin check: explained, decision pending.
4. CI covers Windows and macOS; no local runs needed before pushing.

## Peer conversations (pegasus)

- `llvm-middleend-passes-astra`: the design discussion behind the plan.
- `llvm-middleend-passes-sol`: reviews of S0–S6; `peer log` to read. Verdicts: S0 one
  minor, S1 three, S2 two, S3 three, S4 one finding, S5 one (DemoteFloat16's `ppu`
  triple), S6 three (allocation bundles, bundles on jlcalls, `invoke`), all fixed.
- `llvm-middleend-passes-astra` turn 3: the S5 design (bf16 policy, verifier errors).
