using LLVM, LLVM.IR, LLVM.Passes
using InteractiveUtils: InteractiveUtils

@testset "passes" begin

# the passes process the IR of the running Julia, so where its dialect matters, the tests
# expect what the running Julia's dialect does
dialect = JuliaIR.Dialect(VERSION)

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
        run!(JuliaIR.RemoveNIPass(), mod)
        @test string(mod.datalayout) == "e-i64:64"
    end

    # a required pass: it runs on `optnone` functions too, which for a module pass
    # means that it is part of the pipeline even at -O0
    @test JuliaIR.RemoveNIPass().required
end

@testset "PropagateJuliaAddrspaces" begin
    @test JuliaIR.PropagateAddrspacesPass().required
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
            define i64 @f() {
              %stack = alloca i64
              %casted = addrspacecast ptr %stack to ptr addrspace(11)
              %load = load i64, ptr addrspace(11) %casted
              ret i64 %load
            }""") begin
        run!(JuliaIR.PropagateAddrspacesPass(), mod)
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
        run!(JuliaIR.DemoteFloat16Pass(; fp16=:keep), mod)
        @test occursin("%r = fadd half", string(mod))
        run!(JuliaIR.DemoteFloat16Pass(; fp16=:demote), mod)
        @test occursin("%r = fptrunc float", string(mod))
    end

    # On Julia 1.10 and 1.11, a function without `target-features` keeps `half` if the
    # JIT compiles it natively, as in Julia's pipeline: here an AArch64 JIT with FP16,
    # whose probes are faked.
    if JuliaIR.Dialect(VERSION).fp16_rule !== :attributes
        ir = """
            target triple = "aarch64-unknown-linux-gnu"
            define half @f(half %a) {
              %r = fadd half %a, %a
              ret half %r
            }"""
        facts = JuliaIR.NATIVE_FACTS
        saved = copy(facts)
        try
            facts[:jit_target] = (; triple="aarch64-unknown-linux-gnu", cpu=nothing,
                                  features=nothing)
            facts[:jit_fp16] = true
            @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
                run!(JuliaIR.DemoteFloat16Pass(), mod)
                @test occursin("%r = fadd half", string(mod))
                # unless the JIT is ignored, like in `opt`
                run!(JuliaIR.DemoteFloat16Pass(; jit_features=false), mod)
                @test occursin("%r = fptrunc float", string(mod))
            end
            # or the module is for another architecture
            facts[:jit_target] = (; triple="x86_64-unknown-linux-gnu", cpu=nothing,
                                  features=nothing)
            @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
                run!(JuliaIR.DemoteFloat16Pass(), mod)
                @test occursin("%r = fptrunc float", string(mod))
            end
        finally
            empty!(facts)
            merge!(facts, saved)
        end

        # the probe agrees with the code Julia generates
        ir = sprint(io -> InteractiveUtils.code_llvm(io, *, Tuple{Float16,Float16};
                                                     debuginfo=:none))
        @test JuliaIR.native_probe(:jit_fp16) == occursin("fmul half", ir)
    end
end

@testset "GCInvariantVerifier" begin
    @test JuliaIR.GCInvariantVerifierPass().required
    @test_throws ArgumentError("option strong of pass jl-gc-invariant-verifier must be true or false") JuliaIR.GCInvariantVerifierPass(; strong=1)
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
            run!(JuliaIR.GCInvariantVerifierPass(; strong=true), mod)
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
            run!(JuliaIR.GCInvariantVerifierPass(), mod)
        catch err
            err
        end
        @test length(err.ex.violations) == 2
    end
end

@testset "LateGCCleanup" begin
    @test JuliaIR.LateGCCleanupPass().required
    @test JuliaIR.LateLowerGCFramePass().required

    # Calls marked julia.safepoint are safepoints whatever memory effects they, or the
    # functions they call, claim, and lose them, so that optimizations after FinalLowerGC
    # (a module pass on 1.10) keep the roots stored for them.
    final = VERSION < v"1.11-" ? "function(jl-late-lower-gc-frame),FinalLowerGC" :
                                 "function(jl-late-lower-gc-frame,FinalLowerGC)"
    for (decl, call) in (("", "readnone"), ("readnone", ""))
        out = IOBuffer()
        JuliaIR.jlopt(["-S", "-passes=$final,function(sroa,dse,instcombine)", "-"];
                      stdin=IOBuffer("""
                          declare ptr @julia.get_pgcstack()
                          declare ptr addrspace(10) @alloc()
                          declare void @callee(ptr addrspace(10)) $decl

                          define ptr addrspace(10) @marked() {
                          top:
                            %pgcstack = call ptr @julia.get_pgcstack()
                            %x = call ptr addrspace(10) @alloc()
                            call void @callee(ptr addrspace(10) %x) $call "julia.safepoint"
                            ret ptr addrspace(10) %x
                          }"""), stdout=out)
        @test occursin(r"store ptr addrspace\(10\) %x, ptr [^\n]*\n\s*call void @callee",
                       String(take!(out)))
    end

    # the general pass lowers what the cleanup rejects
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
            declare ptr addrspace(10) @julia.typeof(ptr addrspace(10))

            define ptr addrspace(10) @f(ptr addrspace(10) %obj) {
              %t = call ptr addrspace(10) @julia.typeof(ptr addrspace(10) %obj)
              ret ptr addrspace(10) %t
            }""") begin
        run!(JuliaIR.LateLowerGCFramePass(), mod)
        @test !occursin("julia.typeof(", string(mod.functions["f"]))
        tag = dialect.gc_names ? "%obj.tag" : "%[0-9]+"
        @test occursin(Regex("and i64 $tag, -16"), string(mod.functions["f"]))
    end

    # lowering an allocation needs runtime facts: given as pass options, or the running
    # Julia's
    alloc_ir = """
        target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"
        @tag = external addrspace(10) global {}, align 16
        declare ptr @julia.get_pgcstack()
        declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
        define ptr addrspace(10) @alloc(ptr %task) {
        top:
          %pgcstack = call ptr @julia.get_pgcstack()
          %v = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 8, ptr addrspace(10) @tag)
          ret ptr addrspace(10) %v
        }"""
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, alloc_ir) begin
        run!(JuliaIR.LateLowerGCFramePass(; task_ptls=128), mod)
        # Julia 1.11 and older address the field in pointers, later versions in bytes
        index = dialect.gc_ptls_gep === :pointer ? "i64 16" : "i32 128"
        @test occursin("ptr %task, $index", string(mod.functions["alloc"]))
    end
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, alloc_ir) begin
        run!(JuliaIR.LateLowerGCFramePass(), mod)
        @test occursin(r"%ptls_field = getelementptr inbounds \w+, ptr %task, i\d+ \d+",
                       string(mod.functions["alloc"]))
        @test !occursin("julia.gc_alloc_obj(", string(mod.functions["alloc"]))
    end

    # a function that passes its own `sret` argument on to a call returning roots in memory
    # leaves them to its caller, which allocated it; an argument with a string attribute of
    # that name is no such argument
    if dialect.gc_return_roots === :sret
        for (attr, ok) in (("sret({ ptr addrspace(10) })", true), ("\"sret\"", false))
            @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
                    declare ptr @julia.get_pgcstack()
                    declare void @callee(ptr sret({ ptr addrspace(10) }))
                    define void @forward(ptr $attr %out) {
                      %pgcstack = call ptr @julia.get_pgcstack()
                      call void @callee(ptr sret({ ptr addrspace(10) }) %out)
                      ret void
                    }""") begin
                err = try
                    run!(JuliaIR.LateLowerGCFramePass(), mod)
                    nothing
                catch err
                    err
                end
                @test ok ? err === nothing :
                           err isa PassException && occursin("expected an alloca", sprint(showerror, err))
            end
        end
    end

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
            run!(JuliaIR.LateGCCleanupPass(), mod)
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

    # Memory allocations (Julia 1.15 and later) must be lowered first, like other allocations
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
            declare ptr addrspace(10) @julia.gc_alloc_memory(ptr, i64, ptr addrspace(10), i64, i1)
            define ptr addrspace(10) @f(ptr %task) {
              %m = call ptr addrspace(10) @julia.gc_alloc_memory(ptr %task, i64 8, ptr addrspace(10) null, i64 1, i1 false)
              ret ptr addrspace(10) %m
            }""") begin
        f = mod.functions["f"]
        constructs = JuliaIR.unsupported_constructs(f, JuliaIR.Dialect(v"1.15"))
        @test startswith(only(constructs).message, "julia.gc_alloc_memory: allocations must be lowered first")
        @test isempty(JuliaIR.unsupported_constructs(f, JuliaIR.Dialect(v"1.14")))
    end

    # constructs that an earlier pass in the same pipeline introduces in a later function
    @dispose ctx=Context(; opaque_pointers=true) pb=PassBuilder() mod=parse(LLVM.Module, """
            declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))

            define void @trivial() {
              ret void
            }

            define ptr addrspace(10) @alloc(ptr %task) {
              %a = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 8, ptr addrspace(10) null)
              ret ptr addrspace(10) %a
            }""") begin
        JuliaIR.register!(pb)
        add!(pb, "function(jl-late-lower-gc-frame<task-ptls=8>,jl-late-gc-cleanup)")
        err = try
            run!(pb, mod)
            nothing
        catch err
            err
        end
        @test err isa PassException && err.ex isa JuliaIR.UnsupportedInputError
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

            # aggregates of references
            T_prjlvalue = LLVM.PointerType(10)
            for ty in (LLVM.ArrayType(T_prjlvalue, 2), LLVM.VectorType(T_prjlvalue, 2),
                       LLVM.StructType([i64, LLVM.ArrayType(T_prjlvalue, 1)]))
                empty!(info)
                JuliaIR.add_memop!(info, d, 1, UInt32(0), ty, false, true, dl)
                @test info.fields[1].hasobjref && info.fields[1].hasaggr
            end
            @test !JuliaIR.has_objref(LLVM.ArrayType(i64, 2))
            @test !JuliaIR.has_objref(LLVM.VectorType(LLVM.PointerType(0), 2))

            # the end of an access must fit in 32 bits
            @test !JuliaIR.add_memop!(info, a, 1, typemax(UInt32) - UInt32(4), i64, true, false, dl)
        end
    end

    # the pass runs again on a module whose unused lifetime declarations were removed
    # (`repeat<n>` is gone from LLVM 19 on)
    LLVM.version() < v"19" && @testset "repeated" begin
        @dispose ctx=Context(; opaque_pointers=true) pb=PassBuilder() begin
            mod = parse(LLVM.Module, """
                declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))

                define internal i8 @useobj(ptr addrspace(10) %p) alwaysinline {
                  store i8 7, ptr addrspace(10) %p
                  %v = load i8, ptr addrspace(10) %p
                  ret i8 %v
                }

                define i8 @f(ptr %task) {
                  %a = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 16, ptr addrspace(10) null)
                  %v = call i8 @useobj(ptr addrspace(10) %a)
                  ret i8 %v
                }""")
            JuliaIR.register!(pb)
            add!(pb, "repeat<2>(function(jl-alloc-opt),always-inline,strip-dead-prototypes)")
            run!(pb, mod)
            str = string(mod.functions["f"])
            @test !occursin("julia.gc_alloc_obj", str)
            @test occursin("llvm.lifetime.start", str)
            @test verify(mod) === nothing
            dispose(mod)
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
            run!(JuliaIR.AllocOptPass(), mod; remarks=r -> push!(remarks, r))
        end
        @test any(r -> r.kind === :passed && r.name == "Dead Allocation", remarks)
        @test any(r -> r.kind === :missed && r.name == "Escaped", remarks)
        # the escape analysis has its own pass name, like in C++
        unknown = only(filter(r -> r.name == "UnknownCall", remarks))
        @test unknown.kind === :missed && unknown.pass_name == "escape-analysis"
        @test unknown.message ==
              "Unknown call, marking escape (  call void @external(ptr addrspace(10) %escaped))"
        @test all(r -> r.pass_name == "alloc-opt", filter(r -> r !== unknown, remarks))
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
    # Julia 1.12 removed the pass
    changed = dialect.has_combine_muladd
    remarks = []
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
        run!(JuliaIR.CombineMulAddPass(), mod; remarks=r -> push!(remarks, r))
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

