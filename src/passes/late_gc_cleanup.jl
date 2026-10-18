# LateLowerGC cleanup: the part of Julia's LateLowerGCFrame pass
# (`src/llvm-late-gc-lowering.cpp`, `CleanupIR`) that applies to functions without a GC
# frame, as GPU back-ends emit them once their own GC lowering (GPUCompiler's
# GPULowerGCFrame) has replaced allocations and removed write barriers. It strips the
# metadata that only holds while the GC keeps objects alive (`!invariant.load` on loads
# through Julia's address spaces, immutable TBAA tags of constant data), lowers the GC
# intrinsics that have no meaning without a GC frame, lowers jlcalls to calls with an
# argument array, and removes Julia's operand bundles. The input contract is documented
# in docs/src/late_gc_cleanup.md: what needs Julia's runtime or a GC frame is rejected
# with an `UnsupportedInputError` before the function is changed.

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

# operand bundles that only Julia's GC lowering understands
const JULIA_BUNDLES = ("jl_roots", "gc-transition", "julia.gc_alloc_zeroinit_indirect",
                       "julia.gc_alloc_ptr_offsets", "julia.gc_alloc_zeroinit")
# the bundles of `julia.gc_alloc_obj` (Julia master) that ask for the new object to be
# initialized
const ALLOCATION_BUNDLES = ("julia.gc_alloc_ptr_offsets", "julia.gc_alloc_zeroinit")

# intrinsics that need Julia's runtime, and why
function unsupported_functions(dialect::Dialect)
    reasons = Pair{String,String}[
        "julia.gc_alloc_obj" => "allocations must be lowered first (e.g., by GPUCompiler's GPULowerGCFrame)",
        "julia.typeof" => "reading the type of an object needs the object headers of Julia's runtime",
        "julia.blackbox" => "julia.blackbox is lowered to inline assembly for the CPU",
    ]
    for name in dialect.write_barriers
        push!(reasons, name => "write barriers must be removed first (e.g., by GPUCompiler's GPULowerGCFrame)")
    end
    return reasons
end

const PGCSTACK_GETTERS = ("julia.get_pgcstack", "julia.get_pgcstack_or_new")

# the functions of a module that the cleanup acts on
struct CleanupFunctions
    erased::Vector{LLVM.Function}
    pointer_from_objref::Union{Nothing,LLVM.Function}
    gc_loaded::Union{Nothing,LLVM.Function}
    # julia.call, julia.call2, julia.call3 => :call, :call2, :call3
    jlcalls::Dict{LLVM.Function,Symbol}
    pgcstack_getters::Vector{LLVM.Function}
    unsupported::Dict{LLVM.Function,String}
end

function CleanupFunctions(mod::LLVM.Module, dialect::Dialect)
    fns = mod.functions
    lookup(name) = get(fns, name, nothing)
    erased = LLVM.Function[f for f in lookup.(("julia.gcroot_flush",
                                               "llvm.julia.gc_preserve_begin",
                                               "llvm.julia.gc_preserve_end"))
                           if f !== nothing]
    jlcalls = Dict{LLVM.Function,Symbol}()
    for kind in (dialect.has_call3 ? (:call, :call2, :call3) : (:call, :call2))
        f = lookup("julia.$kind")
        f === nothing || (jlcalls[f] = kind)
    end
    getters = LLVM.Function[f for f in lookup.(PGCSTACK_GETTERS) if f !== nothing]
    unsupported = Dict{LLVM.Function,String}()
    for (name, reason) in unsupported_functions(dialect)
        f = lookup(name)
        f === nothing || (unsupported[f] = "$name: $reason")
    end
    return CleanupFunctions(erased, lookup("julia.pointer_from_objref"),
                            dialect.has_gc_loaded ? lookup("julia.gc_loaded") : nothing,
                            jlcalls, getters, unsupported)
end

function called_function(call::Instruction)
    callee = call.called_operand
    return callee isa LLVM.Function ? callee : nothing
end

is_julia_function(fns::CleanupFunctions, f::LLVM.Function) =
    f in fns.erased || f == fns.pointer_from_objref || f == fns.gc_loaded ||
    haskey(fns.jlcalls, f) || f in fns.pgcstack_getters || haskey(fns.unsupported, f)

