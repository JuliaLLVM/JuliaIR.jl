# MultiVersioning: clone functions for several CPU targets, and emit the tables with which
# Julia's image loader picks a version of each function for the CPU it runs on. Port of
# Julia's `src/llvm-multiversioning.cpp`, see docs/src/multiversioning.md.


## targets

# The categories of functions that a target can ask to clone, by what a function contains
# (`collect_func_info`). The bits are those of Julia 1.14's `JL_CLONE_*`.
const CLONE_CATEGORIES = (:loop, :simd, :math, :cpu, :float16, :bfloat16)

clone_bit(category::Symbol) =
    UInt32(1) << (something(findfirst(==(category), CLONE_CATEGORIES)) - 1)

clone_mask(categories) = reduce(|, (clone_bit(c) for c in categories); init=UInt32(0))

clone_categories(mask::Integer) =
    Tuple(c for c in CLONE_CATEGORIES if mask & clone_bit(c) != 0)

# the `JL_TARGET_*` flags of Julia 1.13 and older (`processor.h`), and the bits of 1.14's
# `TargetSpec::packed_flags`
const JL_TARGET_CLONE_ALL = UInt32(1) << 1
const JL_TARGET_OPTSIZE = UInt32(1) << 6
const JL_TARGET_MINSIZE = UInt32(1) << 7
const JL_TARGET_CATEGORIES = (:loop => UInt32(1) << 3, :simd => UInt32(1) << 4,
                              :math => UInt32(1) << 2, :cpu => UInt32(1) << 8,
                              :float16 => UInt32(1) << 9, :bfloat16 => UInt32(1) << 10)
const PACKED_CLONE_ALL = UInt32(1) << 0
const PACKED_OPT_SIZE = UInt32(1) << 1
const PACKED_MIN_SIZE = UInt32(1) << 2
const PACKED_CATEGORIES = (:math => UInt32(1) << 3, :simd => UInt32(1) << 4,
                           :float16 => UInt32(1) << 5, :bfloat16 => UInt32(1) << 6)
# the categories that Julia 1.14 clones for every target that doesn't clone everything
const PACKED_ALWAYS = (:loop, :cpu)

"""
    JuliaIR.MultiVersioningTarget(cpu, features; base=0, clone_all=false, opt_size=false,
                                  min_size=false, clone=())

A target that [`JuliaIR.MultiVersioningPass`](@ref) clones functions for: the name of a
CPU and its features (as in the `target-cpu` and `target-features` function attributes),
and how functions are cloned for it. The first target of a list is the default one, for
which the original functions are kept.

- `clone_all`: clone every function for this target. Such a target (and the first one)
  is the base of a group of targets.
- `base`: for a target that doesn't clone every function, the index (from 0) of the target
  whose version of a function it uses for the functions it doesn't clone; the first target
  or one that clones every function.
- `clone`: for a target that doesn't clone every function, the categories of functions it
  clones, those that contain: `:loop` (loops), `:simd` (vectors), `:math` (fused or fast
  floating-point math), `:cpu` (queries of CPU features), `:float16` (`half` values),
  `:bfloat16` (`bfloat` values, Julia 1.11 and later). Julia 1.14 always clones loops and
  CPU feature queries.
- `opt_size`, `min_size`: optimize the functions cloned for this target for size, or for
  minimal size.

The targets are stored in the module flag `julia.mv.specs` in the encoding of the running
Julia version, see [`JuliaIR.target_specs`](@ref).
"""
struct MultiVersioningTarget
    cpu::String
    features::String
    base::Int
    clone_all::Bool
    opt_size::Bool
    min_size::Bool
    clone::Tuple{Vararg{Symbol}}

    function MultiVersioningTarget(cpu::AbstractString, features::AbstractString;
                                   base::Integer=0, clone_all::Bool=false,
                                   opt_size::Bool=false, min_size::Bool=false, clone=())
        for c in clone
            c in CLONE_CATEGORIES ||
                throw(ArgumentError("unknown clone category $(repr(c)); expected one of $(join(repr.(CLONE_CATEGORIES), ", "))"))
        end
        0 <= base <= typemax(UInt32) ||
            throw(ArgumentError("the base of a target must be an index of 0 or more"))
        new(cpu, features, base, clone_all, opt_size, min_size,
            clone_categories(clone_mask(clone)))
    end
end

function Base.show(io::IO, t::MultiVersioningTarget)
    print(io, "JuliaIR.MultiVersioningTarget(", repr(t.cpu), ", ", repr(t.features))
    t.base == 0 || print(io, "; base=", t.base)
    kwargs = String[]
    t.clone_all && push!(kwargs, "clone_all=true")
    t.opt_size && push!(kwargs, "opt_size=true")
    t.min_size && push!(kwargs, "min_size=true")
    isempty(t.clone) || push!(kwargs, "clone=$(t.clone)")
    if !isempty(kwargs)
        print(io, t.base == 0 ? "; " : ", ", join(kwargs, ", "))
    end
    print(io, ")")
end

"""
    JuliaIR.MultiVersioningError(msg)

The input of [`JuliaIR.MultiVersioningPass`](@ref) can't be processed: e.g., its targets are
malformed, or a global refers to a cloned function in a way that the image loader can't
relocate. Thrown before the module is changed.
"""
struct MultiVersioningError <: Exception
    msg::String
end
Base.showerror(io::IO, e::MultiVersioningError) = print(io, "MultiVersioning: ", e.msg)

# the flags of a target in the encoding of a dialect
function encode_flags(t::MultiVersioningTarget, dialect::Dialect)
    if dialect.mv_spec_flags === :target
        flags = (t.clone_all ? JL_TARGET_CLONE_ALL : UInt32(0)) |
                (t.opt_size ? JL_TARGET_OPTSIZE : UInt32(0)) |
                (t.min_size ? JL_TARGET_MINSIZE : UInt32(0))
        for c in t.clone
            c === :bfloat16 && !dialect.mv_bf16 &&
                throw(ArgumentError("Julia $(dialect.julia) doesn't clone functions for bfloat16"))
            flags |= Dict(JL_TARGET_CATEGORIES)[c]
        end
        return flags
    else
        flags = (t.clone_all ? PACKED_CLONE_ALL : UInt32(0)) |
                (t.opt_size ? PACKED_OPT_SIZE : UInt32(0)) |
                (t.min_size ? PACKED_MIN_SIZE : UInt32(0))
        for c in t.clone
            c in PACKED_ALWAYS && continue
            flags |= Dict(PACKED_CATEGORIES)[c]
        end
        return flags
    end
end

function decode_target(cpu::String, features::String, base::Integer, flags::Integer,
                       dialect::Dialect)
    if dialect.mv_spec_flags === :target
        clone = Symbol[c for (c, bit) in JL_TARGET_CATEGORIES
                       if flags & bit != 0 && (c !== :bfloat16 || dialect.mv_bf16)]
        return MultiVersioningTarget(cpu, features; base,
                                     clone_all = flags & JL_TARGET_CLONE_ALL != 0,
                                     opt_size = flags & JL_TARGET_OPTSIZE != 0,
                                     min_size = flags & JL_TARGET_MINSIZE != 0, clone)
    else
        clone_all = flags & PACKED_CLONE_ALL != 0
        clone = Symbol[c for (c, bit) in PACKED_CATEGORIES if flags & bit != 0]
        clone_all || append!(clone, PACKED_ALWAYS)
        return MultiVersioningTarget(cpu, features; base, clone_all,
                                     opt_size = flags & PACKED_OPT_SIZE != 0,
                                     min_size = flags & PACKED_MIN_SIZE != 0, clone)
    end
