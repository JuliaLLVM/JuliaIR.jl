# CancellationLowering: lower the `julia.cancellation_point()` calls that the code
# generator of Julia 1.14 and later emits for `Base.@cancel_check` into reset regions.
# Port of Julia's `src/llvm-cancellation-lowering.cpp` (1.14).
#
# At a cancellation point, the function publishes a stack buffer, a `jl_reset_ctx_t`, in
# its task's `reset_ctx` field, after saving the task's GC stack and exception handler in
# it and calling `setjmp` on its `mctx` field. While the buffer is published, the runtime
# may deliver a cancellation (or a preemption) by restoring these and jumping back to the
# point. The region a publication opens has to be closed (`reset_ctx = NULL`) before
# anything that a jump back could tear: stores, atomics, volatile loads, and calls that
# are not marked `!julia.reset_safe` (and runtime calls even when they are), and before
# the function returns. Allocations and write barriers may run with the region open:
# they are marked `!julia.reset_region`, and FinalLowerGC lowers them to runtime entry
# points that close and reopen the region themselves. Functions marked
# `"julia.ipo_reset_safe"` may run inside their caller's region, so their calls close it
# too, even when they have no cancellation points of their own.
#
# The layout of the task and of `jl_reset_ctx_t`, and the name of `setjmp`, are facts of
# the runtime (`src/runtime.jl`), read only for functions that need them; whether
# `setjmp` takes a second argument follows the module's triple, as in the C++ pass. For
# the IR of Julia versions before 1.14 (`Dialect.has_cancellation_lowering`), the
# pass does nothing. Like the C++ pass, it is required (it also runs on `optnone`
# functions).

"""
    JuliaIR.CancellationLoweringError

The error thrown by CancellationLowering (`jl-cancellation-lowering`) for a cancellation
point it can't lower: one in a function without a GC stack (a `julia.get_pgcstack` call
in the entry block, or an argument with the `"gcstack"` attribute), or one that is
`invoke`d. The function is not changed.
"""
struct CancellationLoweringError <: Exception
    function_name::String
    message::String
    instruction::String
end

Base.showerror(io::IO, err::CancellationLoweringError) =
    print(io, "CancellationLoweringError: ", err.message, " in function ",
          err.function_name, "\n\t", err.instruction)

const RESET_SAFE_MD = "julia.reset_safe"
const RESET_REGION_MD = "julia.reset_region"

const CANCELLATION_RUNTIME_FACTS = (:task_gcstack, :task_ptls, :task_eh, :task_reset_ctx,
                                    :tls_safepoint, :reset_ctx_size, :reset_ctx_align,
                                    :reset_ctx_gcstack, :reset_ctx_eh, :reset_ctx_mctx,
                                    :setjmp)

# the intrinsics an untagged call may call without closing a region
const RESET_SAFE_INTRINSICS = ("llvm.lifetime.start", "llvm.lifetime.end",
                               "llvm.dbg.declare", "llvm.dbg.value", "llvm.dbg.label",
                               "llvm.assume", "llvm.expect", "llvm.prefetch")
# `DbgInfoIntrinsic`, by name: LLVM 15 has no `llvm.dbg.assign`
const DBG_INFO_INTRINSICS = ("llvm.dbg.declare", "llvm.dbg.value", "llvm.dbg.label",
                             "llvm.dbg.assign")

mutable struct CancellationLowering
    opts::PassOptions
    mod::LLVM.Module
    f::LLVM.Function
    fns::GCFunctions
    builder::IRBuilder
    gc::GCCodegen
    pgcstack::Union{Nothing,Value}
    # the GC stack's getter call, unless the GC stack is an argument
    pgcstack_inst::Union{Nothing,Instruction}
    # the addresses of the task's fields, computed once in the entry block
    reset_ctx_ptr::Union{Nothing,Instruction}
    ptls_field_ptr::Union{Nothing,Instruction}
    eh_field_ptr::Union{Nothing,Instruction}
end

intrinsic_id(callee::LLVM.Function) =
    LLVM.isintrinsic(callee) ? callee.intrinsic : nothing

