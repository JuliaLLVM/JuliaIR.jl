# ExpandAtomicModify: lower the `julia.atomicmodify.*` calls that Julia 1.13 and later emit
# for `@atomic` modify operations. Port of Julia's `src/llvm-expand-atomic-modify.cpp`
# (v1.13 and master), which adapts the cmpxchg loop of LLVM's AtomicExpand pass.
#
# A call
#
#   %oldnew = call {T, T} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.iN.pAS(
#                 ptr align(A) %ptr, ptr @op, i8 ordering, i8 syncscope, args...)
#
# atomically replaces the value at `%ptr` by `@op(old, args...)` and returns the old and
# the new value. When the body of `@op` is a single operation that `atomicrmw` supports, it
# is inlined (also through up to three levels of calls that pass the old value on) and
# turned into that `atomicrmw`; otherwise the call to the operation is wrapped in a
# compare-exchange loop.
#
# The pass only exists in Julia 1.13 and later (`Dialect.has_atomicmodify`); for older
# dialects it does nothing. Like the C++ pass, it is not required (it is skipped on
# `optnone` functions).

const ATOMICMODIFY_PREFIX = "julia.atomicmodify."

# the C++ pass builds instructions with an `IRBuilder<InstSimplifyFolder>`: replace a new
# instruction by what it simplifies to, if anything
function fold!(@nospecialize(inst::Value))
    inst isa Instruction || return inst
    simple = simplify_instruction(inst)
    simple === nothing && return inst
    erase!(inst)
    return simple
end

# The state of the replacement builder for one `julia.atomicmodify` call (C++
# `ReplacementIRBuilder`): instructions it creates get the call's debug location, its
# `!mmra` (where possible) and its `!pcsections` metadata.
struct ReplacementBuilder
    builder::IRBuilder
    mmra::Union{Nothing,Metadata}
    pcsections::Union{Nothing,Metadata}
    strictfp::Bool
end

function ReplacementBuilder(builder::IRBuilder, modify::Instruction)
    position!(builder, LLVM.before(modify))
    builder.debug_location = modify.debug_location
    md = modify.metadata
    mmra = haskey(md, "mmra") ? md["mmra"] : nothing
    pcsections = haskey(md, "pcsections") ? md["pcsections"] : nothing
    f = modify.parent.parent
    strictfp = haskey(f.function_attributes, :strictfp)
    return ReplacementBuilder(builder, mmra, pcsections, strictfp)
end

# what the C++ builder's insertion callback does to every instruction it creates
function inserted!(rb::ReplacementBuilder, @nospecialize(val::Value))
    val isa Instruction || return val
    if rb.mmra !== nothing && supports_mmra(val)
        val.metadata["mmra"] = rb.mmra
    end
    rb.pcsections === nothing || (val.metadata["pcsections"] = rb.pcsections)
    return val
end

position_rb!(rb::ReplacementBuilder, pos) = position!(rb.builder, pos)


## matching the operation to an atomicrmw

# A use of a value, as the user and the index of the operand.
const OperandUse = Tuple{Instruction,Int}

use_value(use::OperandUse) = use[1].operands[use[2]]
set_use!(use::OperandUse, @nospecialize(val::Value)) = (use[1].operands[use[2]] = val)

has_no_uses(@nospecialize(v::Value)) = API.LLVMGetFirstUse(v) == C_NULL

may_read_or_write_memory(inst::Instruction) =
    may_read_from_memory(inst) || may_write_to_memory(inst)

# Whether the operation `target`, in the function that implements the modification, can be
# reordered with the atomic access (C++ `canReorderWithRMW`). Conservatively, no other
# instruction of the function may write memory, nor read it unless the function is
# `nosync`, and if another instruction reads memory, `target` may not write it.
function can_reorder_with_rmw(target::Instruction, verifyop::Bool)
    verifyop || return true
    op = target.parent.parent
    nosync = haskey(op.function_attributes, :nosync)
    nosync && !may_read_or_write_memory(target) && return true
    may_read = false
    for bb in op.blocks, inst in bb.instructions
        inst == target && continue
        may_write_to_memory(inst) && return false
        if !may_read
            may_read = may_read_from_memory(inst)
            !nosync && may_read && return false
        end
    end
    return !(may_read && may_write_to_memory(target))
end

const RMW_BINOPS = Dict(
    API.LLVMAdd => API.LLVMAtomicRMWBinOpAdd,
    API.LLVMSub => API.LLVMAtomicRMWBinOpSub,
    API.LLVMAnd => API.LLVMAtomicRMWBinOpAnd,
    API.LLVMOr => API.LLVMAtomicRMWBinOpOr,
    API.LLVMXor => API.LLVMAtomicRMWBinOpXor,
    API.LLVMFAdd => API.LLVMAtomicRMWBinOpFAdd,
    API.LLVMFSub => API.LLVMAtomicRMWBinOpFSub,
)