end

# a target as the flag encoding of a dialect represents it (Julia 1.14 adds the categories
# it always clones)
normalize_target(t::MultiVersioningTarget, dialect::Dialect) =
    decode_target(t.cpu, t.features, t.base, encode_flags(t, dialect), dialect)

# Module flags are read and added through the `llvm.module.flags` metadata, as LLVM's C
# API can't represent some of their behaviors (`Max`, which `julia.mv.veccall` has).
const MODULE_FLAG_ERROR = 1
const MODULE_FLAG_MAX = 7

# the behavior and value of a module flag, or `nothing` (`Module::getModuleFlag`)
function module_flag(mod::LLVM.Module, name::String)
    flags = get(mod.metadata, "llvm.module.flags", nothing)
    flags === nothing && return nothing
    for flag in flags.operands
        ops = flag.operands
        length(ops) == 3 && ops[2] isa MDString && convert(String, ops[2]) == name ||
            continue
        behavior = metadata_integer(ops[1])
        behavior === nothing && continue
        return (; behavior=Int(behavior), value=ops[3])
    end
    return nothing
end

# `Module::addModuleFlag`: a flag is added even if the module has one of the same name
function add_module_flag!(mod::LLVM.Module, behavior::Int, name::String, value::Metadata)
    i32 = Metadata(ConstantInt(LLVM.Int32Type(), behavior))
    push!(get!(mod.metadata, "llvm.module.flags").operands,
          MDNode([i32, MDString(name), value]))
    return
end
add_module_flag!(mod::LLVM.Module, behavior::Int, name::String, value::Integer) =
    add_module_flag!(mod, behavior, name, Metadata(ConstantInt(LLVM.Int32Type(), value)))

# the integer of a `ConstantAsMetadata`, or `nothing`
function metadata_integer(md)
    md isa ValueAsMetadata || return nothing
    val = Value(md)
    val isa ConstantInt && val.value_type.width <= 64 || return nothing
    return convert(UInt64, val)
end

"""
    JuliaIR.target_specs(mod::LLVM.Module) -> Union{Nothing,Vector{MultiVersioningTarget}}

The targets that [`JuliaIR.MultiVersioningPass`](@ref) clones the functions of `mod` for,
from its `julia.mv.specs` module flag, or `nothing` if it has none. The flag is a tuple of
`!{!"cpu", !"features", i32 base, i32 flags}` tuples, whose flags are encoded like the
running Julia version does: the `JL_TARGET_*` bits of Julia's `processor.h` up to Julia
1.13, or Julia 1.14's `TargetSpec::packed_flags`.
"""
target_specs(mod::LLVM.Module) = target_specs(mod, Dialect(VERSION))

function target_specs(mod::LLVM.Module, dialect::Dialect)
    flag = module_flag(mod, "julia.mv.specs")
    flag === nothing && return nothing
    malformed(what) = throw(MultiVersioningError("the module flag julia.mv.specs is malformed: $what"))
    flag.value isa MDTuple || malformed("not a tuple")
    targets = MultiVersioningTarget[]
    for (i, spec) in enumerate(flag.value.operands)
        spec isa MDTuple && length(spec.operands) == 4 ||
            malformed("target $(i-1) is not a tuple of four elements")
        cpu, features, base, flags = spec.operands
        cpu isa MDString && features isa MDString ||
            malformed("the CPU name and features of target $(i-1) are not strings")
        base = metadata_integer(base)
        flags = metadata_integer(flags)
        base !== nothing && flags !== nothing &&
            base <= typemax(UInt32) && flags <= typemax(UInt32) ||
            malformed("the base and flags of target $(i-1) are not 32-bit integers")
        push!(targets, decode_target(convert(String, cpu), convert(String, features), base,
                                     flags, dialect))
    end
    isempty(targets) && malformed("there are no targets")
    return targets
end

# the `julia.mv.specs` flag for a list of targets (`set_target_specs`)
function set_target_specs!(mod::LLVM.Module, targets::Vector{MultiVersioningTarget},
                           dialect::Dialect)
    i32(x) = Metadata(ConstantInt(LLVM.Int32Type(), x))
    specs = MDNode([MDNode([MDString(t.cpu), MDString(t.features), i32(UInt32(t.base)),
                            i32(encode_flags(t, dialect))]) for t in targets])
    add_module_flag!(mod, MODULE_FLAG_ERROR, "julia.mv.specs", specs)
    return
end

# the targets to clone for: the module's, or the `targets` option if the module has none
function resolve_targets(mod::LLVM.Module,
                         option::Union{Nothing,Vector{MultiVersioningTarget}},
                         dialect::Dialect)
    specs = target_specs(mod, dialect)
    if specs === nothing
        option === nothing &&
            throw(MultiVersioningError("the module has no julia.mv.specs flag and no targets were given (the `targets` option)"))
        # what the module flag will say
        option = [normalize_target(t, dialect) for t in option]
        return option, true
    end
    option === nothing || [normalize_target(t, dialect) for t in option] == specs ||
        throw(MultiVersioningError("the targets given (the `targets` option) differ from the module's julia.mv.specs flag"))
    return specs, false
end

# the targets must form groups: every target that doesn't clone everything uses a version of
# an earlier group base (the first target, or one that clones everything) for what it
# doesn't clone
function check_targets(targets::Vector{MultiVersioningTarget})
    for (i, t) in enumerate(targets)
        i == 1 && continue
        t.clone_all && continue
        t.base < i - 1 && (t.base == 0 || targets[t.base+1].clone_all) ||
            throw(MultiVersioningError("the base of target $(i-1) ($(t.cpu)) is $(t.base), which is neither the first target nor an earlier one that clones every function"))
    end
    return
end


## annotation

is_vector(@nospecialize(ty::LLVMType)) = ty isa LLVM.VectorType || ty isa LLVM.ScalableVectorType

# whether a function type has a vector result or parameter (`is_vector`)
is_vector_function(ft::LLVM.FunctionType) =
    is_vector(LLVM.return_type(ft)) || any(is_vector, LLVM.parameters(ft))

# The categories of a function, and whether it has a vector signature or calls a function
# with one (`collect_func_info`).
function collect_func_info(f::LLVM.Function, am, triple::LLVM.Triple, dialect::Dialect)
    flag = UInt32(0)
    has_veccall = false
    li = am[f][LoopInfo]
    iterate(li) === nothing || (flag |= clone_bit(:loop))
    if is_vector_function(f.function_type)
        flag |= clone_bit(:simd)
        has_veccall = true
    end
    all_flags = clone_mask((:simd, :math, :cpu, :float16)) |
                (dialect.mv_bf16 ? clone_bit(:bfloat16) : UInt32(0))
    for bb in f.blocks, inst in bb.instructions
        if inst isa CallInst
            if is_vector_function(inst.called_type)
                has_veccall = true
                flag |= clone_bit(:simd)
            end
            callee = inst.called_function
            if callee !== nothing
                name = callee.name
                if startswith(name, "llvm.muladd.") || startswith(name, "llvm.fma.")
                    flag |= clone_bit(:math)
                elseif startswith(name, "julia.cpu.")
                    if !startswith(name, "julia.cpu.have_fma.") ||
                       always_have_fma(name, triple) === nothing
                        flag |= clone_bit(:cpu)
                    end
                end
            end
        elseif inst isa StoreInst
            is_vector(inst.operands[1].value_type) && (flag |= clone_bit(:simd))
        elseif is_vector(inst.value_type)
            flag |= clone_bit(:simd)
        end
        if LLVM.supports_fast_math(inst) && any(values(NamedTuple(LLVM.fast_math(inst))))
            flag |= clone_bit(:math)
        end
        for op in inst.operands
            ty = op.value_type
            if ty isa LLVM.HalfType
                flag |= clone_bit(:float16)
            elseif ty isa LLVM.BFloatType && dialect.mv_bf16
                flag |= clone_bit(:bfloat16)
            end
        end
        has_veccall && flag & all_flags == all_flags && return flag, has_veccall
    end
    return flag, has_veccall
