# CombineMulAdd: mark the `fmul` feeding an `fadd`/`fsub` that allows contraction as
# `contract` too, so that the back-end can fuse the two into a multiply-add. Port of
# Julia's `src/llvm-muladd.cpp`, which is the same in 1.10 and 1.11. Julia 1.12 removed
# the pass (JuliaLang/julia#55802; LowerSIMDLoop marks the multiplications feeding
# reductions instead, `Dialect.simdloop_check_combine`), so for later dialects the port
# does nothing. The pass reads no target information: whether to fuse is left to the
# back-end.

# whether `v` has exactly one use (C++'s `hasOneUse`: `fadd %m, %m` uses `%m` twice)
function has_one_use(@nospecialize(v::Value))
    use = API.LLVMGetFirstUse(v)
    return use != C_NULL && API.LLVMGetNextUse(use) == C_NULL
end

# Mark `op` as `contract` if it is an `fmul` that only feeds the addition; return whether
# it changed.
function check_combine!(am, @nospecialize(op::Value))
    op isa Instruction && API.LLVMGetInstructionOpcode(op) == API.LLVMFMul || return false
    if !has_one_use(op)
        # the C++ pass renders the instruction argument as its opcode name
        am === nothing ||
            remark!(am, :missed, "combine-muladd", "Multiuse FMul", op,
                    "fmul had multiple uses fmul")
        return false
    end
    op.fast_math.contract && return false
    am === nothing ||
        remark!(am, :passed, "combine-muladd", "Marked for FMA", op, "marked for fma fmul")
    op.fast_math.contract = true
    return true
end

function combine_muladd!(f::LLVM.Function, am, opts::PassOptions)
    opts.dialect.has_combine_muladd || return PreservedAnalyses(AllAnalyses)
    changed = false
    for bb in f.blocks, inst in bb.instructions
        opcode = API.LLVMGetInstructionOpcode(inst)
        opcode == API.LLVMFAdd || opcode == API.LLVMFSub || continue
        inst.fast_math.contract || continue
        # like the C++ pass, the second operand is only considered when the first one
        # wasn't changed
        ops = inst.operands
        changed |= check_combine!(am, ops[1]) || check_combine!(am, ops[2])
    end
    return changed ? PreservedAnalyses(CFGAnalyses) : PreservedAnalyses(AllAnalyses)
end

const COMBINE_MULADD = define_pass("jl-combine-muladd", :function, combine_muladd!;
                                   required=false, cpp_name="CombineMulAdd")

"""
    JuliaIR.CombineMulAddPass(; julia=VERSION)

Allow the back-end to fuse a multiplication and the addition or subtraction it feeds into
a multiply-add (`jl-combine-muladd` in a pipeline): when an `fadd` or `fsub` has the
`contract` fast-math flag and one of its operands is an `fmul` without other uses, that
`fmul` is marked `contract` too (if both operands qualify, only the first). Julia 1.12
removed the pass, so it does nothing for the IR of Julia 1.12 and later. Like Julia's C++
pass, it is skipped on `optnone` functions.
"""
CombineMulAddPass(; kwargs...) = custom_pass(COMBINE_MULADD; kwargs...)
