# PropagateJuliaAddrspaces: make memory operations through Julia's special address spaces
# (10 to 13) use the untracked pointer they were derived from, when that pointer can be
# recovered by looking through address space casts, GEPs, phis and selects. This is
# legal by Julia's definition of those address spaces but not by LLVM's semantics, and
# removes casts that inhibit LLVM's optimizations. Port of Julia's
# `src/llvm-propagate-addrspaces.cpp` (1.14) for every dialect: chains are lifted into
# the common address space of their leaves (JuliaLang/julia#62807; Julia 1.13 and older
# use the alloca address space, which is wrong for leaves elsewhere, e.g. constant
# globals on GPUs), and constant data's use lists are not walked.

struct PropagateAddrspaces
    mod::LLVM.Module
    builder::IRBuilder
    alloca_as::Int
    # lifted versions of the GEPs, phis and selects of the chains lifted so far
    lifting::Dict{Value,Value}
    # values that can't be lifted: users of leaves in a special address space
    visited::Set{Value}
    # a non-constant value of every address space lifted into, which new instructions
    # use until their operands are lifted (so that IRBuilder does not fold them)
    placeholders::Dict{Int,Instruction}
    # memory intrinsic calls that were replaced, erased at the end so that `visited` and
    # `lifting` don't refer to freed values
    replaced::Vector{Instruction}
end

function strip_lifting_casts(p::PropagateAddrspaces, @nospecialize(v::Value))
    while !haskey(p.lifting, v) && (v isa LLVM.BitCastInst || v isa LLVM.AddrSpaceCastInst)
        v = v.operands[1]
    end
    return v
end

function poison_users!(p::PropagateAddrspaces, worklist::Vector{Value})
    while !isempty(worklist)
        v = pop!(worklist)
        # constant data is uniqued per context, and its users span unrelated functions
        (v isa LLVM.ConstantData || v isa LLVM.ConstantDataSequential) && continue
        for use in v.uses
            user = use.user
            user in p.visited && continue
            push!(p.visited, user)
            push!(worklist, user)
        end
    end
end