end

# The functions defined in a module that the function `f` calls, according to LLVM's call
# graph: direct calls (with the callee's own type), and the callbacks of `!callback`
# metadata of callees. Edges to declarations don't matter here (declarations call no other
# function of the module), so they are left out.
function callees(f::LLVM.Function)
    result = LLVM.Function[]
    for bb in f.blocks, inst in bb.instructions
        inst isa CallBase || continue
        callee = inst.called_function
        callee === nothing && continue
        isdeclaration(callee) || push!(result, callee)
        args = inst.arguments
        for idx in callback_callee_indices(callee)
            idx < length(args) || continue
            cb = strip_pointer_casts(args[idx+1])
            cb isa LLVM.Function && !isdeclaration(cb) && push!(result, cb)
        end
    end
    return result
end

# the argument indices (from 0) of the callees of a function's `!callback` encodings
function callback_callee_indices(f::LLVM.Function)
    node = get(f.metadata, "callback", nothing)
    node === nothing && return Int[]
    indices = Int[]
    for encoding in node.operands
        encoding isa MDNode && !isempty(encoding.operands) || continue
        idx = metadata_integer(encoding.operands[1])
        idx === nothing || push!(indices, Int(idx))
    end
    return indices
end

# The clone sets of the functions of a module and their relocation needs, as computed by
# the annotation or read from the attributes of an annotated module.
struct CloneSets
    # per function with a `julia.mv.clones` attribute: the targets it is cloned for
    clones::Dict{LLVM.Function,BitVector}
    # the functions with a `julia.mv.reloc` attribute, and with `julia.mv.fvar`
    reloc::Set{LLVM.Function}
    fvar::Set{LLVM.Function}
    has_veccall::Bool
end

# the `julia.mv.clones` attribute of a set of targets, as hexadecimal digits of its bits
function clones_string(bits::BitVector)
    x = big(0)
    for i in eachindex(bits)
        bits[i] && (x |= big(1) << (i - 1))
    end
    return uppercase(string(x; base=16))
end

function parse_clones(f::LLVM.Function, str::String, ntargets::Int)
    occursin(r"^[0-9A-Fa-f]+$", str) ||
        throw(MultiVersioningError("the julia.mv.clones attribute of $(f.name) is $(repr(str)), which is not hexadecimal"))
    x = parse(BigInt, str; base=16)
    x >> ntargets == 0 ||
        throw(MultiVersioningError("the julia.mv.clones attribute of $(f.name) is $(repr(str)), which is not a set of the module's $ntargets targets"))
    return BitVector([(x >> (i - 1)) & 1 == 1 for i in 1:ntargets])
end

# the clone sets of an annotated module, from the attributes of its functions
function clone_sets(mod::LLVM.Module, ntargets::Int)
    clones = Dict{LLVM.Function,BitVector}()
    reloc = Set{LLVM.Function}()
    fvar = Set{LLVM.Function}()
    for f in mod.functions
        str = string_attribute(f, "julia.mv.clones")
        str === nothing || (clones[f] = parse_clones(f, str, ntargets))
        haskey(f.function_attributes, "julia.mv.reloc") && push!(reloc, f)
        haskey(f.function_attributes, "julia.mv.fvar") && push!(fvar, f)
    end
    return CloneSets(clones, reloc, fvar, false)
end

# Which targets each function is cloned for, and which functions need a relocation slot
# (`annotate_module_clones`). A target that doesn't clone every function clones the
# functions with one of its categories, and to reduce the number of calls through
# relocation slots, every function that is called by and calls one of them. Unlike the C++
# pass, which visits the functions in the order of their addresses while it extends the
# set, so that the result depends on where the functions happen to be in memory, the set
# is extended until it includes every such function (S-D22(1)).
function annotate_module_clones(mod::LLVM.Module, am, targets::Vector{MultiVersioningTarget},
                                dialect::Dialect)
    triple = LLVM.Triple(mod.triple)
    orig_funcs = [f for f in mod.functions if !isdeclaration(f)]
    ntargets = length(targets)
    infos = Vector{UInt32}(undef, length(orig_funcs))
    has_veccall = false
    for (j, f) in enumerate(orig_funcs)
        infos[j], veccall = collect_func_info(f, am, triple, dialect)
        has_veccall |= veccall
    end
    clones = [falses(ntargets) for _ in orig_funcs]
    subtarget_cloned = falses(length(orig_funcs))

    # the call graph between the definitions, computed when a target needs it
    graph = nothing
    function call_graph()
        graph === nothing || return graph
        index = Dict(f => j for (j, f) in enumerate(orig_funcs))
        graph = [unique!([index[c] for c in callees(f)]) for f in orig_funcs]
        return graph
    end

    for i in 2:ntargets
        if targets[i].clone_all
            foreach(c -> c[i] = true, clones)
            continue
        end
        mask = clone_mask(targets[i].clone)
        selected = [infos[j] & mask != 0 for j in eachindex(orig_funcs)]
        if any(selected)
            children = call_graph()
            changed = true
            while changed
                changed = false
                for j in eachindex(orig_funcs)
                    selected[j] || continue
                    for c in children[j]
                        selected[c] && continue
                        if any(c2 -> selected[c2], children[c])
                            selected[c] = true
                            changed = true
                        end
                    end
                end
            end
        end
        for j in eachindex(orig_funcs)
            if selected[j]
                clones[j][i] = true
                subtarget_cloned[j] = true
            end
        end
    end

    # Functions cloned for a target that only clones some functions need a slot when
    # instructions use them, as the image loader picks the version their callers in the
    # same group call. Functions that aliases name need one for the trampolines that
    # replace the aliases, and other functions in global initializers only an entry in
    # the function table. With a single target, nothing needs either.
    reloc = Set{LLVM.Function}()
    fvar = Set{LLVM.Function}()
    if ntargets > 1
        for (j, f) in enumerate(orig_funcs)
            if subtarget_cloned[j] && !isdone(constant_uses(f, mod, Instruction))
                push!(reloc, f)
            else
                walk = constant_uses(f, mod, GlobalValue)
                isdone(walk) && continue
                alias = false
                while !isdone(walk)
                    if use_info(walk).user isa GlobalAlias
                        alias = true
                        break
                    end
                    next!(walk)
                end
                push!(alias ? reloc : fvar, f)
            end
        end
    end
    sets = Dict(f => c for (f, c) in zip(orig_funcs, clones) if any(c))
    return CloneSets(sets, reloc, fvar, has_veccall)
end

# Whether the module already has the `julia.mv.veccall` flag that the annotation adds. The
# C++ pass adds a second flag, which makes the module invalid; the port keeps an identical
# one, and rejects others (S-D22(6)).
function check_veccall_flag(mod::LLVM.Module)
    flag = module_flag(mod, "julia.mv.veccall")
    flag === nothing && return false
    flag.behavior == MODULE_FLAG_MAX && metadata_integer(flag.value) == 1 &&
        Value(flag.value).value_type == LLVM.Int32Type() ||
        throw(MultiVersioningError("the module already has a julia.mv.veccall flag, which differs from the one the annotation adds (i32 1, behavior Max)"))
    return true
end

