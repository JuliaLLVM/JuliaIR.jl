# Lowering of Julia types to LLVM types: a port of the "mapping between julia and llvm
# types" in Julia's src/cgutils.cpp (`julia_type_to_llvm`, `_julia_struct_to_llvm`,
# `bitstype_to_llvm`) and of the calling-convention queries of src/codegen.cpp
# (`deserves_stack` and friends). See docs/src/type_lowering.md.
#
# Like the C++, the lowering never consults a data layout: it builds LLVM types from the
# layout that the running Julia computed for each type (field offsets and sizes, which
# fields are references, inline unions), so the results are only meaningful for the
# running Julia. `check_layout` compares them with a data layout.


## facts about the running Julia

# Julia's `GenericMemory` (1.11 and later) changed how the runtime reports layouts, see
# `datatype_layout`, and introduced `GenericMemoryRef`.
const HAS_MEMORY = isdefined(Core, :GenericMemory)

# `MAX_ALIGN` (Julia's src/julia_internal.h, src/julia.h before 1.12), the largest
# alignment Julia gives a primitive type, which caps the integers that represent inline
# unions. Julia aligns a primitive type to its size rounded up to a power of two, capped at
# `MAX_ALIGN`; the only other rule, 4-byte alignment of 8-byte types on 32-bit x86 outside
# Windows, doesn't apply to a 32-byte type. So the alignment of a 256-bit primitive is `MAX_ALIGN`, as long
# as that is at most 32 bytes (it is at most 16 on every platform and version).
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
# fields, for `Memory{T}`). Throws where the C++ dereferences a null layout.
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

# `jl_datatype_nbits` of a primitive type: Julia 1.14 stores primitives of any number of
# bits (`primitive type P7 7`) and reports the bits that are not used.
primitive_bits(T::DataType) =
    @static isdefined(Core, :bitsizeof) ? Int(Core.bitsizeof(T)) : 8 * sizeof(T)

# `jl_struct_try_layout`: whether `T` has a layout, computing it if the runtime deferred
# that (asking for a field offset makes it compute the layout, or fail when the type has
# none).
function try_layout(T::DataType)
    T.layout != C_NULL && return true
    HAS_MEMORY && T.name === Base.typename(Core.GenericMemory) && return true
    fieldcount(T) == 0 && return false
    try
        fieldoffset(T, 1)
    catch
        return false
    end
    return T.layout != C_NULL
end

# the kinds: the types of types (`jl_is_kind`)
const KINDS = (DataType, Union, UnionAll, Core.TypeofBottom,
               (@static isdefined(Core, :TypeEq) ? (Core.TypeEq, Core.TypeEgal) : ())...)
is_kind(@nospecialize(T)) = any(K -> K === T, KINDS)

# `Union{}`, and what the dialect lowers like it (`is_typeofbottom_typealias`)
function is_bottom_alias(@nospecialize(T), d::Dialect)
    T === Union{} && return true
    d.bottom_aliases === :bottom && return false
    # `typeof(Union{})` is hidden from inference: Julia 1.10's fails internally on
    # comparisons with it and with `Type{Union{}}`, which are `==` but not `===`
    # (JuliaLang/julia#56913, fixed in 1.11)
    T === Base.inferencebarrier(Core.TypeofBottom) && return true
    if d.bottom_aliases === :typeofbottom_super
        return T === Type{Union{}}
    end
    # `:some_type`: `Type{Union{}}` is a `Core.TypeEq` object
    @static if isdefined(Core, :TypeEq)
        return (T isa Core.TypeEq || T isa Core.TypeEgal) && T.T === Union{}
    end
    return false
end

# `jl_is_concrete_immutable`
is_concrete_immutable(@nospecialize(T), d::Dialect) =
    T isa DataType && !ismutabletype(T) && isconcretetype(T) &&
    !(d.boxes_kinds && is_kind(T))

