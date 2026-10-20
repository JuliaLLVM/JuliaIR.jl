# CPUFeatures

Julia code can ask about the CPU it will run on: `Core.Intrinsics.have_fma(T)` (used by
`fma` and some of `Base.Math`) and, from Julia 1.14 on, `Base.@cpu_supports`. The code
generator emits calls of intrinsics for these, `julia.cpu.have_fma.<type>` (`f16`, `f32`,
`f64`) and `julia.cpu.supports.<features>` (a comma-separated list of LLVM's feature
names, e.g. `julia.cpu.supports.avx2,fma`), which Julia's CPUFeatures pass folds to
constants. `jl-cpu-features` (Julia's name `CPUFeatures`, created with
[`JuliaIR.CPUFeaturesPass`](@ref)) is its port. It decides per calling function, so that
multiversioned clones of a function, which have their own `target-cpu` and
`target-features` attributes, get their own answers.

## How the answer is decided

Julia's C++ pass is two different passes, depending on the Julia version, and the port
follows the running Julia's.

Up to Julia 1.13, a feature string is searched for the features that provide FMA:

| Module's triple | Has FMA for `f32` and `f64` | For `f32` only |
|-----------------|-----------------------------|----------------|
| x86 (`i686`, `x86_64`, `amd64`, ...) | `+fma` or `+fma4` | |
| 32-bit ARM (`arm*`, not `thumb*`) | `+vfp4` | `+vfp4sp` |
| AArch64 | always, the features aren't read | |
| anything else | never | |

The feature string is the function's `target-features` attribute (also when it is
empty), and without it the feature string of Julia's JIT. The first of the features in
the table that is found decides: `+fma,-fma` has FMA. Features that imply others don't
count (`+avx512f` has no FMA here), and neither does `target-cpu`.

From Julia 1.14 on, LLVM's tables for the target are asked whether the function's CPU
and features enable the features: `+avx512f` has FMA, the last setting of a feature
wins, and `target-cpu="haswell"` has FMA. RISC-V has FMA for `f32` with `+f` and for
`f64` with `+d`. `julia.cpu.supports.<list>` is true when every name in the list is a
feature that LLVM knows for the target and the target has it; unknown names (and an
empty list) make it false. The CPU and features are the function's `target-cpu` and
`target-features` attributes, each where present, and otherwise the target machine's:
Julia's pipeline gives the C++ pass the target machine it compiles for (the JIT's, for
code compiled at run time). By name, e.g. in `opt`, the pass has no target machine, and
a function without attributes is compiled for the generic CPU of its triple. The
module's triple has to belong to a target that is registered with LLVM in the process
(Julia's library only has some, and Julia only registers the native one); otherwise
every answer is false.

## Where the target comes from

Without options, the port does what the C++ pass does when it runs by name in the
running Julia. The options say what the C++ pass would get from Julia's JIT instead:

- `target_cpu` and `target_features` give the CPU and the feature string (e.g.
  `"+avx2,-fma"`);
- `target_machine` gives an `LLVM.TargetMachine`, which can't be combined with them.

Up to Julia 1.13, the features of the options (or the target machine's feature string)
take the place of the JIT's feature string; `target_cpu` is accepted and has no effect,
as the C++ pass never reads a CPU. Without options, the port uses the answers that the
running Julia's JIT gives for `have_fma`, which it reads from the code Julia generates
for `Core.Intrinsics.have_fma(Float32)` and `(Float64)`. For a module of another
architecture than the JIT's (e.g. ARM code compiled on x86) the answer is false: the
JIT's feature string only has features of its own architecture, unless Julia was
started with features of another one in its CPU target (`-C`), which LLVM ignores but
the C++ pass would find. The answers
are read once per process, and only when a function without `target-features` needs
them.

From Julia 1.14 on, the options take the place of the target machine that Julia's
pipeline gives the C++ pass. A module without a triple is then taken to be for the
target machine's triple (`target_machine`), or the JIT's (`target_cpu`,
`target_features`); Julia's own modules always have one. [`JuliaIR.jit_target`](@ref)
returns the JIT's CPU, features and triple, so
`JuliaIR.CPUFeaturesPass(; target_cpu=t.cpu, target_features=t.features)` with
`t = JuliaIR.jit_target()` decides like Julia's own pipeline does for JIT code.

The options can't be given in pipeline text, as feature strings contain commas, which
separate the elements of a pipeline. Pass them to the constructor, or to
[`JuliaIR.register!`](@ref) (`options=Dict("jl-cpu-features" => (; target_cpu=...))`); `jlopt`
gives its `-mcpu` and `-mattr` flags to the pass that way (unlike `opt`, where these
flags don't reach Julia's pass when it runs by name).

## Dependence on the process and the library

So that the passes give the same answers as the C++ pass in the same process, some
answers depend on the process:

- Up to Julia 1.13, functions without `target-features` get the JIT's answers, i.e.
  whether the machine the tests run on has FMA.
- From Julia 1.14 on, whether a target is registered: Julia's x86-64 library has no
  AArch64, ARM or RISC-V target, so these triples have no FMA there. `jlopt` registers
  every target of the library, like `opt`.
- From Julia 1.14 on, the names of features, what they imply and the features of CPUs
  are those of the LLVM library the passes run on, which may be newer than Julia's.

IR for GPUs doesn't have the x86, ARM or RISC-V triples that the pass answers for, so it
folds every `have_fma` to false there; GPUCompiler has its own pass, which answers per
back-end.

## Differences with Julia's C++ pass

- An intrinsic that isn't called (e.g. its address is stored in a global), is passed as
  an argument, is called with `invoke`, or returns something else than an integer makes
  the port throw a [`JuliaIR.CPUFeaturesError`](@ref) before it changes the module. The
  C++ pass crashes on such uses, or erases the call that passes the intrinsic, or the
  `invoke` (leaving a block without a terminator).
- Up to Julia 1.13, the JIT's answers come from the code Julia generates for
  `have_fma`, not from the JIT's feature string, which Julia doesn't export; for modules
  of the JIT's architecture they are what the C++ pass decides from that string.
- From Julia 1.14 on, `target_cpu` and `target_features` describe the target without a
  target machine: the subtarget is created from them with LLVM's
  `Target::createMCSubtargetInfo`, where a target machine creates its own subtarget class
  for the function. Both have the same features for the targets the pass answers for,
  except where a target machine reads other function attributes (X86's
  `"use-soft-float"`). `target_machine` gives exactly the C++ pass's behaviour.
- From Julia 1.14 on, a module without a triple is taken to be for the target's triple
  when the target is given (see above). The C++ pass creates the subtarget for the
  target machine's triple, but decides `have_fma` by the module's empty triple, so that
  it is always false, while `julia.cpu.supports` can be true. Julia's own pipeline
  doesn't run into this, as the code generator sets the triple of every module.
