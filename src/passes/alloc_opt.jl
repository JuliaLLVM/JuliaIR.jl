# AllocOpt: remove Julia GC allocations (`julia.gc_alloc_obj`) whose object does not
# escape, or move them to the stack, whole or split into their fields. Port of Julia's
# `src/llvm-alloc-opt.cpp` (master), with the representation choices of older Julia
# versions where their tests check them (see `alloc_layout` and `alloc_initialization`
# in `Dialect`).

# the alignment of Julia's small GC allocations (`JL_SMALL_BYTE_ALIGNMENT`)
const JL_SMALL_BYTE_ALIGNMENT = 16

mutable struct AllocOpt
    const f::LLVM.Function
    const am::FunctionAnalysisManager
    const dialect::Dialect
    const fns::JuliaFunctions
    const dl::DataLayout
    const layout::String  # the data layout, as a string
    const builder::IRBuilder
    const lifetime_size::Bool
    const lifetime_start::LLVM.Function
    const lifetime_end::LLVM.Function
    const T_prjlvalue::LLVMType
    const T_pjlvalue::LLVMType

    domtree::Union{Nothing,DomTree}
    reachable::Union{Nothing,Set{BasicBlock}}

    # allocations to optimize, with their size; insertion-ordered, without duplicates
    worklist::Vector{Tuple{Instruction,Int}}
    inworklist::Set{Instruction}
    # allocations (and typeof calls) to erase at the end
    removed::Vector{Instruction}
    info::AllocUseInfo
    first_safepoint::Dict{BasicBlock,Union{Nothing,Instruction}}
end

function domtree(opt::AllocOpt)
    opt.domtree === nothing && (opt.domtree = opt.am[DomTree])
    return opt.domtree
end

function reachable_blocks(opt::AllocOpt)
    if opt.reachable === nothing
        seen = Set{BasicBlock}()
        stack = [first(opt.f.blocks)]
        while !isempty(stack)
            bb = pop!(stack)
            bb in seen && continue
            push!(seen, bb)
            append!(stack, bb.successors)
        end
        opt.reachable = seen
    end
    return opt.reachable
end

# whether the definition `def` dominates every instruction in `bb` (C++'s
# `DT.dominates(Instruction*, BasicBlock*)`; true for unreachable blocks)
inst_dominates_block(opt::AllocOpt, def::Instruction, bb::BasicBlock) =
    dominates(domtree(opt), def, first(bb.instructions))

# whether block `a` dominates block `b`, both reachable
block_dominates(opt::AllocOpt, a::BasicBlock, b::BasicBlock) =
    a == b || dominates(domtree(opt), first(a.instructions), first(b.instructions))

# remarks, like the C++ pass emits them (without printing the IR)
remark(opt::AllocOpt, kind, name, inst, message) =
    remark!(opt.am, kind, "alloc-opt", name, inst, message)

# position the builder like C++'s `IRBuilder<>(inst)`, which also takes its debug location
function position_at!(opt::AllocOpt, inst::Instruction)
    position!(opt.builder, LLVM.before(inst))
    opt.builder.debug_location = inst.debug_location
end

# erase an instruction, keeping the cache of safepoints valid
function erase_inst!(opt::AllocOpt, inst::Instruction)
    bb = inst.parent
    if bb !== nothing && get(opt.first_safepoint, bb, nothing) == inst
        delete!(opt.first_safepoint, bb)
    end
    erase!(inst)
end

function replace_uses_of!(user::Instruction, from::Value, to::Value)
    ops = user.operands
    for i in eachindex(ops)
        ops[i] == from && (ops[i] = to)
    end
end

## data layout queries

function is_legal_integer(layout::String, bits::Integer)
    for spec in split(layout, '-')
        # the native integer widths (`n8:16:32:64`), not the non-integral address
        # spaces (`ni:10:11`)
        occursin(r"^n\d", spec) || continue
        return any(w -> parse(Int, w) == bits, split(spec[2:end], ':'))
    end
    return false
end

## allocations

# the size of an allocation, or -1 if `inst` is not one of a known size
function gc_alloc_size(opt::AllocOpt, inst::Instruction)
    inst isa CallInst || return -1
    inst.called_operand == opt.fns.alloc_obj || return -1
    sz = inst.arguments[2]
    sz isa ConstantInt || return -1
    n = convert(UInt64, sz)
    # IntegerType::MAX_INT_BITS / 8
    n < (1 << 23) ÷ 8 && n < typemax(Int32) || return -1
    return Int(n)
end

function push_instruction!(opt::AllocOpt, inst::Instruction)
    sz = gc_alloc_size(opt, inst)
    if sz != -1 && !(inst in opt.inworklist)
        push!(opt.worklist, (inst, sz))
        push!(opt.inworklist, inst)
    end