# record the annotation in the module: the function attributes and module flags
function annotate!(mod::LLVM.Module, sets::CloneSets, has_veccall_flag::Bool)
    for f in sets.reloc
        push!(f.function_attributes, StringAttribute("julia.mv.reloc", ""))
    end
    for f in sets.fvar
        push!(f.function_attributes, StringAttribute("julia.mv.fvar", ""))
    end
    for (f, c) in sets.clones
        push!(f.function_attributes, StringAttribute("julia.mv.clones", clones_string(c)))
    end
    if sets.has_veccall && !has_veccall_flag
        add_module_flag!(mod, MODULE_FLAG_MAX, "julia.mv.veccall", 1)
    end
    add_module_flag!(mod, MODULE_FLAG_ERROR, "julia.mv.annotated", 1)
    return
end


## checks

# the instructions that have to come first in their block
const EHPad = Union{LLVM.LandingPadInst, LLVM.CatchPadInst, LLVM.CleanupPadInst,
                    LLVM.CatchSwitchInst}

# Whether a module has a table like `jl_fvars` that the `external` option accepts: one
# with an array of constants (which rules out a zero initializer, like the C++ pass).
function has_table(mod::LLVM.Module, name::String)
    gv = get(mod.globals, name, nothing)
    return gv !== nothing && gv.initializer isa ConstantArray
end

function check_table(mod::LLVM.Module, name::String, external::Bool, functions::Bool)
    err(what) = throw(MultiVersioningError("the table $name $what"))
    gv = get(mod.globals, name, nothing)
    gv === nothing && err("is missing")
    init = gv.initializer
    init === nothing && err("has no initializer")
    init.value_type isa LLVM.ArrayType || err("is not an array")
    isempty(gv.uses) || err("is used")
    if !(init isa ConstantArray)
        isnull(init) || err("is not an array of constants")
        init.value_type.length == 0 ||
            err("is zero-initialized, so it has entries that are not functions")
        return
    end
    functions || return
    for (i, entry) in enumerate(init.operands)
        strip_pointer_casts(entry) isa LLVM.Function || external ||
            err("has an entry that is not a function (entry $(i-1))")
    end
end

# A table like `jl_fvar_idxs`, from which the image loader reads a 32-bit index for each of
# the `n` entries of the table that goes with it. The pass only renames it.
function check_index_table(mod::LLVM.Module, name::String, n::Int)
    gv = get(mod.globals, name, nothing)
    gv === nothing && throw(MultiVersioningError("the table $name is missing"))
    ty = gv.global_value_type
    ty isa LLVM.ArrayType && ty.element_type == LLVM.Int32Type() && ty.length >= n ||
        throw(MultiVersioningError("the table $name is not an array of at least $n 32-bit indices"))
end

# The checks for what the C++ pass asserts or crashes on, before the module is changed
# (S-D22). Returns whether to clone the module, rather than only annotate it, which
# `external` does for modules without a usable `jl_fvars` table.
function check_cloning(mod::LLVM.Module, targets::Vector{MultiVersioningTarget},
                       sets::CloneSets, dialect::Dialect, external::Bool)
    offsets = dialect.mv_tables === :offsets
    if external && !(has_table(mod, "jl_fvars") && (!offsets || has_table(mod, "jl_gvars")))
        return false
    end
    check_table(mod, "jl_fvars", external, true)
    offsets && check_table(mod, "jl_gvars", external, false)

    fvar_list = LLVM.Function[f for f in table_elements(mod.globals["jl_fvars"], external)]
    fvars = Set(fvar_list)
    if !(external && isempty(fvars))
        check_index_table(mod, "jl_fvar_idxs", length(fvar_list))
        offsets && check_index_table(mod, "jl_gvar_idxs",
                                     length(table_elements(mod.globals["jl_gvars"], false)))
        suffix = module_flag(mod, "julia.mv.suffix")
        suffix === nothing || suffix.value isa MDString ||
            throw(MultiVersioningError("the module flag julia.mv.suffix is not a string"))
    end

    function_index(f) = f in fvars ||
        throw(MultiVersioningError("$(f.name) needs a relocation, but is not in the table jl_fvars"))
    # the checks go over the functions in module order, so that of several violations, the
    # error names the same one in every run (the sets are ordered by hash)
    for f in mod.functions
        f in sets.reloc || continue
        haskey(sets.clones, f) ||
            throw(MultiVersioningError("$(f.name) has a julia.mv.reloc attribute, but no julia.mv.clones attribute"))
        isdeclaration(f) || function_index(f)
    end

    # the functions that targets that clone everything need a version of
    for (i, t) in enumerate(targets)
        i > 1 && t.clone_all || continue
        uncloned(f) = !get(sets.clones, f, falses(i))[i]
        for f in mod.functions
            (!isdeclaration(f) || haskey(sets.clones, f) || f in fvars) && uncloned(f) &&
                throw(MultiVersioningError("$(f.name) is not cloned for target $(i-1) ($(t.cpu)), which clones every function"))
        end
    end

    for f in mod.functions
        clones = get(sets.clones, f, nothing)
        clones === nothing && continue
        # uses by instructions of versions that call the version the image loader picks
        # (`fix_inst_uses`)
        if any(clones[i] && !targets[i].clone_all for i in 2:length(targets))
            walk = constant_uses(f, mod, Instruction)
            while !isdone(walk)
                user = use_info(walk).user
                user_f = user.parent.parent
                if haskey(sets.clones, user_f)
                    f in sets.reloc ||
                        throw(MultiVersioningError("$(f.name) is called by $(user_f.name), which is cloned, but has no julia.mv.reloc attribute"))
                    # the load from the slot would have to come before the pad
                    load_position(user, Use(use_info(walk).use)) isa EHPad &&
                        throw(MultiVersioningError("$(f.name) can't be loaded from its relocation slot in $(user_f.name), which is cloned: the load would come before an exception handling instruction"))
                end
                next!(walk)
            end
        end
        # uses by global values other than the tables, which cloning takes out of the
        # module first (`fix_gv_uses`)
        walk = constant_uses(f, mod, GlobalValue)
        while !isdone(walk)
            info = use_info(walk)
            user = info.user
            if user.name == "jl_fvars" || offsets && user.name == "jl_gvars"
                next!(walk)
                continue
            end
            what = "$(f.name) is cloned, but used by $(user.name)"
            info.samebits ||
                throw(MultiVersioningError("$what through a constant that changes its address"))
            if user isa GlobalAlias
                f in sets.reloc ||
                    throw(MultiVersioningError("$what, an alias, and has no julia.mv.reloc attribute"))
                is_vector_function(f.function_type) &&
                    throw(MultiVersioningError("$what, an alias, and has vector arguments or results"))
            elseif user isa GlobalVariable
                user.constant &&
                    throw(MultiVersioningError("$what, a constant global variable"))
                user.name in ("llvm.used", "llvm.compiler.used") &&
                    throw(MultiVersioningError("$what"))
                function_index(f)
            else
                throw(MultiVersioningError("$what, which is neither a global variable nor an alias"))
            end
            next!(walk)
        end
    end
    return true
end


## cloning

# A target and its value map, which maps the functions of its group's base to the target's
# clones of them (and, once cloned, their contents).
struct CloneTarget
    idx::Int
    vmap::ValueMap
end

# The first target or one that clones every function, and the targets that clone some
# functions and otherwise use its versions.
struct CloneGroup
    base::CloneTarget
    clones::Vector{CloneTarget}
end

# a value map entry, treating the identity entries that cloning adds for the global values
# it doesn't change as missing (`map_get`)
function map_get(vmap::ValueMap, @nospecialize(key::Value))
    val = get(vmap, key, nothing)
    return val === nothing || val == key ? nothing : val
