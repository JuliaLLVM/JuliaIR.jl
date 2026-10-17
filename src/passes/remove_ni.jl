# RemoveNI: remove the non-integral address spaces from the data layout (`-ni:10:11:12:13`),
# which Julia declares so that LLVM doesn't introduce integer casts of GC-tracked pointers,
# but which back-ends don't know about. Port of Julia's `src/llvm-remove-ni.cpp`, which
# has not changed since Julia 1.10.

function remove_ni!(mod::LLVM.Module, am, opts::PassOptions)
    layout = unsafe_string(API.LLVMGetDataLayoutStr(mod))
    # like the C++ pass, remove the first `-ni:...` component only
    range = findfirst("-ni:", layout)
    range === nothing && return PreservedAnalyses(AllAnalyses)
    stop = something(findnext('-', layout, last(range)), lastindex(layout) + 1)
    mod.datalayout = layout[1:first(range)-1] * layout[stop:end]
    return PreservedAnalyses(CFGAnalyses)
end

const REMOVE_NI = define_pass("jl-remove-ni", :module, remove_ni!; required=true,
                              cpp_name="RemoveNI")

"""
    JuliaIR.RemoveNIPass(; julia=VERSION)

Remove the non-integral address spaces from the data layout of a module (`jl-remove-ni`
in a pipeline). Needed before code generation by back-ends that don't support
non-integral pointers.
"""
RemoveNIPass(; kwargs...) = custom_pass(REMOVE_NI; kwargs...)