end

# the alignment of an allocation's result, if it has one
function ret_align(call::Instruction)
    attrs = call.return_attributes
    haskey(attrs, :align) && return Int(attrs[:align].value)
    callee = call.called_function
    if callee !== nothing && haskey(callee.return_attributes, :align)
        return Int(callee.return_attributes[:align].value)
    end
    return nothing
end

# the alignment of the stack memory that replaces an allocation of `sz` bytes
function stack_alignment(opt::AllocOpt, alloc::Instruction, sz::Integer)
    if opt.dialect.alloc_layout === :legacy
        # Julia 1.10 and 1.11: the power of two above the size (LLVM's `NextPowerOf2`),
        # up to 16, but not less than the uses need
        align = sz > 1 ? min(JL_SMALL_BYTE_ALIGNMENT, nextpow(2, sz + 1)) : 1
        for field in opt.info.fields, access in field.accesses
            access_align = access.inst.alignment
            access_align === nothing || (align = max(align, access_align))
        end
        return align
    else
        return max(something(ret_align(alloc), 1), JL_SMALL_BYTE_ALIGNMENT)
    end
end

# the type of stack memory for `sz` bytes without references
function stack_type(opt::AllocOpt, sz::Integer, align::Integer)
    ctx = context(opt.f)
    if opt.dialect.alloc_layout === :legacy
        return is_legal_integer(opt.layout, sz * 8) ? LLVM.IntType(sz * 8) :
               LLVM.ArrayType(LLVM.Int8Type(), sz)
    else
        # alignment-sized chunks, so that SROA splits the alloca into aligned pieces; at
        # most 64 bits, which every back-end supports
        elsize = min(align, 8)
        n = cld(sz, elsize)
        return n == 1 ? LLVM.IntType(elsize * 8) : LLVM.ArrayType(LLVM.IntType(elsize * 8), n)
    end
end

## the optimizer

function check_inst!(opt::AllocOpt, alloc::Instruction)
    escape_analysis!(opt.info, alloc, opt.fns, opt.dl;
                     remark=(name, inst, msg) -> remark(opt, :missed, name, inst, msg))
end

function optimize_all!(opt::AllocOpt)
    info = opt.info
    while !isempty(opt.worklist)
        orig, sz = pop!(opt.worklist)
        delete!(opt.inworklist, orig)
        check_inst!(opt, orig)
        if info.escaped
            remark(opt, :missed, "Escaped", orig, "GC allocation escaped")
            info.hastypeof && optimize_tag!(opt, orig)
            continue
        end
        if info.haserror || info.returned
            remark(opt, :missed, "Escaped", orig, "GC allocation has error or was returned")
            info.hastypeof && optimize_tag!(opt, orig)
            continue
        end
        if !info.addrescaped && !info.hasload && (!info.haspreserve || !info.refstore)
            # no one takes the address or reads anything, and there's no meaningful
            # preserve of fields: delete all uses
            remark(opt, :passed, "Dead Allocation", orig, "GC allocation removed")
            remove_alloc!(opt, orig)
            continue
        end
        has_unboxed = info.has_unknown_unboxed
        has_ref = info.has_unknown_objref
        has_refaggr = info.has_unknown_objrefaggr
        for field in info.fields
            has_unboxed |= field.hasunboxed
            if field.hasobjref
                has_ref = true
                if field.hasaggr || field.multiloc || field.size != sizeof(Ptr{Cvoid})
                    has_refaggr = true
                    break
                end
            end
        end
        if has_refaggr
            remark(opt, :missed, "Escaped", orig,
                   "GC allocation has unusual object reference, unable to move to stack")
            info.hastypeof && optimize_tag!(opt, orig)
            continue
        end
        if !info.hasunknownmem && !info.addrescaped
            # no one cares about the memory layout of the object: split it
            remark(opt, :passed, "Stack Split Allocation", orig, "GC allocation split on stack")
            split_on_stack!(opt, orig)
            continue
        end
        # moving to the stack makes an object with references an array of references,
        # which would make the GC rooting pass mistake unboxed fields for references
        if has_ref && (has_unboxed || info.addrescaped)
            remark(opt, :missed, "Escaped", orig,
                   "GC allocation could not be split since it contains both boxed and unboxed values, unable to move to stack")
            info.hastypeof && optimize_tag!(opt, orig)
            continue
        end
        remark(opt, :passed, "Stack Move Allocation", orig, "GC allocation moved to stack")
        move_to_stack!(opt, orig, sz, has_ref)
    end
end

function finalize!(opt::AllocOpt)
    isempty(opt.removed) && return false
    for inst in opt.removed
        erase_inst!(opt, inst)
    end
    return true
end

