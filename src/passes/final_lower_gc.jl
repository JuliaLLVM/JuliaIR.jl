# FinalLowerGC: port of Julia's final GC lowering pass (`src/llvm-final-gc-lowering.cpp`,
# and from Julia 1.14 on `llvm-final-gc-lowering-stock.cpp`). It lowers what
# LateLowerGCFrame leaves behind to code for Julia's runtime: the GC frame intrinsics,
# allocations, root queuing and safepoints, and from Julia 1.14 on also the write barriers.
# The functions keep the names of the C++ ones; differences between Julia versions are
# fields of `Dialect`, deviations from the C++ are documented in
# docs/src/final_lower_gc.md.

mutable struct FinalLowerGC
    dialect::Dialect
    mod::LLVM.Module
    builder::IRBuilder
    gc::GCCodegen
    # the GC stack of the function being lowered: a call in the entry block, or an argument
    pgcstack::Union{Nothing,Value}
    # the runtime functions the intrinsics are lowered to, once declared
    runtime::Dict{Symbol,LLVM.Function}
    cfg_modified::Bool
end

function FinalLowerGC(dialect::Dialect, mod::LLVM.Module, builder::IRBuilder)
    gc = GCCodegen(dialect, mod, builder, runtime_layout(dialect, mod))
    return FinalLowerGC(dialect, mod, builder, gc, nothing, Dict{Symbol,LLVM.Function}(),
                        false)
end

# the runtime functions that FinalLowerGC declares, in the order the C++ declares them
runtime_functions(dialect::Dialect) =
    dialect.gc_alloc_reset_safe ?
        (:gc_queue_root, :gc_small_alloc, :gc_big_alloc, :gc_alloc_typed,
         :gc_queue_root_reset_safe, :gc_small_alloc_reset_safe, :gc_big_alloc_reset_safe,
         :gc_alloc_typed_reset_safe) :
        (:gc_queue_root, :gc_small_alloc, :gc_big_alloc, :gc_alloc_typed)

function declare_runtime_functions!(p::FinalLowerGC)
    for which in runtime_functions(p.dialect)
        p.runtime[which] = get_or_declare(p.gc, which; check=true)
    end
    return [p.runtime[which] for which in runtime_functions(p.dialect)]
end

parent_function(inst::Instruction) = LLVM.parent(LLVM.parent(inst))

# the calls of write barriers that FinalLowerGC lowers (Julia 1.14 and later)
function barrier_calls(p::FinalLowerGC)
    calls = Instruction[]
    for name in write_barrier_names(p.dialect)
        f = get(p.mod.functions, name, nothing)
        f === nothing && continue
        for use in LLVM.uses(f)
            call = LLVM.user(use)
            call isa LLVM.CallInst && call.called_operand == f && push!(calls, call)
        end
    end
    return calls
end

# The C++ pass calls an existing function of a runtime function's name whatever its type,
# which gives invalid IR. Check what the functions in `functions` will call, before the
# pass changes anything: the existing declarations, the calls of `julia.queue_gc_root`
# (which become calls of the runtime's function), and from Julia 1.14 on the intrinsic that
# the write barriers call.
function check_declarations(p::FinalLowerGC, functions)
    mod = p.mod
    for which in runtime_functions(p.dialect)
        name, ft = gc_declaration(p.gc, which)
        existing = get(mod.functions, name, nothing)
        existing === nothing || existing.function_type == ft ||
            throw(DeclarationError(name, string(ft), string(existing.function_type)))
    end
    queue_root = get(mod.functions, "julia.queue_gc_root", nothing)
    queue_root === nothing && return
    name, ft = gc_declaration(p.gc, :gc_queue_root)
    if any(call -> parent_function(call) in functions && !isempty(barrier_children(call)),
           barrier_calls(p))
        queue_root.function_type == ft ||
            throw(DeclarationError(LLVM.name(queue_root), string(ft),
                                   string(queue_root.function_type)))
    end
    for use in LLVM.uses(queue_root)
        call = LLVM.user(use)
        call isa LLVM.CallInst && call.called_operand == queue_root || continue
        parent_function(call) in functions || continue
        call.called_type == ft ||
            throw(DeclarationError(name, string(ft), string(call.called_type)))
    end
end

# the intrinsics FinalLowerGC lowers
const FINAL_GC_INTRINSICS = ("julia.new_gc_frame", "julia.get_gc_frame_slot",
                             "julia.push_gc_frame", "julia.pop_gc_frame",
                             "julia.gc_alloc_bytes", "julia.queue_gc_root",
                             "julia.safepoint")

