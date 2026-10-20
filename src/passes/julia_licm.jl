# JuliaLICM: move what LLVM's LICM can't out of loops. Port of Julia's
# `src/llvm-julia-licm.cpp`, a loop pass in every supported version (1.14's, for the IR
# of every version; the differences are below and in docs/src/julia_licm.md).
#
# - `llvm.julia.gc_preserve_begin` is hoisted to the preheader when its operands are
#   defined before the loop; a `gc_preserve_end` of a token defined before the loop is
#   sunk to the exits of the loop (cloned for every further exit, erased if the loop has
#   none). Extending a preserve region is always legal.
# - Write barriers are hoisted to the preheader once their parent and children are (made)
#   loop invariant: a store in the loop keeps the stored object alive across safepoints,
#   so one barrier before the loop suffices. From Julia 1.14 on, a field barrier whose
#   slots vary becomes an object barrier.
# - `julia.gc_alloc_obj` calls whose object doesn't escape the loop (by the escape analysis
#   that AllocOpt uses, ignoring uses after the loop) are hoisted to the preheader, where
#   the object is zeroed, so that every iteration reuses it.

const LICM_REMARKS = "julia-licm"

# The state of one invocation of the pass on a loop.
mutable struct JuliaLICM
    const loop::Loop
    const ar::LoopAnalysisResults
    const dialect::Dialect
    const mod::LLVM.Module
    const dl::DataLayout
    fns::JuliaFunctions
    const li::LoopInfo
    const dt::DomTree
    const se::ScalarEvolution
    const mssa::Union{Nothing,MemorySSA}
    const updater::Union{Nothing,MemorySSAUpdater}
    const builder::IRBuilder
    const preheader::BasicBlock
    const header::BasicBlock
    # the exit blocks of the loop, collected when first needed
    exit_blocks::Union{Nothing,Vector{BasicBlock}}
    changed::Bool
    const info::AllocUseInfo
end

block_properly_dominates(p::JuliaLICM, a::BasicBlock, b::BasicBlock) =
    a != b && dominates(p.dt, a, b)

# `eraseInstruction`
function erase_inst!(p::JuliaLICM, inst::Instruction)
    p.updater === nothing || remove_access!(p.updater, inst)
    erase!(inst)
end

# `moveInstructionBefore`: move `inst` before `dest`, and its memory access to `place` in
# the block of `dest`. Like C++'s `moveBefore`, the debug records attached to `inst` stay,
# and `inst` goes after those attached to `dest`.
function move_inst_before!(p::JuliaLICM, inst::Instruction, dest::Instruction;
                           place::Symbol=:before_terminator)
    move!(inst, LLVM.before(dest))
    if p.updater !== nothing
        access = memory_access(p.mssa, inst)
        access === nothing || move_to_place!(p.updater, access, LLVM.parent(dest), place)
    end
    forget!(p.se, inst)
    return
end

# `createNewInstruction`: give `new` a memory access if `ref`, which it was created from,
# has one
function create_access!(p::JuliaLICM, new::Instruction, ref::Instruction;
                        place::Symbol=:beginning)
    p.updater === nothing && return
    memory_access(p.mssa, ref) === nothing && return
    access = create_access_in_block!(p.updater, new, LLVM.parent(new), place)
    if access isa MemoryDef
        insert_def!(p.updater, access; rename=true)
    elseif access isa MemoryUse
        insert_use!(p.updater, access; rename=true)
    end
    return
end

# whether an instruction that isn't loop invariant may be hoisted once its operands are
hoistable(inst::Instruction) =
    is_safe_to_speculatively_execute(inst) && !may_read_from_memory(inst) && !(inst isa EHPad)

# `makeLoopInvariant`, a copy of LLVM's `Loop::makeLoopInvariant` that also updates
# MemorySSA and SCEV: whether `v` is loop invariant, after hoisting it and the operands it
# depends on to the preheader if that is safe. Operands hoisted before a failure stay
# hoisted, like in C++.
function make_loop_invariant!(p::JuliaLICM, @nospecialize(v::Value))
    v isa Instruction || return true
    is_loop_invariant(p.loop, v) && return true
    hoistable(v) || return false
    for op in v.operands
        make_loop_invariant!(p, op) || return false
    end
    move_inst_before!(p, v, LLVM.terminator(p.preheader))
    # metadata like `!range` may depend on a condition in the loop
    drop_unknown_metadata!(v)
    p.changed = true
    return true
end

# The instruction at the first insertion point of `bb`, or `nothing` if there is none (a
# block with only a `catchswitch`).
function exit_insertion_inst(bb::BasicBlock)
    pos = LLVM.after_phis(bb)
    pos === nothing && return nothing
    return Instruction(pos.anchor)
end

