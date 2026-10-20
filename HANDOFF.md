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
| S14 type lowering (`julia_type`, `isboxed`, `julia_struct_type`, `deserves_*`, `check_layout`) | done, branch `tb/s14-type-lowering` (on S32) | see `git log` |
| S12 differential harness (`test/differential/`) | done, branch `tb/s12-differential` (on S14) | see `git log` |
| S11a mode B in the upstream harness, upgrade oracle, rule-generated patches for LLVM 23 (S11 steps 4–5) | done, branch `tb/s11a-mode-b-harness` (on S12) | see `git log` |
| v115 Julia 1.15 (master after 1.14 branched): pins, dialect gates, CI | done, branch `tb/julia-1.15` (on S11a) | see `git log` |
| S7 RemoveJuliaAddrspaces (`jl-remove-addrspaces`), RemoveAddrspaces (`jl-remove-all-addrspaces`) | done, branch `tb/s7-remove-addrspaces` (on `tb/juliair-deps-pin`) | see `git log` |
| S15 FinalLowerGC (`jl-final-lower-gc`) | done, every dialect; branch `tb/s15-final-lower-gc` (on S7) | see `git log` |
| S16 LowerPTLS (`jl-lower-ptls`) | done, branch `tb/s16-lower-ptls` (on S15) | see `git log` |
| S20 CPUFeatures (`jl-cpu-features`), keyword-only pass options | done, branch `tb/s20-cpufeatures` (on S16) | see `git log` |
| S21 JuliaMultiVersioning (`jl-multiversioning`) | done, branch `tb/s21-multiversioning` (on S20) | see `git log` |
| S9 JuliaLICM (`jl-licm`) | done, branch `tb/s9-julia-licm` (on S21) | see `git log` |
| S36 ledger appends with O_APPEND (concurrent processes garbled lines) | done, branch `tb/s36-ledger-append` (on S9) | see `git log` |
| S11 steps 2–3, 6–7: tests on a standalone LLVM 23 (`julia_llvm_in_use()`, lit tools of the library, LowerExcHandlers lifetime fix), mode B at every pin, the IR-crossing test, CI jobs `standalone-llvm`/`mode-b`/`oracle` | done, branch `tb/s11-standalone` (on S36) | see `git log` |
| S29a local performance fixes (TBAA, attributes, type stability, module facts) | done, branch `tb/s29-local-perf` (on S11) | see `git log` |
| S23 Julia's pipeline rebuilt from the ports (`julia<...>`), parts 2 and 3 | done, branch `tb/s23-pipelines` (on S29a) | see `git log` |
| S33 pass options and GC codegen helpers consolidated (S-D33) | done, branch `tb/s33-consolidate` (on S23) | see `git log` |
| jlopt as a Pkg app (`[apps]`, `@main` in `src/app.jl` on Julia 1.11+, docs in testing.md) | done, branch `tb/jlopt-app` (on S33) | see `git log` |
| S31 readability refactor of the ports, first part (S-D25, S-D29) | in progress, branch `tb/s31-readability` (on `tb/review-fixes`): keyword `Dialect`, LLVM.jl opcode/global/enum wrappers, shared helpers in irutils; ports' output unchanged | see `git log` |
| #42 intrinsic IDs and library facts in the selected library's scope (no `Intrinsic` constants; probes read with Julia's LLVM; `optimize!` selects the module's library; `JULIAIR_TEST_LIBRARY`) | done, branch `l3/scoped-library` (on `tb/ci-trim`) | see `git log` |

S29a details: local speed-ups of AllocOpt, PropagateJuliaAddrspaces, LateLowerGCFrame,
LateGCCleanup and FinalLowerGC, output unchanged (differential and mode A). AllocOpt walks
uses with a typed stack without boxed captures, and keeps its data layout and types per run in
`module_facts` (src/registration.jl); LateLowerGCFrame keeps its TBAA tags and the memos of
`tbaa_derives_from`/the downgraded tags per run, FinalLowerGC and LowerPTLS keep their
`TBAATags` (src/gc.jl) per function and per run, the shared `get_or_declare` looks GC
intrinsics up by name before building their types, and attribute tests everywhere use
`haskey`/`get` by kind (Symbol: enum or type attribute, String: string attribute). Warm on
1.12, synthetic corpus, port/C++ ratios against S11 went from 5.3/4.1/4.7/5.8/3.1 to
2.2/3.2/3.1/4.4/2.7.

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
their output doesn't depend on the host. The GC constants and the helpers shared with
FinalLowerGC (GC stack, declarations of intrinsics and runtime functions, TBAA, tag
loads, write barriers) are in `src/gc.jl`. The docs page `docs/src/late_lower_gc_frame.md` has the per-version table,
the contract and every deviation. All `late-lower-gc*.ll`, `gcroots.ll`,
`refinements.ll`, `returnstwicegc.ll`, `gc-writebarrier-volatile.ll`,
`alloc-opt-gcframe.ll`, `multiversioning-abi.ll` (with the S21 port) and
`safepoint_stress.jl` run with the port in mode A at every pin (1.10's
`safepoint_stress.jl` through an override: its CHECK line is typed), with the FinalLowerGC
port behind it since S15. The harness's `derived` status (S6) is unused now.

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
`setjmp`, `tls_offset`, `pgcstack_getter`, master's `task_reset_ctx`/`reset_ctx_*`, ...; `RUNTIME_FACTS` lists
them). Each is resolved when read: the pass option of the same name, else the running
Julia's value (only for its own dialect), else a `RuntimeError` naming the fact and the
option. No target checks: like the C++, the host's values serve any triple. A pass
declares the options with `options=runtime_options(:fact, ...)`. The running Julia's values
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
It emits safepoints through the shared `emit_gc_safepoint!` of `src/gc.jl` (S33);
`GCFunctions` gained `cancellation_point` and `get_pgcstack` (in `src/gc.jl` since S15)
serves both passes. Facts: the task, `jl_reset_ctx_t` and `setjmp` facts of S24c, read
only for functions with points or runtime calls in `"julia.ipo_reset_safe"` functions;
the setjmp arity uses LowerExcHandlers' unnormalized triple rule (`setjmp_savemask`).
Deviations
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

