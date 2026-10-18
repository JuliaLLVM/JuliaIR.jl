# Write a corpus of unoptimized IR of the running Julia, as Julia's code generator hands it
# to the optimizer (`code_llvm(...; optimize=false, raw=true, dump_module=true)`), one module
# per function, with (`NAME.dbg.ll`) and without (`NAME.ll`) debug information.
#
#   julia --project=test/differential test/differential/corpus.jl OUTDIR

using InteractiveUtils

## GC stacks, allocations and write barriers

mutable struct MBox
    x::Any
    y::Int
end
mutable struct Two
    a::Int
    b::Int
end
struct Pair2
    a::Any
    b::Any
end
mutable struct RefPair
    a::Any
    b::Any
end

alloc_ref(x) = Ref(x)
alloc_ref_load(x) = Ref(x)[]
alloc_vec(n) = [i for i in 1:n]
alloc_mut(x) = MBox(x, 1)
alloc_mut_field(x) = (b = MBox(x, 1); b.y + 1)
alloc_two(x) = (t = Two(x, x + 1); t.a * t.b)
alloc_refpair(x, y) = (p = RefPair(x, y); GC.@preserve p (p.a, p.b))
function alloc_loop(n)
    s = 0
    for i in 1:n
        r = Ref(i)
        s += r[]
    end
    s
end
function alloc_push(n)
    acc = Any[]
    for i in 1:n
        push!(acc, Ref(i))
    end
    acc
end
typeof_alloc(x) = typeof(Ref(x))
tuple_box(x) = (Ref((x, x))[])[1]
partial_init(x::Int) = (r = Ref{NTuple{3,Int}}(); r[] = (x, x, x); r[][2])
barrier_set(b::MBox, v) = (b.x = v; nothing)
barrier_vec(a::Vector{Any}, v) = (a[1] = v; nothing)
dyn_call(x) = x + 1
typeof_any(x) = typeof(x)
union_ret(x::Int) = x > 0 ? x : nothing
function loop_any(a::Vector{Any})
    s = 0
    for x in a
        s += x::Int
    end
    s
end
function pairs_any(a::Vector{Any}, b::Vector{Any})
    @inbounds for i in 1:2:length(a)-1
        b[i] = a[i]
        b[i+1] = a[i+1]
    end
    b
end
tuple_any(x, y) = (x, y)
struct_any(x, y) = Pair2(x, y)
function phi_any(c::Bool, x, y)
    z = c ? Ref(x) : Ref(y)
    z[]
end
ptr_objref(x::MBox) = pointer_from_objref(x)
function many_live(x, y, z)
    a = Ref(x); b = Ref(y); c = Ref(z)
    println(a); println(b)
    (a, b, c)
end
string_concat(a::String, b::String) = a * b
dict_get(d::Dict{Any,Any}, k) = get(d, k, nothing)
arrays_of_any(n) = fill!(Vector{Any}(undef, n), nothing)
sum_tuple(t::NTuple{4,Any}) = t[1] === t[2] ? t[3] : t[4]
vector_sel(c::Bool, a::Vector{Any}) = c ? a[1] : a[2]
@static if VERSION >= v"1.12-"
    gc_safe_call() = @ccall gc_safe=true usleep(0::Cuint)::Cint
else
    gc_safe_call() = @ccall usleep(0::Cuint)::Cint
end

## GC.@preserve

function preserve_load(a::Vector{Int})
    GC.@preserve a begin
        unsafe_load(pointer(a))
    end
end
function preserve_ref(x)
    r = Ref{Any}(x)
    GC.@preserve r ccall(:jl_breakpoint, Cvoid, (Any,), r[])
end
function preserve_loop(a::Vector{Float64})
    s = 0.0
    GC.@preserve a for i in 1:length(a)
        s += unsafe_load(pointer(a), i)
    end
    s
end

## exceptions

@noinline maybe_throw(x) = x > 0 ? x : error("negative")
@noinline nothing_call() = nothing
try_simple(x) = try maybe_throw(x) catch; 0 end
try_finally(x) = try maybe_throw(x) finally nothing_call() end
try_catch_var(x) = try maybe_throw(x) catch e; e isa ErrorException ? -1 : -2 end
try_nested(x) = try
        try maybe_throw(x) catch; maybe_throw(-x) end
    catch
        0
    end
