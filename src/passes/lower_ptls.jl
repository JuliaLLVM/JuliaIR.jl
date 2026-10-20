# LowerPTLS: lower the calls of `julia.get_pgcstack` and `julia.get_pgcstack_or_new`,
# which return the current task's GC stack, to the code that finds it in the running
# process: a read of the thread pointer plus the runtime's TLS offset, or a call of the
# runtime's getter (JIT mode), or a load of the getter that the system image's loader
# fills in, with a fast path through the thread pointer where the image has an ELF TLS
# offset (imaging mode). For `julia.get_pgcstack_or_new` (the entry of a C-callable
# function), a thread that isn't Julia's is adopted, and the GC state is switched to
# unsafe on entry and restored at the returns. Port of Julia's `src/llvm-ptls.cpp`; see
# docs/src/lower_ptls.md for the differences between Julia versions and from the C++.

"""
    JuliaIR.LowerPTLSError(message)

LowerPTLS can't lower a module: a getter is used other than as the called function of a
`call` (e.g. by an `invoke` or as a value), a symbol it needs to declare exists with an
incompatible definition, a `julia.get_pgcstack_or_new` call doesn't dominate the returns
whose GC state it has to restore, or the thread pointer of the target can't be read. The
module is left unchanged.
"""
struct LowerPTLSError <: Exception
    message::String
end

Base.showerror(io::IO, err::LowerPTLSError) = print(io, "LowerPTLSError: ", err.message)

const PGCSTACK_GETTER = "julia.get_pgcstack"
const PGCSTACK_GETTER_OR_NEW = "julia.get_pgcstack_or_new"
const PGCSTACK_FUNC_SLOT = "jl_pgcstack_func_slot"
const PGCSTACK_KEY_SLOT = "jl_pgcstack_key_slot"
const PGCSTACK_RESOLVED = "jl_get_pgcstack_resolved"

mutable struct LowerPTLS
    mod::LLVM.Module
    dialect::Dialect
    imaging::Bool
    tls_getters::Bool
    # the module's triple, or the running Julia's when it has none
    triple::LLVM.Triple
    builder::IRBuilder
    gc::GCCodegen
    T_size::LLVMType
    # set up when the first getter is found
    FT_getter::Union{Nothing,LLVM.FunctionType}
    T_pppjlvalue::Union{Nothing,LLVMType}
    slots::Dict{String,LLVM.GlobalVariable}
    cfg_modified::Bool
end

layout(p::LowerPTLS) = p.gc.layout

function effective_triple(mod::LLVM.Module)
    str = LLVM.triple(mod)
    return LLVM.Triple(isempty(str) ? LLVM.normalize(Sys.MACHINE) : str)
end

# the assembly that reads the thread pointer, or `nothing` if there is none
function thread_pointer_asm(p::LowerPTLS)
    t = p.triple
    LLVM.isaarch64(t) && return "mrs \$0, tpidr_el0"
    LLVM.isarm(t) && return "mrc p15, 0, \$0, c13, c0, 3"
    p.dialect.ptls_tp_inbounds && LLVM.isriscv(t) && return "mv \$0, tp"
    t.arch === :x86_64 && return "movq %fs:0, \$0"
    LLVM.isx86(t) && return "movl %gs:0, \$0"
    return nothing
end

# `Function::callsFunctionThatReturnsTwice`
function calls_returns_twice(f::LLVM.Function)
    for bb in f.blocks, inst in bb.instructions
        inst isa LLVM.CallBase && can_return_twice(inst) && return true
    end
    return false
end

# the argument of a function that holds its GC stack
function gc_stack_argument(p::LowerPTLS, f::LLVM.Function)
    for (i, arg) in enumerate(f.parameters)
        attrs = collect(f.parameter_attributes[i])
        found = p.dialect.ptls_stack_argument === :gcstack ?
            has_string_fn_attr(attrs, "gcstack") : has_enum_fn_attr(attrs, "swiftself")
        found && return arg
    end
    return nothing
