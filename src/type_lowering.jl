# Lowering of Julia types to LLVM types. Julia's code generator (`jl_type_to_llvm`) lowers
# them with Julia's LLVM, into a context of that library; for a context of another library,
# the result is rebuilt there. The calling-convention queries port those of Julia's
# src/codegen.cpp (`deserves_stack` and friends). See docs/src/type_lowering.md.


## lowering

# Julia's code generator lowers a type into a context of Julia's LLVM
function julia_type_to_llvm(@nospecialize(T::Type), ctx::Union{Context,API.LLVMContextRef})
    boxed = Ref{Bool}()
    ref = ccall(:jl_type_to_llvm, API.LLVMTypeRef, (Any, API.LLVMContextRef, Ptr{Bool}),
                T, ctx, boxed)
    return ref, boxed[]
end

# call `f` with a temporary context of Julia's LLVM: not an LLVM.jl `Context`, which would
# be kept alive when disposed of while an exception is being handled, and neither activated
# nor changing the current library
function with_julia_context(f; opaque_pointers::Bool=true)
    lib = LLVM.julia_library
    LLVM.check_loaded(lib)
    ref = API.LLVMContextCreate(lib)
    try
        LLVM.atleast(17, lib) || API.LLVMContextSetOpaquePointers(lib, ref, opaque_pointers)
        return f(ref)
    finally
        API.LLVMContextDispose(lib, ref)
    end
end

check_boxed(@nospecialize(T), boxed::Bool, allow_boxed::Bool) =
    !allow_boxed && boxed && error("Conversion of boxed type $T is not allowed")

# rebuild a type of another library in the active context. this only covers the types that
# Julia's code generator lowers Julia types to, which are literal types.
function import_type(lib::LLVM.Library, ref::API.LLVMTypeRef)
    kind = API.LLVMGetTypeKind(lib, ref)
    if kind == API.LLVMVoidTypeKind
        LLVM.VoidType()
    elseif kind == API.LLVMIntegerTypeKind
        LLVM.IntType(API.LLVMGetIntTypeWidth(lib, ref))
    elseif kind == API.LLVMHalfTypeKind
        LLVM.HalfType()
    elseif kind == API.LLVMBFloatTypeKind
        LLVM.BFloatType()
    elseif kind == API.LLVMFloatTypeKind
        LLVM.FloatType()
    elseif kind == API.LLVMDoubleTypeKind
        LLVM.DoubleType()
    elseif kind == API.LLVMPointerTypeKind
        addrspace = API.LLVMGetPointerAddressSpace(lib, ref)
        if !supports_typed_pointers()
            LLVM.PointerType(addrspace)
        elseif !Bool(API.LLVMPointerTypeIsOpaque(lib, ref))
            LLVM.PointerType(import_type(lib, API.LLVMGetElementType(lib, ref)), addrspace)
        else
            error("Cannot lower a Julia type with pointers in a context with typed pointers: Julia's LLVM $(lib.version) only lowers to opaque pointers")
        end
    elseif kind == API.LLVMArrayTypeKind
        n = LLVM.atleast(17, lib) ? API.LLVMGetArrayLength2(lib, ref) :
                                    API.LLVMGetArrayLength(lib, ref)
        LLVM.ArrayType(import_type(lib, API.LLVMGetElementType(lib, ref)), n)
    elseif kind == API.LLVMVectorTypeKind
        LLVM.VectorType(import_type(lib, API.LLVMGetElementType(lib, ref)),
                        API.LLVMGetVectorSize(lib, ref))
    elseif kind == API.LLVMStructTypeKind && Bool(API.LLVMIsLiteralStruct(lib, ref))
        elems = LLVMType[import_type(lib, API.LLVMStructGetTypeAtIndex(lib, ref, i))
                         for i in 0:Int(API.LLVMCountStructElementTypes(lib, ref))-1]
        LLVM.StructType(elems; packed=Bool(API.LLVMIsPackedStruct(lib, ref)))
    else
        str = LLVM.unsafe_message(lib, API.LLVMPrintTypeToString(lib, ref))
        error("Cannot rebuild LLVM type $str of LLVM library :$(lib.name) in another context")
    end
end

