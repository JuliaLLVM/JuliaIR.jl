# Facts about the Julia runtime that code is compiled against, which some passes need
# and which the IR doesn't spell out: the layout of runtime structures (task, thread-local
# state, exception handlers) and target-specific names and code. Like Julia's C++
# passes, which compile them in from Julia's headers, the ports take them from the
# running Julia, whose IR they process; see docs/src/runtime.md.

# The facts, with a description for error messages and documentation. Each can be given
# explicitly as a pass option (e.g. `handler-size=264`).
const RUNTIME_FACTS = (
    task_gcstack = "the offset of `gcstack` in `jl_task_t`",
    task_ptls = "the offset of `ptls` in `jl_task_t`",
    task_eh = "the offset of `eh` in `jl_task_t`",
    task_reset_ctx = "the offset of `reset_ctx` in `jl_task_t`",
    tls_safepoint = "the offset of `safepoint` in `jl_tls_states_t`",
    tls_gc_state = "the offset of `gc_state` in `jl_tls_states_t`",
    handler_size = "the size of an exception handler (`jl_handler_t`)",
    handler_align = "the alignment of an exception handler (`jl_handler_t`)",
    setjmp = "the name of the runtime's `setjmp` (`jl_setjmp_name`)",
    reset_ctx_size = "the size of a reset context (`jl_reset_ctx_t`)",
    reset_ctx_align = "the alignment of a reset context (`jl_reset_ctx_t`)",
    reset_ctx_gcstack = "the offset of `gcstack` in `jl_reset_ctx_t`",
    reset_ctx_eh = "the offset of `eh` in `jl_reset_ctx_t`",
    reset_ctx_mctx = "the offset of `mctx` in `jl_reset_ctx_t`",
    tls_elf_support = "whether the runtime accesses thread-local storage with ELF TLS (`jl_tls_elf_support`)",
    tls_offset = "the offset of the GC stack's thread-local variable from the thread pointer, or -1 if code can't address it (`jl_tls_offset`)",
    pgcstack_getter = "the address of the function that returns the GC stack (from `jl_pgcstack_getkey`)",
    pgcstack_key = "the key of the GC stack's thread-local variable (from `jl_pgcstack_getkey`)",
    smalltag_shift = "the position of `smalltag` in the `flags` of a `jl_datatype_t`",
    max_small_tag = "the number of small type tags (`jl_max_tags`)",
    task_world_age = "the offset of `world_age` in `jl_task_t`",
    cfunction_cache = "where the call site of a `@cfunction` caches its entry point and world (`:arguments` or `:cfuncdata`)",
    cfuncdata_size = "the size of the call-site data of a `@cfunction` (`cfuncdata_t`)",
)

# the declaration of the option that gives a fact explicitly (`nothing` when it isn't)
function fact_option(name::Symbol)
    name === :setjmp && return option(Union{Nothing,String}, nothing; valid=!isempty,
                                      requirement="a non-empty string")
    name === :tls_elf_support && return option(Union{Nothing,Bool}, nothing)
    name === :cfunction_cache &&
        return option(Union{Nothing,Symbol}, nothing; valid=in((:arguments, :cfuncdata)),
                      requirement="arguments or cfuncdata")
    name === :tls_offset && return option(Union{Nothing,Int}, nothing)
    name in (:pgcstack_getter, :pgcstack_key) && return option(Union{Nothing,UInt}, nothing)
    name in (:handler_align, :reset_ctx_align) &&
        return option(Union{Nothing,Int}, nothing; valid=ispow2,
                      requirement="a positive power of two")
    return option(Union{Nothing,Int}, nothing; valid=(>=(0)),
                  requirement="a non-negative integer")
end

"""
    JuliaIR.runtime_options(facts::Symbol...)

The pass options of a pass that needs the runtime facts `facts` (see
[`JuliaIR.runtime_layout`](@ref)), for `define_pass`'s `options`: one option per fact
that gives it explicitly (`task_ptls` is `task-ptls=N` in a pipeline).
"""
function runtime_options(facts::Symbol...)
    for f in facts
        haskey(RUNTIME_FACTS, f) || throw(ArgumentError("unknown runtime fact $f"))
    end
    return NamedTuple{facts}(map(fact_option, facts))
