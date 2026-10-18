# JuliaMultiVersioning

Julia's system and package images run on many CPUs, but code compiled for a recent CPU's
features runs faster on that CPU. When Julia builds an image for several *targets* (the
`JULIA_CPU_TARGET` environment variable, or `--cpu-target`), its `JuliaMultiVersioning`
pass compiles the image's functions once per target where that pays off, and emits tables
from which Julia's image loader picks, for the CPU it runs on, a version of each function.

`jl-multiversioning` (`JuliaIR.MultiVersioningPass`) ports the pass for the IR of every
Julia version from 1.10 on, and `jlopt` runs it for Julia's name of the pass
(`JuliaMultiVersioning`, also `JuliaMultiVersioning<external>`). It is a required module
pass, which does nothing unless the module has the `julia.mv.enable` module flag. The code
keeps the names and the structure of the C++ (`annotate_module_clones`, `CloneCtx`,
`prepare_slots!`, `clone_bodies!`, `fix_gv_uses!`, `fix_inst_uses!`, `emit_metadata!`, ...),
so that both can be read side by side.

## Targets

The targets are listed in the `julia.mv.specs` module flag, which Julia sets when it
builds an image: a CPU name, the target features to add, the index of a *base* target and
flags. [`JuliaIR.target_specs`](@ref) reads them as
[`JuliaIR.MultiVersioningTarget`](@ref)s. The first target is the one the image needs at
least; a target either clones every function (`clone_all`), or only the functions that
benefit from its features (its `clone` categories), and uses the versions of its base
target (the first target, or one that clones every function) for the others. For modules
without the flag, the `targets` keyword of `MultiVersioningPass` gives them, and the pass
records them in the flag.

## What the pass does

1. **Annotation.** Julia annotates its modules before it runs the pass (which marks them
   with the `julia.mv.annotated` flag); for other modules, the pass does it. Each function
   gets a `julia.mv.clones` attribute, the set of targets to clone it for: every target
   that clones everything, and the targets one of whose categories the function has
   (loops, vector arguments or results, fast or fused floating-point math, queries of
   CPU features, `half` or `bfloat` values, as the target says), together with the
   functions in between such functions in the call graph. Functions that some targets
   clone and that instructions use, or that aliases name, get a *relocation slot*
   (`julia.mv.reloc`); other functions in global initializers are marked
   `julia.mv.fvar`. With the `julia.mv.skipcloning`
   flag, the pass stops here.
2. **Cloning.** Each function is cloned for its targets (`f.1`, `f.2`, ... after the
   targets' indices), with the target's CPU and features, `optsize` or `minsize` if the
   target says so (unless the function is `optnone`), and a `julia.mv.clone` attribute
   with the target's index.
3. **Uses.** Calls (and other uses by instructions) from a version of a function to a
   function that some targets of its group clone load the callee from its relocation
   slot, which the loader fills in with the version it picks. Uses in global initializers
   become null, and *relocations*: entries telling the loader to write the picked version
   there. Aliases of cloned functions become *trampolines*, functions that call the
   function through its slot.
4. **Tables.** The pass replaces Julia's table of the image's functions (`jl_fvars`) by
   the tables the loader reads: the functions (`jl_fvar_*`), the relocations
   (`jl_clone_slots`), and per target the functions it has a version of
   (`jl_clone_idxs`) and those versions (`jl_clone_ptrs`, or `jl_clone_offsets`). The
   `julia.mv.suffix` module flag is appended to their names.

## What changes between Julia versions

| Behaviour | 1.10 | 1.11 | 1.12 | 1.13 | master |
|-----------|------|------|------|------|--------|
| encoding of the targets' flags | `JL_TARGET_*` bits | same | same | same | packed flags |
| loops and CPU feature queries cloned by every target | no | no | no | no | yes |
| `bfloat` values as a category | no | yes | yes | yes | yes |
| tables | offsets from the first function and the first global variable (`jl_fvar_base`, `jl_gvar_base`), also of `jl_gvars` | pointers (`jl_fvar_count`, `jl_fvar_ptrs`, `jl_clone_ptrs`) | same | same | same |
| relocation slots of defined functions | null | null | a trampoline that initializes the runtime first | same | same |

## Differences from the C++ pass

The port changes what the C++ pass does where it is wrong (S-D3, S-D22):

- **Call-graph expansion.** The C++ pass extends the set of functions to clone in the
  order of their addresses in memory, without revisiting functions, so that whether a
  function between cloned ones is cloned can differ from one run to the next. The port
  extends the set until it contains every function that is called by and calls a
  function in it, which includes everything the C++ pass may clone.
- **Trampolines' ABI.** Before Julia 1.13, trampolines call the function without its
  calling convention and its parameter and return attributes (like `byval` and `sret`),
  which passes the arguments wrong. The port keeps them for every version, like Julia
  1.13 does.
- **32-bit IR on Julia 1.10.** Julia 1.10 truncates the tables' offsets according to the
  pointer size of the machine it runs on, which emits invalid IR for 32-bit targets on
  64-bit machines. The port goes by the module's pointer size, like later versions.
- **Uses of aliases.** The C++ pass erases the aliases it replaces by trampolines with
  their uses, which leaves those dangling; the port redirects them to the trampolines.
- **Duplicate `julia.mv.veccall` flags.** When it annotates a module that already has the
  flag, the C++ pass adds a second one, which makes the module invalid. The port keeps an
  identical flag, and rejects a different one.
- **`external`.** For reduced test cases, `external` tolerates function tables with
  entries that aren't function definitions: the C++ pass drops every entry after the
  first of them, the port only those entries.
- **Malformed input.** Where the C++ pass asserts, crashes or emits wrong code (no
  `jl_fvars` or `jl_fvar_idxs` table, malformed target flags or `julia.mv.clones`
  attributes, functions without a version for a target that clones everything, a
  relocated function that isn't in the function table, a target based on one that
  doesn't clone everything, a cloned function in a constant global, in `llvm.used`, under
  an expression that changes its address, or used by a global value other than a global
  variable or an alias, ...), the port throws a [`JuliaIR.MultiVersioningError`](@ref)
  before it changes the module.

What the port keeps: functions that aren't cloned call the first target's version of the
functions they call, also when a target has a clone of it; and variadic functions'
trampolines use `musttail` calls on every architecture, like Julia's release builds
(builds with assertions reject them on ARM and PowerPC).
