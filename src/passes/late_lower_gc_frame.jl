# LateLowerGCFrame: port of Julia's GC root placement pass (`src/llvm-late-gc-lowering.cpp`
# and what it uses from `llvm-gc-interface-passes.h`, `llvm-pass-helpers.cpp` and
# `llvm-codegen-shared.h`). The design is described at the top of
# `llvm-gc-interface-passes.h`; the functions here keep the names and structure of the
# C++ (`LocalScan` is `local_scan`, `ComputeLiveness` is `compute_liveness!`, ...), so
# that both can be read side by side. Differences between Julia versions are fields of
# `Dialect` (the `gc_*` ones); deviations from the C++ are documented in
# docs/src/late_lower_gc_frame.md.


## constants of Julia's runtime (the same on every target)

# GC states of a thread (`julia_threads.h`)
const JL_GC_STATE_SAFE = 2

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


## types and values

const TypeRef = API.LLVMTypeRef
const ValueRef = API.LLVMValueRef

type_kind(t::TypeRef) = API.LLVMGetTypeKind(t)
vref(@nospecialize(v::Value)) = Base.unsafe_convert(ValueRef, v)

is_pointer_type(t::TypeRef) = type_kind(t) == API.LLVMPointerTypeKind
is_vector_type(t::TypeRef) = type_kind(t) in (API.LLVMVectorTypeKind,
                                              API.LLVMScalableVectorTypeKind)
is_struct_type(t::TypeRef) = type_kind(t) == API.LLVMStructTypeKind
is_array_type(t::TypeRef) = type_kind(t) == API.LLVMArrayTypeKind
type_addrspace(t::TypeRef) = Int(API.LLVMGetPointerAddressSpace(t))

# a scalar pointer type in one of Julia's address spaces (10 to 13)
is_special_ptr(t::TypeRef) =
    is_pointer_type(t) && AS_TRACKED <= type_addrspace(t) <= AS_LOADED

# a pointer, or vector of pointers, in the tracked address space
is_tracked_value(@nospecialize(v::Value)) =
    let t = scalar_typeref(typeref(v))
        is_pointer_type(t) && type_addrspace(t) == AS_TRACKED
    end

# the address space of a pointer or vector of pointers
value_addrspace(@nospecialize(v::Value)) = type_addrspace(scalar_typeref(typeref(v)))

is_pointer_value(@nospecialize(v::Value)) = is_pointer_type(typeref(v))

function array_length(t::TypeRef)
    return LLVM.version() >= v"17" ? Int(API.LLVMGetArrayLength2(t)) :
                                     Int(API.LLVMGetArrayLength(t))
end

# the number of elements of a struct, array or vector type (the minimum for scalable
# vectors), like `getCompositeNumElements`
function composite_num_elements(t::TypeRef)
    is_struct_type(t) && return Int(API.LLVMCountStructElementTypes(t))
    is_array_type(t) && return array_length(t)
    return Int(API.LLVMGetVectorSize(t))
end

# the type of element `i` (0-based) of a struct, array or vector type
composite_element_type(t::TypeRef, i::Integer) =
    is_struct_type(t) ? API.LLVMStructGetTypeAtIndex(t, i) : API.LLVMGetElementType(t)

# the types contained in a struct, array or vector type (`Type::subtypes`)
function subtypes(t::TypeRef)
    is_struct_type(t) || return [API.LLVMGetElementType(t)]
    return [API.LLVMStructGetTypeAtIndex(t, i) for i in 0:composite_num_elements(t)-1]
end

is_composite(t::TypeRef) = is_struct_type(t) || is_array_type(t) || is_vector_type(t)

# how many pointers in Julia's address spaces a type holds (`count`), whether it holds
# anything else (`all == false`), and whether any of them isn't tracked (`derived`)
struct CountTrackedPointers
    count::Int
    all::Bool
    derived::Bool
end

function CountTrackedPointers(t::TypeRef, ignore_loaded::Bool=false)
    count = 0
    all = true
    derived = false
    if is_pointer_type(t)
        if is_special_ptr(t)
            as = type_addrspace(t)
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
        if is_array_type(t)
            count *= array_length(t)
        elseif is_vector_type(t)
            count *= Int(API.LLVMGetVectorSize(t))
        end
    end
    count == 0 && (all = false)
    return CountTrackedPointers(count, all, derived)
end

function has_loaded_ty(t::TypeRef)
    if is_pointer_type(t)
        return type_addrspace(t) == AS_LOADED
    elseif is_composite(t)
        return any(has_loaded_ty, subtypes(t))
    end
    return false
end

# the index paths of the special pointers inside a type, like `TrackCompositeType`
function track_composite_type(t::TypeRef)
    numberings = Vector{Vector{Int}}()
    idxs = Int[]
    function walk(t)
        if is_pointer_type(t)
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

# the type at a path of indices in an aggregate type (`ExtractValueInst::getIndexedType`)
function indexed_type(t::TypeRef, idxs)
    for i in idxs
        t = composite_element_type(t, i)
    end
    return t
end

is_undef(@nospecialize(v::Value)) = v isa UndefValue || v isa PoisonValue

attr_kind(a::Attribute) = string(LLVM.kind(a))

# `ConstantData`: constants without operands
is_constant_data(@nospecialize(v::Value)) =
    API.LLVMIsAConstantInt(v) != C_NULL || API.LLVMIsAConstantFP(v) != C_NULL ||
    API.LLVMIsAConstantPointerNull(v) != C_NULL ||
    API.LLVMIsAConstantAggregateZero(v) != C_NULL ||
    API.LLVMIsAConstantDataSequential(v) != C_NULL ||
    API.LLVMIsAConstantTokenNone(v) != C_NULL || API.LLVMIsAUndefValue(v) != C_NULL

# the opcode of an instruction or constant expression (`Operator::getOpcode`), or nothing
function operator_opcode(@nospecialize(v::Value))
    v isa Instruction && return v.opcode
    v isa LLVM.ConstantExpr && return API.LLVMGetConstOpcode(v)
    return nothing
end

# the argument a call returns (`CallBase::getReturnedArgOperand`), or nothing
function returned_argument(call::Instruction)
    callee = call.called_operand
    for i in 1:length(call.arguments)
        attrs = collect(call.argument_attributes[i])
        if callee isa LLVM.Function && i <= length(callee.parameters)
            append!(attrs, collect(callee.parameter_attributes[i]))
        end
        any(a -> a isa EnumAttribute && attr_kind(a) == "returned", attrs) &&
            return call.arguments[i]
    end
    return nothing
end

# `Value::stripInBoundsOffsets`: through inbounds GEPs, bitcasts, address space casts and
# calls returning an argument
function strip_in_bounds_offsets(@nospecialize(v::Value))
    is_pointer_value(v) || return v
    visited = Set{ValueRef}((vref(v),))
    while true
        op = operator_opcode(v)
        if op == API.LLVMGetElementPtr
            API.LLVMIsInBounds(v) != 0 || return v
            v = Value(API.LLVMGetOperand(v, 0))
        elseif op == API.LLVMBitCast
            new = Value(API.LLVMGetOperand(v, 0))
            is_pointer_value(new) || return v
            v = new
        elseif op == API.LLVMAddrSpaceCast
            v = Value(API.LLVMGetOperand(v, 0))
        elseif v isa LLVM.CallBase
            ret = returned_argument(v)
            ret === nothing && return v
            v = ret
        else
            return v
        end
        vref(v) in visited && return v
        push!(visited, vref(v))
    end
end


# the function a call calls, if its type matches (`CallBase::getCalledFunction`)
function called_function(call::Instruction)
    callee = call.called_operand
    callee isa LLVM.Function || return nothing
    callee.function_type == call.called_type || return nothing
    return callee
end

# whether a call is an `IntrinsicInst` (calls a function named `llvm.*`)
function is_intrinsic_call(call::Instruction)
    callee = called_function(call)
    return callee !== nothing && startswith(LLVM.name(callee), "llvm.")
end

intrinsic_is(call::Instruction, intr::Intrinsic) =
    let callee = called_function(call)
        callee !== nothing && LLVM.isintrinsic(callee) && callee.intrinsic == intr
    end

has_string_fn_attr(attrs, name::String) =
    any(a -> a isa StringAttribute && attr_kind(a) == name, attrs)
has_enum_fn_attr(attrs, name::String) =
    any(a -> a isa EnumAttribute && attr_kind(a) == name, attrs)

# `CallBase::hasFnAttr`: on the call, or on the function it calls
function call_has_fn_attr(call::Instruction, name::String, string_attr::Bool)
    has = string_attr ? has_string_fn_attr : has_enum_fn_attr
    has(collect(call.function_attributes), name) && return true
    callee = called_function(call)
    return callee !== nothing && has(collect(callee.function_attributes), name)
end

can_return_twice(call::Instruction) = call_has_fn_attr(call, "returns_twice", false)

# the memory effects of the attributes of a function or call site: the `memory`
# attribute, or the legacy ones before LLVM 16; unrestricted without them
function attribute_memory_effects(attrs)
    effects = MemoryEffects(:readwrite)
    for a in collect(attrs)
        a isa EnumAttribute || continue
        k = attr_kind(a)
        if k == "memory"
            effects &= MemoryEffects(a)
        elseif k == "readnone"
            effects &= MemoryEffects(:none)
        elseif k == "readonly"
            effects &= MemoryEffects(:read)
        elseif k == "writeonly"
            effects &= MemoryEffects(:write)
        elseif k == "argmemonly"
            effects &= MemoryEffects(argmem=:readwrite)
        elseif k == "inaccessiblememonly"
            effects &= MemoryEffects(inaccessiblemem=:readwrite)
        elseif k == "inaccessiblemem_or_argmemonly"
            effects &= MemoryEffects(argmem=:readwrite, inaccessiblemem=:readwrite)
        end
    end
    return effects
end

function_memory_effects(f::LLVM.Function) =
    attribute_memory_effects(f.function_attributes)

# `CallBase::getMemoryEffects`: the call's and the callee's effects, where operand
# bundles (other than the ones that LLVM knows not to access memory) make the callee's
# read and write anything
function call_memory_effects(call::Instruction)
    effects = attribute_memory_effects(call.function_attributes)
    callee = call.called_operand
    if callee isa LLVM.Function
        fn_effects = function_memory_effects(callee)
        bundles = [LLVM.tag(b) for b in call.operand_bundles]
        if !intrinsic_is(call, Intrinsic("llvm.assume"))
            any(t -> !(t in ("ptrauth", "kcfi", "convergencectrl")), bundles) &&
                (fn_effects |= MemoryEffects(:read))
            any(t -> !(t in ("deopt", "funclet", "ptrauth", "kcfi", "convergencectrl")), bundles) &&
                (fn_effects |= MemoryEffects(:write))
        end
        effects &= fn_effects
    end
    return effects
end

const MEMORY_LOCATIONS = (:argmem, :inaccessiblemem, :other)

only_reads_memory(e::MemoryEffects) =
    all(loc -> !(e[loc] in (:write, :readwrite)), MEMORY_LOCATIONS)
only_accesses_arg_pointees(e::MemoryEffects) =
    all(loc -> loc === :argmem || e[loc] === :none, MEMORY_LOCATIONS)

# the integer of a constant, at most INT_MAX (`getLimitedValue(INT_MAX)`)
limited_value(c::LLVM.ConstantInt) = min(convert(UInt64, c), UInt64(typemax(Int32)))

# the element `i` of a constant aggregate, or nothing
function aggregate_element(c::LLVM.Constant, i::Integer)
    ref = API.LLVMGetAggregateElement(c, i)
    return ref == C_NULL ? nothing : Value(ref)
end

shuffle_mask(inst::Instruction) =
    [Int(API.LLVMGetMaskValue(inst, i)) for i in 0:Int(API.LLVMGetNumMaskElements(inst))-1]

# shuffle mask elements that are undefined (`-1` in LLVM's C++ API)
const UNDEF_MASK_ELEM = -1

# the index list of an extractvalue or insertvalue
aggregate_indices(inst::Instruction) =
    [Int(unsafe_load(API.LLVMGetIndices(inst), i)) for i in 1:Int(API.LLVMGetNumIndices(inst))]

# the constant-folding builder inserts constants instead of instructions; these create
# an instruction (like the C++'s `XInst::Create`) by building it from a placeholder
# operand and swapping the real operand in
function placeholder(builder::IRBuilder, @nospecialize(v::Value))
    return freeze!(builder, v)
end

function new_select!(builder::IRBuilder, @nospecialize(cond::Value), @nospecialize(a::Value),
                     @nospecialize(b::Value), name::String)
    tmp = placeholder(builder, a)
    inst = select!(builder, cond, tmp, b, name)::Instruction
    inst.operands[2] = a
    erase!(tmp)
    return inst
end

function new_extract_element!(builder::IRBuilder, @nospecialize(vec::Value),
                              @nospecialize(idx::Value), name::String="")
    tmp = placeholder(builder, vec)
    inst = extract_element!(builder, tmp, idx, name)::Instruction
    inst.operands[1] = vec
    erase!(tmp)
    return inst
end

function new_extract_value!(builder::IRBuilder, @nospecialize(agg::Value), idxs::Vector{Int},
                            name::String="")
    tmp = placeholder(builder, agg)
    inst = extract_value!(builder, tmp, idxs, name)::Instruction
    inst.operands[1] = agg
    erase!(tmp)
    return inst
end

function new_addrspacecast!(builder::IRBuilder, @nospecialize(v::Value), ty::LLVMType,
                            name::String="")
    v isa LLVM.Constant || return addrspacecast!(builder, v, ty, name)::Instruction
    tmp = placeholder(builder, v)
    inst = addrspacecast!(builder, tmp, ty, name)::Instruction
    inst.operands[1] = v
    erase!(tmp)
    return inst
end

# position the builder before `inst`, with `inst`'s debug location like C++'s
# `IRBuilder<> builder(inst)`, or without one (`XInst::Create(..., inst)`)
function position_before!(builder::IRBuilder, inst::Instruction; debug::Bool)
    position!(builder, LLVM.before(inst))
    builder.debug_location = debug ? inst.debug_location : nothing
end


## InstSimplifyFolder, for the extractions of Julia 1.12 and later

# `getSplatValue`
function splat_value(@nospecialize(v::Value))
    if v isa LLVM.Constant
        is_vector_type(typeref(v)) || return nothing
        n = composite_num_elements(typeref(v))
        n == 0 && return nothing
        first_elt = aggregate_element(v, 0)
        first_elt === nothing && return nothing
        for i in 1:n-1
            e = aggregate_element(v, i)
            (e === nothing || vref(e) != vref(first_elt)) && return nothing
        end
        return first_elt
    end
    # shuffle (insertelement ?, splat, 0), ?, zeroinitializer
    if v isa LLVM.ShuffleVectorInst
        ins = v.operands[1]
        if ins isa LLVM.InsertElementInst
            idx = ins.operands[3]
            if idx isa LLVM.ConstantInt && convert(Int, idx) == 0 &&
               all(m -> m == 0 || m == UNDEF_MASK_ELEM, shuffle_mask(v))
                return ins.operands[2]
            end
        end
    end
    return nothing
end

