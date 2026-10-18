using LLVM, LLVM.IR, LLVM.Passes

@testset "passes" begin

@testset "RemoveNI" begin
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
            target datalayout = "e-i64:64-ni:10:11:12:13"
            """) begin
        opts = JuliaIR.parse_options("")
        # the data layout changes, the CFG does not
        @test JuliaIR.remove_ni!(mod, nothing, opts) == PreservedAnalyses(CFGAnalyses)
        @test string(mod.datalayout) == "e-i64:64"
        @test JuliaIR.remove_ni!(mod, nothing, opts) == PreservedAnalyses(AllAnalyses)

        mod.datalayout = "e-i64:64-ni:10:11:12:13"
        run!(JuliaIR.RemoveNIPass(; julia=v"1.11"), mod)
        @test string(mod.datalayout) == "e-i64:64"
    end

    # a required pass: it runs on `optnone` functions too, which for a module pass
    # means that it is part of the pipeline even at -O0
    @test JuliaIR.RemoveNIPass().required
end

@testset "PropagateJuliaAddrspaces" begin
    @test !JuliaIR.PropagateAddrspacesPass().required
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
            define i64 @f() {
              %stack = alloca i64
              %casted = addrspacecast ptr %stack to ptr addrspace(11)
              %load = load i64, ptr addrspace(11) %casted
              ret i64 %load
            }""") begin
        run!(JuliaIR.PropagateAddrspacesPass(; julia=v"1.12"), mod)
        load = collect(first(first(mod.functions).blocks).instructions)[3]
        @test load.operands[1] == first(first(first(mod.functions).blocks).instructions)
    end
end