@testset "LowerSIMDLoop" begin
    @test !JuliaIR.LowerSIMDLoopPass().required
    ir = """
        define double @f(ptr %p) !dbg !3 {
        entry:
          br label %loop, !dbg !7
        loop:
          %i = phi i64 [ 0, %entry ], [ %next, %loop ]
          %acc = phi double [ 0.0, %entry ], [ %a2, %loop ]
          %v = load double, ptr %p
          %m = fmul double %v, %v
          %a1 = fadd double %acc, %m
          %a2 = fadd double %a1, %v
          %next = add i64 %i, 1
          %done = icmp eq i64 %next, 10
          br i1 %done, label %exit, label %loop, !llvm.loop !5, !dbg !8
        exit:
          ret double %a2
        }

        !llvm.dbg.cu = !{!0}
        !llvm.module.flags = !{!2}
        !0 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !1, emissionKind: FullDebug)
        !1 = !DIFile(filename: "a.jl", directory: ".")
        !2 = !{i32 2, !"Debug Info Version", i32 3}
        !3 = distinct !DISubprogram(name: "f", scope: !1, file: !1, type: !4, spFlags: DISPFlagDefinition, unit: !0)
        !4 = !DISubroutineType(types: !{})
        !5 = distinct !{!5, !"julia.simdloop", !6}
        !6 = !{!"llvm.loop.vectorize.width", i32 4}
        !7 = !DILocation(line: 7, scope: !3)
        !8 = !DILocation(line: 9, scope: !3)
        """
    flags = "Loop marked for SIMD vectorization with flags { \"simd\": true, \"ivdep\": false }"
    # Julia 1.12 and later also mark the multiplications feeding a reduction
    combine = dialect.simdloop_check_combine
    remarks = []
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
        @dispose pb=PassBuilder(; remarks=r -> push!(remarks, r)) begin
            LLVM.register!(pb, JuliaIR.LowerSIMDLoopPass())
            add!(pb, "function(loop-mssa(jl-lower-simdloop))")
            run!(pb, mod)
        end
        str = string(mod)
        @test occursin("%a1 = fadd reassoc contract double %acc, %m", str)
        @test occursin("%m = fmul $(combine ? "contract " : "")double", str)
        @test occursin(r"!llvm.loop (![0-9]+)\n.*\n\1 = distinct !{\1, ![0-9]+}\n"s, str)
        # the other loop properties are kept, the marker is gone
        @test !occursin("julia.simdloop", str)
        @test occursin("!\"llvm.loop.vectorize.width\", i32 4", str)
        # the remark about the loop is located at the preheader's terminator (the
        # start of the loop); the header's terminator keeps its own location
        header = collect(first(mod.functions).blocks)[2]
        @test LLVM.line(LLVM.terminator(header).debug_location) == 9
    end
    expected = [(:analysis, "Loop SIMD Flags", flags, 7),
                (:missed, "FirstArithmeticOpInChainIsUninteresting",
                 "first arithmetic op in chain is uninteresting", 0),
                (:passed, "MarkedUnsafeAlgebra", "marked unsafe algebra on fadd", 0)]
    combine && push!(expected, (:passed, "Marked for FMA", "marked for fma fmul", 0))
    push!(expected, (:passed, "MarkedUnsafeAlgebra", "marked unsafe algebra on fadd", 0))
    @test [(r.kind, r.name, r.message, r.line) for r in remarks] == expected
    @test all(r -> r.pass_name == "lower_simd_loop", remarks)
end

