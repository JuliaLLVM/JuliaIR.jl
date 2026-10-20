# The first process of the IR-crossing test (test/crossing.jl): with Julia's own LLVM, and
# without LLVM.jl, write a module in bitcode whose types are Julia's lowering of the
# corpus, with functions that compute their layout, and what Julia and its LLVM know
# about that layout.
#
#   julia writer.jl OUTDIR      (writes OUTDIR/crossing.bc and OUTDIR/crossing.toml)

using InteractiveUtils: code_llvm
using Libdl

include(joinpath(@__DIR__, "corpus.jl"))
using .CrossingCorpus: TYPES

const libllvm = Base.libllvm_path()

toml_list(v) = "[" * join(Int.(v), ", ") * "]"

function main(outdir)
    # the data layout and triple of the modules that Julia's code generator creates
    ir = sprint(io -> code_llvm(io, identity, (Int,); raw=true, dump_module=true))
    datalayout = match(r"target datalayout = \"([^\"]*)\"", ir)[1]
    triple = match(r"target triple = \"([^\"]*)\"", ir)[1]

    ctx = ccall((:LLVMContextCreate, libllvm), Ptr{Cvoid}, ())
    # the module is written with opaque pointers, which a context of LLVM 15 or 16 (Julia
    # 1.10, 1.11) may not have by default
    opaque = dlsym(dlopen(libllvm), :LLVMContextSetOpaquePointers; throw_error=false)
    opaque === nothing || ccall(opaque, Cvoid, (Ptr{Cvoid}, Cint), ctx, true)
    td = ccall((:LLVMCreateTargetData, libllvm), Ptr{Cvoid}, (Cstring,), datalayout)
    toml = IOBuffer()
    println(toml, "datalayout = ", repr(datalayout))
    println(toml, "triple = ", repr(triple))
    println(toml, "llvm = ", repr(string(Base.libllvm_version)))
    # datalayout before triple, as Julia prints modules: the text keeps the layout as is
    src = IOBuffer()
    println(src, "target datalayout = \"$datalayout\"")
    println(src, "target triple = \"$triple\"")
    for (i, (T, per_field)) in enumerate(TYPES)
        boxed = Ref{Bool}(false)
        ty = ccall(:jl_type_to_llvm, Ptr{Cvoid}, (Any, Ptr{Cvoid}, Ptr{Bool}), T, ctx, boxed)
        boxed[] && error("$T is boxed")
        str = unsafe_string(ccall((:LLVMPrintTypeToString, libllvm), Cstring, (Ptr{Cvoid},), ty))
        n = ccall((:LLVMCountStructElementTypes, libllvm), Cuint, (Ptr{Cvoid},), ty)
        offsets = [Int(ccall((:LLVMOffsetOfElement, libllvm), Culonglong, (Ptr{Cvoid}, Ptr{Cvoid}, Cuint), td, ty, k))
                   for k in 0:n-1]
        size = Int(ccall((:LLVMABISizeOfType, libllvm), Culonglong, (Ptr{Cvoid}, Ptr{Cvoid}), td, ty))
        align = Int(ccall((:LLVMABIAlignmentOfType, libllvm), Cuint, (Ptr{Cvoid}, Ptr{Cvoid}), td, ty))

        println(toml, "\n[[types]]")
        println(toml, "name = ", repr(string(T)))
        println(toml, "type = ", repr(str))
        println(toml, "offsets = ", toml_list(offsets))
        println(toml, "size = ", size)
        println(toml, "align = ", align)
        println(toml, "julia_size = ", sizeof(T))
        println(toml, "julia_align = ", Base.datatype_alignment(T))
        println(toml, "julia_offsets = ", toml_list(per_field ? fieldoffset.(T, 1:fieldcount(T)) : []))

        # the type, and its layout as the optimizer folds it
        println(src, "declare void @type_$i($str)")
        println(src, """
            define i64 @size_$i() {
              %p = getelementptr $str, ptr null, i64 1
              %s = ptrtoint ptr %p to i64
              ret i64 %s
            }""")
        for k in 0:n-1
            println(src, """
                define i64 @offset_$(i)_$k() {
                  %p = getelementptr $str, ptr null, i32 0, i32 $k
                  %o = ptrtoint ptr %p to i64
                  ret i64 %o
                }""")
        end
    end

    text = String(take!(src))
    buf = ccall((:LLVMCreateMemoryBufferWithMemoryRangeCopy, libllvm), Ptr{Cvoid},
               (Ptr{UInt8}, Csize_t, Cstring), text, sizeof(text), "crossing")
    mod = Ref{Ptr{Cvoid}}(C_NULL)
    msg = Ref{Cstring}(C_NULL)
    ccall((:LLVMParseIRInContext, libllvm), Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Ptr{Cvoid}}, Ptr{Cstring}),
         ctx, buf, mod, msg) == 0 || error(unsafe_string(msg[]))
    ccall((:LLVMWriteBitcodeToFile, libllvm), Cint, (Ptr{Cvoid}, Cstring), mod[],
         joinpath(outdir, "crossing.bc")) == 0 || error("could not write the bitcode")
    write(joinpath(outdir, "crossing.toml"), take!(toml))
end

main(ARGS[1])