end

# the code that reads the GC stack from thread-local storage, at an offset from the thread
# pointer: the runtime's `jl_tls_offset` (JIT mode) or a value loaded from the image
# (`emit_pgcstack_tp`)
function emit_pgcstack_tp!(p::LowerPTLS, offset::Union{Nothing,Value}, insert_before::Instruction)
    builder = p.builder
    position_before!(builder, insert_before; debug=true)
    T_ptr = LLVM.PointerType(AS_GENERIC)
    tls = if LLVM.isx86(p.triple) && calls_returns_twice(LLVM.parent(insert_before.parent))
        # hide the addition from LLVM, which would otherwise keep the thread pointer in a
        # register across the `setjmp` (JuliaLang/julia#17288)
        x86_64 = p.triple.arch === :x86_64
        if offset !== nothing
            ft = LLVM.FunctionType(T_ptr, [LLVM.value_type(offset)])
            asm = x86_64 ? "movq %fs:0, \$0;\naddq \$1, \$0" : "movl %gs:0, \$0;\naddl \$1, \$0"
            call!(builder, ft, InlineAsm(ft, asm, "=&r,r,~{dirflag},~{fpsr},~{flags}", false),
                  Value[offset], "pgcstack")
        else
            ft = LLVM.FunctionType(T_ptr)
            asm = (x86_64 ? "movq %fs:0, \$0;\naddq \$\$" : "movl %gs:0, \$0;\naddl \$\$") *
                  "$(layout(p).tls_offset), \$0"
            call!(builder, ft, InlineAsm(ft, asm, "=r,~{dirflag},~{fpsr},~{flags}", false),
                  Value[], "tls_pgcstack")
        end
    else
        asm = thread_pointer_asm(p)
        asm === nothing && throw(LowerPTLSError(unsupported_target(p)))
        if offset === nothing
            offset = ConstantInt(p.T_size, layout(p).tls_offset, true)
        end
        ft = LLVM.FunctionType(T_ptr)
        tp = call!(builder, ft, InlineAsm(ft, asm, "=r", false), Value[], "thread_ptr")
        (p.dialect.ptls_tp_inbounds ? inbounds_gep! : gep!)(builder, LLVM.Int8Type(), tp,
                                                            Value[offset], "tls_ppgcstack")
    end
    return load!(builder, p.T_pppjlvalue, tls, "tls_pgcstack")
end

unsupported_target(p::LowerPTLS) =
    "can't read the thread pointer for target $(string(p.triple)); use the getter instead (JIT mode with `tls-offset=-1`, or imaging mode with `tls-elf-support=no`)"

# The getter calls are pure and don't throw: `memory(none)`, or `readnone` before LLVM 16.
function set_pgcstack_attrs!(call::Instruction)
    attrs = call.function_attributes
    push!(attrs, LLVM.version() >= v"16" ? EnumAttribute("memory", 0) : EnumAttribute("readnone"))
    push!(attrs, EnumAttribute("nounwind"))
    return
end

function load_slot!(p::LowerPTLS, T::LLVMType, slot::String)
    load = load!(p.builder, T, p.slots[slot])
    tbaa_decorate!(tbaa_const(), load)
    return load
end

# the global value of the module named `name`, of any kind (`Module::getNamedValue`)
function named_global(mod::LLVM.Module, name::String)
    for set in (mod.functions, mod.globals, mod.aliases, mod.ifuncs)
        gv = get(set, name, nothing)
        gv === nothing || return gv
    end
    return nothing
end

global_addrspace(gv::LLVM.GlobalValue) = LLVM.addrspace(LLVM.value_type(gv))

# the declaration of an external function like the getter, as Julia declares the function
# that adopts a thread
function declare_like!(p::LowerPTLS, name::String, getter::LLVM.Function)
    f = get(p.mod.functions, name, nothing)
    f === nothing || return f
    f = LLVM.Function(p.mod, name, getter.function_type; addrspace=global_addrspace(getter))
    LLVM.linkage!(f, LLVM.linkage(getter))
    LLVM.copy_attributes!(f, getter)
    for (kind, md) in getter.metadata
        f.metadata[kind] = md
    end
    return f
