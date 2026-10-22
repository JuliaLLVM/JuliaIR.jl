# What Julia's GC lowering passes share (LateLowerGCFrame, FinalLowerGC, LowerPTLS,
# CancellationLowering, JuliaLICM): the constants of the runtime's GC, the counting of
# tracked pointers in types, Julia's TBAA nodes, the declarations of the GC intrinsics and
# of the runtime functions they are lowered to (`JuliaPassContext`, `jl_intrinsics` and
# `jl_well_known` in Julia's `llvm-pass-helpers.cpp`), and the code the passes emit (type
# tag loads, write barriers).

## constants of Julia's runtime (the same on every target)

# GC bits in an object's header word (`julia_internal.h`); GC_IN_IMAGE_REMSET since 1.13
const GC_MARKED = 1
const GC_OLD_MARKED = 3
const GC_IN_IMAGE = 4
const GC_IN_IMAGE_REMSET = 8
const GC_IN_IMAGE_NOT_REMSET = GC_IN_IMAGE

# the alignment of small GC allocations and of types (`JL_SMALL_BYTE_ALIGNMENT`): type
# tags are the header word before an object, whose low 4 bits are GC bits
const JL_SMALL_BYTE_ALIGNMENT = 16

# GC states of a thread (`julia_threads.h`)
const JL_GC_STATE_SAFE = 2

# a GC frame starts with two words (`jl_gcframe_t`: nroots, prev)
const GC_FRAME_HEADER_SLOTS = 2

# the alignment of objects the GC allocates (`JL_HEAP_ALIGNMENT`)
const JL_HEAP_ALIGNMENT = JL_SMALL_BYTE_ALIGNMENT


## GenericMemory

# The layout of a GenericMemory, which depends on the size of a pointer: the header
# (`jl_genericmemory_t`) holds the length, then the data pointer. Julia's C++ computes these
# for the pointers of the machine it runs on; the ports use the target's.

genericmemory_length_offset(ptrsize::Integer) = 0
genericmemory_ptr_offset(ptrsize::Integer) = ptrsize
genericmemory_header_size(ptrsize::Integer) = 2 * ptrsize

# the size of the largest objects in GC pools (`GC_MAX_SZCLASS`)
gc_max_szclass(ptrsize::Integer) = 2032 - ptrsize

# A GenericMemory whose data fits a GC pool together with its header is allocated as a
# single object, with the data at this offset (`JL_GENERICMEMORY_INLINE_DATA_OFFSET`).
# Larger ones get their data from `jl_gc_managed_malloc`.
genericmemory_inline_data_offset(ptrsize::Integer) =
    cld(genericmemory_header_size(ptrsize), JL_SMALL_BYTE_ALIGNMENT) * JL_SMALL_BYTE_ALIGNMENT
genericmemory_data_inline(nbytes::Integer, ptrsize::Integer) =
    nbytes <= gc_max_szclass(ptrsize) - genericmemory_inline_data_offset(ptrsize)

# If `call` is a `julia.gc_alloc_memory` (the function `alloc_memory`, Julia 1.15 and
# later) of a constant size whose data will be inline, the size of the whole object
# (`JuliaPassContext::getInlineMemorySize`); otherwise `nothing`.
function inline_memory_size(alloc_memory::Union{Nothing,LLVM.Function},
                            call::Instruction, dl::DataLayout)
    alloc_memory === nothing && return nothing
    call isa CallInst && call.called_operand == alloc_memory || return nothing
    nbytes = call.arguments[2]
    nbytes isa ConstantInt || return nothing
    n = convert(UInt64, nbytes)
    ptrsize = storage_size(dl, LLVM.PointerType(AS_GENERIC))
    genericmemory_data_inline(n, ptrsize) || return nothing
    return Int(genericmemory_inline_data_offset(ptrsize) + n)
end


## tracked pointers

# a scalar pointer type in one of Julia's address spaces (10 to 13)
is_special_ptr(@nospecialize(t::LLVMType)) =
    t isa PointerType && AS_TRACKED <= t.addrspace <= AS_LOADED

# how many pointers in Julia's address spaces a type holds (`count`), whether it holds
# anything else (`all == false`), and whether any of them isn't tracked (`derived`)
struct CountTrackedPointers
    count::Int
    all::Bool
    derived::Bool
end

