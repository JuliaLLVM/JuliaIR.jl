# IR that crosses from Julia's LLVM to the library that LLVM.jl uses, in bitcode: a newer
# LLVM upgrades the data layout of older modules when it reads them, and from LLVM 18 on
# gives x86's i128 an alignment of 16, which Julia 1.10 and 1.11 lay out with 8. The ports
# expect the data layout that Julia's code generator used; whoever carries the IR across
# (GPUCompiler) has to restore it. A first process, on Julia's own LLVM, writes a module
# with Julia's lowering of a corpus of types and what Julia knows about their layout
# (test/crossing/writer.jl); this one reads it, checks that the layout is Julia's once the
# data layout is restored, and that it would not be without restoring it.

using LLVM, LLVM.IR, LLVM.Passes, TOML

include(joinpath(@__DIR__, "crossing", "corpus.jl"))

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
    mktempdir() do dir
        # only the standard library, so that LLVM.jl's preferences can't apply
        writer = joinpath(@__DIR__, "crossing", "writer.jl")
        cmd = addenv(`$(Base.julia_cmd()) --startup-file=no $writer $dir`,
                     "JULIA_LOAD_PATH" => "@stdlib")
        @test success(pipeline(cmd; stdout, stderr))
        info = TOML.parsefile(joinpath(dir, "crossing.toml"))
        types = info["types"]
        @test length(types) == length(CrossingCorpus.TYPES)

        # what Julia's LLVM computed is what Julia lays out
        for (t, (T, per_field)) in zip(types, CrossingCorpus.TYPES)
            @test t["size"] == t["julia_size"] == sizeof(T)
            @test t["align"] <= t["julia_align"]
            per_field && @test t["offsets"] == t["julia_offsets"]
        end

        # LLVM 18 and later add i128:128 to the data layout of older x86 modules
        source_llvm = VersionNumber(info["llvm"])
        upgrades_i128 = Sys.ARCH in (:x86_64, :i686) && source_llvm < v"18" &&
                        LLVM.version() >= v"18"

        @dispose ctx=Context(; opaque_pointers=true) begin
            mod = parse(LLVM.Module, MemoryBufferFile(joinpath(dir, "crossing.bc")))
            read_layout = string(mod.datalayout)
            @test occursin("i128:128", read_layout) ==
                  (upgrades_i128 || occursin("i128:128", info["datalayout"]))

            # without restoring the data layout, the known wrong layout of `Wide`
            wide = findfirst(((T, _),) -> T === CrossingCorpus.Wide, CrossingCorpus.TYPES)
            ref = types[wide]
            optimize!(mod)
            size = folded(mod.functions["size_$wide"])
            offset = folded(mod.functions["offset_$(wide)_1"])
            if upgrades_i128
                @test (offset, size) == (16, 32)
                @test (offset, size) != (ref["offsets"][2], ref["size"])
            else
                @test (offset, size) == (ref["offsets"][2], ref["size"])
            end
            dispose(mod)

            # with the data layout restored, Julia's layout, in the layout queries and as
            # the optimizer folds it after the ports
            mod = parse(LLVM.Module, MemoryBufferFile(joinpath(dir, "crossing.bc")))
            mod.datalayout = info["datalayout"]
            dl = mod.datalayout
            for (i, t) in enumerate(types)
                ty = only(mod.functions["type_$i"].function_type.parameters)
                @test string(ty) == t["type"]
                @test [LLVM.offsetof(dl, ty, k) for k in 1:length(ty.elements)] == t["offsets"]
                @test LLVM.abi_size(dl, ty) == t["size"]
                @test LLVM.abi_alignment(dl, ty) == t["align"]
                # the port's lowering of the type, in this library, is the carried one
                T = CrossingCorpus.TYPES[i][1]
                @test JuliaIR.julia_type(T) == ty
            end
            optimize!(mod)
            for (i, t) in enumerate(types)
                @test folded(mod.functions["size_$i"]) == t["size"]
                @test [folded(mod.functions["offset_$(i)_$k"]) for k in 0:length(t["offsets"])-1] ==
                      t["offsets"]
            end
            dispose(mod)
        end
    end
end