# Where to sink the ends of a token defined in `begin_loop` (`nothing` if it is defined
# outside every loop): the start of each exit block of the loop that is in `begin_loop`.
# An end isn't sunk out of the loop that defines its token, since LCSSA can't add phis for
# tokens, so a later loop transformation (e.g., unswitching) could break dominance; this
# only extends the preserve region (Julia 1.13 and later, adopted for every version). Exit
# blocks without an insertion point are skipped as well.
function exit_points(p::JuliaLICM, begin_loop::Union{Nothing,Loop})
    if p.exit_blocks === nothing
        p.exit_blocks = collect(p.loop.exit_blocks)
    end
    points = Instruction[]
    for bb in p.exit_blocks
        begin_loop === nothing || bb in begin_loop || continue
        point = exit_insertion_inst(bb)
        point === nothing || push!(points, point)
    end
    return points
end

function hoist_preserve_begin!(p::JuliaLICM, call::Instruction)
    for arg in call.arguments
        arg isa Instruction || continue
        block_properly_dominates(p, LLVM.parent(arg), p.header) || return
    end
    move_inst_before!(p, call, LLVM.terminator(p.preheader))
    remark!(p.ar, :passed, LICM_REMARKS, "Hoisted", call) do
        "hoisting preserve begin ", "PreserveBegin" => call
    end
    p.changed = true
    return
end

function sink_preserve_end!(p::JuliaLICM, call::Instruction)
    args = call.arguments
    isempty(args) && return
    token = first(args)
    # the C++ pass crashes on an end of a token that isn't an instruction (`token none`);
    # leaving the end in place is always legal
    token isa Instruction || return
    begin_block = LLVM.parent(token)
    block_properly_dominates(p, begin_block, p.header) || return
    p.changed = true
    points = exit_points(p, p.li[begin_block])
    if isempty(points)
        erase_inst!(p, call)
        return
    end
    move_inst_before!(p, call, points[1]; place=:beginning)
    remark!(p.ar, :passed, LICM_REMARKS, "Sunk", call) do
        "sinking preserve end ", "PreserveEnd" => call
    end
    for point in points[2:end]
        # like C++'s `CallInst::Create(call, {}, point)`: without bundles and metadata
        clone = clone_call!(p.builder, call; pos=LLVM.before(point))
        create_access!(p, clone, call)
        remark!(p.ar, :passed, LICM_REMARKS, "Sunk", call) do
            "cloning and sinking preserve end", "PreserveEnd" => call
        end
    end
    return
end

is_snapshot_barrier(d::Dialect) =
    d.barrier_flavour === :object_field && d.gc_barrier in (:snapshot, :snapshot_field_precise)
is_field_precise_barrier(d::Dialect) =
    d.barrier_flavour === :object_field && d.gc_barrier in (:field_precise, :snapshot_field_precise)

# the slots of a field barrier
field_barrier_slots(call::Instruction) =
    collect(call.arguments)[FIELD_WB_SLOT_ARG:2:end]

# Replace a field barrier by an object barrier with the same parent and children in the
# preheader (`hoistAsObjectBarrier`). Throws, leaving the barrier as it is, if the module
# declares the object barrier with another type (the C++ pass emits an invalid call).
function hoist_as_object_barrier!(p::JuliaLICM, call::Instruction)
    f = get_or_declare_object_write_barrier!(p.mod)
    is_write_barrier(p.fns, f) || (p.fns = JuliaFunctions(p.mod, p.dialect))
    args = Value[first(call.arguments); write_barrier_children(p.fns, call)]
    builder = p.builder
    position!(builder, LLVM.before(LLVM.terminator(p.preheader)))
    builder.debug_location = call.debug_location
    replacement = call!(builder, LLVM.function_type(f), f, args)
    # iterated rather than indexed: indexing returns a one-operand node like `!{i64 1}` as
    # its operand (`MetadataAsValue` canonicalizes it), which can't be attached
    region = MDKind("julia.reset_region")
    for (kind, md) in call.metadata
        kind == region && (replacement.metadata[kind] = md)
    end
    create_access!(p, replacement, call; place=:before_terminator)
    erase_inst!(p, call)
    return replacement
end

function hoist_write_barrier!(p::JuliaLICM, call::Instruction)
    # a snapshot barrier must see every store, so it can't be hoisted across safepoints
    is_snapshot_barrier(p.dialect) && return
    make_loop_invariant!(p, first(call.arguments)) || return
    all(child -> make_loop_invariant!(p, child), write_barrier_children(p.fns, call)) ||
        return
    # keeping a field barrier needs its slots too; every slot is tried
    slots_invariant = true
    if is_field_write_barrier(p.fns, call.called_operand)
        for slot in field_barrier_slots(call)
            slots_invariant &= make_loop_invariant!(p, slot)
        end
    end
    if slots_invariant
        move_inst_before!(p, call, LLVM.terminator(p.preheader))
    elseif is_field_precise_barrier(p.dialect)
        # demoting it to an object barrier is assumed too imprecise to be worth it
        return
    else
        call = hoist_as_object_barrier!(p, call)
    end
    p.changed = true
    remark!(p.ar, :passed, LICM_REMARKS, "Hoist", call) do
        "hoisting write barrier ", "GC Write Barrier" => call
    end
    return