is_tuple_type(T::DataType) = T.name === Base.typename(Tuple)
is_vecelement_type(@nospecialize(T)) = T isa DataType && T.name === Base.typename(VecElement)
is_cpointer_type(T::DataType) = T.name === Base.typename(Ptr)
is_llvmpointer_type(T::DataType) = T.name === Base.typename(Core.LLVMPtr)
is_array_type(T::DataType) = T.name === Base.typename(Array)
is_genericmemory_type(T::DataType) = HAS_MEMORY && T.name === Base.typename(Core.GenericMemory)
is_genericmemoryref_type(T::DataType) = HAS_MEMORY && T.name === Base.typename(Core.GenericMemoryRef)

# `jl_special_vector_alignment`, as of Julia 1.14 (whose odd-bit primitives can't be
# vector elements; older versions have no odd-bit primitives): the alignment of an
# `NTuple{n,T}` that is lowered to an LLVM vector, or 0 if it isn't one.
function special_vector_alignment(n::Int, @nospecialize(T))
    is_vecelement_type(T) || return 0
    E = fieldtype(T, 1)
    (E isa DataType && isprimitivetype(E)) || return 0
    size = sizeof(E)
    ispow2(size) || return 0
    primitive_bits(E) == 8size || return 0
    return nextpow(2, n * size)
end


## lowering

# the LLVM type of the Julia type, and whether its values are boxed (passed as a
# `ptr addrspace(10)` to the object)
struct Lowered
    type::LLVMType
    boxed::Bool
end

boxed_type() = Lowered(PointerType(10), true)
unboxed(@nospecialize(T::LLVMType)) = Lowered(T, false)

is_ghost(@nospecialize(T::LLVMType)) = T isa LLVM.VoidType || isemptytype(T)

# `_julia_type_to_llvm`
function lower_type(@nospecialize(T), no_boxing::Bool, d::Dialect)
    is_bottom_alias(T, d) && return unboxed(LLVM.VoidType())
    if is_concrete_immutable(T, d) || no_boxing
        T isa DataType || throw(ArgumentError("$T is not a data type, and has no layout"))
        datatype_size(T) == 0 && return unboxed(LLVM.VoidType())
        return lower_struct(T, false, d)
    end
    return boxed_type()
end

# `_julia_struct_to_llvm`: the representation of a value of type `T` (`llvmcall`: in a
# `ccall` with the `llvmcall` calling convention).
function lower_struct(@nospecialize(T), llvmcall::Bool, d::Dialect)
    is_bottom_alias(T, d) && return unboxed(LLVM.VoidType())
    d.boxes_kinds && is_kind(T) && return boxed_type()
    T isa DataType || return boxed_type()
    isprimitivetype(T) && return unboxed(lower_bitstype(T, llvmcall, d))
    if !isabstracttype(T) &&
       !(T.layout != C_NULL && is_opaque(own_layout(T))) &&
       !is_array_type(T) && !is_genericmemory_type(T)
        is_genericmemoryref_type(T) && return unboxed(lower_memoryref(T, d))
        return unboxed(lower_fields(T, llvmcall, d))
    end
    return boxed_type()
end

# `bitstype_to_llvm`
function lower_bitstype(T::DataType, llvmcall::Bool, d::Dialect)
    T === Bool && return llvmcall ? LLVM.Int1Type() : LLVM.Int8Type()
    T === Float16 && return LLVM.HalfType()
    T === Float32 && return LLVM.FloatType()
    T === Float64 && return LLVM.DoubleType()
    @static if isdefined(Core, :BFloat16)
        T === Core.BFloat16 && return LLVM.BFloatType()
    end
    is_cpointer_type(T) && d.cpointer_type === :pointer && return PointerType(0)
    if is_llvmpointer_type(T)
        as = T.parameters[2]
        as isa Union{Int32,Int64} || error("invalid pointer address space")
        return PointerType(as)
    end
    return LLVM.IntType(primitive_bits(T))
end

# the `GenericMemoryRef` types: the element's address (its index, for memory of unions or
# of types without data) and the memory object
function lower_memoryref(T::DataType, d::Dialect)
    M = fieldtype(T, 2)
    elem = Base.datatype_arrayelem(M)   # 0: inline, 1: boxed, 2: union
    index = elem == 2 || (elem == 0 && own_layout(M).size == 0)
    # `GenericMemoryRef`'s address-space parameter is not used: the C++ always uses 0
    ptr_or_offset = index ? lower_bitstype(Int, false, d) : PointerType(0)
    return StructType(LLVMType[ptr_or_offset, PointerType(10)])
