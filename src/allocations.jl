# Escape analysis of Julia's GC allocations (`julia.gc_alloc_obj`), used by AllocOpt and
# later JuliaLICM. Port of Julia's `src/llvm-alloc-helpers.cpp` (1.14).

# Julia's address spaces (`src/llvm-codegen-shared.h`), which are the same in every dialect
const AS_GENERIC = 0
const AS_TRACKED = 10
const AS_DERIVED = 11
const AS_CALLEE_ROOTED = 12
const AS_LOADED = 13

# The functions of Julia's dialect that a module declares (`JuliaPassContext` in C++);
# `nothing` for those it doesn't use.
struct JuliaFunctions
    alloc_obj::Union{Nothing,LLVM.Function}
    typeof::Union{Nothing,LLVM.Function}
    gc_preserve_begin::Union{Nothing,LLVM.Function}
    gc_preserve_end::Union{Nothing,LLVM.Function}
    pointer_from_objref::Union{Nothing,LLVM.Function}
    gc_loaded::Union{Nothing,LLVM.Function}
    # all write barriers, and the field barriers among them (whose odd operands are the
    # slots that are written)
    write_barriers::Vector{LLVM.Function}
    field_write_barriers::Vector{LLVM.Function}
end

function JuliaFunctions(mod::LLVM.Module, dialect::Dialect)
    fs = mod.functions
    lookup(name) = get(fs, name, nothing)
    barriers = LLVM.Function[f for f in lookup.(dialect.write_barriers) if f !== nothing]
    field_barriers = filter(f -> startswith(f.name, "julia.field_write_barrier"), barriers)
    return JuliaFunctions(lookup("julia.gc_alloc_obj"), lookup("julia.typeof"),
                          lookup("llvm.julia.gc_preserve_begin"),
                          lookup("llvm.julia.gc_preserve_end"),
                          lookup("julia.pointer_from_objref"),
                          dialect.has_gc_loaded ? lookup("julia.gc_loaded") : nothing,
                          barriers, field_barriers)
end

is_write_barrier(fns::JuliaFunctions, @nospecialize(callee::Value)) =
    any(==(callee), fns.write_barriers)
is_field_write_barrier(fns::JuliaFunctions, @nospecialize(callee::Value)) =
    any(==(callee), fns.field_write_barriers)

# the first operand of a field write barrier that is a slot; the next slots follow every
# other operand
const FIELD_WB_SLOT_ARG = 2

# whether a type contains a tracked pointer
function has_objref(@nospecialize(ty::LLVMType))
    ty isa LLVM.PointerType && return ty.addrspace == AS_TRACKED
    (ty isa LLVM.ArrayType || ty isa LLVM.VectorType) && return has_objref(ty.element_type)
    if ty isa LLVM.StructType
        for elty in ty.elements
            has_objref(elty) && return true
        end
    end
    return false
end

is_aggregate(@nospecialize(ty::LLVMType)) =
    ty isa LLVM.StructType || ty isa LLVM.ArrayType || ty isa LLVM.VectorType

# an access of an allocation, at a constant offset
struct MemOp
    inst::Instruction
    opno::Int  # the (1-based) operand that is the address
    offset::UInt32
    size::UInt32
    isobjref::Bool
    isaggr::Bool
end

# a field of an allocation: a range of bytes that is accessed as a unit
mutable struct Field
    size::UInt32
    hasobjref::Bool
    hasaggr::Bool
    multiloc::Bool
    hasload::Bool
    # there is an unboxed (non-reference) value at this offset
    hasunboxed::Bool
    # the type it is accessed as, or `nothing` if accessed in several ways
    elty::Union{Nothing,LLVMType}
    accesses::Vector{MemOp}
end

Field(size, elty) = Field(size, false, false, false, false, false, elty, MemOp[])

# the bits of an `allockind` attribute (`llvm::AllocFnKind`)
const ALLOCKIND_UNINITIALIZED = UInt64(1) << 3
const ALLOCKIND_ZEROED = UInt64(1) << 4

# What the escape analysis found out about the uses of an allocation.
mutable struct AllocUseInfo
    uses::Set{Instruction}
    # uses in insertion order, for deterministic iteration
    use_order::Vector{Instruction}
    preserves::Vector{Instruction}
    # fields by offset, sorted
    offsets::Vector{UInt32}
    fields::Vector{Field}
    # a completely unknown use
    escaped::Bool
    # the address is leaked to functions that don't care where the object is allocated
    addrescaped::Bool
    # the memory is read
    hasload::Bool
    # there are uses in GC preserve intrinsics or `jl_roots` operand bundles
    haspreserve::Bool
    # reference fields are loaded or stored
    refload::Bool
    refstore::Bool
    # there are `julia.typeof` calls, which can be optimized without removing the allocation
    hastypeof::Bool
    # memory accesses whose offset, size or value cannot be computed; a weaker form of
    # `addrescaped`, since `hasload` still says whether the memory is read
    hasunknownmem::Bool
    # the object is returned
    returned::Bool
    # the object is used by an error function (in a block that ends in `unreachable`)
    haserror::Bool
    # the `allockind` of the allocation (0 if unknown)
    allockind::UInt64
    # references, aggregates containing references, and unboxed values not in a known field
    has_unknown_objref::Bool
    has_unknown_objrefaggr::Bool
    has_unknown_unboxed::Bool