function CountTrackedPointers(@nospecialize(t::LLVMType), ignore_loaded::Bool=false)
    count = 0
    all = true
    derived = false
    if t isa PointerType
        if is_special_ptr(t)
            as = t.addrspace
            if !(ignore_loaded && as == AS_LOADED)
                count += 1
                as != AS_TRACKED && (derived = true)
            end
        end
    elseif is_composite(t)
        for elt in subtypes(t)
            sub = CountTrackedPointers(elt, ignore_loaded)
            count += sub.count
            all &= sub.all
            derived |= sub.derived
        end
        if t isa ArrayType || is_vector_type(t)
            count *= composite_num_elements(t)
        end
    end
    count == 0 && (all = false)
    return CountTrackedPointers(count, all, derived)
end

function has_loaded_ty(@nospecialize(t::LLVMType))
    if t isa PointerType
        return t.addrspace == AS_LOADED
    elseif is_composite(t)
        return any(has_loaded_ty, subtypes(t))
    end
    return false
end

# the index paths of the special pointers inside a type, like `TrackCompositeType`
function track_composite_type(@nospecialize(t::LLVMType))
    numberings = Vector{Vector{Int}}()
    idxs = Int[]
    function walk(t)
        if t isa PointerType
            is_special_ptr(t) && push!(numberings, copy(idxs))
        elseif is_composite(t)
            for idx in 0:composite_num_elements(t)-1
                push!(idxs, idx)
                walk(composite_element_type(t, idx))
                pop!(idxs)
            end
        end
    end
    walk(t)
    return numberings
end

## TBAA

# Julia's TBAA access tag for a type `name` under `parent` (or the root), and the type
# node (`tbaa_make_child_with_context`)
function tbaa_make_child(name::String, parent=nothing; constant::Bool=false)
    jtbaa = MDNode([MDString("jtbaa")])
    root = MDNode([MDString("jtbaa"), jtbaa, i64_metadata(0)])
    scalar = MDNode([MDString(name), something(parent, root), i64_metadata(0)])
    tag = constant ? MDNode([scalar, scalar, i64_metadata(0), i64_metadata(1)]) :
                     MDNode([scalar, scalar, i64_metadata(0)])
    return tag, scalar
end

tbaa_gcframe() = first(tbaa_make_child("jtbaa_gcframe"))
tbaa_tag() = first(tbaa_make_child("jtbaa_tag", last(tbaa_make_child("jtbaa_data"))))
tbaa_const() = first(tbaa_make_child("jtbaa_const"; constant=true))

# Julia's TBAA access tags that the GC lowering passes attach (`tbaa_gcframe`, `tbaa_tag`
# and `tbaa_const` of C++'s pass context), which a pass keeps once built (`tbaa_tags`)
struct TBAATags
    gcframe::MDNode
    tag::MDNode
    constant::MDNode
end

TBAATags() = TBAATags(tbaa_gcframe(), tbaa_tag(), tbaa_const())

# set a TBAA tag, and mark loads of constant memory (the `tbaa_const` tag of `tags`)
# invariant (`tbaa_decorate`)
function tbaa_decorate!(tags::TBAATags, md::MDNode, inst::Instruction)
    inst.metadata[LLVM.MD_tbaa] = md
    if inst isa LLVM.LoadInst && md == tags.constant
        inst.metadata[LLVM.MD_invariant_load] = MDNode(Metadata[])
    end
    return inst
end

# Whether the access tag `tag`, or a type it derives from up to the root, has one of
# `names`, like Julia's `isTBAA`.
function tbaa_derives_from(tag::MDNode, names)
    node = tag
    while length(node.operands) > 1
        parent = node.operands[2]
        parent isa MDNode && !isempty(parent.operands) || return false
        name = parent.operands[1]
        name isa MDString || return false
        convert(String, name) in names && return true
        node = parent
    end
    return false
end

# The access tag `tag` without its immutability flag, like LLVM's
# `MDBuilder::createMutableTBAAAccessTag`: the tag itself if it is mutable, otherwise a
# new tag `!{base, access, i64 offset}`, or `!{base, access, i64 offset, i64 size}` for the
# new TBAA format (whose access types aren't named by a string).
function mutable_tbaa_tag(tag::MDNode)
    ops = tag.operands
    base, access = ops[1], ops[2]
    new_format = access.operands[1] isa MDNode
    flag = new_format ? 5 : 4
    length(ops) < flag && return tag
    metadata_int(ops[flag]) == 0 && return tag
    i64(op) = Metadata(ConstantInt(LLVM.Int64Type(), metadata_int(op)))
    return new_format ? MDNode([base, access, i64(ops[3]), i64(ops[4])]) :
                        MDNode([base, access, i64(ops[3])])