function is_safepoint(opt::AllocOpt, inst::Instruction)
    inst isa CallInst || return false
    callee = inst.called_function
    callee === nothing && return true
    # intrinsics (C++'s `IntrinsicInst`: any function with a name starting with `llvm.`)
    startswith(callee.name, "llvm.") && return false
    # functions emitted by codegen that are not safepoints
    callee == opt.fns.pointer_from_objref && return false
    opt.fns.gc_loaded !== nothing && callee == opt.fns.gc_loaded && return false
    callee.name == "memcmp" && return false
    return true
end

function first_safepoint(opt::AllocOpt, bb::BasicBlock)
    haskey(opt.first_safepoint, bb) && opt.first_safepoint[bb] !== nothing &&
        return opt.first_safepoint[bb]
    first = nothing
    for inst in bb.instructions
        if is_safepoint(opt, inst)
            first = inst
            break
        end
    end
    opt.first_safepoint[bb] = first
    return first
end

# the first instruction where non-PHI instructions can be inserted
function first_insertion_inst(bb::BasicBlock)
    for inst in bb.instructions
        inst isa Union{PHIInst,LandingPadInst,CatchPadInst,CleanupPadInst,CatchSwitchInst} &&
            continue
        return inst
    end
    error("block without insertion point")
end

function lifetime_call!(opt::AllocOpt, f::LLVM.Function, ptr::Value, size::Integer,
                        at::Instruction)
    builder = opt.builder
    position!(builder, LLVM.before(at))
    builder.debug_location = nothing
    args = opt.lifetime_size ? Value[ConstantInt(LLVM.Int64Type(), size), ptr] : Value[ptr]
    call!(builder, f.function_type, f, args)
end

function insert_lifetime_end!(opt::AllocOpt, ptr::Value, size::Integer, insert::Instruction)
    # insert the end before nearby lifetime markers, so that the lifetimes of two
    # allocations don't overlap when one starts at the first safepoint of the other
    prev = insert.prev
    while prev isa CallInst && (callee = prev.called_function) !== nothing &&
          is_lifetime(callee)
        insert = prev
        prev = insert.prev
    end
    lifetime_call!(opt, opt.lifetime_end, ptr, size, insert)
end

# insert lifetime markers for `ptr`, based on the uses of the allocation `orig`
function insert_lifetime!(opt::AllocOpt, ptr::Value, size::Integer, orig::Instruction)
    info = opt.info
    lifetime_call!(opt, opt.lifetime_start, ptr, size, orig)
    def_bb = orig.parent
    bbs = Set{BasicBlock}([def_bb])
    bbs_order = BasicBlock[def_bb]
    function add!(bb)
        bb in bbs && return false
        push!(bbs, bb)
        push!(bbs_order, bb)
        return true
    end
    # the blocks where the allocation is live: those of its uses and their predecessors,
    # up to the definition
    for use in info.use_order
        bb = use.parent
        add!(bb) || continue
        stack = collect(bb.predecessors)
        while !isempty(stack)
            pred = pop!(stack)
            add!(pred) && append!(stack, pred.predecessors)
        end
    end

    # blocks with invisible uses between `gc_preserve_begin` and `gc_preserve_end`: those
    # dominated by the begin, until a block dominated by an end
    extra_use = Set{BasicBlock}()
    reachable = reachable_blocks(opt)
    for preserve in info.preserves
        pbb = preserve.parent
        pbb in reachable || continue
        ends = [user.parent for user in preserve.users]
        for bb in opt.f.blocks
            bb in reachable && block_dominates(opt, pbb, bb) || continue
            bb in extra_use && continue
            any(e -> e == bb || (e in reachable && block_dominates(opt, e, bb)), ends) &&
                continue
            add!(bb)
            push!(extra_use, bb)
        end
    end

    # in each block, the first instruction(s) where the allocation is possibly dead
    first_dead = Instruction[]
    for bb in bbs_order
        succs = bb.successors
        if any(succ -> succ != def_bb && succ in bbs, succs)
            for succ in succs
                succ in bbs || push!(first_dead, first(succ.instructions))
            end
        elseif bb in extra_use
            push!(first_dead, bb.terminator)
        else
            # the instruction after the last use
            next = nothing
            for inst in Iterators.reverse(collect(bb.instructions))
                if inst in info.uses
                    next === nothing || push!(first_dead, next)
                    break
                end
                next = inst
            end
        end
    end

    # one lifetime end per block, at the first safepoint after the first dead instruction
    done = Set{BasicBlock}()
    while !isempty(first_dead)
        inst = pop!(first_dead)
        bb = inst.parent
        bb in done && continue
        push!(done, bb)
        if inst == first(bb.instructions)
            # no use in or after this block: if it isn't dominated by the definition, the
            # allocation is dead when entering it; otherwise there could be uses we don't
            # track before the next safepoint
            if !inst_dominates_block(opt, orig, bb)
                insert_lifetime_end!(opt, ptr, size, first_insertion_inst(bb))
                continue
            elseif (insert = first_safepoint(opt, bb)) !== nothing
                insert_lifetime_end!(opt, ptr, size, insert)
                continue
            end
        else
            found = false
            it = inst
            while it !== nothing
                if is_safepoint(opt, it)
                    insert_lifetime_end!(opt, ptr, size, it)
                    found = true
                    break
                end
                it = it.next
            end
            found && continue
        end
        for succ in bb.successors
            push!(first_dead, first(succ.instructions))
        end
    end