end

# whether the GC state is restored at the returns of a function that adopts threads: the
# C++ only does so when the function returns no tracked pointers
restores_gc_state(f::LLVM.Function) =
    CountTrackedPointers(Base.unsafe_convert(TypeRef, LLVM.return_type(f.function_type))).count == 0

# Call another function (`CallBase::setCalledOperand`), which may be in another address
# space than the getter: the callee is the last operand of a call. (LLVM.jl's
# `called_operand!` insists on the same pointer type.)
set_called_operand!(call::Instruction, @nospecialize(callee::Value)) =
    (LLVM.operands(call)[end] = callee)

# Lower one call of a getter (`fix_pgcstack_use`).
function fix_pgcstack_use!(p::LowerPTLS, call::Instruction, getter::LLVM.Function, or_new::Bool)
    builder = p.builder
    gc = p.gc
    if isempty(call.uses)
        erase!(call)
        return
    end
    if or_new
        # pgcstack = getter()
        # if pgcstack != null:            (fast)
        #     last_gc_state = <enter the GC-unsafe state>
        #     phi = pgcstack
        # else:                           (slow)
        #     last_gc_state = GC-safe
        #     phi = adopt()
        # ... phi ...
        # unless the function returns tracked pointers: at every return,
        #     <restore last_gc_state>
        next = LLVM.next(call)
        position_before!(builder, next; debug=true)
        cmp = icmp!(builder, LLVM.API.LLVMIntNE, call, LLVM.null(LLVM.value_type(call)))
        # (the C++ creates the phi before the split, and splits before it: the same IR)
        fast_term, slow_term = split_block_and_insert_if_then_else!(cmp, next; weights=(9, 1))
        p.cfg_modified = true
        position_before!(builder, next; debug=true)
        phi = phi!(builder, LLVM.value_type(call), "pgcstack")
        replace_uses!(call, phi)
        LLVM.operands(cmp)[1] = call

        adopt = copy(call)
        adopt_fn = declare_like!(p, p.dialect.ptls_adopt_thread, getter)
        LLVM.called_operand!(adopt, adopt_fn)
        move!(adopt, LLVM.before(slow_term))
        push!(phi.incoming, (adopt, slow_term.parent))

        # (the debug location stays the split point's, which `fast_term` has too)
        position!(builder, LLVM.before(fast_term))
        ptls = current_ptls_from_task!(gc, current_task_from_pgcstack!(gc, call), tbaa_gcframe())
        prior = emit_gc_unsafe_enter!(gc, ptls)
        # the safepoint ends the block in a branch; the fast path continues after it
        move!(fast_term, LLVM.at_end(builder.insert_block))
        push!(phi.incoming, (call, fast_term.parent))

        f = LLVM.parent(call.parent)
        if restores_gc_state(f)
            position_before!(builder, phi; debug=false)
            last_gc_state = phi!(builder, LLVM.Int8Type())
            # a thread adopted here leaves in the GC-safe state
            push!(last_gc_state.incoming,
                  (ConstantInt(LLVM.Int8Type(), JL_GC_STATE_SAFE), slow_term.parent))
            push!(last_gc_state.incoming, (prior, fast_term.parent))
            for bb in collect(f.blocks)
                ret = LLVM.terminator(bb)
                ret isa LLVM.RetInst || continue
                position_before!(builder, ret; debug=true)
                ptls = current_ptls_from_task!(gc, current_task_from_pgcstack!(gc, phi),
                                               tbaa_gcframe())
                if p.dialect.ptls_exit_safepoint
                    store!(builder, last_gc_state, gc_state_address!(gc, ptls);
                           align=GC_STATE_ALIGN, ordering=LLVM.API.LLVMAtomicOrderingRelease)
                    emit_gc_final_safepoint!(gc, ptls, tbaa_gcframe())
                else
                    emit_gc_unsafe_leave!(gc, ptls, last_gc_state)
                end
            end
        end
    end

    T_ptr = LLVM.PointerType(AS_GENERIC)
    if p.imaging
        position_before!(builder, call; debug=true)
        if layout(p).tls_elf_support
            # offset = <the image's TLS offset>
            # if offset != 0:  pgcstack = <thread pointer> + offset    (fast)
            # else:            pgcstack = <the image's getter>()       (slow)
            offset = load_slot!(p, p.T_size, p.dialect.ptls_image_offset_slot)
            cmp = icmp!(builder, LLVM.API.LLVMIntNE, offset, ConstantInt(p.T_size, 0))
            fast_term, slow_term = split_block_and_insert_if_then_else!(cmp, call;
                                                                        weights=(9, 1))
            p.cfg_modified = true
            fast_tls = emit_pgcstack_tp!(p, offset, fast_term)
            position_before!(builder, call; debug=true)
            phi = phi!(builder, p.T_pppjlvalue, "pgcstack")
            replace_uses!(call, phi)
            move!(call, LLVM.before(slow_term))
            position_before!(builder, call; debug=true)
            set_called_operand!(call, load_slot!(p, T_ptr, PGCSTACK_FUNC_SLOT))
            set_pgcstack_attrs!(call)
            push!(phi.incoming, (fast_tls, fast_tls.parent))
            push!(phi.incoming, (call, call.parent))
            return
        end
        # the getter that the image's loader stores (`jl_get_pgcstack` would take
        # another indirection)
        getter_ptr = load_slot!(p, T_ptr, PGCSTACK_FUNC_SLOT)
        if LLVM.isdarwin(p.triple)
            key = load_slot!(p, p.T_size, PGCSTACK_KEY_SLOT)
            new_call = call!(builder, p.FT_getter, getter_ptr, Value[key])
            take_name!(new_call, call)
            replace_uses!(call, new_call)
            erase!(call)
            call = new_call
        else
            set_called_operand!(call, getter_ptr)
        end
        set_pgcstack_attrs!(call)
    elseif !p.tls_getters && layout(p).tls_offset != -1
        replace_uses!(call, emit_pgcstack_tp!(p, nothing, call))
        erase!(call)
    elseif p.dialect.ptls_jit_getter === :address
        # the runtime's getter, at its address in this process
        target = const_inttoptr(ConstantInt(p.T_size, layout(p).pgcstack_getter), T_ptr)
        if LLVM.isdarwin(p.triple)
            key = ConstantInt(p.T_size, layout(p).pgcstack_key)
            position_before!(builder, call; debug=false)
            new_call = call!(builder, p.FT_getter, target, Value[key])
            take_name!(new_call, call)
            replace_uses!(call, new_call)
            erase!(call)
            call = new_call
        else
            set_called_operand!(call, target)
        end
        set_pgcstack_attrs!(call)
    else
        resolved = named_global(p.mod, PGCSTACK_RESOLVED)
        if resolved === nothing
            # (declared as returning nothing, and called as returning the GC stack)
            resolved = LLVM.Function(p.mod, PGCSTACK_RESOLVED,
                                     LLVM.FunctionType(LLVM.VoidType()))
        end
        set_called_operand!(call, resolved)
        set_pgcstack_attrs!(call)
    end
    return
