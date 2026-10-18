# Pass definitions, their options, and registration with LLVM.jl.

## options

"""
    JuliaIR.PassOptions

The options of one occurrence of a pass in a pipeline: the [`JuliaIR.Dialect`](@ref) of
the IR (`dialect`) and the pass-specific options (`extra`, a `NamedTuple`).
"""
struct PassOptions{T<:NamedTuple}
    dialect::Dialect
    extra::T
end

Base.:(==)(a::PassOptions, b::PassOptions) = a.dialect == b.dialect && a.extra == b.extra

# option keys shared by all passes, as written in a pipeline
const DIALECT_KEYS = ("julia", "fp16", "bf16", "gc-barrier")

option_key(name::Symbol) = replace(string(name), '_' => '-')

"""
    JuliaIR.parse_options(str; julia=VERSION, fp16=:auto, bf16=:auto, gc_barrier=:stock,
                          extra=(;))

Parse the option text of a pass in a pipeline (the part between `<` and `>`, e.g.
`julia=1.12;fp16=demote`) into [`JuliaIR.PassOptions`](@ref). Options are separated by
`;`. The keyword arguments are the defaults for options that are not given. `extra`
holds the defaults of the pass-specific options, which determine how they are parsed:
a `Bool` option is written `name` or `no-name`, a `Symbol` option `name=value`.
Unknown and repeated options are rejected.
"""
function parse_options(str::AbstractString; julia=VERSION, fp16::Symbol=:auto,
                       bf16::Symbol=:auto, gc_barrier::Symbol=:stock,
                       extra::NamedTuple=(;))
    julia = julia isa VersionNumber ? julia : parse_julia_version(string(julia))
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

        if key == "julia"
            value === nothing && throw(ArgumentError("option julia requires a version, e.g. julia=1.12"))
            julia = parse_julia_version(value)
        elseif key == "fp16"
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
            else
                error("unsupported type of option $key: $(typeof(default))")
            end
        else
            known = [DIALECT_KEYS..., (option_key(k) for k in keys(extra))...]
            throw(ArgumentError("unknown option $key; expected one of $(join(known, ", "))"))
        end
    end
    dialect = Dialect(julia; fp16, bf16, gc_barrier)
    values = NamedTuple{keys(extra)}(Tuple(extra_values[k] for k in keys(extra)))
    return PassOptions(dialect, values)
end

# the options as text, the inverse of `parse_options`
function options_string(opts::PassOptions)
    parts = [options_string(opts.dialect)]
    for (k, v) in pairs(opts.extra)
        push!(parts, v isa Bool ? (v ? option_key(k) : "no-" * option_key(k)) :
                     v isa Symbol ? "$(option_key(k))=$(replace(string(v), '_' => '-'))" :
                     "$(option_key(k))=$v")
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
- `lifetime_size`: whether the lifetime intrinsics take a size argument (before LLVM 22).
"""
function library_facts(ctx::Context)
    # LLVM.jl supports one library per session; this is where a per-context library
    # would be queried once it supports several.
    llvm = LLVM.version()
    return (; llvm, lifetime_size = llvm < v"22")
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
# the name of Julia's C++ pass it ports, which `jlopt` maps to this pass.
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

# all passes, in the order they were defined
const PASSES = PassDefinition[]

function define_pass(name, kind, impl; required::Bool, extra::NamedTuple=(;),
                     cpp_name::String)
    startswith(name, "jl-") || error("pass names must start with jl-")
    kind in (:module, :function, :loop) || error("invalid pass kind $kind")
    def = PassDefinition(name, kind, required, impl, extra, cpp_name)
    filter!(p -> p.name != name, PASSES)
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
function custom_pass(def::PassDefinition; julia=VERSION, fp16::Symbol=:auto,
                     bf16::Symbol=:auto, gc_barrier::Symbol=:stock, kwargs...)
    for (k, v) in pairs(kwargs)
        haskey(def.extra, k) ||
            throw(ArgumentError("unknown option $k for pass $(def.name)"))
        v isa typeof(def.extra[k]) ||
            throw(ArgumentError("option $k of pass $(def.name) must be a $(typeof(def.extra[k]))"))
    end
    extra = merge(def.extra, values(kwargs))
    # validate the defaults now, rather than when the pass is first used
    parse_options(""; julia, fp16, bf16, gc_barrier, extra)
    parse = str -> parse_options(str; julia, fp16, bf16, gc_barrier, extra)
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
passes() = [def.name for def in PASSES]

"""
    JuliaIR.register!(pb::PassBuilder; julia=VERSION, fp16=:auto, bf16=:auto,
                      gc_barrier=:stock)

Register every pass of this package with the pass builder `pb`, so that they can be used
by name in its pipeline. The keyword arguments are the defaults of the options for
occurrences of the passes that do not specify them (see [`JuliaIR.Dialect`](@ref)).
"""
function register!(pb::PassBuilder; julia=VERSION, fp16::Symbol=:auto,
                   bf16::Symbol=:auto, gc_barrier::Symbol=:stock)
    for def in PASSES
        LLVM.register!(pb, custom_pass(def; julia, fp16, bf16, gc_barrier))
    end
    return pb
end
