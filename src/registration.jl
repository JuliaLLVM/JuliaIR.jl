# Pass definitions, their options, and registration with LLVM.jl.

## options

"""
    JuliaIR.PassOptions

The options of one occurrence of a pass in a pipeline: the [`JuliaIR.Dialect`](@ref) of
the IR (`dialect`, the running Julia's, with the policies of the options) and the
pass-specific options (`extra`, a `NamedTuple`).
"""
struct PassOptions{T<:NamedTuple}
    dialect::Dialect
    extra::T
end

Base.:(==)(a::PassOptions, b::PassOptions) = a.dialect == b.dialect && a.extra == b.extra

# option keys shared by all passes (the policies of the dialect), as written in a pipeline
const POLICY_KEYS = ("fp16", "bf16", "gc-barrier")

option_key(name::Symbol) = replace(string(name), '_' => '-')

"""
    JuliaIR.Optional{T}(value=nothing)

The value of a pass option that may be left unspecified (`nothing`), and its type `T`: a
signed integer like an offset (`T = Int`, e.g. `tls-offset=-8` in a pipeline), or an
address (`T = UInt`, written as `pgcstack-getter=0x4011c0`). A pass's default for such an
option is `Optional{T}()`; its constructor's keyword takes a `T` or `nothing`.
"""
struct Optional{T<:Integer}
    value::Union{Nothing,T}
    # (an inner constructor, so that there is no `Optional(nothing)` without a `T`)
    Optional{T}(value=nothing) where {T<:Integer} = new{T}(value)
end

# the value of an option, `nothing` for an unspecified `Optional`
option_value(x) = x
option_value(x::Optional) = x.value

function parse_optional(::Type{Optional{T}}, key, value) where {T}
    n = tryparse(T, value)
    n === nothing &&
        throw(ArgumentError(T <: Unsigned ? "option $key requires an address (a non-negative integer)" :
                                            "option $key requires an integer"))
    return Optional{T}(n)
end

# the value of an option given as a keyword argument, for a pass whose default is `default`
function option_argument(default::Optional{T}, @nospecialize(v), key) where {T}
    v isa Optional{T} && return v
    v === nothing && return Optional{T}()
    if v isa Integer || (T <: Unsigned && v isa Ptr)
        n = tryparse_convert(T, v)
        n === nothing || return Optional{T}(n)
    end
    throw(ArgumentError("option $key must be $(T <: Unsigned ? "an address" : "an integer") or `nothing`"))
end
function option_argument(default, @nospecialize(v), key)
    v isa typeof(default) || throw(ArgumentError("option $key must be a $(typeof(default))"))
    return v
end

tryparse_convert(::Type{T}, v::Ptr) where {T} = T(UInt(v))
function tryparse_convert(::Type{T}, v::Integer) where {T}
    typemin(T) <= v <= typemax(T) || return nothing
    return T(v)
end

