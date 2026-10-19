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

# Pointer types, by their reference, without wrapping the type of every value.
function scalar_typeref(ty::API.LLVMTypeRef)
    kind = API.LLVMGetTypeKind(ty)
    vector = kind == API.LLVMVectorTypeKind || kind == API.LLVMScalableVectorTypeKind
    return vector ? API.LLVMGetElementType(ty) : ty
end

# whether a value is a pointer, or a pointer or vector of pointers
is_pointer(@nospecialize(v::Value)) =
    API.LLVMGetTypeKind(API.LLVMTypeOf(v)) == API.LLVMPointerTypeKind
is_pointer_like(@nospecialize(v::Value)) =
    API.LLVMGetTypeKind(scalar_typeref(API.LLVMTypeOf(v))) == API.LLVMPointerTypeKind

# the address space of a pointer or vector of pointers, or of their type
pointer_addrspace(@nospecialize(v::Value)) =
    Int(API.LLVMGetPointerAddressSpace(scalar_typeref(API.LLVMTypeOf(v))))
pointer_addrspace(@nospecialize(ty::LLVMType)) =
    Int(API.LLVMGetPointerAddressSpace(scalar_typeref(Base.unsafe_convert(API.LLVMTypeRef, ty))))

# the address space of allocas, from the data layout string (`A<n>`)
function alloca_addrspace(layout::String)
    for spec in split(layout, '-')
        m = match(r"^A(\d+)$", spec)
        m === nothing || return parse(Int, m[1])
    end
    return 0
end

# like C++'s `CallInst::Create(call, bundles, pos)`: the same call with other operand
# bundles (and without metadata), inserted at `pos` (by default before the call), named
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
    if API.LLVMCanValueUseFastMathFlags(call) != 0
        new_call.fast_math = call.fast_math
    end
    new_call.debug_location = call.debug_location
    return new_call
end


## values, calls and attributes

# the type of a value, by its reference
typeref(@nospecialize(v::Value)) = API.LLVMTypeOf(v)

# whether `callee` is the function `f`, which may be absent (`nothing`)
is_fn(f, @nospecialize(callee)) = f !== nothing && callee !== nothing && f == callee

# the integer of a constant, at most INT_MAX (`getLimitedValue(INT_MAX)`)
limited_value(c::LLVM.ConstantInt) = min(convert(UInt64, c), UInt64(typemax(Int32)))

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

intrinsic_is(call::Instruction, intr::Intrinsic) =
    let callee = called_function(call)
        callee !== nothing && LLVM.isintrinsic(callee) && callee.intrinsic == intr
    end

# `Module::getOrInsertFunction`: whatever global has the name (a function of another
# type, an alias) is called with `ft`
function get_or_insert_function!(mod::LLVM.Module, name::String, ft::LLVM.FunctionType)
    f = get(mod.functions, name, nothing)
    f === nothing || return f
    for lookup in (API.LLVMGetNamedGlobalAlias, API.LLVMGetNamedGlobalIFunc)
        ref = lookup(mod, name, length(name))
        ref == C_NULL || return LLVM.Value(ref)
    end
    ref = API.LLVMGetNamedGlobal(mod, name)
    ref == C_NULL || return LLVM.Value(ref)
    return LLVM.Function(mod, name, ft)
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

md_kind(@nospecialize(v::Value), name::String) =
    API.LLVMGetMDKindIDInContext(context(v), name, length(name))

function metadata_by_name(inst::Instruction, name::String)
    kind = md_kind(inst, name)
    for (k, md) in inst.metadata
        k == kind && return md
    end
    return nothing
end

function set_metadata_by_name!(inst::Instruction, name::String, md::Metadata)
    API.LLVMSetMetadata(inst, md_kind(inst, name), API.LLVMMetadataAsValue(context(inst), md))
end


## TBAA

# the integer in a `ConstantAsMetadata` operand
metadata_int(md::Metadata) = convert(Int, Value(md))

# Whether the access tag `tag`, or a type it derives from up to the root, has one of
# `names`, like Julia's `isTBAA`.
function tbaa_derives_from(tag::MDNode, names)
    node = tag
    while length(node.operands) > 1
        parent = node.operands[2]
        parent isa MDNode && !isempty(parent.operands) || return false
        name = parent.operands[1]
        name isa MDString || return false
        convert(String, name) in names && return true
        node = parent
    end
    return false
end

# The access tag `tag` without its immutability flag, like LLVM's
# `MDBuilder::createMutableTBAAAccessTag`: the tag itself if it is mutable, otherwise a
# new tag `!{base, access, i64 offset}`, or `!{base, access, i64 offset, i64 size}` for the
# new TBAA format (whose access types aren't named by a string).
function mutable_tbaa_tag(tag::MDNode)
    ops = tag.operands
    base, access = ops[1], ops[2]
    new_format = access.operands[1] isa MDNode
    flag = new_format ? 5 : 4
    length(ops) < flag && return tag
    metadata_int(ops[flag]) == 0 && return tag
    i64(op) = Metadata(ConstantInt(LLVM.Int64Type(), metadata_int(op)))
    return new_format ? MDNode([base, access, i64(ops[3]), i64(ops[4])]) :
                        MDNode([base, access, i64(ops[3])])
end

# whether `v` has exactly one use (C++'s `hasOneUse`: `fadd %m, %m` uses `%m` twice)
function has_one_use(@nospecialize(v::Value))
    use = API.LLVMGetFirstUse(v)
    return use != C_NULL && API.LLVMGetNextUse(use) == C_NULL
end