const RMW_INTRINSICS = [
    "llvm.minnum" => API.LLVMAtomicRMWBinOpFMin,
    "llvm.maxnum" => API.LLVMAtomicRMWBinOpFMax,
    "llvm.smax" => API.LLVMAtomicRMWBinOpMax,
    "llvm.umax" => API.LLVMAtomicRMWBinOpUMax,
    "llvm.smin" => API.LLVMAtomicRMWBinOpMin,
    "llvm.umin" => API.LLVMAtomicRMWBinOpUMin,
]

# the atomicrmw operation of a binary intrinsic, if any
function rmw_intrinsic(f::LLVM.Function)
    for (name, op) in RMW_INTRINSICS
        LLVM.isintrinsic(f, Intrinsic(name)) && return op
    end
    # `atomicrmw usub_sat` exists since LLVM 20 (Julia 1.13's, the first dialect with
    # these calls); the API of older versions doesn't define it
    LLVM.isintrinsic(f, Intrinsic("llvm.usub.sat")) && return API.LLVMAtomicRMWBinOpUSubSat
    return nothing
end

is_binary_operator(@nospecialize(v::Value)) =
    v isa Instruction && API.LLVMIsABinaryOperator(v) != C_NULL

# the operand of a two-operand instruction that `old` is used as (or as the second
# operand, if the instruction is commutative)
function old_operand(inst::Instruction, @nospecialize(old::Value), commutative::Bool)
    ops = inst.operands
    ops[1] == old && return 1
    commutative && ops[2] == old && return 2
    return 0
end

# Match the operation that computes `retval` from the old value `old` to an atomicrmw
# operation (C++ `patternMatchAtomicRMWOp`). Returns `false` (no atomicrmw), `true` (a
# call that the old value is passed to, which can be inlined in turn), or an atomicrmw
# operation, together with the use of the other operand (or of the old value, for a
# call). `Or` without such a use stands for an access that leaves the value unchanged (an
# `atomicrmw or` with zero), `Xchg` without one for an operation that ignores the old
# value. With `retval === nothing`, `old` is the first argument of the function that
# implements the operation, which is verified (it must be defined here and return the
# operation's result, which only uses the old value once); otherwise `old` is the
# atomicrmw that replaced it after inlining the function.
function match_rmw_op(@nospecialize(old::Value), @nospecialize(retval))
    verifyop = retval === nothing
    if verifyop
        op = (old::Argument).parent
        (isdeclaration(op) || isinterposable(op) || LLVM.isintrinsic(op)) &&
            return false, nothing
        has_no_uses(old) && return API.LLVMAtomicRMWBinOpXchg, nothing
        has_one_use(old) || return false, nothing
        ret = nothing
        for bb in op.blocks
            term = bb.terminator
            if term isa LLVM.RetInst
                ret === nothing || return false, nothing
                ret = term
            end
        end
        ret === nothing && return false, nothing
        retval = ret.operands[1]
        has_one_use(retval) || return false, nothing
    end
    retval == old && return API.LLVMAtomicRMWBinOpOr, nothing
    has_no_uses(old) && return API.LLVMAtomicRMWBinOpXchg, nothing

    if is_binary_operator(retval)
        binop = retval::Instruction
        opcode = API.LLVMGetInstructionOpcode(binop)
        idx = old_operand(binop, old, iscommutative(binop))
        if idx != 0 && can_reorder_with_rmw(binop, verifyop)
            rmw_op = get(RMW_BINOPS, opcode, nothing)
            rmw_op === nothing || return rmw_op, (binop, 3 - idx)
        end
        # nand: `xor (and old, val), -1`
        if opcode == API.LLVMXor
            ops = binop.operands
            if ops[2] isa ConstantInt &&
               ops[2] == Value(API.LLVMConstAllOnes(ops[2].value_type))
                and = ops[1]
                if is_binary_operator(and) && has_one_use(and) &&
                   API.LLVMGetInstructionOpcode(and) == API.LLVMAnd
                    idx = old_operand(and, old, iscommutative(and))
                    if idx != 0 && can_reorder_with_rmw(and, verifyop)
                        return API.LLVMAtomicRMWBinOpNand, (and, 3 - idx)
                    end
                end
            end
        end
        return false, nothing
    elseif retval isa CallInst && (callee = retval.called_function) !== nothing &&
           LLVM.isintrinsic(callee)
        call = retval::CallInst
        if length(call.arguments) == 2
            idx = old_operand(call, old, iscommutative(call))
            if idx != 0 && can_reorder_with_rmw(call, verifyop)
                rmw_op = rmw_intrinsic(callee)
                rmw_op === nothing || return rmw_op, (call, 3 - idx)
            end
        end
        return false, nothing
    elseif retval isa CallInst
        # a call the old value is passed to, which can be inlined in turn
        call = retval::CallInst
        for (i, arg) in enumerate(call.arguments)
            if arg == old
                can_reorder_with_rmw(call, verifyop) && return true, (call, i)
                return false, nothing
            end
        end
    end
    return false, nothing
