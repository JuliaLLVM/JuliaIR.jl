using LLVM, LLVM.IR, InteractiveUtils

# the facts for a module of the running Julia's dialect
function facts(; kwargs...)
    @dispose ctx=Context(; opaque_pointers=true) mod=LLVM.Module("facts") begin
        return JuliaIR.runtime_layout(JuliaIR.Dialect(VERSION), mod; kwargs...)
    end
end

@testset "runtime facts" begin

# Each fact of the running Julia against an independent check: what the runtime exposes,
# or the code Julia generates for other functions than the probes. Facts without such a
# check are compared with the values measured for x86-64 Linux (S24's research).
@testset "running Julia" begin
    rt = facts()
    W = sizeof(Ptr{Cvoid})
    task = current_task()
    ptls = ccall(:jl_get_ptls_states, Ptr{Cvoid}, ())

    # the task: gcstack follows the Julia-visible fields after a 4-byte one; ptls by value
    @test rt.task_gcstack == cld(sizeof(Task) + 4, W) * W
    GC.@preserve task begin
        @test unsafe_load(Ptr{Ptr{Cvoid}}(pointer_from_objref(task) + rt.task_ptls)) == ptls
    end
    # `eh` follows `ptls` and `excstack`
    @test rt.task_eh == rt.task_ptls + 2W

    # exception handlers: the setjmp of the C library, Julia's own on Windows
    libc = Base.BinaryPlatforms.libc(Base.BinaryPlatforms.HostPlatform())
    @test rt.setjmp == (Sys.iswindows() ? "ijl_setjmp" :
                        Sys.islinux() && libc == "glibc" ? "__sigsetjmp" : "sigsetjmp")
    @test rt.handler_size > 64
    @test rt.handler_align == 16

    # thread-local storage
    @test rt.tls_elf_support == (Sys.islinux() || Sys.isfreebsd())
    if rt.tls_elf_support
        @test rt.tp_asm == Dict(:x86_64 => "movq %fs:0, \$0", :i686 => "movl %gs:0, \$0",
                                :aarch64 => "mrs \$0, tpidr_el0",
                                :armv7l => "mrc p15, 0, \$0, c13, c0, 3",
                                :riscv64 => "mv \$0, tp")[Sys.ARCH]
    end

    # the cancellation points of Julia 1.14 and later
    has_cancel = isdefined(Base, Symbol("@cancel_check"))
    for name in (:task_reset_ctx, :reset_ctx_size, :reset_ctx_align, :reset_ctx_gcstack,
                 :reset_ctx_eh, :reset_ctx_mctx)
        if has_cancel
            @test getproperty(rt, name) isa Int
        else
            @test_throws "doesn't exist in the runtime of the running Julia" getproperty(rt, name)
        end
    end
    if has_cancel
        @test (rt.reset_ctx_gcstack, rt.reset_ctx_eh) == (W, 2W)
    end

    # small type tags: the header of an object of a builtin type is its type's tag, which
    # is below `max_small_tag`; other types have none
    function header_tag(x)
        box = Any[x]
        GC.@preserve box Int(unsafe_load(unsafe_load(Ptr{Ptr{UInt}}(pointer(box))) - W) >> 4)
    end
    for x in (1.0, Int32(1), true, 'c', "a string", :symbol, (1, 2), Any[])
        T = typeof(x)
        tag = Int(T.flags) >> rt.smalltag_shift
        if tag == 0
            @test header_tag(x) >= rt.max_small_tag   # the address of its type
        else
            @test header_tag(x) == tag
            @test tag < rt.max_small_tag
        end
    end
    @test Int(Int64.flags) >> rt.smalltag_shift > 0
    @test Int(Some{Int}.flags) >> rt.smalltag_shift == 0

    # the world age: the runtime's, also in the latest world
    read_world_age() = GC.@preserve task unsafe_load(Ptr{UInt}(pointer_from_objref(task) + rt.task_world_age))
    @test read_world_age() == ccall(:jl_get_tls_world_age, UInt, ())
    @test Base.invokelatest(read_world_age) == Base.get_world_counter()

    # the call-site data of a `@cfunction`: 6 words, 8 with the cached entry point and
    # world (`cfuncdata_t` in src/runtime_ccall.c)
    if VERSION >= v"1.12"
        @test rt.cfunction_cache == (VERSION < v"1.13-" ? :arguments : :cfuncdata)
        @test rt.cfuncdata_size == (rt.cfunction_cache === :arguments ? 6W : 8W)
    else
        @test_throws "doesn't exist in the runtime of the running Julia" rt.cfunction_cache
        @test_throws "doesn't exist in the runtime of the running Julia" rt.cfuncdata_size
    end

    # the values measured on x86-64 Linux with glibc; 1.14's were measured on a nightly
    # build, so prereleases (and newer versions, which have the newest dialect) only
    # report differences
    if Sys.ARCH === :x86_64 && Sys.islinux() && libc == "glibc"
        measured = Dict(
            v"1.10" => (; task_gcstack=112, task_ptls=128, task_eh=144, tls_safepoint=16,
                        tls_gc_state=25, handler_size=256, smalltag_shift=10,
                        max_small_tag=64, task_world_age=120),
            v"1.11" => (; task_gcstack=112, task_ptls=128, task_eh=144, tls_safepoint=16,
                        tls_gc_state=25, handler_size=256, smalltag_shift=10,
                        max_small_tag=64, task_world_age=120),
            v"1.12" => (; task_gcstack=152, task_ptls=168, task_eh=184, tls_safepoint=16,
                        tls_gc_state=25, handler_size=264, smalltag_shift=10,
                        max_small_tag=64, task_world_age=160, cfunction_cache=:arguments,
                        cfuncdata_size=48),
            v"1.13" => (; task_gcstack=152, task_ptls=168, task_eh=184, tls_safepoint=16,
                        tls_gc_state=25, handler_size=264, smalltag_shift=10,
                        max_small_tag=64, task_world_age=160, cfunction_cache=:cfuncdata,
                        cfuncdata_size=64),
            v"1.14" => (; task_gcstack=192, task_ptls=208, task_eh=224, tls_safepoint=16,
                        tls_gc_state=128, handler_size=280, task_reset_ctx=264,
                        reset_ctx_size=224, reset_ctx_align=8, reset_ctx_mctx=24,
                        smalltag_shift=10, max_small_tag=64, task_world_age=200,
                        cfunction_cache=:cfuncdata, cfuncdata_size=64))
        minor = JuliaIR.dialect_minor(VERSION)
        exact = isempty(VERSION.prerelease) &&
                VersionNumber(VERSION.major, VERSION.minor) == minor
        for (name, value) in pairs(measured[minor])
            if exact
                @test getproperty(rt, name) == value
            elseif getproperty(rt, name) != value
                @warn "Runtime fact $name differs from the value measured on an earlier nightly build: $(getproperty(rt, name)) (running Julia) vs $value"
            end
        end
    end

    # the GC state in the code that Julia generates for a GC-safe `ccall` (Julia 1.12
    # and later): the byte it sets to JL_GC_STATE_SAFE
    if VERSION >= v"1.12"
        # (`@eval`: older versions can't expand the macro call)
        gc_safe = @eval p -> @ccall gc_safe=true strlen(p::Ptr{UInt8})::Csize_t
        ir = sprint(io -> code_llvm(io, gc_safe, (Ptr{UInt8},); optimize=true, debuginfo=:none))
        m = match(r"store atomic i8 2, ptr (%\S+) ", ir)
        @test m !== nothing
        m = match(Regex("\\Q$(m[1])\\E = getelementptr inbounds (?:nuw )?i8, ptr %\\S+, i64 (\\d+)"), ir)
        @test m !== nothing && parse(Int, m[1]) == rt.tls_gc_state
    end

    # allocations, whose pool offset follows the thread-local state layout: what
    # Julia's code generator and FinalLowerGC emit agrees with `jl_gc_classify_pools`
    alloc() = Ref((1, 2))
    ir = sprint(io -> code_llvm(io, alloc, (); optimize=true, debuginfo=:none))
    m = match(r"@ijl_gc_(?:small|pool)_alloc(?:_instrumented)?\([^,]*, i32 (\d+), i32 (\d+)", ir)
    @test m !== nothing
    osize = Ref{Cint}(0)
    offset = ccall(:jl_gc_classify_pools, Cint, (Csize_t, Ref{Cint}), 16, osize)
    @test (parse(Int, m[1]), parse(Int, m[2])) == (offset, osize[])

    # the probes run once
    @test haskey(JuliaIR.NATIVE_FACTS, :handler)
    @test facts().handler_size === rt.handler_size