function try_loop(xs)
    s = 0
    for x in xs
        try
            x == 3 && break
            s += maybe_throw(x)
        catch
            return -1
        end
    end
    s
end
function try_return(x)
    try
        x > 1 && return maybe_throw(x)
        maybe_throw(-x)
    catch
        0
    end
end
try_rethrow(x) = try maybe_throw(x) catch; rethrow() end
throws(x) = x > 0 ? x : throw(ArgumentError("negative"))
lock_call(l::ReentrantLock, x) = lock(() -> maybe_throw(x), l)

## @simd

function simd_sum(xs)
    acc = zero(eltype(xs))
    @simd for x in xs
        acc += x
    end
    acc
end
function simd_sum_ivdep(xs)
    acc = zero(eltype(xs))
    @simd ivdep for x in xs
        acc += x
    end
    acc
end
function simd_dot(xs, ys)
    acc = zero(eltype(xs))
    @simd for i in eachindex(xs, ys)
        @inbounds acc += xs[i] * ys[i]
    end
    acc
end
function simd_sub(xs)
    acc = zero(eltype(xs))
    @simd for x in xs
        acc -= x * x
    end
    acc
end
function simd_axpy!(y, a, x)
    @simd ivdep for i in eachindex(x, y)
        @inbounds y[i] = muladd(a, x[i], y[i])
    end
    y
end
function simd_nested(A)
    acc = zero(eltype(A))
    for j in axes(A, 2)
        @simd for i in axes(A, 1)
            @inbounds acc += A[i, j]
        end
    end
    acc
end
function simd_minmax(xs)
    m = typemax(eltype(xs))
    @simd for x in xs
        m = min(m, x)
    end
    m
end
plain_loop(xs) = (s = zero(eltype(xs)); for x in xs; s += x; end; s)
fma_like(a, b, c) = a * b + c
fma_contract(a, b, c) = @fastmath a * b + c
muladd_call(a, b, c) = muladd(a, b, c)

## atomics

mutable struct AtomicInt
    @atomic x::Int
end
mutable struct AtomicFloat
    @atomic x::Float64
end
mutable struct AtomicAny
    @atomic x::Any
end
double_plus(x, y) = 2x + y
atomic_add(a::AtomicInt, v) = @atomic a.x += v
atomic_max(a::AtomicInt, v) = @atomic a.x max v
atomic_custom(a::AtomicInt, v) = @atomic a.x double_plus v
atomic_mono(a::AtomicInt, v) = @atomic :monotonic a.x += v
atomic_fadd(a::AtomicFloat, v) = @atomic a.x += v
atomic_any(a::AtomicAny, v) = @atomic a.x += v
atomic_swap(a::AtomicInt, v) = @atomicswap a.x = v
atomic_replace(a::AtomicInt, o, n) = @atomicreplace a.x o => n
atomic_load(a::AtomicInt) = @atomic a.x
atomic_ptr_add(p::Ptr{Int}, v) = Core.Intrinsics.atomic_pointermodify(p, +, v, :sequentially_consistent)
function atomic_loop(a::AtomicInt, n)
    for i in 1:n
        @atomic a.x += i
    end
end

## Float16

f16_add(a::Float16, b::Float16) = a + b
f16_mix(a::Float16, b::Float16, c::Float32) = Float32(a * b) + c
f16_vec(a::Vector{Float16}) = sum(a)
f16_cmp(a::Float16, b::Float16) = a < b ? a - b : sqrt(a)
f16_tuple(t::NTuple{4,Float16}) = t .* Float16(2)

## closures

make_closure(x) = () -> x
make_adder(x) = y -> x + y
call_closure(f, x) = f(x)
function boxed_capture(n)
    s = 0
    foreach(i -> (s += i), 1:n)
    s
end

