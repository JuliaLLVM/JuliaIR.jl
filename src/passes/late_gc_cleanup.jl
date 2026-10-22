# LateGCCleanup: LateLowerGCFrame restricted to functions without a GC frame, as GPU
# back-ends emit them once their own GC lowering (GPUCompiler's GPULowerGCFrame) has
# replaced allocations and removed write barriers. It validates that a function only
# contains what the cleanup part of the pass handles without Julia's runtime (the input
# contract in docs/src/late_lower_gc_frame.md), and then runs the general pass on it:
# what needs Julia's runtime or a GC frame is rejected with an `UnsupportedInputError`
# before the function is changed.

"""
    JuliaIR.UnsupportedConstruct

A construct that LateGCCleanup (`jl-late-gc-cleanup`) does not support: the `message`
that names it, the offending `instruction` (or argument) as text, and its source
`location` (`file:line`, or empty without debug information).
"""
struct UnsupportedConstruct
    message::String
    instruction::String
    location::String
end

"""
    JuliaIR.UnsupportedInputError

The error thrown by LateGCCleanup (`jl-late-gc-cleanup`) when a function contains
constructs that need Julia's runtime or a GC frame (see the input contract in the
documentation). `constructs` lists all of them, as [`JuliaIR.UnsupportedConstruct`](@ref)s,
in the order of the function's instructions. The function is not changed.
"""
struct UnsupportedInputError <: Exception
    function_name::String
    constructs::Vector{UnsupportedConstruct}
end

function Base.showerror(io::IO, err::UnsupportedInputError)
    print(io, "UnsupportedInputError: function ", err.function_name,
          " contains constructs that LateGCCleanup does not support")
    for c in err.constructs
        print(io, '\n', c.message)
        isempty(c.location) || print(io, " (at ", c.location, ")")
        print(io, "\n\t", c.instruction)
    end
end

# the source location of an instruction, as `file:line`
function location_string(inst::Instruction)
    loc = inst.debug_location
    loc === nothing && return ""
    scope = LLVM.scope(loc)
    file = scope === nothing ? nothing : LLVM.file(scope)
    return string(file === nothing ? "unknown" : LLVM.filename(file), ":", LLVM.line(loc))
end

# the bundles of `julia.gc_alloc_obj` (Julia 1.14 and later) that ask for the new object
# to be initialized
const ALLOCATION_BUNDLES = ("julia.gc_alloc_ptr_offsets", "julia.gc_alloc_zeroinit")

const PGCSTACK_GETTERS = ("julia.get_pgcstack", "julia.get_pgcstack_or_new")

# the intrinsics that the cleanup rejects, and why
function unsupported_functions(dialect::Dialect)
    reasons = Pair{String,String}[
        "julia.gc_alloc_obj" => "allocations must be lowered first (e.g., by GPUCompiler's GPULowerGCFrame)",
        "julia.typeof" => "reading the type of an object needs the object headers of Julia's runtime",
        "julia.blackbox" => "julia.blackbox is lowered to inline assembly for the CPU",
        "julia.safepoint" => "safepoints need Julia's runtime and must be lowered by FinalLowerGC",
    ]
    for name in dialect.write_barriers
        push!(reasons, name => "write barriers must be removed first (e.g., by GPUCompiler's GPULowerGCFrame)")
    end
    for name in ("julia.new_gc_frame", "julia.push_gc_frame", "julia.pop_gc_frame",
                 "julia.get_gc_frame_slot", "julia.gc_alloc_bytes", "julia.queue_gc_root")
        push!(reasons, name => "GC frames and allocations of Julia's runtime are lowered by FinalLowerGC")
    end
    return reasons
end

# the intrinsics that the cleanup lowers
function cleanup_functions(dialect::Dialect)
    names = ["julia.gcroot_flush", "llvm.julia.gc_preserve_begin",
             "llvm.julia.gc_preserve_end", "julia.pointer_from_objref", "julia.call",
             "julia.call2"]
    dialect.has_gc_loaded && push!(names, "julia.gc_loaded")
    dialect.has_call3 && push!(names, "julia.call3")
    return names