S14 details (plan decision S-D28): `src/type_lowering.jl` ports Julia's lowering of Julia
types to LLVM types (`cgutils.cpp`'s `_julia_type_to_llvm`, `_julia_struct_to_llvm`,
`bitstype_to_llvm`) and the calling-convention queries of `codegen.cpp`, for any context
with opaque pointers (typed contexts are rejected). Everything comes from the running
Julia's layouts (Base reflection: `DataTypeLayout`, `DataTypeFieldDesc`,
`uniontype_layout`, `datatype_arrayelem`); `MAX_ALIGN` is the alignment of a 256-bit
primitive. Dialect fields `cpointer_type`, `bottom_aliases`, `boxes_kinds`; the rest
(`BFloat16`, `GenericMemoryRef`, `TypeEq`, odd-bit primitives, the `jl_datatype_layout`
fallback of 1.11+) follows from what the running Julia has. Where the C++ aborts (atomic
fields, no layout, no fixed layout) the port throws `ArgumentError`. `check_layout(T, dl)`
compares Julia's layout with LLVM's under a data layout; the GPU divergences are pinned in
`test/type_lowering.jl` and documented in `docs/src/type_lowering.md`. No upstream
fixtures exist; the oracle is Julia's `jl_type_to_llvm`/`jl_struct_to_llvm` in the same
context (package tests: a corpus of ~100 types; a scratch sweep over 15-20k types of Core,
Base and stdlibs found no difference on any version). The cross-library variant of the
bitcode-carrier test needs LLVM.jl's multi-library support (S11); for now the carrier goes
between two contexts of Julia's LLVM.

S12 details: `test/differential/` (not part of `Pkg.test()`; docs/src/testing.md has the
user's view). `run.jl` runs each `PassSpec` of `passes.jl` (C++ pass and port, by Julia's
name; prefixes from `prefix_pipeline`; optional preparation, remarks, retries for
nondeterministic C++, `aborts` for the verifier) on every input module, in a worker
process that the supervisor restarts after a crash or hang (the in-flight job is
recorded from the worker log). Outputs are compared after removing local names and
inlining attribute groups. An entry of `exceptions.toml` rewrites one side's output
(deletes or replaces what its regex matches), and a difference is excepted only if the
outputs are identical after the rewrites that apply; `canonicalize` names a rewrite in
`CANONICALIZATIONS` (the GC frame slot order); `accept` entries take differences that
can't be rewritten away (invalid C++ IR, S-D30's escape analysis) without comparing
them, counted as `accepted`. A pass compared on nothing fails the run. `corpus.jl` writes the
`code_llvm` corpus, `gpucompiler/corpus.jl` (own environment: registered GPUCompiler and
LLVM.jl) the GPU modules, one target per process. `all.sh WORKDIR` does everything for
every juliaup channel, with core dumps disabled; `run.jl --report --out DIR ...`
re-reports after editing the exceptions (the worker keeps both outputs of every
difference). `test/differential` is a workspace project (no new packages); on 1.10/1.11
all.sh develops JuliaIR into a versioned manifest there. Adding a port: one `PassSpec`
(one per configuration for a pass with options, like `GCInvariantVerifier<strong>`).
The differential found CancellationLowering inserting the task field addresses of a GC
stack argument after the entry's `#dbg_value` records where the C++ (`entry.begin()`,
which keeps the iterator's head bit when no alloca is skipped) inserts them before;
fixed on this branch (`test/lit/cancellation-lowering-debug-records.ll`). CI's
`upstream` job runs the differential on 1.12, 1.14-nightly and nightly (fixtures, `code_llvm` corpus,
`inputs/`; no GPUCompiler), about 4.5 minutes locally on 1.12.