# `findScalarElement`
function find_scalar_element(@nospecialize(v::Value), elt::Int)
    t = typeref(v)
    elt_type = API.LLVMGetElementType(t)
    if type_kind(t) == API.LLVMVectorTypeKind && elt >= composite_num_elements(t)
        return Value(API.LLVMGetPoison(elt_type))
    end
    v isa LLVM.Constant && return aggregate_element(v, elt)
    if v isa LLVM.InsertElementInst
        idx = v.operands[3]
        idx isa LLVM.ConstantInt || return nothing
        convert(Int, idx) == elt && return v.operands[2]
        vref(v.operands[1]) == vref(v) && return nothing
        return find_scalar_element(v.operands[1], elt)
    end
    if v isa LLVM.ShuffleVectorInst && type_kind(t) == API.LLVMVectorTypeKind
        lhs_width = composite_num_elements(typeref(v.operands[1]))
        in_elt = shuffle_mask(v)[elt+1]
        in_elt < 0 && return Value(API.LLVMGetPoison(elt_type))
        in_elt < lhs_width && return find_scalar_element(v.operands[1], in_elt)
        return find_scalar_element(v.operands[2], in_elt - lhs_width)
    end
    if type_kind(t) == API.LLVMScalableVectorTypeKind
        splat = splat_value(v)
        splat !== nothing && elt < composite_num_elements(t) && return splat
    end
    return nothing
end

# `simplifyExtractValueInst`
function simplify_extract_value(@nospecialize(agg::Value), idxs::Vector{Int})
    if agg isa LLVM.Constant
        c = agg
        for i in idxs
            c = aggregate_element(c, i)
            c === nothing && return nothing
        end
        return c
    end
    ivi = agg
    while ivi isa LLVM.InsertValueInst
        ins_idxs = aggregate_indices(ivi)
        n = min(length(ins_idxs), length(idxs))
        if ins_idxs[1:n] == idxs[1:n]
            length(ins_idxs) == length(idxs) && return ivi.operands[2]
            break
        end
        ivi = ivi.operands[1]
    end
    return nothing
end

# `simplifyExtractElementInst` with a constant index
function simplify_extract_element(@nospecialize(vec::Value), idx::Int)
    t = typeref(vec)
    if vec isa LLVM.Constant
        return aggregate_element(vec, idx)
    end
    nelts = composite_num_elements(t)
    if type_kind(t) == API.LLVMVectorTypeKind && idx >= nelts
        return Value(API.LLVMGetPoison(API.LLVMGetElementType(t)))
    end
    if idx < nelts
        splat = splat_value(vec)
        splat !== nothing && return splat
    end
    return find_scalar_element(vec, idx)
end


## the pass

# a basic block's results of the local scan, and its liveness
mutable struct BBState
    # uses in this block, not updated after the local scan
    defs::BitSet
    phi_outs::BitSet
    up_exposed_uses::BitSet
    # updated by the dataflow
    live_in::BitSet
    live_out::BitSet
    has_safepoint::Bool
    # safepoints are numbered backwards: the first in the block has the highest number
    first_safepoint::Int
    last_safepoint::Int
    first_safepoint_after_first_def::Int
end
BBState() = BBState(BitSet(), BitSet(), BitSet(), BitSet(), BitSet(), false, -1, -1, -1)

mutable struct State
    f::LLVM.Function
    # the maximum assigned value number, and safepoint number
    max_ptr_number::Int
    max_safepoint_number::Int
    # numbers of IR values, including derived ones
    all_ptr_numbering::Dict{ValueRef,Int}
    all_composite_numbering::Dict{ValueRef,Vector{Int}}
    reverse_ptr_numbering::Dict{Int,Value}
    # for each value, the values live at some safepoint with it (0-based numbers)
    neighbors::Vector{BitSet}
    bb_states::Dict{ValueRef,BBState}
    # if all values a value refines to are rooted, it is too (-1: externally rooted,
    # -2: permanently rooted)
    refinements::Dict{Int,Vector{Int}}
    # the values a `gc_preserve_begin` keeps alive until its ends
    gc_preserves::Vector{Pair{Instruction,Vector{Int}}}
    # safepoints, in the order of their numbers
    safepoint_numbering::Vector{Instruction}
    returns_twice::Vector{Int}
    live_sets::Vector{BitSet}
    live_if_live_out::Vector{Vector{Int}}
    callee_roots::Vector{Vector{Int}}
    # allocas that are sunk into the GC frame, with their number of roots, in order
    array_allocas::Vector{Instruction}
    array_alloca_roots::Dict{ValueRef,Int}
    # the allocas of single tracked pointers (`gc_root_allocas_first`)
    root_allocas::Vector{Instruction}
    tracked_stores::Vector{Tuple{Instruction,Int}}
end

State(f::LLVM.Function) =
    State(f, -1, -1, Dict{ValueRef,Int}(), Dict{ValueRef,Vector{Int}}(), Dict{Int,Value}(),
          BitSet[], Dict{ValueRef,BBState}(), Dict{Int,Vector{Int}}(),
          Pair{Instruction,Vector{Int}}[], Instruction[], Int[], BitSet[], Vector{Int}[],
          Vector{Int}[], Instruction[], Dict{ValueRef,Int}(), Instruction[],
          Tuple{Instruction,Int}[])

bb_state(S::State, bb::BasicBlock) = get!(BBState, S.bb_states, vref(bb))

has_array_alloca(S::State, ai::Instruction) = haskey(S.array_alloca_roots, vref(ai))
function set_array_alloca!(S::State, ai::Instruction, n::Int)
    haskey(S.array_alloca_roots, vref(ai)) || push!(S.array_allocas, ai)
    S.array_alloca_roots[vref(ai)] = n
end

# the functions of Julia's runtime interface in a module (`JuliaPassContext`)
struct GCFunctions
    pgcstack_getter::Union{Nothing,LLVM.Function}
    adoptthread::Union{Nothing,LLVM.Function}
    gcroot_flush::Union{Nothing,LLVM.Function}
    gc_preserve_begin::Union{Nothing,LLVM.Function}
    gc_preserve_end::Union{Nothing,LLVM.Function}
    pointer_from_objref::Union{Nothing,LLVM.Function}
    gc_loaded::Union{Nothing,LLVM.Function}
    alloc_obj::Union{Nothing,LLVM.Function}
    typeof::Union{Nothing,LLVM.Function}
    blackbox::Union{Nothing,LLVM.Function}
    write_barriers::Vector{LLVM.Function}
    field_write_barriers::Vector{LLVM.Function}
    pop_handler_noexcept::Union{Nothing,LLVM.Function}
    call::Union{Nothing,LLVM.Function}
    call2::Union{Nothing,LLVM.Function}
    call3::Union{Nothing,LLVM.Function}
end

function GCFunctions(mod::LLVM.Module, dialect::Dialect)
    fns = mod.functions
    lookup(name) = get(fns, name, nothing)
    barriers = LLVM.Function[f for f in lookup.(dialect.write_barriers) if f !== nothing]
    field_barriers = LLVM.Function[f for f in barriers if startswith(LLVM.name(f), "julia.field_write_barrier")]
    return GCFunctions(lookup("julia.get_pgcstack"), lookup("julia.get_pgcstack_or_new"),
                       lookup("julia.gcroot_flush"), lookup("llvm.julia.gc_preserve_begin"),
                       lookup("llvm.julia.gc_preserve_end"),
                       lookup("julia.pointer_from_objref"),
                       dialect.has_gc_loaded ? lookup("julia.gc_loaded") : nothing,
                       lookup("julia.gc_alloc_obj"), lookup("julia.typeof"),
                       lookup("julia.blackbox"), barriers, field_barriers,
                       lookup("ijl_pop_handler_noexcept"), lookup("julia.call"),
                       lookup("julia.call2"),
                       dialect.has_call3 ? lookup("julia.call3") : nothing)
end

is_fn(f, @nospecialize(callee)) = f !== nothing && callee !== nothing && f == callee
is_write_barrier(fns::GCFunctions, @nospecialize(callee)) =
    callee isa LLVM.Function && callee in fns.write_barriers
is_field_write_barrier(fns::GCFunctions, @nospecialize(callee)) =
    callee isa LLVM.Function && callee in fns.field_write_barriers

mutable struct LateLowerGCFrame
    dialect::Dialect
    opts::PassOptions
    mod::LLVM.Module
    f::LLVM.Function
    am::Any
    fns::GCFunctions
    builder::IRBuilder
    dl::DataLayout
    T_prjlvalue::LLVMType
    T_size::LLVMType
    # the GC stack: a call in the entry block, or an argument
    pgcstack::Union{Nothing,Value}
    domtree::Union{Nothing,DomTree}
    # the facts about Julia's runtime (`RuntimeFacts`), read when needed
    layout::Any
    cfg_modified::Bool
end

function dominator_tree(p::LateLowerGCFrame)
    p.domtree === nothing && (p.domtree = p.am[DomTree])
    return p.domtree::DomTree
end

function runtime_layout(p::LateLowerGCFrame)
    p.layout === nothing && (p.layout = runtime_layout(p.opts, p.mod))
    return p.layout
end

pointer_size(p::LateLowerGCFrame) = storage_size(p.dl, LLVM.PointerType(AS_GENERIC))
pointer_align(p::LateLowerGCFrame) = abi_alignment(p.dl, LLVM.PointerType(AS_GENERIC))

# the GC stack of a function (`JuliaPassContext::getPGCstack`)
get_pgcstack(p::LateLowerGCFrame, f::LLVM.Function) = get_pgcstack(p.fns, p.dialect, f)
function get_pgcstack(fns::GCFunctions, dialect::Dialect, f::LLVM.Function)
    if fns.pgcstack_getter !== nothing || fns.adoptthread !== nothing
        for inst in first(f.blocks).instructions
            inst isa LLVM.CallInst || continue
            callee = inst.called_operand
            if is_fn(fns.pgcstack_getter, callee) || is_fn(fns.adoptthread, callee)
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


## numbering (FindBaseValue, Number*, Lift*)

const MASKED_LOAD = Intrinsic("llvm.masked.load")
const MASKED_GATHER = Intrinsic("llvm.masked.gather")
const VECTOR_EXTRACT = Intrinsic("llvm.vector.extract")
const VECTOR_INSERT = Intrinsic("llvm.vector.insert")

is_gc_loaded_call(p::LateLowerGCFrame, @nospecialize(v::Value)) =
    p.dialect.has_gc_loaded && v isa LLVM.CallInst &&
    let callee = called_function(v)
        callee !== nothing && LLVM.name(callee) == "julia.gc_loaded"
    end

null_generic_pointer() = LLVM.null(LLVM.PointerType(AS_GENERIC))

# Walk through simple expressions until we hit something that requires root numbering.
# If the input value is a scalar (pointer), we may return a composite value as base, in
# which case the second member is the index of the value in the vector.
function find_base_value(p::LateLowerGCFrame, S::State, @nospecialize(v::Value),
                         use_cache::Bool=true)
    cur = v
    fld_idx = -1
    while true
        if use_cache
            if is_pointer_value(cur)
                haskey(S.all_ptr_numbering, vref(cur)) && return (cur, fld_idx)
            else
                haskey(S.all_composite_numbering, vref(cur)) && return (cur, fld_idx)
            end
        end
        if cur isa LLVM.BitCastInst
            cur = cur.operands[1]
        elseif cur isa LLVM.AddrSpaceCastInst
            new = cur.operands[1]
            value_addrspace(new) == 0 && break
            cur = new
        elseif cur isa LLVM.FreezeInst
            cur = cur.operands[1]
        elseif cur isa LLVM.GetElementPtrInst
            cur = cur.operands[1]
            # GEP can make vectors from a single base pointer
            if fld_idx != -1 && !is_vector_type(typeref(cur))
                fld_idx = -1
            end
        elseif cur isa LLVM.ExtractElementInst
            idx = cur.operands[2]
            idx isa LLVM.ConstantInt || break
            fld_idx = Int(limited_value(idx))
            cur = cur.operands[1]
        elseif cur isa LLVM.LoadInst
            if has_loaded_ty(typeref(cur))
                # the old (deprecated) implementation of loaded pointers: new code uses
                # julia.gc_loaded to pair the load with its tracked value
                cur = cur.operands[1]
                fld_idx = -1
                is_special_ptr(typeref(cur)) || (cur = null_generic_pointer())
                continue
            end
            break
        elseif cur isa LLVM.AtomicCmpXchgInst || cur isa LLVM.AtomicRMWInst
            break
        elseif cur isa LLVM.CallInst && is_intrinsic_call(cur)
            if intrinsic_is(cur, MASKED_LOAD) || intrinsic_is(cur, MASKED_GATHER)
                # like a load followed by a select; never derived, so no lifting is
                # needed, but loaded pointers walk to their base
                t = typeref(cur)
                if is_vector_type(t) && has_loaded_ty(API.LLVMGetElementType(t))
                    is_load = intrinsic_is(cur, MASKED_LOAD)
                    cur = cur.operands[1]
                    if is_load
                        fld_idx = -1
                        is_special_ptr(typeref(cur)) || (cur = null_generic_pointer())
                    else
                        ct = typeref(cur)
                        if is_vector_type(ct) && !is_special_ptr(API.LLVMGetElementType(ct))
                            cur = null_generic_pointer()
                            fld_idx = -1
                        end
                    end
                    continue
                end
                break
            elseif intrinsic_is(cur, VECTOR_EXTRACT)
                t = typeref(cur)
                if is_vector_type(t) && has_loaded_ty(API.LLVMGetElementType(t))
                    cur = cur.operands[1]
                    fld_idx = -1
                    continue
                end
                break
            end
            break
        elseif is_gc_loaded_call(p, cur)
            cur = cur.operands[1]
        else
            break
        end
    end
    return (cur, fld_idx)
end

# `IRBuilder<InstSimplifyFolder>` at `insert_before` (Julia 1.12 and later), or
# `XInst::Create(..., insert_before)`
function extract_value_at!(p::LateLowerGCFrame, @nospecialize(agg::Value), idxs::Vector{Int},
                           insert_before::Instruction)
    if p.dialect.gc_extract_simplify
        folded = simplify_extract_value(agg, idxs)
        folded === nothing || return folded
        position_before!(p.builder, insert_before; debug=true)
    else
        position_before!(p.builder, insert_before; debug=false)
    end
    return new_extract_value!(p.builder, agg, idxs)
end

function extract_element_at!(p::LateLowerGCFrame, @nospecialize(vec::Value), idx::Int,
                             insert_before::Instruction)
    if p.dialect.gc_extract_simplify
        folded = simplify_extract_element(vec, idx)
        folded === nothing || return folded
        position_before!(p.builder, insert_before; debug=true)
    else
        position_before!(p.builder, insert_before; debug=false)
    end
    return new_extract_element!(p.builder, vec, ConstantInt(LLVM.Int32Type(), idx))
end

function maybe_extract_scalar(p::LateLowerGCFrame, S::State, val_expr::Tuple{Value,Int},
                              insert_before::Instruction)
    v, idx = val_expr
    if is_pointer_value(v)
        @assert idx == -1
        if !is_tracked_value(v)
            base = number_base!(p, S, v)
            v = base >= 0 ? get_ptr_for_number(p, S, base, insert_before) :
                            LLVM.null(p.T_prjlvalue)
        end
    elseif idx != -1
        tracked = track_composite_type(typeref(v))
        idxs = tracked[idx+1]
        idxs_not_vec = idxs[1:end-1]
        final_t = indexed_type(typeref(v), idxs_not_vec)
        is_vec = is_vector_type(final_t)
        t = composite_element_type(final_t, last(idxs))
        if type_addrspace(t) != AS_TRACKED
            # if v isn't tracked, get the shadow def
            numbers = number_all_base!(p, S, v)
            base = numbers[idx+1]
            return base >= 0 ? get_ptr_for_number(p, S, base, insert_before) :
                               LLVM.null(p.T_prjlvalue)
        end
        if length(idxs) > is_vec
            v = extract_value_at!(p, v, is_vec ? idxs_not_vec : idxs, insert_before)
        end
        if is_vec
            v = extract_element_at!(p, v, last(idxs), insert_before)
        end
    end
    return v
end

