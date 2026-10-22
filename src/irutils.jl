# IR utilities shared by the passes.

# the metadata and debug location of `src`, like C++'s `copyMetadata`
function copy_metadata!(dst::Instruction, src::Instruction)
    for (kind, md) in src.metadata
        dst.metadata[kind] = md
    end
    dst.debug_location = src.debug_location
    return dst
end

is_special_addrspace(as::Integer) = AS_TRACKED <= as <= AS_LOADED

# the scalar type of a vector type, or the type itself
scalar_type(@nospecialize(t::LLVMType)) =
    t isa Union{VectorType,ScalableVectorType} ? t.element_type : t

# whether a value is a pointer, or a pointer or vector of pointers
is_pointer(@nospecialize(v::Value)) = v.value_type isa PointerType
is_pointer_like(@nospecialize(v::Value)) = scalar_type(v.value_type) isa PointerType

# the address space of a pointer or vector of pointers, or of their type
pointer_addrspace(@nospecialize(v::Value)) = pointer_addrspace(v.value_type)
pointer_addrspace(@nospecialize(ty::LLVMType)) = scalar_type(ty).addrspace

# the address space of allocas, from the data layout string (`A<n>`)
alloca_addrspace(mod::LLVM.Module) = alloca_addrspace(string(mod.datalayout))
function alloca_addrspace(layout::String)
    for spec in split(layout, '-')
        m = match(r"^A(\d+)$", spec)
        m === nothing || return parse(Int, m[1])
    end
    return 0
end

# like C++'s `CallInst::Create(call, bundles, pos)`: the same call with other operand
# bundles (keeping only debug metadata), inserted at `pos` (by default before the call), named
# `name`, which C++ passes as the call's own name
function clone_call!(builder::IRBuilder, call::Instruction,
                     bundles::Vector{OperandBundle}=OperandBundle[];
                     pos::LLVM.InsertionPoint{Instruction}=LLVM.before(call),
                     name::String="")
    position!(builder, pos)
    builder.debug_location = nothing
    new_call = call!(builder, call.called_type, call.called_operand,
                     collect(call.arguments), bundles, name)
    new_call.tailcall_kind = call.tailcall_kind
    new_call.callconv = call.callconv
    for attr in collect(call.function_attributes)
        push!(new_call.function_attributes, attr)
    end
    for attr in collect(call.return_attributes)
        push!(new_call.return_attributes, attr)
    end
    for i in 1:length(call.arguments), attr in collect(call.argument_attributes[i])
        push!(new_call.argument_attributes[i], attr)
    end
    if supports_fast_math(call)
        new_call.fast_math = call.fast_math
    end
    new_call.debug_location = call.debug_location
    return new_call
end


## composite types

is_vector_type(@nospecialize(t::LLVMType)) = t isa Union{VectorType,ScalableVectorType}
is_composite(@nospecialize(t::LLVMType)) =
    t isa Union{StructType,ArrayType,VectorType,ScalableVectorType}

# the number of elements of a struct, array or vector type (the minimum for scalable
# vectors), like `getCompositeNumElements`
composite_num_elements(t::StructType) = length(t.elements)
composite_num_elements(t::Union{ArrayType,VectorType}) = t.length
composite_num_elements(t::ScalableVectorType) = t.min_length

# the type of element `i` (0-based) of a struct, array or vector type
composite_element_type(t::StructType, i::Integer) = t.elements[i+1]
composite_element_type(@nospecialize(t::LLVMType), i::Integer) = t.element_type

# the types contained in a struct, array or vector type (`Type::subtypes`)
subtypes(t::StructType) = collect(t.elements)
subtypes(@nospecialize(t::LLVMType)) = LLVMType[t.element_type]


## values, calls and attributes

# the instructions that have to come first in their block, after any PHIs
const EHPad = Union{LLVM.LandingPadInst, LLVM.CatchPadInst, LLVM.CleanupPadInst,
                    LLVM.CatchSwitchInst}

# the value of a function's string attribute, or `nothing` if it doesn't have it
function string_attribute(f::LLVM.Function, kind::String)
    attr = get(f.function_attributes, kind, nothing)
    return attr === nothing ? nothing : LLVM.value(attr)
end

# whether a function is one of the intrinsics of debug records (`llvm.dbg.*`)
is_debug_intrinsic(f::LLVM.Function) = startswith(LLVM.name(f), "llvm.dbg.")

# whether `callee` is the function `f`, which may be absent (`nothing`)
is_fn(f, @nospecialize(callee)) = f !== nothing && callee !== nothing && f == callee