end

# replace a use of an allocation by an intrinsic with one of a different (stack) pointer,
# which needs another overload of the intrinsic
function replace_intrinsic_use!(opt::AllocOpt, call::Instruction, orig::Value, new::Value)
    mod = opt.f.parent
    args = Value[arg == orig ? new : arg for arg in call.arguments]
    old_ft = call.called_type
    nparams = length(old_ft.parameters)
    new_ft = LLVM.FunctionType(old_ft.return_type,
                               LLVMType[a.value_type for a in args[1:nparams]];
                               vararg=isvararg(old_ft))
    intr = call.called_function.intrinsic
    new_f = LLVM.Function(mod, intr, new_ft)
    new_f.callconv = call.callconv
    position!(opt.builder, LLVM.before(call))
    opt.builder.debug_location = nothing
    new_call = call!(opt.builder, new_ft, new_f, args)
    new_call.tailcall_kind = call.tailcall_kind
    # keep the function and return attributes, not those of the parameters
    for attr in collect(call.function_attributes)
        push!(new_call.function_attributes, attr)
    end
    for attr in collect(call.return_attributes)
        push!(new_call.return_attributes, attr)
    end
    new_call.debug_location = call.debug_location
    replace_uses!(call, new_call)
    erase_inst!(opt, call)
end

function remove_write_barrier_use!(opt::AllocOpt, call::Instruction, val::Value)
    args = call.arguments
    is_destination = args[1] == val
    if is_field_write_barrier(opt.fns, call.called_operand)
        for i in FIELD_WB_SLOT_ARG:2:length(args)
            is_destination |= args[i] == val
        end
    end
    if is_destination
        erase_inst!(opt, call)
    else
        # the allocation doesn't escape, but other fields covered by this barrier may still
        # be written: only drop the eliminated child
        replace_uses_of!(call, val, null(val.value_type))
    end
end

function remove_gc_preserve!(opt::AllocOpt, call::Instruction, val::Value)
    replace_uses_of!(call, val, null(val.value_type))
    clear_attributes!(call)
    all(arg -> arg isa Constant, call.arguments) || return
    for user in collect(call.users)
        # gc_preserve_end returns void
        erase_inst!(opt, user)
    end
    erase_inst!(opt, call)
end

function clear_attributes!(call::Instruction)
    for attrs in (call.function_attributes, call.return_attributes,
                  (call.argument_attributes[i] for i in 1:length(call.arguments))...)
        for attr in collect(attrs)
            delete!(attrs, attr)
        end
    end
end

# initialize stack memory that replaces an allocation, if the allocation was initialized
function initialize_alloca!(opt::AllocOpt, buff::Instruction, at::Instruction)
    kind = opt.info.allockind
    kind & ALLOCKIND_UNINITIALIZED != 0 && return
    initialization = opt.dialect.alloc_initialization
    initialization === :none && return
    T = buff.allocated_type
    position_at!(opt, at)
    if initialization === :store
        # Julia 1.11: zero, or a frozen undefined value for allocations that are neither
        # zeroed nor uninitialized
        init = if kind & ALLOCKIND_ZEROED != 0 || kind == 0
            null(T)
        else
            freeze!(opt.builder, LLVM.UndefValue(T))
        end
        store!(opt.builder, init, buff)
    else
        memset!(opt.builder, buff, ConstantInt(LLVM.Int8Type(), 0),
                ConstantInt(LLVM.Int64Type(), abi_size(opt.dl, T)), buff.alignment)
    end
end

