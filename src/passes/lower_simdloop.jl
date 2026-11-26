# LowerSIMDLoop: turn the loop markers that Julia's `@simd` emits into what LLVM's loop
# vectorizer understands. Port of Julia's `src/llvm-simdloop.cpp`, a loop pass in every
# supported version. Julia marks a loop by putting the strings `julia.simdloop` and
# `julia.ivdep` in the loop ID (the `!llvm.loop` metadata of the latch terminators). The
# pass removes every string starting with `julia` from the loop ID, and for
#
# - `julia.ivdep`: tags every instruction of the loop that may access memory with
#   `!llvm.mem.parallel_loop_access`, which tells LLVM that the iterations don't depend on
#   each other through memory;
# - `julia.simdloop`: finds the floating-point reductions of the loop (chains of
#   `fadd`/`fsub` or `fmul`/`fdiv` from a header phi back to it) and allows reassociating
#   and contracting them (`reassoc contract`). From Julia 1.12 on, the `fmul` feeding an
#   addition of such a chain is marked `contract` too (`Dialect.simdloop_check_combine`;
#   this replaced the CombineMulAdd pass).

const SIMDLOOP_REMARKS = "lower_simd_loop"

# The C++ pass emits the remark about the loop flags at the start of the loop, with the
# header as the code region; LLVM.jl emits remarks about an instruction, at its location
# and in its block. Use the header's terminator, at the start location for the remark.
function remark_loop_flags!(ar::LoopAnalysisResults, loop::Loop, simd::Bool, ivdep::Bool)
    term = LLVM.terminator(loop.header)
    # LLVM can't look for the start location in a loop ID with null operands (the C++ pass
    # crashes on one): report the remark without a location
    loc = all(!isnothing, loop_id(loop).operands) ? start_location(loop) : nothing
    old = term.debug_location
    term.debug_location = loc
    try
        remark!(ar, :analysis, SIMDLOOP_REMARKS, "Loop SIMD Flags", term) do
            "Loop marked for SIMD vectorization with flags { \"simd\": $simd, \"ivdep\": $ivdep }"
        end
    finally
        term.debug_location = old
    end
end

# The kind of reduction `user` continues when it uses `operand`
# (`getReduceOpcode`): additions and subtractions of the running value are an `FAdd`
# chain, multiplications and divisions of it an `FMul` chain. `nothing` otherwise.
function reduce_opcode(user::Instruction, @nospecialize(operand::Value))
    opcode = user.opcode
    if opcode == LLVM.Opcode.FSub
        return user.operands[1] == operand ? LLVM.Opcode.FAdd : nothing
    elseif opcode == LLVM.Opcode.FAdd
        return LLVM.Opcode.FAdd
    elseif opcode == LLVM.Opcode.FDiv
        return user.operands[1] == operand ? LLVM.Opcode.FMul : nothing
    elseif opcode == LLVM.Opcode.FMul
        return LLVM.Opcode.FMul
    else
        return nothing
    end
end

# On Julia 1.12 and later: mark the `fmul` that only feeds an addition of a reduction as
# `contract` (`checkCombine`).
function check_combine!(ar, loop::Loop, @nospecialize(op::Value))
    op isa Instruction && op.opcode == LLVM.Opcode.FMul || return
    op in loop || return
    if !has_one_use(op)
        remark!(ar, :missed, SIMDLOOP_REMARKS, "Multiuse FMul", op) do
            "fmul had multiple uses ", "fmul" => op
        end
        return
    end
    op.fast_math.contract && return
    remark!(ar, :passed, SIMDLOOP_REMARKS, "Marked for FMA", op) do
        "marked for fma ", "fmul" => op
    end
    op.fast_math.contract = true
    return
end