@testset "JuliaLICM" begin
    @test !JuliaIR.JuliaLICMPass().required
    @test JuliaIR.JULIA_LICM.kind === :loop
    @test JuliaIR.JULIA_LICM.cpp_name == "JuliaLICM"
    @test JuliaIR.JuliaLICMPass(; gc_barrier=:snapshot) isa LLVM.CustomPass
    @test_throws ArgumentError JuliaIR.JuliaLICMPass(; gc_barrier=:nonsense)

    object_barriers = dialect.barrier_flavour === :object_field
    barrier = object_barriers ? "julia.object_write_barrier" : "julia.write_barrier"
    ir = """
        @tag = external addrspace(10) global {}, align 16
        declare token @llvm.julia.gc_preserve_begin(...)
        declare void @llvm.julia.gc_preserve_end(token)
        declare ptr @julia.get_pgcstack()
        declare noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10)) allocsize(1)
        declare void @$barrier(ptr addrspace(10), ...)
        declare void @use(ptr addrspace(10))

        define void @f(ptr addrspace(10) %obj, ptr addrspace(10) %child, ptr %p, i1 %c) {
        top:
          %pgcstack = call ptr @julia.get_pgcstack()
          store i64 0, ptr %p
          br label %loop
        loop:
          %i = phi i64 [ 0, %top ], [ %next, %loop ]
          %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
          call void @use(ptr addrspace(10) %obj)
          call void @llvm.julia.gc_preserve_end(token %token)
          %local = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
          store i64 %i, ptr addrspace(10) %local
          %escaped = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
          call void @use(ptr addrspace(10) %escaped)
          call void (ptr addrspace(10), ...) @$barrier(ptr addrspace(10) %obj, ptr addrspace(10) %child)
          store i64 %i, ptr %p
          %next = add i64 %i, 1
          br i1 %c, label %exit, label %loop
        exit:
          ret void
        }"""

    @testset "remarks" begin
        remarks = []
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            @dispose pb=PassBuilder(; remarks=r -> push!(remarks, r)) begin
                JuliaIR.register!(pb)
                add!(pb, "function(loop-mssa(jl-licm))")
                run!(pb, mod)
            end
        end
        # LLVM 21 and later render an intrinsic call with the intrinsic's name
        intrinsic(name) = LLVM.version() >= v"21" ? "call $name" : "call"
        summary = [(r.kind, r.pass_name, r.name) for r in remarks]
        @test summary == [
            (:passed, "julia-licm", "Hoisted"),
            (:passed, "julia-licm", "Sunk"),
            (:analysis, "julia-licm", "EscapeAnalysis"),
            (:passed, "julia-licm", "Hoist"),
            (:missed, "escape-analysis", "UnknownCall"),
            (:analysis, "julia-licm", "EscapeAnalysis"),
            (:missed, "julia-licm", "Escape"),
            (:passed, "julia-licm", "Hoist")]
        messages = [r.message for r in remarks]
        @test messages[1] == "hoisting preserve begin $(intrinsic("llvm.julia.gc_preserve_begin"))"
        @test messages[2] == "sinking preserve end $(intrinsic("llvm.julia.gc_preserve_end"))"
        @test startswith(messages[3], "escape analysis for call\nAllocUseInfo:\nescaped: 0\n")
        @test occursin("\nMemOps: 1\n  offset: 0\n  size: 8\n", messages[3])
        @test messages[4] == "hoisting gc allocation call"
        @test messages[5] ==
              "Unknown call, marking escape (  call void @use(ptr addrspace(10) %escaped))"
        @test startswith(messages[6], "escape analysis for call\nAllocUseInfo:\nescaped: 1\n")
        @test messages[7] == "not hoisting gc allocation call because it may escape"
        @test messages[8] == "hoisting write barrier call"
        # the values are arguments of their own
        @test remarks[1].arguments[2] ==
              ("PreserveBegin" => intrinsic("llvm.julia.gc_preserve_begin"))
        @test first.(remarks[3].arguments) == ["String", "GC Allocation", "String", "UseInfo"]
    end

    # what `pipeline` prints for `ir` (to stderr), with MemorySSA's accesses numbered in
    # order
    function printed(ir, pipeline)
        out = tempname()
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            open(out, "w") do io
                redirect_stderr(io) do
                    @dispose pb=PassBuilder() begin
                        JuliaIR.register!(pb)
                        add!(pb, pipeline)
                        run!(pb, mod)
                    end
                end
            end
        end
        str = read(out, String)
        ids = Dict{String,String}()
        for m in eachmatch(r"; (\d+) = Memory(Def|Phi)", str)
            ids[m[1]] = string(length(ids) + 1)
        end
        renumber(line) = startswith(line, "; ") ?
            replace(line, r"\b\d+\b" => id -> get(ids, id, id)) : line
        return join(map(renumber, split(str, '\n')), '\n')
    end

    @testset "preserved analyses" begin
        # the analyses the pass keeps are those built from scratch for its result
        updated = printed(ir, "function(loop-mssa(jl-licm),print<memoryssa>)")
        @test occursin("call void @llvm.memset", updated)
        @test updated ==
              printed(ir, "function(loop-mssa(jl-licm),invalidate<memoryssa>,print<memoryssa>)")

        # ScalarEvolution, queried before the pass, forgets what the pass invalidates:
        # the loop disposition of the address of a field of a hoisted allocation
        scev_ir = """
            @tag = external addrspace(10) global {}, align 16
            declare ptr @julia.get_pgcstack()
            declare noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10)) allocsize(1)
            define void @f(i1 %c) {
            top:
              %pgcstack = call ptr @julia.get_pgcstack()
              br label %loop
            loop:
              %i = phi i64 [ 0, %top ], [ %next, %loop ]
              %local = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 16, ptr addrspace(10) @tag)
              %field = getelementptr i8, ptr addrspace(10) %local, i64 8
              store i64 %i, ptr addrspace(10) %field
              %next = add i64 %i, 1
              br i1 %c, label %exit, label %loop
            exit:
              ret void
            }"""
        updated = printed(scev_ir, "function(print<scalar-evolution>,loop-mssa(jl-licm)," *
                                   "print<scalar-evolution>)")
        @test occursin("LoopDispositions: { %loop: Invariant }", updated)
        @test updated == printed(scev_ir, "function(print<scalar-evolution>," *
                                          "loop-mssa(jl-licm),invalidate<scalar-evolution>," *
                                          "print<scalar-evolution>)")
    end

    @testset "errors" begin
        # A declaration of the object barrier with another type is rejected when a field
        # barrier is to be demoted to it, here after the allocation that is the barrier's
        # child was hoisted: the barrier stays, and the IR is valid. A field barrier that
        # keeps its slots doesn't need the declaration.
        function run_bad(slot, child)
            bad = """
                @tag = external addrspace(10) global {}
                declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
                declare void @julia.object_write_barrier(ptr)
                declare void @julia.field_write_barrier.p11(ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...)
                define void @f(ptr %task, ptr addrspace(10) %parent, ptr addrspace(10) %other, i1 %c) {
                top:
                  br label %loop
                loop:
                  %i = phi i64 [ 0, %top ], [ %i.next, %loop ]
                  %child = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 8, ptr addrspace(10) @tag)
                  %slot = getelementptr ptr addrspace(10), ptr addrspace(10) $slot
                  %slot.derived = addrspacecast ptr addrspace(10) %slot to ptr addrspace(11)
                  call void (ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %slot.derived, ptr addrspace(10) $child)
                  %i.next = add i64 %i, 1
                  br i1 %c, label %exit, label %loop
                exit:
                  ret void
                }"""
            @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, bad) begin
                err = try
                    @dispose pb=PassBuilder() begin
                        JuliaIR.register!(pb)
                        add!(pb, "function(loop-mssa(jl-licm))")
                        run!(pb, mod)
                    end
                    nothing
                catch err
                    err
                end
                verify(mod)
                # the block of the call of `callee`
                block(callee) = only(LLVM.name(bb) for bb in mod.functions["f"].blocks
                                     for inst in bb.instructions
                                     if inst isa CallInst && LLVM.name(inst.called_operand) == callee)
                return err, block("julia.field_write_barrier.p11"), block("julia.gc_alloc_obj")
            end
        end
        if object_barriers
            err, barrier_block, alloc_block = run_bad("%parent, i64 %i", "%child")
            @test err isa PassException && err.ex isa ArgumentError
            @test (barrier_block, alloc_block) == ("loop", "top")
            # the slot varies with an allocation, which is hoisted first
            @test run_bad("%child, i64 0", "%other") == (nothing, "top", "top")
        end
    end
end