end

@testset "explicit facts" begin
    rt = facts(; task_ptls=100, setjmp="jl_setjmp", tls_elf_support=:no)
    @test rt.task_ptls == 100
    @test rt.setjmp == "jl_setjmp"
    @test rt.tls_elf_support === false
    @test rt.task_gcstack == facts().task_gcstack
    @test facts(; tp_asm="mov \$0, tp").tp_asm == "mov \$0, tp"
    @test_throws "invalid option tls-elf-support" facts(; tls_elf_support=:maybe).tls_elf_support
    @test_throws "unknown runtime fact" facts(; task_foo=1)
    @test propertynames(facts()) == keys(JuliaIR.RUNTIME_FACTS)

    # as pass options
    @test JuliaIR.runtime_options(:task_ptls, :tls_elf_support, :setjmp, :tp_asm) ==
          (; task_ptls=0, tls_elf_support=:auto, setjmp="", tp_asm="")
    @test_throws "unknown runtime fact" JuliaIR.runtime_options(:task_foo)
    extra = JuliaIR.runtime_options(:task_ptls, :tls_elf_support)
    opts = JuliaIR.parse_options("task-ptls=100;tls-elf-support=yes"; extra)
    @dispose ctx=Context(; opaque_pointers=true) mod=LLVM.Module("m") begin
        rt = JuliaIR.runtime_layout(opts, mod)
        @test rt.task_ptls == 100
        @test rt.tls_elf_support === true
        @test rt.task_gcstack == facts().task_gcstack
        @test JuliaIR.runtime_fact(JuliaIR.Dialect(VERSION), mod, :task_ptls; task_ptls=12) == 12
    end
end

end
