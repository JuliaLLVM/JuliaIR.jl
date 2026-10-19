using LLVM, LLVM.IR, InteractiveUtils

# Types whose lowering exercises every rule, with the definitions they need.
module LoweringCorpus
    struct Pad; a::Int8; b::Int64; c::Int16; end
    struct WithRef; a::Int; s::String; end
    struct WithUnion; a::Int8; u::Union{Int32,Nothing}; end
    struct WithUnion2; u::Union{Int128,Int8}; end
    struct I128; a::Int8; b::Int128; end
    struct Inner; a::Int32; b::Int8; end
    struct Outer; x::Inner; y::Int8; end
    struct Ghost end
    struct WithGhost; a::Int; g::Ghost; b::Float32; end
    struct AllGhost; a::Ghost; b::Nothing; end
    primitive type P24 24 end
    primitive type P128 128 end
    primitive type P256 256 end
    mutable struct Mut; x::Int; end
    struct HasMut; m::Mut; i::Int; end
    struct Hetero; a::Int32; b::Int32; end
    struct VE8; v::NTuple{8,VecElement{Float32}}; end
    struct UHi; a::Int8; u::Union{NTuple{8,VecElement{Float32}},Nothing}; end
    struct Uninit; x::Int; y::String; Uninit(x) = new(x); end
    struct AbsField; x::Integer; y::Int8; end
    struct U3; a::Union{Int16,Int8,Nothing}; b::Union{Float64,Int32}; end
    struct UGhosts; a::Union{Nothing,Missing}; end
    struct UGhostInt; a::Int32; u::Union{Ghost,Int8}; end
    struct NestedPad; a::Int8; t::Tuple{Int8,Int32}; c::Int8; end
    struct WithLP; a::Int8; p::Core.LLVMPtr{Float32,5}; end
    struct WithLP3; a::Int8; p::Core.LLVMPtr{Float32,3}; end
    struct PaddedLP3; p::Core.LLVMPtr{Int8,3}; x::Int64; end
    struct WithPtr; a::Int8; p::Ptr{Int}; end
    struct BoolPair; a::Bool; b::Bool; end
    struct VEU; v::VecElement{Union{Int8,Nothing}}; end
    struct P24Pair; a::P24; b::P24; end
    mutable struct MutUnion; u::Union{Int,Nothing}; end
    mutable struct WithAtomic; @atomic x::Int; end
    struct HasAtomicInline; a::Int; end

    const TYPES = Any[
        Bool, Int8, UInt16, Char, Int32, Int64, Int128, UInt128, Float16, Float32, Float64,
        P24, P128, P256, Ptr{Int}, Ptr{Cvoid}, Core.LLVMPtr{Int8,3}, Core.LLVMPtr{Float32,1},
        Nothing, Ghost, AllGhost, Union{}, Core.TypeofBottom, Type{Union{}}, Type{Int},
        DataType, Union, UnionAll, typeof(Type{Int}),
        Tuple{}, Tuple{Int,Int}, NTuple{4,Float32}, NTuple{2,Bool}, Tuple{Bool,Int8},
        NTuple{3,VecElement{Float32}}, NTuple{4,VecElement{Int8}}, NTuple{3,VecElement{Bool}},
        NTuple{2,VecElement{P24}}, NTuple{8,VecElement{Float32}}, VecElement{Float64},
        VecElement{Tuple{Int,Int}}, VecElement{String}, VEU, Tuple{Int8,Int64}, Tuple{Int,Nothing},
        Tuple{Int,Tuple{}}, Tuple{Tuple{},Int8,Nothing}, NTuple{2,Ptr{Int}},
        Pad, WithRef, WithUnion, WithUnion2, I128, Outer, WithGhost, Mut, HasMut, Hetero, VE8,
        UHi, Uninit, AbsField, U3, UGhosts, UGhostInt, NestedPad, WithLP, WithLP3, PaddedLP3, WithPtr,
        BoolPair, P24Pair, MutUnion, Tuple{String,Int}, Tuple{Symbol,Symbol},
        Tuple{Union{Nothing,String},Int}, Any, Int, Integer, Union{Int,Nothing},
        Base.RefValue{Int}, ComplexF64, Complex{Bool}, Some{Int}, Some{Nothing}, String, Symbol,
        Vector{Int}, Vector, Tuple{Vararg{Int}}, Base.Fix1{typeof(+),Int},
        NamedTuple{(:a,:b),Tuple{Int8,Float64}}, Tuple{Float16,Float16}, Tuple{Char,Char},
        Tuple{Int32,Float32}, Core.SimpleVector, Module, Task, WithAtomic,
    ]
    if isdefined(Core, :GenericMemory)
        append!(TYPES, [Memory{Int}, Memory{Nothing}, MemoryRef{Int}, MemoryRef{Any},
                        MemoryRef{String}, MemoryRef{Union{Int,Nothing}}, MemoryRef{Nothing},
                        Core.GenericMemoryRef{:atomic,Int,Core.CPU},
                        Core.GenericMemoryRef{:not_atomic,Tuple{Int,String},Core.CPU},
                        Tuple{MemoryRef{Int},Int}])
    end
    isdefined(Core, :BFloat16) && push!(TYPES, Core.BFloat16)
    if isdefined(Core, :bitsizeof)
        # odd-bit primitives (Julia 1.14 and later)
        @eval primitive type P7 7 end
        @eval primitive type P17 17 end
        @eval struct P7Pair; a::P7; b::Int8; end
        append!(TYPES, [P7, P17, P7Pair, NTuple{4,VecElement{P7}}])
    end
    if isdefined(Core, :TypeEq)
        # the kinds of `Type{T}` objects (Julia 1.14 and later)
        append!(TYPES, [Core.TypeEq, Core.TypeEgal, Core.TypeEgal{Int}])
    end
