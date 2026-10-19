# Type lowering

When Julia compiles a function, its code generator decides for every Julia type which
LLVM type represents values of it: `Int64` becomes `i64`, a struct of an `Int8` and an
`Int64` becomes `{ i8, i64 }`, a mutable struct becomes a pointer to a heap-allocated
object (`ptr addrspace(10)`, a "boxed" value), and a type without data like `Nothing`
becomes `void`. Code that works with the IR Julia generates, like GPUCompiler's argument
handling and kernel state, has to build the same types.

In a context of Julia's own LLVM, LLVM.jl's `convert(LLVMType, T)` asks Julia's C++ for
them. That only works for Julia's own LLVM library: GPU back-ends that run on a separate
LLVM library need the same types in that library's contexts. JuliaIR.jl ports Julia's
lowering (the "mapping between julia and llvm types" in Julia's `src/cgutils.cpp`) to
Julia, so that it works in any context with opaque pointers:

```julia
using LLVM, JuliaIR
@dispose ctx=Context(; opaque_pointers=true) begin
    JuliaIR.julia_type(Tuple{Int8,Int64})          # { i8, i64 }
    JuliaIR.julia_type(Vector{Int}; allow_boxed=true)  # ptr addrspace(10)
    JuliaIR.isboxed(Vector{Int})                   # true
end
```

## Entry points

The functions are not exported:

- [`JuliaIR.julia_type(T)`](@ref JuliaIR.julia_type): the LLVM type of values of type `T`,
  like `convert(LLVMType, T)`; boxed types are an error unless `allow_boxed=true`. With
  `no_boxing=true`, mutable and other types that would be boxed are lowered by their
  fields instead, like Julia's `jl_struct_to_llvm` (some types, like `Memory`, are still
  boxed).
- [`JuliaIR.isboxed(T)`](@ref JuliaIR.isboxed): whether `julia_type` lowers `T` to a box.
- [`JuliaIR.julia_struct_type(T)`](@ref JuliaIR.julia_struct_type): the representation
  Julia uses for C calls and intrinsics; with `llvmcall=true`, the types that
  `ccall(..., llvmcall, ...)` declares (`Bool` is `i1`, a struct of identical fields is an
  LLVM struct rather than an array).
- [`JuliaIR.deserves_argbox(T)`](@ref JuliaIR.deserves_argbox),
  [`deserves_retbox`](@ref JuliaIR.deserves_retbox),
  [`deserves_stack`](@ref JuliaIR.deserves_stack) and
  [`deserves_sret(T, llvmT)`](@ref JuliaIR.deserves_sret): how functions that Julia compiles
  receive arguments and return values of type `T`. This differs from `isboxed`: a struct
  with a reference field that can be left undefined is lowered unboxed, but passed boxed.
- [`JuliaIR.check_layout(T, dl)`](@ref JuliaIR.check_layout): a diagnostic that compares
  Julia's layout of `T` with the layout of its LLVM type under a data layout (below).

## How types are lowered

The lowering reads the layout that the running Julia computed for each type (field
offsets and sizes, which fields are references, how inline unions are stored), never a
data layout, so its results describe values of the running Julia. In order:

1. `Union{}` lowers to `void`, and so do the types Julia treats as its aliases (see the
   table below).
2. Types whose values Julia boxes (mutable, abstract and non-concrete types) lower to
   `ptr addrspace(10)`.
3. Types without data (`Nothing`, empty structs, structs of such fields) lower to `void`.
4. Primitive types: `Bool` is `i8` (`i1` for `llvmcall`), `Float16`/`BFloat16`/`Float32`/
   `Float64` are `half`/`bfloat`/`float`/`double`, `Core.LLVMPtr{T,AS}` is
   `ptr addrspace(AS)`, and any other primitive is an integer of its size in bits.
5. A `MemoryRef` is a pair of a pointer to the element (an `Int` offset for memory of
   unions or of types without data) and the memory object.