# the write barriers, which FinalLowerGC lowers from Julia 1.14 on
write_barrier_names(dialect::Dialect) =
    dialect.gc_barrier_lowering === :deferred ? dialect.write_barriers : String[]

function has_use(mod::LLVM.Module, name::String)
    f = get(mod.functions, name, nothing)
    return f !== nothing && !isempty(f.uses)
end

# whether any function of the module uses a GC intrinsic (Julia 1.13 and later)
should_run_final_gc(p::FinalLowerGC) =
    any(name -> has_use(p.mod, name), FINAL_GC_INTRINSICS) ||
    any(name -> has_use(p.mod, name), write_barrier_names(p.dialect))


## positions

is_debug_intrinsic_call(inst::Instruction) =
    inst isa LLVM.CallInst && (callee = called_function(inst)) !== nothing &&
    is_debug_intrinsic(callee)

# the debug location that C++'s `IRBuilder` takes from the instruction it is positioned
# at (`getStableDebugLoc` from LLVM 18 on: the next instruction's for a debug intrinsic)
function stable_debug_location(inst::Instruction)
    if LLVM.version() >= v"18"
        while is_debug_intrinsic_call(inst) && inst.next !== nothing
            inst = inst.next
        end
    end
    return inst.debug_location
end

# position the builder for the code that replaces `target`: before it, with its debug
# location, or, where Julia 1.10 inserts after it (`IRBuilder<>(target->getNextNode())`),
# with the next instruction's debug location
function position_for!(p::FinalLowerGC, target::Instruction; after::Bool=false)
    at = after ? target.next::Instruction : target
    position!(p.builder, LLVM.before(at))
    p.builder.debug_location = stable_debug_location(at)
end


## lowerings

# `julia.new_gc_frame(n)`: a zeroed stack array of `n` roots and the frame's two header
# words
function lower_new_gc_frame!(p::FinalLowerGC, target::Instruction)
    builder = p.builder
    nroots = Int(limited_value(target.arguments[1]::LLVM.ConstantInt))
    position_for!(p, target; after=p.dialect.gc_final_debugloc_next)
    T_int32 = LLVM.Int32Type()
    frame_alloca = array_alloca!(builder, p.gc.T_prjlvalue, ConstantInt(T_int32, nroots + 2))
    # LateLowerGCFrame records a stronger alignment that allocas moved into the frame need
    # (Julia 1.13, adopted for every version)
    LLVM.alignment!(frame_alloca, max(16, something(ret_align(target), 1)))
    # for targets whose allocas aren't in the generic address space
    gcframe = addrspacecast!(builder, frame_alloca, LLVM.PointerType(AS_GENERIC))
    take_name!(gcframe, target)
    # the frame is zeroed with a non-volatile memset that only aliases the frame (Julia
    # 1.14 and later; up to 1.13, a volatile one without TBAA, which keeps it from being
    # removed)
    size = pointer_size(p.gc) * (nroots + 2)
    memset = memset!(builder, gcframe, ConstantInt(LLVM.Int8Type(), 0),
                     ConstantInt(LLVM.Int64Type(), size), 16)
    memset.metadata[LLVM.MD_tbaa] = tbaa_tags(p.gc).gcframe
    replace_uses!(target, gcframe)
    erase!(target)
end

# `julia.push_gc_frame(frame, n)`: link the frame into the task's GC stack
function lower_push_gc_frame!(p::FinalLowerGC, target::Instruction)
    builder = p.builder
    gcframe, n = target.arguments
    nroots = Int(limited_value(n::LLVM.ConstantInt))
    names = p.dialect.gc_names
    T_int32 = LLVM.Int32Type()
    T_ptr = LLVM.PointerType(AS_GENERIC)
    align = pointer_align(p.gc)
    position_for!(p, target; after=p.dialect.gc_final_debugloc_next)
    nroots_addr = inbounds_gep!(builder, p.gc.T_prjlvalue, gcframe, [ConstantInt(T_int32, 0)],
                                names ? "frame.nroots" : "")
    # `JL_GC_ENCODE_PUSHARGS`
    store = store!(builder, ConstantInt(p.gc.T_size, nroots << 2), nroots_addr; align)
    store.metadata[LLVM.MD_tbaa] = tbaa_tags(p.gc).gcframe
    # in the order of the C++ (whose compilers evaluate the store's operands right to left)
    prev_addr = inbounds_gep!(builder, p.gc.T_prjlvalue, gcframe, [ConstantInt(T_int32, 1)],
                              names ? "frame.prev" : "")
    prev = load!(builder, T_ptr, p.pgcstack, names ? "task.gcstack" : ""; align)
    store = store!(builder, prev, prev_addr; align)
    store.metadata[LLVM.MD_tbaa] = tbaa_tags(p.gc).gcframe
    store!(builder, gcframe, p.pgcstack; align)
    erase!(target)
