# Type lowering

When Julia compiles a function, its code generator decides for every Julia type which
LLVM type represents values of it: `Int64` becomes `i64`, a struct of an `Int8` and an
`Int64` becomes `{ i8, i64 }`, a mutable struct becomes a pointer to a heap-allocated
object (`ptr addrspace(10)`, a "boxed" value), and a type without data like `Nothing`
becomes `void`. Code that works with the IR Julia generates, like GPUCompiler's argument
handling and kernel state, has to build the same types.

Julia's code generator (`jl_type_to_llvm`) only creates types in a context of Julia's own
LLVM library. [`JuliaIR.llvm_type(T)`](@ref JuliaIR.llvm_type) works in a context of any
library: for another library, such as a standalone build of a newer LLVM, it lowers the
type in a temporary context of Julia's LLVM and rebuilds the result in the active context
(the types Julia lowers to are all literal types: integers, floating-point types,
pointers, arrays, vectors and literal structs).

```julia
using LLVM, JuliaIR
@dispose ctx=Context(; opaque_pointers=true) begin
    JuliaIR.llvm_type(Tuple{Int8,Int64})               # { i8, i64 }
    JuliaIR.llvm_type(Vector{Int}; allow_boxed=true)   # ptr addrspace(10)
end
JuliaIR.isboxed(Vector{Int})                           # true
JuliaIR.isghosttype(Nothing)                           # true
```

## Entry points

The functions are not exported:

- [`JuliaIR.llvm_type(T)`](@ref JuliaIR.llvm_type): the LLVM type of values of type `T`,
  in the active context, like LLVM.jl's `convert(LLVMType, T)`; boxed types are an error
  unless `allow_boxed=true`.
- [`JuliaIR.isboxed(T)`](@ref JuliaIR.isboxed): whether `T` is lowered to a box.
- [`JuliaIR.isghosttype(T)`](@ref JuliaIR.isghosttype): whether `T` is lowered to `void`.
- [`JuliaIR.deserves_argbox(T)`](@ref JuliaIR.deserves_argbox),
  [`deserves_retbox`](@ref JuliaIR.deserves_retbox),
  [`deserves_stack`](@ref JuliaIR.deserves_stack) and
  [`deserves_sret(T, llvmT)`](@ref JuliaIR.deserves_sret): how functions that Julia compiles
  receive arguments and return values of type `T`, ported from Julia's
  `src/codegen.cpp`. This differs from `isboxed`: a struct with a reference field that can
  be left undefined is lowered unboxed, but passed boxed.
- [`JuliaIR.check_layout(T, dl)`](@ref JuliaIR.check_layout): a diagnostic that compares
  Julia's layout of `T` with the layout of its LLVM type under a data layout (below).

In a context with typed pointers (as Julia 1.10 and 1.11 create by default), the pointers
of a lowered type can only be rebuilt if Julia's LLVM uses typed pointers as well (LLVM
16 or older).

## How Julia lowers types

The lowering reads the layout that the running Julia computed for each type (field
offsets and sizes, which fields are references, how inline unions are stored), never a
data layout, so its results describe values of the running Julia. In order:

1. `Union{}` lowers to `void`, and so do the types Julia treats as its aliases (see the
   table below).
2. Types whose values Julia boxes (mutable, abstract and non-concrete types) lower to
   `ptr addrspace(10)`.
3. Types without data (`Nothing`, empty structs, structs of such fields) lower to `void`.
4. Primitive types: `Bool` is `i8`, `Float16`/`BFloat16`/`Float32`/
   `Float64` are `half`/`bfloat`/`float`/`double`, `Core.LLVMPtr{T,AS}` is
   `ptr addrspace(AS)`, and any other primitive is an integer of its size in bits.
5. A `MemoryRef` is a pair of a pointer to the element (an `Int` offset for memory of
   unions or of types without data) and the memory object.
6. Other structs and tuples lower by their fields: a reference field becomes
   `ptr addrspace(10)`, fields without data are dropped, and an inline union field
   (`x::Union{Int32,Nothing}`) becomes integers of the union's alignment covering its
   data, then the byte that selects the member (preceded by an empty array of vectors when
   the union is aligned more than Julia's `MAX_ALIGN`). A `VecElement` becomes its
   element; a tuple of identical `VecElement`s whose primitive element has a power-of-two
   byte size becomes an LLVM vector (`NTuple{3,VecElement{Float32}}` is `<3 x float>`);
   fields that all have the
   same LLVM type become an array, everything else a literal struct.

### Differences between Julia versions

The dialect of the running Julia ([`JuliaIR.Dialect`](@ref)) describes what changed:

| | 1.10, 1.11 | 1.12, 1.13 | 1.14 and later |
|---|---|---|---|
| `Ptr{T}` (`cpointer_type`) | integer (`i64`) | `ptr` | `ptr` |
| aliases of `Union{}` (`bottom_aliases`) | none | `typeof(Union{})`, `Type{Union{}}` | `typeof(Union{})`, `Type{Union{}}` (a `Core.TypeEq`) |
| kinds (`boxes_kinds`): `DataType`, `Union`, `UnionAll`, `Core.TypeEq`, ... | lowered by their fields (`Union` is `[2 x ptr addrspace(10)]`) | same | boxed |

Other differences follow from what the running Julia has, not from the dialect:
`BFloat16`, `Memory` and `MemoryRef` exist from Julia 1.11 on, and Julia 1.14 has
primitive types of any number of bits (`primitive type P7 7 end` is `i7`).

Julia's `MAX_ALIGN`, the largest alignment Julia gives a primitive type, caps the
integers that represent an inline union (a union with a larger alignment, like one with
a `VecElement` tuple member, gets the alignment marker). It is 8 on x86-64 before Julia
1.12 and 16 from then on (always 16 on AArch64, 4 on 32-bit x86 before 1.12): there,
`struct S; u::Union{Int128,Int8}; end` lowers to `{ i64, i64, i8 }` before 1.12 and
`{ i128, i8 }` after. Julia doesn't expose `MAX_ALIGN`; `check_layout` reads it as the
alignment Julia gives a 256-bit primitive type. That relies on Julia's rule for
primitive types (their size rounded up to a power of two, capped at `MAX_ALIGN`; the
4-byte alignment of 8-byte types on 32-bit x86 doesn't affect a 32-byte type) and on
`MAX_ALIGN` being at most 32 bytes, which holds on every platform and version.

## Layouts and data layouts

The LLVM types only describe values correctly if LLVM lays them out like Julia: Julia's
code generator addresses fields by their byte offsets, which it maps onto the LLVM type's
elements. The tests check this agreement for a corpus of types under the running Julia's
data layout. [`JuliaIR.check_layout(T, dl)`](@ref JuliaIR.check_layout) reports
differences in size, allocation size (the stride of arrays),
alignment, field offsets and pointer sizes, as
[`JuliaIR.LayoutDivergence`](@ref)s.

For the GPU data layouts in the tests, some types diverge. Consumers must account for these differences when accessing memory:

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

The package tests compare `llvm_type`, `isboxed` and `isghosttype` with Julia's
`jl_type_to_llvm` for a corpus of types that covers every rule, together with the
rebuilding of the result in another context; check the calling-convention queries
against how functions that Julia compiles receive each argument type, and `check_layout`
against the running Julia's data layout and the GPU data layouts above (pinning the
divergences). Julia's own types, carried in bitcode into another context, compare equal to
the rebuilt ones there; with `JULIAIR_TEST_LIBRARY`, that context belongs to another LLVM
library.