end

"""
    JuliaIR.RuntimeError(msg)

A fact about the Julia runtime that a pass needs is not known: the IR is of another Julia
version than the running one, the fact doesn't exist in the running Julia, or it could
not be read from it. Facts can be given explicitly with pass options.
"""
struct RuntimeError <: Exception
    msg::String
end
Base.showerror(io::IO, e::RuntimeError) = print(io, "RuntimeError: ", e.msg)

"""
    JuliaIR.RuntimeFacts

The facts about the Julia runtime for one dialect, returned by
[`JuliaIR.runtime_layout`](@ref). Each fact is a property, looked up when it is read:
reading one that is not known throws a [`JuliaIR.RuntimeError`](@ref).
"""
struct RuntimeFacts
    dialect::Dialect
    overrides::NamedTuple
end

Base.propertynames(::RuntimeFacts) = keys(RUNTIME_FACTS)

function Base.getproperty(rt::RuntimeFacts, name::Symbol)
    haskey(RUNTIME_FACTS, name) || return getfield(rt, name)
    return runtime_fact(rt, name)
end

running_julia() = "Julia $(VERSION.major).$(VERSION.minor)"

function runtime_fact(rt::RuntimeFacts, name::Symbol)
    overrides = getfield(rt, :overrides)
    given = get(overrides, name, nothing)
    given === nothing || return given
    dialect = getfield(rt, :dialect)
    julia = "Julia $(dialect.minor.major).$(dialect.minor.minor)"
    what = "$(RUNTIME_FACTS[name]) (`$name`) of $julia's runtime"
    option = "; give it with the pass option $(option_key(name))"
    if dialect.minor != dialect_minor(VERSION)
        throw(RuntimeError("$what is only known when running on $julia, not on $(running_julia())$option"))
    end
    return native_fact(name, option)
end

"""
    JuliaIR.runtime_layout(dialect::Dialect, mod::LLVM.Module; facts...)
    JuliaIR.runtime_layout(opts::PassOptions, mod::LLVM.Module)

The facts about the runtime of Julia `dialect` that passes processing `mod` need, as a
[`JuliaIR.RuntimeFacts`](@ref) whose properties are the facts:

- the layout of a task (`task_gcstack`, `task_ptls`, `task_eh` and, from Julia 1.14
  on, `task_reset_ctx`) and of the thread-local state (`tls_safepoint`, `tls_gc_state`), as
  byte offsets;
- exception handlers: `handler_size` and `handler_align` (of `jl_handler_t`) and the name
  of the runtime's `setjmp`; from Julia 1.14 on, the reset context (`reset_ctx_size`,
  `reset_ctx_align` and the offsets `reset_ctx_gcstack`, `reset_ctx_eh`, `reset_ctx_mctx`);
- thread-local storage: `tls_elf_support`, the offset `tls_offset` of the GC stack from
  the thread pointer, and the getter function of the GC stack and its key
  (`pgcstack_getter` and `pgcstack_key`, process addresses);
- small type tags, which objects of the runtime's builtin types carry in their header
  instead of the address of their type (`smalltag << 4`): where a `DataType`'s `flags`
  hold its tag (`smalltag_shift`), and how many tags there are (`max_small_tag`);
- the world age of a task (`task_world_age`, a byte offset), which a C-callable wrapper
  (`@cfunction`) sets to the latest world while it runs;
- from Julia 1.12 on, the data at the call site of a `@cfunction` that the runtime's
  `jl_get_abi_converter` resolves its entry point with: its size (`cfuncdata_size`, of
  `cfuncdata_t`), and where the entry point and the world it is valid in are cached
  (`cfunction_cache`): in two separate words passed with it (`:arguments`, Julia 1.12),
  or in its first two fields (`:cfuncdata`).

A fact is resolved when it is read, in order: from the keyword argument (pass option) of
the same name, which gives it explicitly; from the running Julia, if `dialect` is its
own; otherwise a [`JuliaIR.RuntimeError`](@ref) that names the fact and the option. Like
Julia's own passes, the running Julia's facts are used whatever target `mod` is for
(IR for targets without Julia's runtime, like GPUs, doesn't need them).

With `PassOptions`, the facts given explicitly come from the pass's options (see
[`JuliaIR.runtime_options`](@ref)).
"""
function runtime_layout(dialect::Dialect, mod::LLVM.Module; facts...)
    given = map(collect(pairs(facts))) do (k, v)
        haskey(RUNTIME_FACTS, k) || throw(ArgumentError("unknown runtime fact $k"))
        k => convert_option(fact_option(k), v, "the runtime fact $k")
    end
    return RuntimeFacts(dialect, (; given...))