@testset "DemoteFloat16" begin
    @test JuliaIR.DemoteFloat16Pass().required
    @test_throws "invalid bf16 policy" JuliaIR.DemoteFloat16Pass(; bf16=:never)
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
            define half @f(half %a) {
              %r = fadd half %a, %a
              ret half %r
            }""") begin
        run!(JuliaIR.DemoteFloat16Pass(; julia=v"1.12", fp16=:keep), mod)
        @test occursin("%r = fadd half", string(mod))
        run!(JuliaIR.DemoteFloat16Pass(; julia=v"1.12", fp16=:demote), mod)
        @test occursin("%r = fptrunc float", string(mod))
    end
end

@testset "GCInvariantVerifier" begin
    @test JuliaIR.GCInvariantVerifierPass().required
    @test_throws "must be a Bool" JuliaIR.GCInvariantVerifierPass(; strong=1)
    ir = """
        define ptr addrspace(11) @f(ptr addrspace(10) %obj, ptr %p) {
          %derived = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
          %gep = getelementptr i8, ptr addrspace(10) %obj, i64 8
          store ptr addrspace(11) %derived, ptr %p
          ret ptr addrspace(11) %derived
        }"""
    # every violation is reported, and the error outlives the module
    err = @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
        try
            run!(JuliaIR.GCInvariantVerifierPass(; julia=v"1.12", strong=true), mod)
            nothing
        catch err
            err
        end
    end
    @test err isa PassException && err.ex isa JuliaIR.GCInvariantError
    @test [v.message for v in err.ex.violations] ==
          ["GC tracked values may not appear in GEP expressions. You may have to decay the value first",
           "Illegal store of decayed value", "Only gc tracked values may be directly returned"]
    @test occursin("store ptr addrspace(11) %derived, ptr %p", err.ex.violations[2].instruction)
    msg = sprint(showerror, err.ex)
    @test startswith(msg, "GCInvariantError: GC invariants are violated in function f\n")
    @test occursin("Illegal store of decayed value\n\t  store ptr addrspace(11)", msg)

    # without the strong check, GEPs of tracked pointers are fine
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
        err = try
            run!(JuliaIR.GCInvariantVerifierPass(; julia=v"1.12"), mod)
        catch err
            err
        end
        @test length(err.ex.violations) == 2
    end
end

@testset "AllocOpt" begin
    @test !JuliaIR.AllocOptPass().required

    @testset "data layout" begin
        @test JuliaIR.alloca_addrspace("e-p:64:64-A5-G1-ni:7") == 5
        @test JuliaIR.alloca_addrspace("e-i64:64-n8:16:32:64") == 0
        @test JuliaIR.is_legal_integer("e-i64:64-n8:16:32:64-S128", 32)
        @test !JuliaIR.is_legal_integer("e-i64:64-n8:16:32:64-S128", 96)
        @test !JuliaIR.is_legal_integer("e-i64:64", 32)
        @test !JuliaIR.is_legal_integer("e-ni:10:11:12:13", 32)
        @test JuliaIR.is_legal_integer("e-ni:10:11:12:13-n8:16:32:64", 32)
    end

    @testset "fields" begin
        @dispose ctx=Context(; opaque_pointers=true) begin
            mod = parse(LLVM.Module, """
                define void @f(ptr %p) {
                  %a = load i64, ptr %p
                  %b = load i32, ptr %p
                  %c = load i32, ptr %p
                  %d = load ptr addrspace(10), ptr %p
                  ret void
                }""")
            dl = mod.datalayout
            a, b, c, d = collect(only(only(mod.functions).blocks).instructions)[1:4]
            info = JuliaIR.AllocUseInfo()
            i64, i32 = LLVM.Int64Type(), LLVM.Int32Type()

            # disjoint fields
            @test JuliaIR.add_memop!(info, a, 1, UInt32(0), i64, true, false, dl)
            @test JuliaIR.add_memop!(info, b, 1, UInt32(8), i32, false, true, dl)
            @test info.offsets == [0, 8]
            @test info.fields[1].hasload && !info.fields[2].hasload
            @test info.fields[1].elty == i64

            # an access within a field keeps it, but forgets its type
            JuliaIR.add_memop!(info, c, 1, UInt32(4), i32, true, false, dl)
            @test info.offsets == [0, 8]
            @test info.fields[1].elty === nothing

            # an access that overlaps two fields merges them
            JuliaIR.add_memop!(info, a, 1, UInt32(4), i64, true, false, dl)
            @test info.offsets == [0]
            @test info.fields[1].size == 12
            @test info.fields[1].multiloc
            @test length(info.fields[1].accesses) == 4

            # references
            empty!(info)
            JuliaIR.add_memop!(info, d, 1, UInt32(16), LLVM.PointerType(10), false, true, dl)
            @test info.refstore && !info.refload
            @test info.fields[1].hasobjref && !info.fields[1].hasunboxed

            # the end of an access must fit in 32 bits
            @test !JuliaIR.add_memop!(info, a, 1, typemax(UInt32) - UInt32(4), i64, true, false, dl)
        end
    end

    @testset "remarks" begin
        remarks = []
        @dispose ctx=Context(; opaque_pointers=true) begin
            mod = parse(LLVM.Module, """
                @tag = external addrspace(10) global {}
                declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
                declare void @external(ptr addrspace(10))
                define void @f(ptr %ptls) {
                  %dead = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %ptls, i64 8, ptr addrspace(10) @tag)
                  %escaped = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %ptls, i64 8, ptr addrspace(10) @tag)
                  call void @external(ptr addrspace(10) %escaped)
                  ret void
                }""")
            run!(JuliaIR.AllocOptPass(; julia=v"1.12"), mod; remarks=r -> push!(remarks, r))
        end
        @test any(r -> r.kind === :passed && r.name == "Dead Allocation", remarks)
        @test any(r -> r.kind === :missed && r.name == "Escaped", remarks)
        @test any(r -> r.kind === :missed && r.name == "UnknownCall", remarks)
        @test all(r -> r.pass_name == "alloc-opt", remarks)
    end
end

end