"""
    JuliaIR.llvm_type(T; allow_boxed=false)::LLVMType

The LLVM type that Julia's code generator uses for values of the Julia type `T`, in the
active context, which can belong to any LLVM library. Values of types that Julia boxes are
pointers to objects (`ptr addrspace(10)`), which is an error unless `allow_boxed` is set.

Julia's code generator lowers the type with Julia's LLVM; for a context of another
library, the result is rebuilt there. In a context with typed pointers, types that
contain pointers require Julia's LLVM to support typed pointers as well (LLVM 16 or older,
Julia 1.11 and older).

See also [`JuliaIR.isboxed`](@ref) and [`JuliaIR.isghosttype`](@ref).
"""
function llvm_type(@nospecialize(T::Type); allow_boxed::Bool=false)
    ctx = context()
    if ctx.library === LLVM.julia_library
        ref, boxed = julia_type_to_llvm(T, ctx)
        check_boxed(T, boxed, allow_boxed)
        return LLVMType(ref)
    end
    # typed pointers are only used if Julia's LLVM supports them too
    with_julia_context(; opaque_pointers=!supports_typed_pointers(ctx)) do jlctx
        ref, boxed = julia_type_to_llvm(T, jlctx)
        check_boxed(T, boxed, allow_boxed)
        return import_type(LLVM.julia_library, ref)
    end
end

@deprecate julia_type(T; allow_boxed::Bool=false) llvm_type(T; allow_boxed) false

# lower `T` with Julia's code generator, without rebuilding the result, to query it
function query_lowering(f, @nospecialize(T::Type))
    ctx = context(; throw_error=false)
    ctx !== nothing && ctx.library === LLVM.julia_library &&
        return f(julia_type_to_llvm(T, ctx)...)
    return with_julia_context(jlctx -> f(julia_type_to_llvm(T, jlctx)...))
end

"""
    JuliaIR.isboxed(T)::Bool

Whether Julia's code generator represents values of type `T` as pointers to boxed objects
(see [`JuliaIR.llvm_type`](@ref)). This is not the calling convention: whether a function
receives an argument of type `T` as a box is [`JuliaIR.deserves_argbox`](@ref) (a struct
with an undefined reference field is lowered unboxed but passed boxed, for example). It
doesn't need an active context.
"""
isboxed(@nospecialize(T::Type)) = query_lowering((ref, boxed) -> boxed, T)

"""
    JuliaIR.isghosttype(T::Type)::Bool
    JuliaIR.isghosttype(T::LLVMType)::Bool

Whether values of the Julia type `T` have no representation in the code Julia generates,
because they contain no data (`Nothing`, empty structs, `Union{}`): Julia's code generator
lowers `T` to `void` (see [`JuliaIR.llvm_type`](@ref)). For an LLVM type, whether it is
`void` or an empty type. The Julia method doesn't need an active context.
"""
isghosttype(@nospecialize(T::Type)) =
    query_lowering((ref, boxed) -> API.LLVMGetTypeKind(LLVM.julia_library, ref) ==
                                   API.LLVMVoidTypeKind, T)
isghosttype(@nospecialize(T::LLVMType)) = T isa LLVM.VoidType || isemptytype(T)


## facts about the running Julia

# Julia's `GenericMemory` (1.11 and later) changed how the runtime reports layouts, see
# `datatype_layout`.
const HAS_MEMORY = isdefined(Core, :GenericMemory)

# `MAX_ALIGN` (Julia's src/julia_internal.h, src/julia.h before 1.12), the largest
# alignment Julia gives a primitive type, which caps the integers that represent inline
# unions. Julia aligns a primitive type to its size rounded up to a power of two, capped at
# `MAX_ALIGN`; the only other rule, 4-byte alignment of 8-byte types on 32-bit x86 outside
# Windows, doesn't apply to a 32-byte type. So the alignment of a 256-bit primitive is
# `MAX_ALIGN`, as long as that is at most 32 bytes (it is at most 16 on every platform and
# version).
primitive type MaxAlignProbe 256 end
max_align() = Base.datatype_alignment(MaxAlignProbe)

# the layout the runtime computed for `T` (`T->layout`), or `nothing`
function own_layout(T::DataType)
    T.layout == C_NULL && return nothing
    return unsafe_load(Ptr{Base.DataTypeLayout}(T.layout))
end

# `jl_is_layout_opaque`: a layout without fields that the runtime still knows to contain
# references (`String`, `Symbol`, `Memory`, Julia 1.10's `Array`)
is_opaque(L::Base.DataTypeLayout) = L.nfields == 0 && L.npointers > 0

# `jl_datatype_layout`: from Julia 1.11 on, a type without a layout or with an opaque one
# reports the layout of its type constructor's body instead (that of `GenericMemory`'s
# fields, for `Memory{T}`)
function datatype_layout(T::DataType)
    L = own_layout(T)
    if HAS_MEMORY && (L === nothing || is_opaque(L))
        W = Base.unwrap_unionall(T.name.wrapper)
        L = W isa DataType ? own_layout(W) : nothing
    end
    L === nothing && throw(ArgumentError("type $T has no layout"))
    return L