has_reset_safe_md(inst::Instruction) = haskey(inst.metadata, RESET_SAFE_MD)

# mark an instruction the pass creates as reset-safe, so that the walk for unsafe points
# doesn't take the pass's own bookkeeping for program state a reset could tear
set_reset_safe_md!(inst::Instruction) = (inst.metadata[RESET_SAFE_MD] = MDNode(Metadata[]))

# Runtime machinery that the code generator inserts implicitly (calls into the runtime
# library, generic dispatch) is not part of what lets inference tag a statement
# reset-safe, and its frames must never be abandoned by a reset: such calls close the
# region even when tagged. `Function::isIntrinsic` is by name (`llvm.*`), not by ID.
function is_implicit_runtime_call(p::CancellationLowering, call::Instruction)
    callee = called_function(call)
    (callee === nothing || startswith(LLVM.name(callee), "llvm.")) && return false
    name = LLVM.name(callee)
    startswith(name, "julia.call") && return true
    # only read the setjmp fact for names it could be
    (startswith(name, "ijl_") || startswith(name, "jl_")) || return false
    return name != p.gc.layout.setjmp
end

# `BasicBlock::getTerminatingMustTailCall`
function terminating_musttail_call(bb::BasicBlock)
    ret = LLVM.terminator(bb)
    ret isa LLVM.RetInst || return nothing
    ret == first(bb.instructions) && return nothing
    prev = LLVM.prev(ret)
    prev === nothing && return nothing
    rv = isempty(LLVM.operands(ret)) ? nothing : LLVM.operands(ret)[1]
    if rv !== nothing
        rv == prev || return nothing
        if prev isa LLVM.BitCastInst
            rv = LLVM.operands(prev)[1]
            prev = LLVM.prev(prev)
            (prev === nothing || rv != prev) && return nothing
        end
    end
    prev isa LLVM.CallInst && LLVM.tailcall_kind(prev) == LLVM.TailCallKind.MustTail &&
        return prev
    return nothing
end

# the addresses of the task's `reset_ctx`, `ptls` and `eh` fields, after the GC stack's
# getter call or, for a GC stack argument, after the entry block's allocas
# (`computeResetCtxPtr`)
function compute_reset_ctx_ptr!(p::CancellationLowering)
    p.pgcstack === nothing && return
    builder = p.builder
    if p.pgcstack_inst !== nothing
        position_before!(builder, LLVM.next(p.pgcstack_inst); debug=true)
    else
        entry = first(p.f.blocks)
        pos = nothing
        for inst in entry.instructions
            inst isa LLVM.AllocaInst && continue
            pos = inst
            break
        end
        # an entry block of only allocas has no terminator: not valid IR
        if pos == first(entry.instructions)
            # `entry.begin()`, before the debug records of the first instruction; an
            # iterator advanced past allocas comes after the records
            position!(builder, LLVM.at_begin(entry))
        else
            position_before!(builder, pos; debug=true)
        end
    end
    rt = p.gc.layout
    T_int8 = LLVM.Int8Type()
    T_int64 = LLVM.Int64Type()
    task = gep!(builder, T_int8, p.pgcstack, [ConstantInt(T_int64, -rt.task_gcstack)],
                "current_task")
    p.reset_ctx_ptr = gep!(builder, T_int8, task, [ConstantInt(T_int64, rt.task_reset_ctx)],
                           "reset_ctx_ptr")
    p.ptls_field_ptr = gep!(builder, T_int8, task, [ConstantInt(T_int64, rt.task_ptls)],
                            "ptls_field_ptr")
    p.eh_field_ptr = gep!(builder, T_int8, task, [ConstantInt(T_int64, rt.task_eh)],
                          "eh_field_ptr")
    return
end

function emit_safepoint!(p::CancellationLowering)
    builder = p.builder
    ptls = load!(builder, LLVM.PointerType(), p.ptls_field_ptr, "ptls";
                 align=pointer_align(p.gc))
    # `emit_gc_safepoint`, without TBAA
    emit_gc_safepoint!(p.gc, ptls, nothing; final=false)