const CORPUS = Any[
    (alloc_ref, (Any,)), (alloc_ref, (Int,)), (alloc_ref_load, (Int,)), (alloc_vec, (Int,)),
    (alloc_mut, (Any,)), (alloc_mut_field, (Any,)), (alloc_two, (Int,)),
    (alloc_refpair, (Any, Any)), (alloc_loop, (Int,)), (alloc_push, (Int,)),
    (typeof_alloc, (Int,)), (tuple_box, (Int,)), (partial_init, (Int,)),
    (barrier_set, (MBox, Any)), (barrier_vec, (Vector{Any}, Any)), (dyn_call, (Any,)),
    (typeof_any, (Any,)), (union_ret, (Int,)), (loop_any, (Vector{Any},)),
    (pairs_any, (Vector{Any}, Vector{Any})), (tuple_any, (Any, Any)),
    (struct_any, (Any, Any)), (phi_any, (Bool, Any, Any)), (ptr_objref, (MBox,)),
    (many_live, (Any, Any, Any)), (string_concat, (String, String)),
    (dict_get, (Dict{Any,Any}, Any)), (arrays_of_any, (Int,)),
    (sum_tuple, (NTuple{4,Any},)), (vector_sel, (Bool, Vector{Any})), (gc_safe_call, ()),
    (sort!, (Vector{Any},)), (push!, (Vector{Any}, Any)), (string, (Any,)),
    (preserve_load, (Vector{Int},)), (preserve_ref, (Any,)),
    (preserve_loop, (Vector{Float64},)),
    (try_simple, (Int,)), (try_finally, (Int,)), (try_catch_var, (Int,)),
    (try_nested, (Int,)), (try_loop, (Vector{Int},)), (try_return, (Int,)),
    (try_rethrow, (Int,)), (throws, (Int,)), (lock_call, (ReentrantLock, Int)),
    (simd_sum, (Vector{Float64},)), (simd_sum, (Vector{Float32},)),
    (simd_sum, (Vector{Int},)), (simd_sum, (UnitRange{Int},)),
    (simd_sum_ivdep, (Vector{Float64},)), (simd_dot, (Vector{Float64}, Vector{Float64})),
    (simd_dot, (Vector{ComplexF32}, Vector{ComplexF32})), (simd_sub, (Vector{Float64},)),
    (simd_axpy!, (Vector{Float64}, Float64, Vector{Float64})),
    (simd_nested, (Matrix{Float64},)), (simd_minmax, (Vector{Float64},)),
    (plain_loop, (Vector{Float64},)), (sum, (Vector{Float64},)),
    (fma_like, (Float64, Float64, Float64)), (fma_contract, (Float64, Float64, Float64)),
    (muladd_call, (Float64, Float64, Float64)),
    (atomic_add, (AtomicInt, Int)), (atomic_max, (AtomicInt, Int)),
    (atomic_custom, (AtomicInt, Int)), (atomic_mono, (AtomicInt, Int)),
    (atomic_fadd, (AtomicFloat, Float64)), (atomic_any, (AtomicAny, Int)),
    (atomic_swap, (AtomicInt, Int)), (atomic_replace, (AtomicInt, Int, Int)),
    (atomic_load, (AtomicInt,)), (atomic_ptr_add, (Ptr{Int}, Int)),
    (atomic_loop, (AtomicInt, Int)),
    (f16_add, (Float16, Float16)), (f16_mix, (Float16, Float16, Float32)),
    (f16_vec, (Vector{Float16},)), (f16_cmp, (Float16, Float16)),
    (f16_tuple, (NTuple{4,Float16},)),
    (make_closure, (Int,)), (make_adder, (Any,)), (call_closure, (Function, Int)),
    (boxed_capture, (Int,)),
]

function main(out)
    mkpath(out)
    n = 0
    names = Dict{String,Int}()
    for (f, types) in CORPUS
        base = string(nameof(f))
        k = names[base] = get(names, base, 0) + 1
        name = k == 1 ? base : "$(base)_$k"
        for (suffix, debuginfo) in (("", :none), (".dbg", :default))
            ir = try
                sprint(io -> code_llvm(io, f, types; optimize=false, raw=true,
                                       dump_module=true, debuginfo))
            catch err
                println("skipped $name$suffix: ", sprint(showerror, err))
                continue
            end
            write(joinpath(out, "$name$suffix.ll"), ir)
            n += 1
        end
    end
    println("wrote $n modules to $out")
end

isinteractive() || main(ARGS[1])