6. Other structs and tuples lower by their fields: a reference field becomes
   `ptr addrspace(10)`, fields without data are dropped, and an inline union field
   (`x::Union{Int32,Nothing}`) becomes integers of the union's alignment covering its
   data, then the byte that selects the member (preceded by an empty array of vectors when
   the union is aligned more than Julia's `MAX_ALIGN`). A `VecElement` becomes its
   element; a tuple of identical `VecElement`s of a power-of-two size becomes an LLVM
   vector (`NTuple{4,VecElement{Float32}}` is `<4 x float>`); fields that all have the
   same LLVM type become an array, everything else a literal struct.

### Differences between Julia versions

The dialect of the running Julia ([`JuliaIR.Dialect`](@ref)) describes what changed:

| | 1.10, 1.11 | 1.12, 1.13 | 1.14 and later |
|---|---|---|---|
| `Ptr{T}` (`cpointer_type`) | integer (`i64`) | `ptr` | `ptr` |
| aliases of `Union{}` (`bottom_aliases`) | none | `typeof(Union{})`, `Type{Union{}}` | `typeof(Union{})`, `Type{Union{}}` (a `Core.TypeEq`) |
| kinds (`boxes_kinds`): `DataType`, `Union`, `UnionAll`, `Core.TypeEq`, ... | lowered by their fields (`Union` is `[2 x ptr addrspace(10)]`) | same | boxed |

Other differences follow from what the running Julia has, not from the dialect:
`BFloat16`, `Memory` and `MemoryRef` exist from Julia 1.11 on, Julia 1.14 has
primitive types of any number of bits (`primitive type P7 7 end` is `i7`), and from 1.11
on, Julia reports the layout of `Memory{T}` through its type constructor's, which makes
`no_boxing` box `Memory{Nothing}` rather than lower it to `void`.

Julia's `MAX_ALIGN`, the largest alignment Julia gives a primitive type, caps the
integers that represent an inline union (a union with a larger alignment, like one with
a `VecElement` tuple member, gets the alignment marker). It is 8 on x86-64 before Julia
1.12 and 16 from then on (always 16 on AArch64, 4 on 32-bit x86 before 1.12): there,
`struct S; u::Union{Int128,Int8}; end` lowers to `{ i64, i64, i8 }` before 1.12 and
`{ i128, i8 }` after. Julia doesn't expose `MAX_ALIGN`; the port reads it as the
alignment Julia gives a 256-bit primitive type. That relies on Julia's rule for
primitive types (their size rounded up to a power of two, capped at `MAX_ALIGN`; the
4-byte alignment of 8-byte types on 32-bit x86 doesn't affect a 32-byte type) and on
`MAX_ALIGN` being at most 32 bytes, which holds on every platform and version.

### Deviations from Julia's C++

Where Julia's C++ aborts the process or dereferences a null pointer, the port throws an
`ArgumentError`:

- lowering a type with an `@atomic` field by its fields (`no_boxing=true`, or
  `julia_struct_type`); before Julia 1.14 this includes `DataType`, and from Julia
  1.12 on `Task`;
- `no_boxing=true` for a type without a layout (an abstract type, a `Union`, a
  `UnionAll`);
- a struct type without a fixed layout (a type with free type parameters).

Lowering these types normally (boxed) works as in the C++. Unlike `convert(LLVMType, T)`,
the port requires a context with opaque pointers (Julia 1.10 and 1.11 create contexts with
typed pointers by default; use `Context(; opaque_pointers=true)` there, or
`convert(LLVMType, T)` if typed pointers are needed). The C++ ignores the address-space
parameter of `GenericMemoryRef`, and so does the port.

## Layouts and data layouts

The LLVM types only describe values correctly if LLVM lays them out like Julia: Julia's
code generator addresses fields by their byte offsets, which it maps onto the LLVM type's
elements. Under the data layout of the running Julia's own target that always holds.
[`JuliaIR.check_layout(T, dl)`](@ref JuliaIR.check_layout) lists where it doesn't under
another data layout: differences in size, allocation size (the stride of arrays),
alignment, field offsets and pointer sizes, as
[`JuliaIR.LayoutDivergence`](@ref)s.

For GPU targets, some types diverge, with the port exactly as with Julia's C++ (so code
for these types and targets is wrong today; the lowering reproduces Julia, not the
target):

- NVPTX aligns 128-bit integers to 16 bytes, which Julia only does from 1.12 on (on
  x86-64): before, `Int128` and structs containing it diverge
  (`struct S; a::Int8; b::Int128; end` is 24 bytes in Julia and 32 in LLVM).
- AMDGPU, Metal (AIR) and SPIR-V align them to 8 bytes, so from Julia 1.12 on, `Int128`,
  primitive types of 16 bytes or more, and structs containing them diverge (the same `S`
  is 32 bytes in Julia and 24 in LLVM).
- AMDGPU's pointers in address spaces 3 (local) and 5 (private) are 4 bytes, while
  Julia's `Core.LLVMPtr` has the host's pointer size (8 bytes on 64-bit hosts):
  `Core.LLVMPtr{T,3}` and structs containing such pointers diverge, even where padding
  keeps the struct's size and field offsets the same.

## Testing

The package tests compare the port with Julia's C++ (`jl_type_to_llvm` and
`jl_struct_to_llvm`) in the same context, for a corpus of types that covers every rule,
on every Julia version; check the `llvmcall` variant against the declarations that
`ccall(..., llvmcall, ...)` emits, the calling-convention queries against how functions
that Julia compiles receive each argument type, and `check_layout` against the running
Julia's data layout and the GPU data layouts above (pinning the divergences). Julia's own
types, carried in bitcode into another context, compare equal to the port's there.