function maybe_extract_vector(p::LateLowerGCFrame, S::State, @nospecialize(base_vec::Value),
                              insert_before::Instruction)
    numbers = number_all_base!(p, S, base_vec)
    return Value[n >= 0 ? get_ptr_for_number(p, S, n, insert_before) :
                          LLVM.null(p.T_prjlvalue) for n in numbers]
end

function get_ptr_for_number(p::LateLowerGCFrame, S::State, num::Int, insert_before::Instruction)
    val = S.reverse_ptr_numbering[num]
    idx = -1
    if !is_pointer_value(val)
        all_nums = S.all_composite_numbering[vref(val)]
        idx = findfirst(==(num), all_nums) - 1
    end
    return maybe_extract_scalar(p, S, (val, idx), insert_before)
end

is_numbered(S::State, @nospecialize(v::Value)) =
    is_pointer_value(v) ? haskey(S.all_ptr_numbering, vref(v)) :
                          haskey(S.all_composite_numbering, vref(v))

function lift_select!(p::LateLowerGCFrame, S::State, si::Instruction)
    is_numbered(S, si) && return  # already visited here
    numbers = Int[]
    num_roots = 1
    sty = typeref(si)
    is_pointer_type(sty) || (numbers = fill(-1, CountTrackedPointers(sty).count))
    # find the base root for the arguments
    true_base = maybe_extract_scalar(p, S, find_base_value(p, S, si.operands[2], false), si)
    false_base = maybe_extract_scalar(p, S, find_base_value(p, S, si.operands[3], false), si)
    true_bases = Value[]
    false_bases = Value[]
    if !is_pointer_value(true_base)
        true_bases = maybe_extract_vector(p, S, true_base, si)
        num_roots = length(true_bases)
    end
    if !is_pointer_value(false_base)
        false_bases = maybe_extract_vector(p, S, false_base, si)
        num_roots = length(false_bases)
    end
    # handled recursively, through a PHI node
    is_numbered(S, si) && return
    for i in 0:num_roots-1
        true_elem = is_pointer_value(true_base) ? true_base : true_bases[i+1]
        false_elem = is_pointer_value(false_base) ? false_base : false_bases[i+1]
        cond = si.operands[1]
        if is_vector_type(typeref(cond))
            position_before!(p.builder, si; debug=false)
            cond = new_extract_element!(p.builder, cond, ConstantInt(LLVM.Int32Type(), i))
        end
        position_before!(p.builder, si; debug=false)
        select_base = new_select!(p.builder, cond, true_elem, false_elem, "gclift")
        number = (S.max_ptr_number += 1)
        S.all_ptr_numbering[vref(select_base)] = number
        S.reverse_ptr_numbering[number] = select_base
        if is_pointer_type(sty)
            S.all_ptr_numbering[vref(si)] = number
        else
            numbers[i+1] = number
        end
    end
    if type_kind(sty) == API.LLVMVectorTypeKind && num_roots != length(numbers)
        # broadcast the scalar root number to fill the vector
        @assert num_roots == 1
        numbers = fill(numbers[1], Int(API.LLVMGetVectorSize(sty)))
    end
    is_pointer_type(sty) || (S.all_composite_numbering[vref(si)] = numbers)
    return
end

function lift_extract_element!(p::LateLowerGCFrame, S::State, eei::Instruction)
    haskey(S.all_ptr_numbering, vref(eei)) && return
    base = maybe_extract_scalar(p, S, find_base_value(p, S, eei.operands[1], false), eei)
    haskey(S.all_ptr_numbering, vref(eei)) && return  # handled recursively
    if is_pointer_value(base)
        S.all_ptr_numbering[vref(eei)] = number!(p, S, base)
        return
    end
    bases = maybe_extract_vector(p, S, base, eei)
    builder = p.builder
    position_before!(builder, eei; debug=true)
    base_vec = Value(API.LLVMGetPoison(LLVM.VectorType(p.T_prjlvalue, length(bases))))
    for (i, b) in enumerate(bases)
        base_vec = insert_element!(builder, base_vec, b, ConstantInt(LLVM.Int64Type(), i - 1))
    end
    lift = extract_element!(builder, base_vec, eei.operands[2], "gclift")
    S.all_ptr_numbering[vref(eei)] = number!(p, S, lift)
    return
end

function lift_phi!(p::LateLowerGCFrame, S::State, phi::Instruction)
    is_numbered(S, phi) && return
    lifted = Instruction[]
    numbers = Int[]
    num_roots = 1
    pty = typeref(phi)
    if !is_pointer_type(pty)
        num_roots = CountTrackedPointers(pty).count
        numbers = zeros(Int, num_roots)
    end
    for i in 1:num_roots
        position_before!(p.builder, phi; debug=false)
        lift = phi!(p.builder, p.T_prjlvalue, "gclift")
        number = (S.max_ptr_number += 1)
        S.all_ptr_numbering[vref(lift)] = number
        S.reverse_ptr_numbering[number] = lift
        if is_pointer_type(pty)
            S.all_ptr_numbering[vref(phi)] = number
        else
            numbers[i] = number
        end
        push!(lifted, lift)
    end
    is_pointer_type(pty) || (S.all_composite_numbering[vref(phi)] = numbers)
    for (incoming, incoming_bb) in collect(phi.incoming)
        terminator = incoming_bb.terminator
        base = maybe_extract_scalar(p, S, find_base_value(p, S, incoming, false), terminator)
        incoming_bases = Value[]
        is_pointer_value(base) || (incoming_bases = maybe_extract_vector(p, S, base, terminator))
        for (i, lift) in enumerate(lifted)
            elem = is_pointer_value(base) ? base : incoming_bases[i]
            push!(lift.incoming, (elem, incoming_bb))
        end
    end
end

function number_base!(p::LateLowerGCFrame, S::State, @nospecialize(cur::Value))
    n = get(S.all_ptr_numbering, vref(cur), nothing)
    n === nothing || return n
    if cur isa LLVM.Constant
        number = -2  # permanently rooted
    elseif cur isa LLVM.Argument || cur isa LLVM.AllocaInst ||
           (cur isa LLVM.AddrSpaceCastInst && !is_tracked_value(cur))
        number = -1  # rooted in the parent
    elseif !is_special_ptr(typeref(cur))
        number = -1  # externally rooted somehow, hopefully
    elseif cur isa LLVM.SelectInst && !is_tracked_value(cur)
        lift_select!(p, S, cur)
        return S.all_ptr_numbering[vref(cur)]
    elseif cur isa LLVM.PHIInst && !is_tracked_value(cur)
        lift_phi!(p, S, cur)
        return S.all_ptr_numbering[vref(cur)]
    elseif cur isa LLVM.ExtractElementInst && !is_tracked_value(cur)
        lift_extract_element!(p, S, cur)
        return S.all_ptr_numbering[vref(cur)]
    elseif cur isa LLVM.ExtractValueInst
        numbers = number_all_base!(p, S, cur)
        @assert length(numbers) == 1
        number = numbers[1]
    else
        number = (S.max_ptr_number += 1)
        S.reverse_ptr_numbering[number] = cur
    end
    S.all_ptr_numbering[vref(cur)] = number
    return number
end

function number!(p::LateLowerGCFrame, S::State, @nospecialize(v::Value))
    cur, idx = find_base_value(p, S, v)
    number = idx == -1 ? number_base!(p, S, cur) : number_all_base!(p, S, cur)[idx+1]
    vref(v) != vref(cur) && (S.all_ptr_numbering[vref(v)] = number)
    return number
end

# whether the index path `elem` starts with `idxs`
starts_with(elem::Vector{Int}, idxs::Vector{Int}) =
    length(elem) >= length(idxs) && elem[1:length(idxs)] == idxs

# assign pointer numbers to a def instruction
function number_all_base!(p::LateLowerGCFrame, S::State, @nospecialize(cur::Value))
    if is_pointer_value(cur)
        n = get(S.all_ptr_numbering, vref(cur), nothing)
        n === nothing || return [n]
    else
        ns = get(S.all_composite_numbering, vref(cur), nothing)
        ns === nothing || return ns
    end
    numbers = Int[]
    tracked = CountTrackedPointers(typeref(cur))
    tracked.count == 0 && return numbers
    if cur isa LLVM.Constant || cur isa LLVM.AllocaInst || cur isa LLVM.Argument ||
       (cur isa LLVM.AddrSpaceCastInst && !is_tracked_value(cur))
        numbers = fill(-1, tracked.count)
    elseif cur isa LLVM.ShuffleVectorInst
        numbers1 = number_all!(p, S, cur.operands[1])
        numbers2 = number_all!(p, S, cur.operands[2])
        for idx in shuffle_mask(cur)
            if idx < 0
                push!(numbers, -1)
            elseif idx < length(numbers1)
                push!(numbers, numbers1[idx+1])
            else
                push!(numbers, numbers2[idx-length(numbers1)+1])
            end
        end
    elseif cur isa LLVM.InsertElementInst
        idx_op = cur.operands[3]
        idx_op isa LLVM.ConstantInt ||
            error("LateLowerGCFrame: insertelement of a tracked pointer at a non-constant index is not supported")
        numbers = copy(number_all!(p, S, cur.operands[1]))
        numbers[convert(Int, idx_op)+1] = number!(p, S, cur.operands[2])
    elseif cur isa LLVM.CallInst && intrinsic_is(cur, VECTOR_INSERT)
        # vector insert is a bit like a shuffle, so use the same approach
        numbers1 = number_all!(p, S, cur.operands[1])
        numbers2 = number_all!(p, S, cur.operands[2])
        first_idx = convert(Int, cur.operands[3])
        for i in 0:length(numbers1)-1
            if i < first_idx
                push!(numbers, numbers1[i+1])
            elseif i - first_idx < length(numbers2)
                push!(numbers, numbers2[i-first_idx+1])
            else
                push!(numbers, numbers1[i+1])
            end
        end
    elseif cur isa LLVM.InsertValueInst
        numbers = copy(number_all!(p, S, cur.operands[1]))
        tracked_paths = track_composite_type(typeref(cur))
        insert_numbers = number_all!(p, S, cur.operands[2])
        idxs = aggregate_indices(cur)
        j = 0
        for (i, elem) in enumerate(tracked_paths)
            if starts_with(elem, idxs)
                numbers[i] = insert_numbers[j += 1]
            end
        end
    elseif cur isa LLVM.ExtractValueInst
        base_numbers = number_all!(p, S, cur.operands[1])
        tracked_paths = track_composite_type(typeref(cur.operands[1]))
        idxs = aggregate_indices(cur)
        for (i, elem) in enumerate(tracked_paths)
            starts_with(elem, idxs) && push!(numbers, base_numbers[i])
        end
    elseif tracked.derived
        if cur isa LLVM.SelectInst
            lift_select!(p, S, cur)
        elseif cur isa LLVM.PHIInst
            lift_phi!(p, S, cur)
        else
            error("LateLowerGCFrame: unexpected generating operation for derived values: $(string(cur))")
        end
        numbers = is_pointer_value(cur) ? [S.all_ptr_numbering[vref(cur)]] :
                                          S.all_composite_numbering[vref(cur)]
    else
        # numbered sequentially
        for _ in 1:tracked.count
            num = (S.max_ptr_number += 1)
            push!(numbers, num)
            S.reverse_ptr_numbering[num] = cur
        end
    end
    if is_pointer_value(cur)
        @assert length(numbers) == 1
        S.all_ptr_numbering[vref(cur)] = numbers[1]
    else
        S.all_composite_numbering[vref(cur)] = numbers
    end
    return numbers
end

# the pointer number of every GC-tracked value inside `v`
function number_all!(p::LateLowerGCFrame, S::State, @nospecialize(v::Value))
    if is_pointer_value(v)
        n = get(S.all_ptr_numbering, vref(v), nothing)
        n === nothing || return [n]
    else
        ns = get(S.all_composite_numbering, vref(v), nothing)
        ns === nothing || return ns
    end
    tracked = CountTrackedPointers(typeref(v))
    tracked.count == 0 && return Int[]
    cur, idx = find_base_value(p, S, v)
    number = -1
    if is_pointer_value(cur)
        # the base is a single pointer: number it
        number = number_base!(p, S, cur)
        numbers = fill(number, tracked.count)
    else
        # the base is an aggregate: number all of it, then select
        numbers = number_all_base!(p, S, cur)
        if idx != -1
            number = numbers[idx+1]
            numbers = fill(number, tracked.count)
        end
    end
    if vref(cur) != vref(v)
        if is_pointer_value(v)
            S.all_ptr_numbering[vref(v)] = number
        else
            S.all_composite_numbering[vref(v)] = numbers
        end
    end
    return numbers
end


## local scan

function note_def!(S::State, BBS::BBState, num::Int)
    @assert num >= 0
    @assert !(num in BBS.defs) "SSA violation or misnumbering"
    push!(BBS.defs, num)
    delete!(BBS.up_exposed_uses, num)
    # live at every following safepoint of the block, if live out
    if BBS.has_safepoint
        for safepoint in BBS.first_safepoint:-1:BBS.last_safepoint
            push!(S.live_if_live_out[safepoint+1], num)
        end
    end
end

function maybe_note_def!(p::LateLowerGCFrame, S::State, BBS::BBState, @nospecialize(def::Value),
                         refined_ptr::Vector{Int}=Int[])
    rt = typeref(def)
    if is_pointer_type(rt)
        is_special_ptr(rt) || return false
        @assert is_tracked_value(def) "returned value of GC interest, but not tracked"
        num = number!(p, S, def)
        note_def!(S, BBS, num)
        isempty(refined_ptr) || (S.refinements[num] = refined_ptr)
        return true
    else
        nums = number_all!(p, S, def)
        for num in nums
            note_def!(S, BBS, num)
            isempty(refined_ptr) || (S.refinements[num] = copy(refined_ptr))
        end
        return !isempty(nums)
    end
end

function note_safepoint!(S::State, BBS::BBState, call::Instruction, callee_roots::Vector{Int})
    number = (S.max_safepoint_number += 1)
    push!(S.safepoint_numbering, call)
    # the pointers upward exposed here are live at this safepoint, even when they have a
    # def earlier in this block (and don't participate in the dataflow)
    push!(S.live_sets, copy(BBS.up_exposed_uses))
    push!(S.live_if_live_out, Int[])
    push!(S.callee_roots, callee_roots)
    BBS.has_safepoint = true
    BBS.last_safepoint == -1 && (BBS.last_safepoint = number)
    BBS.first_safepoint = number
    return number
end

function note_use!(p::LateLowerGCFrame, S::State, @nospecialize(v::Value), uses::BitSet)
    # short circuit to avoid having to deal with vectors of constants, etc.
    v isa LLVM.Constant && return
    if is_pointer_value(v)
        if is_special_ptr(typeref(v))
            num = number!(p, S, v)
            num < 0 && return
            push!(uses, num)
        end
    else
        for num in number_all!(p, S, v)
            num < 0 && continue
            push!(uses, num)
        end
    end
end

function note_operand_uses!(p::LateLowerGCFrame, S::State, BBS::BBState, inst::Instruction)
    for op in inst.operands
        note_use!(p, S, op, BBS.up_exposed_uses)
    end
end