end

# the group's version of a function
base_func(grp::CloneGroup, f::LLVM.Function) =
    grp.base.idx == 0 ? f : grp.base.vmap[f]::LLVM.Function

has_subtarget_clone(grp::CloneGroup, f::LLVM.Function) =
    any(t -> map_get(t.vmap, base_func(grp, f)) !== nothing, grp.clones)

mutable struct CloneCtx
    mod::LLVM.Module
    dialect::Dialect
    tbaa_const::MDNode
    targets::Vector{MultiVersioningTarget}
    sets::CloneSets
    groups::Vector{CloneGroup}
    # the targets by index (from 1): a group base or a clone in a group
    linearized::Vector{CloneTarget}
    # the group of each target
    group_of::Vector{CloneGroup}
    # the function table `jl_fvars`, and the index of each of its functions (from 1)
    fvars::Vector{LLVM.Function}
    func_ids::Dict{LLVM.Function,Int}
    # Julia 1.10: the global variable table `jl_gvars`
    gvars::Vector{Constant}
    T_size::LLVMType
    # the functions with a body or clones, in module order
    orig_funcs::Vector{LLVM.Function}
    # addresses in global initializers to write the address of a function to, with the
    # function's index in `fvars` (from 0)
    gv_relocs::Vector{Tuple{Constant,Int}}
    # the relocation slots of functions defined in the module, by index in `fvars` (from
    # 0), and of functions defined elsewhere
    const_relocs::Dict{Int,GlobalVariable}
    extern_relocs::Dict{LLVM.Function,GlobalVariable}
    external::Bool
    builder::IRBuilder
end

function target_groups(targets::Vector{MultiVersioningTarget})
    groups = CloneGroup[CloneGroup(CloneTarget(0, ValueMap()), CloneTarget[])]
    group_of = Vector{CloneGroup}(undef, length(targets))
    group_of[1] = groups[1]
    for i in 2:length(targets)
        t = targets[i]
        if t.clone_all
            push!(groups, CloneGroup(CloneTarget(i - 1, ValueMap()), CloneTarget[]))
            group_of[i] = groups[end]
        else
            group_of[i] = group_of[t.base+1]
            push!(group_of[i].clones, CloneTarget(i - 1, ValueMap()))
        end
    end
    linearized = Vector{CloneTarget}(undef, length(targets))
    for grp in groups
        for t in grp.clones
            linearized[t.idx+1] = t
        end
        linearized[grp.base.idx+1] = grp.base
    end
    return groups, linearized, group_of
end

# The elements of a table like `jl_fvars` (an array of pointers), with casts stripped. With
# `external`, entries that aren't function definitions are left out, as happens in reduced
# test cases (the C++ pass drops every entry after the first such one; S-D22(5)).
function table_elements(gv::GlobalVariable, external::Bool)
    init = gv.initializer
    isnull(init) &&
        return Constant[null(init.value_type.element_type) for _ in 1:init.value_type.length]
    elements = Constant[]
    for entry in init.operands
        val = strip_pointer_casts(entry)::Constant
        external && !(val isa LLVM.Function && !isdeclaration(val)) && continue
        push!(elements, val)
    end
    return elements
end

# take a table out of the module, so that it doesn't show up as a use (`consume_gv`)
function consume_table!(gv::GlobalVariable)
    init = gv.initializer
    erase!(gv)
    !isnull(init) && isempty(init.uses) && LLVM.unsafe_destroy!(init)
    return
end

function CloneCtx(mod::LLVM.Module, targets::Vector{MultiVersioningTarget}, sets::CloneSets,
                  dialect::Dialect, external::Bool, builder::IRBuilder)
    groups, linearized, group_of = target_groups(targets)
    fvars_gv = mod.globals["jl_fvars"]
    fvars = LLVM.Function[f for f in table_elements(fvars_gv, external)]
    consume_table!(fvars_gv)
    gvars = Constant[]
    if dialect.mv_tables === :offsets
        gvars_gv = mod.globals["jl_gvars"]
        gvars = table_elements(gvars_gv, false)
        consume_table!(gvars_gv)
    end
    func_ids = Dict{LLVM.Function,Int}(f => i for (i, f) in enumerate(fvars))
    orig_funcs = [f for f in mod.functions if !isdeclaration(f) || haskey(sets.clones, f)]
    return CloneCtx(mod, dialect, tbaa_const(), targets, sets, groups, linearized, group_of,
                    fvars, func_ids, gvars, intptr(mod.datalayout), orig_funcs,
                    Tuple{Constant,Int}[], Dict{Int,GlobalVariable}(),
                    Dict{LLVM.Function,GlobalVariable}(), external, builder)
end

function dispose_maps(ctx::CloneCtx)
    for grp in ctx.groups
        dispose(grp.base.vmap)
        foreach(t -> dispose(t.vmap), grp.clones)
    end
end

# the index of a function in `fvars`, from 0 (`get_func_id`)
func_id(ctx::CloneCtx, f::LLVM.Function) = ctx.func_ids[f] - 1

reloc_slot(ctx::CloneCtx, f::LLVM.Function) =
    isdeclaration(f) ? ctx.extern_relocs[f] : ctx.const_relocs[func_id(ctx, f)]

function load_slot!(ctx::CloneCtx, ty::LLVMType, slot::GlobalVariable)
    load = load!(ctx.builder, ty, slot)
    load.metadata[LLVM.MD_tbaa] = ctx.tbaa_const
    load.metadata[LLVM.MD_invariant_load] = MDNode(Metadata[])
    return load
end

# A function that calls `f` through its relocation slot (`create_trampoline`), after
# initializing the runtime if `autoinit`. The call has the calling convention and the
# return and parameter attributes of `f`, except `julia.return_roots` (the trampoline has
# no GC frame, and its caller roots what it passes on). Julia 1.13 introduced that; the
# port does it for every version (S-D22(2)), as calls that don't match the ABI of `f`, e.g.
# for `byval` and `sret` parameters, pass their arguments wrong.
function create_trampoline!(ctx::CloneCtx, f::LLVM.Function, slot::GlobalVariable;
                            autoinit::Bool=false)
    ft = f.function_type
    trampoline = LLVM.Function(ctx.mod, "", ft)
    copy_attributes!(trampoline, f)
    trampoline.visibility = LLVM.API.LLVMHiddenVisibility
    trampoline.dso_local = true
    delete!(trampoline.function_attributes, "julia.mv.reloc")
    delete!(trampoline.function_attributes, "julia.mv.clones")

    builder = ctx.builder
    position!(builder, LLVM.at_end(BasicBlock(trampoline, "top")))
    builder.debug_location = nothing
    if autoinit
        init_ft = LLVM.FunctionType(LLVM.PointerType())
        init = get(ctx.mod.functions, "ijl_autoinit_and_adopt_thread", nothing)
        init === nothing &&
            (init = LLVM.Function(ctx.mod, "ijl_autoinit_and_adopt_thread", init_ft))
        call!(builder, init_ft, init)
    end
    ptr = load_slot!(ctx, f.value_type, slot)
    call = call!(builder, ft, ptr, collect(trampoline.parameters))
    call.callconv = f.callconv
    append!(call.return_attributes, collect(f.return_attributes))
    for i in 1:length(ft.parameters), attr in collect(f.parameter_attributes[i])
        attr isa StringAttribute && attr.kind == "julia.return_roots" && continue
        push!(call.argument_attributes[i], attr)
    end
    # musttail isn't supported on ARM and PowerPC, which the C++ asserts; release builds
    # emit it anyway, which the port follows (S-D22(7))
    call.tailcall_kind = isvararg(ft) ? LLVM.TailCallKind.MustTail : LLVM.TailCallKind.Tail
    ft.return_type == LLVM.VoidType() ? ret!(builder) : ret!(builder, call)
    return trampoline