end

using .LoweringCorpus: TYPES

# Julia's C++ lowering in the current context
function cpp_lowering(@nospecialize(T); no_boxing::Bool=false)
    boxed = Ref{Bool}(false)
    ref = no_boxing ?
        ccall(:jl_struct_to_llvm, LLVM.API.LLVMTypeRef,
              (Any, LLVM.API.LLVMContextRef, Ptr{Bool}), T, context(), boxed) :
        ccall(:jl_type_to_llvm, LLVM.API.LLVMTypeRef,
              (Any, LLVM.API.LLVMContextRef, Ptr{Bool}), T, context(), boxed)
    return LLVMType(ref), boxed[]
end

has_atomic_field(@nospecialize(T)) =
    T isa DataType && any(i -> Base.isfieldatomic(T, i), 1:fieldcount(T))

# whether Julia's `jl_struct_to_llvm` gives a result for `T` instead of aborting
cpp_struct_lowers(@nospecialize(T)) =
    T isa DataType && isconcretetype(T) &&
    ((JuliaIR.DIALECT.boxes_kinds && JuliaIR.is_kind(T)) || !has_atomic_field(T))

# the data layout of the running Julia's own modules
host_datalayout() =
    match(r"target datalayout = \"([^\"]*)\"",
          sprint(io -> code_llvm(io, identity, (Int,); dump_module=true, raw=true)))[1]

# the parsed module of a function as Julia generates it (without optimization)
function julia_module(f, types)
    ir = sprint(io -> code_llvm(io, f, types; dump_module=true, raw=true, optimize=false))
    return parse(LLVM.Module, ir)
end

@testset "type lowering" begin

# Julia's lowering creates types in a context of Julia's LLVM
julia_llvm_in_use() && @testset "against Julia's C++" begin
    @dispose ctx=Context(; opaque_pointers=true) begin
        for T in TYPES
            ref, boxed = cpp_lowering(T)
            @test JuliaIR.julia_type(T; allow_boxed=true) == ref
            @test JuliaIR.isboxed(T) == boxed
            if cpp_struct_lowers(T)
                @test JuliaIR.julia_type(T; allow_boxed=true, no_boxing=true) ==
                      first(cpp_lowering(T; no_boxing=true))
            end
        end
    end
end

