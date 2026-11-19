using LLVM, LLVM.IR

# The code that the GC lowering passes emit to reach the thread-local state, poll
# safepoints and switch the GC state, which several passes share: each pass's forms, for
# the dialect of every Julia version, with the runtime facts given explicitly.
@testset "GC codegen" begin

X86_64 = """
    target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128-ni:10:11:12:13"
    target triple = "x86_64-unknown-linux-gnu"
    """
I686 = """
    target datalayout = "e-m:e-p:32:32-p270:32:32-p271:32:32-p272:64:64-i128:128-f64:32:64-f80:32-n8:16:32-S128-ni:10:11:12:13"
    target triple = "i686-unknown-linux-gnu"
    """

FACTS = "task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25"

# the output of `pass!(f_or_mod, am, opts)` on `ir`, with the options of `def` for the
# dialect of Julia `v`
function lower(pass!, def, ir, v, options; target=:function)
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
        opts = JuliaIR.parse_options(options; options=def.options)
        opts = JuliaIR.PassOptions(JuliaIR.Dialect(v), opts.extra)
        if target === :module
            pass!(mod, nothing, opts)
        else
            pass!(mod.functions["f"], nothing, opts)
        end
        verify(mod)
        return string(mod)
    end
end

# the lines of `out` in function `f`, without leading spaces
function body(out)
    m = match(r"define [^\n]*@f\(.*?\n}"s, out)
    return [strip(l) for l in split(m.match, '\n')]
end

has(out, line) = any(==(line), body(out))
has(out, re::Regex) = any(l -> occursin(re, l), body(out))

@testset "LowerPTLS" begin
    or_new(prefix) = """
        $prefix
        declare ptr @julia.get_pgcstack_or_new()
        declare void @use(ptr)
        define void @f() {
          %pgcstack = call ptr @julia.get_pgcstack_or_new()
          call void @use(ptr %pgcstack)
          ret void
        }"""
    ptls(ir, v, facts=FACTS) =
        lower(JuliaIR.lower_ptls!, JuliaIR.LOWER_PTLS, ir, v, "tls-offset=-8;tls-elf-support=yes;$facts";
              target=:module)

    # the task and its thread-local state: pointer-sized GEPs up to Julia 1.11
    for v in (v"1.10", v"1.11")
        out = ptls(or_new(X86_64), v)
        @test has(out, r"^%current_task\d* = getelementptr inbounds ptr, ptr %\S+, i64 -19$")
        @test has(out, r"^%ptls_field\d* = getelementptr inbounds ptr, ptr %current_task\d*, i64 21$")
        @test has(out, r"^%\d+ = getelementptr inbounds ptr, ptr %ptls_load\d*, i64 2$")
        @test has(out, r"^%safepoint\d* = load ptr, ptr %\d+, align 8, !tbaa")
    end
    for v in (v"1.12", v"1.13", v"1.14")
        out = ptls(or_new(X86_64), v)
        @test has(out, r"^%current_task\d* = getelementptr inbounds i8, ptr %\S+, i32 -152$")
        @test has(out, r"^%ptls_field\d* = getelementptr inbounds i8, ptr %current_task\d*, i32 168$")
    end

    # the safepoint page: a plain load up to 1.12, monotonic on 1.13, also with a named
    # address from 1.14 on
    out = ptls(or_new(X86_64), v"1.12")
    @test has(out, r"^%safepoint\d* = load ptr, ptr %\d+, align 8, !tbaa")
    out = ptls(or_new(X86_64), v"1.13")
    @test has(out, r"^%safepoint\d* = load atomic ptr, ptr %\d+ monotonic, align 8, !tbaa")
    out = ptls(or_new(X86_64), v"1.14")
    @test has(out, r"^%safepoint_addr\d* = getelementptr inbounds i8, ptr %ptls_load\d*, i32 16$")
    @test has(out, r"^%safepoint\d* = load atomic ptr, ptr %safepoint_addr\d* monotonic, align 8, !tbaa")

    # final safepoints: a volatile load of the page between signal fences
    for v in (v"1.10", v"1.12", v"1.14")
        out = ptls(or_new(X86_64), v)
        @test has(out, r"^%\d+ = load volatile i64, ptr %safepoint\d*, align 8$")
        @test has(out, "fence syncscope(\"singlethread\") seq_cst")
        @test !occursin("julia.safepoint", out)
    end

    # the GC state byte: stored with alignment 1, whatever its offset
    out = ptls(or_new(X86_64), v"1.12")
    @test has(out, r"^%gc_state\d* = getelementptr inbounds i8, ptr %ptls_load\d*, i32 25$")
    @test has(out, r"^store atomic i8 0, ptr %gc_state\d* release, align 1$")
    @test has(out, r"^%old_state\d* = load atomic i8, ptr %gc_state\d* monotonic, align 1$")
    out = ptls(or_new(X86_64), v"1.12", "task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=24")
    @test has(out, r"^store atomic i8 0, ptr %gc_state\d* release, align 1$")

    # a 32-bit target: pointer-sized integers and alignments
    out = ptls(or_new(I686), v"1.11", "task-gcstack=76;task-ptls=84;tls-safepoint=8;tls-gc-state=13")
    @test has(out, r"^%current_task\d* = getelementptr inbounds ptr, ptr %\S+, i32 -19$")
    @test has(out, r"^%\d+ = load volatile i32, ptr %safepoint\d*, align 4$")
    out = ptls(or_new(I686), v"1.12", "task-gcstack=76;task-ptls=84;tls-safepoint=8;tls-gc-state=13")
    @test has(out, r"^%ptls_load\d* = load ptr, ptr %ptls_field\d*, align 4, !tbaa")
    @test has(out, r"^%safepoint\d* = load ptr, ptr %\d+, align 4, !tbaa")

    # facts are read when needed: a getter without adoption needs none of the task's,
    # adoption of a foreign dialect without them names the first one it needs
    get_ir = """
        $X86_64
        declare ptr @julia.get_pgcstack()
        declare void @use(ptr)
        define void @f() {
          %pgcstack = call ptr @julia.get_pgcstack()
          call void @use(ptr %pgcstack)
          ret void
        }"""
    foreign = VERSION < v"1.12" ? v"1.14" : v"1.10"
    @test occursin("%fs:0", ptls(get_ir, foreign, ""))
    @test_throws JuliaIR.RuntimeError ptls(or_new(X86_64), foreign, "")
    @test_throws "task_gcstack" ptls(or_new(X86_64), foreign, "")