end


## the context of the emitters

# What the emitters need: the dialect, the module, the builder (positioned by the caller,
# with the debug location the C++ builder would have), the runtime facts, the types of
# the module's layout, and Julia's TBAA tags (built on first use, `tbaa_tags`).
mutable struct GCCodegen
    dialect::Dialect
    mod::LLVM.Module
    builder::IRBuilder
    layout::RuntimeFacts
    dl::DataLayout
    T_prjlvalue::LLVMType     # a tracked pointer
    T_size::LLVMType          # the integer of a pointer's size
    tbaa::Union{Nothing,TBAATags}
end

# `tbaa`: tags that the pass keeps for longer than the context, e.g. for a whole run
function GCCodegen(dialect::Dialect, mod::LLVM.Module, builder::IRBuilder,
                   layout::RuntimeFacts; tbaa::Union{Nothing,TBAATags}=nothing)
    dl = mod.datalayout
    T_size = LLVM.IntType(8 * storage_size(dl, LLVM.PointerType(AS_GENERIC)))
    return GCCodegen(dialect, mod, builder, layout, dl, LLVM.PointerType(AS_TRACKED), T_size,
                     tbaa)
end

function tbaa_tags(g::GCCodegen)
    g.tbaa === nothing && (g.tbaa = TBAATags())
    return g.tbaa::TBAATags
end

pointer_size(g::GCCodegen) = storage_size(g.dl, LLVM.PointerType(AS_GENERIC))
pointer_align(g::GCCodegen) = abi_alignment(g.dl, LLVM.PointerType(AS_GENERIC))


## the GC stack

# the GC stack of a function (`JuliaPassContext::getPGCstack`): a call to one of the
# getters (`julia.get_pgcstack`, `julia.get_pgcstack_or_new`) in the entry block, or an
# argument with the `gcstack` attribute (Julia 1.13 and later)
function get_pgcstack(dialect::Dialect, f::LLVM.Function, getter, adopt)
    if getter !== nothing || adopt !== nothing
        for inst in first(f.blocks).instructions
            inst isa LLVM.CallInst || continue
            callee = inst.called_operand
            if is_fn(getter, callee) || is_fn(adopt, callee)
                return inst
            end
        end
    end
    if dialect.gc_stack_argument
        for (i, arg) in enumerate(f.parameters)
            haskey(f.parameter_attributes[i], "gcstack") && return arg
        end
    end
    return nothing
end


## declarations of GC intrinsics (`jl_intrinsics`, `jl_well_known`)

# `memory(argmem: readwrite, inaccessiblemem: readwrite)`, or the attribute it replaced
# before LLVM 16
inaccessible_or_arg_mem_only() =
    LLVM.version() < v"16" ? EnumAttribute("inaccessiblemem_or_argmemonly") :
        EnumAttribute(MemoryEffects(argmem=:readwrite, inaccessiblemem=:readwrite))

alloc_size_attr(elem_size_arg::Integer) =
    EnumAttribute("allocsize", (UInt64(elem_size_arg) << 32) | 0xffffffff)

# the attributes of allocation functions (`addGCAllocAttributes`)
function add_gc_alloc_attributes!(g::GCCodegen, f::LLVM.Function)
    if g.dialect.gc_alloc_bytes_tag
        push!(f.function_attributes,
              EnumAttribute(MemoryEffects(argmem=:read, inaccessiblemem=:readwrite)))
        push!(f.function_attributes, EnumAttribute("allockind", 1))  # AllocFnKind::Alloc
        push!(f.function_attributes, EnumAttribute("willreturn"))
        push!(f.function_attributes, EnumAttribute("nounwind"))
    end
    push!(f.return_attributes, EnumAttribute("noalias"))
    push!(f.return_attributes, EnumAttribute("nonnull"))
    return f
end

# the attributes of the runtime's allocation functions for cancellation reset regions
# (`addResetSafeGCAllocAttributes`, Julia 1.14): without the memory effects, as they
# also update the task's reset context
function add_reset_safe_gc_alloc_attributes!(f::LLVM.Function)
    push!(f.function_attributes, EnumAttribute("allockind", 1))  # AllocFnKind::Alloc
    push!(f.function_attributes, EnumAttribute("willreturn"))
    push!(f.function_attributes, EnumAttribute("nounwind"))
    push!(f.return_attributes, EnumAttribute("noalias"))
    push!(f.return_attributes, EnumAttribute("nonnull"))
    return f