end

# `julia.pop_gc_frame(frame)`: restore the task's GC stack
function lower_pop_gc_frame!(p::FinalLowerGC, target::Instruction)
    builder = p.builder
    gcframe = target.arguments[1]
    align = pointer_align(p.gc)
    position_for!(p, target)
    prev_addr = inbounds_gep!(builder, p.gc.T_prjlvalue, gcframe,
                              [ConstantInt(LLVM.Int32Type(), 1)])
    prev = load!(builder, p.gc.T_prjlvalue, prev_addr, p.dialect.gc_names ? "frame.prev" : "";
                 align)
    prev.metadata[LLVM.MD_tbaa] = tbaa_tags(p.gc).gcframe
    store = store!(builder, prev, p.pgcstack; align)
    store.metadata[LLVM.MD_tbaa] = tbaa_tags(p.gc).gcframe
    erase!(target)
end

# `julia.get_gc_frame_slot(frame, i)`: the address of a root, after the header
function lower_get_gc_frame_slot!(p::FinalLowerGC, target::Instruction)
    builder = p.builder
    gcframe, index = target.arguments
    position_for!(p, target)
    index = add!(builder, index, ConstantInt(LLVM.Int32Type(), GC_FRAME_HEADER_SLOTS))
    gep = inbounds_gep!(builder, p.gc.T_prjlvalue, gcframe, [index])
    take_name!(gep, target)
    replace_uses!(target, gep)
    erase!(target)
end

has_reset_region(inst::Instruction) = haskey(inst.metadata, "julia.reset_region")

# `julia.queue_gc_root(v)`: the runtime's function, called in place
function lower_queue_gc_root!(p::FinalLowerGC, target::Instruction)
    # from Julia 1.14 on, the call may run with a cancellation reset region published
    callee = p.dialect.gc_alloc_reset_safe && has_reset_region(target) ?
        p.runtime[:gc_queue_root_reset_safe] : p.runtime[:gc_queue_root]
    target.called_type == callee.function_type ||
        throw(DeclarationError(LLVM.name(callee), string(target.called_type),
                               string(callee.function_type)))
    target.called_operand = callee
end

# `julia.safepoint(page)`: a volatile load of the safepoint page, which the runtime
# protects to stop the thread
function lower_safepoint!(p::FinalLowerGC, target::Instruction)
    position_for!(p, target)
    load!(p.builder, p.gc.T_size, target.arguments[1]; volatile=true)
    erase!(target)
end

# `CreateZExtOrTrunc`
function zext_or_trunc!(builder::IRBuilder, @nospecialize(v::Value), ty::LLVMType)
    from, to = LLVM.width(LLVM.value_type(v)), LLVM.width(ty)
    from == to && return v
    return from < to ? zext!(builder, v, ty) : trunc!(builder, v, ty)
end

# `julia.gc_alloc_bytes(ptls, size[, tag])`: allocate from the pool of the size class of a
# constant size, as a big object, or of a dynamic size
function lower_gc_alloc_bytes!(p::FinalLowerGC, target::Instruction)
    builder = p.builder
    dialect = p.dialect
    position_for!(p, target)
    args = collect(target.arguments)
    ptls, size = args[1], args[2]
    tag = dialect.gc_alloc_bytes_tag ? Value[args[3]] : Value[]
    # from Julia 1.14 on, the allocation may run with a cancellation reset region published
    reset_safe = dialect.gc_alloc_reset_safe && has_reset_region(target)
    runtime(which) = p.runtime[reset_safe ? Symbol(which, :_reset_safe) : which]
    deref = UInt64(0)
    if size isa LLVM.ConstantInt
        sz = convert(UInt64, size)
        class = gc_pool_class(dialect, sz)
        if class === nothing
            callee = runtime(:gc_big_alloc)
            call_args = Value[ptls, ConstantInt(p.gc.T_size, sz + pointer_size(p.gc)), tag...]
        else
            offset, osize = class
            callee = runtime(:gc_small_alloc)
            call_args = Value[ptls, ConstantInt(LLVM.Int32Type(), offset),
                              ConstantInt(LLVM.Int32Type(), osize), tag...]
        end
        # the object's size (Julia 1.11, adopted for 1.10, which claims the size of the
        # pool's objects, or that of a big object's allocation, past the object's start)
        deref = sz
    else
        # the typed allocation function doesn't count the type tag in the size
        callee = runtime(:gc_alloc_typed)
        tag_arg = isempty(tag) ? LLVM.null(LLVM.PointerType(AS_GENERIC)) : tag[1]
        call_args = Value[ptls, zext_or_trunc!(builder, size, p.gc.T_size), tag_arg]
        deref = UInt64(pointer_size(p.gc))
    end
    new_call = call!(builder, callee.function_type, callee, call_args)
    copy_function_attributes!(new_call, callee)
    if dialect.gc_alloc_bytes_tag
        align = max(something(ret_align(target), 1), pointer_align(p.gc))
        push!(new_call.return_attributes, EnumAttribute("align", align))
    end
    deref > 0 && push!(new_call.return_attributes, EnumAttribute("dereferenceable", deref))
    take_name!(new_call, target)
    replace_uses!(target, new_call)
    erase!(target)
