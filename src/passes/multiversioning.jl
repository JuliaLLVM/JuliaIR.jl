# MultiVersioning: clone functions for several CPU targets, and emit the tables with which
# Julia's image loader picks a version of each function for the CPU it runs on. Port of
# Julia's `src/llvm-multiversioning.cpp`, see docs/src/multiversioning.md.


## targets

# The categories of functions that a target can ask to clone, by what a function contains
# (`collect_func_info`). The bits are those of Julia master's `JL_CLONE_*`.
const CLONE_CATEGORIES = (:loop, :simd, :math, :cpu, :float16, :bfloat16)

clone_bit(category::Symbol) =
    UInt32(1) << (something(findfirst(==(category), CLONE_CATEGORIES)) - 1)

clone_mask(categories) = reduce(|, (clone_bit(c) for c in categories); init=UInt32(0))

clone_categories(mask::Integer) =
    Tuple(c for c in CLONE_CATEGORIES if mask & clone_bit(c) != 0)

# the `JL_TARGET_*` flags of Julia 1.13 and older (`processor.h`), and the bits of master's
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
# the categories that Julia master clones for every target that doesn't clone everything
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
  `:bfloat16` (`bfloat` values, Julia 1.11 and later). Julia 1.14 always clones the first
  two of them.
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
    val isa ConstantInt && API.LLVMGetIntTypeWidth(API.LLVMTypeOf(val)) <= 64 ||
        return nothing
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
function resolve_targets(mod::LLVM.Module, option::Vector{MultiVersioningTarget},
                         dialect::Dialect)
    specs = target_specs(mod, dialect)
    if specs === nothing
        isempty(option) &&
            throw(MultiVersioningError("the module has no julia.mv.specs flag and no targets were given (the `targets` option)"))
        # what the module flag will say
        option = [normalize_target(t, dialect) for t in option]
        return option, true
    end
    isempty(option) || [normalize_target(t, dialect) for t in option] == specs ||
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

# whether a function type has a vector result or parameter (`is_vector`)
function is_vector_function(fty::API.LLVMTypeRef)
    is_vector_type(API.LLVMGetReturnType(fty)) && return true
    params = Vector{API.LLVMTypeRef}(undef, API.LLVMCountParamTypes(fty))
    API.LLVMGetParamTypes(fty, params)
    return any(is_vector_type, params)
end

# the function a call calls, if it calls one directly with its own type (C++'s
# `CallBase::getCalledFunction`)
function called_function_ref(call::API.LLVMValueRef)
    callee = API.LLVMGetCalledValue(call)
    API.LLVMIsAFunction(callee) == C_NULL && return nothing
    API.LLVMGlobalGetValueType(callee) == API.LLVMGetCalledFunctionType(call) ||
        return nothing
    return callee
end

ref_name(ref::API.LLVMValueRef) = unsafe_string(API.LLVMGetValueName2(ref, Ref{Csize_t}()))

# The categories of a function, and whether it has a vector signature or calls a function
# with one (`collect_func_info`).
function collect_func_info(f::LLVM.Function, am, triple::LLVM.Triple, dialect::Dialect)
    flag = UInt32(0)
    has_veccall = false
    li = am[f][LoopInfo]
    iterate(li) === nothing || (flag |= clone_bit(:loop))
    if is_vector_function(API.LLVMGlobalGetValueType(f))
        flag |= clone_bit(:simd)
        has_veccall = true
    end
    all_flags = clone_mask((:simd, :math, :cpu, :float16)) |
                (dialect.mv_bf16 ? clone_bit(:bfloat16) : UInt32(0))
    for bb in f.blocks, inst in bb.instructions
        ref = inst.ref
        if API.LLVMIsACallInst(ref) != C_NULL
            if is_vector_function(API.LLVMGetCalledFunctionType(ref))
                has_veccall = true
                flag |= clone_bit(:simd)
            end
            callee = called_function_ref(ref)
            if callee !== nothing
                name = ref_name(callee)
                if startswith(name, "llvm.muladd.") || startswith(name, "llvm.fma.")
                    flag |= clone_bit(:math)
                elseif startswith(name, "julia.cpu.")
                    if !startswith(name, "julia.cpu.have_fma.") ||
                       always_have_fma(name, triple) === nothing
                        flag |= clone_bit(:cpu)
                    end
                end
            end
        elseif API.LLVMIsAStoreInst(ref) != C_NULL
            if is_vector_type(API.LLVMTypeOf(API.LLVMGetOperand(ref, 0)))
                flag |= clone_bit(:simd)
            end
        elseif is_vector_type(API.LLVMTypeOf(ref))
            flag |= clone_bit(:simd)
        end
        if API.LLVMCanValueUseFastMathFlags(ref) != 0 && API.LLVMGetFastMathFlags(ref) != 0
            flag |= clone_bit(:math)
        end
        for i in 0:API.LLVMGetNumOperands(ref)-1
            kind = API.LLVMGetTypeKind(API.LLVMTypeOf(API.LLVMGetOperand(ref, i)))
            if kind == API.LLVMHalfTypeKind
                flag |= clone_bit(:float16)
            elseif kind == API.LLVMBFloatTypeKind && dialect.mv_bf16
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
function callees(f::LLVM.Function, callback_kind::Cuint)
    result = API.LLVMValueRef[]
    for bb in f.blocks, inst in bb.instructions
        ref = inst.ref
        API.LLVMIsACallInst(ref) == C_NULL && API.LLVMIsAInvokeInst(ref) == C_NULL &&
            API.LLVMIsACallBrInst(ref) == C_NULL && continue
        callee = called_function_ref(ref)
        callee === nothing && continue
        API.LLVMIsDeclaration(callee) == 0 && push!(result, callee)
        for idx in callback_callee_indices(callee, callback_kind)
            idx < API.LLVMGetNumArgOperands(ref) || continue
            cb = API.LLVMExtraStripPointerCasts(API.LLVMGetOperand(ref, idx))
            API.LLVMIsAFunction(cb) != C_NULL && API.LLVMIsDeclaration(cb) == 0 &&
                push!(result, cb)
        end
    end
    return result
