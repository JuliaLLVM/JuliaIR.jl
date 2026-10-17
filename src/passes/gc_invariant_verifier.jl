# GCInvariantVerifier: check the invariants of Julia's GC address spaces that GC root
# placement relies on (Julia's devdocs, "GC root placement"): which casts between the
# address spaces are allowed, that decayed pointers aren't stored, loaded or returned,
# that jlcall arguments are tracked, and (on Julia master) the operands of field write
# barriers. Port of Julia's `src/llvm-gc-invariant-verifier.cpp`. Where the C++ pass
# aborts after printing the violations, the port throws a `GCInvariantError` listing
# them, which `jlopt` turns into an abort.

"""
    JuliaIR.GCInvariantViolation

One violation of a GC invariant found by GCInvariantVerifier: the `message` that says
which invariant, and the offending `instruction`, as text.
"""
struct GCInvariantViolation
    message::String
    instruction::String
end

"""
    JuliaIR.GCInvariantError

The error thrown by GCInvariantVerifier (`jl-gc-invariant-verifier`) when a function
violates GC invariants. `violations` lists every violation found in the function, in
the order of its instructions, as [`JuliaIR.GCInvariantViolation`](@ref)s.
"""
struct GCInvariantError <: Exception
    function_name::String
    violations::Vector{GCInvariantViolation}
end

function Base.showerror(io::IO, err::GCInvariantError)
    print(io, "GCInvariantError: GC invariants are violated in function ", err.function_name)
    # like the C++ pass prints them
    for v in err.violations
        print(io, '\n', v.message, "\n\t", v.instruction)
    end
end

struct GCInvariantVerifier
    dialect::Dialect
    strong::Bool
    violations::Vector{GCInvariantViolation}
end

function check(v::GCInvariantVerifier, cond::Bool, message::String, @nospecialize(val::Value))
    cond || push!(v.violations, GCInvariantViolation(message, string(val)))
    return
end

# whether a type is checked as a pointer: Julia 1.12 and later also check vectors of
# pointers
is_checked_pointer(v::GCInvariantVerifier, @nospecialize(val::Value)) =
    v.dialect.verifier_vector_pointers ? is_pointer_like(val) : is_pointer(val)

function verify_addrspacecast!(v::GCInvariantVerifier, inst::Instruction)
    # the C++ pass of Julia 1.10 and 1.11 assumes scalar pointers here; the address space
    # of vectors of pointers is the one of their elements
    from = pointer_addrspace(inst.operands[1])
    to = pointer_addrspace(inst)
    from == AS_GENERIC && return
    check(v, to != AS_LOADED && from != AS_LOADED,
          "Illegal address space cast involving loaded ptr", inst)
    check(v, from != AS_TRACKED || to == AS_CALLEE_ROOTED || to == AS_DERIVED,
          "Illegal address space cast from tracked ptr", inst)
    check(v, from != AS_CALLEE_ROOTED && from != AS_DERIVED,
          "Illegal address space cast from decayed ptr", inst)
end

function verify_store!(v::GCInvariantVerifier, inst::Instruction,
                       @nospecialize(val::Value), @nospecialize(ptr::Value))
    if is_checked_pointer(v, val)
        # arguments don't obey this, but they are rooted by the caller
        as = pointer_addrspace(val)
        check(v, as != AS_CALLEE_ROOTED && as != AS_DERIVED,
              "Illegal store of decayed value", inst)
    end
    check(v, pointer_addrspace(ptr) != AS_CALLEE_ROOTED,
          "Illegal store to callee rooted value", inst)
end

function verify_load!(v::GCInvariantVerifier, inst::Instruction)
    if is_checked_pointer(v, inst)
        as = pointer_addrspace(inst)
        check(v, as != AS_CALLEE_ROOTED && as != AS_DERIVED,
              "Illegal load of gc relevant value", inst)
    end
    ptr = inst.operands[1]
    if is_checked_pointer(v, ptr)
        check(v, pointer_addrspace(ptr) != AS_CALLEE_ROOTED,
              "Illegal load of callee rooted value", inst)
    end
end

function verify_return!(v::GCInvariantVerifier, inst::Instruction)
    ops = inst.operands
    isempty(ops) && return
    val = ops[1]
    is_checked_pointer(v, val) || return
    as = pointer_addrspace(val)
    check(v, !is_special_addrspace(as) || as == AS_TRACKED,
          "Only gc tracked values may be directly returned", inst)
end

function verify_gep!(v::GCInvariantVerifier, inst::Instruction)
    is_checked_pointer(v, inst) || return
    as = pointer_addrspace(inst)
    is_special_addrspace(as) || return
    # GEPs of tracked pointers are fine as long as they don't feed into uses, and the
    # optimizer introduces them (it doesn't distinguish GEP(cast) from cast(GEP)), but
    # the code generator doesn't, which a strong check right after it can enforce
    v.strong && check(v, as != AS_TRACKED,
                      "GC tracked values may not appear in GEP expressions. You may have to decay the value first",
                      inst)
end

