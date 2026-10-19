# What Julia's GC lowering passes share (LateLowerGCFrame, FinalLowerGC): the constants
# of the runtime's GC, the declarations of the GC intrinsics and of the runtime functions
# they are lowered to (`JuliaPassContext`, `jl_intrinsics` and `jl_well_known` in Julia's
# `llvm-pass-helpers.cpp`), TBAA nodes, and the code both passes emit (type tag loads,
# write barriers). JuliaLICM uses the write-barrier helpers too.

## constants of Julia's runtime (the same on every target)

# GC bits in an object's header word (`julia_internal.h`); GC_IN_IMAGE_REMSET since 1.13
const GC_MARKED = 1
const GC_OLD_MARKED = 3
const GC_IN_IMAGE = 4
const GC_IN_IMAGE_REMSET = 8
const GC_IN_IMAGE_NOT_REMSET = GC_IN_IMAGE

# type tags are the header word before an object; types are 16-byte aligned, so the low
# 4 bits of the tag are GC bits (`JL_SMALL_BYTE_ALIGNMENT`)
const TAG_ALIGNMENT = 16

# a GC frame starts with two words (`jl_gcframe_t`: nroots, prev)
const GC_FRAME_HEADER_SLOTS = 2


## the state of a GC lowering pass

# A pass that uses these helpers has the fields `dialect`, `mod`, `builder`, `dl`
# (the module's data layout), `T_prjlvalue` (a tracked pointer) and `T_size` (the
# integer of a pointer's size), and a method of `tbaa_tags` that returns its `TBAATags`.
abstract type GCLowering end

pointer_size(p::GCLowering) = storage_size(p.dl, LLVM.PointerType(AS_GENERIC))
pointer_align(p::GCLowering) = abi_alignment(p.dl, LLVM.PointerType(AS_GENERIC))

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
            has_string_attribute(f.parameter_attributes[i], "gcstack") && return arg
        end
    end
    return nothing
end

is_fn(f, @nospecialize(callee)) = f !== nothing && callee !== nothing && f == callee

# position the builder before `inst`, with `inst`'s debug location like C++'s
# `IRBuilder<> builder(inst)`, or without one (`XInst::Create(..., inst)`)
function position_before!(builder::IRBuilder, inst::Instruction; debug::Bool)
    position!(builder, LLVM.before(inst))
    builder.debug_location = debug ? inst.debug_location : nothing
end

function copy_function_attributes!(call::Instruction, f::LLVM.Function)
    for attr in collect(f.function_attributes)
        push!(call.function_attributes, attr)
    end
    for attr in collect(f.return_attributes)
        push!(call.return_attributes, attr)
    end
    for i in 1:length(f.parameters), attr in collect(f.parameter_attributes[i])
        push!(call.argument_attributes[i], attr)
    end
end

md_kind(@nospecialize(v::Value), name::String) =
    API.LLVMGetMDKindIDInContext(context(v), name, length(name))

function metadata_by_name(inst::Instruction, name::String)
    kind = md_kind(inst, name)
    for (k, md) in inst.metadata
        k == kind && return md
    end
    return nothing
end

function set_metadata_by_name!(inst::Instruction, name::String, md::Metadata)
    API.LLVMSetMetadata(inst, md_kind(inst, name), API.LLVMMetadataAsValue(context(inst), md))
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
function add_gc_alloc_attributes!(p::GCLowering, f::LLVM.Function)
    if p.dialect.gc_alloc_bytes_tag
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

# the name and type of a GC intrinsic (`jl_intrinsics`) or runtime function
# (`jl_well_known`)
function gc_declaration(p::GCLowering, which::Symbol)
    T_ptr = LLVM.PointerType(AS_GENERIC)
    T_int32 = LLVM.Int32Type()
    T_void = LLVM.VoidType()
    T_size = p.T_size
    # from Julia 1.11 on, the allocation functions take the type tag as an integer
    tag = p.dialect.gc_alloc_bytes_tag ? LLVMType[T_size] : LLVMType[]
    return if which === :get_gc_frame_slot
        "julia.get_gc_frame_slot", LLVM.FunctionType(T_ptr, [T_ptr, T_int32])
    elseif which === :gc_alloc_bytes
        "julia.gc_alloc_bytes", LLVM.FunctionType(p.T_prjlvalue, [T_ptr, T_size, tag...])
    elseif which === :new_gc_frame
        "julia.new_gc_frame", LLVM.FunctionType(T_ptr, [T_int32])
    elseif which === :push_gc_frame
        "julia.push_gc_frame", LLVM.FunctionType(T_void, [T_ptr, T_int32])
    elseif which === :pop_gc_frame
        "julia.pop_gc_frame", LLVM.FunctionType(T_void, [T_ptr])
    elseif which === :queue_gc_root
        "julia.queue_gc_root", LLVM.FunctionType(T_void, [p.T_prjlvalue])
    elseif which in (:gc_queue_root, :gc_queue_root_reset_safe)
        which === :gc_queue_root ? "ijl_gc_queue_root" : "ijl_gc_queue_root_reset_safe",
        LLVM.FunctionType(T_void, [p.T_prjlvalue])
    elseif which in (:gc_small_alloc, :gc_small_alloc_reset_safe)
        which === :gc_small_alloc ? gc_alloc_function_name(p.dialect, which) :
                                    "ijl_gc_small_alloc_reset_safe",
        LLVM.FunctionType(p.T_prjlvalue, [T_ptr, T_int32, T_int32, tag...])
    elseif which in (:gc_big_alloc, :gc_big_alloc_reset_safe)
        which === :gc_big_alloc ? gc_alloc_function_name(p.dialect, which) :
                                  "ijl_gc_big_alloc_reset_safe",
        LLVM.FunctionType(p.T_prjlvalue, [T_ptr, T_size, tag...])
    elseif which in (:gc_alloc_typed, :gc_alloc_typed_reset_safe)
        # Julia 1.10 passes a null pointer instead of the tag
        which === :gc_alloc_typed ? "ijl_gc_alloc_typed" : "ijl_gc_alloc_typed_reset_safe",
        LLVM.FunctionType(p.T_prjlvalue, [T_ptr, T_size, isempty(tag) ? T_ptr : T_size])
    else
        error("unknown GC intrinsic $which")
    end