end

# `reset_ctx = NULL` (release), before the builder's position
function clear_region!(p::CancellationLowering)
    store = store!(p.builder, LLVM.null(LLVM.PointerType()), p.reset_ctx_ptr;
                   align=pointer_align(p.gc), volatile=true,
                   ordering=LLVM.AtomicOrdering.Release)
    set_reset_safe_md!(store)
    return store
end

# Lower a cancellation point: if this frame's region is still published, nothing to do;
# otherwise unpublish, safepoint, fill the buffer (its `sp` stamp, the task's GC stack
# and exception handler, `setjmp` on its `mctx`), and publish it. Returns the buffer
# and the publishing store.
function lower_point!(p::CancellationLowering, point::Instruction,
                      buffer::Union{Nothing,Instruction})
    builder = p.builder
    rt = p.gc.layout
    T_int8 = LLVM.Int8Type()
    T_int32 = LLVM.Int32Type()
    T_int64 = LLVM.Int64Type()
    T_ptr = LLVM.PointerType()
    align = pointer_align(p.gc)
    # every instruction created for the point gets its debug location
    loc = point.debug_location

    # one buffer for all points of the function: regions never nest within a frame
    if buffer === nothing
        position_before!(builder, first(first(p.f.blocks).instructions); debug=true)
        buffer = alloca!(builder, LLVM.ArrayType(T_int8, rt.reset_ctx_size), "cancel_ucontext";
                         align=rt.reset_ctx_align)
        # The task and setjmp use generic pointers, even with a separate stack address space.
        if LLVM.addrspace(buffer.value_type) != AS_GENERIC
            buffer = addrspacecast!(builder, buffer, T_ptr, "cancel_ucontext_generic")
        end
    end

    check_bb = LLVM.parent(point)
    cont_bb = split_block!(LLVM.before(point), "cancel_pt_cont")
    establish_bb = BasicBlock(LLVM.before(cont_bb), "cancel_establish")
    erase!(LLVM.terminator(check_bb))
    position!(builder, LLVM.at_end(check_bb))
    builder.debug_location = loc
    prev = load!(builder, T_ptr, p.reset_ctx_ptr, "reset_ctx_prev"; align, volatile=true,
                 ordering=LLVM.AtomicOrdering.Monotonic)
    set_reset_safe_md!(prev)
    live = icmp!(builder, LLVM.IntPredicate.EQ, prev, buffer, "region_live")
    br!(builder, live, cont_bb, establish_bb)

    position!(builder, LLVM.at_end(establish_bb))
    builder.debug_location = loc
    clear_region!(p)
    emit_signal_fence!(p.gc)
    emit_safepoint!(p)

    sp = ptrtoint!(builder, buffer, p.gc.T_size)
    stamp = store!(builder, sp, buffer; align=rt.reset_ctx_align, volatile=true,
                   ordering=LLVM.AtomicOrdering.Monotonic)
    set_reset_safe_md!(stamp)
    gcstack = load!(builder, T_ptr, p.pgcstack, "saved_gcstack"; align)
    gcstack_slot = gep!(builder, T_int8, buffer, [ConstantInt(T_int64, rt.reset_ctx_gcstack)],
                        "cancel_gcstack_slot")
    set_reset_safe_md!(store!(builder, gcstack, gcstack_slot; align, volatile=true))
    eh = load!(builder, T_ptr, p.eh_field_ptr, "saved_eh"; align)
    eh_slot = gep!(builder, T_int8, buffer, [ConstantInt(T_int64, rt.reset_ctx_eh)],
                   "cancel_eh_slot")
    set_reset_safe_md!(store!(builder, eh, eh_slot; align, volatile=true))

    mctx = gep!(builder, T_int8, buffer, [ConstantInt(T_int64, rt.reset_ctx_mctx)],
                "cancel_mctx")
    # like the code generator's setjmp: Windows' takes no savemask argument
    savemask = setjmp_savemask(nothing, p.mod.triple)
    setjmp_type = LLVM.FunctionType(T_int32, savemask ? LLVMType[T_ptr, T_int32] : LLVMType[T_ptr])
    setjmp_func = get_or_insert_function!(p.mod, rt.setjmp, setjmp_type)
    setjmp = call!(builder, setjmp_type, setjmp_func,
                   savemask ? Value[mctx, ConstantInt(T_int32, 0)] : Value[mctx])
    push!(LLVM.function_attributes(setjmp), EnumAttribute("returns_twice"))

    publish = store!(builder, buffer, p.reset_ctx_ptr; align, volatile=true,
                     ordering=LLVM.AtomicOrdering.Release)
    set_reset_safe_md!(publish)
    br!(builder, cont_bb)

    if !isempty(LLVM.uses(point))
        position_before!(builder, first(cont_bb.instructions); debug=true)
        phi = phi!(builder, T_int32)
        append!(LLVM.incoming(phi), [(ConstantInt(T_int32, 0), check_bb),
                                     (setjmp, establish_bb)])
        replace_uses!(point, phi)
    end
    erase!(point)
    return buffer, publish