# whether a load reads from memory that its base object keeps alive for as long as it
# is alive (`isLoadFromImmut` up to Julia 1.13, `isLoadFromRootedRegion` on master)
function is_load_from_rooted_region(p::LateLowerGCFrame, li::Instruction)
    md = li.metadata
    haskey(md, LLVM.MD_invariant_load) && return true
    if p.dialect.gc_rooted_loads === :tbaa
        tbaa = haskey(md, LLVM.MD_tbaa) ? md[LLVM.MD_tbaa] : nothing
        return tbaa isa MDNode && tbaa_derives_from(tbaa, p.dialect.gc_immutable_tbaa)
    end
    haskey(md, LLVM.MD_alias_scope) || return false
    scopes = md[LLVM.MD_alias_scope]
    scopes isa MDNode || return false
    found = false
    for scope in scopes.operands
        scope isa MDNode || continue
        ops = scope.operands
        length(ops) >= 2 || continue
        domain = ops[2]
        (domain isa MDNode && !isempty(domain.operands)) || continue
        domain_name = domain.operands[1]
        (domain_name isa MDString && convert(String, domain_name) == "jnoalias") || continue
        # a scope is named by a trailing operand ({self, domain, name}), or by its string
        # key ({name, domain})
        name = length(ops) > 2 && ops[3] isa MDString ? convert(String, ops[3]) : ""
        isempty(name) && ops[1] isa MDString && (name = convert(String, ops[1]))
        # may reside in a region that can drop the reference
        name in ("jnoalias_immutdata", "jnoalias_mutconstdata") || return false
        found = true
    end
    return found
end

function is_const_gv(gv::LLVM.GlobalVariable)
    LLVM.isconstant(gv) && return true
    kind = API.LLVMGetMDKindIDInContext(context(gv), "julia.constgv", length("julia.constgv"))
    for (k, _) in gv.metadata
        k == kind && return true
    end
    return false
end

# Whether this can be traced through constant loads to a constant global, or an otherwise
# globally rooted value. Almost all `tbaa_const` loads satisfy this, except for constants
# local to a task, for which `task_local[]` is set: they don't need a root in the task,
# but write barriers for when the task dies.
function is_load_from_const_gv(p::LateLowerGCFrame, li::LLVM.LoadInst, task_local::Ref{Bool},
                               seen=nothing)
    # codegen only emits single-slot globals, but LLVM's global merging may introduce GEPs
    load_base = strip_in_bounds_offsets(li.operands[1])
    gv = load_base isa LLVM.GlobalVariable ? load_base : nothing
    if is_load_from_rooted_region(p, li)
        gv === nothing || return true
        return is_load_from_const_gv_value(p, load_base, task_local, seen)
    end
    gv === nothing || return is_const_gv(gv)
    return false
end

function is_load_from_const_gv_value(p::LateLowerGCFrame, @nospecialize(v::Value),
                                     task_local::Ref{Bool}, seen=nothing)
    v = strip_in_bounds_offsets(v)
    v isa LLVM.LoadInst && return is_load_from_const_gv(p, v, task_local, seen)
    v isa LLVM.GlobalVariable && return is_const_gv(v)
    is_constant_data(v) && return true  # null pointer
    if v isa LLVM.ConstantExpr  # literal pointers
        return API.LLVMGetConstOpcode(v) == API.LLVMIntToPtr &&
               is_constant_data(Value(API.LLVMGetOperand(v, 0)))
    end
    if v isa LLVM.SelectInst
        return is_load_from_const_gv_value(p, v.operands[2], task_local, seen) &&
               is_load_from_const_gv_value(p, v.operands[3], task_local, seen)
    end
    if v isa LLVM.PHIInst
        if seen === nothing
            seen = Set{ValueRef}((vref(v),))
        elseif vref(v) in seen
            return true
        else
            push!(seen, vref(v))
        end
        for (incoming, _) in collect(v.incoming)
            is_load_from_const_gv_value(p, incoming, task_local, seen) || return false
        end
        return true
    end
    if v isa LLVM.CallInst
        callee = called_function(v)
        if callee !== nothing
            name = LLVM.name(callee)
            name == "julia.typeof" && return true
            if name == "julia.get_pgcstack"
                task_local[] = true
                return true
            end
            if p.dialect.has_gc_loaded && name == "julia.gc_loaded"
                return is_load_from_const_gv_value(p, v.operands[1], task_local, seen) &&
                       is_load_from_const_gv_value(p, v.operands[2], task_local, seen)
            end
        end
    end
    if v isa LLVM.Argument
        task_local[] = true
        return true
    end
    return false
end

# loads from a jlcall argument array (Julia 1.12 and older)
function looks_like_frame_ref(@nospecialize(v::Value))
    is_special_ptr(typeref(v)) && return false
    v = strip_in_bounds_offsets(v)
    is_special_ptr(typeref(v)) && return false
    return v isa LLVM.Argument
end

function get_load_value_align(li::Instruction)
    md = li.metadata
    haskey(md, LLVM.MD_align) || return 1
    # single-constant nodes come back as the constant itself
    node = md[LLVM.MD_align]
    c = node isa MDNode ? node.operands[1] : node
    return Int(min(convert(UInt64, Value(c)), UInt64(typemax(Int))))
end

function get_phi_refinements(p::LateLowerGCFrame, phi::Instruction, S::State)
    # Can violate the domination property of the refinements, since incoming values that
    # don't dominate the PHI node may be externally rooted, which is only known after
    # the scan; fixed up by `fix_up_refinements!`.
    return Int[number!(p, S, incoming) for (incoming, _) in collect(phi.incoming)]
end

function fix_up_refinements!(p::LateLowerGCFrame, phi_numbers::Vector{Int}, S::State)
    # Find the values that must be externally rooted: those whose refinements all are,
    # by assuming every value is and removing the ones that are not.
    n = S.max_ptr_number + 1
    extern_rooted = trues(n)
    perm_rooted = trues(n)
    has_bit(bv, i) = 0 <= i < length(bv) && bv[i+1]
    # values not derived from anything
    for i in 0:S.max_ptr_number
        r = get(S.refinements, i, nothing)
        if r === nothing || isempty(r)
            extern_rooted[i+1] = false
            perm_rooted[i+1] = false
        end
    end
    keys_sorted = sort!(collect(keys(S.refinements)))
    # values reachable from those, recursively
    changed = true
    while changed
        changed = false
        for num in keys_sorted
            has_bit(extern_rooted, num) || continue
            for refine in S.refinements[num]
                if refine == -2
                    continue
                elseif refine == -1
                    if has_bit(perm_rooted, num)
                        changed = true
                        perm_rooted[num+1] = false
                    end
                    continue
                elseif !has_bit(extern_rooted, refine)
                    changed = true
                    extern_rooted[num+1] = false
                    perm_rooted[num+1] = false
                    break
                elseif !has_bit(perm_rooted, refine)
                    if has_bit(perm_rooted, num)
                        changed = true
                        perm_rooted[num+1] = false
                    end
                end
            end
        end
    end
    # normalize externally rooted values
    for num in keys_sorted
        refined = S.refinements[num]
        if has_bit(perm_rooted, num)
            S.refinements[num] = [-2]
            continue
        elseif has_bit(extern_rooted, num)
            S.refinements[num] = [-1]
            continue
        end
        for (i, refine) in enumerate(refined)
            # externally rooted refinements don't need to be followed
            has_bit(extern_rooted, refine) && (refined[i] = -1)
        end
    end
    # Remove the invalid refinements of PHI nodes, or relax non-dominating refinements to
    # their own refinements, if those dominate the PHI node.
    visited = falses(n)
    for num in phi_numbers
        (num < 0 || has_bit(extern_rooted, num)) && continue
        visited[num+1] = true
        phi = S.reverse_ptr_numbering[num]
        refined_ptr = get!(Vector{Int}, S.refinements, num)
        j = 0  # the new length (0-based indices i and j, as in the C++)
        i = 0
        while i < length(refined_ptr)
            refine = refined_ptr[i+1]
            if refine < 0 || visited[refine+1]
                i += 1
                continue
            end
            visited[refine+1] = true
            i != j && (refined_ptr[j+1] = refine)
            j += 1
            inst = S.reverse_ptr_numbering[refine]
            if inst isa Instruction
                if dominates(dominator_tree(p), inst, phi)
                    i += 1
                    continue
                end
                j -= 1  # overwrite/ignore it
                # non-dominating refinement
                r = get(S.refinements, refine, nothing)
                if r !== nothing && !isempty(r)
                    # found a replacement: fill in the gap between i and j first
                    new_refined = copy(r)
                    k = 0
                    while k < length(new_refined) && i >= j + k
                        refined_ptr[i-k+1] = new_refined[k+1]
                        k += 1
                    end
                    i = i - k
                    k < length(new_refined) && append!(refined_ptr, new_refined[k+1:end])
                    i += 1
                    continue
                end
                # invalid: remove all refinements
                empty!(refined_ptr)
                break
            end
            i += 1
        end
        if !isempty(refined_ptr)
            # j == 0 means that everything is externally rooted, handled above
            @assert j != 0 && j <= length(refined_ptr)
            resize!(refined_ptr, j)
        else
            delete!(S.refinements, num)
        end
        fill!(visited, false)
    end
end

# Look through selects and phis to find all possible alloca bases of a pointer, or none
# if a non-alloca base is found. The bases may differ in size and type.
function find_alloca_bases(@nospecialize(v::Value))
    allocas = Instruction[]
    if v isa LLVM.AllocaInst
        push!(allocas, v)
        return allocas
    end
    worklist = Value[v]
    visited = Set{ValueRef}((vref(v),))
    while !isempty(worklist)
        w = pop!(worklist)
        stripped = strip_in_bounds_offsets(w)
        if stripped isa LLVM.AllocaInst
            any(a -> a == stripped, allocas) || push!(allocas, stripped)
        elseif w isa LLVM.PHIInst
            for (incoming, _) in collect(w.incoming)
                if !(vref(incoming) in visited)
                    push!(visited, vref(incoming))
                    push!(worklist, incoming)
                end
            end
        elseif w isa LLVM.SelectInst
            for op in (w.operands[2], w.operands[3])
                if !(vref(op) in visited)
                    push!(visited, vref(op))
                    push!(worklist, op)
                end
            end
        else
            empty!(allocas)
            return allocas
        end
    end
    return allocas
end

is_static_alloca(ai::Instruction) =
    ai.operands[1] isa LLVM.ConstantInt && ai.parent == first(LLVM.parent(ai.parent).blocks)

alloca_array_size(ai::Instruction) = convert(Int, ai.operands[1]::LLVM.ConstantInt)

function is_tracked_pointer_type(t::LLVMType)
    ref = Base.unsafe_convert(TypeRef, t)
    return is_pointer_type(ref) && type_addrspace(ref) == AS_TRACKED
end

function maybe_track_store!(p::LateLowerGCFrame, S::State, si::Instruction)
    ptr_base = strip_in_bounds_offsets(si.operands[2])
    tracked = CountTrackedPointers(typeref(si.operands[1]))
    tracked.count == 0 && return false  # nothing to track is being stored
    # SROA and InstCombine can merge conditional stores to allocas into a select or phi
    # of allocas (JuliaLang/julia#60985)
    allocas = find_alloca_bases(ptr_base)
    isempty(allocas) && return false  # assume it is rooted
    needs_tracked_store = false
    is_tracked = false
    for ai in allocas
        sty = LLVM.allocated_type(ai)
        if !is_static_alloca(ai) || is_tracked_pointer_type(sty) || has_array_alloca(S, ai)
            continue  # already numbered
        end
        alloca_tracked = CountTrackedPointers(Base.unsafe_convert(TypeRef, sty))
        if alloca_tracked.count > 0
            @assert !alloca_tracked.derived
            if alloca_tracked.all
                # track the alloca directly
                set_array_alloca!(S, ai, alloca_tracked.count * alloca_array_size(ai))
                is_tracked = true
                continue
            end
        end
        needs_tracked_store = true
    end
    if needs_tracked_store
        # track the store with a shadow
        push!(S.tracked_stores, (si, tracked.count))
        is_tracked = true
    end
    return is_tracked
end

const SRET_ERROR = "LateLowerGCFrame: expected an alloca as the destination of returned roots"

# the type of an `sret` attribute of the first argument of a call, or nothing
function sret_type(call::Instruction)
    length(call.arguments) >= 1 || return nothing
    attrs = collect(call.argument_attributes[1])
    callee = called_function(call)
    if callee !== nothing && !isempty(callee.parameters)
        append!(attrs, collect(callee.parameter_attributes[1]))
    end
    for a in attrs
        a isa TypeAttribute && attr_kind(a) == "sret" && return LLVM.value(a)
    end
    return nothing
end

function string_param_attr(call::Instruction, i::Int, name::String)
    for a in collect(call.argument_attributes[i])
        a isa StringAttribute && attr_kind(a) == name && return LLVM.value(a)
    end
    return nothing
end

# the roots a call returns in memory (`julia.return_roots` on master, `sret` before);
# returns whether the call defines them
function note_return_roots!(p::LateLowerGCFrame, S::State, call::Instruction)
    has_def_before = false
    if p.dialect.gc_return_roots === :attribute
        for i in 1:length(call.arguments)
            attr = string_param_attr(call, i, "julia.return_roots")
            attr === nothing && continue
            return_roots = something(tryparse(Int, attr), 0)
            has_def_before = true
            gc_allocas = find_alloca_bases(strip_in_bounds_offsets(call.arguments[i]))
            isempty(gc_allocas) && error(SRET_ERROR * ": $(string(call))")
            for ai in gc_allocas
                elt = LLVM.allocated_type(ai)
                if !(is_static_alloca(ai) && is_tracked_pointer_type(elt))
                    # a maximum, since calls may be cloned
                    live_roots = get(S.array_alloca_roots, vref(ai), 0)
                    set_array_alloca!(S, ai, max(live_roots, return_roots))
                end
            end
        end
    else
        elt = sret_type(call)
        elt === nothing && return false
        eltref = Base.unsafe_convert(TypeRef, elt)
        tracked = CountTrackedPointers(eltref, true)
        tracked.count == 0 && return false
        has_def_before = true
        sret_base = strip_in_bounds_offsets(call.arguments[1])
        allocas = find_alloca_bases(sret_base)
        # trampolines forward their own sret argument, rooted by their caller
        if isempty(allocas) && !(sret_base isa LLVM.Argument && argument_has_sret(sret_base))
            error(SRET_ERROR * ": $(string(call))")
        end
        for sret in allocas
            is_static_alloca(sret) && is_tracked_pointer_type(elt) && continue
            @assert !tracked.derived
            if tracked.all
                set_array_alloca!(S, sret, tracked.count * alloca_array_size(sret))
            else
                arg1 = strip_in_bounds_offsets(call.arguments[2])
                gc_allocas = find_alloca_bases(arg1)
                isempty(gc_allocas) && error(SRET_ERROR * ": $(string(call))")
                for sret_gc in gc_allocas
                    elt_gc = LLVM.allocated_type(sret_gc)
                    if !(is_static_alloca(sret_gc) && is_tracked_pointer_type(elt_gc))
                        set_array_alloca!(S, sret_gc, tracked.count * alloca_array_size(sret_gc))
                    end
                end
            end
        end
    end
    return has_def_before
end

argument_index(arg::LLVM.Argument) = findfirst(==(arg), collect(LLVM.parent(arg).parameters))
argument_has_sret(arg::LLVM.Argument) =
    any(a -> attr_kind(a) == "sret", collect(LLVM.parent(arg).parameter_attributes[argument_index(arg)]))

# calls emitted by codegen that are not safepoints
const NON_SAFEPOINT_RUNTIME_CALLS = ("jl_egal__unboxed", "jl_lock_value", "jl_unlock_value",
                                     "jl_lock_field", "jl_unlock_field", "memcmp")

function is_non_safepoint_callee(p::LateLowerGCFrame, callee::LLVM.Function)
    fns = p.fns
    for f in (fns.pointer_from_objref, fns.gc_preserve_begin, fns.gc_preserve_end,
              fns.typeof, fns.blackbox, fns.pgcstack_getter, fns.gc_loaded,
              fns.pop_handler_noexcept)
        is_fn(f, callee) && return true
    end
    is_write_barrier(fns, callee) && return true
    return LLVM.name(callee) in NON_SAFEPOINT_RUNTIME_CALLS
end