# Move an allocation to the stack. Must not erase safepoints, so that the lifetime markers
# find all of the original ones.
function move_to_stack!(opt::AllocOpt, orig::Instruction, sz::Int, has_ref::Bool)
    builder = opt.builder
    tag = orig.arguments[3]
    push!(opt.removed, orig)
    # the allocation doesn't escape or flow into a phi, so none of the values derived from
    # it are live when it is allocated again: allocate it in the entry block
    align = stack_alignment(opt, orig, sz)
    # like C++'s `prolog_builder`, insert before the original first instruction
    prolog = first(first(opt.f.blocks).instructions)
    position_at!(opt, prolog)
    buff = if sz == 0
        array_alloca!(builder, LLVM.Int8Type(), ConstantInt(LLVM.Int64Type(), 0))
    elseif has_ref
        # an array of references, so that GC frame lowering treats it as a non-mem2reg'd
        # alloca; the root and preserve handling below keep it alive
        n = sz ÷ abi_size(opt.dl, opt.T_prjlvalue)
        array_alloca!(builder, opt.T_prjlvalue, ConstantInt(LLVM.Int64Type(), n); align)
    else
        alloca!(builder, stack_type(opt, sz, align); align)
    end
    insert_lifetime!(opt, buff, sz, orig)
    sz != 0 && !has_ref && initialize_alloca!(opt, buff, orig)
    copy_metadata!(buff, orig)
    take_name!(buff, orig)

    # replace the uses of `orig_i` (derived from the allocation) by `new_i` (derived from
    # the stack memory); both are pointers, `new_i` in the alloca address space
    stack = Tuple{Instruction,Instruction}[]
    simple_replace(orig_i, new_i) = begin
        if isempty(orig_i.uses)
            orig_i == orig || erase_inst!(opt, orig_i)
            return true
        end
        if orig_i.value_type == new_i.value_type
            replace_uses!(orig_i, new_i)
            orig_i == orig || erase_inst!(opt, orig_i)
            return true
        end
        return false
    end
    simple_replace(orig, buff) && return
    cur = (orig, buff)
    function push_frame!(orig_i, new_i)
        simple_replace(orig_i, new_i) && return
        push!(stack, cur)
        cur = (orig_i, new_i)
    end
    function replace!(user::Instruction)
        orig_i, new_i = cur
        if user isa LoadInst || user isa StoreInst || user isa AtomicCmpXchgInst ||
           user isa AtomicRMWInst
            replace_uses_of!(user, orig_i, new_i)
        elseif user isa CallInst
            callee = user.called_operand
            if callee == opt.fns.pointer_from_objref
                position_at!(opt, prolog)
                cast = addrspacecast!(builder, new_i,
                                      user.called_function.function_type.return_type)
                replace_uses!(user, cast)
                erase_inst!(opt, user)
            elseif opt.fns.gc_loaded !== nothing && callee == opt.fns.gc_loaded
                replace_uses_of!(user, orig_i, null(orig_i.value_type))
            elseif callee == opt.fns.typeof
                replace_uses!(user, tag)
                erase_inst!(opt, user)
            elseif callee == opt.fns.gc_preserve_begin
                # remove the preserve intrinsics, for better optimization
                if has_ref
                    replace_uses_of!(user, orig_i, buff)
                else
                    remove_gc_preserve!(opt, user, orig_i)
                end
            elseif is_write_barrier(opt.fns, callee)
                remove_write_barrier_use!(opt, user, orig_i)
            elseif callee isa LLVM.Function && LLVM.isintrinsic(callee)
                replace_intrinsic_use!(opt, user, orig_i, new_i)
            else
                # an operand bundle
                replace_uses_of!(user, orig_i, has_ref ? buff : null(orig_i.value_type))
            end
        elseif user isa AddrSpaceCastInst || user isa BitCastInst
            push_frame!(user, new_i)
        elseif user isa GetElementPtrInst
            position!(builder, LLVM.before(user))
            builder.debug_location = nothing
            indices = collect(user.indices)
            new_gep = user.inbounds ?
                inbounds_gep!(builder, user.source_element_type, new_i, indices) :
                gep!(builder, user.source_element_type, new_i, indices)
            take_name!(new_gep, user)
            copy_metadata!(new_gep, user)
            push_frame!(user, new_gep)
        else
            error("unexpected use of an allocation: $(string(user))")
        end
    end
    while true
        replace!(first(cur[1].users))
        while isempty(cur[1].uses)
            cur[1] == orig || erase_inst!(opt, cur[1])
            isempty(stack) && return
            cur = pop!(stack)
        end
    end
end