end

function runtime_layout(opts::PassOptions, mod::LLVM.Module)
    facts = NamedTuple(k => v for (k, v) in pairs(opts.extra) if haskey(RUNTIME_FACTS, k))
    return runtime_layout(opts.dialect, mod; facts...)
end

"""
    JuliaIR.runtime_fact(dialect::Dialect, mod::LLVM.Module, name::Symbol; facts...)

One fact of [`JuliaIR.runtime_layout`](@ref).
"""
runtime_fact(dialect::Dialect, mod::LLVM.Module, name::Symbol; kwargs...) =
    getproperty(runtime_layout(dialect, mod; kwargs...), name)

## the running Julia's facts

# Each fact comes from one probe, run once per process when one of its facts is first
# needed: the runtime's own structures and exported functions where possible, and the
# code that Julia's code generator and C++ passes emit for a small function otherwise.
const FACT_PROBES = (
    task_gcstack = :task, task_ptls = :safepoint, task_eh = :task,
    task_reset_ctx = :cancel, tls_safepoint = :safepoint, tls_gc_state = :gc_state,
    handler_size = :handler, handler_align = :handler, setjmp = :handler,
    reset_ctx_size = :cancel, reset_ctx_align = :cancel,
    reset_ctx_gcstack = :cancel, reset_ctx_eh = :cancel, reset_ctx_mctx = :cancel,
    tls_elf_support = :tls, tls_offset = :tls,
    pgcstack_getter = :pgcstack_getkey, pgcstack_key = :pgcstack_getkey,
    smalltag_shift = :smalltag, max_small_tag = :smalltag,
    task_world_age = :world_age, cfunction_cache = :cfunction, cfuncdata_size = :cfunction,
)

# probe => its facts (a NamedTuple, `nothing` for facts the running Julia doesn't have)
# or the RuntimeError it threw
const NATIVE_FACTS = Dict{Symbol,Any}()
const NATIVE_FACTS_LOCK = ReentrantLock()

function native_probe(probe::Symbol)
    facts = lock(NATIVE_FACTS_LOCK) do
        get!(NATIVE_FACTS, probe) do
            try
                run_probe(Val(probe))
            catch err
                err isa RuntimeError || rethrow()
                err
            end
        end
    end
    facts isa RuntimeError && throw(facts)
    return facts
end

function native_fact(name::Symbol, option::String)
    value = try
        getproperty(native_probe(FACT_PROBES[name]), name)
    catch err
        err isa RuntimeError || rethrow()
        throw(RuntimeError("cannot read $(RUNTIME_FACTS[name]) (`$name`) from the running $(running_julia()): $(err.msg)$option"))
    end
    value === nothing &&
        throw(RuntimeError("$(RUNTIME_FACTS[name]) (`$name`) doesn't exist in the runtime of the running $(running_julia())$option"))
    return value
end