end

AllocUseInfo() = AllocUseInfo(Set{Instruction}(), Instruction[], Instruction[], UInt32[],
                              Field[], false, false, false, false, false, false, false,
                              false, false, false, 0, false, false, false)

function Base.empty!(info::AllocUseInfo)
    empty!(info.uses)
    empty!(info.use_order)
    empty!(info.preserves)
    empty!(info.offsets)
    empty!(info.fields)
    info.escaped = info.addrescaped = info.hasload = info.haspreserve = false
    info.refload = info.refstore = info.hastypeof = info.hasunknownmem = false
    info.returned = info.haserror = false
    info.allockind = 0
    info.has_unknown_objref = info.has_unknown_objrefaggr = info.has_unknown_unboxed = false
    return info
end

# Print what the escape analysis found, like `AllocUseInfo::dump` (for remarks). Uses are
# listed in the order they were found.
function dump_use_info(io::IO, info::AllocUseInfo)
    b(x::Bool) = Int(x)
    println(io, "AllocUseInfo:")
    println(io, "escaped: ", b(info.escaped))
    println(io, "addrescaped: ", b(info.addrescaped))
    println(io, "returned: ", b(info.returned))
    println(io, "haserror: ", b(info.haserror))
    println(io, "hasload: ", b(info.hasload))
    println(io, "haspreserve: ", b(info.haspreserve))
    println(io, "hasunknownmem: ", b(info.hasunknownmem))
    println(io, "hastypeof: ", b(info.hastypeof))
    println(io, "refload: ", b(info.refload))
    println(io, "refstore: ", b(info.refstore))
    print(io, "allockind:")
    info.allockind & ALLOCKIND_UNINITIALIZED != 0 && print(io, " uninitialized")
    info.allockind & ALLOCKIND_ZEROED != 0 && print(io, " zeroed")
    println(io)
    println(io, "Uses: ", length(info.use_order))
    foreach(inst -> println(io, string(inst)), info.use_order)
    if !isempty(info.preserves)
        println(io, "Preserves: ", length(info.preserves))
        foreach(inst -> println(io, string(inst)), info.preserves)
    end
    println(io, "MemOps: ", length(info.fields))
    for (offset, field) in zip(info.offsets, info.fields)
        println(io, "  offset: ", offset)
        println(io, "  size: ", field.size)
        println(io, "  hasobjref: ", b(field.hasobjref))
        println(io, "  hasload: ", b(field.hasload))
        println(io, "  hasaggr: ", b(field.hasaggr))
        println(io, "  accesses: ", length(field.accesses))
        for memop in field.accesses
            println(io, "    ", string(memop.inst))
            println(io, "    ", memop.isaggr ? "aggr" : "scalar")
            println(io, "    ", memop.isobjref ? "objref" : "bits")
            println(io, "    ", memop.offset)
            println(io, "    ", memop.size)
        end
    end
end

function add_use!(info::AllocUseInfo, @nospecialize(inst::Instruction))
    inst in info.uses && return
    push!(info.uses, inst)
    push!(info.use_order, inst)
end

# the field that contains the bytes [offset, offset+size), merging overlapping fields
function get_field!(info::AllocUseInfo, offset::UInt32, size::UInt32,
                    @nospecialize(elty::LLVMType))
    offsets, fields = info.offsets, info.fields
    n = length(offsets)
    # the last field that starts no higher than `offset`
    i = searchsortedlast(offsets, offset)
    lb = ub = 0  # first and last overlapping field
    if i > 0
        field = fields[i]
        # the field contains the location
        if UInt64(offsets[i]) + field.size >= UInt64(offset) + size
            field.elty === nothing || field.elty == elty || (field.elty = nothing)
            return field
        end
        if UInt64(offsets[i]) + field.size > offset
            lb = ub = i
        end
        i += 1
    else
        i = 1
    end
    # the last field that overlaps with the location, and the first one if none above
    while i <= n && UInt64(offsets[i]) < UInt64(offset) + size
        lb == 0 && (lb = i)
        ub = i
        i += 1
    end
    if lb == 0
        field = Field(size, elty)
        j = searchsortedfirst(offsets, offset)
        insert!(offsets, j, offset)
        insert!(fields, j, field)
        return field
    end
    # merge the overlapping fields into one
    new_offset = min(offset, offsets[lb])
    new_end = max(UInt64(offset) + size, UInt64(offsets[ub]) + fields[ub].size)
    field = Field(UInt32(new_end - new_offset), nothing)
    field.multiloc = true
    for j in lb:ub
        old = fields[j]
        field.hasobjref |= old.hasobjref
        field.hasload |= old.hasload
        field.hasaggr |= old.hasaggr
        append!(field.accesses, old.accesses)
    end
    deleteat!(offsets, lb:ub)
    deleteat!(fields, lb:ub)
    insert!(offsets, lb, new_offset)
    insert!(fields, lb, field)
    return field
