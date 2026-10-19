# DemoteFloat16: perform floating-point arithmetic on `half` and `bfloat` values in
# `float`, extending the operands and truncating the result of every operation, which
# preserves IEEE semantics on targets without native support (where back-ends otherwise
# keep intermediate results in `float`, breaking e.g. Dekker arithmetic). Port of Julia's
# `src/llvm-demote-float16.cpp`; which functions it demotes depends on the dialect
# (`fp16_rule`) unless the `fp16`/`bf16` policies say so explicitly. Unlike the C++ pass,
# the port never consults the host's CPU features (on Julia 1.10 and 1.11, the C++ pass
# uses the JIT's features for functions without `target-features`; in `opt`, and here,
# such functions have none), leaves instructions alone that have nothing to demote (the
# C++ pass recreates every instruction with a 16-bit result type, also when that type is
# kept), and gives the replacement the name of the original.

const DEMOTED_OPCODES = (API.LLVMFNeg, API.LLVMFAdd, API.LLVMFSub, API.LLVMFMul,
                         API.LLVMFDiv, API.LLVMFRem, API.LLVMFCmp)

function string_attribute(f::LLVM.Function, kind::String)
    for attr in f.function_attributes
        attr isa StringAttribute && LLVM.kind(attr) == kind && return LLVM.value(attr)
    end
    return nothing
end

# the architectures of LLVM's `Triple` that the C++ pass checks for, by the names
# `Triple::parseArch` accepts
const PPC_ARCHS = ("powerpc", "powerpcspe", "ppc", "ppc32", "powerpcle", "ppcle", "ppc32le",
                   "powerpc64", "ppu", "ppc64", "powerpc64le", "ppc64le")
const AARCH64_ARCHS = ("aarch64", "arm64", "arm64e", "arm64ec", "aarch64_be", "aarch64_32",
                       "arm64_32")
const X86_64_ARCHS = ("x86_64", "amd64", "x86_64h")

triple_arch(triple::String) = first(split(triple, '-'))

# whether a type is kept (`true`) or demoted, according to the policy or to the rule of
# the Julia version
function keeps_fp16(f::LLVM.Function, triple::String, dialect::Dialect)
    dialect.fp16 === :keep && return true
    dialect.fp16 === :demote && return false
    if dialect.fp16_rule === :attributes
        attr = string_attribute(f, "julia.hasfp16")
        attr === nothing || return attr == "true"
        # half uses excessive precision on PowerPC (llvm/llvm-project#97975)
        return !(triple_arch(triple) in PPC_ARCHS)
    else
        features = something(string_attribute(f, "target-features"), "")
        arch = triple_arch(triple)
        if arch in AARCH64_ARCHS
            (occursin("+fp16fml", features) || occursin("+fullfp16", features)) &&
                return true
        elseif arch in X86_64_ARCHS
            occursin("+avx512fp16", features) && return true
        end
        return string_attribute(f, "julia.hasfp16") !== nothing
    end
end

function keeps_bf16(f::LLVM.Function, dialect::Dialect)
    dialect.bf16 === :keep && return true
    dialect.bf16 === :demote && return false
    if dialect.fp16_rule === :attributes
        # bfloat is always promoted in software by LLVM's back-ends
        # (llvm/llvm-project#97975), so its arithmetic is kept
        attr = string_attribute(f, "julia.hasbf16")
        return attr === nothing || attr == "true"
    elseif dialect.fp16_rule === :target_features_bf16
        return string_attribute(f, "julia.hasbf16") !== nothing
    else
        # Julia 1.10 doesn't demote bfloat
        return true
    end
end

# The kind of the scalar type of `ty`, and a type of the same shape with `float` scalars.
# Types are handled as references: LLVM.jl doesn't wrap scalable vector types.
function scalar_type_kind(ty::API.LLVMTypeRef)
    kind = API.LLVMGetTypeKind(ty)
    if kind == API.LLVMVectorTypeKind || kind == API.LLVMScalableVectorTypeKind
        kind = API.LLVMGetTypeKind(API.LLVMGetElementType(ty))
    end
    return kind
end

