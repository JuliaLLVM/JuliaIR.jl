# Facts about the Julia runtime that code is compiled against, which some passes need
# and which the IR doesn't say: the layout of runtime structures and the names and
# signatures of runtime functions that depend on how Julia was built. They are facts of
# the target's runtime build (OS, architecture, libc, build options), not of the dialect,
# and a target triple doesn't determine them.

"""
    JuliaIR.RuntimeProfile(; handler_size, handler_align=16, setjmp)

The facts about a Julia runtime that passes need, describing the build of Julia the
generated code will run with:

- `handler_size`, `handler_align`: the size and alignment in bytes of an exception
  handler (`jl_handler_t`, which holds a `jmp_buf`), used by LowerExcHandlers;
- `setjmp`: the name of the `setjmp` function that handlers call (`jl_setjmp_name`:
  `__sigsetjmp` with glibc, `sigsetjmp` on other Unixes, `jl_setjmp`/`ijl_setjmp` on
  Windows). It also determines the signature: the Windows functions take only the
  buffer, the others also take the `savemask` argument (`setjmp_savemask`).

Passes that need these facts take them as options (`handler-size=N;handler-align=N;
setjmp=NAME`), or `runtime=native` for the running Julia's own, see
[`JuliaIR.resolve_runtime`](@ref).
"""
struct RuntimeProfile
    handler_size::Int
    handler_align::Int
    setjmp::String
    setjmp_savemask::Bool
end

function RuntimeProfile(; handler_size::Integer, handler_align::Integer=16,
                        setjmp::AbstractString)
    handler_size > 0 || throw(ArgumentError("invalid handler size $handler_size"))
    ispow2(handler_align) || throw(ArgumentError("invalid handler alignment $handler_align"))
    isempty(setjmp) && throw(ArgumentError("the name of setjmp must not be empty"))
    return RuntimeProfile(handler_size, handler_align, setjmp,
                          !(setjmp in ("jl_setjmp", "ijl_setjmp")))
end

# The pass options that select a runtime profile, with their defaults: `runtime=native`
# asks for the running Julia's facts, the others give them explicitly (all or none).
const RUNTIME_OPTIONS = (; runtime=:auto, handler_size=0, handler_align=0, setjmp="")

"""
    JuliaIR.RuntimeError(msg)

The runtime facts a pass needs are not known: neither given as options, nor those of the
running Julia (which are only used for its own dialect and target).
"""
struct RuntimeError <: Exception
    msg::String
end
Base.showerror(io::IO, e::RuntimeError) = print(io, "RuntimeError: ", e.msg)

"""
    JuliaIR.resolve_runtime(extra::NamedTuple, dialect::Dialect, mod::LLVM.Module)

The [`JuliaIR.RuntimeProfile`](@ref) for a pass with the options `extra` (which include
`RUNTIME_OPTIONS`) on module `mod` of dialect `dialect`. In order:

1. the profile given explicitly by the options `handler-size`, `handler-align` and
   `setjmp` (which take precedence over `runtime=native`);
2. the running Julia's own profile, only for its own dialect (never for an older one)
   and for a module whose target triple is the host's (ignoring the vendor). A module
   without a triple only gets it with `runtime=native` (which `jlopt` uses by default);
   by default (`runtime=auto`) its target is considered unknown;
3. otherwise a [`JuliaIR.RuntimeError`](@ref), e.g. for a module of another target.

Passes call this only when they need the facts, so that IR that doesn't need them is
processed without.
"""
function resolve_runtime(extra::NamedTuple, dialect::Dialect, mod::LLVM.Module)
    explicit = (extra.handler_size, extra.handler_align, extra.setjmp) != (0, 0, "")
    extra.runtime in (:auto, :native) ||
        throw(ArgumentError("invalid option runtime=$(extra.runtime); expected auto or native"))
    if explicit
        (extra.handler_size == 0 || extra.handler_align == 0 || isempty(extra.setjmp)) &&
            throw(ArgumentError("an explicit runtime profile needs all of handler-size, handler-align and setjmp"))
        return RuntimeProfile(; extra.handler_size, extra.handler_align, extra.setjmp)
    end

    triple = mod.triple
    native_dialect = dialect.minor == dialect_minor(VERSION)
    native_target = isempty(triple) ? extra.runtime === :native : is_host_triple(triple)
    if native_dialect && native_target
        return native_runtime(mod)
    end
    why = !native_dialect ?
        "the IR is of the Julia $(dialect.minor) dialect, not of the running Julia $(VERSION.major).$(VERSION.minor)" :
        isempty(triple) ?
        "the module has no target triple; use runtime=native for the running Julia's" :
        "the module's target ($triple) is not the host's"
    throw(RuntimeError("the facts of the Julia runtime are unknown (handler size and alignment, setjmp): $why; give them with the options handler-size, handler-align and setjmp"))