end

# record a memory access; returns false if its end doesn't fit in 32 bits
function add_memop!(info::AllocUseInfo, inst::Instruction, opno::Int, offset::UInt32,
                    @nospecialize(elty::LLVMType), isload::Bool, isstore::Bool,
                    dl::DataLayout)
    size = storage_size(dl, elty)
    isaggr = is_aggregate(elty)
    isobjref = has_objref(elty)
    field = get_field!(info, offset, UInt32(min(size, typemax(UInt32))), elty)
    field.hasunboxed |= !isobjref || !(elty isa LLVM.PointerType)
    # a field with a mix of references and bits cannot be split
    !isempty(field.accesses) && field.hasobjref != isobjref && (field.multiloc = true)
    isload && (field.hasload = true)
    if isobjref
        isstore && (info.refstore = true)
        isload && (info.refload = true)
        isaggr && (field.hasaggr = true)
        field.hasobjref = true
    elseif isaggr
        field.hasaggr = true
    end
    push!(field.accesses, MemOp(inst, opno, offset, UInt32(min(size, typemax(UInt32))),
                                isobjref, isaggr))
    return size < typemax(UInt32) - offset
end

function unknown_access!(info::AllocUseInfo, @nospecialize(elty::LLVMType))
    objref = has_objref(elty)
    info.has_unknown_objref |= objref
    info.has_unknown_objrefaggr |= objref && !(elty isa LLVM.PointerType)
    info.has_unknown_unboxed |= !objref || !(elty isa LLVM.PointerType)
    info.hasunknownmem = true
end

const UNKNOWN_OFFSET = typemax(UInt32)

is_lifetime(f::LLVM.Function) =
    LLVM.isintrinsic(f, LIFETIME_START) || LLVM.isintrinsic(f, LIFETIME_END)
# lifetime markers and debug intrinsics (`DbgInfoIntrinsic`)
is_lifetime_or_debug(f::LLVM.Function) = is_lifetime(f) || is_debug_intrinsic(f)

# the `allockind` of a call, from its attributes or those of the called function
function alloc_kind(@nospecialize(call::Instruction))::UInt64
    attrs = call.function_attributes
    if haskey(attrs, :allockind)
        return UInt64(attrs[:allockind].value)
    end
    callee = call.called_function
    if callee !== nothing && haskey(callee.function_attributes, :allockind)
        return UInt64(callee.function_attributes[:allockind].value)
    end
    return UInt64(0)
end

# the pass name of the remarks of the escape analysis (`DEBUG_TYPE` in C++)
const ESCAPE_REMARKS = "escape-analysis"