# the current task's `gcstack` (whose address the runtime hands out as the task's
# `pgcstack`), and its `eh`: the field that a `try` changes (to its handler) and that is
# restored when it is left
function run_probe(::Val{:task})
    task = current_task()
    W = sizeof(Ptr{Cvoid})
    n = 8
    outside = Vector{UInt}(undef, n)
    inside = Vector{UInt}(undef, n)
    restored = Vector{UInt}(undef, n)
    GC.@preserve task outside inside restored begin
        pgcstack = ccall(:jl_get_pgcstack, Ptr{Cvoid}, ())
        gcstack = Int(pgcstack - pointer_from_objref(task))
        0 < gcstack < 4096 ||
            throw(RuntimeError("the current task's `pgcstack` is not inside the task"))
        words = Ptr{UInt}(pgcstack)
        read_words!(outside, words)
        try
            read_words!(inside, words)
        catch
        end
        read_words!(restored, words)
    end
    changed = [i for i in 1:n if inside[i] != outside[i]]
    (length(changed) == 1 && outside == restored && inside[only(changed)] != 0) ||
        throw(RuntimeError("entering a `try` doesn't change exactly one field of the task after `gcstack`"))
    return (; task_gcstack=gcstack, task_eh=gcstack + (only(changed) - 1) * W)
end

@noinline function read_words!(buf::Vector{UInt}, ptr::Ptr{UInt})
    for i in eachindex(buf)
        buf[i] = unsafe_load(ptr, i)
    end
end

# the byte of the thread-local state that becomes JL_GC_STATE_SAFE (2) in a GC-safe region
function run_probe(::Val{:gc_state})
    ptls = ccall(:jl_get_ptls_states, Ptr{Cvoid}, ())
    n = 512
    before = Vector{UInt8}(undef, n)
    after = Vector{UInt8}(undef, n)
    # the GC may run while this thread is GC-safe: only copy bytes there, into memory
    # allocated before
    GC.@preserve before after begin
        ccall(:memcpy, Ptr{Cvoid}, (Ptr{UInt8}, Ptr{Cvoid}, Csize_t), before, ptls, n)
        old = ccall(:jl_gc_safe_enter, Int8, ())
        ccall(:memcpy, Ptr{Cvoid}, (Ptr{UInt8}, Ptr{Cvoid}, Csize_t), after, ptls, n)
        ccall(:jl_gc_safe_leave, Cvoid, (Int8,), old)
    end
    changed = [i - 1 for i in 1:n if before[i] == 0 && after[i] == 2]
    length(changed) == 1 ||
        throw(RuntimeError("entering a GC-safe region doesn't change exactly one byte of the thread-local state from 0 to 2"))
    return (; tls_gc_state=only(changed))
end

function run_probe(::Val{:tls})
    return (; tls_elf_support=unsafe_load(cglobal(:jl_tls_elf_support, Cint)) != 0,
            tls_offset=unsafe_load(cglobal(:jl_tls_offset, Int)))
end

# what Julia's code generator calls when it can't read the GC stack from the thread pointer
function run_probe(::Val{:pgcstack_getkey})
    getter = Ref{Ptr{Cvoid}}(C_NULL)
    key = Ref{UInt}(0)
    ccall(:jl_pgcstack_getkey, Cvoid, (Ptr{Ptr{Cvoid}}, Ptr{UInt}), getter, key)
    getter[] == C_NULL && throw(RuntimeError("`jl_pgcstack_getkey` returned no getter"))
    return (; pgcstack_getter=UInt(getter[]), pgcstack_key=key[])
end