is_pointer_in(@nospecialize(val::Value), as::Int) =
    is_pointer(val) && pointer_addrspace(val) == as

function verify_call!(v::GCInvariantVerifier, inst::Instruction)
    callee = inst.called_function
    callee === nothing && return
    name = callee.name
    dialect = v.dialect
    if dialect.barrier_flavour === :object_field
        if dialect.gc_barrier in (:field_precise, :snapshot_field_precise)
            # code generation doesn't emit whole-object barriers in this configuration
            check(v, name != "julia.object_write_barrier",
                  "Object write barrier is not permitted with field-precise barriers", inst)
        end
        # the barriers are variadic, so LLVM doesn't check the types of their operands
        if startswith(name, "julia.field_write_barrier.")
            derived = name == "julia.field_write_barrier.p11"
            check(v, derived || name == "julia.field_write_barrier.p13",
                  "Unknown field write barrier address space", inst)
            args = collect(inst.arguments)
            n = length(args)
            check(v, n >= 3 && isodd(n),
                  "Field write barrier must be (parent, slot, child) plus (slot, child) pairs", inst)
            n >= 1 && check(v, is_pointer_in(args[1], AS_TRACKED),
                            "Field write barrier requires a tracked parent", inst)
            for i in 2:2:n-1
                check(v, is_pointer_in(args[i], derived ? AS_DERIVED : AS_LOADED),
                      "Field write barrier slot address space must match its declaration", inst)
                check(v, is_pointer_in(args[i+1], AS_TRACKED),
                      "Field write barrier requires tracked children", inst)
                check(v, !(strip_pointer_casts(args[i]) isa LLVM.PointerNull),
                      "Field write barrier requires non-null slots", inst)
            end
        end
    end
    if name == "julia.call" || name == "julia.call2" || (dialect.has_call3 && name == "julia.call3")
        args = inst.arguments
        if dialect.has_call3
            # the variadic arguments, after the parameters of the call's function type
            fixed = length(inst.called_type.parameters)
            for arg in collect(args)[fixed+1:end]
                check(v, is_checked_pointer(v, arg) &&
                         pointer_addrspace(arg) == AS_TRACKED,
                      "Invalid derived pointer in jlcall", inst)
            end
        else
            # Julia 1.10: the function, then tracked arguments
            for (i, arg) in enumerate(args)
                check(v, is_pointer(arg) &&
                         pointer_addrspace(arg) == (i == 1 ? AS_GENERIC : AS_TRACKED),
                      "Invalid derived pointer in jlcall", inst)
            end
        end
    end
end

function gc_invariant_verifier!(f::LLVM.Function, am, opts::PassOptions)
    v = GCInvariantVerifier(opts.dialect, opts.extra.strong, GCInvariantViolation[])
    for bb in f.blocks, inst in bb.instructions
        if inst isa LLVM.AddrSpaceCastInst
            verify_addrspacecast!(v, inst)
        elseif inst isa LLVM.LoadInst
            verify_load!(v, inst)
        elseif inst isa LLVM.StoreInst
            ops = inst.operands
            verify_store!(v, inst, ops[1], ops[2])
        elseif inst isa LLVM.AtomicCmpXchgInst
            ops = inst.operands
            verify_store!(v, inst, ops[3], ops[1])
        elseif inst isa LLVM.AtomicRMWInst
            ops = inst.operands
            verify_store!(v, inst, ops[2], ops[1])
        elseif inst isa LLVM.RetInst
            verify_return!(v, inst)
        elseif inst isa LLVM.GetElementPtrInst
            verify_gep!(v, inst)
        elseif inst isa LLVM.IntToPtrInst
            check(v, !is_special_addrspace(pointer_addrspace(inst)), "Illegal inttoptr", inst)
        elseif inst isa LLVM.PtrToIntInst
            # Julia 1.13 and older say "Illegal inttoptr" here
            check(v, !is_special_addrspace(pointer_addrspace(inst.operands[1])),
                  "Illegal ptrtoint", inst)
        elseif inst isa LLVM.CallInst
            verify_call!(v, inst)
        end
    end
    isempty(v.violations) || throw(GCInvariantError(f.name, v.violations))
    return PreservedAnalyses(AllAnalyses)
end

const GC_INVARIANT_VERIFIER = define_pass("jl-gc-invariant-verifier", :function,
                                          gc_invariant_verifier!; required=true,
                                          extra=(; strong=false),
                                          cpp_name="GCInvariantVerifier")

"""
    JuliaIR.GCInvariantVerifierPass(; julia=VERSION, strong=false)

Check that functions obey the invariants of Julia's GC address spaces
(`jl-gc-invariant-verifier` in a pipeline, `jl-gc-invariant-verifier<strong>` for
`strong=true`), and throw a [`JuliaIR.GCInvariantError`](@ref) listing every violation
otherwise. `strong` also rejects GEPs of tracked pointers, which Julia's code generator
never emits but the optimizer may introduce.
"""
GCInvariantVerifierPass(; kwargs...) = custom_pass(GC_INVARIANT_VERIFIER; kwargs...)
