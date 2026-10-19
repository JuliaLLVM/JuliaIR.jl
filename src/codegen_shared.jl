# Code that several passes emit the same way, ports of the helpers in Julia's
# `src/llvm-codegen-shared.h`.

# the safepoint page of a thread (`get_current_signal_page_from_ptls`), loaded the way
# `style` (a dialect's `gc_safepoint_load`) says; without TBAA when `tbaa` is `nothing`
function signal_page_from_ptls!(builder::IRBuilder, @nospecialize(ptls::Value),
                                style::Symbol, tls_safepoint::Integer, align::Integer,
                                tbaa::Union{Nothing,MDNode})
    psafepoint = inbounds_gep!(builder, LLVM.Int8Type(), ptls,
                               [ConstantInt(LLVM.Int32Type(), tls_safepoint)],
                               style === :monotonic_named ? "safepoint_addr" : "")
    load = load!(builder, LLVM.PointerType(AS_GENERIC), psafepoint, "safepoint"; align,
                 ordering=style === :plain ? LLVM.API.LLVMAtomicOrderingNotAtomic :
                                             LLVM.API.LLVMAtomicOrderingMonotonic)
    tbaa === nothing || tbaa_decorate!(tbaa, load)
    return load
end

emit_signal_fence!(builder::IRBuilder) =
    fence!(builder, LLVM.API.LLVMAtomicOrderingSequentiallyConsistent; scope="singlethread")

# a safepoint (`emit_gc_safepoint`, not final): a call of `julia.safepoint` on the
# safepoint page, declared in `mod` if needed
function emit_gc_safepoint!(builder::IRBuilder, mod::LLVM.Module, @nospecialize(ptls::Value),
                            style::Symbol, tls_safepoint::Integer, align::Integer,
                            tbaa::Union{Nothing,MDNode})
    signal_page = signal_page_from_ptls!(builder, ptls, style, tls_safepoint, align, tbaa)
    emit_signal_fence!(builder)
    f = get(mod.functions, "julia.safepoint", nothing)
    if f === nothing
        f = LLVM.Function(mod, "julia.safepoint",
                          LLVM.FunctionType(LLVM.VoidType(), [LLVM.PointerType(AS_GENERIC)]))
        push!(f.function_attributes, inaccessible_or_arg_mem_only())
    end
    call!(builder, f.function_type, f, Value[signal_page])
    emit_signal_fence!(builder)
end