"""
    JuliaIR.parse_options(str; fp16=:auto, bf16=:auto, gc_barrier=:stock, extra=(;))

Parse the option text of a pass in a pipeline (the part between `<` and `>`, e.g.
`fp16=demote;strong`) into [`JuliaIR.PassOptions`](@ref), whose dialect is the running
Julia's. Options are separated by `;`. The keyword arguments are the defaults for
options that are not given. `extra`
holds the defaults of the pass-specific options, which determine how they are parsed:
a `Bool` option is written `name` or `no-name`, a `Symbol` option `name=value`, an
`Int` option a non-negative integer, a `String` option any text, and a
[`JuliaIR.Optional`](@ref) option a signed integer or an address. Unknown and repeated
options are rejected.
"""
function parse_options(str::AbstractString; fp16::Symbol=:auto, bf16::Symbol=:auto,
                       gc_barrier::Symbol=:stock, extra::NamedTuple=(;))
    extra_values = Dict{Symbol,Any}(pairs(extra))
    seen = Set{Symbol}()
    for opt in split(str, ';'; keepempty=false)
        key, value = if occursin('=', opt)
            k, v = split(opt, '='; limit=2)
            String(k), String(v)
        else
            String(opt), nothing
        end
        # boolean options are negated with a `no-` prefix, like LLVM's pass options
        negated = false
        name = Symbol(replace(key, '-' => '_'))
        if value === nothing && startswith(key, "no-") && !haskey(extra, name)
            negated = true
            key = key[4:end]
            name = Symbol(replace(key, '-' => '_'))
        end
        name in seen && throw(ArgumentError("option $key is given more than once"))
        push!(seen, name)

        if key == "fp16"
            value === nothing && throw(ArgumentError("option fp16 requires a value"))
            fp16 = Symbol(value)
        elseif key == "bf16"
            value === nothing && throw(ArgumentError("option bf16 requires a value"))
            bf16 = Symbol(value)
        elseif key == "gc-barrier"
            value === nothing && throw(ArgumentError("option gc-barrier requires a value"))
            gc_barrier = Symbol(replace(value, '-' => '_'))
        elseif haskey(extra, name)
            default = extra[name]
            if default isa Bool
                value === nothing ||
                    throw(ArgumentError("option $key is a flag, write $key or no-$key"))
                extra_values[name] = !negated
            elseif default isa Symbol
                (value === nothing || negated) &&
                    throw(ArgumentError("option $key requires a value"))
                extra_values[name] = Symbol(replace(value, '-' => '_'))
            elseif default isa Int
                (value === nothing || negated) &&
                    throw(ArgumentError("option $key requires a value"))
                n = tryparse(Int, value)
                (n === nothing || n < 0) &&
                    throw(ArgumentError("option $key requires a non-negative integer"))
                extra_values[name] = n
            elseif default isa String
                (value === nothing || negated) &&
                    throw(ArgumentError("option $key requires a value"))
                extra_values[name] = value
            elseif default isa Optional
                (value === nothing || negated) &&
                    throw(ArgumentError("option $key requires a value"))
                extra_values[name] = parse_optional(typeof(default), key, value)
            else
                error("unsupported type of option $key: $(typeof(default))")
            end
        else
            known = [POLICY_KEYS..., (option_key(k) for k in keys(extra))...]
            throw(ArgumentError("unknown option $key; expected one of $(join(known, ", "))"))
        end
    end
    dialect = Dialect(VERSION; fp16, bf16, gc_barrier)
    values = NamedTuple{keys(extra)}(Tuple(extra_values[k] for k in keys(extra)))
    return PassOptions(dialect, values)
end

# the options as text, the inverse of `parse_options`
function options_string(opts::PassOptions)
    policies = options_string(opts.dialect)
    parts = isempty(policies) ? String[] : [policies]
    for (k, v) in pairs(opts.extra)
        v isa Optional && v.value === nothing && continue
        push!(parts, v isa Bool ? (v ? option_key(k) : "no-" * option_key(k)) :
                     v isa Symbol ? "$(option_key(k))=$(replace(string(v), '_' => '-'))" :
                     v isa Optional{<:Unsigned} ? "$(option_key(k))=0x$(string(v.value; base=16))" :
                     "$(option_key(k))=$(option_value(v))")
    end
    return join(parts, ";")
end


## library

"""
    JuliaIR.require_opaque(ctx::LLVM.Context)

Throw an error if `ctx` uses typed pointers. The passes only support opaque pointers;
IR with typed pointers (as emitted by Julia 1.10) needs to be parsed into a context that
uses opaque pointers, e.g. `Context(; opaque_pointers=true)`, which upgrades it.
"""
function require_opaque(ctx::Context)
    supports_typed_pointers(ctx) &&
        throw(ArgumentError("JuliaIR's passes require a context with opaque pointers; create it with `Context(; opaque_pointers=true)`"))
    return
end

"""
    JuliaIR.library_facts(ctx::LLVM.Context)

What the passes need to know about the LLVM library that `ctx` belongs to, as opposed to
the Julia dialect of the IR:

- `llvm`: the version of LLVM;
- `lifetime_size`: whether the lifetime intrinsics take a size argument (before LLVM 22);
- `masked_load_alignment`: whether `llvm.masked.load` and `llvm.masked.gather` take an
  alignment argument (before LLVM 22);
- `null_pointer_alignment`: whether LLVM's `Value::getPointerAlignment` takes a null
  pointer to have the maximum alignment (before LLVM 22; later, only integer constants
  cast to pointers have a known alignment).
"""
function library_facts(ctx::Context)
    # LLVM.jl supports one library per session; this is where a per-context library
    # would be queried once it supports several.
    llvm = LLVM.version()
    return (; llvm, lifetime_size = llvm < v"22", masked_load_alignment = llvm < v"22",
             null_pointer_alignment = llvm < v"22")
end


## ledger