# The small type tag of `Int64`, read from the header of a boxed `Int64`, is the field of
# `Int64.flags` that `smalltag_shift` locates. How many tags there are comes from the code
# Julia generates for `typeof` of an object of unknown type: a tag below `max_small_tag
# << 4` indexes `jl_small_typeof`.
function run_probe(::Val{:smalltag})
    box = Any[Int64(1)]
    header = GC.@preserve box begin
        obj = unsafe_load(Ptr{Ptr{UInt}}(pointer(box)))
        unsafe_load(obj - sizeof(UInt))
    end
    tag = Int(header >> 4)      # the low 4 bits are the GC's
    flags = Int(Int64.flags)
    shifts = [s for s in 0:(8 * sizeof(Int64.flags) - 1) if flags >> s == tag]
    (tag != 0 && length(shifts) == 1) ||
        throw(RuntimeError("the small type tag of `Int64` ($tag) is not a field of its `flags` ($flags)"))
    max_small_tag = with_probe_ir(probe_typeof, Tuple{Any}, "`typeof`") do mod
        bounds = Set{Int}()
        indexes = false
        for inst in instructions(mod)
            if inst isa LLVM.GetElementPtrInst
                base = inst.operands[1]
                base isa LLVM.GlobalVariable && endswith(base.name, "jl_small_typeof") &&
                    (indexes = true)
            elseif inst isa LLVM.ICmpInst && LLVM.predicate(inst) == LLVM.IntPredicate.ULT
                bound = constant_integer(inst.operands[2])
                bound === nothing || push!(bounds, bound)
            end
        end
        (indexes && length(bounds) == 1) || return nothing
        return only(bounds) >> 4
    end
    return (; smalltag_shift=only(shifts), max_small_tag)
end

# The word of the current task that the builtin `Core._call_in_world` sets to the world it
# calls in (world 1, in which the intrinsic it calls, a builtin, reads the word).
function run_probe(::Val{:world_age})
    task = current_task()
    W = sizeof(Ptr{Cvoid})
    gcstack = native_probe(:task).task_gcstack
    offsets = GC.@preserve task begin
        base = Ptr{UInt}(pointer_from_objref(task))
        [off for off in 0:W:(gcstack + 8W)
         if unsafe_load(base + off) != 1 &&
            Core._call_in_world(UInt(1), Core.Intrinsics.pointerref, base + off, 1, 1) == 1]
    end
    length(offsets) == 1 ||
        throw(RuntimeError("calling in another world doesn't change exactly one field of the current task to it"))
    return (; task_world_age=only(offsets))
end

# The call of `jl_get_abi_converter` in the code Julia generates for a `@cfunction`: its
# last argument is the call site's `cfuncdata_t`, after the cached entry point and world
# when they are separate (Julia 1.12).
probe_cfunction_target(x::Float64) = x
probe_cfunction() = @cfunction(probe_cfunction_target, Float64, (Float64,))

function run_probe(::Val{:cfunction})
    dialect_minor(VERSION) >= v"1.12" ||
        return (; cfunction_cache=nothing, cfuncdata_size=nothing)
    with_probe_ir(probe_cfunction, Tuple{}, "a `@cfunction`") do mod
        calls = [inst for inst in instructions(mod)
                 if inst isa LLVM.CallInst && inst.called_operand isa LLVM.Function &&
                    LLVM.name(inst.called_operand) == "jl_get_abi_converter"]
        length(calls) == 1 || return nothing
        args = only(calls).arguments
        length(args) in (2, 4) || return nothing
        data = args[end]
        data isa LLVM.GlobalVariable || return nothing
        size = Int(abi_size(mod.datalayout, LLVM.global_value_type(data)))
        return (; cfunction_cache=length(args) == 4 ? :arguments : :cfuncdata,
                cfuncdata_size=size)
    end
end

# the value of an integer constant, also one converted to a pointer (`inttoptr`)
function constant_integer(v::LLVM.Value)
    v isa LLVM.ConstantInt && return convert(Int, v)
    if v isa LLVM.ConstantExpr && v.opcode == LLVM.Opcode.IntToPtr
        return constant_integer(LLVM.operands(v)[1])
    end
    return nothing
end

# The probes of generated code. The code is parsed into a context of the library LLVM.jl
# uses, which may be newer than Julia's LLVM.
probe_safepoint() = (GC.safepoint(); nothing)
probe_typeof(@nospecialize(x)) = typeof(x)

function probe_handler(x::Int)
    try
        x > 0 && error("x")
        return 1
    catch
        return 2
    end
end

@static if isdefined(Base, Symbol("@cancel_check"))
    probe_cancel() = (Base.@cancel_check; 1)
end

