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
        lower(JuliaIR.lower_ptls!, JuliaIR.LOWER_PTLS, ir, v, "tls-offset=-8;$facts";
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

@testset "LateLowerGCFrame" begin
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
end

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
                v"1.14", facts)
    # its own GEPs and load of the thread-local state, and a safepoint without TBAA
    @test has(out, r"^%ptls_field_ptr = getelementptr i8, ptr %current_task, i64 208$")
    @test has(out, r"^%ptls = load ptr, ptr %ptls_field_ptr, align 8$")
    @test has(out, r"^%safepoint_addr = getelementptr inbounds i8, ptr %ptls, i32 16$")
    @test has(out, r"^%safepoint = load atomic ptr, ptr %safepoint_addr monotonic, align 8$")
    @test has(out, r"^call void @julia.safepoint\(ptr %safepoint\)$")
end

end