function float_type(ty::API.LLVMTypeRef, T_float::API.LLVMTypeRef)
    kind = API.LLVMGetTypeKind(ty)
    kind == API.LLVMVectorTypeKind && return API.LLVMVectorType(T_float, API.LLVMGetVectorSize(ty))
    kind == API.LLVMScalableVectorTypeKind &&
        return API.LLVMScalableVectorType(T_float, API.LLVMGetVectorSize(ty))
    return T_float
end

typeref(@nospecialize(v::Value)) = API.LLVMTypeOf(v)

function demote_float16!(f::LLVM.Function, am, opts::PassOptions)
    dialect = opts.dialect
    triple = f.parent.triple
    keep_fp16 = keeps_fp16(f, triple, dialect)
    keep_bf16 = keeps_bf16(f, dialect)
    keep_fp16 && keep_bf16 && return PreservedAnalyses(AllAnalyses)

    T_float = API.LLVMFloatTypeInContext(context(f))
    function demoted(@nospecialize(v::Value))
        kind = scalar_type_kind(typeref(v))
        return (!keep_fp16 && kind == API.LLVMHalfTypeKind) ||
               (!keep_bf16 && kind == API.LLVMBFloatTypeKind)
    end

    erase = Instruction[]
    @dispose builder=IRBuilder() begin
        for bb in f.blocks, inst in bb.instructions
            opcode = API.LLVMGetInstructionOpcode(inst)
            opcode in DEMOTED_OPCODES || continue
            ops = inst.operands
            any(demoted, ops) || continue
            # skip `@fastmath` operations
            inst.fast_math.fast && continue

            position!(builder, LLVM.before(inst))
            builder.debug_location = inst.debug_location
            args = map(ops) do op
                demoted(op) || return op
                Value(API.LLVMBuildFPExt(builder, op, float_type(typeref(op), T_float), ""))
            end
            new = if opcode == API.LLVMFNeg
                fneg!(builder, args[1])
            elseif opcode == API.LLVMFCmp
                fcmp!(builder, inst.predicate, args[1], args[2])
            elseif opcode == API.LLVMFAdd
                fadd!(builder, args[1], args[2])
            elseif opcode == API.LLVMFSub
                fsub!(builder, args[1], args[2])
            elseif opcode == API.LLVMFMul
                fmul!(builder, args[1], args[2])
            elseif opcode == API.LLVMFDiv
                fdiv!(builder, args[1], args[2])
            else
                frem!(builder, args[1], args[2])
            end
            # IRBuilder folds constant operands; only new instructions get the metadata
            # and flags of the original
            if new isa Instruction
                copy_metadata!(new, inst)
                new.fast_math = inst.fast_math
            end
            if typeref(new) != typeref(inst)
                new = Value(API.LLVMBuildFPTrunc(builder, new, typeref(inst), ""))
            end
            new isa Instruction && take_name!(new, inst)
            replace_uses!(inst, new)
            push!(erase, inst)
        end
    end
    isempty(erase) && return PreservedAnalyses(AllAnalyses)
    foreach(erase!, erase)
    return PreservedAnalyses(CFGAnalyses)
end

const DEMOTE_FLOAT16 = define_pass("jl-demote-float16", :function, demote_float16!;
                                   required=true, cpp_name="DemoteFloat16")

"""
    JuliaIR.DemoteFloat16Pass(; fp16=:auto, bf16=:auto)

Perform floating-point arithmetic on `half` (`fp16`) and `bfloat` (`bf16`) values in
`float`, truncating every result, so that the IEEE semantics of the 16-bit types are
preserved on targets that don't support them natively (`jl-demote-float16` in a
pipeline). Whether a type is demoted is decided by the policies: `:demote` and `:keep`
apply to every function, `:auto` follows the rule of the Julia version, which reads the
function's `target-features` (Julia 1.10, 1.11) or `julia.hasfp16`/`julia.hasbf16`
attributes (1.12 and later; without them, `half` is demoted only on PowerPC and `bfloat`
is kept). Operations with all fast-math flags are left alone.

Meant to run late in the pipeline, not followed by `instcombine` (which would fold the
conversions away); `gvn` can clean up redundant conversions. Like Julia's C++ pass, it
is required, so it also runs on `optnone` functions, whose semantics it affects.
"""
DemoteFloat16Pass(; kwargs...) = custom_pass(DEMOTE_FLOAT16; kwargs...)