@testset "rules" begin
    C = LoweringCorpus
    d = JuliaIR.DIALECT
    @dispose ctx=Context(; opaque_pointers=true) begin
        lower(T) = string(JuliaIR.julia_type(T; allow_boxed=true))
        lower_unboxed(T) = string(JuliaIR.julia_type(T; no_boxing=true))
        iword = "i$(8sizeof(Int))"
        @test lower(Int) == iword
        @test lower(Bool) == "i8"
        @test lower(C.Pad) == "{ i8, i64, i16 }"
        @test lower(C.WithRef) == "{ $iword, ptr addrspace(10) }"
        @test lower(C.Mut) == "ptr addrspace(10)"
        @test lower(C.Ghost) == "void"
        @test lower(C.WithGhost) == "{ $iword, float }"
        @test lower(NTuple{3,VecElement{Float32}}) == "<3 x float>"
        @test lower(NTuple{2,VecElement{C.P24}}) == "[2 x i24]"
        @test lower(C.Hetero) == "[2 x i32]"
        @test lower(VecElement{Float64}) == "double"
        @test lower(C.UGhosts) == "{ i8 }"
        @test lower(C.WithLP) == "{ i8, ptr addrspace(5) }"

        # Julia's own types change between versions
        @test lower(Ptr{Int}) == (d.cpointer_type === :pointer ? "ptr" :
                                  iword)
        @test lower(Type{Union{}}) ==
              (d.bottom_aliases === :bottom ? "ptr addrspace(10)" : "void")
        @test lower(Union) == (d.boxes_kinds ? "ptr addrspace(10)" : "[2 x ptr addrspace(10)]")
        if isdefined(Core, :GenericMemoryRef)
            @test lower(MemoryRef{Int}) == "{ ptr, ptr addrspace(10) }"
            @test lower(MemoryRef{Union{Int,Nothing}}) ==
                  "{ $iword, ptr addrspace(10) }"
        end
        if isdefined(Core, :bitsizeof)
            @test lower(C.P7) == "i7"
        end

        # an inline union: data as integers of its alignment (at most `MAX_ALIGN`), then
        # the selector byte
        al = min(16, JuliaIR.max_align())
        @test lower(C.WithUnion2) == "{ $(join(fill("i$(8al)", 16 ÷ al), ", ")), i8 }"
        # an alignment marker where the union is aligned more than `MAX_ALIGN`
        @test startswith(lower(C.UHi), "{ i8, [0 x <32 x i8>], ")

        # boxing
        @test_throws "boxed type" JuliaIR.julia_type(C.Mut)
        @test lower_unboxed(C.Mut) == "[1 x $iword]"
        @test JuliaIR.isboxed(Any) && !JuliaIR.isboxed(Int) && !JuliaIR.isboxed(C.Uninit)
    end
end

# where Julia's C++ aborts, the port throws
@testset "unsupported types" begin
    C = LoweringCorpus
    @dispose ctx=Context(; opaque_pointers=true) begin
        # an atomic field (C++: `abort()`)
        @test_throws "atomic field" JuliaIR.julia_type(C.WithAtomic; no_boxing=true)
        @test JuliaIR.isboxed(C.WithAtomic)
        # no layout (C++: null dereference)
        @test_throws "no layout" JuliaIR.julia_type(Integer; no_boxing=true)
        @test_throws "not a data type" JuliaIR.julia_type(Union{Int,Nothing}; no_boxing=true)
        @test_throws "not a data type" JuliaIR.julia_type(Vector; no_boxing=true)
        # no fixed layout (C++: `abort()`)
        @test_throws "no fixed layout" JuliaIR.julia_struct_type(Base.unwrap_unionall(Some))
        # an address space that is no integer (C++: an error too)
        @test_throws "invalid pointer address space" JuliaIR.julia_type(Core.LLVMPtr{Int8,:x})
    end

    # typed pointers are rejected
    if LLVM.version() < v"17"
        @dispose ctx=Context(; opaque_pointers=false) begin
            @test_throws "opaque pointers" JuliaIR.julia_type(Int)
            @test_throws "opaque pointers" JuliaIR.isboxed(Int)
            @test_throws "opaque pointers" JuliaIR.julia_struct_type(Int)
        end
    end
end

# the declarations that `ccall(..., llvmcall, ...)` emits
llvmcall_expect(x) = ccall("llvm.expect.i1", llvmcall, Bool, (Bool, Bool), x, true)
llvmcall_overflow(x) = ccall("llvm.sadd.with.overflow.i32", llvmcall, Tuple{Int32,Bool},
                    (Int32, Int32), x, x)
llvmcall_ctpop(x) = ccall("llvm.ctpop.v4i1", llvmcall, NTuple{4,VecElement{Bool}},
                 (NTuple{4,VecElement{Bool}},), x)
llvmcall_ptrmask(x) = ccall("llvm.ptrmask.p3.i64", llvmcall, Core.LLVMPtr{Int8,3},
                   (Core.LLVMPtr{Int8,3}, Int64), x, -1)
llvmcall_rdrand() = ccall("llvm.x86.rdrand.32", llvmcall, LoweringCorpus.Hetero, ())