# Remove an allocation and its uses. Must not erase safepoints, like `move_to_stack!`.
function remove_alloc!(opt::AllocOpt, orig::Instruction)
    tag = orig.arguments[3]
    push!(opt.removed, orig)
    isempty(orig.uses) && return
    stack = Instruction[]
    cur = orig
    function push_frame!(orig_i)
        if isempty(orig_i.uses)
            erase_inst!(opt, orig_i)
            return
        end
        push!(stack, cur)
        cur = orig_i
    end
    function remove!(user::Instruction)
        orig_i = cur
        if user isa StoreInst
            # all stores are dead; the stored value may be an allocation that can now be
            # optimized
            stored = user.value_operand
            stored isa Instruction && push_instruction!(opt, stored)
            erase_inst!(opt, user)
        elseif user isa CallInst
            callee = user.called_operand
            if callee == opt.fns.gc_preserve_begin
                remove_gc_preserve!(opt, user, orig_i)
            elseif callee == opt.fns.typeof
                replace_uses!(user, tag)
                erase_inst!(opt, user)
            elseif is_write_barrier(opt.fns, callee)
                remove_write_barrier_use!(opt, user, orig_i)
            elseif callee isa LLVM.Function && LLVM.isintrinsic(callee) &&
                   (LLVM.isintrinsic(callee, MEMSET) || is_lifetime_or_debug(callee))
                erase_inst!(opt, user)
            else
                # an operand bundle
                replace_uses_of!(user, orig_i, null(orig_i.value_type))
            end
        elseif user isa AddrSpaceCastInst || user isa BitCastInst || user isa GetElementPtrInst
            push_frame!(user)
        else
            error("unexpected use of an allocation: $(string(user))")
        end
    end
    while true
        remove!(first(cur.users))
        while isempty(cur.uses)
            cur == orig || erase_inst!(opt, cur)
            isempty(stack) && return
            cur = pop!(stack)
        end
    end
end

# The allocation can't be optimized out: forward its type tag to `julia.typeof` calls.
function optimize_tag!(opt::AllocOpt, orig::Instruction)
    tag = orig.arguments[3]
    last_removed = length(opt.removed)
    for user in orig.users
        user isa CallInst && user.called_operand == opt.fns.typeof || continue
        remark(opt, :passed, "typeof", user, "removed typeof call for GC allocation")
        replace_uses!(user, tag)
        # erased at the end, which makes the pass report a change
        push!(opt.removed, user)
    end
    for i in last_removed+1:length(opt.removed)
        replace_uses_of!(opt.removed[i], orig, LLVM.UndefValue(orig.value_type))
    end
end

struct SplitSlot
    slot::Instruction
    isref::Bool
    offset::UInt32
    size::UInt32
end