end

# the names of the runtime's allocation functions (`jl_well_known`)
function gc_alloc_function_name(dialect::Dialect, which::Symbol)
    entry_points = dialect.gc_alloc_entry_points
    if which === :gc_small_alloc
        entry_points === :pool ? "ijl_gc_pool_alloc" :
        entry_points === :pool_instrumented ? "ijl_gc_pool_alloc_instrumented" :
                                              "ijl_gc_small_alloc"
    elseif which === :gc_big_alloc
        entry_points === :pool_instrumented ? "ijl_gc_big_alloc_instrumented" :
                                              "ijl_gc_big_alloc"
    else
        error("unknown allocation function $which")
    end
end

# the name of a GC intrinsic (`jl_intrinsics`) or runtime function (`jl_well_known`)
function gc_declaration_name(dialect::Dialect, which::Symbol)
    return if which === :get_gc_frame_slot
        "julia.get_gc_frame_slot"
    elseif which === :gc_alloc_bytes
        "julia.gc_alloc_bytes"
    elseif which === :new_gc_frame
        "julia.new_gc_frame"
    elseif which === :push_gc_frame
        "julia.push_gc_frame"
    elseif which === :pop_gc_frame
        "julia.pop_gc_frame"
    elseif which === :safepoint
        "julia.safepoint"
    elseif which === :queue_gc_root
        "julia.queue_gc_root"
    elseif which === :gc_queue_root
        "ijl_gc_queue_root"
    elseif which === :gc_queue_root_reset_safe
        "ijl_gc_queue_root_reset_safe"
    elseif which in (:gc_small_alloc, :gc_big_alloc)
        gc_alloc_function_name(dialect, which)
    elseif which === :gc_small_alloc_reset_safe
        "ijl_gc_small_alloc_reset_safe"
    elseif which === :gc_big_alloc_reset_safe
        "ijl_gc_big_alloc_reset_safe"
    elseif which === :gc_alloc_typed
        "ijl_gc_alloc_typed"
    elseif which === :gc_alloc_typed_reset_safe
        "ijl_gc_alloc_typed_reset_safe"
    elseif which === :gc_alloc_genericmemory
        # not among the functions that the library exports with an `ijl_` prefix
        "jl_alloc_genericmemory_unchecked"
    else
        error("unknown GC intrinsic $which")
    end
end

# the type of a GC intrinsic or runtime function, built apart from its name so that one
# that is already declared is found without building it
function gc_declaration_type(g::GCCodegen, which::Symbol)
    T_ptr = LLVM.PointerType(AS_GENERIC)
    T_int32 = LLVM.Int32Type()
    T_void = LLVM.VoidType()
    T_size = g.T_size
    # from Julia 1.11 on, the allocation functions take the type tag as an integer
    tag = g.dialect.gc_alloc_bytes_tag ? LLVMType[T_size] : LLVMType[]
    return if which === :get_gc_frame_slot
        LLVM.FunctionType(T_ptr, [T_ptr, T_int32])
    elseif which === :gc_alloc_bytes
        LLVM.FunctionType(g.T_prjlvalue, [T_ptr, T_size, tag...])
    elseif which === :new_gc_frame
        LLVM.FunctionType(T_ptr, [T_int32])
    elseif which === :push_gc_frame
        LLVM.FunctionType(T_void, [T_ptr, T_int32])
    elseif which === :pop_gc_frame
        LLVM.FunctionType(T_void, [T_ptr])
    elseif which === :safepoint
        LLVM.FunctionType(T_void, [T_ptr])
    elseif which in (:queue_gc_root, :gc_queue_root, :gc_queue_root_reset_safe)
        LLVM.FunctionType(T_void, [g.T_prjlvalue])
    elseif which in (:gc_small_alloc, :gc_small_alloc_reset_safe)
        LLVM.FunctionType(g.T_prjlvalue, [T_ptr, T_int32, T_int32, tag...])
    elseif which in (:gc_big_alloc, :gc_big_alloc_reset_safe)
        LLVM.FunctionType(g.T_prjlvalue, [T_ptr, T_size, tag...])
    elseif which in (:gc_alloc_typed, :gc_alloc_typed_reset_safe)
        # Julia 1.10 passes a null pointer instead of the tag
        LLVM.FunctionType(g.T_prjlvalue, [T_ptr, T_size, isempty(tag) ? T_ptr : T_size])
    elseif which === :gc_alloc_genericmemory
        # the thread-local state, the size of the data and the type
        LLVM.FunctionType(g.T_prjlvalue, [T_ptr, T_size, T_ptr])
    else
        error("unknown GC intrinsic $which")
    end
