# Write a corpus of unoptimized GPUCompiler modules (`GPUCompiler.compile(:llvm, job)` with
# `optimize=false, cleanup=false`): close to the IR GPUCompiler hands to its optimization
# pipeline, which runs Julia's passes (or JuliaIR's ports) on it, except that the target's
# `finish_ir!`, which follows the optimizer, has run too. One module per kernel and target (PTX, GCN,
# SPIR-V, Metal, and native code without the Julia runtime), in OUTDIR/<target>/.
#
#   julia --project=test/differential/gpucompiler test/differential/gpucompiler/corpus.jl OUTDIR [TARGET...]
#
# TARGETs are ptx, gcn, spirv, metal and native (default: all). GPUCompiler can crash while
# compiling for one target (GCN on Julia 1.10 and 1.11), so all.sh runs one per process.
#
# This environment is separate from JuliaIR's: GPUCompiler brings its own (registered)
# LLVM.jl, and only the IR text crosses over.

using GPUCompiler, LLVM

module Runtime
    signal_exception() = return
    malloc(sz) = ccall("extern gpu_malloc", llvmcall, Ptr{Nothing}, (Csize_t,), sz)
    report_oom(sz) = return
    report_exception(ex) = return
    report_exception_name(ex) = return
    report_exception_frame(idx, func, file, line) = return
end

struct Params <: AbstractCompilerParams end
GPUCompiler.runtime_module(::CompilerJob{<:Any,Params}) = Runtime

const TARGETS = Dict(
    "ptx" => () -> PTXCompilerTarget(; cap=v"7.0"),
    "gcn" => () -> GCNCompilerTarget(; dev_isa="gfx900", backend=:inprocess),
    "spirv" => () -> SPIRVCompilerTarget(; backend=:khronos),
    "metal" => () -> MetalCompilerTarget(; macos=v"12.2", metal=v"3.0", air=v"3.0"),
    "native" => () -> NativeCompilerTarget(; jlruntime=false),
)

## kernels

mutable struct Box
    x::Int
end
struct Point
    x::Float32
    y::Float32
end

function vadd(a::Ptr{Float32}, b::Ptr{Float32}, c::Ptr{Float32}, i::Int)
    unsafe_store!(c, unsafe_load(a, i) + unsafe_load(b, i), i)
    return
end
function alloc_local(p::Ptr{Int}, v::Int)
    b = Box(v)
    b.x += 1
    unsafe_store!(p, b.x)
    return
end
@noinline function bump(b::Box)
    b.x += 1
    return
end
function alloc_call(p::Ptr{Int}, v::Int)
    b = Box(v)
    bump(b)
    unsafe_store!(p, b.x)
    return
end
function alloc_objref(p::Ptr{Int}, v::Int)
    r = Ref(v)
    GC.@preserve r begin
        unsafe_store!(p, unsafe_load(Ptr{Int}(pointer_from_objref(r))))
    end
    return
end
function alloc_tuple(p::Ptr{Float32}, x::Float32)
    r = Ref(Point(x, 2x))
    unsafe_store!(p, r[].x + r[].y)
    return
end
function simd_sum(p::Ptr{Float32}, n::Int, out::Ptr{Float32})
    acc = 0f0
    @simd for i in 1:n
        acc += unsafe_load(p, i)
    end
    unsafe_store!(out, acc)
    return
end
function simd_ivdep(p::Ptr{Float32}, q::Ptr{Float32}, n::Int)
    @simd ivdep for i in 1:n
        unsafe_store!(q, 2f0 * unsafe_load(p, i), i)
    end
    return
end
function preserve(p::Ptr{Int}, v::Int)
    r = Ref(v)
    GC.@preserve r begin
        unsafe_store!(p, unsafe_load(Base.unsafe_convert(Ptr{Int}, r)))
    end
    return
end
function atomic_add(p::Ptr{Int}, v::Int)
    Core.Intrinsics.atomic_pointermodify(p, +, v, :monotonic)
    return
end
function atomic_max(p::Ptr{Int32}, v::Int32)
    Core.Intrinsics.atomic_pointermodify(p, max, v, :sequentially_consistent)
    return
end
function atomic_fadd(p::Ptr{Float32}, v::Float32)
    Core.Intrinsics.atomic_pointermodify(p, +, v, :monotonic)
    return
end
function atomic_cas(p::Ptr{Int}, o::Int, n::Int)
    Core.Intrinsics.atomic_pointerreplace(p, o, n, :acquire_release, :monotonic)
    return
end
function checked(p::Ptr{Int}, i::Int)
    i > 0 || throw(BoundsError())
    unsafe_store!(p, i)
    return
end
function div_error(p::Ptr{Int}, a::Int, b::Int)
    unsafe_store!(p, div(a, b))
    return
end
function f16_math(p::Ptr{Float16}, a::Float16, b::Float16)
    unsafe_store!(p, a * b + Float16(1))
    return
end
function f16_mixed(p::Ptr{Float32}, a::Float16)
    unsafe_store!(p, Float32(a * a) + 1f0)
    return
end
function closure(p::Ptr{Float32}, x::Float32)
    f = y -> x * y
    unsafe_store!(p, f(2f0))
    return
end
function fma_like(p::Ptr{Float64}, a::Float64, b::Float64, c::Float64)
    unsafe_store!(p, a * b + c)
    return
end

const KERNELS = [
    (vadd, (Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Int)),
    (alloc_local, (Ptr{Int}, Int)), (alloc_call, (Ptr{Int}, Int)),
    (alloc_objref, (Ptr{Int}, Int)),
    (alloc_tuple, (Ptr{Float32}, Float32)),
    (simd_sum, (Ptr{Float32}, Int, Ptr{Float32})),
    (simd_ivdep, (Ptr{Float32}, Ptr{Float32}, Int)),
    (preserve, (Ptr{Int}, Int)),
    (atomic_add, (Ptr{Int}, Int)), (atomic_max, (Ptr{Int32}, Int32)),
    (atomic_fadd, (Ptr{Float32}, Float32)), (atomic_cas, (Ptr{Int}, Int, Int)),
    (checked, (Ptr{Int}, Int)), (div_error, (Ptr{Int}, Int, Int)),
    (f16_math, (Ptr{Float16}, Float16, Float16)), (f16_mixed, (Ptr{Float32}, Float16)),
    (closure, (Ptr{Float32}, Float32)),
    (fma_like, (Ptr{Float64}, Float64, Float64, Float64)),
]

function main(out, targets=sort(collect(keys(TARGETS))))
    n = 0
    for tname in targets
        target = TARGETS[tname]
        dir = joinpath(out, tname)
        mkpath(dir)
        for (f, types) in KERNELS
            name = string(nameof(f))
            source = methodinstance(typeof(f), Tuple{types...})
            config = CompilerConfig(target(), Params(); kernel=true, optimize=false,
                                    cleanup=false, validate=false)
            job = CompilerJob(source, config)
            ir = try
                JuliaContext() do ctx
                    mod, meta = GPUCompiler.compile(:llvm, job)
                    s = string(mod)
                    LLVM.dispose(mod)
                    s
                end
            catch err
                println("skipped $tname/$name: ", first(sprint(showerror, err), 300))
                continue
            end
            write(joinpath(dir, "$name.ll"), ir)
            n += 1
        end
    end
    println("wrote $n modules to $out")
end

isinteractive() || main(ARGS[1], isempty(ARGS[2:end]) ? sort(collect(keys(TARGETS))) : ARGS[2:end])