end

# the argument indices of the callees of a function's `!callback` encodings
function callback_callee_indices(f::API.LLVMValueRef, kind::Cuint)
    n = Ref{Csize_t}()
    entries = API.LLVMGlobalCopyAllMetadata(f, n)
    indices = Int[]
    try
        for i in 0:Int(n[])-1
            API.LLVMValueMetadataEntriesGetKind(entries, i) == kind || continue
            node = Metadata(API.LLVMValueMetadataEntriesGetMetadata(entries, i))
            for encoding in node.operands
                encoding isa MDNode && !isempty(encoding.operands) || continue
                idx = metadata_integer(encoding.operands[1])
                idx === nothing || push!(indices, Int(idx))
            end
        end
    finally
        entries == C_NULL || API.LLVMDisposeValueMetadataEntries(entries)
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

const FUNCTION_INDEX = reinterpret(API.LLVMAttributeIndex, API.LLVMAttributeFunctionIndex)

has_fn_attribute(f::LLVM.Function, kind::String) =
    API.LLVMGetStringAttributeAtIndex(f, FUNCTION_INDEX, kind, length(kind)) != C_NULL

# the clone sets of an annotated module, from the attributes of its functions
function clone_sets(mod::LLVM.Module, ntargets::Int)
    clones = Dict{LLVM.Function,BitVector}()
    reloc = Set{LLVM.Function}()
    fvar = Set{LLVM.Function}()
    for f in mod.functions
        str = string_attribute(f, "julia.mv.clones")
        str === nothing || (clones[f] = parse_clones(f, str, ntargets))
        has_fn_attribute(f, "julia.mv.reloc") && push!(reloc, f)
        has_fn_attribute(f, "julia.mv.fvar") && push!(fvar, f)
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
        index = Dict(f.ref => j for (j, f) in enumerate(orig_funcs))
        kind = API.LLVMGetMDKindIDInContext(context(mod), "callback", 8)
        graph = [unique!([index[c] for c in callees(f, kind)]) for f in orig_funcs]
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

    # With a single target, nothing is relocated. With a target that clones everything,
    # uses by instructions still have to be redirected to the right version.
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
        API.LLVMGetIntTypeWidth(API.LLVMTypeOf(Value(flag.value))) == 32 ||
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


## pass

function run_multiversioning!(mod::LLVM.Module, am, dialect::Dialect, external::Bool,
                              option::Vector{MultiVersioningTarget})
    module_flag(mod, "julia.mv.enable") !== nothing || return false
    targets, add_specs = resolve_targets(mod, option, dialect)
    check_targets(targets)

    # Julia annotates its modules before running the pass; `opt` tests let it annotate
    annotated = module_flag(mod, "julia.mv.annotated") !== nothing
    sets = annotated ? clone_sets(mod, length(targets)) :
                       annotate_module_clones(mod, am, targets, dialect)
    has_veccall_flag = !annotated && sets.has_veccall && check_veccall_flag(mod)
    skipcloning = module_flag(mod, "julia.mv.skipcloning") !== nothing
    if !skipcloning
        throw(MultiVersioningError("cloning is not implemented yet"))
    end

    add_specs && set_target_specs!(mod, targets, dialect)
    annotated || annotate!(mod, sets, has_veccall_flag)
    return add_specs || !annotated
end

function multiversioning!(mod::LLVM.Module, am, opts::PassOptions)
    changed = run_multiversioning!(mod, am, opts.dialect, opts.extra.external,
                                   opts.extra.targets)
    return changed ? PreservedAnalyses(CFGAnalyses, LoopInfo) : PreservedAnalyses(AllAnalyses)
end

const MULTIVERSIONING = define_pass("jl-multiversioning", :module, multiversioning!;
                                    required=true, cpp_name="",
                                    extra=(; external=false,
                                           targets=MultiVersioningTarget[]))

"""
    JuliaIR.MultiVersioningPass(; external=false, targets=MultiVersioningTarget[])

Clone the functions of a module for several CPU targets, and emit the tables with which
Julia's image loader picks a version of each function for the CPU it runs on
(`jl-multiversioning` in a pipeline). This is how Julia builds system and package images
that run well on several CPUs. The pass only acts on modules with a `julia.mv.enable`
module flag.

The targets come from the module flag `julia.mv.specs` (see [`JuliaIR.target_specs`](@ref)),
which Julia sets when it builds an image, or for a module without it from `targets` (a
vector of [`JuliaIR.MultiVersioningTarget`](@ref)s, which the pass then records in the
flag); targets that differ from the module's are an error.

Julia annotates the functions of its modules with the targets to clone them for before it
runs the pass; for modules without the `julia.mv.annotated` flag, the pass annotates them
itself, cloning for each target the functions that benefit from it (with loops, vectors,
fast or fused floating-point math, CPU feature queries, `half` or `bfloat` values, as the
target says) and the functions between them in the call graph.

`external` (`jl-multiversioning<external>`, Julia's `JuliaMultiVersioning<external>`)
tolerates a missing or malformed `jl_fvars` table, as bugpoint produces; the module is then
only annotated. Input the image loader couldn't handle raises a
[`JuliaIR.MultiVersioningError`](@ref) before the module is changed. Like Julia's C++ pass,
this pass is required (it also runs on `optnone` functions' modules).
"""
MultiVersioningPass(; kwargs...) = custom_pass(MULTIVERSIONING; kwargs...)