end

# lower the TSan build's cancellation point: only a safepoint, the point is 0
function lower_point_without_region!(p::CancellationLowering, point::Instruction)
    position_before!(p.builder, point; debug=true)
    emit_safepoint!(p)
    replace_uses!(point, ConstantInt(LLVM.Int32Type(), 0))
    erase!(point)
end

# the cancellation points of a function, in the use-list order of the intrinsic (the
# order the C++ pass lowers them in, which determines the names of what it creates)
function cancellation_points(p::CancellationLowering)
    points = Instruction[]
    cp = p.fns.cancellation_point
    cp === nothing && return points
    for use in LLVM.uses(cp)
        user = LLVM.user(use)
        user isa Instruction && LLVM.parent(LLVM.parent(user)) == p.f || continue
        if user isa LLVM.CallInst && user.called_operand == cp
            push!(points, user)
        elseif user isa LLVM.InvokeInst && user.called_operand == cp
            # the C++ pass silently leaves these alone
            throw(CancellationLoweringError(LLVM.name(p.f),
                "`julia.cancellation_point` is invoked", string(user)))
        end
    end
    return points
end

is_publish_store(p::CancellationLowering, inst::Instruction) =
    inst isa LLVM.StoreInst && p.reset_ctx_ptr !== nothing &&
    LLVM.operands(inst)[2] == p.reset_ctx_ptr &&
    !(LLVM.operands(inst)[1] isa LLVM.PointerNull)

# whether a call may run with a region open without closing it first (only asked for
# calls that are untagged or runtime machinery)
function is_exempt_call(p::CancellationLowering, call::Instruction)
    callee = called_function(call)
    callee === nothing && return false
    fns = p.fns
    if startswith(LLVM.name(callee), "llvm.")
        id = intrinsic_id(callee)
        id !== nothing && id.name in RESET_SAFE_INTRINSICS && return true
    end
    name = LLVM.name(callee)
    name == "julia.safepoint" && return true
    is_fn(fns.pointer_from_objref, callee) && return true
    is_fn(fns.gc_loaded, callee) && return true
    # allocations and write barriers are annotated instead (FinalLowerGC lowers them to
    # entry points that close and reopen the region)
    is_fn(fns.alloc_obj, callee) && return true
    is_write_barrier(fns, callee) && return true
    # the name of setjmp last, so that its fact is read only for calls that are left
    return name == p.gc.layout.setjmp
end

