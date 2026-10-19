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
| S17 LowerExcHandlers (`jl-lower-exc-handlers`), runtime profiles | done, branch `tb/s17-lower-exc-handlers` (on S18's PR #6) | 138ff79, e4b7864, 8e55cc4 |
| S24c runtime facts from the running Julia, AllocOpt pointer size from the data layout | done, replaces S24b's tables in PR #9 (on S17) | 2ad92d5, 3772cd7 |
| S8 LowerSIMDLoop (`jl-lower-simdloop`), loop passes, LLVM.jl branch | done, branch `tb/s8-lower-simdloop` (on S24c, PR #9) | 72da87e, bc882e2, 43b272e |
| S6b LateLowerGCFrame (`jl-late-lower-gc-frame`) | port done, every dialect; branch `tb/s6b-late-lower-gc-frame` (on S8, PR #10) | see `git log` |
| S10 ExpandAtomicModify (`jl-expand-atomic-modify`) | done, branch `tb/s10-expand-atomic-modify` (on S6b, PR #11) | see `git log` |
| S26 `julia` option removed, S27 master fixtures at the nightly's commit, S28 `required` flags | done, branch `tb/s26-drop-julia-option` (on S10) | see `git log` |
| S19 CancellationLowering (`jl-cancellation-lowering`) | done, branch `tb/s19-cancellation-lowering` (on S26) | see `git log` |
| S30 AllocOpt on arrays/vectors of references, stale LLVM.jl API audit, Base corpus run | done, branch `tb/s30-allocopt-eltype` (on S19) | see `git log` |

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
LLVM from the dialect's own on. Narrowed by S-D17: a Julia version only processes its own IR (S26 removed
the `julia` option: the passes use `Dialect(VERSION)`); only the LLVM library may be newer than Julia's. A coordinator session (kick-off prompt
`~/Julia/plans/llvm-middleend/PROMPT.coordinator.md`) delegates items to subagents, stacks PRs with
`gh stack`, and may push `tb/*` branches and open PRs on JuliaIR.jl and LLVM.jl.

S5 details: one file per pass in `src/passes/`, shared pointer and metadata helpers in
`src/irutils.jl`. Every upstream fixture of the three passes passes in mode A at every
pin, without overrides. Deviations from the C++ (master semantics for every dialect, two
C++ bugs in PropagateJuliaAddrspaces' memset handling, DemoteFloat16 policies and name
keeping, the verifier's error type) are in the plan's Log and `docs/src/index.md`.

S6/S6b details: `src/passes/late_lower_gc_frame.jl` is the full port of
`LateLowerGCFrame` (`jl-late-lower-gc-frame`, `cpp_name = "LateLowerGCFrame"`, so `jlopt`
runs it for Julia's name); its functions follow the C++ ones (`local_scan`,
`compute_liveness!`, `color_roots`, `place_roots_and_update_calls!`, `cleanup_ir!`), and
the differences between Julia versions are the `gc_*` fields of `Dialect`.
`src/passes/late_gc_cleanup.jl` is `jl-late-gc-cleanup`: it checks the GPU input contract
(`UnsupportedInputError`) and runs the same code (without declaring
`ijl_gc_small_alloc`). The task and TLS offsets come from S24c's runtime facts
(`runtime_layout(opts, mod)`, pass options `task-ptls` etc. via `runtime_options`), read
only by the allocation and GC-transition lowerings; lit tests give them as options so
their output doesn't depend on the host. The GC constants are in the pass
file. The docs page `docs/src/late_lower_gc_frame.md` has the per-version table,
the contract and every deviation. All `late-lower-gc*.ll`, `gcroots.ll`,
`refinements.ll`, `returnstwicegc.ll`, `gc-writebarrier-volatile.ll`,
`alloc-opt-gcframe.ll`, `multiversioning-abi.ll` and `safepoint_stress.jl` run with the
port in mode A at every pin (1.10's `safepoint_stress.jl` through an override: its CHECK
line is typed). The harness's `derived` status (S6) is unused now.

S18 details: `src/passes/combine_muladd.jl`, a faithful port of the 1.10/1.11 C++ pass
(identical in both versions), remarks included. `Dialect.has_combine_muladd` says which
dialects have the pass; for 1.12 and later it is a no-op. Not required (skipped on
`optnone`, like the C++). Reads no target information. Upstream `muladd.ll` runs in mode A
at the 1.10 and 1.11 pins; `test/lit/combine-muladd.ll` covers the cases.

S17 details: `src/passes/lower_exc_handlers.jl`; `Dialect.except_enter` (`:no_task`,
`:task`, `:task_buffer`, `:none` from 1.13, where the pass is a no-op). The handler size
and alignment and setjmp's name are runtime facts (S24c, below), read only when a
function has handlers; whether setjmp takes a `savemask` argument follows the module's
triple (not on Windows), like the C++, unless `setjmp-savemask` overrides it. Upstream
`lower-handlers*.ll` run with the port at 1.10–1.12, without overrides; the package's lit
tests give the facts explicitly so they don't depend on the host. Pass options can be
`Int` and `String` (taken verbatim) besides `Bool`/`Symbol`.

S24c details (plan decision S-D17; replaces S17's `RuntimeProfile` and S24b's generated
tables): `src/runtime.jl`. `runtime_layout(dialect, mod)` (or `runtime_layout(opts, mod)`
from pass options) returns a lazy `RuntimeFacts` whose properties are the facts
(`task_gcstack`, `task_ptls`, `task_eh`, `tls_safepoint`, `tls_gc_state`, `handler_size`,
`setjmp`, `tp_asm`, master's `task_reset_ctx`/`reset_ctx_*`, ...; `RUNTIME_FACTS` lists
them). Each is resolved when read: the pass option of the same name, else the running
Julia's value (only for its own dialect), else a `RuntimeError` naming the fact and the
option. No target checks: like the C++, the host's values serve any triple. A pass
declares the options with `extra=runtime_options(:fact, ...)`. The running Julia's values
come from probes run once per process (`NATIVE_FACTS`, emptied in `__init__`): live from
the runtime (`jl_get_pgcstack`, the task word a `try` changes, the TLS byte
`jl_gc_safe_enter` sets, `jl_tls_elf_support`) or from `code_llvm` of small functions
(`GC.safepoint()`, a `try`, `Base.@cancel_check`) parsed into LLVM.jl's library;
docs/src/runtime.md has the table. GC pool classification is not a fact: S15 should
`ccall(:jl_gc_classify_pools, ...)` like the C++. AllocOpt takes the reference-slot size
and alignment from the data layout (`test/lit/alloc-opt-32bit.ll`).

S8 details: `src/passes/lower_simdloop.jl`, the first loop pass (`define_pass(...,
:loop, ...)` creates an LLVM.jl `LoopPass`; the implementation gets the `Loop` and the
loop pass manager's `LoopAnalysisResults`). Faithful to every version's C++ pass;
`Dialect.simdloop_check_combine` (1.12+) adds `contract` to the `fmul` feeding a
reduction. Deviations: the new loop ID is distinct on every dialect (master's fix; the
C++ of 1.10–1.13 corrupts other uses of an identical uniqued node such as `!{null}`),
and the "Loop SIMD Flags" remark is emitted on the header's terminator (temporarily
given the loop's start location), as LLVM.jl's `remark!` only takes an instruction.
`Instruction::mayReadOrWriteMemory` is LLVM.jl's `may_read_from_memory(inst) ||
may_write_to_memory(inst)` (wrappers of the C++). No pinned Julia version
has a module-level variant or `julia.loopinfo_marker`; the C++ pass is an optional loop
pass at every pin. Upstream `julia-simdloop.ll`, `julia-simdloop-memoryssa.ll` and
`loopinfo.jl` run with the port at every pin.

S10 details: `src/passes/expand_atomic_modify.jl`, faithful to the C++ of 1.13 and
master (they differ only in the `atomicrmw xchg` placement, master's fix adopted for both,
and how `!pcsections` is copied, with the same result). `Dialect.has_atomicmodify`: no-op
before 1.13. Not required, like the C++ at both pins (S-D7 said required). Wraps LLVM.jl
#671 (`inline!`, `split_block!`, `simplify_instruction` for the InstSimplifyFolder,
`move!(...; debug_records=true)`, `rmw.binop =`, `isinterposable`, `iscommutative`,
`supports_mmra`). Inputs where the C++ crashes, hangs or emits invalid IR throw
`JuliaIR.AtomicModifyError` or are handled (docs/src/index.md). Upstream
`atomic-modify.ll` runs at the 1.13 and master pins; `test/lit/expand-atomic-modify.ll`
(`REQUIRES: julia-ge-1.13`) covers the cases.

S26–S28 details: the dialect is always the running Julia's (`Dialect(VERSION; fp16, bf16,
gc_barrier)` in `parse_options`); `julia=` in a pipeline is an unknown option, and
`Dialect(::VersionNumber)` remains the map from a version to the drift table
(`test/dialect.jl` checks every row on any Julia). Each Julia tests its own dialect: the
testsets branch on `JuliaIR.Dialect(VERSION)`, and lit RUN lines of some versions are
gated by the features `julia-1.X`/`julia-ge-1.X` (see "Lit convention" below). Dead LLVM
checks in dialect-only code went (ExpandAtomicModify's LLVM 19/20, LateLowerGCFrame's
LLVM 16 in the 1.11+ allocation attributes), and `Dialect.propagate_addrspaces_target`.
S27: the development pin in `test/upstream/manifest.toml` has no commit; `run.jl`
requires the checkout at `Base.GIT_VERSION_INFO.commit` of the running nightly, and CI
reads it from the installed nightly before the sparse checkout. S28: every port's
`required` equals `passes.h` at every pin (PropagateJuliaAddrspaces was the only
mismatch). Validated: `Pkg.test()` 1.10 431, 1.11 431, 1.12 428, 1.13 396, nightly 394;
lit RUN lines executed 104/107/112/112/114 (549 over the five versions, 765 before, when
every version ran every dialect's lines); mode A 20/21/22/24/27 and `--cpp` 28/32/33/35/
40 + 2 unsupported, master at the nightly's commit 08e5253dc0.

S19 details: `src/passes/cancellation_lowering.jl`, faithful to master's C++ (the only
version with the pass; `Dialect.has_cancellation_lowering`, a no-op before). Required.
The safepoint emission it shares with LateLowerGCFrame moved to `src/codegen_shared.jl`;
`GCFunctions` gained `cancellation_point` and `get_pgcstack(fns, dialect, f)` serves both
passes. Facts: the task, `jl_reset_ctx_t` and `setjmp` facts of S24c, read only for
functions with points or runtime calls in `"julia.ipo_reset_safe"` functions; the setjmp
arity uses LowerExcHandlers' unnormalized triple rule (`setjmp_savemask`). Deviations
(docs/src/cancellation_lowering.md): the CFG is reported changed when blocks are split
(the C++'s stale dominator tree makes LateLowerGCFrame, the C++ and the port alike, drop
a `GC.@preserve` root; `test/passes.jl` checks it end to end), `CancellationLoweringError`
for a point without an entry-block GC stack and for an `invoke`d point, DataLayout
pointer alignment. Upstream `cancellation-lowering.ll` runs with the port at the nightly's
commit. Lit: `cancellation-lowering.ll` (update_test_checks, facts as options),
`-targets.ll` (Windows arity, i686, name order, errors), `-noop.ll` (1.13 and older).

S30 details: AllocOpt's `has_objref` called `eltype` on array and vector types, which
LLVM.jl no longer defines, so Base's fallback (`Any`) made AllocOpt throw on any load or
store of an aggregate of references; it uses `.element_type` now
(`test/lit/alloc-opt-aggregates.ll`, the `fields` testset). An audit of `src/` and
`test/` found no other stale LLVM.jl API: every `LLVM.x`/`API.x` exists on
`tb/inline-api`, and of the Base functions LLVM.jl 9.x extended for types and constants
and no longer does (`eltype`, `length`, `size`, `collect`, `getindex`, `isempty` on types),
only `eltype` has a fallback that returns instead of throwing, and that was its only use.
Every port runs, at its positions in Julia's pipeline (input made by the C++ prefix),
without exception or invalid output over 360 modules per version (300 Base methods, 60
synthetic) on 1.12, 1.13 and nightly, identical to the C++ pass at its main position
(LateLowerGCFrame modulo slot order, LateGCCleanup modulo `ijl_gc_small_alloc`); the
driver is S30's `corpus.jl` in the coordinator's scratchpad. Nightly's JIT stalls
(in `linkOutput`) compiling `push!` on a `Set{Any}` of signatures in `gen_corpus.jl`; an
`IdSet` avoids it. S12's differential found AllocOpt removing or splitting, on 1.10 to
1.12, allocations that those versions' C++ keeps: the port has 1.13's escape analysis for
every version (#62166's `getField` fix, #61131's `multiloc` guard and atomic lowering on
stack slots, #62752's RMW slot, whose absence crashes 1.12's C++). Kept on every version
(Tim, S-D30), documented in `docs/src/index.md`, tested by `alloc-opt-fields.ll` and
`alloc-opt-atomics.ll`; Julia 1.10-1.12's own LateLowerGCFrame/FinalLowerGC accept the
result. A version-gated variant (`Dialect.alloc_exact_fields`, `alloc_lower_atomics`) is
on the local branch `tb/s30-review-gated` should that be needed.

From S8 on, JuliaIR.jl depends on LLVM.jl's unmerged custom loop passes (#670), from S10
on also on its inlining API (#671, stacked on #670):
`[sources]` (root and `test/`) and the default `ref` of `.github/actions/llvm-dev`
point at the branch `tb/inline-api`, which is based on LLVM.jl `main` (so it has
`promote_mem_to_reg!`, #669); move both to the top of whatever LLVM.jl branches JuliaIR
needs. The action removes the LLVM entry of `[sources]` before developing its
checkout, as Pkg 1.11 and later refuse to replace a `url` source by a `path`.

## Layout

- `src/dialect.jl`: `Dialect` (what each Julia version's IR looks like; passes branch on
  its fields, and the `fp16`/`bf16`/`gc_barrier` policies). `src/irutils.jl`: helpers
  shared by passes (metadata copy, pointer types by reference, alloca address space). `src/registration.jl`: option parsing (`jl-x<fp16=demote;strong>`),
  `PassDefinition`/`define_pass`, `custom_pass` (the LLVM.jl pass with defaults),
  `register!`, `require_opaque`, `library_facts`, the ledger (`JULIAIR_LEDGER`).
  `src/runtime.jl`: `runtime_layout` and the probes behind it (facts about the
  running Julia's runtime that some passes need).
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
- Against the LLVM.jl stack (S8 on): as above, but `rev = "tb/loop-passes"` and the
  `libLLVMExtra` builds of that branch's `deps/LLVMExtra` (built from a `git archive` of
  it with `deps/build_local.jl` under each Julia version; directory
  `llvm<ver>-<tree hash of deps/LLVMExtra>`). Julia 1.10 needs
  `Pkg.develop(path=<checkout>)` (or `Pkg.add(url=..., rev=...)`) into
  `Manifest-v1.10.toml`; don't leave a `test/Manifest-v1.10.toml` behind (Pkg.test then
  fails with "can not merge projects").
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
  For master, check out the nightly's own commit:
  `git -C DIR checkout $(julia +nightly -e 'print(Base.GIT_VERSION_INFO.commit)')`.
- Docs: `julia +1.12 --project=docs docs/make.jl`.
- Each Julia version only tests its own dialect (lit lines and testsets): a change to the
  1.10 code path is only exercised by running Julia 1.10, so run all five versions.

## Lit convention

`test/litsetup.jl` passes the running dialect's minor version to `common.cfg.py`, which
defines the lit feature `julia-1.X` for it (a nightly newer than the known versions has
the newest one's) and `julia-ge-1.X` for it and every older known minor. A test file for
some versions says `REQUIRES: julia-1.10 || julia-1.11` (or `UNSUPPORTED: julia-ge-1.13`);
a RUN line for some versions is `; RUN: %if julia-1.12 %{ opt ... | FileCheck ... %}`, and
per-version check prefixes on a shared line are
`--check-prefixes=CHECK,%if julia-ge-1.12 %{COMBINE%} %else %{NOCOMBINE%}`. lit prints
"has no command after substitutions" for a line whose `%if` is false. `test/lit.jl` fails
on any `julia-*` feature under `test/lit` that isn't a known minor, since a misspelled
one would skip its lines silently. Ledger checks match `julia=` without a version.
- update_test_checks.py: not in any JLL; copy `llvm/utils/update_test_checks.py` and
  `UpdateTestChecks/` from an LLVM source tree, write a wrapper with `jlopt_bindir(dir)`,
  run `python3 update_test_checks.py --opt-binary=dir/opt test.ll`.

## Next steps

1. When LLVM.jl is released with `promote_mem_to_reg!` and the LLVMExtra_jll of Yggdrasil
   #15179: in PR #1, replace the action's uses by a raised LLVM compat bound (or drop PR #1
   and add the compat bound to PR #2), merge, and mark E1 done in the plan.
2. S6b is done on `tb/s6b-late-lower-gc-frame` (on S8). Next: S15 (FinalLowerGC, which
   the frame fixtures run behind the port), then E2 → S7, L5b → S9, E3 → S10 and the
   other CPU passes.
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

- The scratchpad directory is shared by all subagents: keep files in a subdirectory
  named after the item.
- Julia's C++ LateLowerGCFrame orders the frame slots of allocas by their addresses
  (a `DenseMap`), so its output differs between runs; a differential must retry or
  tolerate slot permutations (the port uses the function's order).
- The C++ recreates every call that CleanupIR reaches with the old call's name, so LLVM
  appends a number to the new call's name before `takeName`, and the numbers LLVM gives
  later clashing names shift. The port recreates them the same way to keep names equal.
- LLVM's C API returns a single-constant metadata node (`!{i64 8}`) as the constant
  itself (`ConstantAsMetadata`), not as an `MDNode`.
- `jld eval` and shell heredocs inside complex commands are refused by the worktree
  sandbox; run scripts from files (`jld run`, `python3 script.py`).
- `julia +nightly` moves: the master fixtures must be checked out at its commit
  (`Base.GIT_VERSION_INFO.commit`), or `run.jl` refuses them.

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
- Nightly moves daily, and with it the master fixtures: the manifest's entries for 1.14
  apply to whatever master is, so a changed fixture can fail CI without any change here.
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
- LLVM.jl has no `eltype` for array or vector types (use `.element_type`; Base's `eltype`
  silently returns `Any`, S30) and can't wrap scalable
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

- `position!(builder, inst)` doesn't exist in LLVM.jl 10: use `LLVM.before(inst)` /
  `LLVM.after(inst)`. `mod.datalayout` is a `DataLayout`; `alloca_addrspace` wants the
  string (`unsafe_string(API.LLVMGetDataLayoutStr(mod))`).
- Pass defaults and pipeline options are merged before the pass sees them, so a pass
  can't tell a default from an explicit option: the runtime-fact options use a value
  that means "not given" (0, `""`, `:auto`).
- Closures assign outer locals of the same name: `plan_fixture`'s `classify` overwrote
  the fixture's `runs` (fixed with `local`), which hid override pipelines from the
  ledger check.
- Running one of Julia's C++ passes from inside a JuliaIR pass callback (a nested
  `PassBuilder` in a fresh context) works.
- Runtime-fact probes: code coverage (CI's `--code-coverage=user`) adds `load volatile`
  and `store volatile` of line counters at constant addresses to the probe functions on
  1.10 and 1.11, so the safepoint probe can't take the only volatile load (that failed
  S24b's CI on 1.10/1.11); it collects every load chain of the expected shape and
  requires one distinct result. `@test` evaluates its expression inside a `try`, so
  reading the task's `eh` inside `@test` sees the test's handler. Julia 1.10 under `-g2`
  (which verifies the optimizer's IR) printed "φ node is not at the beginning of the
  basic block" and an internal-error dump for a `return` inside nested
  `try`/`finally` in a `@dispose` block (harmless, the method falls back to
  unoptimized code); `with_probe_ir` avoids that shape.

- Loop passes run after `loop-simplify`/`lcssa`, which LLVM's loop pass manager adds:
  multiple latches are merged into one and exits get LCSSA phis and preheaders, so lit
  tests must expect the canonical form (and can't test loop IDs on several latches).
- LLVM 15 doesn't parse `memory(...)`: lit tests that run on Julia 1.10 use the old
  attributes (`readnone`, `argmemonly readonly`) and accept both spellings in CHECK lines.
- With LLVM.jl's multi-library stack (#662 on), enum values print as
  `LLVM.Opcode.FAdd` instead of `LLVMFAdd`; `opcode_name` handles both. `get(inst.metadata, kind, default)` doesn't
  exist (use `haskey`), and `terminator`, `uses`, `user` aren't exported.
- lit features `llvm-ge-<N>` (from `test/litsetup.jl`'s `llvm_major`) gate tests on the
  LLVM version; a dialect's own LLVM is implied by `julia-ge-1.X`, so they are only
  needed for LLVM versions newer than a dialect's own.
- Julia 1.13/nightly's `code_llvm` of `modifyfield!` with a callable struct prints an op
  helper referring to the caller's alloca (unparsable); ExpandAtomicModify's inlining
  hides it. Julia's C++ ExpandAtomicModify aborts (bad_variant_access) on an `fadd` op
  inlined into a `strictfp` caller and hangs on multi-block ops that reach the loop.
- update_test_checks.py captures value and block names as FileCheck variables, so its
  CHECK lines don't notice when a port names things differently (e.g. creates them in
  another order: `%reset_ctx_prev3` instead of `%reset_ctx_prev`); check names that
  matter by hand (`cancellation-lowering-targets.ll`), and compare text in the
  differential.
- LLVM 23's verifier no longer accepts a bitcast between a `musttail` call and its `ret`
  (with opaque pointers there is nothing to cast); the ports keep the C++'s handling.
- The worktree sandbox refuses commands that point git outside the worktree unless they
  are plain: read Julia's sources with a lone `git -C /home/tim/Julia/src/julia show
  <rev>:<file>` (absolute path, nothing else in the command).
- Julia's C++ LowerSIMDLoop only reports remarks with
  `LLVM.clopts("-pass-remarks=lower_simd_loop", "-pass-remarks-missed=lower_simd_loop",
  "-pass-remarks-analysis=lower_simd_loop")`.

## Decisions (Tim, 2026-10-17)

1. Name and repo: `JuliaLLVM/JuliaIR.jl`.
2. Versions newer than the development minor get its dialect (no error, no warning).
3. Nightly pin check: replaced by S-D19 (fixtures at the nightly's own commit, S27).
4. CI covers Windows and macOS; no local runs needed before pushing.

## Peer conversations (pegasus)

- `llvm-middleend-passes-astra`: the design discussion behind the plan.
- `llvm-middleend-passes-sol`: reviews of S0–S6; `peer log` to read. Verdicts: S0 one
  minor, S1 three, S2 two, S3 three, S4 one finding, S5 one (DemoteFloat16's `ppu`
  triple), S6 three (allocation bundles, bundles on jlcalls, `invoke`), all fixed.
- `llvm-middleend-passes-astra` turn 3: the S5 design (bf16 policy, verifier errors).