function with_probe_ir(f, probe, types, what)
    ir = sprint(io -> InteractiveUtils.code_llvm(io, probe, types; optimize=true,
                                                 dump_module=true, debuginfo=:none))
    # Julia's code generator wrote the probe for its own LLVM, which may be newer than the
    # library that a pass runs with: inspect it with Julia's, then restore the caller's.
    result = Context(; library=:julia, opaque_pointers=true) do ctx
        @dispose mod=parse_probe_ir(ir, what) begin
            f(mod)
        end
    end
    result === nothing &&
        throw(RuntimeError("the code it generates for $what doesn't have the expected shape:\n$ir"))
    return result
end

function parse_probe_ir(ir, what)
    try
        parse(LLVM.Module, ir)
    catch err
        throw(RuntimeError("the code it generates for $what can't be parsed: $(sprint(showerror, err))"))
    end
end

instructions(mod::LLVM.Module) =
    (inst for f in mod.functions for bb in f.blocks for inst in bb.instructions)

# the base pointer and constant byte offset of a pointer
function base_offset(ptr::LLVM.Value, dl::DataLayout)
    offset = 0
    while true
        if ptr isa LLVM.GetElementPtrInst
            offset += LLVM.constant_offset(Int, ptr, dl)
            ptr = ptr.operands[1]
        elseif ptr isa LLVM.BitCastInst || ptr isa LLVM.AddrSpaceCastInst
            ptr = ptr.operands[1]
        else
            return ptr, offset
        end
    end
end

# A safepoint is a volatile load from the page that the thread-local state's `safepoint`
# points to, and the thread-local state is loaded from the task's `ptls`, at an offset
# from the task's `pgcstack`.
function run_probe(::Val{:safepoint})
    with_probe_ir(probe_safepoint, Tuple{}, "`GC.safepoint()`") do mod
        dl = mod.datalayout
        # (code coverage adds other volatile accesses)
        polls = Set{Tuple{Int,Int}}()
        for inst in instructions(mod)
            (inst isa LLVM.LoadInst && inst.volatile) || continue
            page = inst.operands[1]
            page isa LLVM.LoadInst || continue
            ptls, safepoint = base_offset(page.operands[1], dl)
            ptls isa LLVM.LoadInst || continue
            _, ptls_offset = base_offset(ptls.operands[1], dl)
            push!(polls, (ptls_offset, safepoint))
        end
        length(polls) == 1 || return nothing
        ptls_offset, safepoint = only(polls)
        gcstack = native_probe(:task).task_gcstack
        return (; task_ptls=gcstack + ptls_offset, tls_safepoint=safepoint)
    end
end

# An exception handler is a stack buffer that `setjmp` (the only call that returns twice)
# is called on: lowered by Julia's C++ LowerExcHandlers up to Julia 1.12, emitted by its
# code generator later.
function run_probe(::Val{:handler})
    with_probe_ir(probe_handler, Tuple{Int}, "a `try`") do mod
        dl = mod.datalayout
        calls = [inst for inst in instructions(mod)
                 if inst isa LLVM.CallInst && can_return_twice(inst) &&
                    !isempty(inst.arguments)]
        length(calls) == 1 || return nothing
        call = only(calls)
        buff, offset = base_offset(call.arguments[1], dl)
        (buff isa LLVM.AllocaInst && offset == 0) || return nothing
        return (; handler_size=alloca_size(buff, dl), handler_align=Int(buff.alignment),
                setjmp=call.called_operand.name)
    end
end

alloca_size(buff::LLVM.AllocaInst, dl::DataLayout) =
    Int(abi_size(dl, buff.allocated_type)) * convert(Int, buff.operands[1])