end


## the compare-exchange loop

# the integer type of the size of a floating-point type (`getPrimitiveSizeInBits`)
function float_bits(@nospecialize(T::LLVMType))
    kind = API.LLVMGetTypeKind(T)
    kind == API.LLVMHalfTypeKind && return 16
    kind == API.LLVMBFloatTypeKind && return 16
    kind == API.LLVMFloatTypeKind && return 32
    kind == API.LLVMDoubleTypeKind && return 64
    kind == API.LLVMX86_FP80TypeKind && return 80
    return 128  # fp128, ppc_fp128
end

# Replace the atomic modification by a loop around a compare-exchange (C++
# `insertRMWCmpXchgLoop` and `createWeakCmpXchgInstFun`, after LLVM's AtomicExpand, but
# with a monotonic failure ordering and an unordered initial load). The builder is at the
# `julia.atomicmodify` call. `perform_op(loaded)` computes the new value at the current
# position of the builder. Returns the old and the new value.
function insert_cmpxchg_loop!(rb::ReplacementBuilder, modify::Instruction,
                              @nospecialize(T::LLVMType), @nospecialize(ptr::Value),
                              align::Int, ordering, scope::SyncScope, perform_op)
    builder = rb.builder
    bb = modify.parent
    exit_bb = split_block!(modify, "atomicrmw.end")
    loop_bb = BasicBlock(LLVM.before(exit_bb), "atomicrmw.start")

    # replace the branch that splitting the block added by the initial load
    erase!(bb.terminator)
    position_rb!(rb, LLVM.at_end(bb))
    init_loaded = inserted!(rb, load!(builder, T, ptr;
                                      ordering=API.LLVMAtomicOrderingUnordered, align))
    inserted!(rb, br!(builder, loop_bb))

    position_rb!(rb, LLVM.at_end(loop_bb))
    loaded = inserted!(rb, phi!(builder, T, "loaded"))
    push!(LLVM.incoming(loaded), (init_loaded, bb))

    new_val = perform_op(loaded)

    success_ordering = ordering == API.LLVMAtomicOrderingUnordered ?
                       API.LLVMAtomicOrderingMonotonic : ordering
    cmp, new = loaded, new_val
    need_bitcast = T isa LLVM.FloatingPointType
    if need_bitcast
        int_T = LLVM.IntType(float_bits(T))
        new = fold!(inserted!(rb, bitcast!(builder, new, int_T)))
        cmp = fold!(inserted!(rb, bitcast!(builder, cmp, int_T)))
    end
    pair = inserted!(rb, atomic_cmpxchg!(builder, ptr, cmp, new, success_ordering,
                                         API.LLVMAtomicOrderingMonotonic; scope, align))
    copy_metadata!(pair, modify)
    success = fold!(inserted!(rb, extract_value!(builder, pair, 1, "success")))
    new_loaded = fold!(inserted!(rb, extract_value!(builder, pair, 0, "newloaded")))
    if need_bitcast
        new_loaded = fold!(inserted!(rb, bitcast!(builder, new_loaded, T)))
    end
    push!(LLVM.incoming(loaded), (new_loaded, loop_bb))
    inserted!(rb, br!(builder, success, exit_bb, loop_bb))

    position_rb!(rb, LLVM.at_begin(exit_bb))
    return new_loaded, new_val
end


## the expansion

"""
    JuliaIR.AtomicModifyError

The error thrown by ExpandAtomicModify (`jl-expand-atomic-modify`) for a
`julia.atomicmodify` call it can't lower (where Julia's C++ pass crashes or emits invalid
IR): its operation is not a function, its values are not integers, floating-point
numbers or pointers, its ordering or synchronization scope is not a constant or the
ordering is invalid, it needs a compare-exchange loop but its pointer has no alignment,
or the inlined operation no longer corresponds to the `atomicrmw` it was matched to
(e.g., because inlining it into a `strictfp` function made it a constrained
floating-point intrinsic). The function is left unchanged by the errors of the first
three kinds, which are checked before any call is lowered.
"""
struct AtomicModifyError <: Exception
    function_name::String
    message::String
    instruction::String