# If `phi` starts a floating-point reduction of `loop`, i.e. a cycle in which each
# instruction is the only user of the previous one in the loop, allow reassociating and
# contracting its operations (`enableUnsafeAlgebraIfReduction`).
function enable_unsafe_algebra_if_reduction!(ar, loop::Loop, phi::Instruction,
                                             se::ScalarEvolution, dialect::Dialect)
    chain = Instruction[]
    opcode = nothing
    inst = phi
    while true
        # the only user of `inst` in the loop; `users` in C++ lists a user once per use
        next = nothing
        for use in LLVM.uses(inst)
            u = LLVM.user(use)::Instruction
            u in loop || continue
            if next !== nothing
                remark!(ar, :missed, SIMDLOOP_REMARKS, "NotReductionVar", u) do
                    "not a reduction variable because operation has two internal uses"
                end
                return
            end
            next = u
        end
        if next === nothing
            remark!(ar, :missed, SIMDLOOP_REMARKS, "ChainPrematurelyTerminated", inst) do
                "chain prematurely terminated at ", "Instruction" => inst
            end
            return
        end
        next == phi && break
        if opcode !== nothing
            if reduce_opcode(next, inst) != opcode
                remark!(ar, :missed, SIMDLOOP_REMARKS, "ChainBroke", next) do
                    "chain broke at ", "Instruction" => next, " because of wrong opcode"
                end
                return
            end
        else
            opcode = reduce_opcode(next, inst)
            if opcode === nothing
                remark!(ar, :missed, SIMDLOOP_REMARKS,
                        "FirstArithmeticOpInChainIsUninteresting", next) do
                    "first arithmetic op in chain is uninteresting"
                end
                return
            end
        end
        push!(chain, next)
        inst = next
    end
    for k in chain
        remark!(ar, :passed, SIMDLOOP_REMARKS, "MarkedUnsafeAlgebra", k) do
            "marked unsafe algebra on ", "Instruction" => k
        end
        k.fast_math.reassoc = true
        k.fast_math.contract = true
        if dialect.simdloop_check_combine
            op = k.opcode
            if op == LLVM.Opcode.FAdd || op == LLVM.Opcode.FSub
                ops = k.operands
                check_combine!(ar, loop, ops[1])
                check_combine!(ar, loop, ops[2])
            end
        end
        forget!(se, k)
    end
    return
end

function lower_simdloop!(loop::Loop, ar::LoopAnalysisResults, opts::PassOptions)
    id = loop_id(loop)
    id === nothing && return PreservedAnalyses(AllAnalyses)

    # drop the strings Julia puts in the loop ID, keeping the rest (and the self reference
    # out of it, which is recreated)
    simd = ivdep = false
    ops = Metadata[]
    for op in id.operands[2:end]
        if op isa MDString
            str = convert(String, op)
            if startswith(str, "julia")
                str == "julia.simdloop" && (simd = true)
                str == "julia.ivdep" && (ivdep = true)
                continue
            end
        end
        push!(ops, something(op, LLVM.MDNull()))
    end
    simd || ivdep || return PreservedAnalyses(AllAnalyses)

    # distinct, as in Julia 1.14: Julia 1.13 and older create a uniqued node and then make
    # it refer to itself, which changes any other user of an identical node (e.g. `!{null}`,
    # the type array of a subroutine type without arguments, when every other operand was
    # removed)
    id = MDNode([nothing; ops]; distinct=true)
    id.operands[1] = id
    loop_id!(loop, id)
    remark_loop_flags!(ar, loop, simd, ivdep)

    if ivdep
        # tell LLVM that the iterations are independent through memory, so that
        # `Loop::isAnnotatedParallel` holds
        access = MDNode(Metadata[id])
        for bb in loop.blocks, inst in bb.instructions
            may_read_from_memory(inst) || may_write_to_memory(inst) || continue
            inst.metadata[LLVM.MD_mem_parallel_loop_access] = access
        end
    end

    if simd
        se = ar[ScalarEvolution]
        for inst in loop.header.instructions
            inst isa LLVM.PHIInst || break
            enable_unsafe_algebra_if_reduction!(ar, loop, inst, se, opts.dialect)
        end
        forget_loop_dispositions!(se)
    end

    # only metadata and fast-math flags changed: MemorySSA, the CFG and the loop analyses
    # are still valid
    return PreservedAnalyses(LoopAnalyses, CFGAnalyses, MemorySSA)
end

const LOWER_SIMDLOOP = define_pass("jl-lower-simdloop", :loop, lower_simdloop!;
                                   required=false, cpp_name="LowerSIMDLoop")

"""
    JuliaIR.LowerSIMDLoopPass(; ports=nothing)

Lower the loop markers of Julia's `@simd` (`jl-lower-simdloop` in a pipeline; a loop
pass, for `loop(...)` and `loop-mssa(...)` pipelines). Julia marks the loop ID of a loop
with `julia.simdloop` and, for `@simd ivdep`, `julia.ivdep`. The pass removes these
markers, tags the memory accesses of `ivdep` loops with `!llvm.mem.parallel_loop_access`,
and allows reassociating and contracting the floating-point reductions of `simd` loops.
For the IR of Julia 1.12 and later, it also marks the multiplications that only feed an
addition of a reduction as `contract`. Like Julia's C++ pass, it is skipped on `optnone`
functions.

See [`JuliaIR.Pass`](@ref) for `ports`, which selects this package's port or Julia's
C++ pass.
"""
LowerSIMDLoopPass(; ports::Union{Nothing,Bool}=nothing, kwargs...) =
    make_pass(LOWER_SIMDLOOP, ports; kwargs...)