@testset "LowerExcHandlers" begin
    @test JuliaIR.LowerExcHandlersPass().required
    # a handler in the running Julia's dialect; Julia 1.13 and later emit none (and have
    # no LowerExcHandlers), for them the IR of 1.12 checks that the pass does nothing
    kind = dialect.except_enter === :none ? :task_buffer : dialect.except_enter
    enter_type = kind === :task_buffer ? "{i32, ptr}" : "i32"
    enter_args = kind === :no_task ? "" : "ptr %ct"
    pop_args(n) = kind === :no_task ? "i32 $n" : "ptr %ct, i32 $n"
    ir(; triple="", call=true, pops=1) = """
        $(isempty(triple) ? "" : "target triple = \"$triple\"")
        declare $enter_type @julia.except_enter($(kind === :no_task ? "" : "ptr")) returns_twice
        declare void @ijl_pop_handler($(kind === :no_task ? "i32" : "ptr, i32"))
        define void @f(ptr %ct) {
          $(call ? "%r = call $enter_type @julia.except_enter($enter_args)" : "")
          $(call ? "call void @ijl_pop_handler($(pop_args(pops)))" : "")
          ret void
        }"""
    lowered(mod) = !occursin(r"call [^\n]*@julia.except_enter\(", string(mod))
    function lower(triple; kwargs...)
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir(; triple)) begin
            run!(JuliaIR.LowerExcHandlersPass(; kwargs...), mod)
            @test lowered(mod)
            return string(mod)
        end
    end

    # without handlers, the runtime facts aren't needed and nothing changes
    no_handlers = ir(; triple="armv7-unknown-linux-gnueabihf", call=false)
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, no_handlers) begin
        before = string(mod)
        opts = JuliaIR.parse_options(""; options=JuliaIR.LOWER_EXC_HANDLERS.options)
        @test JuliaIR.lower_exc_handlers!(mod.functions["f"], nothing, opts) ==
              PreservedAnalyses(AllAnalyses)
        @test string(mod) == before
    end

    if dialect.except_enter === :none
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir()) begin
            before = string(mod)
            run!(JuliaIR.LowerExcHandlersPass(), mod)
            @test string(mod) == before
        end
    else
        @testset "runtime facts" begin
            # the running Julia's, whatever the target
            @dispose ctx=Context(; opaque_pointers=true) mod=LLVM.Module("m") begin
                rt = JuliaIR.runtime_layout(JuliaIR.Dialect(VERSION), mod)
                for triple in ("", LLVM.default_triple(), "amdgcn-amd-amdhsa")
                    out = lower(triple)
                    @test occursin("alloca i8, i32 $(rt.handler_size), align 16", out)
                    # Windows Julia's default triple, `x86_64-w64-mingw32`, isn't
                    # normalized, so the C++ pass passes a savemask there too
                    @test occursin("call i32 @$(rt.setjmp)(ptr %1, i32 0)", out)
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
                run!(JuliaIR.LowerExcHandlersPass(; handler_size=264, handler_align=16,
                                                  setjmp="__sigsetjmp"), mod)
                @test lowered(mod)
                @test occursin("call i32 @__sigsetjmp(ptr %1)", string(mod))
                @test verify(mod) === nothing
            end
            # the signature of setjmp, explicitly
            out = lower(""; handler_size=264, handler_align=16, setjmp="__sigsetjmp",
                        setjmp_savemask=false)
            @test occursin("call i32 @__sigsetjmp(ptr %1)", out)
            out = lower("x86_64-w64-mingw32"; handler_size=320, handler_align=16,
                        setjmp="jl_setjmp", setjmp_savemask=true)
            @test occursin("call i32 @jl_setjmp(ptr %1, i32 0)", out)
            opts = JuliaIR.parse_options("setjmp-savemask=no";
                                         options=JuliaIR.LOWER_EXC_HANDLERS.options)
            @test opts.extra.setjmp_savemask === false
            @test_throws ArgumentError("option setjmp-savemask requires yes or no") JuliaIR.parse_options(
                "setjmp-savemask=auto"; options=JuliaIR.LOWER_EXC_HANDLERS.options)
            @test_throws "must be true, false or `nothing`" lower(""; handler_size=264,
                handler_align=16, setjmp="__sigsetjmp", setjmp_savemask=:auto)
        end

        @testset "lowering" begin
            @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir()) begin
                run!(JuliaIR.LowerExcHandlersPass(; handler_size=200, handler_align=16,
                                                  setjmp="sigsetjmp"), mod)
                @test lowered(mod)
                @test occursin("alloca i8, i32 200, align 16", string(mod))
                @test occursin("call i32 @sigsetjmp(ptr %1, i32 0) #0", string(mod))
            end
            # leaving more handlers than were entered is rejected before changing anything
            @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir(; pops=2)) begin
                before = string(mod)
                f = mod.functions["f"]
                opts = JuliaIR.parse_options("handler-size=200;handler-align=16;setjmp=sigsetjmp";
                                             options=JuliaIR.LOWER_EXC_HANDLERS.options)
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


@testset "LowerPTLS" begin
    @test JuliaIR.LowerPTLSPass().required
    ir(body; triple="x86_64-unknown-linux-gnu") = """
        $(isempty(triple) ? "" : "target triple = \"$triple\"")
        declare ptr @julia.get_pgcstack()
        declare ptr @julia.get_pgcstack_or_new()
        declare void @use(ptr)
        $body"""
    get_ir = """
        define void @f() {
          %pgcstack = call ptr @julia.get_pgcstack()
          call void @use(ptr %pgcstack)
          ret void
        }"""
    or_new_ir = """
        define void @f() {
          %pgcstack = call ptr @julia.get_pgcstack_or_new()
          call void @use(ptr %pgcstack)
          ret void
        }"""
    function lower(ir_str, options="")
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir_str) begin
            opts = JuliaIR.parse_options(options; options=JuliaIR.LOWER_PTLS.options)
            pa = JuliaIR.lower_ptls!(mod, nothing, opts)
            verify(mod)
            return pa, string(mod)
        end
    end

    @testset "options" begin
        opts = JuliaIR.parse_options("imaging;tls-elf-support=no;tls-offset=-1;pgcstack-getter=0x10;pgcstack-key=32";
                                     options=JuliaIR.LOWER_PTLS.options)
        @test opts.extra.imaging
        @test !opts.extra.tls_getters
        @test opts.extra.tls_offset === -1
        @test opts.extra.pgcstack_getter === UInt(0x10)
        @test opts.extra.pgcstack_key === UInt(32)
        # unspecified facts are read from the running Julia, when needed
        opts = JuliaIR.parse_options(""; options=JuliaIR.LOWER_PTLS.options)
        @test opts.extra.tls_offset === nothing
        @test_throws ArgumentError("option pgcstack-getter requires an address (a non-negative integer)") JuliaIR.parse_options("pgcstack-getter=-1";
                                                                 options=JuliaIR.LOWER_PTLS.options)
        @test JuliaIR.LowerPTLSPass(; imaging=true, tls_offset=-8,
                                    pgcstack_getter=Ptr{Cvoid}(UInt(0x1000))).required
        if dialect.ptls_jit_getter === :resolved
            _, out = lower(ir(get_ir), "tls-getters;tls-offset=-8")
            @test occursin("call ptr @jl_get_pgcstack_resolved()", out)
        else
            @test_throws "only exists from Julia 1.14 on" lower(ir(get_ir), "tls-getters")
        end
    end

    @testset "preserved analyses" begin
        # nothing to lower: nothing changes, and no fact is needed
        pa, out = lower("""
            target triple = "powerpc64le-unknown-linux-gnu"
            declare void @use(ptr)""")
        @test pa == PreservedAnalyses(AllAnalyses)
        # the GC stack through the thread pointer, or the getter: the CFG is unchanged
        pa, out = lower(ir(get_ir), "tls-offset=-8")
        @test pa == PreservedAnalyses(CFGAnalyses)
        @test occursin("movq %fs:0", out) && !occursin("@julia.get_pgcstack", out)
        pa, out = lower(ir(get_ir), "imaging;tls-elf-support=no")
        @test pa == PreservedAnalyses(CFGAnalyses)
        # the ELF TLS fast path and thread adoption split blocks
        pa, out = lower(ir(get_ir), "imaging;tls-elf-support=yes")
        @test pa == PreservedAnalyses()
        pa, out = lower(ir(or_new_ir), "tls-offset=-8;task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25")
        @test pa == PreservedAnalyses()
        @test occursin("call ptr @$(dialect.ptls_adopt_thread)()", out)
    end

    @testset "errors" begin
        # the message of the error, which must leave the module unchanged
        function rejection(ir_str, options)
            @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir_str) begin
                before = string(mod)
                opts = JuliaIR.parse_options(options; options=JuliaIR.LOWER_PTLS.options)
                err = try
                    JuliaIR.lower_ptls!(mod, nothing, opts)
                    nothing
                catch err
                    err
                end
                err isa JuliaIR.LowerPTLSError || return err
                return string(mod) == before ? sprint(showerror, err) : "module changed"
            end
        end
        bad = ir("""
            $get_ir
            define void @g(i1 %c) {
            top:
              br i1 %c, label %adopt, label %done
            adopt:
              %pgcstack = call ptr @julia.get_pgcstack_or_new()
              call void @use(ptr %pgcstack)
              br label %done
            done:
              ret void
            }""")
        @test occursin("doesn't dominate a return", rejection(bad, "tls-offset=-8"))
        # names of the image's variables that are taken by other kinds of globals
        for decl in ["@x = global ptr null\n@jl_pgcstack_func_slot = alias ptr, ptr @x",
                     "@jl_pgcstack_func_slot = external thread_local global ptr",
                     "declare void @jl_pgcstack_func_slot()"]
            @test occursin("@jl_pgcstack_func_slot is declared in the module, but not as an external, not thread-local variable",
                           rejection(ir("$decl\n$get_ir"), "imaging;tls-elf-support=no"))
        end
        # the function that adopts a thread must be declared like the getter
        adopt = dialect.ptls_adopt_thread
        facts = "tls-offset=-8;task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25"
        for decl in ["@x = global ptr null\n@$adopt = alias ptr, ptr @x",
                     "declare ptr @$adopt(i32)",
                     "declare ptr @$adopt() addrspace(1)"]
            @test occursin("@$adopt is not declared like @julia.get_pgcstack_or_new",
                           rejection(ir("$decl\n$or_new_ir"), facts))
        end
        # targets without a known thread pointer need the getter
        triple = "powerpc64le-unknown-linux-gnu"
        @test_throws JuliaIR.LowerPTLSError lower(ir(get_ir; triple), "tls-offset=-8")
        _, out = lower(ir(get_ir; triple), "tls-offset=-1;pgcstack-getter=0x1000;pgcstack-key=0")
        @test !occursin("asm", out)
        _, out = lower(ir(get_ir; triple), "imaging;tls-elf-support=no")
        @test !occursin("asm", out)
    end

    # the function that adopts a thread is declared in the getter's address space
    @testset "address space" begin
        _, out = lower("""
            target triple = "x86_64-unknown-linux-gnu"
            declare ptr @julia.get_pgcstack_or_new() addrspace(1)
            declare void @use(ptr)
            define void @f() {
              %pgcstack = call addrspace(1) ptr @julia.get_pgcstack_or_new()
              call void @use(ptr %pgcstack)
              ret void
            }""", "tls-offset=-8;task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25")
        @test occursin("call addrspace(1) ptr @$(dialect.ptls_adopt_thread)()", out)
        @test occursin("declare ptr @$(dialect.ptls_adopt_thread)() addrspace(1)", out)
        # the getter's replacements are in the default address space
        as1_ir = """
            target triple = "x86_64-unknown-linux-gnu"
            declare ptr @julia.get_pgcstack() addrspace(1)
            define ptr @f() {
              %pgcstack = call addrspace(1) ptr @julia.get_pgcstack()
              ret ptr %pgcstack
            }"""
        _, out = lower(as1_ir, "imaging;tls-elf-support=yes")
        @test occursin(r"%pgcstack = call ptr %\d+\(\)", out)
        _, out = lower(as1_ir, "imaging;tls-elf-support=no")
        @test occursin(r"%pgcstack = call ptr %\d+\(\)", out)
        _, out = lower(as1_ir, "tls-offset=-1;pgcstack-getter=0x1000;pgcstack-key=0")
        @test occursin(dialect.ptls_jit_getter === :resolved ?
                       "call ptr @jl_get_pgcstack_resolved()" :
                       "call ptr inttoptr (i64 4096 to ptr)()", out)
    end

    # the thread pointer of the host, as Julia's own code reads it (in JIT mode)
    @testset "host" begin
        rt_offset = unsafe_load(cglobal(:jl_tls_offset, Int))
        f() = (GC.safepoint(); nothing)
        julia_ir = sprint(io -> InteractiveUtils.code_llvm(io, f, (); raw=true, dump_module=true))
        m = match(r"asm \"([^\"]+)\", \"=r\"\(\)", julia_ir)
        _, out = lower(ir(get_ir; triple=""))
        if rt_offset == -1
            @test m === nothing
            if dialect.ptls_jit_getter === :resolved
                @test occursin("call ptr @jl_get_pgcstack_resolved()", out)
            else
                @test occursin(r"call ptr inttoptr \(i64 \d+ to ptr\)\(", out)
            end
        else
            @test m !== nothing
            @test occursin("asm \"$(m[1])\", \"=r\"()", out)
            @test occursin(r"getelementptr (inbounds )?i8, ptr %thread_ptr, i64 " * string(rt_offset), out)
        end
    end