end

# the name and type of a GC intrinsic or runtime function; this always builds the type,
# so code that may find the function already declared should use `get_or_declare`
gc_declaration(g::GCCodegen, which::Symbol) =
    gc_declaration_name(g.dialect, which), gc_declaration_type(g, which)

"""
    JuliaIR.DeclarationError

The error thrown by a pass that needs to call a function of Julia's runtime (or one of
Julia's intrinsics) when the module already has a function of that name with another
type: calling it would create invalid IR. The module is not changed by the pass before
the error.
"""
struct DeclarationError <: Exception
    name::String
    expected::String
    found::String
end

Base.showerror(io::IO, err::DeclarationError) =
    print(io, "DeclarationError: the module declares ", err.name, " as ", err.found,
          ", but Julia's runtime defines it as ", err.expected)

# a GC intrinsic or runtime function, declared if the module doesn't have it yet
# (`JuliaPassContext::getOrDeclare`). An existing function is used whatever its type,
# like the C++, unless `check`, which throws a `DeclarationError` for another type.
function get_or_declare(g::GCCodegen, which::Symbol; check::Bool=false)
    name = gc_declaration_name(g.dialect, which)
    existing = get(g.mod.functions, name, nothing)
    if existing !== nothing
        if check
            ft = gc_declaration_type(g, which)
            existing.function_type != ft &&
                throw(DeclarationError(name, string(ft), string(existing.function_type)))
        end
        return existing
    end
    f = LLVM.Function(g.mod, name, gc_declaration_type(g, which))
    if which in (:gc_alloc_bytes, :gc_big_alloc, :gc_alloc_typed)
        push!(f.function_attributes, alloc_size_attr(1))
        add_gc_alloc_attributes!(g, f)
    elseif which === :gc_small_alloc
        push!(f.function_attributes, alloc_size_attr(2))
        add_gc_alloc_attributes!(g, f)
    elseif which === :gc_alloc_genericmemory
        # without `allocsize`: its size is that of the data, not of the object
        add_gc_alloc_attributes!(g, f)
    elseif which in (:gc_big_alloc_reset_safe, :gc_alloc_typed_reset_safe)
        push!(f.function_attributes, alloc_size_attr(1))
        add_reset_safe_gc_alloc_attributes!(f)
    elseif which === :gc_small_alloc_reset_safe
        push!(f.function_attributes, alloc_size_attr(2))
        add_reset_safe_gc_alloc_attributes!(f)
    elseif which === :new_gc_frame
        push!(f.return_attributes, EnumAttribute("noalias"))
        push!(f.return_attributes, EnumAttribute("nonnull"))
    elseif which in (:queue_gc_root, :gc_queue_root, :safepoint)
        push!(f.function_attributes, inaccessible_or_arg_mem_only())
    end
    return f
end

function call_intrinsic!(g::GCCodegen, which::Symbol, args::Vector{<:Value},
                         name::String="")
    f = get_or_declare(g, which)
    return call!(g.builder, f.function_type, f, Value[args...], name)
end


## type tags

# the address of the type tag of an object: the word before it (`EmitTagPtr`)
function emit_tag_ptr!(g::GCCodegen, t::LLVMType, @nospecialize(v::Value))
    name = g.dialect.gc_names ? LLVM.name(v) * ".tag_addr" : ""
    return inbounds_gep!(g.builder, t, v, [ConstantInt(g.T_size, -1)], name)
end

# a load of the type tag of an object (`EmitLoadTag`)
function emit_load_tag!(g::GCCodegen, @nospecialize(v::Value))
    addr = emit_tag_ptr!(g, g.T_size, v)
    name = g.dialect.gc_names ? LLVM.name(v) * ".tag" : ""
    load = load!(g.builder, g.T_size, addr, name; align=pointer_align(g),
                 ordering=LLVM.AtomicOrdering.Unordered,
                 volatile=g.dialect.gc_tag_load_volatile)
    load.metadata[LLVM.MD_tbaa] = tbaa_tags(g).tag
    # the tag is at least 16 (a type), so it is still not null after masking the GC bits
    load.metadata[LLVM.MD_range] = MDNode([i64_metadata_of(g.T_size, JL_SMALL_BYTE_ALIGNMENT),
                                           i64_metadata_of(g.T_size, 0)])
    return load