const DBG_INTRINSIC_PREFIX = "llvm.dbg."
const LIFETIME_START_INTR = Intrinsic("llvm.lifetime.start")
const LIFETIME_END_INTR = Intrinsic("llvm.lifetime.end")

function scan_call!(p::LateLowerGCFrame, S::State, BBS::BBState, ci::Instruction)
    if is_intrinsic_call(ci)
        # Most intrinsics are not GC uses or defs, but some have memory operands. Only
        # skip those that are emitted often and cannot be GC uses.
        callee = called_function(ci)
        if startswith(LLVM.name(callee), DBG_INTRINSIC_PREFIX) ||
           intrinsic_is(ci, LIFETIME_START_INTR) || intrinsic_is(ci, LIFETIME_END_INTR)
            return
        end
        if intrinsic_is(ci, MASKED_LOAD) || intrinsic_is(ci, MASKED_GATHER)
            t = typeref(ci)
            if is_vector_type(t)
                elt = API.LLVMGetElementType(t)
                if CountTrackedPointers(elt).count > 0
                    # LLVM sometimes materializes these with undefined pointers in Julia's
                    # address spaces: make them null
                    passthru_idx = library_facts(context(ci)).masked_load_alignment ? 4 : 3
                    passthru = ci.operands[passthru_idx]
                    if is_undef(passthru)
                        ci.operands[passthru_idx] = LLVM.null(LLVM.value_type(passthru))
                    end
                end
                has_loaded_ty(elt) && return  # not real defs
            end
        end
        if intrinsic_is(ci, VECTOR_EXTRACT) || intrinsic_is(ci, VECTOR_INSERT)
            return  # not real defs
        end
    end
    callee = called_function(ci)
    if callee !== nothing && is_fn(p.fns.typeof, callee)
        maybe_note_def!(p, S, BBS, ci, [-2])
    elseif callee !== nothing && is_fn(p.fns.gc_loaded, callee)
        return
    else
        maybe_note_def!(p, S, BBS, ci) &&
            (BBS.first_safepoint_after_first_def = BBS.first_safepoint)
    end
    has_def_before = note_return_roots!(p, S, ci)
    note_operand_uses!(p, S, BBS, ci)
    # calls that codegen marks `julia.safepoint` had their memory effects narrowed from
    # inferred effects, but can still reach a safepoint
    marked_safepoint = call_has_fn_attr(ci, "julia.safepoint", true)
    returns_twice = can_return_twice(ci)
    if !returns_twice
        if callee !== nothing
            if is_fn(p.fns.gc_preserve_begin, callee)
                args = Int[]
                for v in ci.arguments
                    v isa LLVM.Constant && continue
                    if is_pointer_value(v)
                        if is_special_ptr(typeref(v))
                            num = number!(p, S, v)
                            num >= 0 && push!(args, num)
                        end
                    else
                        for num in number_all!(p, S, v)
                            num >= 0 && push!(args, num)
                        end
                    end
                end
                push!(S.gc_preserves, ci => args)
                return
            end
            is_non_safepoint_callee(p, callee) && return
            effects = function_memory_effects(callee)
            if !marked_safepoint &&
               (only_reads_memory(effects) || only_accesses_arg_pointees(effects))
                return
            end
        end
        # intrinsics are never safepoints
        is_intrinsic_call(ci) && return
        effects = call_memory_effects(ci)
        # readonly functions, and those that cannot change GC state (which is
        # inaccessible memory), are not safepoints
        if !marked_safepoint &&
           (only_accesses_arg_pointees(effects) || only_reads_memory(effects))
            return
        end
    end
    callee_roots = Int[]
    for v in ci.arguments
        # arguments rooted by the callee; recorded, since other values may be refined to them
        (v isa LLVM.Constant || !is_pointer_value(v) ||
         value_addrspace(v) != AS_CALLEE_ROOTED) && continue
        v = strip_pointer_casts(v)
        is_tracked_value(v) || continue
        num = number!(p, S, v)
        num < 0 && continue
        push!(callee_roots, num)
    end
    safepoint_number = note_safepoint!(S, BBS, ci, callee_roots)
    if returns_twice
        push!(S.returns_twice, safepoint_number)
        has_def_before = true
    end
    # with returned roots, the def happens before the call instead of after
    has_def_before && (BBS.first_safepoint_after_first_def = safepoint_number)
    return
end

function scan_instruction!(p::LateLowerGCFrame, S::State, BBS::BBState, inst::Instruction,
                           phi_numbers::Vector{Int})
    if inst isa LLVM.CallInst
        scan_call!(p, S, BBS, inst)
    elseif inst isa LLVM.LoadInst
        # A load from a rooted region is rooted as long as the object it loads from is,
        # so its uses are refined to that object.
        refined_ptr = Int[]
        ty = scalar_typeref(typeref(inst))
        refined_globally = false
        task_local = Ref(false)
        ptr = inst.operands[1]
        if is_load_from_rooted_region(p, inst) && is_special_ptr(typeref(ptr))
            push!(refined_ptr, number!(p, S, ptr))
        elseif p.dialect.gc_frame_ref_refinement && is_pointer_value(inst) &&
               is_special_ptr(ty) && looks_like_frame_ref(ptr)
            # loads from a jlcall argument array
            push!(refined_ptr, -1)
        elseif is_load_from_const_gv(p, inst, task_local)
            # A constant global's object is constant too, and doesn't need a root; a
            # task-local one needs write barriers for when the task dies.
            push!(refined_ptr, task_local[] ? -1 : -2)
            refined_globally = true
        end
        if !has_loaded_ty(ty)
            if maybe_note_def!(p, S, BBS, inst, refined_ptr) && !refined_globally
                BBS.first_safepoint_after_first_def = BBS.first_safepoint
            end
        end
        note_operand_uses!(p, S, BBS, inst)
    elseif inst isa LLVM.AtomicCmpXchgInst
        ty = scalar_typeref(typeref(inst.operands[3]))
        if !(is_pointer_type(ty) && type_addrspace(ty) == AS_LOADED)
            maybe_note_def!(p, S, BBS, inst) &&
                (BBS.first_safepoint_after_first_def = BBS.first_safepoint)
        end
        note_operand_uses!(p, S, BBS, inst)
    elseif inst isa LLVM.AtomicRMWInst
        ty = scalar_typeref(typeref(inst))
        if !(is_pointer_type(ty) && type_addrspace(ty) == AS_LOADED)
            maybe_note_def!(p, S, BBS, inst) &&
                (BBS.first_safepoint_after_first_def = BBS.first_safepoint)
        end
        note_operand_uses!(p, S, BBS, inst)
    elseif inst isa LLVM.SelectInst
        tracked = CountTrackedPointers(typeref(inst))
        if tracked.count > 0 && !tracked.derived
            # record the select definition of these values
            refined_ptr = is_pointer_value(inst) ?
                [number!(p, S, inst.operands[2]), number!(p, S, inst.operands[3])] : Int[]
            maybe_note_def!(p, S, BBS, inst, refined_ptr)
            note_operand_uses!(p, S, BBS, inst)
        elseif tracked.count > 0
            # extra selects for the GC roots
            lift_select!(p, S, inst)
        end
    elseif inst isa LLVM.PHIInst
        tracked = CountTrackedPointers(typeref(inst))
        if tracked.count > 0 && !tracked.derived
            # record the phi definition of these values
            refinements = is_pointer_value(inst) ? get_phi_refinements(p, inst, S) : Int[]
            maybe_note_def!(p, S, BBS, inst, refinements)
            if is_pointer_value(inst)
                push!(phi_numbers, number!(p, S, inst))
            else
                append!(phi_numbers, number_all!(p, S, inst))
            end
            for (incoming, incoming_bb) in collect(inst.incoming)
                incoming_bbs = bb_state(S, incoming_bb)
                note_use!(p, S, incoming, incoming_bbs.phi_outs)
            end
        elseif tracked.count > 0
            # extra phis for the GC roots
            lift_phi!(p, S, inst)
        end
    elseif inst isa LLVM.StoreInst
        note_operand_uses!(p, S, BBS, inst)
        maybe_track_store!(p, S, inst) &&
            (BBS.first_safepoint_after_first_def = BBS.first_safepoint)
    elseif inst isa LLVM.RetInst
        note_operand_uses!(p, S, BBS, inst)
    elseif inst isa LLVM.AddrSpaceCastInst
        if is_tracked_value(inst)
            refined_ptr = Int[]
            task_local = Ref(false)
            origin = strip_pointer_casts(inst.operands[1])
            if origin isa LLVM.LoadInst && is_load_from_const_gv(p, origin, task_local)
                push!(refined_ptr, task_local[] ? -1 : -2)
            end
            maybe_note_def!(p, S, BBS, inst, refined_ptr)
        end
    elseif inst isa LLVM.ExtractElementInst
        if is_tracked_value(inst) && !(inst.operands[2] isa LLVM.ConstantInt)
            refined_ptr = copy(number_all!(p, S, inst.operands[1]))
            maybe_note_def!(p, S, BBS, inst, refined_ptr) &&
                (BBS.first_safepoint_after_first_def = BBS.first_safepoint)
            note_operand_uses!(p, S, BBS, inst)
        end
    elseif inst isa LLVM.AllocaInst
        elt = LLVM.allocated_type(inst)
        if is_static_alloca(inst) && is_tracked_pointer_type(elt)
            if p.dialect.gc_root_allocas_first
                push!(S.root_allocas, inst)
            else
                set_array_alloca!(S, inst, alloca_array_size(inst))
            end
        end
    end
    return
end

function local_scan(p::LateLowerGCFrame, f::LLVM.Function)
    S = State(f)
    phi_numbers = Int[]
    for bb in f.blocks
        BBS = bb_state(S, bb)
        # backwards, so that instructions inserted before the current one (lifted
        # selects and phis) are scanned too
        last_ref = API.LLVMGetLastInstruction(bb)
        inst = last_ref == C_NULL ? nothing : Instruction(last_ref)
        while inst !== nothing
            scan_instruction!(p, S, BBS, inst, phi_numbers)
            inst = inst.prev
        end
        # pre-seed the dataflow variables
        BBS.live_in = copy(BBS.up_exposed_uses)
    end
    fix_up_refinements!(p, phi_numbers, S)
    return S
end


## liveness

# the reachable blocks in post order
function post_order(f::LLVM.Function)
    order = BasicBlock[]
    visited = Set{ValueRef}()
    entry = first(f.blocks)
    stack = [(entry, 1)]
    push!(visited, vref(entry))
    succs = Dict{ValueRef,Vector{BasicBlock}}()
    successors_of(bb) = get!(() -> collect(bb.successors), succs, vref(bb))
    while !isempty(stack)
        bb, i = stack[end]
        ss = successors_of(bb)
        if i <= length(ss)
            stack[end] = (bb, i + 1)
            s = ss[i]
            if !(vref(s) in visited)
                push!(visited, vref(s))
                push!(stack, (s, 1))
            end
        else
            pop!(stack)
            push!(order, bb)
        end
    end
    return order
end

# LiveIn[BB] = UpExposedUses[BB] ∪ (LiveOut[BB] - Defs[BB])
# LiveOut[BB] = PhiUses[BB] ∪ ∪_{Succ} LiveIn[Succ]
function compute_liveness!(p::LateLowerGCFrame, S::State)
    blocks = post_order(S.f)
    converged = false
    while !converged
        any_changed = false
        for bb in blocks
            BBS = bb_state(S, bb)
            new_live = copy(BBS.phi_outs)
            for succ in bb.successors
                union!(new_live, bb_state(S, succ).live_in)
            end
            if new_live != BBS.live_out
                any_changed = true
                BBS.live_out = copy(new_live)
            end
            setdiff!(new_live, BBS.defs)
            union!(new_live, BBS.up_exposed_uses)
            if new_live != BBS.live_in
                any_changed = true
                BBS.live_in = new_live
            end
        end
        converged = !any_changed
    end
    compute_live_sets!(p, S)
end

function is_indirectly_rooted(S::State, visited::BitSet, indirectly_rooted::BitSet,
                              ls::BitSet, ref_ptr::Int)
    ref_ptr in indirectly_rooted && return true
    ref_ptr in visited && return false
    refined_ptr = get(S.refinements, ref_ptr, nothing)
    if refined_ptr === nothing
        push!(visited, ref_ptr)
        return false
    end
    rooted = true
    for n in refined_ptr
        (n < 0 || is_indirectly_rooted(S, visited, indirectly_rooted, ls, n)) && continue
        # not indirectly rooted, but in the live set: can be used to establish a root
        n in ls && continue
        rooted = false
        break
    end
    rooted && push!(indirectly_rooted, ref_ptr)
    push!(visited, ref_ptr)
    return rooted
end

# Remove the values from a live set that are kept alive by other values in it, following
# the refinement graph.
function refine_live_set!(S::State, ls::BitSet, callee_roots::Vector{Int})
    visited = BitSet()
    indirectly_rooted = BitSet()
    for num in callee_roots
        # kept alive by the callee, so other values can be refined to them
        push!(indirectly_rooted, num)
        delete!(ls, num)
    end
    for idx in collect(ls)
        is_indirectly_rooted(S, visited, indirectly_rooted, ls, idx) && delete!(ls, idx)
    end
end

function compute_live_sets!(p::LateLowerGCFrame, S::State)
    # add to the live sets the values live across their safepoint's block
    for (idx, safepoint) in enumerate(S.safepoint_numbering)
        BBS = bb_state(S, safepoint.parent)
        live_across = intersect(BBS.live_in, BBS.live_out)
        ls = S.live_sets[idx]
        union!(ls, live_across)
        for live in S.live_if_live_out[idx]
            live in BBS.live_out && push!(ls, live)
        end
        refine_live_set!(S, ls, S.callee_roots[idx])
        # GC preserves keep their values alive at the safepoints between them and an end
        if !isempty(S.gc_preserves)
            dt = dominator_tree(p)
            for (begin_call, nums) in S.gc_preserves
                dominates(dt, begin_call, safepoint) || continue
                outside_range = false
                for use in begin_call.uses
                    if dominates(dt, LLVM.user(use)::Instruction, safepoint)
                        outside_range = true
                        break
                    end
                end
                outside_range && continue
                union!(ls, nums)
            end
        end
    end
    # the interference graph
    S.neighbors = [BitSet() for _ in 0:S.max_ptr_number]
    for ls in S.live_sets
        for idx in ls
            union!(S.neighbors[idx+1], ls)
        end
    end
end


## root colouring

# Vertices in a perfect elimination ordering of the (chordal, for SSA) interference
# graph, so that greedy coloring is optimal.
mutable struct PEOIterator
    weights::Vector{Int}   # -1 once processed
    positions::Vector{Int}
    levels::Vector{Vector{Int}}
    neighbors::Vector{BitSet}
end

function PEOIterator(neighbors::Vector{BitSet})
    n = length(neighbors)
    return PEOIterator(zeros(Int, n), collect(0:n-1), [collect(0:n-1)], neighbors)
end

function next!(it::PEOIterator)
    # the element in the highest bucket
    next_element = -1
    while next_element == -1 && !isempty(it.levels)
        last_level = it.levels[end]
        while next_element == -1 && !isempty(last_level)
            next_element = pop!(last_level)
        end
        isempty(last_level) && pop!(it.levels)
    end
    next_element == -1 && return -1
    it.weights[next_element+1] = -1
    # raise neighbors
    for neighbor in it.neighbors[next_element+1]
        neighbor == next_element && continue
        w = it.weights[neighbor+1]
        w == -1 && continue  # already processed
        it.levels[w+1][it.positions[neighbor+1]+1] = -1
        w += 1
        it.weights[neighbor+1] = w
        w >= length(it.levels) && push!(it.levels, Int[])
        push!(it.levels[w+1], neighbor)
        it.positions[neighbor+1] = length(it.levels[w+1]) - 1
    end
    return next_element