end

@testset "ExpandAtomicModify" begin
    @test !JuliaIR.ExpandAtomicModifyPass().required
    decls = """
        declare {i64, i64} @julia.atomicmodify.i64(ptr, ptr, i8, i8, ...)
        declare {double, double} @julia.atomicmodify.f64(ptr, ptr, i8, i8, ...)
        declare {{i32, i32}, {i32, i32}} @julia.atomicmodify.s(ptr, ptr, i8, i8, ...)
        define i64 @add(i64 %x, i64 %y) {
          %z = add i64 %x, %y
          ret i64 %z
        }
        define i64 @mul(i64 %x, i64 %y) {
          %z = mul i64 %x, %y
          ret i64 %z
        }
        define double @fadd(double %x, double %y) {
          %z = fadd double %x, %y
          ret double %z
        }
        define {i32, i32} @second({i32, i32} %x, {i32, i32} %y) {
          ret {i32, i32} %y
        }"""
    # the error, if any, and the module after running the pass
    function expand(body)
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, decls * body) begin
            err = try
                run!(JuliaIR.ExpandAtomicModifyPass(), mod)
                nothing
            catch err
                err
            end
            return err, string(mod)
        end
    end

    ok = """
        define i64 @f(ptr %p, i64 %v) {
          %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v)
          %old = extractvalue {i64, i64} %r, 0
          ret i64 %old
        }"""
    err, str = expand(ok)
    if !dialect.has_atomicmodify
        # the IR of Julia 1.12 and earlier has no `julia.atomicmodify` calls
        @test err === nothing && occursin("@julia.atomicmodify.i64(ptr align 8 %p", str)
    else
        @test err === nothing && occursin("atomicrmw add ptr %p, i64 %v seq_cst, align 8", str)

        # calls that can't be lowered are rejected before changing anything, also when an
        # earlier call of the function could be lowered
        function rejected(body, message)
            err, str = expand(body)
            err isa PassException && err.ex isa JuliaIR.AtomicModifyError || return false
            occursin(message, sprint(showerror, err.ex)) || return false
            return occursin("@julia.atomicmodify.i64(ptr align 8 %p, ptr @add", str)
        end
        @test rejected("""
            define void @f(ptr %p, i64 %v, ptr %op) {
              %r1 = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v)
              %r2 = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr %op, i8 7, i8 1, i64 %v)
              ret void
            }""", "the operation is not a function of the old value in function f")
        @test rejected("""
            define void @f(ptr %p, i64 %v, i8 %order) {
              %r1 = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v)
              %r2 = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 %order, i8 1, i64 %v)
              ret void
            }""", "are not constants")
        @test rejected("""
            define void @f(ptr %p, i64 %v) {
              %r1 = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v)
              %r2 = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 -1, i8 1, i64 %v)
              ret void
            }""", "invalid atomic ordering 255")
        @test rejected("""
            define void @f(ptr %p, i64 %v, {i32, i32} %s) {
              %r1 = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v)
              %r2 = call {{i32, i32}, {i32, i32}} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.s(ptr align(8) %p, ptr @second, i8 7, i8 1, {i32, i32} %s)
              ret void
            }""", "don't support values of type { i32, i32 }")

        # the scope operand is an unsigned i8: scope ID 128 is `i8 -128`
        @dispose ctx=Context(; opaque_pointers=true) begin
            for i in 2:128
                SyncScope("scope$i"; context=ctx)
            end
            @test SyncScope("scope128"; context=ctx).id == 128
            @dispose mod=parse(LLVM.Module, decls * """
                define i64 @f(ptr %p, i64 %v) {
                  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 -128, i64 %v)
                  %old = extractvalue {i64, i64} %r, 0
                  ret i64 %old
                }""") begin
                run!(JuliaIR.ExpandAtomicModifyPass(), mod)
                @test occursin("""atomicrmw add ptr %p, i64 %v syncscope("scope128") seq_cst""",
                               string(mod))
            end
        end

        # a compare-exchange loop needs the alignment of the pointer (the C++ pass
        # dereferences an empty `MaybeAlign`)
        err, _ = expand("""
            define i64 @f(ptr %p, i64 %v) {
              %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr %p, ptr @mul, i8 7, i8 1, i64 %v)
              %old = extractvalue {i64, i64} %r, 0
              ret i64 %old
            }""")
        @test err isa PassException && err.ex isa JuliaIR.AtomicModifyError
        @test occursin("has no alignment", sprint(showerror, err.ex))

        # inlined into a strictfp function, `fadd` becomes a constrained intrinsic, which
        # atomicrmw doesn't support (the C++ pass aborts)
        err, _ = expand("""
            define double @f(ptr %p, double %v) strictfp {
              %r = call {double, double} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.f64(ptr align(8) %p, ptr @fadd, i8 7, i8 1, double %v) strictfp
              %old = extractvalue {double, double} %r, 0
              ret double %old
            }""")
        @test err isa PassException && err.ex isa JuliaIR.AtomicModifyError
        @test occursin("no longer matches an atomicrmw operation", sprint(showerror, err.ex))
    end