# the instructions before which an open region must be closed
function unsafe_points(p::CancellationLowering, instrumented::Bool, may_open_at_entry)
    unsafe = Instruction[]
    f = p.f
    entry = first(f.blocks)
    sentinel = p.reset_ctx_ptr !== nothing ? p.reset_ctx_ptr : p.pgcstack_inst
    for bb in f.blocks
        past_setup = bb != entry || sentinel === nothing
        may_open = may_open_at_entry(bb)
        for inst in bb.instructions
            # in the entry block, skip the setup up to the address computation
            if !past_setup
                inst == sentinel && (past_setup = true)
                continue
            end
            if is_publish_store(p, inst)
                may_open = true
                continue
            end
            may_open || continue
            # a function that may only run in its caller's region has its own operations
            # covered by the contract that kept the region open; only its calls are not
            if inst isa LLVM.StoreInst || inst isa LLVM.AtomicCmpXchgInst ||
               inst isa LLVM.AtomicRMWInst
                instrumented && !has_reset_safe_md(inst) && push!(unsafe, inst)
            elseif inst isa LLVM.LoadInst
                instrumented && LLVM.volatile(inst) && !has_reset_safe_md(inst) &&
                    push!(unsafe, inst)
            elseif inst isa LLVM.CallInst
                callee = called_function(inst)
                id = callee === nothing ? nothing : intrinsic_id(callee)
                id !== nothing && (LLVM.name(callee) in DBG_INFO_INTRINSICS ||
                                   id == Intrinsic("llvm.lifetime.start") ||
                                   id == Intrinsic("llvm.lifetime.end")) &&
                    continue
                if !has_reset_safe_md(inst) || is_implicit_runtime_call(p, inst)
                    is_exempt_call(p, inst) || push!(unsafe, inst)
                end
            end
        end
    end
    return unsafe
end

function cancellation_lowering!(f::LLVM.Function, am, opts::PassOptions)
    dialect = opts.dialect
    dialect.has_cancellation_lowering || return PreservedAnalyses(AllAnalyses)
    mod = LLVM.parent(f)
    @dispose builder=IRBuilder() begin
        fns = GCFunctions(mod, dialect)
        gc = GCCodegen(dialect, mod, builder, runtime_layout(opts, mod))
        p = CancellationLowering(opts, mod, f, fns, builder, gc, nothing, nothing, nothing,
                                 nothing, nothing)
        p.pgcstack = get_pgcstack(dialect, f, fns.pgcstack_getter, fns.adoptthread)
        p.pgcstack isa Instruction && (p.pgcstack_inst = p.pgcstack)

        points = cancellation_points(p)
        instrumented = !isempty(points)
        # a function without points of its own only needs instrumentation when it may run
        # inside its caller's region
        fn_attrs = LLVM.function_attributes(f)
        inherits_region = haskey(fn_attrs, "julia.ipo_reset_safe")
        !instrumented && (p.pgcstack === nothing || !inherits_region) &&
            return PreservedAnalyses(AllAnalyses)
        # Under TSan, whose instrumentation runs later and would turn the pass's own
        # bookkeeping into runtime calls a reset could abandon, no region is published:
        # a point is just a safepoint.
        no_publish = haskey(fn_attrs, :sanitize_thread)
        no_publish && !instrumented && return PreservedAnalyses(AllAnalyses)
        # the C++ pass emits instructions with null operands here
        if instrumented && p.pgcstack === nothing
            throw(CancellationLoweringError(LLVM.name(f),
                "cancellation point in a function without a GC stack", string(first(points))))
        end

        changed = false
        cfg_changed = false
        instrumented && compute_reset_ctx_ptr!(p)

        publishes = Instruction[]
        buffer = nothing
        for point in points
            changed = true
            if no_publish
                lower_point_without_region!(p, point)
                continue
            end
            buffer, publish = lower_point!(p, point, buffer)
            push!(publishes, publish)
            cfg_changed = true
        end
        no_publish && return cancellation_preserved(changed, cfg_changed)

        # a region can only be open where a publication reaches, or anywhere in a function
        # that may inherit one from its caller
        may_be_open = Set{BasicBlock}()
        if !inherits_region
            worklist = BasicBlock[]
            for publish in publishes
                append!(worklist, LLVM.successors(LLVM.terminator(LLVM.parent(publish))))
            end
            while !isempty(worklist)
                bb = pop!(worklist)
                if !(bb in may_be_open)
                    push!(may_be_open, bb)
                    append!(worklist, LLVM.successors(LLVM.terminator(bb)))
                end
            end
        end
        may_open_at_entry(bb) = inherits_region || bb in may_be_open

        unsafe = unsafe_points(p, instrumented, may_open_at_entry)
        # without points of its own, the addresses are only computed when needed
        !isempty(unsafe) && p.reset_ctx_ptr === nothing && compute_reset_ctx_ptr!(p)

        # close the region before each unsafe point; the signal fence keeps later passes
        # from moving the operation above the clear
        if p.reset_ctx_ptr !== nothing
            for inst in unsafe
                changed = true
                position_before!(builder, inst; debug=true)
                clear_region!(p)
                emit_signal_fence!(p.gc)
            end
        end

        # and before returning from a function that publishes its own buffer; before a
        # `musttail` call, which must stay next to the return, unconditionally
        if instrumented && p.reset_ctx_ptr !== nothing
            for bb in f.blocks
                ret = LLVM.terminator(bb)
                ret isa LLVM.RetInst || continue
                may_open = may_open_at_entry(bb) ||
                           any(inst -> is_publish_store(p, inst), bb.instructions)
                may_open || continue
                musttail = terminating_musttail_call(bb)
                position_before!(builder, musttail === nothing ? ret : musttail; debug=true)
                clear_region!(p)
            end
        end

        # mark the allocations and write barriers that may run with a region open
        for bb in f.blocks
            region_open = may_open_at_entry(bb)
            for inst in bb.instructions
                if inst isa LLVM.StoreInst
                    if p.reset_ctx_ptr !== nothing && LLVM.operands(inst)[2] == p.reset_ctx_ptr
                        region_open = !(LLVM.operands(inst)[1] isa LLVM.PointerNull)
                    end
                elseif inst isa LLVM.CallInst
                    callee = called_function(inst)
                    callee === nothing && continue
                    if region_open &&
                       (is_fn(fns.alloc_obj, callee) || is_write_barrier(fns, callee))
                        inst.metadata[RESET_REGION_MD] = MDNode(Metadata[])
                        changed = true
                    end
                end
            end
        end
        return cancellation_preserved(changed, cfg_changed)
    end
