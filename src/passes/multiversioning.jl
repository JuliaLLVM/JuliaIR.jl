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

# the value of a module flag, with its behavior, or `nothing`
function module_flag(mod::LLVM.Module, name::String)
    len = Ref{Csize_t}()
    entries = API.LLVMCopyModuleFlagsMetadata(mod, len)
    try
        for i in 0:Int(len[])-1
            keylen = Ref{Csize_t}()
            key = API.LLVMModuleFlagEntriesGetKey(entries, i, keylen)
            unsafe_string(convert(Ptr{UInt8}, key), keylen[]) == name || continue
            return (; behavior = API.LLVMModuleFlagEntriesGetFlagBehavior(entries, i),
                    value = Metadata(API.LLVMModuleFlagEntriesGetMetadata(entries, i)))
        end
    finally
        entries == C_NULL || API.LLVMDisposeModuleFlagsMetadata(entries)
    end
    return nothing
end

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
    mod.flags["julia.mv.specs", API.LLVMModuleFlagBehaviorError] = specs
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