end

@testset "CancellationLowering" begin
    @test JuliaIR.CancellationLoweringPass().required
    ir = """
        declare i32 @julia.cancellation_point()
        declare ptr @julia.get_pgcstack()
        declare ptr addrspace(10) @get_obj()
        declare void @some_call()
        declare token @llvm.julia.gc_preserve_begin(...)
        declare void @llvm.julia.gc_preserve_end(token)
        define i32 @point() {
          %pgcstack = call ptr @julia.get_pgcstack()
          %r = call i32 @julia.cancellation_point()
          ret i32 %r
        }
        define void @ipo() "julia.ipo_reset_safe" {
          %pgcstack = call ptr @julia.get_pgcstack()
          call void @some_call()
          ret void
        }
        define void @none() {
          %pgcstack = call ptr @julia.get_pgcstack()
          call void @some_call()
          ret void
        }
        define void @preserve() {
          %pgcstack = call ptr @julia.get_pgcstack()
          %obj = call ptr addrspace(10) @get_obj()
          %tok = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
          %r = call i32 @julia.cancellation_point()
          call void @some_call()
          call void @llvm.julia.gc_preserve_end(token %tok)
          ret void
        }"""
    opts = JuliaIR.parse_options(""; options=JuliaIR.CANCELLATION_LOWERING.options)
    lower(mod, name) = JuliaIR.cancellation_lowering!(mod.functions[name], nothing, opts)

    if !dialect.has_cancellation_lowering
        # the IR of Julia 1.13 and earlier has no cancellation points
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            before = string(mod)
            for name in ("point", "ipo")
                @test lower(mod, name) == PreservedAnalyses(AllAnalyses)
            end
            @test string(mod) == before
        end
    else
        # a function with nothing to lower reads no runtime facts
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            empty!(JuliaIR.NATIVE_FACTS)
            @test lower(mod, "none") == PreservedAnalyses(AllAnalyses)
            @test isempty(JuliaIR.NATIVE_FACTS)
        end

        # without options, the running Julia's facts
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            rt = JuliaIR.runtime_layout(dialect, mod)
            lower(mod, "point")
            str = string(mod.functions["point"])
            @test occursin("alloca [$(rt.reset_ctx_size) x i8], align $(rt.reset_ctx_align)", str)
            @test occursin("getelementptr i8, ptr %pgcstack, i64 -$(rt.task_gcstack)", str)
            @test occursin("getelementptr i8, ptr %current_task, i64 $(rt.task_reset_ctx)", str)
            @test occursin("getelementptr i8, ptr %cancel_ucontext, i64 $(rt.reset_ctx_mctx)", str)
            @test occursin("call i32 @$(rt.setjmp)(ptr %cancel_mctx", str)
        end

        # Splitting a block for a point changes the CFG; only clears and annotations don't.
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            @test lower(mod, "point") == PreservedAnalyses()
            @test lower(mod, "ipo") == PreservedAnalyses(CFGAnalyses)
            @test lower(mod, "none") == PreservedAnalyses(AllAnalyses)
        end
        # Julia's pass reports the CFG as preserved also when it splits a block: a
        # dominator tree computed before it then lacks the new blocks, and
        # LateLowerGCFrame took the object that `GC.@preserve` keeps alive across the call
        # after the point for dead, without a GC frame to root it.
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) pb=PassBuilder() begin
            JuliaIR.register!(pb)
            add!(pb, "function(require<domtree>,jl-cancellation-lowering,jl-late-lower-gc-frame)")
            run!(pb, mod)
            str = string(mod.functions["preserve"])
            @test occursin("@julia.push_gc_frame", str)
            @test occursin(r"store ptr addrspace\(10\) %obj, ptr %gc_slot_addr", str)
        end
    end
end

@testset "RemoveAddrspaces" begin
    @test JuliaIR.RemoveJuliaAddrspacesPass().required
    @test JuliaIR.RemoveAddrspacesPass().required
    @test JuliaIR.RemoveAddrspacesPass(identity).required
    mapping = JuliaIR.cpp_mapping()
    @test mapping["RemoveJuliaAddrspaces"] == "jl-remove-addrspaces"
    @test mapping["RemoveAddrspaces"] == "jl-remove-all-addrspaces"

    ir = """
        %T = type { ptr addrspace(10), ptr addrspace(3) }
        @g = addrspace(10) global i64 0
        @s = addrspace(3) global i64 0
        define ptr addrspace(3) @f(ptr addrspace(10) %p, ptr addrspace(3) %q, ptr addrspace(1) %r) {
          %a = alloca %T
          ret ptr addrspace(3) %q
        }"""
    function remove(pass)
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            run!(pass, mod)
            @test verify(mod) === nothing
            return string(mod)
        end
    end

    # Julia's address spaces only
    str = remove(JuliaIR.RemoveJuliaAddrspacesPass())
    @test occursin("@g = global i64 0", str)
    @test occursin("@s = addrspace(3) global i64 0", str)
    @test occursin("define ptr addrspace(3) @f(ptr %p, ptr addrspace(3) %q, ptr addrspace(1) %r)", str)
    @test occursin("%T = type { ptr, ptr addrspace(3) }", str)

    # all of them
    str = remove(JuliaIR.RemoveAddrspacesPass())
    @test occursin("@s = global i64 0", str)
    @test occursin("define ptr @f(ptr %p, ptr %q, ptr %r)", str)

    # a mapping of our own
    str = remove(JuliaIR.RemoveAddrspacesPass(as -> as == 3 ? 0 : as))
    @test occursin("@g = addrspace(10) global i64 0", str)
    @test occursin("@s = global i64 0", str)
    @test occursin("define ptr @f(ptr addrspace(10) %p, ptr %q, ptr addrspace(1) %r)", str)
    @test occursin("%T = type { ptr addrspace(10), ptr }", str)
    str = remove(JuliaIR.RemoveAddrspacesPass(as -> as == 1 ? 7 : as))
    @test occursin("ptr addrspace(7) %r", str)
    # the mapping is applied once, also when it maps to an address space it changes
    str = remove(JuliaIR.RemoveAddrspacesPass(as -> as in (1, 3) ? as + 2 : as))
    @test occursin("define ptr addrspace(5) @f(ptr addrspace(10) %p, ptr addrspace(5) %q, ptr addrspace(3) %r)", str)

    # errors of the mapping are rethrown
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
        err = try
            run!(JuliaIR.RemoveAddrspacesPass(as -> error("no mapping for $as")), mod)
            nothing
        catch err
            err
        end
        @test err isa PassException
        @test occursin("no mapping for", sprint(showerror, err))
    end
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
        err = try
            run!(JuliaIR.RemoveAddrspacesPass(as -> -1), mod)
            nothing
        catch err
            err
        end
        @test err isa PassException
        @test occursin("expected an address space", sprint(showerror, err))
    end
    for bad in (2^24, 1.0, :zero)
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            err = try
                run!(JuliaIR.RemoveAddrspacesPass(as -> bad), mod)
                nothing
            catch err
                err
            end
            @test err isa PassException
            @test occursin("expected an address space", sprint(showerror, err))
        end
    end

    # The pass recreates the global values, keeping their names: references taken before
    # are invalid. Identified structs are recreated too, and the old ones renamed, which
    # other modules of the context see (like Julia's pass).
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
        other = LLVM.Module("other")
        GlobalVariable(other, ctx.types["T"], "h")
        f = mod.functions["f"]
        run!(JuliaIR.RemoveJuliaAddrspacesPass(), mod)
        @test mod.functions["f"] != f
        @test occursin("%T.bad = type { ptr addrspace(10), ptr addrspace(3) }", string(other))
        @test occursin("@h = external global %T.bad", string(other))
        @test ctx.types["T"] == first(mod.functions["f"].entry.instructions).allocated_type
        dispose(other)
    end

    # the analyses of deleted functions are removed, so that later passes don't see stale
    # results for a function that reuses the address
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) pb=PassBuilder() begin
        JuliaIR.register!(pb)
        add!(pb, "function(instcombine),jl-remove-addrspaces,function(instcombine,simplifycfg,gvn),jl-remove-addrspaces")
        run!(pb, mod)
        @test verify(mod) === nothing
    end