end

# a relocation slot for every function marked `julia.mv.reloc` (`prepare_slots`)
function prepare_slots!(ctx::CloneCtx)
    for f in ctx.orig_funcs
        f in ctx.sets.reloc || continue
        slot = GlobalVariable(ctx.mod, f.value_type, f.name * ".reloc_slot")
        slot.visibility = LLVM.API.LLVMHiddenVisibility
        slot.dso_local = true
        if isdeclaration(f)
            ctx.extern_relocs[f] = slot
        else
            ctx.const_relocs[func_id(ctx, f)] = slot
            if ctx.dialect.mv_autoinit
                # entry points can be called through their slot before the image loader
                # filled it in, so that has to initialize the runtime
                trampoline = create_trampoline!(ctx, f, slot; autoinit=true)
                trampoline.name = f.name * ".autoinit_trampoline"
                slot.initializer = trampoline
            else
                slot.initializer = null(f.value_type)
            end
        end
    end
end

# the declarations of the clones of every function (`clone_decls`)
function clone_decls!(ctx::CloneCtx)
    for f in ctx.orig_funcs
        clones = get(ctx.sets.clones, f, nothing)
        clones === nothing && continue
        for i in 2:length(ctx.targets)
            clones[i] || continue
            new_f = LLVM.Function(ctx.mod, f.name * "." * string(i - 1), f.function_type)
            new_f.linkage = f.linkage
            copy_attributes!(new_f, f)
            new_f.visibility = f.visibility
            new_f.dso_local = true
            target = ctx.targets[i]
            base = target.clone_all ? f : base_func(ctx.group_of[target.base+1], f)
            ctx.linearized[i].vmap[base] = new_f
        end
    end
end

function clone_function!(f::LLVM.Function, new_f::LLVM.Function, vmap::ValueMap)
    for (src, dst) in zip(f.parameters, new_f.parameters)
        dst.name = src.name
        vmap[src] = dst
    end
    clone_into!(new_f, f; value_map=vmap,
                changes=API.LLVMCloneFunctionChangeTypeGlobalChanges)
end

# Map the compile units to themselves in the value maps of the targets that clone from a
# group's versions, as cloning would otherwise duplicate them (`prepare_vmap`). The C++
# pass does this before every function it clones; the entries don't change in between, and
# Julia's images have a compile unit per function.
function prepare_vmaps!(ctx::CloneCtx)
    cus = get(ctx.mod.metadata, "llvm.dbg.cu", nothing)
    cus === nothing && return
    units = collect(cus.operands)
    for grp in ctx.groups, target in grp.clones, cu in units
        target.vmap.metadata[cu] = cu
    end
end

function add_features!(f::LLVM.Function, target::MultiVersioningTarget)
    attrs = f.function_attributes
    features = string_attribute(f, "target-features")
    push!(attrs, StringAttribute("target-features",
        features === nothing ? target.features : features * "," * target.features))
    push!(attrs, StringAttribute("target-cpu", target.cpu))
    if !haskey(attrs, :optnone)
        if target.opt_size
            push!(attrs, EnumAttribute("optsize"))
        elseif target.min_size
            push!(attrs, EnumAttribute("minsize"))
        end
    end
end

set_clone_index!(f::LLVM.Function, idx::Int) =
    push!(f.function_attributes, StringAttribute("julia.mv.clone", string(idx)))

# The bodies of the clones (`clone_bodies`): per function, the clone for each group base,
# and from that the clones of the group's other targets. The original functions get the
# features of the first target only at the end, as aliases of them are replaced by
# trampolines with their attributes.
function clone_bodies!(ctx::CloneCtx)
    prepare_vmaps!(ctx)
    for f in ctx.orig_funcs
        for (i, grp) in enumerate(ctx.groups)
            group_f = f
            if i != 1
                group_f = base_func(grp, f)
                isdeclaration(f) || clone_function!(f, group_f, grp.base.vmap)
            end
            for target in grp.clones
                target_f = map_get(target.vmap, group_f)
                target_f === nothing && continue
                isdeclaration(f) || clone_function!(group_f, target_f, target.vmap)
                add_features!(target_f, ctx.targets[target.idx+1])
                set_clone_index!(target_f, target.idx)
            end
            if i != 1
                add_features!(group_f, ctx.targets[grp.base.idx+1])
                set_clone_index!(group_f, grp.base.idx)
            end
        end
    end
end


## uses of the cloned functions

# a constant expression or aggregate like `val`, with other operands
function rebuild_constant(@nospecialize(val::Constant), args::Vector{Constant})
    if val isa ConstantExpr
        return LLVM.with_operands(val, args)
    elseif val isa ConstantArray
        return ConstantArray(val.value_type.element_type, args)
    elseif val isa ConstantStruct
        return ConstantStruct(val.value_type, args)
    else
        return ConstantVector(args)
    end
end

# The initializer of a global that a use walk reached the function from, with null for the
# function (`rewrite_gv_init`): that puts the global in a writable section, and the image
# loader writes the address of the right version there.
function rewrite_gv_init(stack::Vector{UseFrame})
    res = null(Value(stack[1].val).value_type)
    for frame in @view stack[2:end]
        val = Value(frame.val)::Constant
        idx = Use(frame.use).operand_index
        args = Constant[i == idx ? res : op for (i, op) in enumerate(val.operands)]
        res = rebuild_constant(val, args)
    end
    return res
end

# replace an alias of a function by a trampoline that calls it through its relocation slot
# (`rewrite_alias`)
function rewrite_alias!(ctx::CloneCtx, alias::GlobalAlias, f::LLVM.Function)
    trampoline = create_trampoline!(ctx, f, reloc_slot(ctx, f))
    push!(trampoline.function_attributes, StringAttribute("julia.mv.alias", ""))
    alias_name = alias.name
    alias.name = ""
    trampoline.name = alias_name
    trampoline.linkage = alias.linkage
    trampoline.visibility = alias.visibility
    trampoline.dso_local = alias.dso_local
    trampoline.dllstorage = alias.dllstorage
    # the C++ pass erases the alias with its uses, which leaves them dangling
    replace_uses!(alias, trampoline)
    erase!(alias)
end

# Make the uses of cloned functions in global initializers relocations, which the image
# loader fills in with the right version (`fix_gv_uses`), and replace the aliases of
# cloned functions by trampolines.
function fix_gv_uses!(ctx::CloneCtx)
    for f in ctx.orig_funcs
        haskey(ctx.sets.clones, f) || continue
        changed = true
        while changed
            changed = false
            walk = constant_uses(f, ctx.mod, GlobalValue)
            while !isdone(walk)
                changed = true
                info = use_info(walk)
                if info.user isa GlobalAlias
                    rewrite_alias!(ctx, info.user, f)
                else
                    gv = info.user::GlobalVariable
                    addr = const_ptrtoint(gv, ctx.T_size)
                    if info.offset != 0
                        addr = const_add(addr, ConstantInt(ctx.T_size, info.offset))
                    end
                    push!(ctx.gv_relocs, (addr, func_id(ctx, f)))
                    gv.initializer = rewrite_gv_init(walk.stack)
                end
                next!(walk)
            end
        end
    end
end

function finalize_orig_clone_attr!(ctx::CloneCtx)
    for f in ctx.orig_funcs
        haskey(ctx.sets.clones, f) && set_clone_index!(f, 0)
    end