# The cancellation points of Julia 1.14 and later: `setjmp` on the `mctx` of a reset
# context on the stack, whose `gcstack` and `eh` are copied from the task, and which the
# task's `reset_ctx` points to (all addressed from the task's `pgcstack`).
function run_probe(::Val{:cancel})
    isdefined(@__MODULE__, :probe_cancel) ||
        return (; task_reset_ctx=nothing, reset_ctx_size=nothing, reset_ctx_align=nothing,
                reset_ctx_gcstack=nothing, reset_ctx_eh=nothing, reset_ctx_mctx=nothing)
    gcstack = native_probe(:task).task_gcstack
    with_probe_ir(probe_cancel, Tuple{}, "`Base.@cancel_check`") do mod
        dl = mod.datalayout
        calls = [inst for inst in instructions(mod)
                 if inst isa LLVM.CallInst && can_return_twice(inst) &&
                    !isempty(inst.arguments)]
        isempty(calls) && return nothing
        buff, mctx = base_offset(first(calls).arguments[1], dl)
        buff isa LLVM.AllocaInst || return nothing
        pgcstack = task_reset_ctx = reset_gcstack = reset_eh = nothing
        stores = [inst for inst in instructions(mod) if inst isa LLVM.StoreInst]
        for store in stores
            val, ptr = store.operands
            if val == buff
                pgcstack, task_reset_ctx = base_offset(ptr, dl)
            end
        end
        pgcstack === nothing && return nothing
        for store in stores
            val, ptr = store.operands
            val isa LLVM.LoadInst || continue
            base, offset = base_offset(ptr, dl)
            base == buff || continue
            src, field = base_offset(val.operands[1], dl)
            src == pgcstack || continue
            if field == 0
                reset_gcstack = offset
            else
                reset_eh = offset
            end
        end
        (reset_gcstack === nothing || reset_eh === nothing) && return nothing
        return (; task_reset_ctx=gcstack + task_reset_ctx,
                reset_ctx_size=alloca_size(buff, dl), reset_ctx_align=Int(buff.alignment),
                reset_ctx_gcstack=reset_gcstack, reset_ctx_eh=reset_eh, reset_ctx_mctx=mctx)
    end
end


## the running Julia's GC size classes

# allocation size => its pool (offset, object size), or `nothing` for big objects
const POOL_CLASSES = Dict{UInt64,Union{Nothing,Tuple{Int,Int}}}()
const POOL_CLASSES_LOCK = ReentrantLock()

"""
    JuliaIR.gc_pool_class(dialect::Dialect, sz::Integer)

How the running Julia's GC allocates an object of `sz` bytes: the offset of its pool in
the thread-local state and the size of the pool's objects, `(offset, osize)`, or
`nothing` when the object is too big for a pool. This is what Julia's FinalLowerGC asks
the runtime (`jl_gc_classify_pools`), which compiles the allocation into a call of the
pool's allocation function, and depends on the build (e.g. the page size).

Only the running Julia's GC can be asked: for another `dialect`, or a running Julia that
was built with another GC than the stock one, this throws a
[`JuliaIR.RuntimeError`](@ref). The answers are cached for the process.
"""
function gc_pool_class(dialect::Dialect, sz::Integer)
    julia = "Julia $(dialect.minor.major).$(dialect.minor.minor)"
    dialect.minor == dialect_minor(VERSION) ||
        throw(RuntimeError("the GC size class of an allocation of $sz bytes is only known when running on $julia, not on $(running_julia())"))
    if isdefined(GC, :gc_active_impl)
        impl = GC.gc_active_impl()
        occursin("stock", impl) ||
            throw(RuntimeError("the running $(running_julia()) uses a GC that its FinalLowerGC doesn't lower allocations for ($impl)"))
    end
    lock(POOL_CLASSES_LOCK) do
        get!(POOL_CLASSES, UInt64(sz)) do
            osize = Ref{Cint}(0)
            offset = ccall(:jl_gc_classify_pools, Cint, (Csize_t, Ref{Cint}), sz, osize)
            offset < 0 ? nothing : (Int(offset), Int(osize[]))
        end
    end
end


## the JIT's target

# What Julia's JIT compiles for: Julia's CPUFeatures pass uses it for functions without
# target attributes. Unlike the runtime facts, these describe a target, which
# CPUFeatures takes as its options (`target_cpu`, `target_features`, `target_machine`);
# the running Julia's are the defaults where the C++ pass uses the JIT's.

