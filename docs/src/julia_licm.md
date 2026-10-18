# JuliaLICM

LLVM's loop-invariant code motion doesn't know the intrinsics of Julia's GC: it won't
move a call it can't prove free of side effects, and it can't know that an object that
never leaves a loop could be allocated once. Julia's `JuliaLICM` pass moves these out of
loops itself. `jl-licm` (`JuliaIR.JuliaLICMPass`) ports it for the IR of every Julia
version from 1.10 on, and `jlopt` runs it for Julia's name of the pass (`JuliaLICM`). It
is a loop pass (for `loop(...)` and `loop-mssa(...)` pipelines), not required: like the
C++, it skips `optnone` functions.

## What is moved

For a loop with a preheader, in reverse postorder of its blocks:

- **`llvm.julia.gc_preserve_begin`** is hoisted to the preheader when all its operands
  are defined before the loop (or are constants). A begin that stays leaves its ends
  where they are.
- **`llvm.julia.gc_preserve_end`** of a hoisted begin is sunk to the exits of the loop:
  moved to the first exit and cloned, without operand bundles or metadata, into the
  others. A loop without exits loses the end. The exits are those of the loop that
  defines the token (the innermost loop of its begin): an end is never sunk out of a
  loop its token is defined in, as LCSSA has no phis of tokens.
- **Write barriers** are hoisted to the preheader when their parent and children are,
  or can be made, loop invariant. Instructions that compute them are hoisted first if
  they are safe to speculate and don't read memory, losing metadata other than debug
  locations and keeping their flags. A barrier only marks the parent as possibly
  pointing to young objects, so one barrier before the loop suffices. On Julia 1.10
  to 1.13 this is `julia.write_barrier`. On Julia master, a `julia.object_write_barrier`
  is hoisted the same way. A `julia.field_write_barrier.p*` is hoisted as is when its
  slots are invariant too. Otherwise it is replaced in the preheader by an object
  barrier with the same parent and children, keeping its `!julia.reset_region`. That
  object barrier is declared with codegen's attributes when the module doesn't declare
  one yet.
- **`julia.gc_alloc_obj`** is hoisted when its operands can be made loop invariant and
  the escape analysis that AllocOpt also uses (`escape_analysis!`), restricted to the
  blocks of the loop, finds that the object doesn't escape. Its address mustn't escape
  either, and no reference may be stored into it: an object older than what it points
  to would need a write barrier. Uses after the loop don't count. The object is then
  shared by all iterations, so it is cleared with a `memset` in the preheader, aligned
  to the size of a pointer in address space 0 of the data layout.

The GC's barrier configuration on Julia master (the pass's `gc_barrier` option,
`gc-barrier=` in a pipeline) restricts the barriers. With `snapshot` and
`snapshot-field-precise`, a barrier must see each store, so none are hoisted. With
`field-precise`, field barriers with varying slots stay in the loop rather than being
demoted. The option has no effect on the IR of Julia 1.10 to 1.13, which has a single
barrier.

## Analyses

In a `loop-mssa` pipeline, the pass updates MemorySSA for every access it moves,
creates or removes. The tests check that the result is the MemorySSA that is built from
scratch for the transformed function. When something changed, it forgets the loop
dispositions of ScalarEvolution, and preserves the loop analyses, the CFG and
MemorySSA. Otherwise it preserves everything.

## Remarks

The pass emits remarks under the pass name `julia-licm`:

- `Hoisted` and `Sunk` for the preserve intrinsics.
- `Hoist` for barriers and allocations.
- `EscapeAnalysis`, an analysis remark that holds the `AllocUseInfo` of each allocation.
- `Escape` for an allocation that stays, with the reason.

The escape analysis emits its own remarks under `escape-analysis`, also when AllocOpt
runs it. Values in remarks are rendered by LLVM: an intrinsic call is `call
llvm.julia.gc_preserve_begin` from LLVM 21 on, and `call` before.

## Deviations from the C++

The port follows Julia master on every version where the C++ differs or fails:

| | C++ | port |
|-|-----|------|
| D1 | before Julia 1.13, an allocation whose address is the value operand of an atomic store or `atomicrmw` is hoisted (the escape analysis took it for a store into the object) | master's escape analysis on every version: it stays in the loop |
| D2 | before Julia 1.12.8, an end is sunk to the exits of the outermost loop being processed, so a token can be used outside the loop that defines it (invalid IR once the loop is cloned) | master's rule (JuliaLang/julia#63036) on every version |
| D3 | an end whose token isn't an instruction (`token none`) is cast to one, which crashes the pass on Julia master | the end stays where it is |
| D4 | a field barrier is demoted to a call of a `julia.object_write_barrier` that the module declares with another type, which is invalid IR | an `ArgumentError`, raised before the loop is changed |
| D5 | an exit block without an insertion point (a `catchswitch`) crashes the pass | that exit is skipped; Julia doesn't emit funclets |
| D6 | the uses of an `AllocUseInfo` beyond 16 are printed in pointer order | in the order they were found |

Remarks use master's names and formats on every version, including the `AllocUseInfo`
dump, which the C++ of Julia 1.10 and 1.11 prints in older formats.