end

# The C++ pass reports the CFG as preserved also when it split blocks, which leaves a
# cached dominator tree without the new blocks; LateLowerGCFrame then took a
# `GC.@preserve`d object for dead across a call after a cancellation point.
cancellation_preserved(changed::Bool, cfg_changed::Bool) =
    !changed ? PreservedAnalyses(AllAnalyses) :
    cfg_changed ? PreservedAnalyses() : PreservedAnalyses(CFGAnalyses)

const CANCELLATION_LOWERING =
    define_pass("jl-cancellation-lowering", :function, cancellation_lowering!; required=true,
                options=runtime_options(CANCELLATION_RUNTIME_FACTS...),
                cpp_name="CancellationLowering")

"""
    JuliaIR.CancellationLoweringPass(; task_gcstack=nothing, task_ptls=nothing,
                                     task_eh=nothing, task_reset_ctx=nothing,
                                     tls_safepoint=nothing, reset_ctx_size=nothing,
                                     reset_ctx_align=nothing, reset_ctx_gcstack=nothing,
                                     reset_ctx_eh=nothing, reset_ctx_mctx=nothing,
                                     setjmp=nothing)

Lower the cancellation points (`julia.cancellation_point()` calls, from
`Base.@cancel_check`) that Julia 1.14 and later emit into reset regions
(`jl-cancellation-lowering` in a pipeline, `CancellationLowering` in Julia's pipeline):
at a point, the function publishes a stack buffer in its task, filled by `setjmp`, to
which the runtime can jump back to deliver a cancellation; the pass closes the region
again before every operation such a jump could tear, and before returning. See the
documentation for the details.

Julia releases up to 1.13 don't have cancellation points, so for their IR the pass does
nothing. Like Julia's pass, it also runs on `optnone` functions.

The lowering needs the layout of the runtime's task and reset context and the name of
its `setjmp`, which are taken from the running Julia (see
[`JuliaIR.runtime_layout`](@ref)) only for functions that need them; the keyword
arguments give these facts explicitly.
"""
CancellationLoweringPass(; kwargs...) = custom_pass(CANCELLATION_LOWERING; kwargs...)