probe_have_fma32() = Core.Intrinsics.have_fma(Float32)
probe_have_fma64() = Core.Intrinsics.have_fma(Float64)

# the constant that a function without arguments returns, once optimized by Julia's
# pipeline
function probe_constant(probe, what)
    with_probe_ir(probe, Tuple{}, what) do mod
        values = Set{Int}()
        # (not its wrappers, like `jfptr_*`)
        for f in mod.functions, bb in f.blocks, inst in bb.instructions
            startswith(LLVM.name(f), "julia_") || continue
            inst isa LLVM.RetInst || continue
            val = only(inst.operands)
            val isa LLVM.ConstantInt || return nothing
            push!(values, convert(Int, val))
        end
        length(values) == 1 || return nothing
        return only(values)
    end
end

# Up to Julia 1.13, the C++ pass decides whether a function without `target-features`
# has FMA by looking for some features in the JIT's feature string, which Julia doesn't
# export. Only two answers of it matter, which the pass gives for the code that Julia
# generates for `Core.Intrinsics.have_fma`.
function run_probe(::Val{:jit_fma})
    f32 = probe_constant(probe_have_fma32, "`Core.Intrinsics.have_fma(Float32)`")
    f64 = probe_constant(probe_have_fma64, "`Core.Intrinsics.have_fma(Float64)`")
    return (; jit_fma_f32=f32 != 0, jit_fma_f64=f64 != 0)
end

# Up to Julia 1.11, the C++ DemoteFloat16 decides whether a function without
# `target-features` keeps `half` by looking for some features in the JIT's feature string;
# the code that Julia generates for `Float16` arithmetic shows its answer.
probe_fp16_mul(a::Float16, b::Float16) = a * b

function run_probe(::Val{:jit_fp16})
    what = "`*(::Float16, ::Float16)`"
    with_probe_ir(probe_fp16_mul, Tuple{Float16,Float16}, what) do mod
        kept = demoted = false
        for f in mod.functions, bb in f.blocks, inst in bb.instructions
            startswith(LLVM.name(f), "julia_") || continue
            inst isa LLVM.FMulInst || continue
            ty = LLVM.value_type(inst)
            ty isa LLVM.HalfType && (kept = true)
            ty isa LLVM.FloatType && (demoted = true)
        end
        kept == demoted && return nothing
        return kept
    end
end

# The JIT's triple, and from Julia 1.14 on its CPU and feature string, as Julia's JIT
# creates its target machine with them.
function run_probe(::Val{:jit_target})
    jit = ccall(:JLJITGetJuliaOJIT, Ptr{Cvoid}, ())
    triple = unsafe_string(ccall(:JLJITGetTripleString, Cstring, (Ptr{Cvoid},), jit))
    cpu = features = nothing
    # before, `jl_get_llvm_target` returns a C++ type
    if Dialect(VERSION).cpu_features_rule === :subtarget
        imaging = ccall(:jl_generating_output, Cint, ()) != 0
        target = ccall(:jl_get_llvm_target, NTuple{2,Ptr{UInt8}}, (Cstring, Bool),
                       unsafe_string(Base.JLOptions().cpu_target), imaging)
        cpu, features = unsafe_string(target[1]), unsafe_string(target[2])
    end
    return (; triple, cpu, features)
end

"""
    JuliaIR.jit_target()

The target that the running Julia's JIT compiles for, as a named tuple of its `triple`,
`cpu` and `features` (a feature string like `"+avx2,-fma"`). Julia's own pipeline runs
its CPUFeatures pass with the JIT's target machine; to do the same with
[`JuliaIR.CPUFeaturesPass`](@ref), pass it the `cpu` and `features`.

Up to Julia 1.13, the JIT's CPU and features aren't exported (they are `nothing`), and
the pass doesn't need them: it uses the JIT's answers by default, see
[`JuliaIR.CPUFeaturesPass`](@ref).
"""
jit_target() = native_probe(:jit_target)