# Find out how the allocation `alloc` (a `julia.gc_alloc_obj` call) is used, recording it
# in `info`, which is emptied first. Uses outside the blocks in `valid_blocks` (if given)
# are ignored. Missed-optimization remarks are emitted through `remarks` (the analysis
# manager of a function pass or the analysis results of a loop pass), if given.
function escape_analysis!(info::AllocUseInfo, alloc::Instruction, fns::JuliaFunctions,
                          dl::DataLayout; valid_blocks=nothing,
                          remarks::R=nothing) where {R}
    empty!(info)
    info.allockind = alloc_kind(alloc)
    # the instructions whose uses are analyzed: (instruction, offset, its uses, the index
    # of the next use), depth first, so the last one is the current one
    stack = Tuple{Instruction,UInt32,Vector{Use},Int}[(alloc, UInt32(0), collect(alloc.uses), 1)]
    push_inst!(@nospecialize(inst), offset) = push!(stack, (inst, offset, collect(inst.uses), 1))
    function escape!(name, inst, message, key)
        if remarks !== nothing
            remark!(remarks, :missed, ESCAPE_REMARKS, name, inst) do
                message, key => string(inst), ")"
            end
        end
        info.escaped = true
        return false
    end

    # analyze a use; returns false if the allocation escapes
    function check(@nospecialize(inst::Instruction), use::Use)
        offset = stack[end][2]
        if inst isa LoadInst
            info.hasload = true
            if offset == UNKNOWN_OFFSET
                unknown_access!(info, inst.value_type)
            elseif !add_memop!(info, inst, use.operand_index, offset, inst.value_type,
                               true, false, dl)
                info.hasunknownmem = true
            end
            return true
        elseif inst isa CallInst
            callee = inst.called_operand
            if callee isa LLVM.Function && LLVM.isintrinsic(callee)
                if LLVM.isintrinsic(callee, MEMSET)
                    len = inst.arguments[3]
                    val = inst.arguments[2]
                    if offset == UNKNOWN_OFFSET || !(len isa ConstantInt) ||
                       !(val isa ConstantInt) ||
                       convert(UInt64, len) >= typemax(UInt32) - offset
                        info.hasunknownmem = true
                    end
                    return true
                end
                is_lifetime_or_debug(callee) && return true
                # intrinsics don't care whether memory is on the stack or the heap
                info.addrescaped = true
                return true
            end
            if callee == fns.gc_preserve_begin
                for user in inst.users
                    add_use!(info, user)
                end
                inst in info.preserves || push!(info.preserves, inst)
                info.haspreserve = true
                return true
            end
            if callee == fns.pointer_from_objref
                info.addrescaped = true
                return true
            end
            if fns.gc_loaded !== nothing && callee == fns.gc_loaded
                push_inst!(inst, offset)
                return true
            end
            if callee == fns.typeof
                info.hastypeof = true
                return true
            end
            is_write_barrier(fns, callee) && return true
            # uses in a `jl_roots` operand bundle don't escape; everything else does
            if !is_bundle_operand(inst, use, "jl_roots")
                if inst.parent.terminator isa UnreachableInst
                    # likely an error function
                    info.haserror = true
                    return true
                end
                return escape!("UnknownCall", inst, "Unknown call, marking escape (", "Call")
            end
            info.haspreserve = true
            return true
        elseif inst isa StoreInst
            # only storing to the object counts, not storing its address
            if use.operand_index != 2
                return escape!("StoreObjAddr", inst, "Object address is stored somewhere, marking escape (",
                               "Store")
            end
            elty = inst.value_operand.value_type
            if offset == UNKNOWN_OFFSET
                unknown_access!(info, elty)
            elseif !add_memop!(info, inst, use.operand_index, offset, elty, false, true, dl)
                info.hasunknownmem = true
            end
            return true
        elseif inst isa AtomicCmpXchgInst || inst isa AtomicRMWInst
            if use.operand_index != 1
                return escape!("StoreObjAddr", inst, "Object address is cmpxchg/rmw-ed somewhere, marking escape (",
                               "Store")
            end
            info.hasload = true
            # the new value of a cmpxchg is its third operand, that of an atomicrmw its second
            elty = (inst isa AtomicCmpXchgInst ? inst.operands[3] : inst.operands[2]).value_type
            # read-modify-write: this both loads and stores the field
            if offset == UNKNOWN_OFFSET ||
               !add_memop!(info, inst, use.operand_index, offset, elty, true, true, dl)
                unknown_access!(info, elty)
            end
            info.refload = true
            return true
        elseif inst isa AddrSpaceCastInst || inst isa BitCastInst
            push_inst!(inst, offset)
            return true
        elseif inst isa GetElementPtrInst
            next = offset
            if offset != UNKNOWN_OFFSET
                gep_offset = LLVM.constant_offset(inst, dl)
                total = gep_offset === nothing ? -1 : offset + gep_offset
                next = 0 <= total <= typemax(UInt32) ? UInt32(total) : UNKNOWN_OFFSET
            end
            push_inst!(inst, next)
            return true
        elseif inst isa RetInst
            info.returned = true
            return true
        end
        return escape!("UnknownInst", inst, "Unknown instruction, marking escape (", "Inst")
    end

    while true
        # drop the instructions whose uses have all been analyzed
        while stack[end][4] > length(stack[end][3])
            pop!(stack)
            isempty(stack) && return info
        end
        inst, offset, uses, i = stack[end]
        stack[end] = (inst, offset, uses, i + 1)
        use = uses[i]
        user = use.user
        if !(user isa Instruction)
            info.escaped = true
            return info
        end
        if valid_blocks === nothing || user.parent in valid_blocks
            check(user, use) || return info
            add_use!(info, user)
        end
    end
end

# whether `use` is an operand of an operand bundle of `call` with the given tag
function is_bundle_operand(call::Instruction, use::Use, tag::String)
    use.argument_index === nothing || return false
    LLVM.iscallee(use) && return false
    i = use.operand_index - length(call.arguments)
    for bundle in call.operand_bundles
        n = length(bundle.inputs)
        if i <= n
            return bundle.tag == tag
        end
        i -= n
    end
    return false
end