end

function hoist_allocation!(p::JuliaLICM, call::Instruction)
    for arg in call.arguments
        make_loop_invariant!(p, arg) || return
    end
    info = escape_analysis!(p.info, call, p.fns, p.dl; valid_blocks=p.loop, remarks=p.ar)
    remark!(p.ar, :analysis, LICM_REMARKS, "EscapeAnalysis", call) do
        "escape analysis for ", "GC Allocation" => call, "\n",
        "UseInfo" => sprint(dump_use_info, info)
    end
    reason = info.escaped ? " because it may escape" :
             info.addrescaped ? " because its address may escape" :
             # stores of references would need write barriers once the object is older
             # than what is stored in it
             info.refstore ? " because it may have an object stored to it" : nothing
    if reason !== nothing
        remark!(p.ar, :missed, LICM_REMARKS, "Escape", call) do
            "not hoisting gc allocation ", "GC Allocation" => call, reason
        end
        return
    end
    remark!(p.ar, :passed, LICM_REMARKS, "Hoist", call) do
        "hoisting gc allocation ", "GC Allocation" => call
    end
    term = LLVM.terminator(p.preheader)
    move_inst_before!(p, call, term)
    # the object is reused by every iteration: clear it, assuming that the GC allocates
    # memory aligned to pointers
    builder = p.builder
    position!(builder, LLVM.before(term))
    builder.debug_location = call.debug_location
    clear = memset!(builder, call, ConstantInt(Int8(0)), call.arguments[2],
                    LLVM.pointersize(p.dl, 0))
    if p.updater !== nothing
        def = create_access_in_block!(p.updater, clear, p.preheader, :before_terminator)
        def isa MemoryDef && insert_def!(p.updater, def; rename=true)
    end
    p.changed = true
    return
end

function run_julia_licm!(p::JuliaLICM)
    fns = p.fns
    try
        # hoist the begins of a loop before sinking its ends
        for bb in reverse_postorder(p.loop, p.li), inst in bb.instructions
            inst isa CallInst || continue
            callee = inst.called_operand
            if callee == fns.gc_preserve_begin
                hoist_preserve_begin!(p, inst)
            elseif callee == fns.gc_preserve_end
                sink_preserve_end!(p, inst)
            elseif is_write_barrier(p.fns, callee)
                hoist_write_barrier!(p, inst)
            elseif callee == fns.alloc_obj
                hoist_allocation!(p, inst)
            end
        end
    finally
        # also when a demotion throws, as the hoists before it stay
        p.changed && forget_loop_dispositions!(p.se)
    end
    return p.changed
end

function julia_licm!(loop::Loop, ar::LoopAnalysisResults, opts::PassOptions)
    preheader = loop.preheader
    preheader === nothing && return PreservedAnalyses(AllAnalyses)
    header = loop.header
    mod = LLVM.parent(LLVM.parent(header))
    dialect = opts.dialect
    fns = JuliaFunctions(mod, dialect)
    # an end needs a begin, so modules with only ends are skipped
    fns.gc_preserve_begin === nothing && isempty(fns.write_barriers) &&
        fns.alloc_obj === nothing && return PreservedAnalyses(AllAnalyses)

    mssa = get(ar, MemorySSA, nothing)
    changed = @dispose builder=IRBuilder() begin
        run!(updater) = run_julia_licm!(JuliaLICM(
            loop, ar, dialect, mod, mod.datalayout, fns, ar[LoopInfo], ar[DomTree],
            ar[ScalarEvolution], mssa, updater, builder, preheader, header, nothing, false,
            AllocUseInfo()))
        mssa === nothing ? run!(nothing) : MemorySSAUpdater(run!, mssa)
    end
    changed || return PreservedAnalyses(AllAnalyses)
    return PreservedAnalyses(LoopAnalyses, CFGAnalyses, MemorySSA)
end

const JULIA_LICM = define_pass("jl-licm", :loop, julia_licm!; required=false,
                               cpp_name="JuliaLICM")

"""
    JuliaIR.JuliaLICMPass(; gc_barrier=:stock)

Move what LLVM's LICM can't out of loops (`jl-licm` in a pipeline; a loop pass, for
`loop(...)` and `loop-mssa(...)` pipelines, which it keeps MemorySSA valid in): the
`llvm.julia.gc_preserve_begin` calls whose operands are defined before the loop (with
their `llvm.julia.gc_preserve_end` calls sunk to the exits of the loop), write barriers
whose operands are or can be made loop invariant, and the GC allocations that don't escape
the loop, which are then cleared before it. For the IR of Julia 1.14 and later, a field
write barrier whose slots vary in the loop is hoisted as an object barrier. The
`gc_barrier` option is the GC's barrier configuration from Julia 1.14 on: no barrier is
hoisted with snapshot barriers, and no field barrier demoted with field-precise ones. Like
Julia's C++ pass, it is skipped on `optnone` functions.
"""
JuliaLICMPass(; kwargs...) = custom_pass(JULIA_LICM; kwargs...)