end

# the types that represent an inline union field of `fieldsize` bytes (data, then the
# selector byte): integers sized to make the alignment generally correct, preceded by an
# alignment marker when that alignment exceeds `MAX_ALIGN`
function push_union_field!(elts::Vector{LLVMType}, @nospecialize(U), fieldsize::Int)
    _, _, al = Base.uniontype_layout(U)
    fsz1 = fieldsize - 1
    if fsz1 > 0
        if al > max_align()
            push!(elts, ArrayType(VectorType(LLVM.Int8Type(), al), 0))
            al = max_align()
        end
        for _ in 1:div(fsz1, al)
            push!(elts, LLVM.IntType(8al))
        end
        for _ in 1:rem(fsz1, al)
            push!(elts, LLVM.Int8Type())
        end
    end
    push!(elts, LLVM.Int8Type())
    return elts
end

# the struct case of `_julia_struct_to_llvm`: the fields that hold data, as one LLVM type
function lower_fields(T::DataType, llvmcall::Bool, d::Dialect)
    try_layout(T) ||
        throw(ArgumentError("type $T has no fixed layout, and cannot be lowered"))
    ftypes = fieldtypes(T)
    n = length(ftypes)
    (n == 0 || datatype_size(T) == 0) && return LLVM.VoidType()

    # one element per field, except that fields without data are dropped and inline unions
    # take several
    elts = LLVMType[]
    has_union = false
    desc = Base.DataTypeFieldDesc(T)
    for (i, F) in enumerate(ftypes)
        Base.isfieldatomic(T, i) &&
            throw(ArgumentError("type $T has an atomic field ($(fieldname(T, i))), which cannot be lowered"))
        fd = desc[i]
        if fd.isptr
            push!(elts, PointerType(10))
        elseif F isa Union
            push_union_field!(elts, F, Int(fd.size))
            has_union = true
        else
            lty = lower_struct(F, llvmcall, d).type
            is_ghost(lty) || push!(elts, lty)
        end
    end

    isempty(elts) && return LLVM.VoidType()
    # `VecElement` is unwrapped, unless its element is a union (even a boxed one)
    is_vecelement_type(T) && !(ftypes[1] isa Union) && return only(elts)
    # fields of one LLVM type, none of them dropped, form an array, or a vector for tuples
    # of `VecElement`s of a suitable size
    if !has_union && length(elts) == n && all(==(elts[1]), elts)
        if is_tuple_type(T) && all(F -> F === ftypes[1], ftypes) &&
           special_vector_alignment(n, ftypes[1]) != 0
            return VectorType(elts[1], n)
        elseif is_tuple_type(T) || !llvmcall
            return ArrayType(elts[1], n)
        end
    end
    return StructType(elts)
end


## entry points

function require_opaque_context()
    ctx = context()
    supports_typed_pointers(ctx) &&
        throw(ArgumentError("JuliaIR's type lowering requires a context with opaque pointers; create it with `Context(; opaque_pointers=true)`, or use `convert(LLVMType, T)` in a typed context of Julia's own LLVM"))
    return
end

const DIALECT = Dialect(VERSION)

function check_boxed(@nospecialize(T), l::Lowered, allow_boxed::Bool)
    !allow_boxed && l.boxed && error("Conversion of boxed type $T is not allowed")
    return l.type
end

