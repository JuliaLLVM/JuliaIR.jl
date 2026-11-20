# IR that crosses from Julia's LLVM to the library that LLVM.jl uses, in bitcode: a newer
# LLVM upgrades the data layout of older modules when it reads them, and from LLVM 18 on
# gives x86's i128 an alignment of 16, which Julia 1.10 and 1.11 lay out with 8. The ports
# expect the data layout that Julia's code generator used; whoever carries the IR across
# (GPUCompiler) has to restore it. In a context of Julia's own LLVM, the test writes a
# module with Julia's lowering of a corpus of types and what that LLVM knows about their
# layout; it then reads the module in a context of the current library, and checks that
# the layout is Julia's once the data layout is restored, and that it would not be without
# restoring it.

using LLVM, LLVM.IR, LLVM.Passes, InteractiveUtils

module CrossingCorpus

# Int128's alignment differs between Julia versions (8 before 1.12 on x86, 16 from then)
struct Wide
    a::Int8
    b::Int128
end
struct Nested
    a::Int8
    w::Wide
end
# an isbits union field, which isn't lowered one element per field
struct WithUnion
    a::Int8
    b::Union{Int8,Int128}
end
struct WithVector
    a::Int16
    v::NTuple{4,VecElement{Float32}}
    p::Ptr{Int}
end

# the types, and whether each field is lowered to one element of the LLVM struct (so that
# the element offsets are the field offsets)
const TYPES = [(Wide, true), (Nested, true), (WithUnion, false), (WithVector, true),
               (Tuple{Int8,UInt128,Int16}, true)]

end

# With Julia's LLVM: the data layout of the modules that Julia's code generator creates,
# the version of that LLVM, the corpus's types as Julia lowers them with their layout in
# that data layout, and the bitcode of a module with those types and functions that
# compute their layout.
function write_crossing()
    ir = sprint(io -> code_llvm(io, identity, (Int,); raw=true, dump_module=true))
    datalayout = match(r"target datalayout = \"([^\"]*)\"", ir)[1]
    triple = match(r"target triple = \"([^\"]*)\"", ir)[1]
    Context(; library=:julia, opaque_pointers=true) do ctx
        # datalayout before triple, as Julia prints modules: the text keeps the layout as is
        src = IOBuffer()
        println(src, "target datalayout = \"$datalayout\"")
        println(src, "target triple = \"$triple\"")
        dl = LLVM.DataLayout(datalayout)
        types = map(enumerate(CrossingCorpus.TYPES)) do (i, (T, _))
            boxed = Ref{Bool}(false)
            ty = LLVMType(ccall(:jl_type_to_llvm, LLVM.API.LLVMTypeRef,
                                (Any, LLVM.API.LLVMContextRef, Ptr{Bool}), T, ctx, boxed))
            boxed[] && error("$T is boxed")
            str = string(ty)
            n = length(ty.elements)

            # the type, and its layout as the optimizer folds it
            println(src, "declare void @type_$i($str)")
            println(src, """
                define i64 @size_$i() {
                  %p = getelementptr $str, ptr null, i64 1
                  %s = ptrtoint ptr %p to i64
                  ret i64 %s
                }""")
            for k in 0:n-1
                println(src, """
                    define i64 @offset_$(i)_$k() {
                      %p = getelementptr $str, ptr null, i32 0, i32 $k
                      %o = ptrtoint ptr %p to i64
                      ret i64 %o
                    }""")
            end

            (; type=str, offsets=[Int(LLVM.offsetof(dl, ty, k)) for k in 1:n],
               size=Int(LLVM.abi_size(dl, ty)), align=Int(LLVM.abi_alignment(dl, ty)))
        end
        dispose(dl)
        bitcode = @dispose mod=parse(LLVM.Module, String(take!(src))) begin
            convert(Vector{UInt8}, mod)
        end
        return (; datalayout, llvm=LLVM.version(), types, bitcode)
    end
end

# the result that a function `() -> i64` folds to
function folded(f::LLVM.Function)
    val = only(f.entry.terminator.operands)
    val isa ConstantInt || error("$(f.name) didn't fold: $(string(f))")
    return convert(Int, val)
end

# the ports and the optimizer, which folds the layout computations
function optimize!(mod)
    @dispose pb=PassBuilder() begin
        JuliaIR.register!(pb)
        add!(pb, "jl-remove-ni,function(jl-propagate-addrspaces,jl-alloc-opt,jl-late-lower-gc-frame,instcombine)")
        run!(pb, mod)
    end
end

@testset "IR crossing" begin
    info = write_crossing()
    types = info.types
    @test length(types) == length(CrossingCorpus.TYPES)

    # what Julia's LLVM computed is what Julia lays out
    for (t, (T, per_field)) in zip(types, CrossingCorpus.TYPES)
        @test t.size == sizeof(T)
        @test t.align <= Base.datatype_alignment(T)
        per_field && @test t.offsets == fieldoffset.(T, 1:fieldcount(T))
    end

    # LLVM 18 and later add i128:128 to the data layout of older x86 modules
    upgrades_i128 = Sys.ARCH in (:x86_64, :i686) && info.llvm < v"18" &&
                    LLVM.version() >= v"18"

    @dispose ctx=Context(; opaque_pointers=true) begin
        mod = parse(LLVM.Module, info.bitcode)
        read_layout = string(mod.datalayout)
        @test occursin("i128:128", read_layout) ==
              (upgrades_i128 || occursin("i128:128", info.datalayout))

        # without restoring the data layout, the known wrong layout of `Wide`
        wide = findfirst(((T, _),) -> T === CrossingCorpus.Wide, CrossingCorpus.TYPES)
        ref = types[wide]
        optimize!(mod)
        size = folded(mod.functions["size_$wide"])
        offset = folded(mod.functions["offset_$(wide)_1"])
        if upgrades_i128
            @test (offset, size) == (16, 32)
            @test (offset, size) != (ref.offsets[2], ref.size)
        else
            @test (offset, size) == (ref.offsets[2], ref.size)
        end
        dispose(mod)

        # with the data layout restored, Julia's layout, in the layout queries and as the
        # optimizer folds it after the ports
        mod = parse(LLVM.Module, info.bitcode)
        mod.datalayout = info.datalayout
        dl = mod.datalayout
        for (i, t) in enumerate(types)
            ty = only(mod.functions["type_$i"].function_type.parameters)
            @test string(ty) == t.type
            @test [LLVM.offsetof(dl, ty, k) for k in 1:length(ty.elements)] == t.offsets
            @test LLVM.abi_size(dl, ty) == t.size
            @test LLVM.abi_alignment(dl, ty) == t.align
            # the port's lowering of the type, in this library, is the carried one
            T = CrossingCorpus.TYPES[i][1]
            @test JuliaIR.julia_type(T) == ty
        end
        optimize!(mod)
        for (i, t) in enumerate(types)
            @test folded(mod.functions["size_$i"]) == t.size
            @test [folded(mod.functions["offset_$(i)_$k"]) for k in 0:length(t.offsets)-1] ==
                  t.offsets
        end
        dispose(mod)
    end
end
