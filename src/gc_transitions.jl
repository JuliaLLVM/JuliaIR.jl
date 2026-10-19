# Code that reaches the current task's thread-local state from its GC stack, polls
# safepoints and switches the GC state, as emitted by the helpers of Julia's
# `llvm-codegen-shared.h` (`get_current_task_from_pgcstack`, `get_current_ptls_from_task`,
# `get_current_signal_page_from_ptls`, `emit_gc_safepoint`, `emit_gc_state_set`).
# LateLowerGCFrame has its own copies of some of these on its pass state; they are
# expected to move to a shared file of GC helpers.

# What the helpers need: the builder (positioned by the caller, with the debug location
# the C++ builder would have), the dialect, the runtime facts, the module's layout, and
# Julia's TBAA tags.
struct GCCodegen
    builder::IRBuilder
    dialect::Dialect
    layout::Any         # RuntimeFacts, or anything with the same properties
    dl::DataLayout
    T_size::LLVMType
    tbaa::TBAATags
end

GCCodegen(builder::IRBuilder, dialect::Dialect, layout, dl::DataLayout, T_size::LLVMType) =
    GCCodegen(builder, dialect, layout, dl, T_size, TBAATags())

gc_pointer_size(g::GCCodegen) = storage_size(g.dl, LLVM.PointerType(AS_GENERIC))
gc_pointer_align(g::GCCodegen) = abi_alignment(g.dl, LLVM.PointerType(AS_GENERIC))

# the current task, from its GC stack (`get_current_task_from_pgcstack`)
function current_task_from_pgcstack!(g::GCCodegen, @nospecialize(pgcstack::Value))
    offset = g.layout.task_gcstack
    if g.dialect.gc_ptls_gep === :pointer
        # (the C++ negates the quotient as an unsigned number, which the constant of the
        # pointer-sized type truncates to the same value)
        return inbounds_gep!(g.builder, LLVM.PointerType(AS_GENERIC), pgcstack,
                             [ConstantInt(g.T_size, -(offset ÷ gc_pointer_size(g)))],
                             "current_task")
    else
        return inbounds_gep!(g.builder, LLVM.Int8Type(), pgcstack,
                             [ConstantInt(LLVM.Int32Type(), -offset)], "current_task")
    end
end

# the thread-local state of a task (`get_current_ptls_from_task`)
function current_ptls_from_task!(g::GCCodegen, @nospecialize(task::Value), tbaa::MDNode)
    offset = g.layout.task_ptls
    T_ptr = LLVM.PointerType(AS_GENERIC)
    pptls = if g.dialect.gc_ptls_gep === :pointer
        inbounds_gep!(g.builder, T_ptr, task,
                      [ConstantInt(g.T_size, offset ÷ gc_pointer_size(g))], "ptls_field")
    else
        inbounds_gep!(g.builder, LLVM.Int8Type(), task,
                      [ConstantInt(LLVM.Int32Type(), offset)], "ptls_field")
    end
    ptls_load = load!(g.builder, T_ptr, pptls, "ptls_load"; align=gc_pointer_align(g))
    tbaa_decorate!(tbaa, ptls_load, g.tbaa.constant)
    return ptls_load
end

# the safepoint page of a thread (`get_current_signal_page_from_ptls`)
function signal_page_from_ptls!(g::GCCodegen, @nospecialize(ptls::Value), tbaa::MDNode)
    T_ptr = LLVM.PointerType(AS_GENERIC)
    offset = g.layout.tls_safepoint
    style = g.dialect.gc_safepoint_load
    psafepoint = if g.dialect.gc_ptls_gep === :pointer
        inbounds_gep!(g.builder, T_ptr, ptls,
                      [ConstantInt(g.T_size, offset ÷ gc_pointer_size(g))])
    else
        inbounds_gep!(g.builder, LLVM.Int8Type(), ptls,
                      [ConstantInt(LLVM.Int32Type(), offset)],
                      style === :monotonic_named ? "safepoint_addr" : "")
    end
    load = load!(g.builder, T_ptr, psafepoint, "safepoint"; align=gc_pointer_align(g),
                 ordering=style === :plain ? LLVM.API.LLVMAtomicOrderingNotAtomic :
                                             LLVM.API.LLVMAtomicOrderingMonotonic)
    tbaa_decorate!(tbaa, load, g.tbaa.constant)
    return load