end

# the color (frame slot) of every value (0-based numbers, -1 for none), and the number
# of colors given to the values live at returns_twice calls
function color_roots(S::State)
    colors = fill(-1, S.max_ptr_number + 1)
    ordering = PEOIterator(S.neighbors)
    pre_assigned = 0
    # permanent slots for the values live at returns_twice calls
    for num in S.returns_twice
        for idx in S.live_sets[num+1]
            if colors[idx+1] == -1
                colors[idx+1] = pre_assigned
                pre_assigned += 1
            end
        end
    end
    # greedy coloring
    max_assigned = -1
    while (active = next!(ordering)) != -1
        colors[active+1] != -1 && continue
        # no need to color a value not live at any safepoint
        isempty(S.neighbors[active+1]) && continue
        used = falses(max_assigned + 2)
        for neighbor in S.neighbors[active+1]
            c = colors[neighbor+1]
            (c == -1 || c < pre_assigned) && continue
            used[c-pre_assigned+1] = true
        end
        new_color = findfirst(!, used) - 1
        new_color > max_assigned && (max_assigned = new_color)
        colors[active+1] = new_color + pre_assigned
    end
    return colors, pre_assigned
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
function add_gc_alloc_attributes!(p::LateLowerGCFrame, f::LLVM.Function)
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

# a GC intrinsic or runtime function, declared if the module doesn't have it yet
# (`JuliaPassContext::getOrDeclare`)
function get_or_declare(p::LateLowerGCFrame, which::Symbol)
    T_ptr = LLVM.PointerType(AS_GENERIC)
    T_int32 = LLVM.Int32Type()
    T_void = LLVM.VoidType()
    name, ft = if which === :get_gc_frame_slot
        "julia.get_gc_frame_slot", LLVM.FunctionType(T_ptr, [T_ptr, T_int32])
    elseif which === :gc_alloc_bytes
        "julia.gc_alloc_bytes",
        LLVM.FunctionType(p.T_prjlvalue, p.dialect.gc_alloc_bytes_tag ?
                          [T_ptr, p.T_size, p.T_size] : [T_ptr, p.T_size])
    elseif which === :new_gc_frame
        "julia.new_gc_frame", LLVM.FunctionType(T_ptr, [T_int32])
    elseif which === :push_gc_frame
        "julia.push_gc_frame", LLVM.FunctionType(T_void, [T_ptr, T_int32])
    elseif which === :pop_gc_frame
        "julia.pop_gc_frame", LLVM.FunctionType(T_void, [T_ptr])
    elseif which === :queue_gc_root
        "julia.queue_gc_root", LLVM.FunctionType(T_void, [p.T_prjlvalue])
    elseif which === :gc_small_alloc
        "ijl_gc_small_alloc", LLVM.FunctionType(p.T_prjlvalue, [T_ptr, T_int32, T_int32, p.T_size])
    else
        error("unknown GC intrinsic $which")
    end
    existing = get(p.mod.functions, name, nothing)
    existing === nothing || return existing
    f = LLVM.Function(p.mod, name, ft)
    if which === :gc_alloc_bytes
        push!(f.function_attributes, alloc_size_attr(1))
        add_gc_alloc_attributes!(p, f)
    elseif which === :new_gc_frame
        push!(f.return_attributes, EnumAttribute("noalias"))
        push!(f.return_attributes, EnumAttribute("nonnull"))
    elseif which === :queue_gc_root
        push!(f.function_attributes, inaccessible_or_arg_mem_only())
    elseif which === :gc_small_alloc
        push!(f.function_attributes, alloc_size_attr(2))
        add_gc_alloc_attributes!(p, f)
    end
    return f
end

function call_intrinsic!(p::LateLowerGCFrame, which::Symbol, args::Vector{<:Value},
                         name::String="")
    f = get_or_declare(p, which)
    return call!(p.builder, f.function_type, f, Value[args...], name)
end

slot_name(p::LateLowerGCFrame, prefix::String, slot::Integer) =
    p.dialect.gc_names ? string(prefix, slot) : ""


## root placement

# the values live in from all predecessors, at their last safepoint
function add_in_predecessor_live_outs!(S::State, bb::BasicBlock, live_in::BitSet)
    first_pred = true
    visited = Set{ValueRef}()
    worklist = BasicBlock[bb]
    entry = first(S.f.blocks)
    while !isempty(worklist)
        bb = pop!(worklist)
        # nothing is live at function entry
        if bb == entry
            empty!(live_in)
            return
        end
        for pred in bb.predecessors
            vref(pred) in visited && continue
            push!(visited, vref(pred))
            pred_state = bb_state(S, pred)
            if !pred_state.has_safepoint
                push!(worklist, pred)
                continue
            end
            last_sp = pred_state.last_safepoint
            if first_pred
                union!(live_in, S.live_sets[last_sp+1])
                first_pred = false
            else
                intersect!(live_in, S.live_sets[last_sp+1])
            end
            isempty(live_in) && return
        end
    end
end

function gc_frame_slot!(p::LateLowerGCFrame, gcframe::Instruction, slot::Int, name::String)
    return call_intrinsic!(p, :get_gc_frame_slot,
                           Value[gcframe, ConstantInt(LLVM.Int32Type(), slot)], name)
end

function place_gc_frame_store!(p::LateLowerGCFrame, S::State, r::Int, min_color_root::Int,
                               colors::Vector{Int}, gcframe::Instruction,
                               insert_before::Instruction)
    slot = colors[r+1] + min_color_root
    position_before!(p.builder, insert_before; debug=false)
    slot_address = gc_frame_slot!(p, gcframe, slot, slot_name(p, "gc_slot_addr_", slot))
    val = get_ptr_for_number(p, S, r, insert_before)
    @assert LLVM.value_type(val) == p.T_prjlvalue
    position_before!(p.builder, insert_before; debug=false)
    store!(p.builder, val, slot_address)
end

function place_gc_frame_reset!(p::LateLowerGCFrame, S::State, r::Int, min_color_root::Int,
                               colors::Vector{Int}, gcframe::Instruction,
                               insert_before::Instruction)
    slot = colors[r+1] + min_color_root
    position_before!(p.builder, insert_before; debug=false)
    slot_address = gc_frame_slot!(p, gcframe, slot, slot_name(p, "gc_slot_addr_", slot))
    store!(p.builder, LLVM.null(p.T_prjlvalue), slot_address)
end

function place_gc_frame_stores!(p::LateLowerGCFrame, S::State, min_color_root::Int,
                                colors::Vector{Int}, pre_assigned::Int, gcframe::Instruction)
    for bb in S.f.blocks
        BBS = bb_state(S, bb)
        BBS.has_safepoint || continue
        live_in = BitSet()
        add_in_predecessor_live_outs!(S, bb, live_in)
        last_live = live_in
        for safepoint in BBS.first_safepoint:-1:BBS.last_safepoint
            now_live = S.live_sets[safepoint+1]
            insert_before = S.safepoint_numbering[safepoint+1]
            if p.dialect.gc_slot_resets
                # reset slots of values that died
                for idx in last_live
                    if colors[idx+1] >= pre_assigned && !(idx in now_live)
                        place_gc_frame_reset!(p, S, idx, min_color_root, colors, gcframe,
                                              insert_before)
                    end
                end
            end
            # store values that are live here, but haven't been stored yet
            for idx in now_live
                if !(idx in last_live)
                    place_gc_frame_store!(p, S, idx, min_color_root, colors, gcframe,
                                          insert_before)
                end
            end
            last_live = now_live
        end
    end
end

# the users of `v`, through GEPs and casts, that are intrinsic calls (`RecursivelyVisit`)
function recursively_visit_intrinsics(f, @nospecialize(v::Value))
    for use in collect(v.uses)
        user = LLVM.user(use)
        user isa LLVM.CallInst && is_intrinsic_call(user) && f(user)
        if user isa LLVM.CallInst || user isa LLVM.LoadInst || user isa LLVM.SelectInst ||
           user isa LLVM.PHIInst || user isa LLVM.StoreInst || user isa LLVM.PtrToIntInst ||
           user isa LLVM.ICmpInst || user isa LLVM.InsertElementInst ||
           user isa LLVM.AtomicCmpXchgInst || user isa LLVM.AtomicRMWInst
            continue
        end
        if user isa LLVM.GetElementPtrInst || user isa LLVM.BitCastInst ||
           user isa LLVM.AddrSpaceCastInst
            recursively_visit_intrinsics(f, user)
            continue
        end
        error("LateLowerGCFrame: unexpected use of an alloca moved into the GC frame: $(string(user))")
    end
end

# whether a store or memset in the prologue stores null to a rooted alloca, which the
# frame's slots already are; `nothing` stops the scan
function prologue_null_store(S::State, inst::Instruction)
    if inst isa LLVM.StoreInst
        ptr, val, vol = inst.operands[2], inst.operands[1], inst.volatile
    elseif inst isa LLVM.CallInst && intrinsic_is(inst, MEMSET_INTR)
        ptr, val = inst.operands[1], inst.operands[2]
        vol = convert(Int, inst.operands[4]) != 0
    else
        return false
    end
    ptr = strip_in_bounds_offsets(ptr)
    ptr isa LLVM.GetElementPtrInst && return nothing
    (ptr isa LLVM.AllocaInst && has_array_alloca(S, ptr)) || return false
    # stop at a pointer operation that can't be analyzed or isn't a null store
    (vol || !(val isa LLVM.Constant) || !is_null_value(val)) && return nothing
    return true
end

const MEMSET_INTR = Intrinsic("llvm.memset")

is_null_value(c::LLVM.Constant) = API.LLVMIsNull(c) != 0

function place_roots_and_update_calls!(p::LateLowerGCFrame, colors::Vector{Int},
                                       pre_assigned::Int, S::State)
    f = S.f
    T_int32 = LLVM.Int32Type()
    max_color = maximum(colors; init=-1)
    (max_color != -1 || !isempty(S.array_allocas) || !isempty(S.root_allocas) ||
     !isempty(S.tracked_stores)) || return
    builder = p.builder
    entry = first(f.blocks)

    # create and push a GC frame
    position_before!(builder, first(entry.instructions); debug=false)
    gcframe = call_intrinsic!(p, :new_gc_frame, Value[ConstantInt(T_int32, 0)], "gcframe")
    position!(builder, LLVM.after(p.pgcstack isa LLVM.Argument ? gcframe :
                                  p.pgcstack::Instruction))
    builder.debug_location = nothing
    push_gcframe = call_intrinsic!(p, :push_gc_frame, Value[gcframe, ConstantInt(T_int32, 0)])

    if p.dialect.gc_prologue_store_elision
        # we don't run memsetopt after this, so remove null stores in the prologue, since
        # the frame slots are null already
        to_erase = nothing
        for inst in collect(entry.instructions)
            if to_erase !== nothing
                erase!(to_erase)
                to_erase = nothing
            end
            r = prologue_null_store(S, inst)
            r === nothing && break
            r && (to_erase = inst)
        end
        to_erase === nothing || erase!(to_erase)
    end

    # replace allocas
    alloca_slot = GC_FRAME_HEADER_SLOTS
    frame_align = TAG_ALIGNMENT
    ptrsize = pointer_size(p)
    function replace_alloca(ai::Instruction)
        # preserve both the alloca's alignment and its offset within the frame
        align = Int(LLVM.alignment(ai))
        frame_align = max(frame_align, align)
        slots = align ÷ ptrsize
        slots > 1 && (alloca_slot = cld(alloca_slot, slots) * slots)
        position!(builder, LLVM.after(gcframe))
        builder.debug_location = nothing
        slot_address = gc_frame_slot!(p, gcframe, alloca_slot - GC_FRAME_HEADER_SLOTS,
                                      slot_name(p, "gc_slot_addr", alloca_slot - GC_FRAME_HEADER_SLOTS))
        take_name!(slot_address, ai)
        # lifetime intrinsics no longer apply
        to_delete = Instruction[]
        recursively_visit_intrinsics(ai) do ii
            (intrinsic_is(ii, LIFETIME_START_INTR) || intrinsic_is(ii, LIFETIME_END_INTR)) &&
                push!(to_delete, ii)
        end
        foreach(erase!, to_delete)
        replace_uses!(ai, slot_address)
        erase!(ai)
    end
    for ai in S.root_allocas
        n = alloca_array_size(ai)
        replace_alloca(ai)
        alloca_slot += n
    end
    # The C++ iterates over a hash map keyed by the allocas' addresses, which roughly
    # follows the order in which they were created; this uses their order in the function.
    position = Dict{ValueRef,Int}()
    for (i, inst) in enumerate(entry.instructions)
        inst isa LLVM.AllocaInst && (position[vref(inst)] = i)
    end
    array_allocas = sort(S.array_allocas; by=ai -> get(position, vref(ai), typemax(Int)))
    for ai in array_allocas
        n = S.array_alloca_roots[vref(ai)]
        replace_alloca(ai)
        alloca_slot += n
    end
    for (si, count) in S.tracked_stores
        base = si.operands[1]
        for i in 0:count-1
            position!(builder, LLVM.after(gcframe))
            builder.debug_location = nothing
            slot_address = gc_frame_slot!(p, gcframe, alloca_slot - GC_FRAME_HEADER_SLOTS,
                                          slot_name(p, "gc_slot_addr", alloca_slot - GC_FRAME_HEADER_SLOTS))
            elem = maybe_extract_scalar(p, S, (base, is_pointer_value(base) ? -1 : i), si)
            @assert LLVM.value_type(elem) == p.T_prjlvalue
            position_before!(builder, si; debug=false)
            store!(builder, elem, slot_address)
            alloca_slot += 1
        end
    end
    nroots = ConstantInt(T_int32, max_color + 1 + alloca_slot - GC_FRAME_HEADER_SLOTS)
    gcframe.operands[1] = nroots
    if frame_align > TAG_ALIGNMENT
        push!(gcframe.return_attributes, EnumAttribute("align", frame_align))
    end
    push_gcframe.operands[2] = nroots

    # stores to the GC frame
    place_gc_frame_stores!(p, S, alloca_slot - GC_FRAME_HEADER_SLOTS, colors, pre_assigned,
                           gcframe)
    # pops
    for bb in f.blocks
        term = bb.terminator
        if term isa LLVM.RetInst
            position_before!(builder, term; debug=false)
            call_intrinsic!(p, :pop_gc_frame, Value[gcframe])
        end
    end
    return
end


## cleanup

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

# set a TBAA tag, and mark loads of constant memory invariant (`tbaa_decorate`)
function tbaa_decorate!(md::MDNode, inst::Instruction)
    inst.metadata[LLVM.MD_tbaa] = md
    if inst isa LLVM.LoadInst && md == tbaa_const()
        inst.metadata[LLVM.MD_invariant_load] = MDNode(Metadata[])
    end
    return inst
end

value_name(@nospecialize(v::Value)) = LLVM.name(v)

# the address of the type tag of an object: the word before it (`EmitTagPtr`)
function emit_tag_ptr!(p::LateLowerGCFrame, t::LLVMType, @nospecialize(v::Value))
    name = p.dialect.gc_names ? value_name(v) * ".tag_addr" : ""
    return inbounds_gep!(p.builder, t, v, [ConstantInt(p.T_size, -1)], name)
end

# a load of the type tag of an object (`EmitLoadTag`)
function emit_load_tag!(p::LateLowerGCFrame, @nospecialize(v::Value))
    addr = emit_tag_ptr!(p, p.T_size, v)
    name = p.dialect.gc_names ? value_name(v) * ".tag" : ""
    load = load!(p.builder, p.T_size, addr, name; align=pointer_align(p),
                 ordering=LLVM.API.LLVMAtomicOrderingUnordered,
                 volatile=p.dialect.gc_tag_load_volatile)
    load.metadata[LLVM.MD_tbaa] = tbaa_tag()
    # the tag is at least 16 (a type), so it is still not null after masking the GC bits
    load.metadata[LLVM.MD_range] = MDNode([i64_metadata_of(p.T_size, TAG_ALIGNMENT),
                                           i64_metadata_of(p.T_size, 0)])
    return load