end

i64_metadata_of(t::LLVMType, x::Integer) = Metadata(ConstantInt(t, x))


## write barriers

# The children of a write barrier (`writeBarrierChildren`): the arguments after the
# parent, without the slot operands of field barriers, which alternate with the children.
# `fns` is a pass' table of Julia's functions (`JuliaFunctions`, LateLowerGCFrame's
# `GCFunctions`).
function write_barrier_children(fns, call::Instruction)
    args = collect(call.arguments)
    field = is_field_write_barrier(fns, call.called_operand)
    return [args[i] for i in 2:length(args) if !field || isodd(i)]
end

# the type of `julia.object_write_barrier`: `void (ptr addrspace(10), ...)`
object_write_barrier_type() =
    LLVM.FunctionType(LLVM.VoidType(), [LLVM.PointerType(AS_TRACKED)]; vararg=true)

# The declaration of `julia.object_write_barrier` in `mod` (Julia 1.14 and later), added
# if missing, with the attributes that codegen gives it (`getWriteBarrierAttributes`: the
# barrier reads the headers of the parent and the children, and the slot it guards, which
# keeps it ordered after the store). Throws if the module declares it with another type,
# which a call can't be built for.
function get_or_declare_object_write_barrier!(mod::LLVM.Module)
    name = "julia.object_write_barrier"
    ft = object_write_barrier_type()
    f = get(mod.functions, name, nothing)
    if f !== nothing
        check_object_write_barrier(f)
        return f
    end
    f = LLVM.Function(mod, name, ft)
    push!(f.function_attributes,
          EnumAttribute(MemoryEffects(argmem=:read, inaccessiblemem=:readwrite)))
    push!(f.function_attributes, EnumAttribute("nounwind"))
    push!(f.function_attributes, EnumAttribute("norecurse"))
    push!(f.parameter_attributes[1], EnumAttribute("readonly"))
    return f
end

function check_object_write_barrier(f::LLVM.Function)
    f.function_type == object_write_barrier_type() ||
        throw(ArgumentError("julia.object_write_barrier is declared as $(string(f.function_type)), not as $(string(object_write_barrier_type()))"))
    return
end

# A write barrier of `parent` for `children`, before the barrier call `ci`, in the style of
# `lowering` (`Dialect.gc_barrier_lowering`; `:image` for FinalLowerGC from Julia 1.14 on):
# when the parent is old and marked, and one of the children isn't marked (or, with
# `:image`, the parent is in the system image but not yet in its remembered set), queue
# the parent. Returns the `julia.queue_gc_root` call.
function emit_write_barrier!(g::GCCodegen, ci::Instruction, @nospecialize(parent::Value),
                             children::Vector{<:Value}, lowering::Symbol, debug_info::Int)
    builder = g.builder
    T_size = g.T_size
    named = lowering in (:named, :image)
    set_name!(v, name) = (lowering === :debug_named && debug_info >= 2 &&
                          !(v isa LLVM.Constant)) && (v.name = name)
    position_before!(builder, ci; debug=true)
    par_tag = emit_load_tag!(g, parent)
    par_bits = and!(builder, par_tag, ConstantInt(T_size, GC_OLD_MARKED),
                    named ? "parent_bits" : "")
    set_name!(par_bits, "parent_bits")
    par_old_marked = icmp!(builder, LLVM.IntPredicate.EQ, par_bits,
                           ConstantInt(T_size, GC_OLD_MARKED),
                           named ? "parent_old_marked" : "")
    set_name!(par_old_marked, "parent_old_marked")
    may_trig_term = split_block_and_insert_if_then!(par_old_marked, ci)
    position_before!(builder, may_trig_term; debug=true)
    may_trig_block = may_trig_term.parent
    named && (may_trig_block.name = "may_trigger_wb")
    set_name!(may_trig_block, "may_trigger_wb")
    par_is_image = nothing
    if lowering === :image
        # at the generational boundaries above the youngest, only whether the parent
        # is already in the relevant remembered set can be checked
        par_in_image = and!(builder, par_tag,
                            ConstantInt(T_size, GC_IN_IMAGE | GC_IN_IMAGE_REMSET),
                            "parent_in_image")
        par_is_image = icmp!(builder, LLVM.IntPredicate.EQ, par_in_image,
                             ConstantInt(T_size, GC_IN_IMAGE_NOT_REMSET), "parent_is_image")
    end
    any_child_not_marked = nothing
    for child in children
        child_bit = and!(builder, emit_load_tag!(g, child), ConstantInt(T_size, GC_MARKED),
                         named ? "child_bit" : "")
        set_name!(child_bit, "child_bit")
        child_not_marked = icmp!(builder, LLVM.IntPredicate.EQ, child_bit,
                                 ConstantInt(T_size, 0),
                                 lowering === :unnamed ? "" : "child_not_marked")
        set_name!(child_not_marked, "child_not_marked")
        any_child_not_marked = any_child_not_marked === nothing ? child_not_marked :
            or!(builder, any_child_not_marked, child_not_marked)
    end
    should_trigger = par_is_image === nothing ? any_child_not_marked :
        or!(builder, par_is_image, any_child_not_marked, "should_trigger_wb")
    trig_term = split_block_and_insert_if_then!(should_trigger, may_trig_term;
                                                weights=(1, 9))
    trig_block = trig_term.parent
    named && (trig_block.name = "trigger_wb")
    set_name!(trig_block, "trigger_wb")
    position_before!(builder, trig_term; debug=true)
    return call_intrinsic!(g, :queue_gc_root, Value[parent])
