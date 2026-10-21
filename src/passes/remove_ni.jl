# RemoveNI: remove the non-integral address spaces from the data layout (`-ni:10:11:12:13`),
# which Julia declares so that LLVM doesn't introduce integer casts of GC-tracked pointers,
# but which back-ends don't know about. Port of Julia's `src/llvm-remove-ni.cpp`, which
# has not changed since Julia 1.10. Also handle `ni` as the first layout component,
# which the C++ pass misses because it searches for a preceding hyphen.

function remove_ni!(mod::LLVM.Module, am, opts::PassOptions)
    layout = string(mod.datalayout)
    # like the C++ pass, remove the first `ni:...` component only
    components = split(layout, '-')
    idx = findfirst(startswith("ni:"), components)
    idx === nothing && return PreservedAnalyses(AllAnalyses)
    deleteat!(components, idx)
    mod.datalayout = join(components, '-')
    return PreservedAnalyses(CFGAnalyses)
end

const REMOVE_NI = define_pass("jl-remove-ni", :module, remove_ni!; required=true,
                              cpp_name="RemoveNI")

"""
    JuliaIR.RemoveNIPass()

Remove the non-integral address spaces from the data layout of a module (`jl-remove-ni`
in a pipeline). Needed before code generation by back-ends that don't support
non-integral pointers.
"""
RemoveNIPass(; kwargs...) = custom_pass(REMOVE_NI; kwargs...)