# When the environment variable JULIAIR_LEDGER names a file when the package is loaded,
# every invocation of a pass appends a line to it, so that tests can prove that the port
# ran (and not, e.g., Julia's C++ pass of a similar name). Not printed to stdout or
# stderr, which some tests check.
const LEDGER = Ref("")

function ledger_write(fields...)
    isempty(LEDGER[]) && return
    line = join((getpid(), fields...), '\t') * '\n'
    # one write per line, so that lines of concurrent processes don't interleave
    open(LEDGER[], "a") do io
        write(io, line)
    end
    return
end

ledger_record(name::String, dialect::Dialect) =
    ledger_write("pass", name, "julia=$(dialect.julia)", "llvm=$(LLVM.version())")


## pass definitions

# A pass of this package. `impl(ir, am, opts::PassOptions)` runs it on a module (module
# pass), a function (function pass) or a loop (loop pass, with the loop pass manager's
# `LoopAnalysisResults` as `am`), and returns the preserved analyses. `cpp_name` is
# the name of Julia's C++ pass it ports, which `jlopt` maps to this pass. A pass can be
# defined with the same name for several kinds (FinalLowerGC is a module pass in Julia
# 1.10 and a function pass later); LLVM's pipeline parser picks the one of the pass
# manager it is nested in, and the module pass at the top level.
struct PassDefinition
    name::String
    kind::Symbol
    required::Bool
    impl::Any
    extra::NamedTuple
    cpp_name::String
end

PassDefinition(name, kind, required, impl, extra=(;)) =
    PassDefinition(name, kind, required, impl, extra, "")

# the same pass with another implementation (e.g. one that captures a pass argument that
# can't be a pipeline option)
with_impl(def::PassDefinition, impl) =
    PassDefinition(def.name, def.kind, def.required, impl, def.extra, def.cpp_name)

# all passes, in the order they were defined
const PASSES = PassDefinition[]

function define_pass(name, kind, impl; required::Bool, extra::NamedTuple=(;),
                     cpp_name::String)
    startswith(name, "jl-") || error("pass names must start with jl-")
    kind in (:module, :function, :loop) || error("invalid pass kind $kind")
    def = PassDefinition(name, kind, required, impl, extra, cpp_name)
    filter!(p -> p.name != name || p.kind != kind, PASSES)
    push!(PASSES, def)
    return def
end

function run_pass(def::PassDefinition, @nospecialize(ir), am, opts::PassOptions)
    require_opaque(context(ir isa Loop ? ir.header : ir))
    ledger_record(def.name, opts.dialect)
    return def.impl(ir, am, opts)
end

# the LLVM.jl pass for a definition, with the defaults for options not given in the
# pipeline
function custom_pass(def::PassDefinition; fp16::Symbol=:auto, bf16::Symbol=:auto,
                     gc_barrier::Symbol=:stock, kwargs...)
    given = map(collect(pairs(kwargs))) do (k, v)
        haskey(def.extra, k) ||
            throw(ArgumentError("unknown option $k for pass $(def.name)"))
        k => option_argument(def.extra[k], v, "$k of pass $(def.name)")
    end
    extra = merge(def.extra, (; given...))
    # validate the defaults now, rather than when the pass is first used
    parse_options(""; fp16, bf16, gc_barrier, extra)
    parse = str -> parse_options(str; fp16, bf16, gc_barrier, extra)
    callback = (ir, am, opts) -> run_pass(def, ir, am, opts)
    constructor = def.kind === :module ? ModulePass :
                  def.kind === :function ? FunctionPass : LoopPass
    return constructor(def.name, callback; def.required, analyses=true,
                       parse_options=parse)
end

"""
    JuliaIR.passes()

The names of the passes of this package, as used in pipelines.
"""
passes() = unique(def.name for def in PASSES)

"""
    JuliaIR.register!(pb::PassBuilder; fp16=:auto, bf16=:auto, gc_barrier=:stock)

Register every pass of this package with the pass builder `pb`, so that they can be used
by name in its pipeline. The keyword arguments are the defaults of the policy options for
occurrences of the passes that do not specify them (see [`JuliaIR.Dialect`](@ref)).
"""
function register!(pb::PassBuilder; fp16::Symbol=:auto, bf16::Symbol=:auto,
                   gc_barrier::Symbol=:stock)
    for def in PASSES
        LLVM.register!(pb, custom_pass(def; fp16, bf16, gc_barrier))
    end
    return pb
end