end
datatype_size(T::DataType) = Int(datatype_layout(T).size)

# the kinds: the types of types (`jl_is_kind`)
const KINDS = (DataType, Union, UnionAll, Core.TypeofBottom,
               (@static isdefined(Core, :TypeEq) ? (Core.TypeEq, Core.TypeEgal) : ())...)
is_kind(@nospecialize(T)) = any(K -> K === T, KINDS)

# `jl_is_concrete_immutable`
is_concrete_immutable(@nospecialize(T), d::Dialect) =
    T isa DataType && !ismutabletype(T) && isconcretetype(T) &&
    !(d.boxes_kinds && is_kind(T))

is_vecelement_type(@nospecialize(T)) = T isa DataType && T.name === Base.typename(VecElement)

const DIALECT = Dialect(VERSION)

# The elements that Julia's code generator lowers an inline union field of `fieldsize`
# bytes to: integers sized to the union's alignment (at most `MAX_ALIGN`) covering its
# data, preceded by an alignment marker (`[0 x <al x i8>]`) when that alignment exceeds
# `MAX_ALIGN`, then the selector byte. Returns the number of elements, and the index of
# the first data element among them.
function union_field_elements(@nospecialize(U), fieldsize::Int)
    fsz1 = fieldsize - 1
    fsz1 > 0 || return 1, 1
    _, _, al = Base.uniontype_layout(U)
    marker = al > max_align()
    al = min(al, max_align())
    return marker + div(fsz1, al) + rem(fsz1, al) + 1, marker + 1
end


## calling convention

"""
    JuliaIR.deserves_stack(T)::Bool

Whether Julia's code generator keeps values of type `T` unboxed, passing arguments and
returning results of that type by value (or by reference to a stack copy) rather than as
boxed objects: concrete immutable types that are singletons or can be stored inline. A
port of `deserves_stack` in Julia's src/codegen.cpp.
"""
function deserves_stack(@nospecialize(T))
    is_concrete_immutable(T, DIALECT) || return false
    # `jl_is_datatype_singleton` and `jl_datatype_isinlinealloc(T, 0)`, which is what
    # `Base.allocatedinline` asks the runtime for a `DataType`
    return Base.issingletontype(T) || Base.allocatedinline(T)
end

"""
    JuliaIR.deserves_argbox(T)::Bool

Whether functions that Julia compiles receive arguments of type `T` boxed (as
`ptr addrspace(10)`): `!deserves_stack(T)`.
"""
deserves_argbox(@nospecialize(T)) = !deserves_stack(T)

"""
    JuliaIR.deserves_retbox(T)::Bool

Whether functions that Julia compiles return values of type `T` boxed:
`!deserves_stack(T)`.
"""
deserves_retbox(@nospecialize(T)) = deserves_argbox(T)

"""
    JuliaIR.deserves_sret(T, llvmT::LLVMType)::Bool

Whether a function that returns an unboxed `T`, lowered to `llvmT`, returns it through a
pointer argument (`sret`): values larger than a pointer that are neither floating-point
nor vector values.
"""
deserves_sret(@nospecialize(T), @nospecialize(llvmT::LLVMType)) =
    datatype_size(T) > sizeof(Ptr{Cvoid}) &&
    !(llvmT isa LLVM.FloatingPointType) && !(llvmT isa LLVM.VectorType)


## layout check

"""
    JuliaIR.LayoutDivergence

A difference between the layout of a Julia type and the layout of the LLVM type it is
lowered to, under some data layout, as found by [`JuliaIR.check_layout`](@ref).

- `path`: where in the type, e.g. `"I128.b"`;
- `property`: `:size` (the bytes a value occupies, `sizeof`, which must cover the bytes
  LLVM stores and fit in what it allocates; the value given for LLVM is the bound that is
  violated), `:allocation_size` (the distance between consecutive values in an array:
  `sizeof` rounded up to the alignment vs. LLVM's allocation size), `:alignment`,
  `:offset` (of a field, or of the selector byte of an inline union), or `:pointer_size`
  (of a reference);
- `julia` and `llvm`: the two values, in bytes.
"""
struct LayoutDivergence
    path::String
    property::Symbol
    julia::Int
    llvm::Int
end

Base.show(io::IO, d::LayoutDivergence) =
    print(io, d.path, ": ", d.property, " ", d.julia, " in Julia, ", d.llvm, " in LLVM")

