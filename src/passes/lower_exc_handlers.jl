# LowerExcHandlers: lower Julia's exception handlers. Julia 1.10 to 1.12 emit
# `julia.except_enter` where a `try` starts and `jl_pop_handler(n)` (or, from 1.11,
# `jl_pop_handler_noexcept`) where `n` handlers are left; this pass gives every nesting
# level of handlers a stack buffer of the runtime's `jl_handler_t`, and replaces each
# `julia.except_enter` by `jl_enter_handler` on that buffer followed by `setjmp`, with
# lifetime markers around the buffer's use. Port of Julia's `src/llvm-lower-handlers.cpp`
# (Julia 1.10 to 1.12; later versions emit the handlers directly and don't have the
# pass). The size of `jl_handler_t` and the name of `setjmp` come from the runtime
# profile (`src/runtime.jl`).
#
# Like the C++ pass, this assumes handlers are properly nested and that the nesting depth
# at the start of a block doesn't depend on the path to it, which holds for the IR
# Julia's code generator emits (the pass must run before optimizations that could break
# it).

"""
    JuliaIR.HandlerNestingError

The error thrown by LowerExcHandlers (`jl-lower-exc-handlers`) when a function leaves
more exception handlers than it entered, or leaves a number of them that isn't a
constant. The function is not changed.
"""
struct HandlerNestingError <: Exception
    function_name::String
    message::String
    instruction::String
end

Base.showerror(io::IO, err::HandlerNestingError) =
    print(io, "HandlerNestingError: ", err.message, " in function ", err.function_name,
          "\n\t", err.instruction)

const ENTER_HANDLER = "ijl_enter_handler"
const POP_HANDLER = "ijl_pop_handler"
const POP_HANDLER_NOEXCEPT = "ijl_pop_handler_noexcept"

# the blocks reachable from `entry`, in depth-first preorder (LLVM's `depth_first`)
function depth_first(entry::BasicBlock)
    order = BasicBlock[entry]
    visited = Set{BasicBlock}(order)
    stack = Tuple{BasicBlock,Vector{BasicBlock},Int}[(entry, collect(entry.successors), 1)]
    while !isempty(stack)
        bb, succs, i = stack[end]
        if i > length(succs)
            pop!(stack)
            continue
        end
        stack[end] = (bb, succs, i + 1)
        succ = succs[i]
        succ in visited && continue
        push!(visited, succ)
        push!(order, succ)
        push!(stack, (succ, collect(succ.successors), 1))
    end
    return order
end

# the declaration of a runtime function, created like the C++ pass does if the module
# doesn't have one
function runtime_function!(mod::LLVM.Module, name::String, ft::LLVM.FunctionType)
    f = get(mod.functions, name, nothing)
    f === nothing || return f
    API.LLVMGetNamedGlobal(mod, name) == C_NULL &&
        API.LLVMGetNamedGlobalAlias(mod, name, length(name)) == C_NULL ||
        throw(ArgumentError("module has a global named $name that is not a function"))
    return LLVM.Function(mod, name, ft)
end