end

@testset "FinalLowerGC" begin
    @test JuliaIR.FinalLowerGCPass().required
    @test JuliaIR.FinalLowerGCPass(; kind=:module).type === :module
    @test JuliaIR.FinalLowerGCPass(; kind=:function).type === :function
    @test JuliaIR.FinalLowerGCPass().type === (dialect.gc_final_module ? :module : :function)
    @test_throws ArgumentError JuliaIR.FinalLowerGCPass(; kind=:loop)

    frame_ir = """
        target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"
        declare ptr @julia.get_pgcstack()
        declare noalias nonnull ptr @julia.new_gc_frame(i32)
        declare void @julia.push_gc_frame(ptr, i32)
        declare void @julia.pop_gc_frame(ptr)
        declare void @julia.safepoint(ptr)
        declare void @use(ptr)
        define void @f(ptr %page) {
        top:
          %pgcstack = call ptr @julia.get_pgcstack()
          %gcframe = call ptr @julia.new_gc_frame(i32 1)
          call void @julia.push_gc_frame(ptr %gcframe, i32 1)
          call void @use(ptr %gcframe)
          call void @julia.safepoint(ptr %page)
          call void @julia.pop_gc_frame(ptr %gcframe)
          ret void
        }"""
    function lowered(run, ir=frame_ir)
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            run(mod)
            return string(mod.functions["f"])
        end
    end

    # both kinds lower functions the same way, run directly or in a pipeline (where the
    # name is registered at both levels)
    direct = [lowered(mod -> run!(JuliaIR.FinalLowerGCPass(; kind), mod))
              for kind in (:module, :function)]
    piped = [lowered() do mod
                 @dispose pb=PassBuilder() begin
                     JuliaIR.register!(pb)
                     add!(pb, pipeline)
                     run!(pb, mod)
                 end
             end for pipeline in ("jl-final-lower-gc", "function(jl-final-lower-gc)")]
    @test allequal([direct; piped])
    @test occursin("alloca ptr addrspace(10), i32 3, align 16", direct[1])
    @test occursin("load volatile i64, ptr %page", direct[1])
    @test !occursin(r"julia\.(new_gc_frame|push_gc_frame|pop_gc_frame|safepoint)", direct[1])

    # a runtime function that the module declares differently is rejected before anything
    # is lowered
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, frame_ir * """

            declare void @ijl_gc_queue_root(ptr)""") begin
        before = string(mod)
        err = try
            run!(JuliaIR.FinalLowerGCPass(), mod)
            nothing
        catch err
            err
        end
        @test err isa PassException && err.ex isa JuliaIR.DeclarationError
        @test startswith(sprint(showerror, err.ex),
                         "DeclarationError: the module declares ijl_gc_queue_root as void (ptr)")
        @test string(mod) == before
    end

    # also when the mismatching declaration is not the first one the pass declares, or a
    # call of `julia.queue_gc_root` comes after an intrinsic the pass already lowered
    queue_ir = replace(frame_ir, "  call void @julia.safepoint(ptr %page)" =>
        "  call void @julia.queue_gc_root(ptr %page)") * """

        declare void @julia.queue_gc_root(ptr addrspace(10))"""
    for (ir, name) in ((frame_ir * "\ndeclare void @ijl_gc_alloc_typed(ptr)", "ijl_gc_alloc_typed"),
                       (queue_ir, "ijl_gc_queue_root")),
        kind in (:module, :function)
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            before = string(mod)
            err = try
                run!(JuliaIR.FinalLowerGCPass(; kind), mod)
                nothing
            catch err
                err
            end
            @test err isa PassException && err.ex isa JuliaIR.DeclarationError
            @test err isa PassException && err.ex.name == name
            @test string(mod) == before
        end
    end

    # from Julia 1.14 on, the write barriers call `julia.queue_gc_root`, unless every child
    # is null; the intrinsic is only checked when one does
    if dialect.gc_barrier_lowering === :deferred
        barrier_ir(child) = """
            declare ptr @julia.get_pgcstack()
            declare void @julia.object_write_barrier(ptr addrspace(10), ...)
            declare void @julia.queue_gc_root(ptr)
            define void @f(ptr addrspace(10) %p, ptr addrspace(10) %c) {
            top:
              %pgcstack = call ptr @julia.get_pgcstack()
              call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %p, ptr addrspace(10) $child)
              ret void
            }"""
        for kind in (:module, :function)
            @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, barrier_ir("null")) begin
                run!(JuliaIR.FinalLowerGCPass(; kind), mod)
                @test !occursin("write_barrier(", string(mod.functions["f"]))
            end
            @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, barrier_ir("%c")) begin
                before = string(mod)
                err = try
                    run!(JuliaIR.FinalLowerGCPass(; kind), mod)
                    nothing
                catch err
                    err
                end
                @test err isa PassException && err.ex isa JuliaIR.DeclarationError
                @test err isa PassException && err.ex.name == "julia.queue_gc_root"
                @test string(mod) == before
            end
        end
    end

    @testset "pool classes" begin
        # the runtime's size classes: every object up to `GC_MAX_SZCLASS` comes from a pool
        # whose objects fit it and its tag, the pools of larger objects come later
        W = sizeof(Ptr{Cvoid})
        max_szclass = 2032 - W
        sizes = 0:2100
        classes = [JuliaIR.gc_pool_class(dialect, sz) for sz in sizes]
        small = [(sz, class) for (sz, class) in zip(sizes, classes) if class !== nothing]
        @test first.(small) == 0:max_szclass
        @test all(((sz, (_, osize)),) -> osize >= sz + W, small)
        @test issorted([offset for (_, (offset, _)) in small])
        @test issorted([osize for (_, (_, osize)) in small])
        @test all(sz -> JuliaIR.gc_pool_class(dialect, sz) === nothing,
                  (max_szclass + 1, typemax(Int32), typemax(UInt64)))

        # only the running Julia's GC can be asked
        other = JuliaIR.Dialect(dialect.minor == v"1.10" ? v"1.11" : v"1.10")
        @test_throws JuliaIR.RuntimeError JuliaIR.gc_pool_class(other, 8)

        # the pass allocates the largest pooled size from its pool, one byte more as a big
        # object (whose size includes the tag)
        tag_type, tag = dialect.gc_alloc_bytes_tag ? (", i64", ", i64 0") : ("", "")
        alloc_ir(sz) = """
            target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"
            declare ptr @julia.get_pgcstack()
            declare noalias nonnull ptr addrspace(10) @julia.gc_alloc_bytes(ptr, i64$tag_type)
            define ptr addrspace(10) @f(ptr %ptls) {
            top:
              %pgcstack = call ptr @julia.get_pgcstack()
              %v = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 $sz$tag)
              ret ptr addrspace(10) %v
            }"""
        pass = mod -> run!(JuliaIR.FinalLowerGCPass(), mod)
        offset, osize = JuliaIR.gc_pool_class(dialect, max_szclass)
        small_alloc = JuliaIR.gc_alloc_function_name(dialect, :gc_small_alloc)
        big_alloc = JuliaIR.gc_alloc_function_name(dialect, :gc_big_alloc)
        @test occursin("@$small_alloc(ptr %ptls, i32 $offset, i32 $osize$tag)",
                       lowered(pass, alloc_ir(max_szclass)))
        @test occursin("@$big_alloc(ptr %ptls, i64 $(max_szclass + 1 + W)$tag)",
                       lowered(pass, alloc_ir(max_szclass + 1)))
    end
end