function split_on_stack!(opt::AllocOpt, orig::Instruction)
    builder = opt.builder
    info = opt.info
    tag = orig.arguments[3]
    push!(opt.removed, orig)
    # like C++'s `prolog_builder`, insert before the original first instruction
    prolog = first(first(opt.f.blocks).instructions)
    legacy = opt.dialect.alloc_layout === :legacy
    align = legacy ? nothing : stack_alignment(opt, orig, 0)
    slots = SplitSlot[]
    for (offset, field) in zip(info.offsets, info.fields)
        # a field without readers that is not a reference which needs to be preserved
        # doesn't need memory
        !field.hasload && (!field.hasobjref || !info.haspreserve) && continue
        allocty = if field.hasobjref
            opt.T_prjlvalue
        elseif field.elty !== nothing && !field.multiloc
            field.elty
        else
            stack_type(opt, field.size, something(align, 1))
        end
        position_at!(opt, prolog)
        slot = alloca!(builder, allocty; align)
        insert_lifetime!(opt, slot, field.size, orig)
        if field.hasobjref
            # null-initialized like the GC does, unless the allocation is uninitialized
            # (adopted from Julia 1.13 for every dialect)
            if info.allockind & ALLOCKIND_UNINITIALIZED == 0
                position_at!(opt, orig)
                store!(builder, null(opt.T_prjlvalue), slot)
            end
        else
            initialize_alloca!(opt, slot, orig)
        end
        push!(slots, SplitSlot(slot, field.hasobjref, offset, field.size))
    end
    nslots = length(slots)
    # the slot that contains `offset`
    function find_slot(offset)
        offset == 0 && return 1
        lb, ub = 1, nslots + 1
        while lb + 1 < ub
            mid = (lb + ub) ÷ 2
            if slots[mid].offset <= offset
                lb = mid
            else
                ub = mid
            end
        end
        return lb
    end
    function slot_gep(slot::SplitSlot, offset, elty)
        offset -= slot.offset
        size = abi_size(opt.dl, elty)
        if offset % size == 0
            offset == 0 && return slot.slot
            return inbounds_gep!(builder, elty, slot.slot,
                                 [ConstantInt(LLVM.Int32Type(), offset ÷ size)])
        else
            return inbounds_gep!(builder, LLVM.Int8Type(), slot.slot,
                                 [ConstantInt(LLVM.Int32Type(), offset)])
        end
    end
    # the references in the slots, to preserve them
    function slot_refs()
        refs = Value[]
        for slot in slots
            slot.isref || continue
            ref = load!(builder, opt.T_prjlvalue, slot.slot; align=sizeof(Ptr{Cvoid}))
            push!(refs, ref)
        end
        return refs
    end

    isempty(orig.uses) && (finish_split!(opt, slots); return)
    stack = Tuple{Instruction,UInt32}[]
    cur = (orig, UInt32(0))
    function push_frame!(orig_i, offset)
        if isempty(orig_i.uses)
            erase_inst!(opt, orig_i)
            return
        end
        push!(stack, cur)
        cur = (orig_i, offset)
    end
    function replace!(use::Use)
        user = use.user
        orig_i, offset = cur
        if user isa LoadInst
            slot = slots[find_slot(offset)]
            position_at!(opt, user)
            load_ty = user.value_type
            newload = if slot.isref
                load!(builder, opt.T_prjlvalue, slot.slot)
            else
                load!(builder, load_ty, slot_gep(slot, offset, load_ty))
            end
            newload.alignment = user.alignment
            # heap to stack: the access does not need to be atomic anymore
            newload.ordering = LLVM.API.LLVMAtomicOrderingNotAtomic
            replace_uses!(user, newload)
            erase_inst!(opt, user)
        elseif user isa StoreInst
            stored = user.value_operand
            stored isa Instruction && push_instruction!(opt, stored)
            slot = slots[find_slot(offset)]
            if slot.offset > offset || slot.offset + slot.size <= offset
                erase_inst!(opt, user)
                return
            end
            position_at!(opt, user)
            store_val = stored
            store_ty = store_val.value_type
            newstore = if slot.isref
                if !(store_ty isa LLVM.PointerType)
                    store_val = bitcast!(builder, store_val, intptr(opt.dl, AS_GENERIC))
                    store_val = inttoptr!(builder, store_val, opt.T_pjlvalue)
                    store_ty = opt.T_pjlvalue
                end
                if store_ty.addrspace != AS_TRACKED
                    store_val = addrspacecast!(builder, store_val, opt.T_prjlvalue)
                end
                store!(builder, store_val, slot.slot)
            else
                store!(builder, store_val, slot_gep(slot, offset, store_ty))
            end
            newstore.alignment = user.alignment
            newstore.ordering = LLVM.API.LLVMAtomicOrderingNotAtomic
            erase_inst!(opt, user)
        elseif user isa AtomicCmpXchgInst || user isa AtomicRMWInst
            slot = slots[find_slot(offset)]
            position_at!(opt, user)
            newptr = if slot.isref
                slot.slot
            else
                val = user isa AtomicCmpXchgInst ? user.operands[3] : user.operands[2]
                slot_gep(slot, offset, val.value_type)
            end
            user.operands[use.operand_index] = newptr
            # heap to stack: the access does not need to be atomic anymore
            LLVM.lower_atomic!(user)
        elseif user isa CallInst
            callee = user.called_operand
            if callee isa LLVM.Function && LLVM.isintrinsic(callee)
                if LLVM.isintrinsic(callee, MEMSET)
                    position_at!(opt, user)
                    val_arg = user.arguments[2]
                    val = convert(UInt64, user.arguments[2]) % UInt8
                    size = UInt32(convert(UInt64, user.arguments[3]))
                    for idx in find_slot(offset):nslots
                        slot = slots[idx]
                        (slot.offset + slot.size <= offset || slot.offset >= offset + size) && break
                        if slot.isref
                            ptr = if val == 0
                                null(opt.T_prjlvalue)
                            else
                                intval = UInt64(val) * 0x0101010101010101
                                int = ConstantInt(intptr(opt.dl, AS_TRACKED), intval)
                                const_addrspacecast(const_inttoptr(int, opt.T_pjlvalue),
                                                    opt.T_prjlvalue)
                            end
                            store = store!(builder, ptr, slot.slot)
                            store.alignment = sizeof(Ptr{Cvoid})
                            continue
                        end
                        ptr_slot = slot.slot
                        if offset > slot.offset
                            ptr_slot = inbounds_gep!(builder, LLVM.Int8Type(), slot.slot,
                                                     [ConstantInt(LLVM.Int32Type(), offset - slot.offset)])
                        end
                        sub_size = min(slot.offset + slot.size, offset + size) - max(offset, slot.offset)
                        memset!(builder, ptr_slot, val_arg,
                                ConstantInt(LLVM.Int64Type(), sub_size), 0)
                    end
                end
                erase_inst!(opt, user)
            elseif callee == opt.fns.typeof
                replace_uses!(user, tag)
                erase_inst!(opt, user)
            elseif is_write_barrier(opt.fns, callee)
                remove_write_barrier_use!(opt, user, orig_i)
            elseif callee == opt.fns.gc_preserve_begin
                operands = Value[arg for arg in user.arguments
                                 if arg != orig_i && !(arg isa Constant)]
                position_at!(opt, user)
                append!(operands, slot_refs())
                f = opt.fns.gc_preserve_begin
                new_call = call!(builder, f.function_type, f, operands)
                take_name!(new_call, user)
                replace_uses!(user, new_call)
                erase_inst!(opt, user)
            else
                # a `jl_roots` operand bundle
                position_at!(opt, user)
                bundles = OperandBundle[]
                rebuilt = false
                for bundle in user.operand_bundles
                    if !rebuilt && bundle.tag == "jl_roots"
                        inputs = Value[op for op in bundle.inputs
                                       if op != orig_i && !(op isa Constant)]
                        append!(inputs, slot_refs())
                        push!(bundles, OperandBundle("jl_roots", inputs))
                        rebuilt = true
                    else
                        push!(bundles, bundle)
                    end
                end
                new_call = clone_call!(opt, user, bundles)
                take_name!(new_call, user)
                replace_uses!(user, new_call)
                erase_inst!(opt, user)
            end
        elseif user isa AddrSpaceCastInst || user isa BitCastInst
            push_frame!(user, offset)
        elseif user isa GetElementPtrInst
            gep_offset = LLVM.constant_offset(user, opt.dl)
            push_frame!(user, UInt32(offset + gep_offset))
        else
            error("unexpected use of an allocation: $(string(user))")
        end
    end
    while true
        replace!(first(cur[1].uses))
        while isempty(cur[1].uses)
            cur[1] == orig || erase_inst!(opt, cur[1])
            if isempty(stack)
                finish_split!(opt, slots)
                return
            end
            cur = pop!(stack)
        end
    end