@testset "llvmcall" begin
    C = LoweringCorpus
    @dispose ctx=Context(; opaque_pointers=true) begin
        lower(T) = JuliaIR.julia_struct_type(T; llvmcall=true, allow_boxed=true)
        @test string(lower(Bool)) == "i1"
        @test string(lower(NTuple{4,VecElement{Bool}})) == "<4 x i1>"
        @test string(lower(C.Hetero)) == "{ i32, i32 }"
        @test string(lower(Tuple{Int32,Int32})) == "[2 x i32]"
        @test string(JuliaIR.julia_struct_type(C.Hetero)) == "[2 x i32]"
    end

    cases = Any[(llvmcall_expect, (Bool,), "llvm.expect.i1", Bool, [Bool, Bool]),
                (llvmcall_overflow, (Int32,), "llvm.sadd.with.overflow.i32", Tuple{Int32,Bool},
                 [Int32, Int32]),
                (llvmcall_ctpop, (NTuple{4,VecElement{Bool}},), "llvm.ctpop.v4i1",
                 NTuple{4,VecElement{Bool}}, [NTuple{4,VecElement{Bool}}]),
               ]
    if Sys.WORD_SIZE == 64
        # the mask must have the width of the host's pointers
        push!(cases, (llvmcall_ptrmask, (Core.LLVMPtr{Int8,3},), "llvm.ptrmask.p3.i64",
                      Core.LLVMPtr{Int8,3}, [Core.LLVMPtr{Int8,3}, Int64]))
    end
    if Sys.ARCH === :x86_64
        push!(cases, (llvmcall_rdrand, (), "llvm.x86.rdrand.32", C.Hetero, []))
    end
    @dispose ctx=Context(; opaque_pointers=true) begin
        for (f, types, name, rt, argtypes) in cases
            mod = julia_module(f, types)
            ft = mod.functions[name].function_type
            @test ft.return_type == JuliaIR.julia_struct_type(rt; llvmcall=true)
            @test collect(ft.parameters) == [JuliaIR.julia_struct_type(T; llvmcall=true)
                                     for T in argtypes]
            dispose(mod)
        end
    end
end

@noinline sink(x) = (Base.donotdelete(x); nothing)

# the parameters of `sink` compiled for an argument of type `T`, after the GC stack
function sink_parameters(@nospecialize(T))
    mod = julia_module(sink, (T,))
    f = only(f for f in mod.functions
             if startswith(f.name, "julia_sink") && !isdeclaration(f))
    params = collect(f.function_type.parameters)[2:end]
    dispose(mod)
    return params
end

# how the functions Julia compiles receive arguments: boxed (`ptr addrspace(10)`), by value
# or reference to a copy, or not at all (ghosts)
@testset "calling convention" begin
    @dispose ctx=Context(; opaque_pointers=true) begin
        for T in TYPES
            (T isa DataType && isconcretetype(T)) || T isa Union || continue
            # the argument (and for some aggregates, its roots)
            params = sink_parameters(T)
            lowered = JuliaIR.julia_type(T; allow_boxed=true)
            if isempty(params)
                @test JuliaIR.deserves_stack(T)
                @test lowered isa LLVM.VoidType
            else
                # a tracked pointer is a box, or an unboxed value lowered to one
                # (`VecElement{String}`)
                arg = params[1]
                tracked = arg isa LLVM.PointerType && arg.addrspace == 10
                @test JuliaIR.deserves_argbox(T) ==
                      (tracked && (JuliaIR.isboxed(T) || lowered != arg))
                @test JuliaIR.deserves_retbox(T) == JuliaIR.deserves_argbox(T)
            end
        end

        # a constant type is boxed, but Julia omits the argument before 1.14 (which
        # passes it as a `Core.TypeEq` object)
        @test JuliaIR.deserves_argbox(Type{Int})
        params = sink_parameters(Type{Int})
        if isdefined(Core, :TypeEq)
            @test only(params) == LLVM.PointerType(10)
        else
            @test isempty(params)
        end
    end
    @test JuliaIR.deserves_argbox(LoweringCorpus.Uninit)
    @test !JuliaIR.deserves_argbox(LoweringCorpus.WithRef)

    @dispose ctx=Context(; opaque_pointers=true) begin
        @test JuliaIR.deserves_sret(LoweringCorpus.Pad, JuliaIR.julia_type(LoweringCorpus.Pad))
        @test !JuliaIR.deserves_sret(Int, JuliaIR.julia_type(Int))
        V = NTuple{4,VecElement{Float64}}
        @test !JuliaIR.deserves_sret(V, JuliaIR.julia_type(V))
    end
end