"""
    JuliaIR.check_layout(T, dl::LLVM.DataLayout)::Vector{JuliaIR.LayoutDivergence}

Compare the layout the running Julia uses for values of type `T` with the layout that the
data layout `dl` gives the LLVM type [`JuliaIR.llvm_type`](@ref) lowers `T` to, and return
the differences: the size, allocation size and alignment of `T`, and the offset of every
field that occupies memory, with the size and alignment of the field's value (recursively
for inline fields). An empty result means that code generated for `dl` addresses values
of type `T` like Julia does.

Julia's code generator maps field byte offsets onto LLVM type elements. A divergence
can therefore make field accesses or array strides incorrect unless the consumer adapts
the representation. The lowering itself never consults a data layout; this is a
diagnostic. The tests check agreement with the running Julia's data layout and known
differences for GPU targets.
"""
function check_layout(@nospecialize(T::Type), dl::DataLayout)
    out = LayoutDivergence[]
    if isboxed(T)
        check_pointer!(out, string(T), dl)
    else
        check_value!(out, string(T), T, llvm_type(T), dl)
    end
    return out
end

compare!(out, path, property, julia, llvm) =
    julia == llvm || push!(out, LayoutDivergence(path, property, julia, llvm))

check_pointer!(out, path, dl) =
    compare!(out, path, :pointer_size, sizeof(Ptr{Cvoid}), LLVM.pointersize(dl, 10))

# a value of type `T` stored inline as `lty`, at the top or in a field: its size and
# alignment, and the layout of its fields
function check_value!(out, path, @nospecialize(T), @nospecialize(lty::LLVMType), dl)
    isghosttype(lty) && return
    jsize = datatype_size(T)
    jalign = Base.datatype_alignment(T)
    # Julia's size can include padding that LLVM doesn't store (`<3 x float>`) or
    # allocate (odd-size primitives before Julia 1.14), but must cover what LLVM
    # stores and fit in what it allocates
    store, alloc = storage_size(dl, lty), abi_size(dl, lty)
    jsize < store && compare!(out, path, :size, jsize, store)
    jsize > alloc && compare!(out, path, :size, jsize, alloc)
    compare!(out, path, :allocation_size, cld(jsize, jalign) * jalign, alloc)
    compare!(out, path, :alignment, jalign, abi_alignment(dl, lty))
    T isa DataType && !isprimitivetype(T) && fieldcount(T) > 0 || return
    if is_vecelement_type(T) && !(fieldtype(T, 1) isa Union)
        check_field!(out, path, T, 1, lty, dl)
    elseif lty isa ArrayType || lty isa VectorType
        check_sequence_fields!(out, path, T, lty, dl)
    elseif lty isa StructType
        check_struct_fields!(out, path, T, lty, dl)
    end
    return
end

# a field of `T` stored as an element of type `E`: a reference, or an inline value
function check_field!(out, path, T::DataType, i::Int, @nospecialize(E::LLVMType), dl)
    fpath = string(path, ".", fieldname(T, i))
    if Base.DataTypeFieldDesc(T)[i].isptr
        check_pointer!(out, fpath, dl)
    else
        check_value!(out, fpath, fieldtype(T, i), E, dl)
    end
end

# fields lowered to the elements of an array or vector, one each
function check_sequence_fields!(out, path, T::DataType, lty, dl)
    E = lty.element_type
    for i in 1:fieldcount(T)
        compare!(out, string(path, ".", fieldname(T, i)), :offset, fieldoffset(T, i),
                 (i - 1) * abi_size(dl, E))
        check_field!(out, path, T, i, E, dl)
    end
end

# fields lowered to the elements of a struct: fields without data are dropped, an
# inline union takes several elements
function check_struct_fields!(out, path, T::DataType, lty, dl)
    idx = 1     # the element of the field
    desc = Base.DataTypeFieldDesc(T)
    for i in 1:fieldcount(T)
        fpath = string(path, ".", fieldname(T, i))
        F = fieldtype(T, i)
        fd = desc[i]
        offset = Int(fd.offset)
        if !fd.isptr && F isa Union
            # the data (after an alignment marker, if any), then the selector byte
            n, data = union_field_elements(F, Int(fd.size))
            if n > data
                compare!(out, fpath, :offset, offset, LLVM.offsetof(dl, lty, idx + data - 1))
            end
            compare!(out, string(fpath, " (selector)"), :offset, offset + Int(fd.size) - 1,
                     LLVM.offsetof(dl, lty, idx + n - 1))
            idx += n
        elseif fd.isptr || fd.size > 0
            # (inline fields without data are dropped)
            compare!(out, fpath, :offset, offset, LLVM.offsetof(dl, lty, idx))
            check_field!(out, path, T, i, lty.elements[idx], dl)
            idx += 1
        end
    end
end