end

# The value that a use walk reaches an instruction with, with `replace` for the function
# (`rewrite_inst_use`): the constant expressions on the way become instructions, and the
# aggregates are built with `insertvalue` and `insertelement`.
function rewrite_inst_use(ctx::CloneCtx, stack::Vector{UseFrame}, replace::Value,
                          pos::LLVM.InsertionPoint)
    builder = ctx.builder
    for frame in @view stack[2:end]
        val = Value(frame.val)::Constant
        idx = Use(frame.use).operand_index
        if val isa ConstantExpr
            old = val.operands[idx]
            inst = Instruction(pos, val)
            ops = inst.operands
            for i in 1:length(ops)
                ops[i] == old && (ops[i] = replace)
            end
            replace = inst
            continue
        end
        args = Constant[i == idx ? UndefValue(op.value_type) : op
                        for (i, op) in enumerate(val.operands)]
        agg = rebuild_constant(val, args)
        position!(builder, pos)
        builder.debug_location = nothing
        replace = if val isa ConstantVector
            insert_element!(builder, agg, replace, ConstantInt(ctx.T_size, idx - 1))
        else
            insert_value!(builder, agg, replace, idx - 1)
        end
    end
    return replace
end

# Where a use of a function by an instruction gets the load from the function's slot
# (`replaceUsesWithLoad`): before the instruction, or for a phi, at the end of the block the
# function comes from.
load_position(user::Instruction, use::Use) =
    user isa LLVM.PHIInst ? LLVM.incoming(user)[use.operand_index][2].terminator : user

# Replace the uses of `f` by instructions for which `slot_of` returns a slot by a load from
# that slot (`replaceUsesWithLoad`).
function replace_uses_with_load!(ctx::CloneCtx, f::LLVM.Function, slot_of)
    builder = ctx.builder
    changed = true
    while changed
        changed = false
        walk = constant_uses(f, ctx.mod, Instruction)
        while !isdone(walk)
            info = use_info(walk)
            user = info.user::Instruction
            slot = slot_of(user)
            if slot !== nothing
                use = Use(info.use)
                pos = LLVM.before(load_position(user, use))
                position!(builder, pos)
                builder.debug_location = nothing
                ptr = load_slot!(ctx, f.value_type, slot)
                user.operands[use.operand_index] = rewrite_inst_use(ctx, walk.stack, ptr, pos)
                changed = true
            end
            next!(walk)
        end
    end
end

# Make the uses of functions by the instructions of the versions of a group that has
# targets with clones of them go through the functions' relocation slots, so that they
# call the version the image loader picked (`fix_inst_uses`). Uses by the clones of the
# group's other targets refer to the clones directly.
function fix_inst_uses!(ctx::CloneCtx)
    for grp in ctx.groups
        grpidx = string(grp.base.idx)
        for orig_f in ctx.orig_funcs
            has_subtarget_clone(grp, orig_f) || continue
            f = base_func(grp, orig_f)
            replace_uses_with_load!(ctx, f, function (inst)
                use_f = inst.parent.parent::LLVM.Function
                string_attribute(use_f, "julia.mv.clone") == grpidx || return nothing
                return reloc_slot(ctx, orig_f)
            end)
        end
    end
end

finalize_orig_features!(ctx::CloneCtx) =
    foreach(f -> add_features!(f, ctx.targets[1]), ctx.orig_funcs)


## tables

const JL_SYSIMG_TAG_MASK = UInt32(1) << 31

# A 32-bit offset from `base` to a pointer or address (`get_ptrdiff32`). Julia 1.10 decides
# whether to truncate from the pointer size of the host; the port decides from the module's,
# like later versions do (S-D3).
function ptrdiff32(ctx::CloneCtx, ptr::Constant, base::Constant)
    ptr.value_type isa LLVM.PointerType && (ptr = const_ptrtoint(ptr, ctx.T_size))
    diff = const_sub(ptr, base)
    return ctx.T_size.width > 32 ? const_trunc(diff, LLVM.Int32Type()) : diff
end

function hidden_global!(ctx::CloneCtx, ty::LLVMType, name::String, init;
                        constant::Bool=true)
    gv = GlobalVariable(ctx.mod, ty, name)
    gv.constant = constant
    init === nothing || (gv.initializer = init)
    gv.visibility = LLVM.API.LLVMHiddenVisibility
    gv.dso_local = true
    return gv
end

# Julia 1.11 and later: the number of entries of a table, and its pointers (`emit_table`)
function emit_table!(ctx::CloneCtx, vars::Vector, name::String, suffix::String)
    ptr = LLVM.PointerType()
    hidden_global!(ctx, ctx.T_size, name * "_count" * suffix,
                   ConstantInt(ctx.T_size, length(vars)))
    ptrs = Constant[const_bitcast(v, ptr) for v in vars]
    hidden_global!(ctx, LLVM.ArrayType(ptr, length(ptrs)), name * "_ptrs" * suffix,
                   ConstantArray(ptr, ptrs); constant=false)
    return
end

# Julia 1.10: a base address, and the number of entries and their offsets from it
# (`emit_offset_table`)
function emit_offset_table!(ctx::CloneCtx, vars::Vector, name::String, suffix::String)
    i32 = LLVM.Int32Type()
    base = if isempty(vars)
        hidden_global!(ctx, ctx.T_size, name * "_base" * suffix, null(ctx.T_size))
    else
        b = const_bitcast(vars[1], LLVM.PointerType())
        ga = GlobalAlias(ctx.mod, ctx.T_size, b, name * "_base" * suffix)
        ga.visibility = LLVM.API.LLVMHiddenVisibility
        ga.dso_local = true
        b
    end
    vbase = const_ptrtoint(base, ctx.T_size)
    offsets = Constant[ConstantInt(i32, length(vars))]
    if !isempty(vars)
        push!(offsets, ConstantInt(i32, 0))
        append!(offsets, (ptrdiff32(ctx, v, vbase) for v in @view vars[2:end]))
    end
    hidden_global!(ctx, LLVM.ArrayType(i32, length(offsets)), name * "_offsets" * suffix,
                   ConstantArray(i32, offsets))
    return vbase
end