# The unsigned value of a constant, saturated at INT_MAX (`getLimitedValue(INT_MAX)`).
function limited_value(c::LLVM.ConstantInt)
    limit = UInt64(typemax(Int32))
    bits = LLVM.width(c.value_type)
    bits <= 64 && return min(convert(UInt64, c), limit)
    # a wider constant doesn't convert to UInt64; as a BigInt it is sign-extended, so a
    # negative value is one with the top bit set, which saturates too
    value = convert(BigInt, c)
    return value < 0 ? limit : UInt64(min(value, limit))
end

# the function a call calls, if its type matches (`CallBase::getCalledFunction`)
function called_function(call::Instruction)
    callee = call.called_operand
    callee isa LLVM.Function || return nothing
    callee.function_type == call.called_type || return nothing
    return callee
end

# whether a call is an `IntrinsicInst` (calls a function named `llvm.*`)
function is_intrinsic_call(call::Instruction)
    callee = called_function(call)
    return callee !== nothing && startswith(LLVM.name(callee), "llvm.")
end

# Intrinsic IDs belong to the LLVM library that a pass runs with, so passes look them up
# while processing IR instead of keeping them in constants, which would hold the IDs of
# the library that the package was precompiled with.
intrinsic_is(call::Instruction, intr::Intrinsic) =
    let callee = called_function(call)
        callee !== nothing && LLVM.isintrinsic(callee, intr)
    end

# `Module::getOrInsertFunction`: whatever global has the name (a function of another
# type, an alias) is called with `ft`
function get_or_insert_function!(mod::LLVM.Module, name::String, ft::LLVM.FunctionType)
    for globals in (mod.functions, LLVM.aliases(mod), LLVM.ifuncs(mod), mod.globals)
        gv = get(globals, name, nothing)
        gv === nothing || return gv
    end
    return LLVM.Function(mod, name, ft)
end

# the blocks of a function that are reachable from its entry, in reverse post-order (like
# LLVM's `ReversePostOrderTraversal`, visiting successors in order)
function reverse_postorder_blocks(f::LLVM.Function)
    entry = first(f.blocks)
    order = BasicBlock[]
    seen = Set{BasicBlock}([entry])
    # depth first: each block with the successors it has left to visit
    stack = [(entry, collect(LLVM.successors(LLVM.terminator(entry))), 1)]
    while !isempty(stack)
        bb, succs, i = stack[end]
        if i > length(succs)
            pop!(stack)
            push!(order, bb)
            continue
        end
        stack[end] = (bb, succs, i + 1)
        succ = succs[i]
        succ in seen && continue
        push!(seen, succ)
        push!(stack, (succ, collect(LLVM.successors(LLVM.terminator(succ))), 1))
    end
    return reverse!(order)
end

# position the builder before `inst`, with `inst`'s debug location like C++'s
# `IRBuilder<> builder(inst)`, or without one (`XInst::Create(..., inst)`)
function position_before!(builder::IRBuilder, inst::Instruction; debug::Bool)
    position!(builder, LLVM.before(inst))
    builder.debug_location = debug ? inst.debug_location : nothing
end

# `CallBase::hasFnAttr`: on the call, or on the function it calls, also when the call's
# function type differs from the function's (unlike `called_function`); `kind` is the
# name of an LLVM attribute (a symbol) or of a string attribute
function call_has_fn_attr(call::Instruction, kind::Union{Symbol,String})
    haskey(call.function_attributes, kind) && return true
    callee = call.called_operand
    return callee isa LLVM.Function && haskey(callee.function_attributes, kind)
end

can_return_twice(call::Instruction) = call_has_fn_attr(call, :returns_twice)

# the attributes of a function, on a call of it
function copy_function_attributes!(call::Instruction, f::LLVM.Function)
    for attr in collect(f.function_attributes)
        push!(call.function_attributes, attr)
    end
    for attr in collect(f.return_attributes)
        push!(call.return_attributes, attr)
    end
    for i in 1:length(f.parameters), attr in collect(f.parameter_attributes[i])
        push!(call.argument_attributes[i], attr)
    end
end


## metadata

i64_metadata(x::Integer) = Metadata(ConstantInt(LLVM.Int64Type(), x))

# the integer in a `ConstantAsMetadata` operand
metadata_int(md::Metadata) = convert(Int, Value(md))


## uses and opcodes

# whether `v` has exactly one use (C++'s `hasOneUse`: `fadd %m, %m` uses `%m` twice)
function has_one_use(@nospecialize(v::Value))
    next = iterate(v.uses)
    return next !== nothing && iterate(v.uses, next[2]) === nothing