end

# The declarations of the image's variables that the loader fills in: the getter of the
# GC stack, its key (Darwin) and the TLS offset (`create_hidden_global`). A declaration
# that exists already is reused (the C++ adds another, with a suffixed name).
function slot_type(p::LowerPTLS, name::String)
    name == PGCSTACK_FUNC_SLOT && return LLVM.PointerType(AS_GENERIC)
    return p.T_size
end

function check_slot(p::LowerPTLS, name::String)
    gv = named_global(p.mod, name)
    gv === nothing && return
    (gv isa GlobalVariable && LLVM.isdeclaration(gv) &&
     LLVM.linkage(gv) == LLVM.API.LLVMExternalLinkage && !LLVM.threadlocal(gv) &&
     LLVM.global_value_type(gv) == slot_type(p, name) &&
     global_addrspace(gv) == p.gc.dl.globals_addrspace) ||
        throw(LowerPTLSError("@$name is declared in the module, but not as an external, not thread-local variable of type $(string(slot_type(p, name))): $(string(gv))"))
    return
end

function create_slot!(p::LowerPTLS, name::String)
    gv = get(p.mod.globals, name, nothing)
    if gv === nothing
        gv = GlobalVariable(p.mod, slot_type(p, name), name, p.gc.dl.globals_addrspace)
    end
    # (hidden visibility makes it `dso_local`)
    LLVM.visibility!(gv, LLVM.API.LLVMHiddenVisibility)
    p.slots[name] = gv
    return gv