end

# the constructs of a function that need Julia's runtime or a GC frame
function unsupported_constructs(f::LLVM.Function, dialect::Dialect)
    mod = LLVM.parent(f)
    lookup(name) = get(mod.functions, name, nothing)
    unsupported = Dict{LLVM.Function,String}()
    for (name, reason) in unsupported_functions(dialect)
        fn = lookup(name)
        fn === nothing || (unsupported[fn] = "$name: $reason")
    end
    getters = LLVM.Function[fn for fn in lookup.(PGCSTACK_GETTERS) if fn !== nothing]
    julia_functions = Set{LLVM.Function}(fn for fn in lookup.(cleanup_functions(dialect))
                                         if fn !== nothing)
    union!(julia_functions, keys(unsupported), getters)

    found = UnsupportedConstruct[]
    # Julia's frame lowering roots values in a frame on the GC stack, used or not
    gcstack = "the function has a GC stack, which needs GC frame lowering"
    for (i, arg) in enumerate(f.parameters)
        if haskey(f.parameter_attributes[i], "gcstack")
            push!(found, UnsupportedConstruct("gcstack argument: $gcstack", string(arg), ""))
        end
    end
    for bb in f.blocks, inst in bb.instructions
        inst isa LLVM.CallBase || continue
        callee = inst.called_operand
        callee = callee isa LLVM.Function ? callee : nothing
        if !(inst isa LLVM.CallInst)
            # Julia only emits calls, and the pass only lowers those
            if callee !== nothing && callee in julia_functions ||
               any(b -> LLVM.tag(b) in JULIA_BUNDLES, inst.operand_bundles)
                push!(found, UnsupportedConstruct(
                    "$(opcode_name(inst)) of a Julia intrinsic or with Julia's operand bundles: only calls are supported",
                    string(inst), location_string(inst)))
            end
            continue
        end
        if callee !== nothing
            reason = get(unsupported, callee, nothing)
            if reason !== nothing
                push!(found, UnsupportedConstruct(reason, string(inst), location_string(inst)))
            elseif callee in getters
                push!(found, UnsupportedConstruct("$(LLVM.name(callee)): $gcstack", string(inst),
                                                  location_string(inst)))
            end
        end
        for bundle in inst.operand_bundles
            tag = LLVM.tag(bundle)
            if tag == "gc-transition"
                push!(found, UnsupportedConstruct(
                    "gc-transition operand bundle: GC state transitions need Julia's runtime",
                    string(inst), location_string(inst)))
            elseif tag in ALLOCATION_BUNDLES
                push!(found, UnsupportedConstruct(
                    "$tag operand bundle: only valid on julia.gc_alloc_obj, whose lowering must initialize the object",
                    string(inst), location_string(inst)))
            end
        end
    end
    return found
end

function late_gc_cleanup!(f::LLVM.Function, am, opts::PassOptions)
    # validated even when the general pass would skip the function (thunks)
    unsupported = unsupported_constructs(f, opts.dialect)
    isempty(unsupported) || throw(UnsupportedInputError(LLVM.name(f), unsupported))
    # GPU modules don't link Julia's runtime, so nothing of it is declared
    return late_lower_gc_frame!(f, am, opts; declare_small_alloc=false)
end

const LATE_GC_CLEANUP = define_pass("jl-late-gc-cleanup", :function, late_gc_cleanup!;
                                    required=true, cpp_name="")

"""
    JuliaIR.LateGCCleanupPass()

[`JuliaIR.LateLowerGCFramePass`](@ref) for functions without a GC frame
(`jl-late-gc-cleanup` in a pipeline), as GPU back-ends emit them: the part of Julia's
`LateLowerGCFrame` pass that applies to GPU code. See the input contract in the
documentation; functions that need Julia's runtime or a GC frame make the pass throw a
[`JuliaIR.UnsupportedInputError`](@ref) before anything is changed.
"""
LateGCCleanupPass(; kwargs...) = custom_pass(LATE_GC_CLEANUP; kwargs...)
