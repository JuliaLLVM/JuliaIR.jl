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
