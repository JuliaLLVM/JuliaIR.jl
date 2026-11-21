
## AllocOpt ends a lifetime inside a later `gc_preserve_begin` region of the same allocation
- All pins (1.10 through master), `insertLifetime` in `src/llvm-alloc-opt.cpp`: the walk over the dominator tree from
  each `gc_preserve_begin` skips, and doesn't descend from, blocks that the walk from an earlier begin marked. When two
  begins of one allocation start in the same block, a block that only the later preserve covers can get a
  `lifetime.end` inside that preserve's region, so an opaque call that uses the saved pointer could run after it.
  JuliaIR's port does the same (faithful; documented in docs/src/index.md).
- Reproducer: `@two_preserves` in `test/lit/alloc-opt-preserve.ll` (its CHECK lines pin the C++'s output).
- Possible fix: per-preserve visited state, marking the union of the blocks live.
- Status: not filed.