end

# the children of a write barrier that need one: the arguments after the parent, without
# the slot operands of field barriers (`JuliaPassContext::writeBarrierChildren`) and the
# null pointers (a field that is cleared)
function barrier_children(call::Instruction)
    args = collect(call.arguments)
    field = startswith(LLVM.name(call.called_operand), "julia.field_write_barrier")
    return [args[i] for i in 2:length(args)
            if (!field || iseven(i - 1)) && !(strip_pointer_casts(args[i]) isa LLVM.PointerNull)]
end

# a write barrier (Julia 1.14 and later), the stock GC's: like Julia 1.13's in
# LateLowerGCFrame, without the children that are null (a field that is cleared)
function lower_write_barrier!(p::FinalLowerGC, target::Instruction)
    parent = target.arguments[1]
    children = barrier_children(target)
    isempty(children) && return
    p.cfg_modified = true
    queue_root = emit_write_barrier!(p.gc, target, parent, children, :image, 1)
    # the slow path runs in the barrier's cancellation reset region, if any
    reset_region = get(target.metadata, "julia.reset_region", nothing)
    reset_region === nothing || (queue_root.metadata["julia.reset_region"] = reset_region)
end


## the pass

function_gcstack(p::FinalLowerGC, f::LLVM.Function) =
    get_pgcstack(p.dialect, f, get(p.mod.functions, "julia.get_pgcstack", nothing),
                 get(p.mod.functions, "julia.get_pgcstack_or_new", nothing))

# Lower the intrinsics in one function. Returns `:skipped` (no GC stack, or on Julia 1.13
# and later no GC intrinsic in the module), `:changed`, or `:cfg_changed` (blocks were
# split for write barriers). `declare` declares the runtime functions first, unless the
# module pass of Julia 1.10 did for the whole module.
function final_lower_gc_function!(p::FinalLowerGC, f::LLVM.Function; declare::Bool)
    dialect = p.dialect
    mod = p.mod
    p.pgcstack = function_gcstack(p, f)
    p.pgcstack === nothing && return :skipped
    dialect.gc_final_skip_unused && !should_run_final_gc(p) && return :skipped
    if declare
        check_declarations(p, (f,))
        declare_runtime_functions!(p)
    end
    p.cfg_modified = false

    lookup(name) = get(mod.functions, name, nothing)
    if dialect.gc_barrier_lowering === :deferred
        # Julia 1.14 lowers allocations and write barriers first, as barriers split
        # blocks and may add `julia.queue_gc_root` calls
        alloc_bytes = lookup("julia.gc_alloc_bytes")
        barriers = filter(!isnothing, lookup.(dialect.write_barriers))
        allocs, write_barriers = Instruction[], Instruction[]
        for bb in f.blocks, inst in bb.instructions
            inst isa LLVM.CallInst || continue
            callee = inst.called_operand
            any(b -> b == callee, barriers) && push!(write_barriers, inst)
            is_fn(alloc_bytes, callee) && push!(allocs, inst)
        end
        foreach(call -> lower_gc_alloc_bytes!(p, call), allocs)
        for call in write_barriers
            lower_write_barrier!(p, call)
            erase!(call)
        end
    end

    new_gc_frame = lookup("julia.new_gc_frame")
    get_gc_frame_slot = lookup("julia.get_gc_frame_slot")
    push_gc_frame = lookup("julia.push_gc_frame")
    pop_gc_frame = lookup("julia.pop_gc_frame")
    gc_alloc_bytes = dialect.gc_barrier_lowering === :deferred ? nothing :
                     lookup("julia.gc_alloc_bytes")
    queue_gc_root = lookup("julia.queue_gc_root")
    safepoint = lookup("julia.safepoint")
    for bb in collect(f.blocks), inst in collect(bb.instructions)
        inst isa LLVM.CallInst || continue
        callee = inst.called_operand
        if is_fn(new_gc_frame, callee)
            lower_new_gc_frame!(p, inst)
        elseif is_fn(get_gc_frame_slot, callee)
            lower_get_gc_frame_slot!(p, inst)
        elseif is_fn(push_gc_frame, callee)
            lower_push_gc_frame!(p, inst)
        elseif is_fn(pop_gc_frame, callee)
            lower_pop_gc_frame!(p, inst)
        elseif is_fn(gc_alloc_bytes, callee)
            lower_gc_alloc_bytes!(p, inst)
        elseif is_fn(queue_gc_root, callee)
            lower_queue_gc_root!(p, inst)
        elseif is_fn(safepoint, callee)
            lower_safepoint!(p, inst)
        end
    end
    return p.cfg_modified ? :cfg_changed : :changed