end
has_no_uses(@nospecialize(v::Value)) = isempty(v.uses)

# The name of the opcode of `inst` (`Instruction::getOpcodeName`), e.g. for remarks, where
# C++ passes render instructions that way.
function opcode_name(inst::Instruction)
    opcode = inst.opcode
    opcode == LLVM.Opcode.AtomicCmpXchg && return "cmpxchg"
    opcode == LLVM.Opcode.VAArg && return "va_arg"
    # `LLVM.Opcode.FAdd` -> `fadd`
    return lowercase(last(split(string(opcode), '.')))
end


## uses through constants

# A walk over the uses of a constant by instructions or by global values, also through the
# constant expressions and aggregates that use it, like Julia's `ConstantUses`
# (`llvm-codegen-shared.h`). Each step of the walk is a use whose user is of the requested
# kind; the stack of frames leading to it says how the constant gets there. A frame records
# a constant (the root, then the expressions and aggregates on the way), the use by which
# it uses the previous frame's constant (none for the root), and, while the constant's bits
# appear unchanged in it (`samebits`: aggregates, and pointer and bit casts that keep the
# size), at which byte offset. The uses of a frame's constant are listed when the walk
# enters the frame, so the user may change or drop the current use before the walk
# continues.
struct UseFrame
    use::Union{Nothing,Use}
    val::Constant
    offset::Int
    samebits::Bool
    uses::Vector{Use}
    i::Int  # the current use
end

UseFrame(use::Union{Nothing,Use}, val::Constant, offset::Integer, samebits::Bool) =
    UseFrame(use, val, offset, samebits, collect(val.uses), 1)

current(f::UseFrame) = f.i <= length(f.uses) ? f.uses[f.i] : nothing
advance(f::UseFrame) = UseFrame(f.use, f.val, f.offset, f.samebits, f.uses, f.i + 1)

mutable struct ConstantUses
    stack::Vector{UseFrame}
    datalayout::DataLayout
    # whether the walk stops at instructions, or at global values
    instructions::Bool
end

# Walk the uses of the constant `c` of module `mod` by instructions or by global values:
# `for walk = constant_uses(c, mod, T); !isdone(walk); next!(walk) ... use_info(walk) ... end`
function constant_uses(@nospecialize(c::Constant), mod::LLVM.Module, ::Type{T}) where {T}
    T === Instruction || T === GlobalValue || throw(ArgumentError("unsupported user type $T"))
    walk = ConstantUses([UseFrame(nothing, c, 0, true)], mod.datalayout, T === Instruction)
    forward!(walk)
    return walk
end

isdone(walk::ConstantUses) = isempty(walk.stack)

# the current use, its user, and where the constant is in it (`get_info`)
function use_info(walk::ConstantUses)
    top = walk.stack[end]
    use = current(top)::Use
    return (; use, user=use.user, offset=top.offset, samebits=top.samebits)
end

function next!(walk::ConstantUses)
    walk.stack[end] = advance(walk.stack[end])
    forward!(walk)
    return walk
end

function forward!(walk::ConstantUses)
    stack = walk.stack
    while !isempty(stack)
        frame = stack[end]
        use = current(frame)
        if use === nothing
            pop!(stack)
            continue
        end
        user = use.user
        if walk.instructions ? user isa Instruction : user isa GlobalValue
            return
        end
        stack[end] = advance(frame)
        if user isa ConstantAggregate
            if !frame.samebits
                push!(stack, UseFrame(use, user, 0, false))
                continue
            end
            ty = user.value_type
            offset = if ty isa StructType
                offsetof(walk.datalayout, ty, use.operand_index)
            else
                abi_size(walk.datalayout, ty.element_type) * (use.operand_index - 1)
            end
            push!(stack, UseFrame(use, user, frame.offset + offset, true))
        elseif user isa ConstantExpr
            opcode = user.opcode
            # Unlike Julia's walk, a cast to a narrower or wider type doesn't keep the bits
            # (e.g., `ptrtoint` to `i32` of a 64-bit pointer): the image loader would write
            # a full pointer there, over whatever follows.
            keeps_bits = opcode in (LLVM.Opcode.PtrToInt, LLVM.Opcode.IntToPtr,
                                    LLVM.Opcode.AddrSpaceCast, LLVM.Opcode.BitCast) &&
                bit_size(walk.datalayout, user.value_type) ==
                bit_size(walk.datalayout, frame.val.value_type)
            push!(stack, frame.samebits && keeps_bits ?
                         UseFrame(use, user, frame.offset, true) :
                         UseFrame(use, user, 0, false))
        end
    end
    return
end