@testset "CPUFeatures" begin
    subtarget = dialect.cpu_features_rule === :subtarget
    @test JuliaIR.CPUFeaturesPass().required

    # the target can only be given as keyword arguments
    @test_throws ArgumentError("option target_cpu of pass jl-cpu-features must be a string or `nothing`") JuliaIR.CPUFeaturesPass(; target_cpu=:haswell)
    @test_throws ArgumentError("option target_machine of pass jl-cpu-features must be an LLVM.TargetMachine or `nothing`") JuliaIR.CPUFeaturesPass(; target_machine="x86")
    @dispose pb=PassBuilder() begin
        @test_throws "target_cpu of pass jl-cpu-features must be a string" JuliaIR.register!(pb;
            options=Dict("jl-cpu-features" => (; target_cpu=42)))
    end
    @dispose ctx=Context(; opaque_pointers=true) mod=LLVM.Module("m") pb=PassBuilder() begin
        JuliaIR.register!(pb)
        add!(pb, "jl-cpu-features<target-features=+fma>")
        @test_throws PassException run!(pb, mod)
    end

    # a module that asks about FMA for f32 and f64, without and with target attributes
    function fold(ir; triple="x86_64-unknown-linux-gnu", kwargs...)
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
                target triple = "$triple"
                declare i1 @julia.cpu.have_fma.f32()
                declare i1 @julia.cpu.have_fma.f64()
                $ir""") begin
            run!(JuliaIR.CPUFeaturesPass(; kwargs...), mod)
            return [parse(Bool, m[1]) for m in eachmatch(r"ret i1 (true|false)", string(mod))]
        end
    end
    plain = """
        define i1 @f32() {
          %r = call i1 @julia.cpu.have_fma.f32()
          ret i1 %r
        }
        define i1 @f64() {
          %r = call i1 @julia.cpu.have_fma.f64()
          ret i1 %r
        }"""
    attributed = replace(plain, "() {" => "() \"target-features\"=\"+fma\" {")
    x86 = try
        LLVM.Target(; triple="x86_64-unknown-linux-gnu")
        true
    catch
        false
    end

    @testset "preserved analyses" begin
        opts = JuliaIR.parse_options(""; options=JuliaIR.CPU_FEATURES.options)
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, """
                declare i1 @julia.cpu.have_fma.f64()
                define i1 @f() "target-features"="+fma" {
                  %r = call i1 @julia.cpu.have_fma.f64()
                  ret i1 %r
                }""") begin
            @test JuliaIR.cpu_features!(mod, nothing, opts) == PreservedAnalyses(CFGAnalyses)
            @test JuliaIR.cpu_features!(mod, nothing, opts) == PreservedAnalyses(AllAnalyses)
            # the declaration is kept
            @test haskey(mod.functions, "julia.cpu.have_fma.f64")
        end
    end

    @testset "errors" begin
        # the module is left alone, also the calls before the one that fails
        ir = """
            target triple = "x86_64-unknown-linux-gnu"
            declare i1 @julia.cpu.have_fma.f64()
            declare void @g(ptr)
            define i1 @f() "target-features"="+fma" {
              %r = call i1 @julia.cpu.have_fma.f64()
              call void @g(ptr @julia.cpu.have_fma.f64)
              ret i1 %r
            }
            """
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
            before = string(mod)
            err = try
                run!(JuliaIR.CPUFeaturesPass(), mod)
                nothing
            catch err
                err
            end
            @test err isa PassException && err.ex isa JuliaIR.CPUFeaturesError
            @test string(mod) == before
        end
    end

    @testset "the JIT's target" begin
        jit = JuliaIR.jit_target()
        triple = unsafe_string(ccall(:JLJITGetTripleString, Cstring, (Ptr{Cvoid},),
                                     ccall(:JLJITGetJuliaOJIT, Ptr{Cvoid}, ())))
        @test jit.triple == triple
        if subtarget
            target = ccall(:jl_get_llvm_target, NTuple{2,Ptr{UInt8}}, (Cstring, Bool),
                           unsafe_string(Base.JLOptions().cpu_target), false)
            @test jit.cpu == unsafe_string(target[1])
            @test jit.features == unsafe_string(target[2])
        else
            @test jit.cpu === nothing && jit.features === nothing
        end

        # what Julia's code for `have_fma` returns, which its C++ pass decides by the JIT's
        # target up to Julia 1.13
        have32() = Core.Intrinsics.have_fma(Float32)
        have64() = Core.Intrinsics.have_fma(Float64)
        facts = JuliaIR.native_probe(:jit_fma)
        @test facts.jit_fma_f32 == have32()
        @test facts.jit_fma_f64 == have64()

        # facts are only read when a function has no target features
        empty!(JuliaIR.NATIVE_FACTS)
        @test fold(attributed) == (subtarget ? [x86, x86] : [true, true])
        @test !haskey(JuliaIR.NATIVE_FACTS, :jit_fma)
        if subtarget
            # by default, the generic CPU, as by name (which has FMA on AArch64, but not
            # on x86); the JIT's target with options
            generic = LLVM.isaarch64(LLVM.Triple(triple))
            @test fold(plain; triple) == [generic, generic]
            @test fold(plain; triple, target_cpu=jit.cpu, target_features=jit.features) ==
                  [have32(), have64()]
            # a module without a triple is for the JIT's when options give the target
            @test fold(plain; triple="", target_cpu=jit.cpu, target_features=jit.features) ==
                  [have32(), have64()]
            @test fold(plain; triple="") == [false, false]
        else
            @test fold(plain; triple) == [have32(), have64()]
            # (AArch64 always has FMA, without asking the JIT)
            @test haskey(JuliaIR.NATIVE_FACTS, :jit_fma) == !LLVM.isaarch64(LLVM.Triple(triple))

            # the JIT's answers only hold for modules of its architecture: its feature
            # string has no x86 features on ARM, and the other way around
            try
                JuliaIR.NATIVE_FACTS[:jit_target] =
                    (; triple="armv7l-unknown-linux-gnueabihf", cpu=nothing, features=nothing)
                JuliaIR.NATIVE_FACTS[:jit_fma] = (; jit_fma_f32=true, jit_fma_f64=false)
                @test fold(plain; triple="armv7l-unknown-linux-gnueabihf") == [true, false]
                @test fold(plain; triple="x86_64-unknown-linux-gnu") == [false, false]
                JuliaIR.NATIVE_FACTS[:jit_target] =
                    (; triple="i686-pc-linux-gnu", cpu=nothing, features=nothing)
                @test fold(plain; triple="x86_64-unknown-linux-gnu") == [true, false]
                @test fold(plain; triple="armv7l-unknown-linux-gnueabihf") == [false, false]
                @test fold(plain; triple="riscv64-unknown-linux-gnu") == [false, false]
            finally
                empty!(JuliaIR.NATIVE_FACTS)
            end
        end
    end

    @testset "options" begin
        # the features of the options; the CPU only counts from Julia 1.14 on
        @test fold(plain; target_features="+fma") == [x86 || !subtarget, x86 || !subtarget]
        @test fold(plain; target_features="-fma") == [false, false]
        @test fold(plain; target_cpu="haswell") == (subtarget ? [x86, x86] : fold(plain))
        @test fold(plain; target_cpu="haswell", target_features="") == [x86 && subtarget, x86 && subtarget]
        @test fold(attributed; target_features="-fma") == (subtarget ? [x86, x86] : [true, true])

        # a target machine, which the C++ pass gets in Julia's pipeline
        if x86
            target = LLVM.Target(; triple="x86_64-unknown-linux-gnu")
            @dispose tm=LLVM.TargetMachine(target, "x86_64-unknown-linux-gnu"; cpu="haswell") begin
                # up to Julia 1.13, only its (empty) feature string counts
                @test fold(plain; target_machine=tm) == [subtarget, subtarget]
                @test fold(attributed; target_machine=tm) == [true, true]
                # from Julia 1.14 on, a module without a triple is for the target
                # machine's
                @test fold(plain; triple="", target_machine=tm) == [subtarget, subtarget]
            end
            @dispose tm=LLVM.TargetMachine(target, "x86_64-unknown-linux-gnu";
                                           features="+fma") begin
                @test fold(plain; target_machine=tm) == [true, true]
                @test_throws "can't be combined" JuliaIR.CPUFeaturesPass(; target_machine=tm,
                                                                          target_cpu="haswell")
            end
        end
    end

    @test JuliaIR.always_have_fma("julia.cpu.have_fma.f64", LLVM.Triple("arm64-apple-darwin")) === true
    @test JuliaIR.always_have_fma("julia.cpu.have_fma.f16", LLVM.Triple("aarch64-unknown-linux-gnu")) === false
    @test JuliaIR.always_have_fma("julia.cpu.have_fma.f64", LLVM.Triple("x86_64-unknown-linux-gnu")) === nothing
end

end