end

# the dialects from Julia 1.11 on declare the allocation functions with the memory
# attribute of LLVM 16
LLVM.version() >= v"16" && @testset "LateLowerGCFrame" begin
    transition(prefix; decl="declare void @julia.safepoint(ptr)") = """
        $prefix
        declare ptr @julia.get_pgcstack()
        declare void @ext(ptr)
        $decl
        define void @f(ptr %ptls) {
        top:
          %pgcstack = call ptr @julia.get_pgcstack()
          call void @ext(ptr null) [ "gc-transition"(ptr %ptls) ]
          ret void
        }"""
    llgcf(ir, v, facts=FACTS) =
        lower(JuliaIR.late_lower_gc_frame!, JuliaIR.LATE_LOWER_GC_FRAME, ir, v, facts)

    # the thread-local state: from the GC stack's task on 1.12, the bundle's after
    out = llgcf(transition(X86_64; decl=""), v"1.12")
    @test has(out, r"^%current_task\d* = getelementptr inbounds i8, ptr %pgcstack, i32 -152$")
    @test has(out, r"^%ptls_load\d* = load ptr, ptr %ptls_field\d*, align 8, !tbaa")
    @test has(out, r"^%gc_state\d* = getelementptr inbounds i8, ptr %ptls_load\d*, i32 25$")
    out = llgcf(transition(X86_64; decl=""), v"1.13")
    @test has(out, r"^%gc_state\d* = getelementptr inbounds i8, ptr %ptls, i32 25$")

    # the GC state byte, with the pointer alignment that its offset allows
    @test has(out, r"^%\d+ = load atomic i8, ptr %gc_state monotonic, align 1$")
    @test has(out, r"^store atomic i8 2, ptr %gc_state release, align 1$")
    out = llgcf(transition(X86_64; decl=""), v"1.14",
                "task-gcstack=192;task-ptls=208;tls-safepoint=16;tls-gc-state=128")
    @test has(out, r"^%\d+ = load atomic i8, ptr %gc_state monotonic, align 8$")
    @test has(out, r"^store atomic i8 %\d+, ptr %gc_state release, align 8$")

    # safepoints: a call of `julia.safepoint` on the page, loaded with constant TBAA
    for (v, load) in ((v"1.12", r"^%safepoint\d* = load ptr, ptr %\d+, align 8, !tbaa ![0-9]+, !invariant.load"),
                      (v"1.13", r"^%safepoint\d* = load atomic ptr, ptr %\d+ monotonic, align 8, !tbaa ![0-9]+, !invariant.load"),
                      (v"1.14", r"^%safepoint\d* = load atomic ptr, ptr %safepoint_addr\d* monotonic, align 8, !tbaa ![0-9]+, !invariant.load"))
        out = llgcf(transition(X86_64; decl=""), v)
        @test has(out, load)
        @test count(l -> occursin(r"^call void @julia.safepoint\(ptr %safepoint\d*\)$", l), body(out)) == 2
        @test occursin(r"declare void @julia.safepoint\(ptr\) #\d+", out)
    end

    # an existing declaration is called as it is
    out = llgcf(transition(X86_64; decl="declare void @julia.safepoint(ptr) nounwind"), v"1.13")
    @test count(l -> occursin(r"^call void @julia.safepoint\(ptr %safepoint\d*\)$", l), body(out)) == 2
    @test occursin("declare void @julia.safepoint(ptr) #0", out)
    @test occursin("attributes #0 = { nounwind }", out)
    # also with another type
    out = llgcf(transition(X86_64; decl="declare void @julia.safepoint(ptr, ...)"), v"1.13")
    @test count(l -> occursin(r"^call void \(ptr, \.\.\.\) @julia.safepoint\(ptr %safepoint\d*\)$", l), body(out)) == 2
    @test occursin("declare void @julia.safepoint(ptr, ...)\n", out)

    # a 32-bit target
    out = llgcf(transition(I686; decl=""), v"1.12", "task-gcstack=76;task-ptls=84;tls-safepoint=8;tls-gc-state=13")
    @test has(out, r"^%ptls_load\d* = load ptr, ptr %ptls_field\d*, align 4, !tbaa")
    @test has(out, r"^%safepoint\d* = load ptr, ptr %\d+, align 4, !tbaa")
    @test has(out, r"^%\d+ = load atomic i8, ptr %gc_state monotonic, align 1$")

    # facts are read when needed
    foreign = VERSION < v"1.13" ? v"1.14" : v"1.12"
    plain = """
        $X86_64
        define void @f() {
          ret void
        }"""
    @test occursin("ret void", llgcf(plain, foreign, ""))
    @test_throws JuliaIR.RuntimeError llgcf(transition(X86_64), foreign, "")

    # `julia.gc_alloc_memory` (Julia 1.14 and later): a pooled object with inline data if
    # its size is a constant that fits, the runtime's allocation otherwise; the header is
    # initialized for the pointer size of the target
    memory(prefix, nbytes, len, zeroinit; T="i64") = """
        $prefix
        @tag = external addrspace(10) global {}, align 16
        declare ptr @julia.get_pgcstack()
        declare ptr addrspace(10) @julia.gc_alloc_memory(ptr, $T, ptr addrspace(10), $T, i1)
        define ptr addrspace(10) @f(ptr %task, $T %n, i1 %z) {
        top:
          %pgcstack = call ptr @julia.get_pgcstack()
          %mem = call ptr addrspace(10) @julia.gc_alloc_memory(ptr %task, $T $nbytes, ptr addrspace(10) @tag, $T $len, i1 $zeroinit)
          ret ptr addrspace(10) %mem
        }"""
    facts64 = "task-gcstack=192;task-ptls=208;tls-safepoint=16;tls-gc-state=128"
    facts32 = "task-gcstack=76;task-ptls=84;tls-safepoint=8;tls-gc-state=13"
    out = llgcf(memory(X86_64, 32, 4, true), v"1.14", facts64)
    @test has(out, r"^%mem = call noalias nonnull dereferenceable\(48\) ptr addrspace\(10\) @julia.gc_alloc_bytes\(ptr %ptls_load, i64 48, ")
    @test has(out, r"^%(\d+) = getelementptr inbounds i8, ptr %\d+, i64 16$")
    @test has(out, r"^%\d+ = getelementptr inbounds i8, ptr addrspace\(11\) %\d+, i64 8$")
    @test has(out, r"^call void @llvm.memset.p0.i64\(ptr align 8 %\d+, i8 0, i64 32, i1 false\)$")
    @test has(out, r"^store i64 4, ptr addrspace\(11\) %\d+, align 8$")
    # the largest data that fits a pool of a 32-bit target
    out = llgcf(memory(I686, 2012, "%n", false; T="i32"), v"1.14", facts32)
    @test has(out, r"@julia.gc_alloc_bytes\(ptr %ptls_load, i32 2028, ")
    @test has(out, r"^%\d+ = getelementptr inbounds i8, ptr addrspace\(11\) %\d+, i64 4$")
    @test !occursin("memset", out)
    @test has(out, r"^store i32 %n, ptr addrspace\(11\) %\d+, align 4$")
    out = llgcf(memory(I686, 2013, "%n", true; T="i32"), v"1.14", facts32)
    @test has(out, r"^%mem = call noalias nonnull align 16 dereferenceable\(8\) ptr addrspace\(10\) @jl_alloc_genericmemory_unchecked\(ptr %ptls_load, i32 2013, ptr addrspacecast \(ptr addrspace\(10\) @tag to ptr\)\)")
    @test occursin(r"declare noalias nonnull ptr addrspace\(10\) @jl_alloc_genericmemory_unchecked\(ptr, i32, ptr\) #\d+", out)
    @test has(out, r"^%(\d+) = load ptr, ptr addrspace\(11\) %\d+, align 4$")
    @test has(out, r"^call void @llvm.memset.p0.i32\(ptr align 4 %\d+, i8 0, i32 2013, i1 false\)$")
    out = llgcf(memory(X86_64, "%n", "%n", true), v"1.14", facts64)
    @test has(out, r"@jl_alloc_genericmemory_unchecked\(ptr %ptls_load, i64 %n, ")
    @test has(out, r"^call void @llvm.memset.p0.i64\(ptr align 8 %\d+, i8 0, i64 %n, i1 false\)$")
    # no data to zero
    @test !occursin("memset", llgcf(memory(X86_64, 0, 4, true), v"1.14", facts64))
    # a zeroing flag that LLVM made a variable by merging allocations
    out = llgcf(memory(X86_64, 32, 4, "%z"), v"1.14", facts64)
    @test has(out, r"^%(\d+) = select i1 %z, i64 32, i64 0$")
    @test has(out, r"^call void @llvm.memset.p0.i64\(ptr align 8 %\d+, i8 0, i64 %\d+, i1 false\)$")
    # older versions don't have the intrinsic
    out = llgcf(memory(X86_64, 32, 4, true), v"1.13", facts64)
    @test has(out, r"^%mem = call ptr addrspace\(10\) @julia.gc_alloc_memory\(")

    # From Julia 1.14 on, the slot address of a rooted alloca is computed in the blocks that
    # use it; the entry block's stays for the debug information that refers to it
    local_slot = """
        $X86_64
        declare ptr @julia.get_pgcstack()
        declare void @safepoint()
        declare void @llvm.dbg.declare(metadata, metadata, metadata)
        define void @f(i1 %c, ptr addrspace(10) %v) !dbg !4 {
        top:
          %pgcstack = call ptr @julia.get_pgcstack()
          %local = alloca ptr addrspace(10), align 8
          call void @llvm.dbg.declare(metadata ptr %local, metadata !7, metadata !DIExpression()), !dbg !8
          br i1 %c, label %use, label %exit
        use:
          store ptr addrspace(10) %v, ptr %local, align 8
          call void @safepoint()
          %l = load ptr addrspace(10), ptr %local, align 8
          call void @safepoint()
          br label %exit
        exit:
          ret void
        }
        !llvm.dbg.cu = !{!0}
        !llvm.module.flags = !{!2}
        !0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, emissionKind: FullDebug)
        !1 = !DIFile(filename: "f.jl", directory: "/")
        !2 = !{i32 2, !"Debug Info Version", i32 3}
        !4 = distinct !DISubprogram(name: "f", scope: !1, file: !1, line: 1, type: !5, spFlags: DISPFlagDefinition, unit: !0)
        !5 = !DISubroutineType(types: !6)
        !6 = !{}
        !7 = !DILocalVariable(name: "x", scope: !4, file: !1, line: 1, type: !9)
        !8 = !DILocation(line: 1, scope: !4)
        !9 = !DIBasicType(name: "Int64", size: 64, encoding: DW_ATE_signed)"""
    in_use_block(out) = (ls = body(out); ls[findfirst(l -> startswith(l, "use:"), ls):end])
    slot = r"^%local\d* = call ptr @julia.get_gc_frame_slot\(ptr %gcframe, i32 0\)$"
    out = llgcf(local_slot, v"1.14", facts64)
    @test any(l -> occursin(slot, l), in_use_block(out))
    @test occursin(r"(#dbg_declare\(|@llvm\.dbg\.declare\(metadata )ptr %local\d*,", out)
    out = llgcf(local_slot, v"1.13", facts64)
    @test !any(l -> occursin(slot, l), in_use_block(out))
    @test occursin(r"(#dbg_declare\(|@llvm\.dbg\.declare\(metadata )ptr %local\d*,", out)
    # also through a `DIArgList`
    arglist = replace(local_slot,
        "call void @llvm.dbg.declare(metadata ptr %local, metadata !7, metadata !DIExpression())" =>
        "call void @llvm.dbg.value(metadata !DIArgList(ptr %local), metadata !7, metadata !DIExpression(DW_OP_LLVM_arg, 0))",
        "declare void @llvm.dbg.declare(" => "declare void @llvm.dbg.value(")
    out = llgcf(arglist, v"1.14", facts64)
    @test any(l -> occursin(slot, l), in_use_block(out))
    @test occursin(r"DIArgList\(ptr %local\d*\)", out)

    # Write barriers on an object allocated since the last safepoint on every path to them
    # are removed (Julia 1.14 and later): a fresh object can't be old.
    barrier(body) = """
        $X86_64
        @tag = external addrspace(10) global {}, align 16
        declare ptr @julia.get_pgcstack()
        declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
        declare void @julia.object_write_barrier(ptr addrspace(10), ...)
        declare void @safepoint()
        define ptr addrspace(10) @f(ptr %task, ptr addrspace(10) %child, i1 %c) {
        top:
          %pgcstack = call ptr @julia.get_pgcstack()
          %obj = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 8, ptr addrspace(10) @tag)
        $body
          call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %obj, ptr addrspace(10) %child)
          ret ptr addrspace(10) %obj
        }"""
    has_barrier(out) = has(out, r"^call void \(ptr addrspace\(10\), \.\.\.\) @julia.object_write_barrier\(")
    fresh = barrier("  br label %next\nnext:")
    @test !has_barrier(llgcf(fresh, v"1.14", facts64))
    @test has_barrier(llgcf(fresh, v"1.13", facts64))
    # not after a safepoint
    @test has_barrier(llgcf(barrier("  call void @safepoint()"), v"1.14", facts64))
    # nor after a join where one of the paths passes one
    joined = barrier("""
          br i1 %c, label %sp, label %next
        sp:
          call void @safepoint()
          br label %next
        next:""")
    @test has_barrier(llgcf(joined, v"1.14", facts64))