# Julia's layout of each type against the layout LLVM gives its lowering under a data
# layout: identical for the running Julia's own, and known to differ for GPU targets
# (pinned here; see docs/src/type_lowering.md).
@testset "layout" begin
    gpu_datalayouts = (
        nvptx = "e-i64:64-i128:128-v16:16-v32:32-n16:32:64",
        amdgpu = "e-p:64:64-p1:64:64-p2:32:32-p3:32:32-p4:64:64-p5:32:32-p6:32:32-" *
                 "i64:64-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-" *
                 "v512:512-v1024:1024-v2048:2048-n32:64-S32-A5-G1",
        air = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-" *
              "f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-" *
              "v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32",
        spirv = "e-i64:64-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-" *
                "v512:512-v1024:1024-G1",
    )
    C = LoweringCorpus
    layout_types = filter(T -> T isa DataType && isconcretetype(T), TYPES)
    @dispose ctx=Context(; opaque_pointers=true) begin
        dl = LLVM.DataLayout(host_datalayout())
        for T in layout_types
            @test isempty(JuliaIR.check_layout(T, dl))
        end

        # (for 64-bit hosts: Julia's `LLVMPtr`s have the host's pointer size)
        if Sys.WORD_SIZE == 64
            # the divergences per target, as names of the types that diverge
            diverging(dl) = Set(string(T) for T in layout_types
                                if !isempty(JuliaIR.check_layout(T, LLVM.DataLayout(dl))))
            # Julia aligns `Int128` (and primitives of 16 bytes or more) to 16 bytes on
            # x86-64 from 1.12 on, and always on AArch64; NVPTX does too, the other GPU
            # targets don't
            int128 = ["Int128", "UInt128", string(C.I128), string(C.WithUnion2),
                      string(C.P128), string(C.P256)]
            julia_int128_16 = Base.datatype_alignment(Int128) == 16
            # with 8-byte alignment, the inline union of `WithUnion2` is lowered to 8-byte
            # integers, which NVPTX lays out like Julia
            @test diverging(gpu_datalayouts.nvptx) ==
                  Set(julia_int128_16 ? String[] : filter(!=(string(C.WithUnion2)), int128))

            # AMDGPU's local and private pointers are 4 bytes (Julia's `LLVMPtr`s 8)
            amdgpu_ptr = [string(Core.LLVMPtr{Int8,3}), string(C.WithLP), string(C.WithLP3),
                          string(C.PaddedLP3)]
            @test diverging(gpu_datalayouts.amdgpu) ==
                  Set(julia_int128_16 ? [int128; amdgpu_ptr] : amdgpu_ptr)
            @test diverging(gpu_datalayouts.air) == Set(julia_int128_16 ? int128 : String[])
            @test diverging(gpu_datalayouts.spirv) == Set(julia_int128_16 ? int128 : String[])

            divs = JuliaIR.check_layout(C.WithLP, LLVM.DataLayout(gpu_datalayouts.amdgpu))
            @test any(d -> d.path == "$(C.WithLP).p" && d.property === :offset &&
                           d.julia == 8 && d.llvm == 4, divs)

            # a field that is narrower in LLVM, hidden by padding
            divs = JuliaIR.check_layout(C.PaddedLP3, LLVM.DataLayout(gpu_datalayouts.amdgpu))
            @test any(d -> d.path == "$(C.PaddedLP3).p" && d.property === :size &&
                           d.julia == 8 && d.llvm == 4, divs)
            if isdefined(Core, :GenericMemoryRef)
                dl32 = LLVM.DataLayout("e-p:32:32-p10:64:64")
                divs = JuliaIR.check_layout(MemoryRef{Int}, dl32)
                @test any(d -> d.path == "$(MemoryRef{Int}).ptr_or_offset" &&
                               d.property === :size, divs)
            end
        end
    end
end

# The lowering of Julia's own LLVM, carried in bitcode into another context, is the same
# as the port's in that context. (Across LLVM libraries once LLVM.jl supports them.)
julia_llvm_in_use() && @testset "bitcode carrier" begin
    types = filter(TYPES) do T
        @dispose ctx=Context(; opaque_pointers=true) begin
            !(JuliaIR.julia_type(T; allow_boxed=true) isa LLVM.VoidType)
        end
    end
    buf = @dispose ctx=Context(; opaque_pointers=true) mod=LLVM.Module("carrier") begin
        for (i, T) in enumerate(types)
            ft = LLVM.FunctionType(LLVM.VoidType(), [first(cpp_lowering(T))])
            LLVM.Function(mod, "t$i", ft)
        end
        convert(MemoryBuffer, mod)
    end
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, buf) begin
        for (i, T) in enumerate(types)
            ft = mod.functions["t$i"].function_type
            @test only(ft.parameters) == JuliaIR.julia_type(T; allow_boxed=true)
        end
    end
    dispose(buf)
end

end