end


## the task, safepoints and GC states

# Code that reaches the current task's thread-local state from its GC stack, polls
# safepoints and switches the GC state, as emitted by the helpers of Julia's
# `llvm-codegen-shared.h` (`get_current_task_from_pgcstack`, `get_current_ptls_from_task`,
# `get_current_signal_page_from_ptls`, `emit_gc_safepoint`, `emit_gc_state_set`).

# the current task, from its GC stack (`get_current_task_from_pgcstack`)
function current_task_from_pgcstack!(g::GCCodegen, @nospecialize(pgcstack::Value))
    offset = g.layout.task_gcstack
    if g.dialect.gc_ptls_gep === :pointer
        # (the C++ negates the quotient as an unsigned number, which the constant of the
        # pointer-sized type truncates to the same value)
        return inbounds_gep!(g.builder, LLVM.PointerType(AS_GENERIC), pgcstack,
                             [ConstantInt(g.T_size, -(offset ÷ pointer_size(g)))],
                             "current_task")
    else
        return inbounds_gep!(g.builder, LLVM.Int8Type(), pgcstack,
                             [ConstantInt(LLVM.Int32Type(), -offset)], "current_task")
    end
end

# the thread-local state of a task (`get_current_ptls_from_task`)
function current_ptls_from_task!(g::GCCodegen, @nospecialize(task::Value), tbaa::MDNode)
    offset = g.layout.task_ptls
    T_ptr = LLVM.PointerType(AS_GENERIC)
    pptls = if g.dialect.gc_ptls_gep === :pointer
        inbounds_gep!(g.builder, T_ptr, task,
                      [ConstantInt(g.T_size, offset ÷ pointer_size(g))], "ptls_field")
    else
        inbounds_gep!(g.builder, LLVM.Int8Type(), task,
                      [ConstantInt(LLVM.Int32Type(), offset)], "ptls_field")
    end
    ptls_load = load!(g.builder, T_ptr, pptls, "ptls_load"; align=pointer_align(g))
    tbaa_decorate!(tbaa_tags(g), tbaa, ptls_load)
    return ptls_load
end

# the safepoint page of a thread (`get_current_signal_page_from_ptls`), without TBAA when
# `tbaa` is `nothing`
function signal_page_from_ptls!(g::GCCodegen, @nospecialize(ptls::Value),
                                tbaa::Union{Nothing,MDNode})
    T_ptr = LLVM.PointerType(AS_GENERIC)
    offset = g.layout.tls_safepoint
    style = g.dialect.gc_safepoint_load
    psafepoint = if g.dialect.gc_ptls_gep === :pointer
        inbounds_gep!(g.builder, T_ptr, ptls,
                      [ConstantInt(g.T_size, offset ÷ pointer_size(g))])
    else
        inbounds_gep!(g.builder, LLVM.Int8Type(), ptls,
                      [ConstantInt(LLVM.Int32Type(), offset)],
                      style === :monotonic_named ? "safepoint_addr" : "")
    end
    load = load!(g.builder, T_ptr, psafepoint, "safepoint"; align=pointer_align(g),
                 ordering=style === :plain ? LLVM.AtomicOrdering.NotAtomic :
                                             LLVM.AtomicOrdering.Monotonic)
    tbaa === nothing || tbaa_decorate!(tbaa_tags(g), tbaa, load)
    return load