end

slot_names(p::LowerPTLS) =
    (PGCSTACK_FUNC_SLOT, PGCSTACK_KEY_SLOT, p.dialect.ptls_image_offset_slot)

function init!(p::LowerPTLS, getter::LLVM.Function)
    ft = getter.function_type
    if LLVM.isdarwin(p.triple)
        ft = LLVM.FunctionType(LLVM.return_type(ft), [p.T_size])
    end
    p.FT_getter = ft
    p.T_pppjlvalue = LLVM.return_type(ft)
    if p.imaging
        foreach(name -> create_slot!(p, name), slot_names(p))
    end
    return
end

# Check that the module can be lowered, before changing it. Returns the calls of each
# getter, in the order the C++ visits them.
function check_lower_ptls(p::LowerPTLS, getters)
    calls = Dict{String,Vector{Instruction}}()
    needs_tp = false
    for (name, getter, or_new) in getters
        getter === nothing && continue
        LLVM.return_type(getter.function_type) isa LLVM.PointerType ||
            throw(LowerPTLSError("@$name doesn't return a pointer: $(string(getter))"))
        list = calls[name] = Instruction[]
        for use in getter.uses
            call = LLVM.user(use)
            (call isa LLVM.CallInst && LLVM.iscallee(use) &&
             !any(==(getter), call.arguments)) ||
                throw(LowerPTLSError("@$name is used other than as the function of a call: $(string(call))"))
            push!(list, call)
        end
        domtrees = Dict{LLVM.Function,DomTree}()
        try
            for call in list
                f = LLVM.parent(call.parent)
                gc_stack_argument(p, f) === nothing || continue
                isempty(call.uses) && continue
                needs_tp = true
                or_new || continue
                adopt = named_global(p.mod, p.dialect.ptls_adopt_thread)
                adopt === nothing ||
                    (adopt isa LLVM.Function && adopt.function_type == call.called_type &&
                     global_addrspace(adopt) == global_addrspace(getter)) ||
                    throw(LowerPTLSError("@$(p.dialect.ptls_adopt_thread) is not declared like @$name: $(string(adopt))"))
                restores_gc_state(f) || continue
                # the GC state is restored at every return, from values defined at the call
                dt = get!(() -> DomTree(f), domtrees, f)
                for bb in f.blocks
                    ret = LLVM.terminator(bb)
                    ret isa LLVM.RetInst || continue
                    dominates(dt, call, ret) ||
                        throw(LowerPTLSError("@$name is called in function $(LLVM.name(f)) where it doesn't dominate a return, which needs the GC state it saves: $(string(call))"))
                end
            end
        finally
            foreach(dispose, values(domtrees))
        end
    end
    isempty(calls) && return calls
    p.imaging && foreach(name -> check_slot(p, name), slot_names(p))
    if needs_tp
        # whether a call is lowered to a read of the thread pointer
        reads_tp = p.imaging ? layout(p).tls_elf_support :
                               !p.tls_getters && layout(p).tls_offset != -1
        if reads_tp && thread_pointer_asm(p) === nothing
            throw(LowerPTLSError(unsupported_target(p)))
        end
    end
    return calls
