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

# Pointer types, by their reference: LLVM.jl doesn't wrap scalable vector types.
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

# the address space of a pointer or vector of pointers
pointer_addrspace(@nospecialize(v::Value)) =
    Int(API.LLVMGetPointerAddressSpace(scalar_typeref(API.LLVMTypeOf(v))))

# the address space of allocas, from the data layout string (`A<n>`)
function alloca_addrspace(layout::String)
    for spec in split(layout, '-')
        m = match(r"^A(\d+)$", spec)
        m === nothing || return parse(Int, m[1])
    end
    return 0
end

# like C++'s `CallInst::Create(call, bundles)`: the same call with other operand bundles,
# inserted before it
function clone_call!(builder::IRBuilder, call::Instruction, bundles::Vector{OperandBundle})
    position!(builder, LLVM.before(call))
    builder.debug_location = nothing
    new_call = call!(builder, call.called_type, call.called_operand,
                     collect(call.arguments), bundles)
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