end

# whether a target triple is the host's, ignoring the vendor
function is_host_triple(triple::AbstractString)
    parts(t) = (p = split(LLVM.normalize(t), '-'); (get(p, 1, ""), get(p, 3, ""), get(p, 4, "")))
    return parts(triple) == parts(LLVM.default_triple())
end

const NATIVE_RUNTIME = Ref{Union{Nothing,RuntimeProfile}}(nothing)

# The running Julia's profile. `jl_handler_t` and `jl_setjmp_name` are not exported, so
# they are read from what Julia's own LowerExcHandlers emits for a probe function (on the
# Julia versions that have the pass; later versions emit no handlers to lower).
function native_runtime(mod::LLVM.Module)
    profile = NATIVE_RUNTIME[]
    if profile === nothing
        profile = probe_native_runtime()
        NATIVE_RUNTIME[] = profile
    end
    # like Julia's pass, which decides on the signature of setjmp by the module's target
    # (the host's, or none)
    savemask = !occursin("windows", LLVM.normalize(mod.triple))
    return RuntimeProfile(profile.handler_size, profile.handler_align, profile.setjmp,
                          savemask)
end

function probe_native_runtime()
    minor = dialect_minor(VERSION)
    minor <= v"1.12" ||
        throw(RuntimeError("the running Julia $VERSION has no native exception handler runtime facts (handlers are lowered by its code generator)"))
    enter, args, pop = minor == v"1.10" ? ("i32", "", "i32 1") :
                       minor == v"1.11" ? ("i32", "ptr %ct", "ptr %ct, i32 1") :
                                          ("{i32, ptr}", "ptr %ct", "ptr %ct, i32 1")
    ir = """
        declare $enter @julia.except_enter($(isempty(args) ? "" : "ptr")) returns_twice
        declare void @ijl_pop_handler($(minor == v"1.10" ? "i32" : "ptr, i32"))
        define void @probe(ptr %ct) {
          %r = call $enter @julia.except_enter($args)
          call void @ijl_pop_handler($pop)
          ret void
        }
        """
    @dispose ctx=Context(; opaque_pointers=true) begin
        mod = parse(LLVM.Module, ir)
        try
            try
                @dispose pb=PassBuilder() begin
                    add!(pb, "function(LowerExcHandlers)")
                    run!(pb, mod)
                end
            catch err
                throw(RuntimeError("cannot determine the running Julia's runtime facts: Julia's LowerExcHandlers pass failed or is unavailable ($(sprint(showerror, err)))"))
            end
            f = mod.functions["probe"]
            size = align = 0
            setjmp = ""
            for inst in first(f.blocks).instructions
                if inst isa LLVM.AllocaInst
                    size = convert(Int, inst.operands[1])
                    align = inst.alignment
                elseif inst isa LLVM.CallInst && (callee = inst.called_function) !== nothing &&
                       callee.name != "ijl_enter_handler" && callee.name != "ijl_pop_handler" &&
                       !LLVM.isintrinsic(callee)
                    setjmp = callee.name
                end
            end
            size > 0 && !isempty(setjmp) ||
                throw(RuntimeError("cannot determine the running Julia's runtime facts: unexpected output of Julia's LowerExcHandlers pass:\n$(string(mod))"))
            return RuntimeProfile(; handler_size=size, handler_align=align, setjmp)
        finally
            dispose(mod)
        end
    end
end