end

emit_signal_fence!(g::GCCodegen) =
    fence!(g.builder, LLVM.API.LLVMAtomicOrderingSequentiallyConsistent; scope="singlethread")

# a final safepoint (`emit_gc_safepoint(..., final=true)`): a volatile load from the
# safepoint page, which faults when the GC wants this thread to stop
function emit_gc_final_safepoint!(g::GCCodegen, @nospecialize(ptls::Value), tbaa::MDNode)
    signal_page = signal_page_from_ptls!(g, ptls, tbaa)
    emit_signal_fence!(g)
    load!(g.builder, g.T_size, signal_page; volatile=true)
    emit_signal_fence!(g)
    return
end

# the address of the thread's GC state (a byte)
gc_state_address!(g::GCCodegen, @nospecialize(ptls::Value)) =
    inbounds_gep!(g.builder, LLVM.Int8Type(), ptls,
                  [ConstantInt(LLVM.Int32Type(), g.layout.tls_gc_state)], "gc_state")

# Julia's C++ stores the byte with the alignment of a pointer, which only holds where the
# offset is a multiple of it.
const GC_STATE_ALIGN = 1

# Set the thread's GC state to `state`, and poll a final safepoint when the dialect's
# condition holds (`emit_gc_state_set(..., final=true)`). The current state is loaded
# unless `old_state` is given. The safepoint goes in two new blocks at the end of the
# function, and the builder is left at the end of the second. Returns the old state.
function emit_gc_state_set!(g::GCCodegen, @nospecialize(ptls::Value), state::Value,
                            old_state::Union{Nothing,Value})
    builder = g.builder
    T_int8 = LLVM.Int8Type()
    condition = g.dialect.gc_state_condition
    gc_state = gc_state_address!(g, ptls)
    if old_state === nothing
        old_state = load!(builder, T_int8, gc_state, condition === :ne ? "old_state" : "";
                          ordering=LLVM.API.LLVMAtomicOrderingMonotonic)
    end
    store!(builder, state, gc_state; align=GC_STATE_ALIGN,
           ordering=LLVM.API.LLVMAtomicOrderingRelease)
    if condition === :ne
        old_state isa ConstantInt && state isa ConstantInt &&
            convert(UInt64, old_state) == convert(UInt64, state) && return old_state
    else
        old_state isa ConstantInt && iszero(convert(UInt64, old_state)) && return old_state
        state isa ConstantInt && !iszero(convert(UInt64, state)) && return old_state
    end
    f = LLVM.parent(builder.insert_block)
    pass_bb = BasicBlock(f, "safepoint")
    exit_bb = BasicBlock(f, "after_safepoint")
    zero8 = ConstantInt(T_int8, 0)
    cond = if condition === :and
        and!(builder, icmp!(builder, LLVM.API.LLVMIntNE, old_state, zero8),
             icmp!(builder, LLVM.API.LLVMIntEQ, state, zero8))
    elseif condition === :or
        or!(builder, icmp!(builder, LLVM.API.LLVMIntEQ, old_state, zero8),
            icmp!(builder, LLVM.API.LLVMIntEQ, state, zero8))
    else
        icmp!(builder, LLVM.API.LLVMIntNE, old_state, state, "is_new_state")
    end
    br!(builder, cond, pass_bb, exit_bb)
    position!(builder, LLVM.at_end(pass_bb))
    emit_gc_final_safepoint!(g, ptls, g.tbaa.constant)
    br!(builder, exit_bb)
    position!(builder, LLVM.at_end(exit_bb))
    return old_state
end

# enter the GC-unsafe state (`emit_gc_unsafe_enter(..., final=true)`)
emit_gc_unsafe_enter!(g::GCCodegen, @nospecialize(ptls::Value)) =
    emit_gc_state_set!(g, ptls, ConstantInt(LLVM.Int8Type(), 0), nothing)

# leave the GC-unsafe state for `state` (`emit_gc_unsafe_leave(..., final=true)`)
emit_gc_unsafe_leave!(g::GCCodegen, @nospecialize(ptls::Value), state::Value) =
    emit_gc_state_set!(g, ptls, state, ConstantInt(LLVM.Int8Type(), 0))