S11a details (S11 steps 4–5, plan decision S-D32): `test/upstream/run.jl --mode B` runs the
ports on whatever library LLVM.jl has loaded, with the running Julia still the pin's. RUN
lines naming one of Julia's C++ passes without a port (`JULIA_CPP_PASSES`, the union of
the pins' `passes.def` plus `julia`) are skipped and listed, also on Julia's own LLVM (a dry
run tests the same lines); unknown names still fail. Fixtures get the mode-A patch, then the
patch layer `derived-B/llvm<major>/<minor>/` of the library's major: `<file>.patch` applies
to the pristine fixture (oracle, and mode B without a mode-A patch), `<file>.after-A.patch`
on top of the mode-A patch. Stale checks per layer: without B must fail, and an override
with B alone must fail; layer files must belong to fixtures of the pin. The pins carry
`llvm` (the major of their Julia's LLVM), checked in mode B and the oracle.
`run.jl --cpp --reprint OPT` is the upgrade oracle: Julia's C++ passes in jlopt as with
`--cpp`, every textual output (stdout or `-o FILE`) re-printed by OPT (a newer LLVM's opt),
checked with OPT's FileCheck against pristine + plain B patch; bitcode and stderr pass
through (RUN lines checking stderr are listed, and the B patch of a fixture whose RUN lines
all check stderr is not stale-checked, only listed); a crash of jlopt is re-raised for
`not --crash`. `test/upstream/derive.jl JULIA_REPO --llvm 23 [--check]` generates the layer
from seven rules (memoryssa-alias, lifetime-size, masked-align, target-features-sign (input repair), splat,
null-pointer-splat, decimal-fp), each with its LLVM PR and the Julia commit whose fixture
adaptation it reproduces, and an exact per-(pin, fixture) count of lines changed. 21 patches
for 1.10–1.13; the oracle passes at every pin with them and at master without.

v115 details: Julia master is 1.15.0-DEV since c4ee915 (1.14 branched at 08e5253dc0, the
commit S27 validated). No C++ pass, `passes.h`, `pipeline.cpp` or `test/llvmpasses` changed
between the two (only dead declarations), so 1.15 has 1.14's dialect: `KNOWN_MINORS` still
ends at 1.14 (`NEWEST_MINOR`; newer versions get its dialect, Tim's decision 2), and the
dialect's fields that keyed on "the development version" now say `minor >= v"1.14"`, so
adding a minor no longer changes 1.14's dialect. Lit features and the differential's
`julia = [...]` exceptions follow the dialect's minor (1.15 runs `julia-1.14` lines and
1.14's exceptions). Pins: `1.14` has tag `release-1.14` and no commit (its fixtures are the
1.14 nightly build's commit until 1.14.0 is tagged), `1.15` is master; a prerelease newer
than every pin uses the newest pin if it has no commit (`pin_minor` in `run.jl`), so the
next version bump of master doesn't break CI. CI runs `1.14-nightly` in the test matrix
and the upstream and differential jobs; `all.sh` defaults to it too (juliaup channel
`1.14-nightly`).
The docs and comments that said "Julia master" for the newest dialect's behaviour say
"Julia 1.14 (and later)" now.

S7 details: `src/passes/remove_addrspaces.jl`, both passes required, the same at every
pin. `AddrspaceRemapper` maps types (with its own cache for the whole run: LLVM.jl's
type mapper only caches per call) and `AddrspaceMaterializer` rebuilds constant
expressions, for LLVM.jl's value mapper (#674: `ValueMap`, `map_value`, `clone_into!`,
`remangle_intrinsic`, ...). Faithful otherwise, including the `.bad` renaming of
identified structs in the context; target extension and AMX types map to themselves.
Deviations (docs/src/remove_addrspaces.md): D1 compile units mapped to themselves on
every LLVM (from LLVM 20, CloneFunctionInto only adds a CU to the map when it visits it,
so one referred to only by inlined subprograms got duplicated); D2 the CUs and the
`DIGlobalVariable`s of the globals' `!dbg` are seeded before any global metadata is
mapped (seeding only the CUs leaves the CU's `globals` pointing at a stale variable);
D3 metadata of global declarations kept (master's codegen attaches `!julia.constgv` to
them, so this is a real difference on nightly's IR); D4 all type attributes mapped;
D5 ifuncs recreated (the C++ deletes the resolver they still use and segfaults when the
module is printed); D6 the metadata of global variables and ifuncs mapped after the
initializers, function bodies and aliasees (it is mapped without the type mapper, and the
C++'s interleaving lets a later initializer, body or aliasee reuse its constant
expressions with the old types). Upstream `remove-addrspaces.ll` runs with the port at every pin (1.10
through an override: typed RUN lines), `parsing.ll` too. Differential (C++ vs port
in-process, every pinned fixture, a `code_llvm` corpus with and without debug info, and
from 1.11 the corpus after Julia's pipeline prefix): identical except the lit extras for
D1–D6, and on nightly the `!julia.constgv` of D3 (the prefix is Julia's: from 1.13
ExpandAtomicModify after FinalLowerGC, on master CancellationLowering first). Validated:
`Pkg.test()` 1.10 469, 1.11 469, 1.12 466, 1.13 434, nightly 432; mode A 21/22/23/25/28,
`--cpp` unchanged.

S15 details: `src/passes/final_lower_gc.jl`, faithful to the C++ of every pin
(`llvm-final-gc-lowering.cpp`, master's `-stock.cpp`), with the functions' names. The
differences between versions are `Dialect` fields (`gc_final_module`,
`gc_final_skip_unused`, `gc_final_debugloc_next`, `gc_alloc_entry_points`,
`gc_alloc_reset_safe`, and S6b's `gc_names`, `gc_alloc_bytes_tag`,
`gc_barrier_lowering`). `jl-final-lower-gc` is registered twice, as a module and as a
function pass (`define_pass` keys on name and kind; LLVM's parser picks the registration
by the nesting level); the module pass does 1.10's module-level declarations
(`llvm.compiler.used` round trip) and otherwise runs the function pass on every function.
A top-level name is the module pass, so from 1.11 on `jlopt` (and the upstream harness,
through `port_pipeline`) nests a C++ pipeline that starts with `FinalLowerGC` in
`function(...)`, as LLVM does for the C++ function pass.
Allocations of a constant size ask the running Julia's `jl_gc_classify_pools`
(`gc_pool_class`, cached per process, emptied in `__init__`; `RuntimeError` for another
dialect or a non-stock GC); no pass option. Adopted on every dialect: master's
non-volatile TBAA-tagged frame `memset` (F1), 1.11's `dereferenceable` (F2, for 1.10),
the frame alignment S6b records (1.13). An existing runtime declaration of another type
throws `DeclarationError` before anything changes (F4; the C++ emits invalid IR; also a
mismatching `julia.queue_gc_root` call, checked for every function to be lowered first). Pointer
size and alignment come from the data layout, not the host. On master the CFG is
preserved unless a barrier was lowered. docs/src/final_lower_gc.md has the table and
every deviation; `test/lit/final-lower-gc.ll` the per-version cases, and the testset
"FinalLowerGC" in `test/passes.jl` the pool classes against the runtime. Every upstream
fixture that names FinalLowerGC runs with the port in mode A at every pin
(`final-lower-gc*.ll` are ports now; the frame fixtures and `alloc-opt-gcframe.ll` lost
their "mixed" kind). A differential against the C++ (the `code_llvm` corpus after Julia's
C++ prefix through LateLowerGCFrame, separately and interleaved, and the fixtures'
pipelines) is identical modulo F1/F2 at every pin (Julia's C++ LateLowerGCFrame orders the
frame slots of `sret` root buffers by pointer, a `DenseMap`, so a corpus comparison can
differ between runs in that order). Validated after review: `Pkg.test()` 1.10 469, 1.11
470, 1.12 467, 1.13 435, nightly 441; mode A 22/23/24/26/29 and `--cpp` 28/32/33/35/40 + 2
unsupported (1.10 to master, master at 08e5253dc0).

S16 details: `src/passes/lower_ptls.jl` (`jl-lower-ptls`, `cpp_name = "LowerPTLSPass"`,
required), a port of `llvm-ptls.cpp` for every dialect (the `ptls_*` fields and
`gc_state_condition` of `Dialect`). JIT mode reads the running Julia's facts when a module
calls a getter: `tls_offset` (`jl_tls_offset`) and `pgcstack_getter`/`pgcstack_key`
(`jl_pgcstack_getkey`), options of type `Union{Nothing,Int}` and `Union{Nothing,UInt}` (`tls-offset=-1`,
`pgcstack-getter=0x1000`); imaging mode is the `imaging` option, with `tls-elf-support`.
`tp_asm` is gone from the runtime facts: the thread-pointer asm follows the module's
triple through LLVM.jl's `Triple` (an empty triple is the running Julia's host).
The GC-state and safepoint emitters of `llvm-codegen-shared.h` are in `src/gc.jl`, on
the `GCCodegen` context that every GC pass holds (S33).
`docs/src/lower_ptls.md` lists the deviations (1.12's entry safepoint fixed as in 1.13,
`align 1` GC state stores, the data layout's pointer size, errors where the C++ crashes or
hits `llvm_unreachable`, reused image variables). No upstream fixture runs LowerPTLS
beyond `parsing.ll`; `test/lit/lower-ptls.ll` covers every mode and architecture, and the
differentials (C++ vs port, in-process: a `code_llvm` corpus brought to LowerPTLS's input
by Julia's C++ prefix pipeline, the fixtures with getter calls, synthetic cases, triple
spellings) agree at every version up to the documented deviations. DemoteFloat16 asks
`LLVM.Triple` too, instead of a table of architecture names. Validated after the review
(sol, `s16-review`): `Pkg.test()` 1.10 498, 1.11 498, 1.12 495, 1.13 463, nightly 461; mode A 20/21/22/24/27 and `--cpp`
28/32/33/35/40 + 2 unsupported (unchanged); corpus differential 187/187/190/190/199 equal,
the 2 others per version being AMDGPU's `late-lower-gc-addrspaces.ll`, which the port
rejects (no thread pointer) where the C++ emits x86 asm.

S20 details: `src/passes/cpu_features.jl`, docs page `docs/src/cpu_features.md`. Two
rules (`Dialect.cpu_features_rule`): `:tokens` up to 1.13 (the first FMA feature in the
caller's `target-features`, else in the JIT's string), `:subtarget` on master (LLVM.jl's
`SubtargetInfo`: a `TargetMachine`'s subtarget, or one created from the attributes and the
options; `julia.cpu.supports.*` only there, `Dialect.has_cpu_supports`). The target is
given by the keyword-only options `target_cpu`, `target_features`, `target_machine`
(`jlopt -mcpu/-mattr`), declared with `option(T, nothing; text=false)` since S33
(rejected in pipeline text, left out by `options_string`, converted to `T` when the pass
is created; the definition's `check` rejects combining `target_machine` with the
others), and
`register!(pb; options=Dict(name => (; ...)))` sets such defaults per pass. Defaults:
1.10-1.13 read the JIT's two answers from `code_llvm` of `Core.Intrinsics.have_fma`
(probe `:jit_fma`, used only for modules of the JIT's architecture family); master by
name = the generic CPU; with options and an empty module triple, everything (also
`have_fma`) is decided for the target machine's or the JIT's triple (recorded deviation:
the C++ keeps the empty triple for `have_fma`); `JuliaIR.jit_target()` (probe `:jit_target`:
`jl_get_llvm_target`, `JLJITGetTripleString`) gives what Julia's pipeline uses. Non-call
uses, arguments, `invoke` and non-integer results throw `CPUFeaturesError` before any
change. Upstream `cpu-features*.ll` run at every pin (the AArch64/RISC-V ones are
unsupported on x86 hosts), `multiversioning-x86.ll` behind the JuliaMultiVersioning port
(S21), `parsing.ll` maps `CPUFeatures`. Lit: `cpu-features.ll` (all versions),
`cpu-features-tokens.ll` (up to 1.13), `cpu-features-subtarget.ll` (master, X86
registered), `cpu-features-targets.ll` (master, AArch64/RISC-V registered or not). `always_have_fma` is for S21.

S21 details: `src/passes/multiversioning.jl` (`jl-multiversioning`, `cpp_name =
"JuliaMultiVersioning"`, a required module pass), in sections that follow the C++:
targets (`MultiVersioningTarget`, the `julia.mv.specs` flag in both flag encodings,
`target_specs`), annotation (`annotate_module_clones`), checks (`check_cloning`: what the
C++ asserts on, crashes on or miscompiles throws `MultiVersioningError` before the module
changes), cloning (`CloneCtx`, `prepare_slots!` ... `emit_metadata!`). `src/irutils.jl` has
the `ConstantUses` walk (`constant_uses`, `use_info`, `next!`); `always_have_fma` is
S20's. The dialect fields are
`mv_spec_flags`, `mv_bf16`, `mv_tables` (1.10's offset tables) and `mv_autoinit`. Module
flags are read and added through the `llvm.module.flags` named metadata, as LLVM's C API
can't represent `Max` flags (LLVM.jl's `mod.flags` iteration and assignment are unsafe for
them). The `targets` keyword is vector-valued, which `custom_pass` now supports (not
settable in a pipeline). Deviations (S-D22) are on `docs/src/multiversioning.md`. The
annotate-only, clone-only and x86 fixtures run with the port at every pin (`-x86.ll` with
the CPUFeatures port behind it), `-abi.ll` from 1.13 (behind the LateLowerGCFrame port).
The pass expects the always-inliner to have run, as in Julia's pipeline: before it, the `available_externally` copies of other partitions'
`alwaysinline` functions are relocated but not in the partition's `jl_fvars`, which the
port rejects (the C++ reads a garbage index). Validated after the review: `Pkg.test()` 1.10
759, 1.12 756, nightly 722 (implementer: 742/742/739/707/705); mode A 23/24/25/27/30 (+3
each), `--cpp` 28/32/33/35/40 + 2 unsupported (unchanged). The in-process differential
against the C++ (fixtures, the lit module, a module with every kind of use) is identical
except for the trampolines' ABI on 1.10–1.12 (S-D22(2)); the audit's probes give identical
output, an error where the C++ crashes or miscompiles, or the documented deviations (D1
expansion, D2 on 1.10, D5, D7). On the four partitions of a 1.13 system image built for
`generic;sandybridge,clone_all;haswell,-rdrnd,base(1)` (after the always-inliner), the
output is identical up to the order of the relocations of one function in `jl_clone_slots`
(the C++'s unstable sort), in 0.91× the C++'s time. System images built with the port in
place of the C++ pass load and run with `-C generic`, `sandybridge`, `haswell` and `native`
on 1.13 (4 partitions) and nightly (88 partitions). LLVM.jl's `clone_into!` runs its
value-mapper prepass even without callbacks (about 30% of its time on large functions).

S9 details: `src/passes/julia_licm.jl` ports `JuliaLICM` (`jl-licm`, a loop pass,
`required=false`). Every dialect follows master:

- the #63036 rule for sinking preserve ends;
- master's escape analysis, shared with AllocOpt in `src/allocations.jl`;
- master's remark formats. The escape analysis reports under `escape-analysis`, with
  LLVM.jl's lazy `remark!`.

The deviations D1 to D6, where the C++ is buggy or crashes, are in
`docs/src/julia_licm.md`. `src/gc.jl` holds the write-barrier helpers
(`write_barrier_children` and the declaration of `julia.object_write_barrier`). The pass
keeps MemorySSA up to date, and the testset compares it to one built from scratch. The
differential against the C++ is a scratch script. Its output is identical at 1.13 and
master. At 1.10 to 1.12 it differs only by D1 and D2, plus the older remark formats at
1.10 and 1.11. Validated:

- `Pkg.test()`: 1.10 452, 1.11 452, 1.12 449, 1.13 417, nightly 417.
- Mode A: 24/25/26/28/31, each pin 4 more than before.
- `--cpp`: unchanged.
- Speed: about 2 to 2.7 times the C++ for the whole `loop-mssa` pipeline on a synthetic
  module of 10000 loops.

S23 details: `src/pipeline/pipeline.jl` has `JuliaPipeline` (level, `ports`, Julia's
`OptimizationOptions` per version), the marker passes (registered by `register!`),
`jl-irce-with-cleanup` (1.14's `IRCEWithCleanupPass`), `build_pipeline!`/`pipeline`/
`optimize!`/`alias_analyses!` and `expand_julia_pipeline`; one recipe per version
(`src/pipeline/julia-1.1x.jl`, `Recipe{minor}` by `dialect_minor`, a stage that didn't
change is the previous version's; 1.14 serves 1.15). Every pass is ported, so
`CPP_FALLBACKS` is empty: it is where a pass that a newer Julia adds can fall back to
the C++ until its port lands (mode B then skips `julia<...>` lines). `jlopt` (and so the upstream harness) expands
`julia<...>` unless `-map-julia-passes=0`; it gained `-mcpu`/`-mattr` (`native` = host),
and with a `-print-*` option runs the pipeline once before setting LLVM's options, as
those also apply to Julia's JIT compiling the passes. `test/pipeline.jl` compares
`print_pipeline` of the C++ element and the rebuilt one (C++ names and ports) for every
level and option, and the rebuilt pipeline's output with Julia's on two functions
(retried: LateLowerGCFrame's slot order varies). Upstream: `pipeline-prints.ll` runs
(mode A and `--cpp`, every pin); `pipeline-o*.jl` are `derived`: the patches in
`derived/<minor>/` emit the unoptimized IR and run `llvm-link -S %t/* | opt -mcpu=native
-passes='julia<level=N>' -S` (generated by turning each `-O` RUN line into that, and, in
`pipeline-o2-allocs.jl`, ending the last check at the function's `}` rather than at
`attributes`, as FinalLowerGC's declarations now follow the last function). The
differential has a `PassSpec` per level (`julia<level=N>`, `aborts`, `inherits` the
exceptions of the ports it runs) and its own exceptions for the S-D30 and write-barrier
deviations as they look after the whole pipeline. Triple-less inputs get the host's
triple there, and before 1.14 levels 2 and 3 compare against the rebuilt C++ pipeline
with FinalLowerGC's port (its non-volatile frame memset changes what DSE does). Deviations from Julia's pipeline are
listed in `docs/src/pipeline.md`; not visible in printing and not checked: text
`loop-mssa` with SimpleLoopUnswitch may let LLVM use BFI, and the TLI comes from the
module's triple rather than the target machine's.

S33 details (S-D33): pass options are declared with `option(T, default; text, valid,
requirement)` (`src/registration.jl`, `OptionSpec`), or by a plain default
(`strong=false`, of the default's type). The type decides the text form (`Bool` a flag,
`Union{Nothing,Bool}` `yes`/`no`, `Symbol`, `Int`, `UInt` an address printed in hex,
`String`; other types need `text=false`), how constructor keywords are converted (`Ptr`,
integers in range, `SubString`, vectors) and what `options_string` prints. `PassDefinition`
holds the declarations in `options` (the values still arrive as `opts.extra`);
`parse_options(def, str)` also runs the definition's `check`, so text can't bypass it.
`Optional`, `option_value`, `keyword_only` and the vector special cases are gone.
Runtime facts, `setjmp_savemask` and the multiversioning `targets` are `nothing` when not
given: `task-ptls=0` is a fact of 0, `setjmp=` (empty), `tls-elf-support=auto`,
`setjmp-savemask=auto` and `targets=[]` are rejected, and `runtime_layout` converts the
facts given to it like pass options. On the GC side, `GCCodegen` (dialect, module,
builder, runtime facts, layout types) is the context of every helper in `src/gc.jl`;
it also holds Julia's TBAA tags, built on first use (`tbaa_tags`), or given by
LateLowerGCFrame, which keeps them for the whole run (S29a). FinalLowerGC,
LateLowerGCFrame, LowerPTLS and CancellationLowering hold one.
`gc_transitions.jl` and `codegen_shared.jl` are gone. One `emit_gc_safepoint!(g, ptls,
tbaa; final)` emits final and `julia.safepoint` safepoints; each pass keeps its own forms
(LowerPTLS's `align 1` GC state, LateLowerGCFrame's `gcd` alignment, CancellationLowering's
own GEPs and untagged loads), which `test/gc.jl` checks for every dialect. Generic IR
helpers (attribute and intrinsic predicates, `get_or_insert_function!`, metadata) are in
`src/irutils.jl`; metadata by name goes through LLVM.jl's `inst.metadata[name]`, which
needs LLVM.jl 10.3 (`LLVMGetMetadata2`). The port
outputs on the differential corpus are byte-identical to the base's.
Validated on S9 (LLVM.jl `tb/juliair-deps` 07200ee, LLVMExtra 9a88a5345ba0):
`Pkg.test()` 1.10 1850, 1.11 1964, 1.12 1956, nightly 1987; mode A 31/32/33/35/40/40 and
`--cpp` 28/32/33/35/40/40 (1.10 to 1.15, 2 unsupported on 1.14 and 1.15), unchanged;
differential 1.12 and nightly 0 different, counts unchanged; docs build. Review: sol,
`s33-review`, no P1/P2 left. Rebased onto S23, where `GCCodegen` also took over S29a's
TBAA tags: `Pkg.test()` 1.10 2079, 1.12 2290, nightly 2318; mode A 1.12 38/38 and nightly
45/47 (as on S23), `--cpp` 34/34 and 41/43 (2 unsupported on this host); the port outputs
on the frozen differential corpus at 1.12 are byte-identical to S23's. Review of the
conflict resolutions: sol, `s33-rebase-review`, no P1/P2 left. Not done (follow-up):
unifying `GCFunctions` and `JuliaFunctions` (plan Q5); GC safe-enter/leave emitters stay
out of scope.

JuliaIR.jl depends on the registered LLVM.jl 10.3 (compat `"10.3"`), the first release with
everything the ports use (custom loop passes, the inlining API, value mapping and cloning,
MemorySSA, the target triple wrapper, standalone libraries, ...; JuliaLLVM/LLVM.jl#678 to
#698 and the multilib work). Its LLVMExtra_jll 0.0.55 has builds for every Julia version's
LLVM, nightly's LLVM 23 included, so no environment needs `[sources]` or a local
`libLLVMExtra`.

S11 steps 2–3 details: LLVM.jl loads a standalone library through its `libLLVM`
preference; its `deps/build_standalone.jl 23` builds one. Locally: `[LLVM] libLLVM =
"<.so>"` in the `LocalPreferences.toml` of `.`, `test/`, `test/differential/`, `docs/`, and
`JULIAIR_LLVM_TOOLS=<LLVM_full_jll 23 artifact>/tools` (on pegasus
`~/.julia/artifacts/504b55167f4bdff1834c0aff72735d59b907eadf/tools`). Tests that need Julia's
C++ passes or type lowering are gated on `julia_llvm_in_use()` (test/litsetup.jl, now
included once by runtests.jl) or the lit feature `julia-llvm`.

S11 steps 6–7 details: `test/crossing.jl` (in Pkg.test) runs `test/crossing/writer.jl` in a
second process on Julia's own LLVM without LLVM.jl (`JULIA_LOAD_PATH=@stdlib`), which writes
bitcode with Julia's lowering of a corpus of types plus what Julia and its LLVM say about
their layout; the test reads it into LLVM.jl's library, checks that the layout is Julia's
once the data layout is restored, and that without restoring it, x86 IR of LLVM < 18 read by
LLVM ≥ 18 gets `i128:128` and the wrong layout of `{i8, i128}` (16/32 instead of 8/24).
CI (`.github/workflows/CI.yml`): `standalone-llvm` builds a standalone LLVM 23 with the
`deps/build_standalone.jl` of the LLVM.jl release the package resolves to (LLVM_full_jll
23.1.4, cached on that release's version, a recipe revision and the runner image) and tars
it with LLVM 23's opt/FileCheck/not/count/llvm-dis/llvm-as and `libLLVM.so.23.1jl`
(`tools/` + `lib/`, the tools' RPATH is `$ORIGIN/../lib`);
`mode-b` (only the 1.10 pin of `upstream`: old IR on a newer LLVM is
the GPUCompiler case where LowerExcHandlers broke, and nightly covers new IR on LLVM 23;
one matrix line adds a pin back) sets the `libLLVM` preference and `JULIAIR_LLVM_TOOLS`,
checks LLVM.jl loaded it, runs Pkg.test and `run.jl --mode B`; `oracle` (same pin, only
when test/upstream, litsetup.jl, bin/jlopt or the workflow change, or on
workflow_dispatch) runs `--cpp --reprint` with that opt. Mode-b develops the package into
test/ only after Pkg.test: on 1.10, Pkg.test fails ("can not merge projects") once it is.
Not yet run on GitHub. Locally (CI steps simulated, LLVM 23.1.4, with
S7/S15/S16/S20/S21/S9's ports in mode B too): mode B 1.10 31/31, 1.11 32/32, 1.12 33/33,
1.13 35/35, 1.14 40/42 (2 unsupported on x86); Pkg.test 1.12 1467, 1.14 1470; oracle at
every pin as `--cpp`. The only finding on LLVM 23 was a lit input that LLVM 22's verifier
rejects (`cpu-features-tokens.ll`'s untrimmed `"+sse2, +fma"`), now run before LLVM 22 only.

## Layout

- `src/dialect.jl`: `Dialect` (what each Julia version's IR looks like; passes branch on
  its fields, and the `fp16`/`bf16`/`gc_barrier` policies). `src/irutils.jl`: helpers
  shared by passes (metadata copy, pointer types by reference, alloca address space). `src/registration.jl`: option parsing (`jl-x<fp16=demote;strong>`),
  `PassDefinition`/`define_pass`, `custom_pass` (the LLVM.jl pass with defaults),
  `register!`, `require_opaque`, `library_facts`, the ledger (`JULIAIR_LEDGER`).
  `src/runtime.jl`: `runtime_layout` and the probes behind it (facts about the
  running Julia's runtime that some passes need), and `gc_pool_class`. `src/gc.jl`: what
  the GC passes share: tracked-pointer counting, the `GCCodegen` context, TBAA,
  declarations, type tags, write barriers, and the task, thread-local state, safepoint
  and GC-state emitters.
  `src/jlopt.jl`: the `opt`-compatible driver. `src/passes/<pass>.jl`: one file per pass,
  each ending with `define_pass(...)` and its `JuliaIR.<Name>Pass` constructor.
- `bin/jlopt`: executable wrapper (`using JuliaIR; exit(JuliaIR.jlopt_main(ARGS))`).
- `test/lit/`: the package's lit tests (`.ll` with RUN lines), `lit.cfg.py`, the shared
  `common.cfg.py` (PATH, library path, env passthrough, Windows substitution), and
  `juliair_lit.py` (per-test ledger format, used by the upstream harness).
- `test/litsetup.jl`: finds Python, writes the `opt` wrapper, runs lit.
- `test/upstream/`: `run.jl` (harness), `manifest.toml` (pins + every fixture),
  `derived/<minor>/*.patch` (overrides), `derived-B/llvm<major>/<minor>/*.patch` (mode-B
  layers, generated by `derive.jl`; don't edit them by hand).

## How to run each test tier (pegasus)

- Package tests: `julia +<ver> --project -e 'using Pkg; Pkg.test()'` (1.10, 1.11, 1.12,
  1.13, 1.14-nightly, nightly). Each ~1 min. Stay in your worktree; give each Julia version its own
  manifest (`touch Manifest-v1.10.toml`, then `Pkg.resolve()`; gitignored). On 1.10 and
  1.11 (no workspaces) use `Pkg.test()` from the root: `--project=test` there loads the
  registered packages, and instantiating it writes a `test/Manifest.toml` that Pkg.test
  then picks up (and, on 1.10, fails to merge with dev'd entries: "can not merge
  projects"). At most 3 suites at once on pegasus.
- Against an unreleased LLVM.jl (only when a port needs a change that isn't released
  yet): locally, never committed, `Pkg.develop` a checkout of it into the versioned
  manifest, and if it changes LLVMExtra, build that with its `deps/build_local.jl` under
  the same Julia version and set the `libLLVMExtra` preference in a gitignored
  `LocalPreferences.toml` (one file for every Julia version: test one version at a time).
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
  For master, check out the nightly's own commit:
  `git -C DIR checkout $(julia +nightly -e 'print(Base.GIT_VERSION_INFO.commit)')`.
- A library next to Julia's (GPUCompiler's configuration):
  `JULIAIR_TEST_LIBRARY=<libLLVM-standalone-23.so> julia +<ver> --project -e 'using Pkg; Pkg.test()'`
  runs only the in-process testsets, with that library selected after loading the package
  with Julia's (the `libLLVM` preference instead compiles the package for the library).
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

1. S6b and S15 are done: the GC lowering runs without Julia's C++ passes. Next: the other
   CPU passes.
   For G4 (GPUCompiler adopting the ports): where the C++ LateLowerGCFrame silently lowered
   `julia.typeof`, or built a GC frame for a live GC stack and left GPUCompiler's validator
   to report it with a backtrace, `jl-late-gc-cleanup` throws `UnsupportedInputError`;
   GPUCompiler should turn that into its IR errors.
2. The differential (S12, `test/differential/`) replaces the per-item scratch scripts:
   a new port adds a `PassSpec` to `test/differential/passes.jl`, runs `all.sh`, and
   records its decided deviations in `exceptions.toml`.
3. Tim's call: report upstream that PropagateJuliaAddrspaces redeclares `llvm.memset`
   with the value operand's type as the length overload (invalid call), on every version.

## Traps

- `module_facts` lives as long as one occurrence of a pass in one run, across functions,
  with other passes running in between (whole module passes under `repeat<n>`, LLVM 18
  and older): only cache what no pass changes (data layout, types, uniqued metadata), never
  functions or globals, nor the absence of a function (LateLowerGCFrame declares some of
  LateGCCleanup's while a pipeline runs). `repeat<n>` itself is gone from LLVM 19.
- Never keep an `Intrinsic` (or anything else a library resolves, like attribute kinds)
  in a global constant: it is evaluated when precompiling, with Julia's library, and
  GPUCompiler then runs the passes with another one, where the same ID is another
  intrinsic (the ID of `llvm.lifetime.start` in Julia 1.13's LLVM 20 is that of
  `llvm.instrprof.mcdc.tvbitmap.update` in LLVM 23). Look intrinsics up while running, once per pass
  invocation where it matters (`GCIntrinsics`), and ask the context for the LLVM version
  (`library_facts(ctx)`). `JULIAIR_TEST_LIBRARY` catches this.
- `remark!` only builds a remark's message when a consumer is set (callback, `-pass-remarks`
  options, remark file); unlike LLVM.jl's eager path it doesn't fall back to `@debug`.
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
- The worktree sandbox also refuses commands with shell variables or loops around `git`,
  `sh` or `julia`, and Python heredocs whose text names git: put the loop in a script
  in the scratchpad and run it by its literal path.
- LLVM.jl's `split_block_and_insert_if_then_else!` refuses a phi as the split point: to
  split right after a call and put a phi there, split before the instruction after the
  call (the same IR). `LLVM.called_operand!` replaces the callee but not the call's
  function type, and refuses a callee of another pointer type (address space), which
  `setCalledOperand` accepts; LowerPTLS sets the last operand instead. `GlobalVariable(mod, T, name)` is in address space 0, not the data
  layout's globals address space that C++'s `new GlobalVariable` uses (`G1` on AMDGPU).
- `julia +nightly` moves: the master fixtures must be checked out at its commit
  (`Base.GIT_VERSION_INFO.commit`), or `run.jl` refuses them.

- LLVM.jl 10 exports little: `using LLVM, LLVM.IR, LLVM.Build, LLVM.Passes, LLVM.Analysis`
  and `using LLVM: API`; `LLVM.Target`/`LLVM.TargetMachine` are not exported anywhere.
  Properties: `mod.datalayout`, `mod.triple`, `mod.name`, `v.name`.
- `JuliaIR.register!` is not `LLVM.register!` (different arity; don't extend LLVM's).
- `ignorestatus(pipeline(...))` fails before Julia 1.13: use `pipeline(ignorestatus(cmd); ...)`.
- pegasus writes core files (~500 MB) into the crashing process's working directory: a test
  that makes a process abort must spawn it under `sh -c 'ulimit -c 0 && exec "$@"'` (S32,
  `test/jlopt.jl`). lit's `not --crash` already disables them.
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
- Nightly moves daily, and with it the master fixtures: the manifest's entries for 1.15
  apply to whatever master is (and those for 1.14 to whatever `release-1.14` is, until
  1.14.0 is tagged), so a changed fixture can fail CI without any change here.
- On pegasus, `julia +1.14-nightly` is the release branch's nightly (added 2026-10-19);
  `julia +nightly` was then still 1.14.0-DEV.3787 (08e5253dc0, the branch point), not
  master: run `juliaup update nightly` (once no other run uses it) to get 1.15.
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
  can't tell a default from an explicit option: an option that the pass decides when it
  isn't given is declared `option(Union{Nothing,T}, nothing)` (S33), never with a
  sentinel value of `T`.
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
- Under LLVM.jl's `libLLVM` preference, `ccall(:jl_type_to_llvm, ..., context())` (any
  of Julia's codegen functions given a context of the other library) segfaults instead
  of failing; Julia's passes give `unknown pass name`. Gate such tests on
  `julia_llvm_in_use()`.
- LLVM_utils_unified_jll's tools are of Julia's LLVM: its llvm-dis can't read bitcode a
  newer library writes (`Unknown attribute kind (102)`), hence `JULIAIR_LLVM_TOOLS`.
- LLVM 22's verifier only accepts lifetime markers on allocas; ports that mark a cast of
  an alloca (as Julia's C++ passes do for non-zero alloca address spaces) must mark the
  alloca there (`library_facts(ctx).lifetime_on_alloca`).
- A context of Julia 1.11's LLVM 16, created through the C API, may have typed pointers:
  textual IR with `ptr` then fails to parse; call `LLVMContextSetOpaquePointers` (LLVM 15
  and 16 only) first.
- On Julia 1.10, `Pkg.test()` fails with "can not merge projects" once the package itself
  has been developed into `test/` (e.g. for `--project=test` runs): develop after testing,
  or delete the test manifest.
- The upgrade oracle's `opt` wrapper must run LLVM_full_jll's tools without lit's
  `LD_LIBRARY_PATH` (Julia's libLLVM), and must hide bash's own "Aborted" report when jlopt
  crashes (it would land in `2>&1 | FileCheck` input). LLVM_full_jll 23's `opt` is
  `~/.julia/artifacts/504b55167f4bdff1834c0aff72735d59b907eadf/tools/opt` on pegasus.
- `derive.jl` includes `run.jl` into its own module: `DeriveB.HarnessError` is not
  `UpstreamHarness.HarnessError` when both are loaded (as in `test/upstream.jl`).
- LLVM 23's verifier no longer accepts a bitcast between a `musttail` call and its `ret`
  (with opaque pointers there is nothing to cast); the ports keep the C++'s handling.
- The worktree sandbox refuses commands that point git outside the worktree unless they
  are plain: read Julia's sources with a lone `git -C /home/tim/Julia/src/julia show
  <rev>:<file>` (absolute path, nothing else in the command).
- Julia 1.10's inference fails internally ("Internal error: encountered unexpected error
  in runtime: BoundsError(a=Type{Core.TypeofBottom}, i=1)", printed while compiling a
  caller) when it merges the results of comparing a `DataType` with `===` to both
  `Core.TypeofBottom` and `Type{Union{}}`, which are `==` (JuliaLang/julia#56913, fixed
  by #56915 in 1.11.4, not backported to 1.10); `is_bottom_alias` hides
  `Core.TypeofBottom` behind `Base.inferencebarrier`.
- A `ccall(..., llvmcall)` inside a `@testset` closure fails ("could not evaluate ccall
  return type"); define such functions at top level. `llvm.ptrmask.p3.i32` is invalid
  under the host data layout (index width 64).
- Julia passes an unboxed `VecElement{String}` as a by-value `ptr addrspace(10)`, and
  aggregates with some references get an extra roots parameter: a test of
  `deserves_argbox` can't just look for `addrspace(10)` parameters.
- Julia's C++ LowerSIMDLoop only reports remarks with
  `LLVM.clopts("-pass-remarks=lower_simd_loop", "-pass-remarks-missed=lower_simd_loop",
  "-pass-remarks-analysis=lower_simd_loop")`.
- LLVM 23 rejects a named struct used in an initializer before its definition: define
  `%T = type ...` at the top of lit inputs.
- Julia's C++ FinalLowerGC is not nested automatically in pipeline text: write
  `function(...,FinalLowerGC)` (1.12+) or a module-level `FinalLowerGC` (before).
- `--implicit-check-not=addrspace` also matches the ModuleID (the file name); use
  `'addrspace('`.
- Julia's C++ RemoveJuliaAddrspaces segfaults on modules with an `ifunc`.
- From LLVM 20, CloneFunctionInto only adds the compile units it visits to the value map
  (LLVM 19 and older reset every CU found by DebugInfoFinder).
- LLVM 16 and older rebuild a type-mapped `poison` as `undef`; LLVM 15/16 have no vector
  `llvm.ptrmask`; LLVM 23 turns `llvm.masked.gather`'s alignment operand into an
  attribute.

- The differential's worker runs Julia's C++ passes, which abort the process on IR they
  reject (GCInvariantVerifier) or crash on; an uncaught Julia error in the worker is a
  harness bug and stops the run (`ERROR: LoadError` in the worker log).
- GPUCompiler 2.15 segfaults in its own InstCombine run for GCN on Julia 1.10 and 1.11
  (`gcn.jl:127`), so the GPU corpus is generated one target per process.
- LLVM.jl's `PassException` wraps a port's error: its `ex` field has the original.
- `functions`, `parameters`, `blocks`, `instructions`, `isdeclaration` aren't exported by
  LLVM.jl 10: qualify them (`LLVM.functions(mod)`).
- The worktree sandbox refuses shell commands that mention `GIT_VERSION_INFO`, or `git`
  in complex forms; put such Julia code in a script file.
- LLVM's `-print-before`/`-print-after` also print the IR of Julia's JIT, which compiles
  the passes' Julia code during a run: jlopt warms up first (see S23); anything else
  that sets them in-process (`LLVM.clopts`) prints JIT modules too.
- The output of Julia's C++ pipeline varies between runs where LateLowerGCFrame assigns
  frame slots to allocas (pointer-keyed order): compare whole-pipeline outputs with
  retries.

- lit tests run with lit's internal shell (`ShTest(False)`), also on Windows: don't use
  `sed` and friends in RUN lines, use `split-file` pieces instead. RUN lines inside a
  `split-file` piece are still RUN lines of the whole file.
- The worktree sandbox refuses `cd` before `git`, `git -C` with variables, and compound
  commands that mention "git" (even `.gitignore`): put such steps in a script in the
  scratchpad and run it with `bash <script>`.
- `LocalPreferences.toml` selects one LLVMExtra build (per LLVM major): running another
  Julia version with it fails LLVM.jl's precompilation, so set it right before each run.

- Capturing `print<memoryssa>` (or any LLVM stderr output) with `redirect_stderr` also
  captures the remarks that Julia's own code generator prints while it compiles the
  capturing code. Compile first (a warmup run), or filter `remark: ` lines.
- `inst.metadata[kind]` returns a one-operand node like `!{i64 1}` as its operand
  (`MetadataAsValue` canonicalizes it), which can't be attached to another instruction;
  iterate `inst.metadata` to copy such metadata.
- Julia's C++ JuliaLICM segfaults on an end of `token none` and on demoting a field
  barrier with a mistyped `julia.object_write_barrier`. Keep such probes out of
  in-process differentials, because they kill the process.

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