# The name of the opcode of `inst` (`Instruction::getOpcodeName`), e.g. for remarks, where
# C++ passes render instructions that way.
function opcode_name(inst::Instruction)
    opcode = API.LLVMGetInstructionOpcode(inst)
    opcode == API.LLVMAtomicCmpXchg && return "cmpxchg"
    opcode == API.LLVMVAArg && return "va_arg"
    # `LLVM.Opcode.FAdd`, or `LLVMFAdd` with older LLVM.jl
    return lowercase(chopprefix(last(split(string(opcode), '.')), "LLVM"))
end


## uses through constants

# A walk over the uses of a constant by instructions or by global values, also through the
# constant expressions and aggregates that use it, like Julia's `ConstantUses`
# (`llvm-codegen-shared.h`). Each step of the walk is a use whose user is of the requested
# kind; the stack of frames leading to it says how the constant gets there. A frame records
# a constant (the root, then the expressions and aggregates on the way), the use by which
# it uses the previous frame's constant (none for the root), and, while the constant's bits
# appear unchanged in it (`samebits`: aggregates, and pointer and bit casts that keep the
# size), at which byte
# offset. The next use of every frame is read before the current one is handed out, so the
# user may change or drop the current use before the walk continues.
struct UseFrame
    use::API.LLVMUseRef
    val::API.LLVMValueRef
    offset::Int
    samebits::Bool
    cur::API.LLVMUseRef
    next::API.LLVMUseRef
end

function UseFrame(use::API.LLVMUseRef, val::API.LLVMValueRef, offset::Integer, samebits::Bool)
    cur = API.LLVMGetFirstUse(val)
    next = cur == C_NULL ? cur : API.LLVMGetNextUse(cur)
    return UseFrame(use, val, offset, samebits, cur, next)
end

function advance(f::UseFrame)
    cur = f.next
    next = cur == C_NULL ? cur : API.LLVMGetNextUse(cur)
    return UseFrame(f.use, f.val, f.offset, f.samebits, cur, next)
end

mutable struct ConstantUses
    stack::Vector{UseFrame}
    datalayout::API.LLVMTargetDataRef
    # whether the walk stops at instructions, or at global values
    instructions::Bool
end

# Walk the uses of the constant `c` of module `mod` by instructions or by global values:
# `for walk = constant_uses(c, mod, T); !isdone(walk); next!(walk) ... use_info(walk) ... end`
function constant_uses(@nospecialize(c::Constant), mod::LLVM.Module, ::Type{T}) where {T}
    T === Instruction || T === GlobalValue || throw(ArgumentError("unsupported user type $T"))
    walk = ConstantUses([UseFrame(API.LLVMUseRef(C_NULL), c.ref, 0, true)],
                        API.LLVMGetModuleDataLayout(mod), T === Instruction)
    forward!(walk)
    return walk
end

isdone(walk::ConstantUses) = isempty(walk.stack)

# the current use, its user, and where the constant is in it (`get_info`)
function use_info(walk::ConstantUses)
    top = walk.stack[end]
    return (; use=top.cur, user=Value(API.LLVMGetUser(top.cur)), offset=top.offset,
            samebits=top.samebits)
end

function next!(walk::ConstantUses)
    walk.stack[end] = advance(walk.stack[end])
    forward!(walk)
    return walk
end

is_aggregate(ref::API.LLVMValueRef) =
    API.LLVMIsAConstantStruct(ref) != C_NULL || API.LLVMIsAConstantArray(ref) != C_NULL ||
    API.LLVMIsAConstantVector(ref) != C_NULL

function forward!(walk::ConstantUses)
    stack = walk.stack
    while !isempty(stack)
        frame = stack[end]
        use = frame.cur
        if use == C_NULL
            pop!(stack)
            continue
        end
        user = API.LLVMGetUser(use)
        if walk.instructions ? API.LLVMIsAInstruction(user) != C_NULL :
                               API.LLVMIsAGlobalValue(user) != C_NULL
            return
        end
        stack[end] = advance(frame)
        if is_aggregate(user)
            if !frame.samebits
                push!(stack, UseFrame(use, user, 0, false))
                continue
            end
            idx = API.LLVMExtraGetOperandNo(use)
            ty = API.LLVMTypeOf(user)
            offset = if API.LLVMIsAConstantStruct(user) != C_NULL
                API.LLVMOffsetOfElement(walk.datalayout, ty, idx)
            else
                API.LLVMABISizeOfType(walk.datalayout, API.LLVMGetElementType(ty)) * idx
            end
            push!(stack, UseFrame(use, user, frame.offset + Int(offset), true))
        elseif API.LLVMIsAConstantExpr(user) != C_NULL
            opcode = API.LLVMGetConstOpcode(user)
            # Unlike Julia's walk, a cast to a narrower or wider type doesn't keep the bits
            # (e.g., `ptrtoint` to `i32` of a 64-bit pointer): the image loader would write
            # a full pointer there, over whatever follows.
            keeps_bits = opcode in (API.LLVMPtrToInt, API.LLVMIntToPtr,
                                    API.LLVMAddrSpaceCast, API.LLVMBitCast) &&
                API.LLVMSizeOfTypeInBits(walk.datalayout, API.LLVMTypeOf(user)) ==
                API.LLVMSizeOfTypeInBits(walk.datalayout, API.LLVMTypeOf(frame.val))
            push!(stack, frame.samebits && keeps_bits ?
                         UseFrame(use, user, frame.offset, true) :
                         UseFrame(use, user, 0, false))
        end
    end
    return
end