end

# promote the reference slots to registers, one at a time like C++, so that GC frame
# lowering doesn't see them as stack slots holding references
function finish_split!(opt::AllocOpt, slots)
    for slot in slots
        slot.isref && promote_mem_to_reg!(slot.slot, domtree(opt))
    end
end

# like C++'s `CallInst::Create(call, bundles)`: the same call with other operand bundles
function clone_call!(opt::AllocOpt, call::Instruction, bundles::Vector{OperandBundle})
    builder = opt.builder
    position!(builder, LLVM.before(call))
    builder.debug_location = nothing
    new_call = call!(builder, call.called_type, call.called_operand,
                     collect(call.arguments), bundles)
    new_call.tailcall_kind = call.tailcall_kind
    new_call.callconv = call.callconv
    for attr in collect(call.function_attributes)
        push!(new_call.function_attributes, attr)
    end
    for attr in collect(call.return_attributes)
        push!(new_call.return_attributes, attr)
    end
    for i in 1:length(call.arguments), attr in collect(call.argument_attributes[i])
        push!(new_call.argument_attributes[i], attr)
    end
    new_call.debug_location = call.debug_location
    return new_call
end

function alloc_opt!(f::LLVM.Function, am::FunctionAnalysisManager, opts::PassOptions)
    mod = f.parent
    dialect = opts.dialect
    fns = JuliaFunctions(mod, dialect)
    fns.alloc_obj === nothing && return PreservedAnalyses(AllAnalyses)

    layout = unsafe_string(API.LLVMGetDataLayoutStr(mod))
    facts = library_facts(context(f))
    as = alloca_addrspace(layout)
    ptr = LLVM.PointerType(as)
    lifetime_start = LLVM.Function(mod, LIFETIME_START, LLVMType[ptr])
    lifetime_end = LLVM.Function(mod, LIFETIME_END, LLVMType[ptr])

    @dispose builder=IRBuilder() begin
        opt = AllocOpt(f, am, dialect, fns, mod.datalayout, layout, builder,
                       facts.lifetime_size, lifetime_start, lifetime_end,
                       LLVM.PointerType(AS_TRACKED), LLVM.PointerType(AS_GENERIC),
                       nothing, nothing, Tuple{Instruction,Int}[], Set{Instruction}(),
                       Instruction[], AllocUseInfo(),
                       Dict{BasicBlock,Union{Nothing,Instruction}}())
        for bb in f.blocks, inst in bb.instructions
            push_instruction!(opt, inst)
        end
        optimize_all!(opt)
        finalize!(opt)
    end
    # like the C++ pass, report a change whenever the module uses allocations: declaring
    # the lifetime intrinsics changed it
    return PreservedAnalyses(CFGAnalyses, DomTree)
end

const ALLOC_OPT = define_pass("jl-alloc-opt", :function, alloc_opt!; required=false,
                              cpp_name="AllocOpt")

"""
    JuliaIR.AllocOptPass(; julia=VERSION)

Remove Julia GC allocations whose object does not escape, or move them to the stack,
whole or split into their fields (`jl-alloc-opt` in a pipeline).
"""
AllocOptPass(; kwargs...) = custom_pass(ALLOC_OPT; kwargs...)