end

final_lower_gc_preserved(result::Symbol) =
    result === :skipped ? PreservedAnalyses(AllAnalyses) :
    result === :changed ? PreservedAnalyses(CFGAnalyses) : PreservedAnalyses()

# the function pass (Julia 1.11 and later; on Julia 1.10's IR, it declares the runtime
# functions in the functions it lowers, like later versions)
function final_lower_gc!(f::LLVM.Function, am, opts::PassOptions)
    @dispose builder=IRBuilder() begin
        p = FinalLowerGC(opts.dialect, LLVM.parent(f), builder)
        return final_lower_gc_preserved(final_lower_gc_function!(p, f; declare=true))
    end
end

# the module pass (Julia 1.10; on later versions, the function pass on every function)
function final_lower_gc_module!(mod::LLVM.Module, am, opts::PassOptions)
    dialect = opts.dialect
    @dispose builder=IRBuilder() begin
        p = FinalLowerGC(dialect, mod, builder)
        functions = [f for f in mod.functions if !isdeclaration(f)]
        # the functions with a GC stack are lowered (or skipped as a whole on Julia 1.13
        # and later); check them all before lowering the first
        lowered = filter(f -> function_gcstack(p, f) !== nothing, functions)
        if dialect.gc_final_module || !isempty(lowered) &&
                (!dialect.gc_final_skip_unused || should_run_final_gc(p))
            check_declarations(p, lowered)
        end
        if dialect.gc_final_module
            # Julia 1.10 declares the runtime functions in every module, and keeps them
            # from being removed while it runs (`doInitialization`, `doFinalization`)
            declared = declare_runtime_functions!(p)
            union!(mod.compiler_used, declared)
            for f in functions
                final_lower_gc_function!(p, f; declare=false)
            end
            setdiff!(mod.compiler_used, declared)
            return PreservedAnalyses(CFGAnalyses)
        end
        results = [final_lower_gc_function!(p, f; declare=true) for f in functions]
        return :cfg_changed in results ? PreservedAnalyses() :
               :changed in results ? PreservedAnalyses(CFGAnalyses) :
               PreservedAnalyses(AllAnalyses)
    end
end

const FINAL_LOWER_GC_MODULE = define_pass("jl-final-lower-gc", :module,
                                          final_lower_gc_module!;
                                          required=true, cpp_name="FinalLowerGC")
const FINAL_LOWER_GC_FUNCTION = define_pass("jl-final-lower-gc", :function,
                                            final_lower_gc!;
                                            required=true, cpp_name="FinalLowerGC")

"""
    JuliaIR.FinalLowerGCPass(; kind=:auto)

Julia's final GC lowering (`jl-final-lower-gc` in a pipeline, `FinalLowerGC` in Julia's
pipelines): lowers the GC frame intrinsics that LateLowerGCFrame emits, allocations,
root queuing and safepoints to code for Julia's runtime, and from Julia 1.14 on also the
write barriers. See the documentation for what it does on each Julia version.

The pass is both a module pass and a function pass; `kind` selects one (`:module`,
`:function`), by default the one of the running Julia's pipeline (a module pass on Julia
1.10, a function pass later).

Allocations of a constant size are lowered to the pool of their size class in the running
Julia's GC (see [`JuliaIR.gc_pool_class`](@ref)).
"""
function FinalLowerGCPass(; kind::Symbol=:auto, kwargs...)
    kind === :auto && (kind = Dialect(VERSION).gc_final_module ? :module : :function)
    kind in (:module, :function) ||
        throw(ArgumentError("invalid kind $kind; expected :module, :function or :auto"))
    return custom_pass(kind === :module ? FINAL_LOWER_GC_MODULE : FINAL_LOWER_GC_FUNCTION;
                       kwargs...)
end