# the pointer `v` (in a special address space) lifted into the address space of the
# leaves of its chain of casts, GEPs, phis and selects, or `nothing`
function lift_pointer!(p::PropagateAddrspaces, f::LLVM.Function, @nospecialize(v::Value))
    stack = Instruction[]
    worklist = Value[v]
    local_visited = Set{Value}()
    # every leaf other than null must be in the same address space
    lift_as = -1
    function merge_leaf(@nospecialize(leaf::Value))
        leaf = strip_lifting_casts(p, leaf)
        leaf isa LLVM.PointerNull && return true
        leaf = get(p.lifting, leaf, leaf)
        as = pointer_addrspace(leaf)
        is_special_addrspace(as) && return false
        lift_as == -1 && (lift_as = as)
        return lift_as == as
    end

    while !isempty(worklist)
        cur = pop!(worklist)
        cur in local_visited && continue
        while true
            if cur isa LLVM.BitCastInst
                cur = cur.operands[1]
            elseif cur isa LLVM.AddrSpaceCastInst
                cast = cur
                cur = cast.operands[1]
                if !is_special_addrspace(pointer_addrspace(cast))
                    merge_leaf(cur) || return nothing
                    break
                end
            elseif cur isa LLVM.GetElementPtrInst || cur isa LLVM.SelectInst
                if haskey(p.lifting, cur)
                    merge_leaf(cur) || return nothing
                    break
                elseif cur in p.visited
                    return nothing
                end
                push!(stack, cur)
                push!(local_visited, cur)
                if cur isa LLVM.SelectInst
                    # one arm later, the other one now
                    push!(worklist, cur.operands[3])
                    cur = cur.operands[2]
                else
                    cur = cur.operands[1]
                end
            elseif cur isa LLVM.PHIInst
                if haskey(p.lifting, cur)
                    merge_leaf(cur) || return nothing
                    break
                end
                for (val, _) in cur.incoming
                    push!(worklist, val)
                end
                push!(stack, cur)
                push!(local_visited, cur)
                break
            elseif cur isa LLVM.PointerNull
                # null can be lifted into any address space
                break
            else
                # a leaf
                if !is_pointer_like(cur) || is_special_addrspace(pointer_addrspace(cur))
                    # don't look at its (recursive) users again
                    empty!(worklist)
                    push!(worklist, cur)
                    push!(p.visited, cur)
                    poison_users!(p, worklist)
                    return nothing
                end
                merge_leaf(cur) || return nothing
                break
            end
        end
    end
    # without leaves other than null, use the alloca address space
    lift_as == -1 && (lift_as = p.alloca_as)
    target = LLVM.PointerType(lift_as)

    # create the lifted instructions, then set their operands
    revisit = Tuple{Instruction,Instruction}[]
    for inst in stack
        haskey(p.lifting, inst) && continue
        new = lifted_clone!(p, f, inst, target, lift_as)
        p.lifting[inst] = new
        push!(revisit, (inst, new))
    end
    function collapse(@nospecialize(cur::Value))
        cur = strip_lifting_casts(p, cur)
        cur isa LLVM.PointerNull && return LLVM.PointerNull(target)
        cur = get(p.lifting, cur, cur)
        cur.value_type == target ||
            error("PropagateJuliaAddrspaces: lifted $(string(cur)) is not in address space $lift_as")
        return cur
    end
    for (orig, new) in revisit
        if orig isa LLVM.GetElementPtrInst
            new.operands[1] = collapse(orig.operands[1])
        elseif orig isa LLVM.PHIInst
            append!(new.incoming, [(collapse(val), bb) for (val, bb) in orig.incoming])
        else
            ops = new.operands
            orig_ops = orig.operands
            ops[2] = collapse(orig_ops[2])
            ops[3] = collapse(orig_ops[3])
        end
    end
    return collapse(v)
end

# a copy of a GEP, phi or select that returns a pointer in address space `as`, without
# its pointer operands (they are set after all instructions of a chain are created), like
# C++'s `clone()` + `mutateType`: unnamed, with the flags and metadata of the original
function lifted_clone!(p::PropagateAddrspaces, f::LLVM.Function, inst::Instruction,
                       target::LLVMType, as::Int)
    builder = p.builder
    tmp = get!(p.placeholders, as) do
        position!(builder, LLVM.before(first(first(f.blocks).instructions)))
        phi!(builder, target)
    end
    position!(builder, LLVM.before(inst))
    new = if inst isa LLVM.GetElementPtrInst
        gep = gep!(builder, inst.source_element_type, tmp, collect(inst.indices))
        gep.inbounds = inst.inbounds
        if LLVM.version() >= v"19"
            gep.nusw = inst.nusw
            gep.nuw = inst.nuw
        end
        gep
    elseif inst isa LLVM.PHIInst
        phi!(builder, target)
    else
        select!(builder, inst.operands[1], tmp, tmp)
    end::Instruction
    copy_metadata!(new, inst)
    return new
end

function visit_memop!(p::PropagateAddrspaces, f::LLVM.Function, inst::Instruction, idx::Int)
    orig = inst.operands[idx]
    is_special_addrspace(pointer_addrspace(orig)) || return
    new = lift_pointer!(p, f, orig)
    new === nothing && return
    inst.operands[idx] = new
    return
end