end

function lower_ptls!(mod::LLVM.Module, am, opts::PassOptions)
    dialect = opts.dialect
    imaging = opts.extra.imaging
    tls_getters = opts.extra.tls_getters
    tls_getters && dialect.ptls_jit_getter !== :resolved &&
        throw(ArgumentError("the option tls-getters only exists from Julia 1.14 on, not on $(running_julia())"))
    getters = [(name, get(mod.functions, name, nothing), name == PGCSTACK_GETTER_OR_NEW)
               for name in (PGCSTACK_GETTER, PGCSTACK_GETTER_OR_NEW)]
    all(g -> g[2] === nothing, getters) && return PreservedAnalyses(AllAnalyses)
    @dispose builder=IRBuilder() begin
        dl = mod.datalayout
        T_size = intptr(dl)
        gc = GCCodegen(builder, dialect, runtime_layout(opts, mod), dl, T_size)
        p = LowerPTLS(mod, dialect, imaging, tls_getters, effective_triple(mod), builder, gc,
                      T_size, nothing, nothing, Dict{String,LLVM.GlobalVariable}(), false)
        calls = check_lower_ptls(p, getters)
        for (name, getter, or_new) in getters
            getter === nothing && continue
            p.FT_getter === nothing && init!(p, getter)
            for call in calls[name]
                arg = gc_stack_argument(p, LLVM.parent(call.parent))
                if arg !== nothing
                    dialect.ptls_argument_takes_name && take_name!(arg, call)
                    replace_uses!(call, arg)
                    erase!(call)
                    continue
                end
                fix_pgcstack_use!(p, call, getter, or_new)
            end
            erase!(getter)
        end
        return p.cfg_modified ? PreservedAnalyses() : PreservedAnalyses(CFGAnalyses)
    end
end

# the runtime facts that LowerPTLS may need
const PTLS_RUNTIME_FACTS = (:task_gcstack, :task_ptls, :tls_safepoint, :tls_gc_state,
                            :tls_elf_support, :tls_offset, :pgcstack_getter, :pgcstack_key)

const LOWER_PTLS = define_pass("jl-lower-ptls", :module,
                               (mod, am, opts) -> lower_ptls!(mod, am, opts);
                               required=true,
                               extra=(; imaging=false, tls_getters=false,
                                      runtime_options(PTLS_RUNTIME_FACTS...)...),
                               cpp_name="LowerPTLSPass")

"""
    JuliaIR.LowerPTLSPass(; imaging=false, tls_getters=false, facts...)

Julia's lowering of the GC stack getters (`jl-lower-ptls` in a pipeline, `LowerPTLSPass`
in Julia's pipelines): calls of `julia.get_pgcstack` and `julia.get_pgcstack_or_new`
become the code that finds the current task's GC stack, and C-callable functions (those
that call `julia.get_pgcstack_or_new`) adopt foreign threads and switch the GC state (on
entry, and back at the returns unless the function returns tracked pointers).

In JIT mode (the default), the code reads the GC stack through the thread pointer, at the
running process's `jl_tls_offset`, or calls the runtime's getter (at its address in the
process up to Julia 1.13, through the symbol `jl_get_pgcstack_resolved` from 1.14 on, where
`tls_getters=true` always calls it). The result only works in the process that compiled
it. With `imaging=true`, it loads the getter, and the TLS offset where the running Julia
uses ELF TLS, from variables of the system image that its loader fills in.

The other keyword arguments give the runtime facts explicitly (see
[`JuliaIR.runtime_layout`](@ref)): the task and thread-local state offsets,
`tls_elf_support`, `tls_offset` (-1 for "can't be read from the thread pointer"),
`pgcstack_getter` and `pgcstack_key`. By default, they are read from the running Julia
when a module needs them.
"""
LowerPTLSPass(; kwargs...) = custom_pass(LOWER_PTLS; kwargs...)
