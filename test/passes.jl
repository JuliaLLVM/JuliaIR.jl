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

@testset "LateGCCleanup" begin
    @test JuliaIR.LateGCCleanupPass().required
    ir = """
        declare ptr addrspace(10) @julia.typeof(ptr addrspace(10))
        declare ptr @julia.pointer_from_objref(ptr addrspace(10))

        define ptr @f(ptr addrspace(10) %obj, ptr addrspace(11) %p) {
          %v = load i64, ptr addrspace(11) %p, !invariant.load !0
          %ptr = call ptr @julia.pointer_from_objref(ptr addrspace(10) %obj)
          %t = call ptr addrspace(10) @julia.typeof(ptr addrspace(10) %obj)
          ret ptr %ptr
        }

        !0 = !{}"""
    # unsupported constructs are all reported, before anything is changed
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
        before = string(mod)
        err = try
            run!(JuliaIR.LateGCCleanupPass(; julia=v"1.12"), mod)
            nothing
        catch err
            err
        end
        @test err isa PassException && err.ex isa JuliaIR.UnsupportedInputError
        @test length(err.ex.constructs) == 1
        @test startswith(err.ex.constructs[1].message, "julia.typeof: ")
        @test startswith(sprint(showerror, err.ex),
                         "UnsupportedInputError: function f contains constructs")
        @test string(mod) == before
    end

    # TBAA tags in the format Julia emits (old: access types named by a string) and in
    # the new format (where the immutability flag is the fifth operand)
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
            define void @f(ptr %p) {
              store i8 0, ptr %p, !tbaa !0
              store i8 0, ptr %p, !tbaa !4
              store i8 0, ptr %p, !tbaa !5
              store i8 0, ptr %p, !tbaa !7
              store i8 0, ptr %p, !tbaa !9
              ret void
            }

            !0 = !{!1, !1, i32 0, i32 1}
            !1 = !{!"jtbaa_memoryptr", !2, i64 0}
            !2 = !{!"jtbaa_array", !3, i64 0}
            !3 = !{!"jtbaa"}
            !4 = !{!1, !1, i64 0, i64 0}
            !5 = !{!6, !6, i64 0}
            !6 = !{!"jtbaa_data", !3, i64 0}
            !7 = !{!8, !8, i64 0, i64 8, i64 1}
            !8 = !{!3, i64 8, !"long"}
            !9 = !{!8, !8, i64 0, i64 8}
            """) begin
        tags = [inst.metadata[LLVM.MD_tbaa]
                for inst in first(first(mod.functions).blocks).instructions
                if inst isa LLVM.StoreInst]
        @test JuliaIR.tbaa_derives_from(tags[1], ["jtbaa_array"])
        @test JuliaIR.tbaa_derives_from(tags[1], ["jtbaa_memoryptr"])
        @test !JuliaIR.tbaa_derives_from(tags[1], ["jtbaa_const"])
        @test !JuliaIR.tbaa_derives_from(tags[4], ["long"])

        # the offset becomes an i64, like LLVM builds it
        mutable = JuliaIR.mutable_tbaa_tag(tags[1])
        @test mutable != tags[1]
        @test collect(mutable.operands)[1:2] == collect(tags[1].operands)[1:2]
        @test length(mutable.operands) == 3
        @test Value(mutable.operands[3]) == ConstantInt(Int64(0))
        @test JuliaIR.mutable_tbaa_tag(tags[2]) == tags[2]
        @test JuliaIR.mutable_tbaa_tag(tags[3]) == tags[3]
        @test JuliaIR.mutable_tbaa_tag(tags[4]) == tags[5]
        @test JuliaIR.mutable_tbaa_tag(tags[5]) == tags[5]
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

@testset "CombineMulAdd" begin
    @test !JuliaIR.CombineMulAddPass().required
    ir = """
        define double @f(double %a, double %b, double %c) {
          %once = fmul double %a, %b
          %twice = fmul double %a, %c
          %r1 = fadd contract double %once, %twice
          %r2 = fsub contract double %twice, %c
          %r = fadd double %r1, %r2
          ret double %r
        }"""
    for (julia, changed) in [(v"1.10", true), (v"1.11.9", true), (v"1.12", false)]
        remarks = []
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            run!(JuliaIR.CombineMulAddPass(; julia), mod; remarks=r -> push!(remarks, r))
            @test occursin("%once = fmul contract double", string(mod)) == changed
            @test occursin("%twice = fmul double", string(mod))
        end
        if changed
            @test [(r.kind, r.name, r.message) for r in remarks] ==
                  [(:passed, "Marked for FMA", "marked for fma fmul"),
                   (:missed, "Multiuse FMul", "fmul had multiple uses fmul")]
            @test all(r -> r.pass_name == "combine-muladd", remarks)
        else
            @test isempty(remarks)
        end
    end
end

@testset "LowerExcHandlers" begin
    @test JuliaIR.LowerExcHandlersPass().required
    native_minor = JuliaIR.dialect_minor(VERSION)
    # the 1.12 dialect
    ir(; triple="", call=true) = """
        $(isempty(triple) ? "" : "target triple = \"$triple\"")
        declare {i32, ptr} @julia.except_enter(ptr) returns_twice
        declare void @ijl_pop_handler(ptr, i32)
        define void @f(ptr %ct) {
          $(call ? "%r = call {i32, ptr} @julia.except_enter(ptr %ct)" : "")
          $(call ? "call void @ijl_pop_handler(ptr %ct, i32 1)" : "")
          ret void
        }"""
    lowered(mod) = !occursin("call { i32, ptr } @julia.except_enter", string(mod))
    function lower(triple; julia=v"1.12", kwargs...)
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir(; triple)) begin
            run!(JuliaIR.LowerExcHandlersPass(; julia, kwargs...), mod)
            @test lowered(mod)
            return string(mod)
        end
    end

    @testset "runtime facts" begin
        # the running Julia's, whatever the target (the upstream fixtures cover this for
        # Julia 1.10 and 1.11)
        if native_minor == v"1.12"
            @dispose ctx=Context(; opaque_pointers=true) mod=LLVM.Module("m") begin
                rt = JuliaIR.runtime_layout(JuliaIR.Dialect(VERSION), mod)
                for triple in ("", LLVM.default_triple(), "amdgcn-amd-amdhsa")
                    out = lower(triple; julia=VERSION)
                    @test occursin("alloca i8, i32 $(rt.handler_size), align 16", out)
                    # Windows Julia's default triple, `x86_64-w64-mingw32`, isn't
                    # normalized, so the C++ pass passes a savemask there too
                    @test occursin("call i32 @$(rt.setjmp)(ptr %1, i32 0)", out)
                end
            end
        end

        # explicit facts win
        out = lower("x86_64-unknown-linux-gnu"; handler_size=300, handler_align=16,
                    setjmp="jl_setjmp")
        @test occursin("alloca i8, i32 300, align 16", out)
        @test occursin("call i32 @jl_setjmp(ptr %1, i32 0)", out)
        # the buffers are aligned to at least 16 bytes, like the C++ pass does
        out = lower(""; handler_size=96, handler_align=4, setjmp="ijl_setjmp")
        @test occursin("alloca i8, i32 96, align 16", out)
    end

    @testset "setjmp signature" begin
        # the savemask argument follows the module's triple, not the runtime's setjmp,
        # like the C++ pass: only (unnormalized) Windows triples drop it
        for (triple, savemask) in ("" => true, "x86_64-unknown-linux-gnu" => true,
                                   "amdgcn-amd-amdhsa" => true,
                                   "x86_64-w64-windows-gnu" => false,
                                   "i686-pc-win32" => false,
                                   "x86_64-pc-windows-msvc" => false,
                                   "x86_64-w64-mingw32" => true)
            out = lower(triple; handler_size=264, handler_align=16, setjmp="__sigsetjmp")
            args = savemask ? "ptr %1, i32 0" : "ptr %1"
            @test occursin("call i32 @__sigsetjmp($args)", out)
        end
        # an existing declaration for a Windows target, with the Unix runtime's setjmp
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
                target triple = "x86_64-w64-windows-gnu"
                declare i32 @__sigsetjmp(ptr) returns_twice
                $(ir())""") begin
            run!(JuliaIR.LowerExcHandlersPass(; julia=v"1.12", handler_size=264,
                                              handler_align=16, setjmp="__sigsetjmp"), mod)
            @test lowered(mod)
            @test occursin("call i32 @__sigsetjmp(ptr %1)", string(mod))
            @test verify(mod) === nothing
        end
        # the signature of setjmp, explicitly
        out = lower(""; handler_size=264, handler_align=16, setjmp="__sigsetjmp",
                    setjmp_savemask=:no)
        @test occursin("call i32 @__sigsetjmp(ptr %1)", out)
        out = lower("x86_64-w64-mingw32"; handler_size=320, handler_align=16,
                    setjmp="jl_setjmp", setjmp_savemask=:yes)
        @test occursin("call i32 @jl_setjmp(ptr %1, i32 0)", out)
        opts = JuliaIR.parse_options("julia=1.12;setjmp-savemask=no";
                                     extra=JuliaIR.LOWER_EXC_HANDLERS.extra)
        @test opts.extra.setjmp_savemask === :no
        @test_throws "invalid option setjmp-savemask" lower(""; handler_size=264,
            handler_align=16, setjmp="__sigsetjmp", setjmp_savemask=:maybe)
    end

    @testset "lowering" begin
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir()) begin
            run!(JuliaIR.LowerExcHandlersPass(; julia=v"1.12", handler_size=200,
                                              handler_align=16, setjmp="sigsetjmp"), mod)
            @test lowered(mod)
            @test occursin("alloca i8, i32 200, align 16", string(mod))
            @test occursin("call i32 @sigsetjmp(ptr %1, i32 0) #0", string(mod))
        end
        # the 1.13 dialect has no handlers to lower
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir()) begin
            before = string(mod)
            run!(JuliaIR.LowerExcHandlersPass(; julia=v"1.13"), mod)
            @test string(mod) == before
        end
        # without handlers, the runtime facts aren't needed and nothing changes
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module,
                                                             ir(; triple="armv7-unknown-linux-gnueabihf", call=false)) begin
            before = string(mod)
            opts = JuliaIR.parse_options("julia=1.12"; extra=JuliaIR.LOWER_EXC_HANDLERS.extra)
            @test JuliaIR.lower_exc_handlers!(mod.functions["f"], nothing, opts) ==
                  PreservedAnalyses(AllAnalyses)
            @test string(mod) == before
        end
        # leaving more handlers than were entered is rejected before changing anything
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
                declare {i32, ptr} @julia.except_enter(ptr) returns_twice
                declare void @ijl_pop_handler(ptr, i32)
                define void @f(ptr %ct) {
                  %r = call {i32, ptr} @julia.except_enter(ptr %ct)
                  call void @ijl_pop_handler(ptr %ct, i32 2)
                  ret void
                }""") begin
            before = string(mod)
            f = mod.functions["f"]
            opts = JuliaIR.parse_options("julia=1.12;handler-size=200;handler-align=16;setjmp=sigsetjmp";
                                         extra=JuliaIR.LOWER_EXC_HANDLERS.extra)
            err = try
                JuliaIR.lower_exc_handlers!(f, nothing, opts)
                nothing
            catch err
                err
            end
            @test err isa JuliaIR.HandlerNestingError
            @test occursin("more handlers left than entered", sprint(showerror, err))
            @test string(mod) == before
        end
    end
end

end