function visit_memintrinsic!(p::PropagateAddrspaces, f::LLVM.Function, call::Instruction,
                             intr::LLVM.Intrinsic, transfer::Bool)
    args = collect(call.arguments)
    dest, src = args[1], transfer ? args[2] : nothing
    special_dest = is_special_addrspace(pointer_addrspace(dest))
    special_src = transfer && is_special_addrspace(pointer_addrspace(src))
    (special_dest || special_src) || return
    if special_dest
        new = lift_pointer!(p, f, dest)
        new === nothing || (args[1] = new)
    end
    if special_src
        new = lift_pointer!(p, f, src)
        new === nothing || (args[2] = new)
    end
    args[1] == dest && (!transfer || args[2] == src) && return

    # the overload of the intrinsic for the new pointers. Unlike the C++ pass, keep
    # `llvm.memset.inline` (C++ turns it into `llvm.memset`), and overload memset on the
    # length's type (C++ uses the type of the value operand, which gives a declaration
    # that doesn't match the call).
    overloads = transfer ?
        LLVMType[args[1].value_type, args[2].value_type, args[3].value_type] :
        LLVMType[args[1].value_type, args[3].value_type]
    fn = LLVM.Function(p.mod, intr, overloads)
    position!(p.builder, LLVM.before(call))
    new_call = call!(p.builder, fn.function_type, fn, args, collect(call.operand_bundles))
    new_call.tailcall_kind = call.tailcall_kind
    new_call.callconv = call.callconv
    for attr in collect(call.function_attributes)
        push!(new_call.function_attributes, attr)
    end
    for attr in collect(call.return_attributes)
        push!(new_call.return_attributes, attr)
    end
    for i in 1:length(args), attr in collect(call.argument_attributes[i])
        push!(new_call.argument_attributes[i], attr)
    end
    copy_metadata!(new_call, call)
    push!(p.replaced, call)
    return
end

function propagate_addrspaces!(f::LLVM.Function, am, opts::PassOptions)
    mod = f.parent
    memsets = (Intrinsic("llvm.memset"), Intrinsic("llvm.memset.inline"))
    memtransfers = (Intrinsic("llvm.memcpy"), Intrinsic("llvm.memcpy.inline"),
                    Intrinsic("llvm.memmove"))
    @dispose builder=IRBuilder() begin
        p = PropagateAddrspaces(mod, builder, alloca_addrspace(mod), Dict{Value,Value}(),
                                Set{Value}(), Dict{Int,Instruction}(), Instruction[])
        for bb in f.blocks, inst in bb.instructions
            if inst isa LLVM.LoadInst || inst isa LLVM.StoreInst
                visit_memop!(p, f, inst, inst isa LLVM.LoadInst ? 1 : 2)
            elseif inst isa LLVM.AtomicCmpXchgInst || inst isa LLVM.AtomicRMWInst
                visit_memop!(p, f, inst, 1)
            elseif inst isa LLVM.CallInst
                callee = inst.called_function
                (callee isa LLVM.Function && LLVM.isintrinsic(callee)) || continue
                intr = callee.intrinsic
                if intr in memsets
                    visit_memintrinsic!(p, f, inst, intr, false)
                elseif intr in memtransfers
                    visit_memintrinsic!(p, f, inst, intr, true)
                end
            end
        end
        foreach(erase!, p.replaced)
        foreach(erase!, values(p.placeholders))
    end
    # like the C++ pass, always report a change
    return PreservedAnalyses(CFGAnalyses)
end

const PROPAGATE_ADDRSPACES = define_pass("jl-propagate-addrspaces", :function,
                                         propagate_addrspaces!; required=true,
                                         cpp_name="PropagateJuliaAddrspaces")

"""
    JuliaIR.PropagateAddrspacesPass()

Make loads, stores, atomics and memory intrinsics that access memory through one of
Julia's special address spaces use the untracked pointer the address was derived from,
when that pointer can be recovered through address space casts, GEPs, phis and selects
(`jl-propagate-addrspaces` in a pipeline). Run `dce` or another cleanup afterwards to
remove the instructions that became unused. Like Julia's C++ pass, it is required, so it
also runs on `optnone` functions.
"""
PropagateAddrspacesPass(; kwargs...) = custom_pass(PROPAGATE_ADDRSPACES; kwargs...)