# The tables with which the image loader finds the functions, their clones for each target,
# and the relocations to fill in with the versions it picks (`emit_metadata`).
function emit_metadata!(ctx::CloneCtx)
    nfvars = length(ctx.fvars)
    # an image without functions can't be loaded, but this is for reduced test cases
    ctx.external && nfvars == 0 && return
    mod = ctx.mod
    suffix_flag = module_flag(mod, "julia.mv.suffix")
    suffix = suffix_flag === nothing ? "" : convert(String, suffix_flag.value::MDString)
    i32 = LLVM.Int32Type()

    offsets = ctx.dialect.mv_tables === :offsets
    if offsets
        fbase = emit_offset_table!(ctx, ctx.fvars, "jl_fvar", suffix)
        gbase = emit_offset_table!(ctx, ctx.gvars, "jl_gvar", suffix)
        mod.globals["jl_fvar_idxs"].name = "jl_fvar_idxs" * suffix
        mod.globals["jl_gvar_idxs"].name = "jl_gvar_idxs" * suffix
    else
        emit_table!(ctx, ctx.fvars, "jl_fvar", suffix)
        mod.globals["jl_fvar_idxs"].name = "jl_fvar_idxs" * suffix
    end

    # `jl_clone_slots`: the number of relocations, then per relocation the index of the
    # function and the offset of the address to write it to. Julia 1.10 has the offsets
    # relative to the global variables, later versions relative to the table. The C++ pass
    # sorts the relocations by function with `std::sort`, whose order for one function
    # isn't specified; the port keeps the order in which it found them.
    shared_relocs = Set{Int}()
    sort!(ctx.gv_relocs; by=last, alg=Base.Sort.DEFAULT_STABLE)
    values = Constant[ConstantInt(i32, 0)]
    k = 1
    for id in 0:nfvars-1
        while k <= length(ctx.gv_relocs) && ctx.gv_relocs[k][2] == id
            push!(shared_relocs, id)
            push!(values, ConstantInt(i32, id), ctx.gv_relocs[k][1])
            k += 1
        end
        slot = get(ctx.const_relocs, id, nothing)
        if slot !== nothing
            push!(shared_relocs, id)
            push!(values, ConstantInt(i32, id), slot)
        end
    end
    values[1] = ConstantInt(i32, length(values) ÷ 2)
    slots_gv = hidden_global!(ctx, LLVM.ArrayType(i32, length(values)),
                              "jl_clone_slots" * suffix, nothing)
    offsets || (gbase = const_ptrtoint(slots_gv, ctx.T_size))
    for i in 3:2:length(values)
        values[i] = ptrdiff32(ctx, values[i], gbase)
    end
    slots_gv.initializer = ConstantArray(i32, values)

    # `jl_clone_idxs`: per target, the number of functions it has its own version of, with
    # the tag bit for targets that clone everything, then for the others its base, then the
    # indices of the functions, with the tag bit for those that need relocation (the first
    # target and those that clone everything only list those). `jl_clone_ptrs` (or
    # `jl_clone_offsets`) has the versions.
    idxs = UInt32[]
    fptrs = Constant[]
    for (i, target) in enumerate(ctx.targets)
        tgt = ctx.linearized[i]
        len_idx = length(idxs) + 1
        push!(idxs, 0)
        count = UInt32(0)
        if i == 1 || target.clone_all
            grp = ctx.group_of[i]
            count = JL_SYSIMG_TAG_MASK
            for j in 0:nfvars-1
                if j in shared_relocs
                    count += UInt32(1)
                    push!(idxs, j)
                end
                i != 1 && push!(fptrs, base_func(grp, ctx.fvars[j+1]))
            end
        else
            push!(idxs, target.base)
            grp = ctx.group_of[target.base+1]
            for j in 0:nfvars-1
                base_f = base_func(grp, ctx.fvars[j+1])
                f = map_get(tgt.vmap, base_f)
                if j in shared_relocs
                    count += UInt32(1)
                    push!(idxs, JL_SYSIMG_TAG_MASK | UInt32(j))
                    push!(fptrs, something(f, base_f))
                elseif f !== nothing
                    count += UInt32(1)
                    push!(idxs, j)
                    push!(fptrs, f)
                end
            end
        end
        idxs[len_idx] = count
    end
    hidden_global!(ctx, LLVM.ArrayType(i32, length(idxs)), "jl_clone_idxs" * suffix,
                   ConstantDataArray(i32, idxs))
    if offsets
        offs = Constant[ptrdiff32(ctx, f, fbase) for f in fptrs]
        hidden_global!(ctx, LLVM.ArrayType(i32, length(offs)), "jl_clone_offsets" * suffix,
                       ConstantArray(i32, offs))
    else
        ptr = LLVM.PointerType()
        ptrs = Constant[const_bitcast(f, ptr) for f in fptrs]
        hidden_global!(ctx, LLVM.ArrayType(ptr, length(ptrs)), "jl_clone_ptrs" * suffix,
                       ConstantArray(ptr, ptrs))
    end
    return
end

function clone_module!(mod::LLVM.Module, targets::Vector{MultiVersioningTarget},
                       sets::CloneSets, dialect::Dialect, external::Bool)
    @dispose builder=IRBuilder() begin
        ctx = CloneCtx(mod, targets, sets, dialect, external, builder)
        try
            prepare_slots!(ctx)
            clone_decls!(ctx)
            clone_bodies!(ctx)
            fix_gv_uses!(ctx)
            finalize_orig_clone_attr!(ctx)
            fix_inst_uses!(ctx)
            finalize_orig_features!(ctx)
            emit_metadata!(ctx)
        finally
            dispose_maps(ctx)
        end
    end
    return
end


## pass

function run_multiversioning!(mod::LLVM.Module, am, dialect::Dialect, external::Bool,
                              option::Union{Nothing,Vector{MultiVersioningTarget}})
    module_flag(mod, "julia.mv.enable") !== nothing || return false
    targets, add_specs = resolve_targets(mod, option, dialect)
    check_targets(targets)

    # Julia annotates its modules before running the pass; `opt` tests let it annotate
    annotated = module_flag(mod, "julia.mv.annotated") !== nothing
    sets = annotated ? clone_sets(mod, length(targets)) :
                       annotate_module_clones(mod, am, targets, dialect)
    has_veccall_flag = !annotated && sets.has_veccall && check_veccall_flag(mod)
    skipcloning = module_flag(mod, "julia.mv.skipcloning") !== nothing
    clone = !skipcloning && check_cloning(mod, targets, sets, dialect, external)

    add_specs && set_target_specs!(mod, targets, dialect)
    annotated || annotate!(mod, sets, has_veccall_flag)
    clone || return add_specs || !annotated
    clone_module!(mod, targets, sets, dialect, external)
    return true
end

function multiversioning!(mod::LLVM.Module, am, opts::PassOptions)
    changed = run_multiversioning!(mod, am, opts.dialect, opts.extra.external,
                                   opts.extra.targets)
    return changed ? PreservedAnalyses(CFGAnalyses, LoopInfo) : PreservedAnalyses(AllAnalyses)
end

const MULTIVERSIONING = define_pass("jl-multiversioning", :module, multiversioning!;
                                    required=true, cpp_name="JuliaMultiVersioning",
                                    options=(; external=false,
                                             targets=option(
                                                 Union{Nothing,Vector{MultiVersioningTarget}},
                                                 nothing; text=false, valid=!isempty,
                                                 requirement="a non-empty vector of MultiVersioningTarget")))

"""
    JuliaIR.MultiVersioningPass(; external=false, targets=nothing)

Clone the functions of a module for several CPU targets, and emit the tables with which
Julia's image loader picks a version of each function for the CPU it runs on
(`jl-multiversioning` in a pipeline). This is how Julia builds system and package images
that run well on several CPUs. The pass only acts on modules with a `julia.mv.enable`
module flag.

The targets come from the module flag `julia.mv.specs` (see [`JuliaIR.target_specs`](@ref)),
which Julia sets when it builds an image, or for a module without it from `targets` (a
non-empty vector of [`JuliaIR.MultiVersioningTarget`](@ref)s, which the pass then records
in the flag); targets that differ from the module's are an error.

Julia annotates the functions of its modules with the targets to clone them for before it
runs the pass; for modules without the `julia.mv.annotated` flag, the pass annotates them
itself, cloning for each target the functions that benefit from it (with loops, vectors,
fast or fused floating-point math, CPU feature queries, `half` or `bfloat` values, as the
target says) and the functions between them in the call graph.

`external` (`jl-multiversioning<external>`, Julia's `JuliaMultiVersioning<external>`)
tolerates a missing or malformed `jl_fvars` table, as bugpoint produces: without a table,
the module is only annotated, and entries of the table that aren't function definitions are
left out. Input the image loader couldn't handle raises a
[`JuliaIR.MultiVersioningError`](@ref) before the module is changed. Like Julia's C++ pass,
this pass is required (it also runs on `optnone` functions' modules).
"""
MultiVersioningPass(; kwargs...) = custom_pass(MULTIVERSIONING; kwargs...)