end

AtomicModifyError(modify::Instruction, message::String) =
    AtomicModifyError(modify.parent.parent.name, message, string(modify))

Base.showerror(io::IO, err::AtomicModifyError) =
    print(io, "AtomicModifyError: ", err.message, " in function ", err.function_name,
          "\n\t", err.instruction)

# the alignment of the first argument of a call (`getParamAlign(0)`), or `nothing`
function param_align(call::Instruction)
    attrs = call.argument_attributes[1]
    haskey(attrs, :align) || return nothing
    return Int(attrs[:align].value)
end

# Reject `julia.atomicmodify` calls that can't be lowered, before changing anything.
function check_atomic_modify(modify::Instruction)
    ops = modify.operands
    op = ops[2]
    op isa LLVM.Function && !isempty(op.parameters) ||
        throw(AtomicModifyError(modify, "the operation is not a function of the old value"))
    ops[3] isa ConstantInt && ops[4] isa ConstantInt ||
        throw(AtomicModifyError(modify, "the ordering and synchronization scope are not " *
                                        "constants"))
    # an atomic ordering (`AtomicOrdering`, which has no value 3); like the scope, the C++
    # zero-extends the i8 operand
    ordering = convert(UInt, ops[3])
    ordering in (1, 2, 4, 5, 6, 7) ||
        throw(AtomicModifyError(modify, "invalid atomic ordering $(Int(ordering))"))
    T = modify.called_type.return_type.elements[1]
    T isa Union{LLVM.IntegerType,LLVM.FloatingPointType,LLVM.PointerType} ||
        throw(AtomicModifyError(modify, "atomic operations don't support values of type " *
                                        string(T)))
    return
end

# Lower one `julia.atomicmodify` call (C++ `expandAtomicModifyToCmpXchg`).
function expand_atomic_modify!(builder::IRBuilder, modify::Instruction)
    ops = modify.operands
    ptr = ops[1]
    op = ops[2]::LLVM.Function
    ordering = API.LLVMAtomicOrdering(convert(UInt, ops[3]))
    # zero-extended: the scope IDs registered after the first 126 target-specific ones
    # are negative as an i8
    scope = SyncScope(convert(UInt, ops[4]), context(modify))
    align = param_align(modify)
    ft = modify.called_type
    user_arg_start = length(ft.parameters)
    T = ft.return_type.elements[1]

    rb = ReplacementBuilder(builder, modify)

    # call the operation with an undefined old value, which is replaced later
    args = Value[UndefValue(T)]
    append!(args, collect(modify.arguments)[user_arg_start+1:end])
    modify_op = call!(builder, op.function_type, op, args,
                      collect(OperandBundle, modify.operand_bundles))
    rb.strictfp && push!(modify_op.function_attributes, EnumAttribute("strictfp"))
    inserted!(rb, modify_op)
    modify_op.callconv = op.callconv
    loaded_op::OperandUse = (modify_op, 1)

    old_val = nothing
    new_val = nothing
    rmw_op, _ = match_rmw_op(op.parameters[1], nothing)
    if rmw_op !== false
        position_rb!(rb, LLVM.before(modify_op))
        rmw = atomic_rmw!(builder, API.LLVMAtomicRMWBinOpXchg, ptr, UndefValue(T), ordering;
                          scope, align)
        inserted!(rb, rmw)
        copy_metadata!(rmw, modify)
        position_rb!(rb, LLVM.before(modify))
        set_use!(loaded_op, rmw)
        attempts = 0
        while true
            # a freeze of the call keeps track of the value it returns once inlined
            track_return = inserted!(rb, freeze!(builder, modify_op))
            if inline!(modify_op) !== nothing
                rmw_op = false
                erase!(track_return)
                break
            end
            modify_op = nothing
            new_val = track_return.operands[1]
            erase!(track_return)
            # inlining may have simplified the operation, so match it again
            rmw_op, val_op = match_rmw_op(rmw, new_val)
            if rmw_op === true
                # a call of another function, which the old value is passed to
                modify_op = val_op[1]
                loaded_op = val_op
                move!(rmw, LLVM.before(modify_op); debug_records=true)
                rmw_op = false
                attempts += 1
                attempts > 3 && break
                callee = modify_op.called_function
                callee === nothing && break
                arg = val_op[2]
                arg <= length(callee.parameters) || break
                rmw_op, _ = match_rmw_op(callee.parameters[arg], nothing)
                rmw_op === false && break
            elseif rmw_op === false
                # the C++ pass aborts here (`std::get` of the wrong alternative), e.g.
                # when inlining into a strictfp function made `fadd` a constrained
                # intrinsic
                throw(AtomicModifyError(modify, "the inlined operation no longer matches " *
                                                "an atomicrmw operation"))
            else
                if val_op !== nothing
                    move!(rmw, LLVM.before(val_op[1]); debug_records=true)
                    val = use_value(val_op)
                elseif rmw_op == API.LLVMAtomicRMWBinOpXchg
                    # the operation ignores the old value, so the new value is computed
                    # by the inlined body, which may come after the atomicrmw: move it
                    # down to the call, which the new value dominates (Julia master)
                    move!(rmw, LLVM.before(modify); debug_records=true)
                    val = new_val
                else
                    # an access that leaves the value unchanged: `atomicrmw or` with zero
                    T isa LLVM.IntegerType ||
                        throw(AtomicModifyError(modify, "the operation returns the old " *
                                                "value of type $(string(T)), which " *
                                                "atomicrmw can only leave unchanged " *
                                                "for integers"))
                    val = null(T)
                end
                rmw.binop = rmw_op
                rmw.operands[2] = val
                old_val = rmw
                break
            end
        end
        if rmw_op === false
            set_use!(loaded_op, UndefValue(T))
            erase!(rmw)
        end
    end

    if rmw_op === false
        align === nothing &&
            throw(AtomicModifyError(modify, "the pointer has no alignment, which a " *
                                            "compare-exchange loop needs"))
        old_val, new_val = insert_cmpxchg_loop!(rb, modify, T, ptr, align, ordering, scope,
                                                loaded -> begin
            set_use!(loaded_op, loaded)
            move!(modify_op, LLVM.at_end(loaded.parent); debug_records=true)
            modify_op
        end)
    end

    for use in collect(modify.uses)
        user = use.user
        user isa LLVM.ExtractValueInst && length(user.indices) == 1 || continue
        if has_no_uses(user)
            erase!(user)
        elseif user.indices[1] == 0
            replace_uses!(user, old_val)
            erase!(user)
        elseif user.indices[1] == 1
            replace_uses!(user, new_val)
            erase!(user)
        end
    end
    if !has_no_uses(modify)
        old_new = fold!(inserted!(rb, insert_value!(builder, UndefValue(modify.value_type),
                                                     old_val, 0)))
        old_new = fold!(inserted!(rb, insert_value!(builder, old_new, new_val, 1)))
        replace_uses!(modify, old_new)
    end
    erase!(modify)
    return
