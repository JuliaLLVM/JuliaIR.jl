# DemoteFloat16: perform floating-point arithmetic on `half` and `bfloat` values in
# `float`, extending the operands and truncating the result of every operation, which
# preserves IEEE semantics on targets without native support (where back-ends otherwise
# keep intermediate results in `float`, breaking e.g. Dekker arithmetic). Port of Julia's
# `src/llvm-demote-float16.cpp`; which functions it demotes depends on the dialect
# (`fp16_rule`) unless the `fp16`/`bf16` policies say so explicitly. Unlike the C++ pass,
# the port leaves instructions alone that have nothing to demote (the C++ pass recreates
# every instruction with a 16-bit result type, also when that type is kept), and gives
# the replacement the name of the original.

const DEMOTED_OPCODES = (API.LLVMFNeg, API.LLVMFAdd, API.LLVMFSub, API.LLVMFMul,
                         API.LLVMFDiv, API.LLVMFRem, API.LLVMFCmp)

function string_attribute(f::LLVM.Function, kind::String)
    attr = get(f.function_attributes, kind, nothing)
    return attr === nothing ? nothing : LLVM.value(attr)
end

# whether a type is kept (`true`) or demoted, according to the policy or to the rule of
# the Julia version
function keeps_fp16(f::LLVM.Function, triple::String, dialect::Dialect, jit_features::Bool)
    dialect.fp16 === :keep && return true
    dialect.fp16 === :demote && return false
    if dialect.fp16_rule === :attributes
        attr = string_attribute(f, "julia.hasfp16")
        attr === nothing || return attr == "true"
        # half uses excessive precision on PowerPC (llvm/llvm-project#97975)
        return !LLVM.isppc(LLVM.Triple(triple))
    else
        features = string_attribute(f, "target-features")
        tt = LLVM.Triple(triple)
        # without the attribute, the C++ pass searches the JIT's feature string (none in
        # `opt`)
        features === nothing && jit_features && jit_keeps_fp16(tt, dialect) && return true
        features = something(features, "")
        if LLVM.isaarch64(tt)
            (occursin("+fp16fml", features) || occursin("+fullfp16", features)) &&
                return true
        elseif tt.arch === :x86_64
            occursin("+avx512fp16", features) && return true
        end
        return string_attribute(f, "julia.hasfp16") !== nothing
    end
end

# What the C++ pass of Julia 1.10 and 1.11 decides with the JIT's feature string, which
# Julia doesn't export: like for the code Julia generates for `Float16` arithmetic, if
# the module is for the JIT's architecture (the string only has features of that one).
# For IR of another Julia version than the running one, there is no JIT to ask.
function jit_keeps_fp16(tt::LLVM.Triple, dialect::Dialect)
    dialect.minor == dialect_minor(VERSION) || return false
    (LLVM.isaarch64(tt) || tt.arch === :x86_64) || return false
    try
        jit = LLVM.Triple(native_probe(:jit_target).triple)
        same_arch = LLVM.isaarch64(tt) ? LLVM.isaarch64(jit) : jit.arch === :x86_64
        return same_arch && native_probe(:jit_fp16)
    catch err
        err isa RuntimeError || rethrow()
        throw(RuntimeError("cannot tell whether the JIT of the running $(running_julia()) has native Float16 arithmetic: $(err.msg); ignore its features with the option no-jit-features"))
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
    keep_fp16 = keeps_fp16(f, triple, dialect, opts.extra.jit_features)
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
                                   required=true, extra=(; jit_features=true),
                                   cpp_name="DemoteFloat16")

"""
    JuliaIR.DemoteFloat16Pass(; fp16=:auto, bf16=:auto, jit_features=true)

Perform floating-point arithmetic on `half` (`fp16`) and `bfloat` (`bf16`) values in
`float`, truncating every result, so that the IEEE semantics of the 16-bit types are
preserved on targets that don't support them natively (`jl-demote-float16` in a
pipeline). Whether a type is demoted is decided by the policies: `:demote` and `:keep`
apply to every function, `:auto` follows the rule of the Julia version, which reads the
function's `target-features` (Julia 1.10, 1.11) or `julia.hasfp16`/`julia.hasbf16`
attributes (1.12 and later; without them, `half` is demoted only on PowerPC and `bfloat`
is kept). Operations with all fast-math flags are left alone.

For a function without `target-features`, Julia 1.10 and 1.11 use the features of
Julia's JIT, as the C++ pass does in Julia's pipeline: `half` is kept if the JIT
compiles `Float16` arithmetic natively and the module is for its architecture. That
only applies to IR of the running Julia version; `jit_features=false`
(`no-jit-features` in a pipeline) ignores the JIT, like the C++ pass in `opt`.

Meant to run late in the pipeline, not followed by `instcombine` (which would fold the
conversions away); `gvn` can clean up redundant conversions. Like Julia's C++ pass, it
is required, so it also runs on `optnone` functions, whose semantics it affects.
"""
DemoteFloat16Pass(; kwargs...) = custom_pass(DEMOTE_FLOAT16; kwargs...)