end
LLVM.version() >= v"16" || @test_skip "LateLowerGCFrame needs LLVM 16"

# Julia 1.15's lowerings keep a call's cancellation reset region on the calls that replace
# it, whatever the region's metadata node holds (also with LLVM 16's memory attribute)
LLVM.version() >= v"16" && @testset "reset regions" begin
    # the node of the reset region of the call of `callee` in `out`
    function reset_region(out, callee)
        line = only(filter(l -> occursin("@$callee(", l) && occursin("call", l), body(out)))
        id = match(r"!julia.reset_region (![0-9]+)", line)[1]
        return match(Regex("\n\\$id = (.*)\n"), out)[1]
    end
    for node in ["!{}", "!{i64 1}", "!{!\"region\", i64 2}"]
        barrier = """
            $X86_64
            declare ptr @julia.get_pgcstack()
            declare void @julia.object_write_barrier(ptr addrspace(10), ...)
            define void @f(ptr addrspace(10) %p, ptr addrspace(10) %c) {
            top:
              %pgcstack = call ptr @julia.get_pgcstack()
              call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %p, ptr addrspace(10) %c), !julia.reset_region !0
              ret void
            }
            !0 = $node"""
        out = lower(JuliaIR.final_lower_gc!, JuliaIR.FINAL_LOWER_GC_FUNCTION, barrier,
                    v"1.15", "")
        @test reset_region(out, "ijl_gc_queue_root_reset_safe") == node

        alloc = """
            $X86_64
            @tag = external addrspace(10) global {}, align 16
            declare ptr @julia.get_pgcstack()
            declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
            define ptr addrspace(10) @f(ptr %task) {
            top:
              %pgcstack = call ptr @julia.get_pgcstack()
              %v = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 8, ptr addrspace(10) @tag), !julia.reset_region !0
              ret ptr addrspace(10) %v
            }
            !0 = $node"""
        out = lower(JuliaIR.late_lower_gc_frame!, JuliaIR.LATE_LOWER_GC_FRAME, alloc,
                    v"1.15", "task-gcstack=192;task-ptls=208;tls-safepoint=16;tls-gc-state=128")
        @test reset_region(out, "julia.gc_alloc_bytes") == node
    end