function has_string_attribute(attrs, kind::String)
    for attr in attrs
        attr isa StringAttribute && LLVM.kind(attr) == kind && return true
    end
    return false
end

# the constructs of a function that need Julia's runtime or a GC frame
function unsupported_constructs(f::LLVM.Function, fns::CleanupFunctions)
    found = UnsupportedConstruct[]
    # Julia's frame lowering roots values in a frame on the GC stack, used or not
    gcstack = "the function has a GC stack, which needs GC frame lowering"
    for (i, arg) in enumerate(f.parameters)
        if has_string_attribute(f.parameter_attributes[i], "gcstack")
            push!(found, UnsupportedConstruct("gcstack argument: $gcstack", string(arg), ""))
        end
    end
    for bb in f.blocks, inst in bb.instructions
        inst isa LLVM.CallBase || continue
        callee = called_function(inst)
        if !(inst isa LLVM.CallInst)
            # Julia only emits calls; the rewrites below only handle those
            if callee !== nothing && is_julia_function(fns, callee) ||
               any(b -> LLVM.tag(b) in JULIA_BUNDLES, inst.operand_bundles)
                push!(found, UnsupportedConstruct(
                    "$(opcode_name(inst)) of a Julia intrinsic or with Julia's operand bundles: only calls are supported",
                    string(inst), location_string(inst)))
            end
            continue
        end
        if callee !== nothing
            reason = get(fns.unsupported, callee, nothing)
            if reason !== nothing
                push!(found, UnsupportedConstruct(reason, string(inst), location_string(inst)))
            elseif callee in fns.pgcstack_getters
                push!(found, UnsupportedConstruct("$(callee.name): $gcstack", string(inst),
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

mutable struct LateGCCleanup
    dialect::Dialect
    fns::CleanupFunctions
    builder::IRBuilder
    dl::DataLayout
    T_prjlvalue::LLVMType
    # the array that holds the arguments of jlcalls, if any
    frame::Union{Nothing,Instruction}
    changed::Bool
end

pointer_align(c::LateGCCleanup, ty::LLVMType) = abi_alignment(c.dl, ty)

# the number of arguments of a jlcall that are passed in the argument array
function frame_args(call::Instruction, kind::Symbol)
    n = length(call.arguments) - 1  # the function pointer
    return kind === :call2 ? n - 2 : n - 1
end

# One array for the arguments of every jlcall of a function, like the C++ pass, which
# relies on LLVM to merge the arrays otherwise.
function create_frame!(c::LateGCCleanup, f::LLVM.Function)
    nargs = 0
    for bb in f.blocks, inst in bb.instructions
        inst isa LLVM.CallInst || continue
        kind = get(c.fns.jlcalls, called_function(inst), nothing)
        kind === nothing || (nargs = max(nargs, frame_args(inst, kind)))
    end
    nargs == 0 && return
    position!(c.builder, LLVM.before(first(first(f.blocks).instructions)))
    c.builder.debug_location = nothing
    c.frame = array_alloca!(c.builder, c.T_prjlvalue, ConstantInt(LLVM.Int32Type(), nargs),
                            "jlcallframe")
end

# `addrspacecast val to ty` as an instruction (which `C++`'s `new AddrSpaceCastInst`
# creates even for constants, which IRBuilder folds)
function addrspacecast_inst!(c::LateGCCleanup, @nospecialize(val::Value), ty::LLVMType)
    builder = c.builder
    if val isa LLVM.Constant
        tmp = freeze!(builder, val)
        cast = addrspacecast!(builder, tmp, ty)::Instruction
        cast.operands[1] = val
        erase!(tmp)
        return cast
    end
    return addrspacecast!(builder, val, ty)::Instruction
end

function replace_by_cast!(c::LateGCCleanup, call::Instruction, @nospecialize(obj::Value))
    position!(c.builder, LLVM.before(call))
    c.builder.debug_location = nothing
    cast = addrspacecast_inst!(c, obj, call.value_type)
    take_name!(cast, call)
    replace_uses!(call, cast)
end

# `julia.call(fptr, f, args...)` => `fptr(f, frame, nargs)`, with the arguments stored
# in the frame; `julia.call2(fptr, arg1, f, args...)` => `fptr(f, frame, nargs, arg1)`;
# `julia.call3` like `julia.call`, with a derived function pointer
function lower_jlcall!(c::LateGCCleanup, call::Instruction, decl::LLVM.Function,
                       kind::Symbol)
    builder = c.builder
    args = collect(call.arguments)
    callee = args[1]
    nfixed = kind === :call2 ? 2 : 1
    fixed = args[2:1+nfixed]
    frame_values = args[2+nfixed:end]

    position!(builder, LLVM.before(call))
    builder.debug_location = call.debug_location
    T_ptr = LLVM.PointerType(AS_GENERIC)
    for (slot, val) in enumerate(frame_values)
        ptr = inbounds_gep!(builder, c.T_prjlvalue, c.frame,
                            [ConstantInt(LLVM.Int32Type(), slot - 1)])
        store = store!(builder, val, ptr)
        store.alignment = pointer_align(c, c.T_prjlvalue)
    end
    frame_arg = isempty(frame_values) ? LLVM.null(T_ptr) :
                                        addrspacecast!(builder, c.frame, T_ptr)
    new_args = Value[fixed..., frame_arg, ConstantInt(LLVM.Int32Type(), length(frame_values))]
    if kind === :call2
        push!(new_args, popfirst!(new_args))
    end

    T_int32 = LLVM.Int32Type()
    ft = if kind === :call2
        LLVM.FunctionType(c.T_prjlvalue, [c.T_prjlvalue, T_ptr, T_int32, c.T_prjlvalue])
    elseif kind === :call3
        LLVM.FunctionType(c.T_prjlvalue, [LLVM.PointerType(AS_DERIVED), T_ptr, T_int32])
    else
        LLVM.FunctionType(c.T_prjlvalue, [c.T_prjlvalue, T_ptr, T_int32])
    end
    builder.debug_location = nothing
    bundles = OperandBundle[b for b in call.operand_bundles if !(LLVM.tag(b) in JULIA_BUNDLES)]
    new_call = call!(builder, ft, callee, new_args, bundles)
    new_call.tailcall_kind = call.tailcall_kind
    # the function and return attributes of the call, merged with all attributes of the
    # jlcall declaration (as the C++ pass does)
    for attr in collect(call.function_attributes)
        push!(new_call.function_attributes, attr)
    end
    for attr in collect(call.return_attributes)
        push!(new_call.return_attributes, attr)
    end
    for attr in collect(decl.function_attributes)
        push!(new_call.function_attributes, attr)
    end
    for attr in collect(decl.return_attributes)
        push!(new_call.return_attributes, attr)
    end
    for i in 1:min(length(decl.parameter_attributes), length(new_args)),
        attr in collect(decl.parameter_attributes[i])
        push!(new_call.argument_attributes[i], attr)
    end
    take_name!(new_call, call)
    copy_metadata!(new_call, call)
    replace_uses!(call, new_call)
end

# `julia.gc_alloc_zeroinit_indirect(offset, size)` on an allocation: zero `size` bytes at
# the data pointer stored at `offset` in the allocated object, after the call
function zeroinit_indirect!(c::LateGCCleanup, call::Instruction, bundle::OperandBundle)
    offset, size = collect(LLVM.inputs(bundle))
    size isa ConstantInt && convert(Int, size) == 0 && return
    builder = c.builder
    position!(builder, LLVM.after(call))
    builder.debug_location = call.debug_location
    derived = addrspacecast!(builder, call, LLVM.PointerType(AS_DERIVED))
    field = inbounds_gep!(builder, LLVM.Int8Type(), derived, [offset])
    T_ptr = LLVM.PointerType(AS_GENERIC)
    data = load!(builder, T_ptr, field)
    data.alignment = pointer_align(c, T_ptr)
    memset!(builder, data, ConstantInt(LLVM.Int8Type(), 0), size, pointer_align(c, T_ptr))
end

# remove Julia's operand bundles from a call, after discharging what they ask for
function remove_bundles!(c::LateGCCleanup, call::Instruction)
    bundles = collect(call.operand_bundles)
    any(b -> LLVM.tag(b) in JULIA_BUNDLES, bundles) || return nothing
    kept = OperandBundle[]
    for bundle in bundles
        tag = LLVM.tag(bundle)
        if tag == "julia.gc_alloc_zeroinit_indirect"
            zeroinit_indirect!(c, call, bundle)
        elseif !(tag in JULIA_BUNDLES)
            push!(kept, bundle)
        end
    end
    new_call = clone_call!(c.builder, call, kept)
    take_name!(new_call, call)
    copy_metadata!(new_call, call)
    replace_uses!(call, new_call)
    return new_call
end

# returns whether the call was replaced (and should be erased)
function cleanup_call!(c::LateGCCleanup, call::Instruction)
    fns = c.fns
    callee = called_function(call)
    if callee !== nothing && callee in fns.erased
        # no replacement
    elseif callee !== nothing && callee == fns.pointer_from_objref
        replace_by_cast!(c, call, call.arguments[1])
    elseif callee !== nothing && callee == fns.gc_loaded
        replace_by_cast!(c, call, call.arguments[2])
    elseif callee !== nothing && haskey(fns.jlcalls, callee)
        lower_jlcall!(c, call, callee, fns.jlcalls[callee])
    elseif remove_bundles!(c, call) === nothing
        return false
    end
    if !isempty(call.uses)
        replace_uses!(call, UndefValue(call.value_type))
    end
    return true
end

function cleanup_instruction!(c::LateGCCleanup, inst::Instruction)
    # The GC keeps objects alive, and thus their memory constant, only while they are
    # rooted, which isn't known after GC lowering (JuliaLang/julia#32215).
    if inst isa LLVM.LoadInst && haskey(inst.metadata, LLVM.MD_invariant_load) &&
       is_special_addrspace(pointer_addrspace(inst.operands[1]))
        delete!(inst.metadata, LLVM.MD_invariant_load)
        c.changed = true
    end
    md = inst.metadata
    tag = haskey(md, LLVM.MD_tbaa) ? md[LLVM.MD_tbaa] : nothing
    if tag isa MDNode && length(tag.operands) == 4 &&
       tbaa_derives_from(tag, c.dialect.tbaa_downgrade)
        mutable = mutable_tbaa_tag(tag)
        if mutable != tag
            inst.metadata[LLVM.MD_tbaa] = mutable
            c.changed = true
        end
    end
    # SROA starts chains of insertvalues of aggregates with tracked pointers from undef,
    # and GC lowering may have extracted an undef field from them
    if inst isa LLVM.InsertValueInst
        agg = inst.operands[1]
        if agg isa UndefValue || agg isa LLVM.PoisonValue
            inst.operands[1] = LLVM.null(inst.value_type)
            c.changed = true
        end
    end
    if inst isa LLVM.CallInst && cleanup_call!(c, inst)
        erase!(inst)
        c.changed = true
    end
end

function late_gc_cleanup!(f::LLVM.Function, am, opts::PassOptions)
    # Julia master doesn't lower thunks
    has_string_attribute(f.function_attributes, "thunk") &&
        return PreservedAnalyses(AllAnalyses)
    mod = f.parent
    fns = CleanupFunctions(mod, opts.dialect)
    unsupported = unsupported_constructs(f, fns)
    isempty(unsupported) || throw(UnsupportedInputError(f.name, unsupported))

    @dispose builder=IRBuilder() begin
        c = LateGCCleanup(opts.dialect, fns, builder, mod.datalayout,
                          LLVM.PointerType(AS_TRACKED), nothing, false)
        create_frame!(c, f)
        c.changed |= c.frame !== nothing
        for bb in f.blocks
            for inst in collect(bb.instructions)
                cleanup_instruction!(c, inst)
            end
        end
        return c.changed ? PreservedAnalyses(CFGAnalyses) : PreservedAnalyses(AllAnalyses)
    end
end

const LATE_GC_CLEANUP = define_pass("jl-late-gc-cleanup", :function, late_gc_cleanup!;
                                    required=true, cpp_name="")

"""
    JuliaIR.LateGCCleanupPass(; julia=VERSION)

Clean up Julia's IR after GC lowering, for functions without a GC frame
(`jl-late-gc-cleanup` in a pipeline): the part of Julia's `LateLowerGCFrame` pass that
applies to GPU code. See the input contract in the documentation; functions that need
Julia's runtime or a GC frame make the pass throw a [`JuliaIR.UnsupportedInputError`](@ref).
"""
LateGCCleanupPass(; kwargs...) = custom_pass(LATE_GC_CLEANUP; kwargs...)
