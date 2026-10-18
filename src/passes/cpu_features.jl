# CPUFeatures: fold the intrinsics that ask about the CPU the code runs on,
# `julia.cpu.have_fma.<type>` (`Core.Intrinsics.have_fma`) and, on Julia master,
# `julia.cpu.supports.<features>` (`Base.@cpu_supports`), to constants, from the target
# of the calling function. Port of Julia's `src/llvm-cpufeatures.cpp`, which is two
# passes (`Dialect.cpu_features_rule`):
#
# - up to Julia 1.13 (`:tokens`), a feature string is searched for some features: the
#   caller's `target-features`, or else the feature string of Julia's JIT;
# - on master (`:subtarget`), LLVM's subtarget tables are asked about the caller's
#   `target-cpu` and `target-features`, which take precedence over the target machine's
#   when Julia's pipeline gives the pass one (by name, there is none: the attributes
#   alone, with the generic CPU, describe the target).
#
# The pass options `target_cpu`, `target_features` and `target_machine` describe the
# target that the C++ pass would get from Julia's JIT, see `CPUFeaturesPass`.

"""
    JuliaIR.CPUFeaturesError(msg)

The intrinsics that CPUFeatures folds are used in a way that it doesn't support: not
called (e.g. stored in a global), passed as an argument, called with `invoke`, or
declared with a result that isn't an integer. Julia's C++ pass crashes or produces
invalid IR on such IR. Thrown before the module is changed.
"""
struct CPUFeaturesError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CPUFeaturesError) = print(io, "CPUFeaturesError: ", e.msg)

const HAVE_FMA_PREFIX = "julia.cpu.have_fma."
const CPU_SUPPORTS_PREFIX = "julia.cpu.supports."

"""
    JuliaIR.always_have_fma(name::AbstractString, triple::LLVM.Triple)

Whether code for `triple` has FMA for the type of the intrinsic `name`
(`julia.cpu.have_fma.<type>`) whatever its CPU (`true` or `false`), or `nothing` when
that depends on the CPU. AArch64 always has FMA for `f32` and `f64`. Julia's
multiversioning uses this to skip clones that would only differ in the answer.
"""
function always_have_fma(name::AbstractString, triple::LLVM.Triple)
    LLVM.isaarch64(triple) || return nothing
    typ = chopprefix(name, HAVE_FMA_PREFIX)
    return typ == "f32" || typ == "f64"
end

# the options that describe the target, checked once they are all known
function check_cpu_target(target_cpu, target_features, target_machine)
    target_cpu isa Union{Nothing,String} ||
        throw(ArgumentError("target_cpu must be a string, not a $(typeof(target_cpu))"))
    target_features isa Union{Nothing,String} ||
        throw(ArgumentError("target_features must be a string, not a $(typeof(target_features))"))
    target_machine isa Union{Nothing,LLVM.TargetMachine} ||
        throw(ArgumentError("target_machine must be an LLVM.TargetMachine, not a $(typeof(target_machine))"))
    target_machine !== nothing && (target_cpu !== nothing || target_features !== nothing) &&
        throw(ArgumentError("target_machine can't be combined with target_cpu or target_features"))
    return
end

# The state of one run: the target the options describe, and the subtargets created
# from them (owned by the run).
mutable struct CPUFeaturesRun
    dialect::Dialect
    triple::LLVM.Triple
    cpu::Union{Nothing,String}
    features::Union{Nothing,String}
    tm::Union{Nothing,LLVM.TargetMachine}
    target::Union{Nothing,Missing,LLVM.Target}  # `missing` until it was looked up
    subtargets::Dict{Tuple{String,String},Union{Nothing,LLVM.SubtargetInfo}}
    feature_names::Dict{Ptr{Cvoid},Set{String}}
end

function CPUFeaturesRun(dialect::Dialect, mod::LLVM.Module, extra::NamedTuple)
    (; target_cpu, target_features, target_machine) = extra
    check_cpu_target(target_cpu, target_features, target_machine)
    # the token rule only reads a target machine's feature string, as the C++ pass
    # does with the JIT's
    if dialect.cpu_features_rule === :tokens && target_machine !== nothing
        target_features = target_machine.features
        target_machine = nothing
    end
    return CPUFeaturesRun(dialect, LLVM.Triple(mod.triple), target_cpu, target_features,
                          target_machine, missing, Dict(), Dict())