function lower_exc_handlers!(f::LLVM.Function, am, opts::PassOptions)
    dialect = opts.dialect
    dialect.except_enter === :none && return PreservedAnalyses(AllAnalyses)
    mod = LLVM.parent(f)
    fns = mod.functions
    enter_func = get(fns, "julia.except_enter", nothing)
    enter_func === nothing && return PreservedAnalyses(AllAnalyses)
    task_arg = dialect.except_enter !== :no_task
    leave_funcs = LLVM.Function[]
    for name in (POP_HANDLER, task_arg ? POP_HANDLER_NOEXCEPT : nothing)
        name === nothing && continue
        leave = get(fns, name, nothing)
        leave === nothing || push!(leave_funcs, leave)
    end
    # the operand of jl_pop_handler that says how many handlers are left
    npops_index = task_arg ? 2 : 1

    # step 1: the handler depth at every enter and leave, by a depth-first walk that
    # takes a block's initial depth from its first visited predecessor
    enters = Tuple{Instruction,Int}[]
    leaves = Tuple{Instruction,Int}[]
    exit_depth = Dict{BasicBlock,Int}()
    max_depth = 0
    for bb in depth_first(first(f.blocks))
        depth = 0
        for pred in bb.predecessors
            d = get(exit_depth, pred, nothing)
            if d !== nothing
                depth = d
                break
            end
        end
        for inst in bb.instructions
            inst isa LLVM.CallInst || continue
            callee = inst.called_function
            callee === nothing && continue
            if callee == enter_func
                push!(enters, (inst, depth))
                depth += 1
            elseif callee in leave_funcs
                push!(leaves, (inst, depth))
                npops = inst.arguments[npops_index]
                npops isa ConstantInt ||
                    throw(HandlerNestingError(f.name, "non-constant number of handlers to leave",
                                              string(inst)))
                depth -= convert(Int, npops)
                depth >= 0 ||
                    throw(HandlerNestingError(f.name, "more handlers left than entered",
                                              string(inst)))
            end
            max_depth = max(max_depth, depth)
        end
        exit_depth[bb] = depth
    end
    # Julia's pass also declares the runtime functions and lifetime intrinsics in every
    # function of a module that declares julia.except_enter; this port only does when it
    # lowers handlers, so that the runtime facts are only needed then.
    isempty(enters) && isempty(leaves) && return PreservedAnalyses(AllAnalyses)

    profile = resolve_runtime(opts.extra, dialect, mod)
    facts = library_facts(context(f))
    T_ptr = LLVM.PointerType()
    T_void = LLVM.VoidType()
    T_int32 = LLVM.Int32Type()
    T_int64 = LLVM.Int64Type()

    # the declarations, in the order the C++ pass creates them
    enter_params = task_arg ? LLVMType[enter_func.function_type.parameters[1], T_ptr] :
                              LLVMType[T_ptr]
    jlenter_func = runtime_function!(mod, ENTER_HANDLER,
                                     LLVM.FunctionType(T_void, enter_params))
    setjmp_func = get(fns, profile.setjmp, nothing)
    if setjmp_func === nothing
        params = profile.setjmp_savemask ? LLVMType[T_ptr, T_int32] : LLVMType[T_ptr]
        setjmp_func = runtime_function!(mod, profile.setjmp,
                                        LLVM.FunctionType(T_int32, params))
        push!(setjmp_func.function_attributes, EnumAttribute("returns_twice"))
    end
    lifetime_start = LLVM.Function(mod, LIFETIME_START, LLVMType[T_ptr])
    lifetime_end = LLVM.Function(mod, LIFETIME_END, LLVMType[T_ptr])
    lifetime_args(buff) = facts.lifetime_size ?
        Value[ConstantInt(T_int64, profile.handler_size), buff] : Value[buff]

    @dispose builder=IRBuilder() begin
        # step 2: one buffer per nesting level, in the entry block; separate allocas, so
        # that the optimizer can merge or rearrange them
        first_inst = first(first(f.blocks).instructions)
        alloca_as = alloca_addrspace(unsafe_string(API.LLVMGetDataLayoutStr(mod)))
        buffs = Value[]
        position!(builder, LLVM.before(first_inst))
        builder.debug_location = nothing
        for _ in 1:max_depth
            buff = array_alloca!(builder, LLVM.Int8Type(),
                                 ConstantInt(T_int32, profile.handler_size);
                                 align=profile.handler_align)
            if alloca_as != 0
                buff = addrspacecast!(builder, buff, LLVM.PointerType(AS_GENERIC))
            end
            push!(buffs, buff)
        end

        for (enter, depth) in enters
            buff = buffs[depth+1]
            position!(builder, LLVM.before(enter))
            builder.debug_location = nothing
            call!(builder, lifetime_start.function_type, lifetime_start, lifetime_args(buff))
            args = task_arg ? Value[enter.arguments[1], buff] : Value[buff]
            new_enter = call!(builder, jlenter_func.function_type, jlenter_func, args)
            sj_args = profile.setjmp_savemask ? Value[buff, ConstantInt(T_int32, 0)] :
                                                Value[buff]
            sj = call!(builder, setjmp_func.function_type, setjmp_func, sj_args)
            # also on the call site, see JuliaLang/julia#6757
            push!(sj.function_attributes, EnumAttribute("returns_twice"))
            loc = enter.debug_location
            if loc !== nothing
                new_enter.debug_location = loc
                sj.debug_location = loc
            end
            if dialect.except_enter === :task_buffer
                extracts = Instruction[]
                for use in enter.uses
                    u = use.user
                    u isa LLVM.ExtractValueInst && length(u.indices) == 1 || continue
                    replace_uses!(u, u.indices[1] == 0 ? sj : buff)
                    push!(extracts, u)
                end
                foreach(erase!, extracts)
                if !isempty(enter.uses)
                    agg = insert_value!(builder, UndefValue(enter.value_type), sj, 0)
                    agg = insert_value!(builder, agg, buff, 1)
                    replace_uses!(enter, agg)
                end
            else
                replace_uses!(enter, sj)
            end
            erase!(enter)
        end

        # end the lifetimes of the buffers of the handlers that are left, after the leave
        for (leave, depth) in leaves
            npops = convert(Int, leave.arguments[npops_index])
            position!(builder, LLVM.after(leave))
            builder.debug_location = nothing
            for level in depth-npops+1:depth
                call!(builder, lifetime_end.function_type, lifetime_end,
                      lifetime_args(buffs[level]))
            end
        end
    end
    return PreservedAnalyses(CFGAnalyses)
end

const LOWER_EXC_HANDLERS = define_pass("jl-lower-exc-handlers", :function,
                                       lower_exc_handlers!; required=true,
                                       extra=RUNTIME_OPTIONS,
                                       cpp_name="LowerExcHandlers")

"""
    JuliaIR.LowerExcHandlersPass(; julia=VERSION, runtime=:auto, handler_size=0,
                                 handler_align=0, setjmp="")

Lower Julia's exception handlers (`julia.except_enter` and the matching
`jl_pop_handler` calls) to calls of the runtime's `jl_enter_handler` and `setjmp` on
stack buffers (`jl-lower-exc-handlers` in a pipeline). Only Julia 1.10 to 1.12 emit
these; for later dialects the pass does nothing.

The lowering depends on the Julia runtime the code will run with (the size of its
exception handler structure and the name of its `setjmp`): give them with
`handler_size`, `handler_align` and `setjmp`, or use the running Julia's with
`runtime=:native` (see [`JuliaIR.resolve_runtime`](@ref)). They are only needed for
functions that have handlers.
"""
LowerExcHandlersPass(; kwargs...) = custom_pass(LOWER_EXC_HANDLERS; kwargs...)