end

function expand_atomic_modify!(f::LLVM.Function, am, opts::PassOptions)
    opts.dialect.has_atomicmodify || return PreservedAnalyses(AllAnalyses)
    calls = Instruction[]
    for bb in f.blocks, inst in bb.instructions
        inst isa CallInst || continue
        callee = inst.called_operand
        callee isa LLVM.Function && startswith(callee.name, ATOMICMODIFY_PREFIX) &&
            push!(calls, inst)
    end
    isempty(calls) && return PreservedAnalyses(AllAnalyses)
    foreach(check_atomic_modify, calls)
    @dispose builder=IRBuilder() begin
        for call in calls
            expand_atomic_modify!(builder, call)
        end
    end
    return PreservedAnalyses()
end

const EXPAND_ATOMIC_MODIFY = define_pass("jl-expand-atomic-modify", :function,
                                         expand_atomic_modify!; required=false,
                                         cpp_name="ExpandAtomicModify")

"""
    JuliaIR.ExpandAtomicModifyPass()

Lower the `julia.atomicmodify.*` calls that Julia emits for `@atomic` modify operations
(`jl-expand-atomic-modify` in a pipeline). Such a call atomically replaces the value at a
pointer by the result of a function of the old value, and returns the old and the new
value. When that function is a single operation that `atomicrmw` supports (integer and
floating-point addition and subtraction, bitwise operations, minimum and maximum,
saturating subtraction, or exchange when it ignores the old value), it is inlined and
turned into that `atomicrmw`, also when it reaches the operation through up to three
calls that pass the old value on; otherwise the call to the function is wrapped in a
compare-exchange loop.

Julia 1.13 introduced these calls, so the pass does nothing for the IR of earlier
versions. Like Julia's C++ pass, it is skipped on `optnone` functions.
"""
ExpandAtomicModifyPass(; kwargs...) = custom_pass(EXPAND_ATOMIC_MODIFY; kwargs...)