end

i64_metadata_of(t::LLVMType, x::Integer) = Metadata(ConstantInt(t, x))

# the thread-local state of a task (`get_current_ptls_from_task`)
function current_ptls_from_task!(p::LateLowerGCFrame, @nospecialize(task::Value), tbaa::MDNode)
    builder = p.builder
    offset = runtime_layout(p).task_ptls
    T_ptr = LLVM.PointerType(AS_GENERIC)
    pptls = if p.dialect.gc_ptls_gep === :pointer
        inbounds_gep!(builder, T_ptr, task,
                      [ConstantInt(p.T_size, offset ÷ pointer_size(p))], "ptls_field")
    else
        inbounds_gep!(builder, LLVM.Int8Type(), task,
                      [ConstantInt(LLVM.Int32Type(), offset)], "ptls_field")
    end
    ptls_load = load!(builder, T_ptr, pptls, "ptls_load"; align=pointer_align(p))
    tbaa_decorate!(tbaa, ptls_load)
    return ptls_load
end

# a safepoint (`emit_gc_safepoint`, not final)
emit_gc_safepoint!(p::LateLowerGCFrame, @nospecialize(ptls::Value), tbaa::MDNode) =
    emit_gc_safepoint!(p.builder, p.mod, ptls, p.dialect.gc_safepoint_load,
                       runtime_layout(p).tls_safepoint, pointer_align(p), tbaa)

# the GC stack of the function, created if there is none (Julia 1.12's `getOrAddPGCstack`)
function get_or_add_pgcstack!(p::LateLowerGCFrame)
    fns = p.fns
    entry = first(p.f.blocks)
    if fns.pgcstack_getter !== nothing || fns.adoptthread !== nothing
        for inst in entry.instructions
            inst isa LLVM.CallInst || continue
            callee = inst.called_operand
            (is_fn(fns.pgcstack_getter, callee) || is_fn(fns.adoptthread, callee)) &&
                return inst
        end
    end
    getter = something(fns.pgcstack_getter, get(p.mod.functions, "julia.get_pgcstack", nothing),
                       Some(nothing))
    if getter === nothing
        getter = LLVM.Function(p.mod, "julia.get_pgcstack",
                               LLVM.FunctionType(LLVM.PointerType(AS_GENERIC)))
    end
    position_before!(p.builder, first(entry.instructions); debug=true)
    return call!(p.builder, getter.function_type, getter, Value[])
end

# A call with a `gc-transition` bundle runs with the thread in the GC-safe state: switch
# to it before the call, and back after, with a safepoint at each transition.
function lower_gc_transition!(p::LateLowerGCFrame, call::Instruction, bundle::OperandBundle)
    builder = p.builder
    lowering = p.dialect.gc_transition_lowering
    if lowering === :pgcstack
        pgcstack = get_or_add_pgcstack!(p)
        position_before!(builder, call; debug=true)
        task = inbounds_gep!(builder, LLVM.Int8Type(), pgcstack,
                             [ConstantInt(LLVM.Int32Type(), -runtime_layout(p).task_gcstack)],
                             "current_task")
        ptls = current_ptls_from_task!(p, task, tbaa_gcframe())
    else
        position_before!(builder, call; debug=true)
        ptls = first(LLVM.inputs(bundle))
    end
    offset = runtime_layout(p).tls_gc_state
    # the C++ claims pointer alignment for this byte, which only holds on master's layout
    align = gcd(pointer_align(p), offset)
    T_int8 = LLVM.Int8Type()
    gc_state = inbounds_gep!(builder, T_int8, ptls, [ConstantInt(LLVM.Int32Type(), offset)],
                             "gc_state")
    last_gc_state = load!(builder, T_int8, gc_state; align,
                          ordering=LLVM.API.LLVMAtomicOrderingMonotonic)
    store!(builder, ConstantInt(T_int8, JL_GC_STATE_SAFE), gc_state; align,
           ordering=LLVM.API.LLVMAtomicOrderingRelease)
    tbaa = tbaa_const()
    emit_gc_safepoint!(p, ptls, tbaa)
    next = call.next
    position_before!(builder, next; debug=true)
    store!(builder, last_gc_state, gc_state; align,
           ordering=LLVM.API.LLVMAtomicOrderingRelease)
    emit_gc_safepoint!(p, ptls, tbaa)
end

function update_ptr_numbering!(S::Union{Nothing,State}, @nospecialize(from::Value),
                               @nospecialize(to))
    S === nothing && return
    num = get(S.all_ptr_numbering, vref(from), nothing)
    num === nothing && return
    delete!(S.all_ptr_numbering, vref(from))
    to === nothing || (S.all_ptr_numbering[vref(to)] = num)
    return
end

function replace_call!(@nospecialize(new::Value), call::Instruction, S)
    new isa Instruction && take_name!(new, call)
    replace_uses!(call, new)
    update_ptr_numbering!(S, call, new)
end

# `julia.gc_alloc_obj(task, size, tag)` => `julia.gc_alloc_bytes(ptls, size[, tag])`, and
# a store of the tag to the object's header
# the operand bundles of a call that are not Julia's, which the lowerings keep (a
# deviation, see the docs)
other_bundles(call::Instruction) =
    OperandBundle[b for b in call.operand_bundles if !(LLVM.tag(b) in JULIA_BUNDLES)]

function lower_alloc_obj!(p::LateLowerGCFrame, call::Instruction, S)
    builder = p.builder
    position_before!(builder, call; debug=true)
    T_size = p.T_size

    new_call = nothing
    if !p.dialect.gc_alloc_bytes_tag
        alloc_bytes = get_or_declare(p, :gc_alloc_bytes)
        ptls = current_ptls_from_task!(p, call.arguments[1], tbaa_gcframe())
        size = intcast!(builder, call.arguments[2], T_size)
        new_call = call!(builder, alloc_bytes.function_type, alloc_bytes, Value[ptls, size],
                         other_bundles(call))
        take_name!(new_call, call)
    end

    # LLVM's alignment and bit checks don't look through address space casts, so strip as
    # many casts as possible from the tag, which is mostly loaded as an integer
    tag = strip_pointer_casts_and_aliases(call.arguments[3])
    if tag isa LLVM.ConstantExpr
        if API.LLVMGetConstOpcode(tag) == API.LLVMIntToPtr
            tag = Value(API.LLVMGetOperand(tag, 0))
        end
    elseif tag isa LLVM.LoadInst
        # Make sure the load is marked as aligned, since LLVM might have removed it. Not
        # valid in general, since the load might not be a type on other paths, but it is
        # for constant globals, which are the important cases.
        task_local = Ref(false)
        if is_load_from_const_gv(p, tag, task_local) && get_load_value_align(tag) < TAG_ALIGNMENT
            tag.metadata[LLVM.MD_align] = MDNode([i64_metadata(TAG_ALIGNMENT)])
        end
    end
    # as a last resort, an alignment assumption
    tag_type = LLVM.value_type(tag)
    if tag_type isa LLVM.PointerType && pointer_alignment(p, tag) < TAG_ALIGNMENT
        emit_alignment_assumption!(p, tag, TAG_ALIGNMENT)
    end

    if p.dialect.gc_alloc_bytes_tag
        # `julia.gc_alloc_bytes` specializes on the size of the object, and doesn't set
        # its tag
        alloc_bytes = get_or_declare(p, :gc_alloc_bytes)
        ptls = current_ptls_from_task!(p, call.arguments[1], tbaa_gcframe())
        size = intcast!(builder, call.arguments[2], T_size)
        tagint = ptrtoint!(builder, tag, T_size)
        new_call = call!(builder, alloc_bytes.function_type, alloc_bytes,
                         Value[ptls, size, tagint], other_bundles(call))
        copy_function_attributes!(new_call, alloc_bytes)
        deref = return_dereferenceable_bytes(call)
        deref > 0 && push!(new_call.return_attributes, EnumAttribute("dereferenceable", deref))
        reset_region = metadata_by_name(call, "julia.reset_region")
        reset_region === nothing || set_metadata_by_name!(new_call, "julia.reset_region", reset_region)
        take_name!(new_call, call)
    end

    # set the tag in IR, rather than in the allocation function
    store = store!(builder, tag, emit_tag_ptr!(p, tag_type, new_call);
                   align=pointer_align(p), ordering=LLVM.API.LLVMAtomicOrderingUnordered)
    store.metadata[LLVM.MD_tbaa] = tbaa_tag()

    # null the reference fields, or zero a region (Julia master), so that the GC sees
    # valid pointers before the object is initialized
    bundles = Dict(LLVM.tag(b) => b for b in call.operand_bundles)
    ptr_offsets = get(bundles, "julia.gc_alloc_ptr_offsets", nothing)
    zeroinit = get(bundles, "julia.gc_alloc_zeroinit", nothing)
    T_derived = LLVM.PointerType(AS_DERIVED)
    if ptr_offsets !== nothing
        derived = addrspacecast!(builder, new_call, T_derived)
        for offset in LLVM.inputs(ptr_offsets)
            offset isa LLVM.ConstantInt || continue
            ptr = inbounds_gep!(builder, LLVM.Int8Type(), derived,
                                [ConstantInt(T_size, convert(UInt64, offset))])
            store!(builder, LLVM.null(p.T_prjlvalue), ptr; align=pointer_align(p))
        end
    end
    if zeroinit !== nothing
        offset, size = collect(LLVM.inputs(zeroinit))
        if !(size isa LLVM.ConstantInt && convert(UInt64, size) == 0)
            derived = addrspacecast!(builder, new_call, T_derived)
            ptr = inbounds_gep!(builder, LLVM.Int8Type(), derived, [offset])
            memset!(builder, ptr, ConstantInt(LLVM.Int8Type(), 0), size, pointer_align(p))
        end
    end

    replace_uses!(call, new_call)
    update_ptr_numbering!(S, call, new_call)
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

function return_dereferenceable_bytes(call::Instruction)
    for a in collect(call.return_attributes)
        a isa EnumAttribute && attr_kind(a) == "dereferenceable" && return Int(LLVM.value(a))
    end
    return 0
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

# `Value::getPointerAlignment`, for the values that type tags are
function pointer_alignment(p::LateLowerGCFrame, @nospecialize(v::Value))
    if v isa LLVM.Function
        return 1
    elseif v isa LLVM.GlobalVariable
        align = LLVM.alignment(v)
        align > 0 && return align
        API.LLVMTypeIsSized(LLVM.global_value_type(v)) != 0 || return 1
        if !LLVM.isdeclaration(v)
            return Int(API.LLVMPreferredAlignmentOfGlobal(p.dl, v))
        end
        return abi_alignment(p.dl, LLVM.global_value_type(v))
    elseif v isa LLVM.AllocaInst
        return LLVM.alignment(v)
    elseif v isa LLVM.CallBase
        for a in collect(v.return_attributes)
            a isa EnumAttribute && attr_kind(a) == "align" && return Int(LLVM.value(a))
        end
        callee = called_function(v)
        if callee !== nothing
            for a in collect(callee.return_attributes)
                a isa EnumAttribute && attr_kind(a) == "align" && return Int(LLVM.value(a))
            end
        end
        return 1
    elseif v isa LLVM.LoadInst
        md = v.metadata
        haskey(md, LLVM.MD_align) && return get_load_value_align(v)
    elseif v isa LLVM.Argument
        f = LLVM.parent(v)
        for a in collect(f.parameter_attributes[argument_index(v)])
            a isa EnumAttribute && attr_kind(a) == "align" && return Int(LLVM.value(a))
        end
        return 1
    elseif v isa LLVM.Constant
        # constant addresses: their trailing zeros, up to LLVM's maximum alignment
        c = strip_pointer_casts(v)
        # LLVM 22 and later only look at integer constants cast to pointers
        addr = if API.LLVMIsAConstantPointerNull(c) != C_NULL &&
                  library_facts(context(c)).null_pointer_alignment
            UInt64(0)
        elseif c isa LLVM.ConstantExpr && API.LLVMGetConstOpcode(c) == API.LLVMIntToPtr &&
               Value(API.LLVMGetOperand(c, 0)) isa LLVM.ConstantInt
            convert(UInt64, Value(API.LLVMGetOperand(c, 0)))
        else
            return 1
        end
        return 1 << min(trailing_zeros(addr), 32)
    end
    return 1
end

# `IRBuilder::CreateAlignmentAssumption`
function emit_alignment_assumption!(p::LateLowerGCFrame, @nospecialize(ptr::Value), align::Int)
    assume = Intrinsic("llvm.assume")
    f = LLVM.Function(p.mod, assume)
    T_intptr = LLVM.IntType(8 * storage_size(p.dl, LLVM.value_type(ptr)))
    bundle = OperandBundle("align", Value[ptr, ConstantInt(T_intptr, align)])
    call!(p.builder, f.function_type, f, Value[ConstantInt(LLVM.Int1Type(), 1)],
          [bundle])
end

# `julia.typeof(obj)` => the type tag without the GC bits
function lower_typeof!(p::LateLowerGCFrame, call::Instruction, S)
    builder = p.builder
    position_before!(builder, call; debug=true)
    tag = emit_load_tag!(p, call.arguments[1])
    masked = and!(builder, tag, ConstantInt(p.T_size, ~UInt64(15) & typemax_of(p.T_size)))
    typ = addrspacecast!(builder, inttoptr!(builder, masked, LLVM.PointerType(AS_GENERIC)),
                         p.T_prjlvalue)
    replace_call!(typ, call, S)
end

typemax_of(t::LLVMType) = LLVM.width(t) >= 64 ? typemax(UInt64) : (UInt64(1) << LLVM.width(t)) - 1

# `julia.blackbox(ptr)` => `asm "=r,0"` on the untracked pointer
function lower_blackbox!(p::LateLowerGCFrame, call::Instruction, S)
    builder = p.builder
    position_before!(builder, call; debug=true)
    T_raw = LLVM.PointerType(AS_GENERIC)
    raw = addrspacecast!(builder, call.arguments[1], T_raw)
    ft = LLVM.FunctionType(T_raw, [T_raw])
    asm = InlineAsm(ft, "", "=r,0", false)
    result = call!(builder, ft, asm, Value[raw])
    out = addrspacecast!(builder, result, call.value_type)
    replace_call!(out, call, S)
end