end

emit_signal_fence!(g::GCCodegen) =
    fence!(g.builder, LLVM.AtomicOrdering.SequentiallyConsistent; scope="singlethread")

# A safepoint (`emit_gc_safepoint`): with `final`, a volatile load from the safepoint
# page, which faults when the GC wants this thread to stop; otherwise a call of
# `julia.safepoint` on the page, which FinalLowerGC lowers to that load.
function emit_gc_safepoint!(g::GCCodegen, @nospecialize(ptls::Value),
                            tbaa::Union{Nothing,MDNode}; final::Bool)
    signal_page = signal_page_from_ptls!(g, ptls, tbaa)
    emit_signal_fence!(g)
    if final
        load!(g.builder, g.T_size, signal_page; volatile=true)
    else
        call_intrinsic!(g, :safepoint, Value[signal_page])
    end
    emit_signal_fence!(g)
    return
end

# the address of the thread's GC state (a byte)
gc_state_address!(g::GCCodegen, @nospecialize(ptls::Value)) =
    inbounds_gep!(g.builder, LLVM.Int8Type(), ptls,
                  [ConstantInt(LLVM.Int32Type(), g.layout.tls_gc_state)], "gc_state")

# Julia's C++ stores the byte with the alignment of a pointer, which only holds where the
# offset is a multiple of it.
const GC_STATE_ALIGN = 1

# Set the thread's GC state to `state`, and poll a final safepoint when the dialect's
# condition holds (`emit_gc_state_set(..., final=true)`). The current state is loaded
# unless `old_state` is given. The safepoint goes in two new blocks at the end of the
# function, and the builder is left at the end of the second. Returns the old state.
function emit_gc_state_set!(g::GCCodegen, @nospecialize(ptls::Value), state::Value,
                            old_state::Union{Nothing,Value})
    builder = g.builder
    T_int8 = LLVM.Int8Type()
    condition = g.dialect.gc_state_condition
    gc_state = gc_state_address!(g, ptls)
    if old_state === nothing
        old_state = load!(builder, T_int8, gc_state, condition === :ne ? "old_state" : "";
                          ordering=LLVM.AtomicOrdering.Monotonic)
    end
    store!(builder, state, gc_state; align=GC_STATE_ALIGN,
           ordering=LLVM.AtomicOrdering.Release)
    if condition === :ne
        old_state isa ConstantInt && state isa ConstantInt &&
            convert(UInt64, old_state) == convert(UInt64, state) && return old_state
    else
        old_state isa ConstantInt && iszero(convert(UInt64, old_state)) && return old_state
        state isa ConstantInt && !iszero(convert(UInt64, state)) && return old_state
    end
    f = LLVM.parent(builder.insert_block)
    pass_bb = BasicBlock(f, "safepoint")
    exit_bb = BasicBlock(f, "after_safepoint")
    zero8 = ConstantInt(T_int8, 0)
    cond = if condition === :and
        and!(builder, icmp!(builder, LLVM.IntPredicate.NE, old_state, zero8),
             icmp!(builder, LLVM.IntPredicate.EQ, state, zero8))
    elseif condition === :or
        or!(builder, icmp!(builder, LLVM.IntPredicate.EQ, old_state, zero8),
            icmp!(builder, LLVM.IntPredicate.EQ, state, zero8))
    else
        icmp!(builder, LLVM.IntPredicate.NE, old_state, state, "is_new_state")
    end
    br!(builder, cond, pass_bb, exit_bb)
    position!(builder, LLVM.at_end(pass_bb))
    emit_gc_safepoint!(g, ptls, tbaa_tags(g).constant; final=true)
    br!(builder, exit_bb)
    position!(builder, LLVM.at_end(exit_bb))
    return old_state
end

# enter the GC-unsafe state (`emit_gc_unsafe_enter(..., final=true)`)
emit_gc_unsafe_enter!(g::GCCodegen, @nospecialize(ptls::Value)) =
    emit_gc_state_set!(g, ptls, ConstantInt(LLVM.Int8Type(), 0), nothing)

# leave the GC-unsafe state for `state` (`emit_gc_unsafe_leave(..., final=true)`)
emit_gc_unsafe_leave!(g::GCCodegen, @nospecialize(ptls::Value), state::Value) =
    emit_gc_state_set!(g, ptls, state, ConstantInt(LLVM.Int8Type(), 0))