end

function finish!(run::CPUFeaturesRun)
    for sti in values(run.subtargets)
        sti === nothing || LLVM.dispose(sti)
    end
    empty!(run.subtargets)
    return
end

# the calls of the intrinsics in the module, in the order the C++ pass folds them
function cpu_feature_calls(mod::LLVM.Module, dialect::Dialect)
    calls = Tuple{LLVM.CallInst,Symbol,String}[]
    for f in mod.functions
        fname = LLVM.name(f)
        kind, arg = if startswith(fname, HAVE_FMA_PREFIX)
            :have_fma, chopprefix(fname, HAVE_FMA_PREFIX)
        elseif dialect.has_cpu_supports && startswith(fname, CPU_SUPPORTS_PREFIX)
            :supports, chopprefix(fname, CPU_SUPPORTS_PREFIX)
        else
            continue
        end
        for use in LLVM.uses(f)
            push!(calls, (checked_call(LLVM.user(use), f), kind, String(arg)))
        end
    end
    return calls
end

# the user of an intrinsic, if it is a call of it that the pass can fold
function checked_call(@nospecialize(user::LLVM.Value), f::LLVM.Function)
    fname = LLVM.name(f)
    location = user isa LLVM.Instruction ?
        " in function $(LLVM.name(LLVM.parent(LLVM.parent(user))))" : ""
    if user isa LLVM.InvokeInst
        throw(CPUFeaturesError("$fname is called with `invoke`$location, which is not supported"))
    elseif !(user isa LLVM.CallInst)
        throw(CPUFeaturesError("$fname is used by `$(strip(string(user)))`$location; it can only be called"))
    elseif LLVM.called_operand(user) != f || count(==(f), LLVM.operands(user)) != 1
        throw(CPUFeaturesError("$fname is passed as an argument by `$(strip(string(user)))`$location; it can only be called"))
    elseif !(LLVM.value_type(user) isa LLVM.IntegerType)
        throw(CPUFeaturesError("$fname returns $(string(LLVM.value_type(user))) in `$(strip(string(user)))`$location; it must return an integer"))
    end
    return user
end

function cpu_features!(mod::LLVM.Module, am, opts::PassOptions)
    dialect = opts.dialect
    calls = cpu_feature_calls(mod, dialect)
    isempty(calls) && return PreservedAnalyses(AllAnalyses)

    # decide everything before changing the module, as some decisions can fail
    run = CPUFeaturesRun(dialect, mod, opts.extra)
    results = try
        map(calls) do (call, kind, arg)
            caller = LLVM.parent(LLVM.parent(call))
            kind === :supports ? cpu_supports(run, arg, caller) : have_fma(run, arg, caller)
        end
    finally
        finish!(run)
    end

    for ((call, _, _), result) in zip(calls, results)
        LLVM.replace_uses!(call, ConstantInt(LLVM.value_type(call), result ? 1 : 0))
        LLVM.erase!(call)
    end
    return PreservedAnalyses(CFGAnalyses)
end

function have_fma(run::CPUFeaturesRun, typ::String, caller::LLVM.Function)
    if run.dialect.cpu_features_rule === :tokens
        return have_fma_tokens(run, typ, caller)
    else
        return have_fma_subtarget(run, typ, caller)
    end
end

## Julia 1.13 and older: features in a feature string

function have_fma_tokens(run::CPUFeaturesRun, typ::String, caller::LLVM.Function)
    triple = run.triple
    LLVM.isaarch64(triple) && return (typ == "f32" || typ == "f64")
    features = something(string_attribute(caller, "target-features"), run.features,
                         Some(nothing))
    features === nothing && return jit_have_fma(run, typ)
    arm, x86 = LLVM.isarm(triple), LLVM.isx86(triple)
    # the first of these features decides; the C++ doesn't look further, so
    # `+fma,-fma` has FMA
    for feature in eachsplit(features, ',')
        if arm
            feature == "+vfp4" && return (typ == "f32" || typ == "f64")
            feature == "+vfp4sp" && return typ == "f32"
        elseif x86
            (feature == "+fma" || feature == "+fma4") && return (typ == "f32" || typ == "f64")
        end
    end
    return false