end
LLVM.version() >= v"16" || @test_skip "reset regions need LLVM 16"

@testset "CancellationLowering" begin
    point = """
        $X86_64
        declare i32 @julia.cancellation_point()
        declare ptr @julia.get_pgcstack()
        define i32 @f() {
          %pgcstack = call ptr @julia.get_pgcstack()
          %r = call i32 @julia.cancellation_point()
          ret i32 %r
        }"""
    facts = "task-gcstack=192;task-ptls=208;task-eh=200;task-reset-ctx=264;" *
            "tls-safepoint=16;setjmp=__sigsetjmp;reset-ctx-size=256;reset-ctx-align=16;" *
            "reset-ctx-gcstack=8;reset-ctx-eh=16;reset-ctx-mctx=32"
    out = lower(JuliaIR.cancellation_lowering!, JuliaIR.CANCELLATION_LOWERING, point,
                v"1.15", facts)
    # its own GEPs and load of the thread-local state, and a safepoint without TBAA
    @test has(out, r"^%ptls_field_ptr = getelementptr i8, ptr %current_task, i64 208$")
    @test has(out, r"^%ptls = load ptr, ptr %ptls_field_ptr, align 8$")
    @test has(out, r"^%safepoint_addr = getelementptr inbounds i8, ptr %ptls, i32 16$")
    @test has(out, r"^%safepoint = load atomic ptr, ptr %safepoint_addr monotonic, align 8$")
    @test has(out, r"^call void @julia.safepoint\(ptr %safepoint\)$")

    # A Memory allocation only runs with the region open if it becomes a pooled
    # allocation, not if it becomes a call of the runtime, even when tagged reset-safe.
    memory = """
        $X86_64
        declare i32 @julia.cancellation_point()
        declare ptr @julia.get_pgcstack()
        declare ptr @julia.gc_alloc_memory(ptr, i64, ptr, i64, i1)
        define ptr @f(i64 %n) {
          %pgcstack = call ptr @julia.get_pgcstack()
          %r = call i32 @julia.cancellation_point()
          %small = call ptr @julia.gc_alloc_memory(ptr %pgcstack, i64 32, ptr null, i64 4, i1 false)
          %large = call ptr @julia.gc_alloc_memory(ptr %pgcstack, i64 %n, ptr null, i64 %n, i1 false), !julia.reset_safe !0
          ret ptr %small
        }
        !0 = !{}"""
    clear = r"^store atomic volatile ptr null, ptr %reset_ctx_ptr monotonic"
    # the line of `name`'s definition, and whether the region is cleared just before it
    function allocation(out, name)
        lines = body(out)
        i = findfirst(l -> startswith(l, "%$name = "), lines)
        return lines[i], occursin(clear, lines[i-2])
    end
    out = lower(JuliaIR.cancellation_lowering!, JuliaIR.CANCELLATION_LOWERING, memory,
                v"1.15", facts)
    small, cleared = allocation(out, "small")
    @test endswith(small, "!julia.reset_region !0") && !cleared
    large, cleared = allocation(out, "large")
    @test !occursin("reset_region", large) && cleared
    # pure intrinsics don't close a caller's region, the call after them does
    pure = """
        $X86_64
        declare ptr @julia.get_pgcstack()
        declare double @llvm.fma.f64(double, double, double)
        declare void @unsafe()
        define double @f(double %x) "julia.ipo_reset_safe" {
          %pgcstack = call ptr @julia.get_pgcstack()
          %y = call double @llvm.fma.f64(double %x, double %x, double %x)
          call void @unsafe()
          ret double %y
        }"""
    lines = body(lower(JuliaIR.cancellation_lowering!, JuliaIR.CANCELLATION_LOWERING, pure,
                       v"1.15", facts))
    i = findfirst(l -> startswith(l, "%y = call double @llvm.fma.f64("), lines)
    @test !any(l -> occursin(clear, l), lines[1:i])
    @test occursin(clear, lines[i+1])

    # Julia 1.14 has no cancellation points, so the pass leaves the IR alone
    out = lower(JuliaIR.cancellation_lowering!, JuliaIR.CANCELLATION_LOWERING, point,
                v"1.14", facts)
    @test has(out, r"^%r = call i32 @julia.cancellation_point\(\)$")
end

end