"""
    JuliaIR.julia_type(T; allow_boxed=false, no_boxing=false)::LLVMType

The LLVM type that Julia's code generator uses for values of the Julia type `T`, in the
current context (which must use opaque pointers): a port of Julia's
`julia_type_to_llvm`, giving the same types as `convert(LLVMType, T)` does in a context of
Julia's own LLVM, but in any context, e.g. of another LLVM library.

The result depends on the running Julia: it is built from the layout of `T` that the
running Julia computed, never from a data layout. Values of types that Julia boxes are
lowered to `ptr addrspace(10)`, which is an error unless `allow_boxed` is set.

With `no_boxing=true`, `T` is lowered like an immutable type even if it is mutable or
abstract, as by Julia's `jl_struct_to_llvm` (which Enzyme uses); the result can still be
boxed (for `Memory`, for example). Types for which Julia's C++ would abort throw an
`ArgumentError` instead: types with atomic fields, types without a layout and types
without a fixed layout.

See also [`JuliaIR.isboxed`](@ref) and [`JuliaIR.julia_struct_type`](@ref).
"""
function julia_type(@nospecialize(T); allow_boxed::Bool=false, no_boxing::Bool=false)
    require_opaque_context()
    return check_boxed(T, lower_type(T, no_boxing, DIALECT), allow_boxed)
end

"""
    JuliaIR.isboxed(T)::Bool

Whether [`JuliaIR.julia_type`](@ref) lowers values of type `T` to a pointer to a boxed
object. This is not the calling convention: whether a function receives an argument of
type `T` as a box is [`JuliaIR.deserves_argbox`](@ref) (a struct with an undefined
reference field is lowered unboxed but passed boxed, for example).
"""
function isboxed(@nospecialize(T))
    require_opaque_context()
    return lower_type(T, false, DIALECT).boxed
end

"""
    JuliaIR.julia_struct_type(T; llvmcall=false, allow_boxed=false)::LLVMType

The structural representation of a value of type `T` that Julia's code generator uses
when calling C (`ccall`, `@cfunction`) and for intrinsics: a port of
`_julia_struct_to_llvm`. Unlike [`JuliaIR.julia_type`](@ref), `T` is not checked to be a
concrete immutable type first, and with `llvmcall=true` the result is the variant that
`ccall(..., llvmcall, ...)` declares: `Bool` is `i1`, and structs (but not tuples) whose
fields have the same LLVM type are LLVM structs rather than arrays. This is no ABI
classification for C calls, which Julia's code generator does separately.
"""
function julia_struct_type(@nospecialize(T); llvmcall::Bool=false, allow_boxed::Bool=false)
    require_opaque_context()
    return check_boxed(T, lower_struct(T, llvmcall, DIALECT), allow_boxed)
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
data layout `dl` gives the LLVM type [`JuliaIR.julia_type`](@ref) lowers `T` to, and return
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
function check_layout(@nospecialize(T), dl::DataLayout)
    require_opaque_context()
    out = LayoutDivergence[]
    l = lower_type(T, false, DIALECT)
    if l.boxed
        check_pointer!(out, string(T), dl)
    else
        check_value!(out, string(T), T, l.type, dl)
    end
    return out
end

compare!(out, path, property, julia, llvm) =
    julia == llvm || push!(out, LayoutDivergence(path, property, julia, llvm))

check_pointer!(out, path, dl) =
    compare!(out, path, :pointer_size, sizeof(Ptr{Cvoid}), storage_size(dl, PointerType(10)))

# a value of type `T` stored inline as `lty`, at the top or in a field: its size and
# alignment, and the layout of its fields
function check_value!(out, path, @nospecialize(T), @nospecialize(lty::LLVMType), dl)
    is_ghost(lty) && return
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
            elts = push_union_field!(LLVMType[], F, Int(fd.size))
            data = elts[1] isa ArrayType ? 2 : 1
            if length(elts) > data
                compare!(out, fpath, :offset, offset, LLVM.offsetof(dl, lty, idx + data - 1))
            end
            compare!(out, string(fpath, " (selector)"), :offset, offset + Int(fd.size) - 1,
                     LLVM.offsetof(dl, lty, idx + length(elts) - 1))
            idx += length(elts)
        elseif fd.isptr || !is_ghost(lower_struct(F, false, DIALECT).type)
            compare!(out, fpath, :offset, offset, LLVM.offsetof(dl, lty, idx))
            check_field!(out, path, T, i, lty.elements[idx], dl)
            idx += 1
        end
    end
end