end

# What the C++ pass decides with the JIT's feature string. That string only has the
# features that it looks for when it is for the same architecture as the module (x86
# or ARM), so it decides like for the code Julia generates for `have_fma`.
function jit_have_fma(run::CPUFeaturesRun, typ::String)
    triple = run.triple
    (LLVM.isx86(triple) || LLVM.isarm(triple)) || return false
    (typ == "f32" || typ == "f64") || return false
    facts = try
        jit = LLVM.Triple(native_probe(:jit_target).triple)
        same_arch = LLVM.isx86(triple) ? LLVM.isx86(jit) : LLVM.isarm(jit)
        same_arch ? native_probe(:jit_fma) : nothing
    catch err
        err isa RuntimeError || rethrow()
        throw(RuntimeError("cannot tell whether the JIT of the running $(running_julia()) has FMA: $(err.msg); give its target features with the option target_features"))
    end
    facts === nothing && return false
    return typ == "f32" ? facts.jit_fma_f32 : facts.jit_fma_f64
end

## Julia master: LLVM's subtarget tables

# The subtarget of a function, like `TargetMachine::getSubtargetImpl(F)` with a target
# machine, and otherwise one for the function's `target-cpu` and `target-features`,
# which replace the options where present. `nothing` if there is no subtarget (no
# target for the triple is registered).
function function_subtarget(run::CPUFeaturesRun, caller::LLVM.Function)
    if run.tm !== nothing
        return try
            LLVM.SubtargetInfo(run.tm, caller)
        catch err
            err isa ArgumentError || rethrow()
            nothing
        end
    end
    cpu = something(string_attribute(caller, "target-cpu"), run.cpu, "")
    features = something(string_attribute(caller, "target-features"), run.features, "")
    return get!(run.subtargets, (cpu, features)) do
        target = subtarget_target(run)
        target === nothing && return nothing
        try
            LLVM.SubtargetInfo(target, subtarget_triple(run); cpu, features)
        catch err
            err isa ArgumentError || rethrow()
            nothing
        end
    end
end

# The triple of the subtargets: the module's. Options describe a target machine, which
# Julia's pipeline gives the pass for modules without a triple too: then the JIT's.
function subtarget_triple(run::CPUFeaturesRun)
    if isempty(string(run.triple)) && (run.cpu !== nothing || run.features !== nothing)
        return LLVM.Triple(native_probe(:jit_target).triple)
    end
    return run.triple
end

function subtarget_target(run::CPUFeaturesRun)
    if run.target === missing
        run.target = try
            LLVM.Target(; triple=string(subtarget_triple(run)))
        catch err
            err isa ArgumentError || rethrow()
            nothing
        end
    end
    return run.target
end

# the names of the features that a subtarget's target knows
function feature_names(run::CPUFeaturesRun, sti::LLVM.SubtargetInfo)
    get!(run.feature_names, Ptr{Cvoid}(Base.unsafe_convert(API.LLVMMCSubtargetInfoRef, sti))) do
        Set(LLVM.processor_features(sti))
    end
end

# whether a subtarget has a feature; LLVM aborts for features it doesn't know
function subtarget_has(run::CPUFeaturesRun, sti::LLVM.SubtargetInfo, feature::String)
    feature in feature_names(run, sti) ||
        throw(CPUFeaturesError("the subtarget for $(sti.triple) has no feature $feature, which the module's triple $(run.triple) needs; the target machine is for another architecture"))
    return LLVM.hasfeature(sti, feature)
end