end

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
function get_or_declare(p::GCLowering, which::Symbol; check::Bool=false)
    name, ft = gc_declaration(p, which)
    existing = get(p.mod.functions, name, nothing)
    if existing !== nothing
        check && existing.function_type != ft &&
            throw(DeclarationError(name, string(ft), string(existing.function_type)))
        return existing
    end
    f = LLVM.Function(p.mod, name, ft)
    if which in (:gc_alloc_bytes, :gc_big_alloc, :gc_alloc_typed)
        push!(f.function_attributes, alloc_size_attr(1))
        add_gc_alloc_attributes!(p, f)
    elseif which === :gc_small_alloc
        push!(f.function_attributes, alloc_size_attr(2))
        add_gc_alloc_attributes!(p, f)
    elseif which in (:gc_big_alloc_reset_safe, :gc_alloc_typed_reset_safe)
        push!(f.function_attributes, alloc_size_attr(1))
        add_reset_safe_gc_alloc_attributes!(f)
    elseif which === :gc_small_alloc_reset_safe
        push!(f.function_attributes, alloc_size_attr(2))
        add_reset_safe_gc_alloc_attributes!(f)
    elseif which === :new_gc_frame
        push!(f.return_attributes, EnumAttribute("noalias"))
        push!(f.return_attributes, EnumAttribute("nonnull"))
    elseif which in (:queue_gc_root, :gc_queue_root)
        push!(f.function_attributes, inaccessible_or_arg_mem_only())
    end
    return f
end

function call_intrinsic!(p::GCLowering, which::Symbol, args::Vector{<:Value},
                         name::String="")
    f = get_or_declare(p, which)
    return call!(p.builder, f.function_type, f, Value[args...], name)
end


## metadata and type tags

i64_metadata(x::Integer) = Metadata(ConstantInt(LLVM.Int64Type(), x))

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

# set a TBAA tag, and mark loads of constant memory (`constant`, the `tbaa_const` tag)
# invariant (`tbaa_decorate`)
function tbaa_decorate!(md::MDNode, inst::Instruction, constant::MDNode=tbaa_const())
    inst.metadata[LLVM.MD_tbaa] = md
    if inst isa LLVM.LoadInst && md == constant
        inst.metadata[LLVM.MD_invariant_load] = MDNode(Metadata[])
    end
    return inst
end

value_name(@nospecialize(v::Value)) = LLVM.name(v)

# the address of the type tag of an object: the word before it (`EmitTagPtr`)
function emit_tag_ptr!(p::GCLowering, t::LLVMType, @nospecialize(v::Value))
    name = p.dialect.gc_names ? value_name(v) * ".tag_addr" : ""
    return inbounds_gep!(p.builder, t, v, [ConstantInt(p.T_size, -1)], name)
end

# a load of the type tag of an object (`EmitLoadTag`)
function emit_load_tag!(p::GCLowering, @nospecialize(v::Value))
    addr = emit_tag_ptr!(p, p.T_size, v)
    name = p.dialect.gc_names ? value_name(v) * ".tag" : ""
    load = load!(p.builder, p.T_size, addr, name; align=pointer_align(p),
                 ordering=LLVM.API.LLVMAtomicOrderingUnordered,
                 volatile=p.dialect.gc_tag_load_volatile)
    load.metadata[LLVM.MD_tbaa] = tbaa_tags(p).tag
    # the tag is at least 16 (a type), so it is still not null after masking the GC bits
    load.metadata[LLVM.MD_range] = MDNode([i64_metadata_of(p.T_size, TAG_ALIGNMENT),
                                           i64_metadata_of(p.T_size, 0)])
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
function emit_write_barrier!(p::GCLowering, ci::Instruction, @nospecialize(parent::Value),
                             children::Vector{<:Value}, lowering::Symbol, debug_info::Int)
    builder = p.builder
    T_size = p.T_size
    named = lowering in (:named, :image)
    set_name!(v, name) = (lowering === :debug_named && debug_info >= 2 &&
                          !(v isa LLVM.Constant)) && (v.name = name)
    position_before!(builder, ci; debug=true)
    par_tag = emit_load_tag!(p, parent)
    par_bits = and!(builder, par_tag, ConstantInt(T_size, GC_OLD_MARKED),
                    named ? "parent_bits" : "")
    set_name!(par_bits, "parent_bits")
    par_old_marked = icmp!(builder, LLVM.API.LLVMIntEQ, par_bits,
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
        par_is_image = icmp!(builder, LLVM.API.LLVMIntEQ, par_in_image,
                             ConstantInt(T_size, GC_IN_IMAGE_NOT_REMSET), "parent_is_image")
    end
    any_child_not_marked = nothing
    for child in children
        child_bit = and!(builder, emit_load_tag!(p, child), ConstantInt(T_size, GC_MARKED),
                         named ? "child_bit" : "")
        set_name!(child_bit, "child_bit")
        child_not_marked = icmp!(builder, LLVM.API.LLVMIntEQ, child_bit,
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
    return call_intrinsic!(p, :queue_gc_root, Value[parent])
end