# `julia.call(fptr, f, args...)` => `fptr(f, frame, nargs)`, with the arguments stored
# in the frame; `julia.call2(fptr, arg1, f, args...)` => `fptr(f, frame, nargs, arg1)`;
# `julia.call3` like `julia.call`, with a derived function pointer
function lower_jlcall!(p::LateLowerGCFrame, call::Instruction, kind::Symbol,
                       frame::Instruction, S)
    builder = p.builder
    args = collect(call.arguments)
    new_callee = args[1]
    nfixed = kind === :call2 ? 2 : 1
    replacement_args = Value[args[2:1+nfixed]...]
    frame_values = args[2+nfixed:end]
    position_before!(builder, call; debug=true)
    for (slot, val) in enumerate(frame_values)
        ptr = inbounds_gep!(builder, p.T_prjlvalue, frame,
                            [ConstantInt(LLVM.Int32Type(), slot - 1)])
        store!(builder, val, ptr; align=pointer_align(p))
    end
    T_ptr = LLVM.PointerType(AS_GENERIC)
    push!(replacement_args, isempty(frame_values) ? LLVM.null(T_ptr) :
                                                    addrspacecast!(builder, frame, T_ptr))
    push!(replacement_args, ConstantInt(LLVM.Int32Type(), length(frame_values)))
    if kind === :call2
        # move the trailing argument to the end
        push!(replacement_args, popfirst!(replacement_args))
    end
    T_int32 = LLVM.Int32Type()
    ft = if kind === :call3
        LLVM.FunctionType(p.T_prjlvalue, [LLVM.PointerType(AS_DERIVED), T_ptr, T_int32])
    elseif kind === :call2
        LLVM.FunctionType(p.T_prjlvalue, [p.T_prjlvalue, T_ptr, T_int32, p.T_prjlvalue])
    else
        LLVM.FunctionType(p.T_prjlvalue, [p.T_prjlvalue, T_ptr, T_int32])
    end
    builder.debug_location = nothing
    # Julia's bundles are dropped
    bundles = other_bundles(call)
    new_call = call!(builder, ft, new_callee, replacement_args, bundles)
    new_call.tailcall_kind = call.tailcall_kind
    # the function and return attributes of the call, merged with all attributes of the
    # jlcall declaration
    decl = called_function(call)
    for attr in collect(call.function_attributes)
        push!(new_call.function_attributes, attr)
    end
    for attr in collect(call.return_attributes)
        push!(new_call.return_attributes, attr)
    end
    if decl !== nothing
        for attr in collect(decl.function_attributes)
            push!(new_call.function_attributes, attr)
        end
        for attr in collect(decl.return_attributes)
            push!(new_call.return_attributes, attr)
        end
        for i in 1:min(length(decl.parameter_attributes), length(replacement_args)),
            attr in collect(decl.parameter_attributes[i])
            push!(new_call.argument_attributes[i], attr)
        end
    end
    take_name!(new_call, call)
    copy_metadata!(new_call, call)
    replace_uses!(call, new_call)
    update_ptr_numbering!(S, call, new_call)
    return length(frame_values)
end

# `julia.gc_alloc_zeroinit_indirect(offset, size)` (Julia master, on
# `jl_alloc_genericmemory_unchecked`): zero `size` bytes at the data pointer stored at
# `offset` in the new object, after the call
function zeroinit_indirect!(p::LateLowerGCFrame, call::Instruction, bundle::OperandBundle)
    offset, size = collect(LLVM.inputs(bundle))
    size isa LLVM.ConstantInt && convert(UInt64, size) == 0 && return false
    builder = p.builder
    position!(builder, LLVM.after(call))
    builder.debug_location = call.debug_location
    derived = addrspacecast!(builder, call, LLVM.PointerType(AS_DERIVED))
    field = inbounds_gep!(builder, LLVM.Int8Type(), derived, [offset])
    T_ptr = LLVM.PointerType(AS_GENERIC)
    data = load!(builder, T_ptr, field; align=pointer_align(p))
    memset!(builder, data, ConstantInt(LLVM.Int8Type(), 0), size, pointer_align(p))
    return true
end

# operand bundles that only Julia's GC lowering understands
const JULIA_BUNDLES = ("jl_roots", "gc-transition", "julia.gc_alloc_zeroinit_indirect",
                       "julia.gc_alloc_ptr_offsets", "julia.gc_alloc_zeroinit")

function cleanup_call!(p::LateLowerGCFrame, call::Instruction, S, frame::Instruction,
                       maxframeargs::Ref{Int})
    fns = p.fns
    callee = call.called_operand
    if is_fn(fns.gcroot_flush, callee) || is_fn(fns.gc_preserve_begin, callee) ||
       is_fn(fns.gc_preserve_end, callee)
        # no replacement
    elseif is_fn(fns.pointer_from_objref, callee)
        position_before!(p.builder, call; debug=false)
        replace_call!(new_addrspacecast!(p.builder, call.arguments[1], call.value_type), call, S)
    elseif is_fn(fns.gc_loaded, callee)
        position_before!(p.builder, call; debug=false)
        replace_call!(new_addrspacecast!(p.builder, call.arguments[2], call.value_type), call, S)
    elseif is_fn(fns.blackbox, callee)
        lower_blackbox!(p, call, S)
    elseif is_fn(fns.alloc_obj, callee)
        lower_alloc_obj!(p, call, S)
    elseif is_fn(fns.typeof, callee)
        lower_typeof!(p, call, S)
    elseif is_fn(fns.call, callee) || is_fn(fns.call2, callee) || is_fn(fns.call3, callee)
        kind = is_fn(fns.call, callee) ? :call : is_fn(fns.call2, callee) ? :call2 : :call3
        nargs = lower_jlcall!(p, call, kind, frame, S)
        maxframeargs[] = max(maxframeargs[], nargs)
    else
        bundles = collect(call.operand_bundles)
        for bundle in bundles
            if LLVM.tag(bundle) == "julia.gc_alloc_zeroinit_indirect"
                zeroinit_indirect!(p, call, bundle)
            end
        end
        transition = findfirst(b -> LLVM.tag(b) == "gc-transition", bundles)
        if transition !== nothing && p.dialect.gc_transition_lowering !== :none
            lower_gc_transition!(p, call, bundles[transition])
        end
        # Remove Julia's operand bundles; other ones are kept (a deviation, see the docs).
        # The C++ recreates every call it gets here, which only shows in the numbers that
        # LLVM appends to clashing names, since the new call is created with the name of
        # the old one.
        kept = OperandBundle[b for b in bundles if !(LLVM.tag(b) in JULIA_BUNDLES)]
        new_call = clone_call!(p.builder, call, kept; name=LLVM.name(call))
        take_name!(new_call, call)
        copy_metadata!(new_call, call)
        replace_uses!(call, new_call)
        update_ptr_numbering!(S, call, new_call)
    end
    if !isempty(call.uses)
        replace_uses!(call, UndefValue(call.value_type))
        update_ptr_numbering!(S, call, nothing)
    end
    return true
end

# returns the instruction to visit next: the one after `inst` once it is lowered, which
# may be one that the lowering inserted (and that is cleaned up too, as in the C++)
function cleanup_instruction!(p::LateLowerGCFrame, inst::Instruction, S, frame::Instruction,
                              maxframeargs::Ref{Int}, write_barriers::Vector{Instruction})
    # Strip constant alias information, as it might depend on the GC having preserved a
    # root, which stops being true after this pass (JuliaLang/julia#32215).
    if inst isa LLVM.LoadInst && haskey(inst.metadata, LLVM.MD_invariant_load) &&
       is_special_ptr(typeref(inst.operands[1]))
        delete!(inst.metadata, LLVM.MD_invariant_load)
    end
    md = inst.metadata
    tag = haskey(md, LLVM.MD_tbaa) ? md[LLVM.MD_tbaa] : nothing
    if tag isa MDNode && length(tag.operands) == 4 &&
       tbaa_derives_from(tag, p.dialect.tbaa_downgrade)
        mutable = mutable_tbaa_tag(tag)
        mutable != tag && (inst.metadata[LLVM.MD_tbaa] = mutable)
    end
    # FCA chains created by SROA start with an undef value; with tracked pointers that
    # can lead to partial initialization, and this pass might have extracted an undef
    # field: start them with zeroinitializer
    if inst isa LLVM.InsertValueInst && is_undef(inst.operands[1])
        inst.operands[1] = LLVM.null(inst.value_type)
    end
    inst isa LLVM.CallInst || return inst.next
    if is_write_barrier(p.fns, inst.called_operand)
        push!(write_barriers, inst)
        return inst.next
    end
    cleanup_call!(p, inst, S, frame, maxframeargs) || return inst.next
    next = inst.next
    erase!(inst)
    return next
end

function is_perm_rooted(S, @nospecialize(v::Value))
    v isa LLVM.Constant && return true
    S === nothing && return false
    num = get(S.all_ptr_numbering, vref(v), nothing)
    num === nothing && return false
    refined = get(S.refinements, num, nothing)
    (refined === nothing || isempty(refined)) && return false
    return length(refined) == 1 && refined[1] == -2
end

# the children of a write barrier: the arguments after the parent, without the slot
# operands of field barriers
function write_barrier_children(p::LateLowerGCFrame, call::Instruction)
    args = collect(call.arguments)
    field = is_field_write_barrier(p.fns, call.called_operand)
    return [args[i] for i in 2:length(args) if !field || iseven(i - 1)]
end

function module_debug_level(mod::LLVM.Module)
    flags = mod.flags
    haskey(flags, "julia.debug_level") || return 1
    return convert(Int, Value(flags["julia.debug_level"]))
end

function cleanup_write_barriers!(p::LateLowerGCFrame, S, write_barriers::Vector{Instruction})
    lowering = p.dialect.gc_barrier_lowering
    snapshot = p.dialect.gc_barrier in (:snapshot, :snapshot_field_precise)
    debug_info = lowering === :debug_named ? module_debug_level(p.mod) : 1
    builder = p.builder
    T_size = p.T_size
    for ci in write_barriers
        parent = ci.arguments[1]
        # the insertion-barrier optimization, invalid for snapshot barriers (master)
        if !(lowering === :deferred && snapshot) &&
           all(child -> vref(child) == vref(parent) || is_perm_rooted(S, child),
               write_barrier_children(p, ci))
            erase!(ci)
            continue
        end
        # lowered by FinalLowerGC on Julia master
        lowering === :deferred && continue
        p.cfg_modified = true

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
        for child in collect(ci.arguments)[2:end]
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
        trig_term = split_block_and_insert_if_then!(should_trigger, may_trig_term)
        may_trig_block.terminator.metadata[LLVM.MD_prof] =
            MDNode([MDString("branch_weights"), Metadata(ConstantInt(LLVM.Int32Type(), 1)),
                    Metadata(ConstantInt(LLVM.Int32Type(), 9))])
        trig_block = trig_term.parent
        named && (trig_block.name = "trigger_wb")
        set_name!(trig_block, "trigger_wb")
        position_before!(builder, trig_term; debug=true)
        call_intrinsic!(p, :queue_gc_root, Value[parent])
        erase!(ci)
    end
end

function cleanup_ir!(p::LateLowerGCFrame, S::Union{Nothing,State})
    f = p.f
    entry = first(f.blocks)
    # one array for the arguments of every jlcall, since LLVM would merge them anyway
    position_before!(p.builder, first(entry.instructions); debug=false)
    frame = array_alloca!(p.builder, p.T_prjlvalue, ConstantInt(LLVM.Int32Type(), 0),
                          p.dialect.gc_names ? "jlcallframe" : "")
    maxframeargs = Ref(0)
    write_barriers = Instruction[]
    for bb in collect(f.blocks)
        inst = first(bb.instructions)
        while inst !== nothing
            inst = cleanup_instruction!(p, inst, S, frame, maxframeargs, write_barriers)
        end
    end
    cleanup_write_barriers!(p, S, write_barriers)
    if maxframeargs[] == 0
        erase!(frame)
    else
        frame.operands[1] = ConstantInt(LLVM.Int32Type(), maxframeargs[])
    end
end


## the pass

# the attributes that restrict the memory a call or function accesses: `memory`, or the
# ones it replaced in LLVM 16
function drop_memory_effects!(attrs)
    if LLVM.version() >= v"16"
        delete!(attrs, :memory)
    else
        for kind in (:readnone, :readonly, :writeonly, :argmemonly, :inaccessiblememonly,
                     :inaccessiblemem_or_argmemonly)
            delete!(attrs, kind)
        end
    end
end

has_gcstack_attribute(attrs) =
    any(a -> a isa StringAttribute && attr_kind(a) == "gcstack", collect(attrs))

# Drop the optimistic memory effects that codegen puts on calls marked `julia.safepoint`:
# they were only valid while the GC frame was implicit, and would let DSE or GVN remove
# or forward the frame stores (Julia master). LLVM intersects a call's effects with its
# callee's, so the callee's are dropped too (Julia master only drops the call's).
function drop_safepoint_memory_effects!(f::LLVM.Function)
    for bb in f.blocks, inst in bb.instructions
        inst isa LLVM.CallInst || continue
        call_has_fn_attr(inst, "julia.safepoint", true) || continue
        drop_memory_effects!(inst.function_attributes)
        callee = called_function(inst)
        callee === nothing || drop_memory_effects!(callee.function_attributes)
        for i in 1:length(inst.arguments)
            has_gcstack_attribute(inst.argument_attributes[i]) || continue
            delete!(inst.argument_attributes[i], :readnone)
            if callee !== nothing && i <= length(callee.parameters)
                delete!(callee.parameter_attributes[i], :readnone)
            end
        end
    end
end

# The general pass, or (`declare_small_alloc=false`) the cleanup that
# `jl-late-gc-cleanup` runs on functions it has validated.
function late_lower_gc_frame!(f::LLVM.Function, am, opts::PassOptions;
                              declare_small_alloc::Bool=opts.dialect.gc_declare_small_alloc)
    dialect = opts.dialect
    # thunks are not lowered (Julia master; adopted for every dialect)
    has_string_attribute(f.function_attributes, "thunk") &&
        return PreservedAnalyses(AllAnalyses)
    mod = LLVM.parent(f)
    @dispose builder=IRBuilder() begin
        dl = mod.datalayout
        p = LateLowerGCFrame(dialect, opts, mod, f, am, GCFunctions(mod, dialect), builder, dl,
                             LLVM.PointerType(AS_TRACKED),
                             LLVM.IntType(8 * storage_size(dl, LLVM.PointerType(AS_GENERIC))),
                             nothing, nothing, nothing, false)
        declare_small_alloc && get_or_declare(p, :gc_small_alloc)
        p.pgcstack = get_pgcstack(p, f)
        if p.pgcstack !== nothing
            drop_safepoint_memory_effects!(f)
            S = local_scan(p, f)
            # without a safepoint after the first def, no roots are needed (Julia 1.13)
            needs_frame = !dialect.gc_frame_elision ||
                any(f.blocks) do bb
                    BBS = bb_state(S, bb)
                    bb == first(f.blocks) ? BBS.first_safepoint_after_first_def != -1 :
                                            BBS.has_safepoint
                end
            if needs_frame
                compute_liveness!(p, S)
                colors, pre_assigned = color_roots(S)
                place_roots_and_update_calls!(p, colors, pre_assigned, S)
            end
            cleanup_ir!(p, S)
        else
            cleanup_ir!(p, nothing)
        end
        return p.cfg_modified ? PreservedAnalyses() : PreservedAnalyses(CFGAnalyses)
    end
end

# the runtime facts that the lowering of allocations and GC state transitions needs
const GC_RUNTIME_FACTS = (:task_gcstack, :task_ptls, :tls_safepoint, :tls_gc_state)

const LATE_LOWER_GC_FRAME = define_pass("jl-late-lower-gc-frame", :function,
                                        (f, am, opts) -> late_lower_gc_frame!(f, am, opts);
                                        required=true,
                                        extra=runtime_options(GC_RUNTIME_FACTS...),
                                        cpp_name="LateLowerGCFrame")

"""
    JuliaIR.LateLowerGCFramePass(; gc_barrier=:stock, task_gcstack=0, task_ptls=0,
                                 tls_safepoint=0, tls_gc_state=0)

Julia's GC root placement (`jl-late-lower-gc-frame` in a pipeline, `LateLowerGCFrame`
in Julia's pipelines): roots the values in Julia's tracked address spaces that are live
at a safepoint in a GC frame, and lowers Julia's GC intrinsics, allocations, write
barriers and operand bundles for its runtime. See the documentation for what it does on
each Julia version.

Lowering allocations and GC state transitions needs the layout of the runtime's task and
thread-local state, which is taken from the running Julia (see
[`JuliaIR.runtime_layout`](@ref)) only for functions that need it. The other keyword
arguments give these offsets explicitly.
"""
LateLowerGCFramePass(; kwargs...) = custom_pass(LATE_LOWER_GC_FRAME; kwargs...)