function have_fma_subtarget(run::CPUFeaturesRun, typ::String, caller::LLVM.Function)
    sti = function_subtarget(run, caller)
    sti === nothing && return false
    triple = run.triple
    if LLVM.isaarch64(triple)
        return typ == "f32" || typ == "f64"
    elseif LLVM.isarm(triple)
        subtarget_has(run, sti, "vfp4") && return (typ == "f32" || typ == "f64")
        subtarget_has(run, sti, "vfp4sp") && return typ == "f32"
        return false
    elseif LLVM.isx86(triple)
        (subtarget_has(run, sti, "fma") || subtarget_has(run, sti, "fma4")) &&
            return (typ == "f32" || typ == "f64")
        return false
    elseif LLVM.isriscv(triple)
        typ == "f32" && return subtarget_has(run, sti, "f")
        typ == "f64" && return subtarget_has(run, sti, "d")
        return false
    end
    return false
end

# Whether every feature of a comma-separated list is a feature of the subtarget's target
# that it has; names it doesn't know (including empty ones) make it false.
function cpu_supports(run::CPUFeaturesRun, list::String, caller::LLVM.Function)
    sti = function_subtarget(run, caller)
    (sti === nothing || isempty(list)) && return false
    names = split(list, ',')
    known = feature_names(run, sti)
    all(in(known), names) || return false
    return all(name -> LLVM.hasfeature(sti, name), names)
end

const CPU_FEATURES = define_pass("jl-cpu-features", :module, cpu_features!; required=true,
                                 extra=(target_cpu=nothing, target_features=nothing,
                                        target_machine=nothing),
                                 cpp_name="CPUFeatures")

"""
    JuliaIR.CPUFeaturesPass(; target_cpu=nothing, target_features=nothing,
                            target_machine=nothing)

Fold the intrinsics that ask about the CPU the code will run on to constants
(`jl-cpu-features` in a pipeline): `julia.cpu.have_fma.<type>`
(`Core.Intrinsics.have_fma`) and, on Julia 1.14 and later, `julia.cpu.supports.<features>`
(`Base.@cpu_supports`). The answer is decided per calling function, by the target it is
compiled for. How depends on the Julia version, like Julia's C++ pass:

- Up to Julia 1.13, the function's `target-features` attribute is searched for features
  that provide FMA (`+fma` or `+fma4` on x86, `+vfp4` or `+vfp4sp` on 32-bit ARM; AArch64
  always has FMA, other architectures never). The first one found decides, and
  implied features don't count. Without the attribute, `target_features` is searched,
  or the feature string of `target_machine`; without either, the answer is the one Julia
  gives for its own JIT. The CPU is never consulted, so `target_cpu` has no effect.
- On Julia 1.14 and later, LLVM's tables for the target are asked whether the
  function's CPU and features enable the features (also through implications, and the
  last setting of a feature wins). They are the function's `target-cpu` and
  `target-features` attributes, each where present, and otherwise `target_cpu` and
  `target_features`, or those of `target_machine`, which Julia's pipeline gives the
  C++ pass. Without any of these, the generic CPU is used, as when the C++ pass runs by
  name (e.g. in `opt`): to use the JIT's target like Julia's pipeline does, pass the
  `cpu` and `features` of [`JuliaIR.jit_target`](@ref). The answer is false for
  triples whose target isn't registered with LLVM; a module without a triple is
  compiled for the JIT's when the target is given by options. Names of features are
  LLVM's, so the answers can depend on the version of LLVM.

The options can't be given in a pipeline's text (feature strings contain commas); with
`jlopt`, they are its `-mcpu` and `-mattr` flags. `target_machine` can't be combined
with the other two.

Intrinsics that aren't called, are passed as arguments or are called with `invoke`
make the pass throw a [`JuliaIR.CPUFeaturesError`](@ref) before it changes the module.
Like Julia's C++ pass, it is required, so it also runs on `optnone` functions.
"""
function CPUFeaturesPass(; target_cpu=nothing, target_features=nothing,
                         target_machine=nothing, kwargs...)
    target_cpu isa AbstractString && (target_cpu = String(target_cpu))
    target_features isa AbstractString && (target_features = String(target_features))
    check_cpu_target(target_cpu, target_features, target_machine)
    return custom_pass(CPU_FEATURES; target_cpu, target_features, target_machine, kwargs...)
end
