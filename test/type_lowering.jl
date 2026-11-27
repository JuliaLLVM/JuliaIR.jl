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

# Julia's C++ lowering in the current context, which must be one of Julia's LLVM
function cpp_lowering(@nospecialize(T))
    boxed = Ref{Bool}(false)
    ref = ccall(:jl_type_to_llvm, LLVM.API.LLVMTypeRef,
                (Any, LLVM.API.LLVMContextRef, Ptr{Bool}), T, context(), boxed)
    return LLVMType(ref), boxed[]
end

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
@testset "against Julia's C++" begin
    Context(; library=:julia, opaque_pointers=true) do ctx
        for T in TYPES
            ref, boxed = cpp_lowering(T)
            @test JuliaIR.llvm_type(T; allow_boxed=true) == ref
            @test JuliaIR.isboxed(T) == boxed
            @test JuliaIR.isghosttype(T) == (ref isa LLVM.VoidType)
            # the rebuilding of a lowering in another context
            @test JuliaIR.with_julia_context() do jlctx
                JuliaIR.import_type(LLVM.julia_library,
                                    first(JuliaIR.julia_type_to_llvm(T, jlctx)))
            end == ref
        end
    end
    # without an active context
    @test JuliaIR.isboxed(Any) && !JuliaIR.isboxed(Int)
    @test JuliaIR.isghosttype(Nothing) && !JuliaIR.isghosttype(Int)
end

@testset "rules" begin
    C = LoweringCorpus
    d = JuliaIR.DIALECT
    @dispose ctx=Context(; opaque_pointers=true) begin
        lower(T) = string(JuliaIR.llvm_type(T; allow_boxed=true))
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
        @test_throws "boxed type" JuliaIR.llvm_type(C.Mut)
        @test JuliaIR.isboxed(Any) && !JuliaIR.isboxed(Int) && !JuliaIR.isboxed(C.Uninit)
    end
end

@testset "errors" begin
    @dispose ctx=Context(; opaque_pointers=true) begin
        @test_throws "invalid pointer address space" JuliaIR.llvm_type(Core.LLVMPtr{Int8,:x})
        @test_throws "boxed type" JuliaIR.llvm_type(Any)
    end
    @test_throws "No LLVM context is active" JuliaIR.llvm_type(Int)

    # in a context with typed pointers, pointers can only be rebuilt from typed ones
    if LLVM.version() < v"17"
        @dispose ctx=Context(; opaque_pointers=false) begin
            @test string(JuliaIR.llvm_type(Int32)) == "i32"
            # a box doesn't need to be rebuilt to check its layout
            dl = LLVM.DataLayout(host_datalayout())
            @test isempty(JuliaIR.check_layout(Any, dl))
            if Base.libllvm_version < v"17"
                @test string(JuliaIR.llvm_type(Core.LLVMPtr{Int8,3})) == "i8 addrspace(3)*"
                @test string(JuliaIR.llvm_type(Any; allow_boxed=true)) == "{} addrspace(10)*"
                @test isempty(JuliaIR.check_layout(LoweringCorpus.WithRef, dl))
            else
                @test_throws "typed pointers" JuliaIR.llvm_type(Core.LLVMPtr{Int8,3})
                @test_throws "typed pointers" JuliaIR.check_layout(LoweringCorpus.WithRef, dl)
            end
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
            lowered = JuliaIR.llvm_type(T; allow_boxed=true)
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
        @test JuliaIR.deserves_sret(LoweringCorpus.Pad, JuliaIR.llvm_type(LoweringCorpus.Pad))
        @test !JuliaIR.deserves_sret(Int, JuliaIR.llvm_type(Int))
        V = NTuple{4,VecElement{Float64}}
        @test !JuliaIR.deserves_sret(V, JuliaIR.llvm_type(V))
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

# The lowering of Julia's own LLVM, carried in bitcode into a context of the current
# library, is the same as the port's in that context.
@testset "bitcode carrier" begin
    # the types that lower to `void` can't be carried as a parameter
    voids, bitcode = Context(; library=:julia, opaque_pointers=true) do ctx
        @dispose mod=LLVM.Module("carrier") begin
            voids = Bool[]
            for (i, T) in enumerate(TYPES)
                ty = first(cpp_lowering(T))
                push!(voids, ty isa LLVM.VoidType)
                voids[end] && continue
                LLVM.Function(mod, "t$i", LLVM.FunctionType(LLVM.VoidType(), [ty]))
            end
            voids, convert(Vector{UInt8}, mod)
        end
    end
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, bitcode) begin
        for (i, T) in enumerate(TYPES)
            ty = JuliaIR.llvm_type(T; allow_boxed=true)
            if voids[i]
                @test ty isa LLVM.VoidType
            else
                @test only(mod.functions["t$i"].function_type.parameters) == ty
            end
        end
    end
end

end
