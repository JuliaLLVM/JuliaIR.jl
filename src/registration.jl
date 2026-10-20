# Pass definitions, their options, and registration with LLVM.jl.

## options

"""
    JuliaIR.PassOptions

The options of one occurrence of a pass in a pipeline: the [`JuliaIR.Dialect`](@ref) of
the IR (`dialect`, the running Julia's, with the policies of the options) and the values
of the pass-specific options (`extra`, a `NamedTuple`).
"""
struct PassOptions{T<:NamedTuple}
    dialect::Dialect
    extra::T
    # what the pass found out about the module it runs on (`module_facts`)
    module_facts::Dict{Type,Pair{LLVM.Module,Any}}
end

PassOptions(dialect::Dialect, extra::NamedTuple) =
    PassOptions(dialect, extra, Dict{Type,Pair{LLVM.Module,Any}}())

Base.:(==)(a::PassOptions, b::PassOptions) = a.dialect == b.dialect && a.extra == b.extra

# Facts of type `T` about the module `mod`, which `compute()` returns, computed once for
# all the functions that one occurrence of a function pass runs on: LLVM.jl parses the
# pipeline, creating the options, for every run on a module. As other passes run in
# between, even module passes when the occurrence is repeated (`repeat<n>(...)`, up to
# LLVM 18), only for facts that no pass changes: the data layout and what follows from it,
# types, uniqued metadata (and what follows from its operands, which no pass sets in
# place). Not functions or other globals, which may be added or removed.
function module_facts(compute, opts::PassOptions, mod::LLVM.Module, ::Type{T}) where {T}
    entry = get(opts.module_facts, T, nothing)
    if entry === nothing || first(entry) != mod
        entry = mod => compute()::T
        opts.module_facts[T] = entry
    end
    return last(entry)::T
end

# option keys shared by all passes (the policies of the dialect), as written in a pipeline
const POLICY_KEYS = ("fp16", "bf16", "gc-barrier")

option_key(name::Symbol) = replace(string(name), '_' => '-')

"""
    JuliaIR.OptionSpec

The declaration of a pass-specific option, made with [`JuliaIR.option`](@ref).
"""
struct OptionSpec
    type::Type
    default::Any
    # whether the option can be written in a pipeline
    text::Bool
    # `nothing`, or a predicate on the values of the option other than `nothing`, and what
    # it requires of them, for error messages
    valid::Any
    requirement::String
end

"""
    JuliaIR.option(T, default; text=true, valid=nothing, requirement="")

The declaration of a pass-specific option of type `T`, whose value is `default` unless it
is given, for the `options` of a pass definition. An option whose type includes `Nothing`
may be left unspecified, which its default `nothing` says; the pass then decides (e.g. by
reading the running Julia). The type also decides how the option is written in a
pipeline:

| type | in a pipeline |
|:-----|:--------------|
| `Bool` | `name` or `no-name` |
| `Union{Nothing,Bool}` | `name=yes` or `name=no` |
| `Symbol` | `name=value` (a `-` in the value stands for `_`) |
| `Int` | `name=-8`: a decimal integer |
| `UInt` | `name=0x4011c0`: an address, hexadecimal or decimal |
| `String` | `name=text` |

Options of other types, and options declared with `text=false`, are keyword-only: they
can only be given as keyword arguments of the pass's constructor (e.g. feature lists,
which contain `,`, LLVM's separator of pipeline elements, or objects like a target
machine). A keyword argument is converted to `T` where that loses nothing: an integer in
range, a `Ptr` for an address, any `AbstractString` for a `String`, and any vector of the
element type for a `Vector`.

`valid(value)` says whether a value other than `nothing` is valid, and `requirement`
what it requires, for error messages (e.g. `"a non-negative integer"`). The requirement
describes only the values other than `nothing`, because `nothing` can't be written in a
pipeline: errors about keyword arguments add "or `nothing`" themselves. It defaults to a
description of the type.
"""
function option(@nospecialize(T::Type), @nospecialize(default); text::Bool=true,
                valid=nothing, requirement::String="")
    text && text_form(T) === nothing &&
        throw(ArgumentError("options of type $T have no text form; declare them with `text=false`"))
    spec = OptionSpec(T, default, text, valid,
                      isempty(requirement) ? describe(T) : requirement)
    check_value(spec, default, "the default of the option")
    return spec
end

# the declaration of an option, given as one or by its default value (of its type)
option_spec(spec::OptionSpec) = spec
option_spec(@nospecialize(default)) = option(typeof(default), default)

option_specs(options::NamedTuple) = map(option_spec, options)
option_defaults(specs::NamedTuple) = map(spec -> spec.default, specs)

# the type of the values of an option other than `nothing`
function nonnothing(@nospecialize(T::Type))
    T isa Union || return T
    T.a === Nothing && return T.b
    T.b === Nothing && return T.a
    return T
end
nullable(@nospecialize(T::Type)) = T !== Nothing && Nothing <: T

# how an option of type `T` is written in a pipeline, or `nothing` if it can't be
function text_form(@nospecialize(T::Type))
    S = nonnothing(T)
    S === Bool && return nullable(T) ? :yes_no : :flag
    S === Symbol && return :symbol
    S === Int && return :int
    S === UInt && return :address
    S === String && return :string
    return nothing
end

# what a value of type `T`, other than `nothing`, is
function describe(@nospecialize(T::Type))
    S = nonnothing(T)
    S === Bool && return "true or false"
    S === Int && return "an integer"
    S === UInt && return "an address"
    S === String && return "a string"
    S <: AbstractVector && return "a vector of $(eltype(S))"
    name = string(S)
    return occursin(r"^([AEIOU]|LLVM)"i, name) ? "an $name" : "a $name"
end

# what an option given as a keyword argument requires, with `requirement` describing the
# values other than `nothing`
function keyword_requirement(@nospecialize(T::Type), requirement)
    nullable(T) || return requirement
    # "x or y" becomes "x, y or `nothing`"
    return "$(replace(requirement, " or " => ", ")) or `nothing`"
end

# throw if `value` isn't a value of the option (`what` names it in the error)
function check_value(spec::OptionSpec, @nospecialize(value), what)
    value === nothing && nullable(spec.type) && return
    value isa spec.type ||
        throw(ArgumentError("$what must be $(keyword_requirement(spec.type, describe(spec.type)))"))
    spec.valid === nothing || spec.valid(value) ||
        throw(ArgumentError("$what must be $(keyword_requirement(spec.type, spec.requirement))"))
    return
end

# a keyword argument for an option, converted to the option's type
function convert_option(spec::OptionSpec, @nospecialize(v), what)
    S = nonnothing(spec.type)
    value = if v === nothing || v isa S
        v
    elseif (S === Int || S === UInt) && v isa Integer && typemin(S) <= v <= typemax(S)
        S(v)
    elseif S === UInt && v isa Ptr
        UInt(v)
    elseif S === String && v isa AbstractString
        String(v)
    elseif S <: AbstractVector && v isa AbstractVector && all(x -> x isa eltype(S), v)
        convert(S, collect(v))
    else
        v
    end
    check_value(spec, value, what)
    return value
end

# the value of an option written in a pipeline
function parse_value(spec::OptionSpec, name::Symbol, key, value::Union{Nothing,String},
                     negated::Bool)
    spec.text ||
        throw(ArgumentError("option $key can't be given in a pipeline, only as the `$name` keyword argument of the pass's constructor"))
    form = text_form(spec.type)
    if form === :flag
        value === nothing ||
            throw(ArgumentError("option $key is a flag, write $key or no-$key"))
    else
        (value === nothing || negated) && throw(ArgumentError("option $key requires a value"))
    end
    parsed = if form === :flag
        !negated
    elseif form === :yes_no
        value == "yes" ? true : value == "no" ? false : nothing
    elseif form === :symbol
        Symbol(replace(value, '-' => '_'))
    elseif form === :int
        tryparse(Int, value)
    elseif form === :address
        tryparse(UInt, value)
    else
        value
    end
    requirement = form === :yes_no ? "yes or no" :
                  form === :address && spec.valid === nothing ?
                      "an address (a non-negative integer)" : spec.requirement
    (parsed !== nothing && (spec.valid === nothing || spec.valid(parsed))) ||
        throw(ArgumentError("option $key requires $requirement"))
    return parsed
end

# an option's value as written in a pipeline
function value_string(spec::OptionSpec, @nospecialize(v))
    form = text_form(spec.type)
    form === :yes_no && return v ? "yes" : "no"
    form === :symbol && return replace(string(v), '_' => '-')
    form === :address && return "0x" * string(v; base=16)
    return string(v)
end

"""
    JuliaIR.parse_options(str; fp16=:auto, bf16=:auto, gc_barrier=:stock, options=(;),
                          values)
    JuliaIR.parse_options(def::PassDefinition, str; kwargs...)

Parse the option text of a pass in a pipeline (the part between `<` and `>`, e.g.
`fp16=demote;strong`) into [`JuliaIR.PassOptions`](@ref), whose dialect is the running
Julia's. Options are separated by `;`. The keyword arguments are the defaults for the
policies that are not given; `options` declares the pass-specific options (as
[`JuliaIR.option`](@ref)s, or by their default values), which decides how they are
written, and `values` holds their values when they are not given (by default, the
declared defaults). Unknown, repeated and keyword-only options are rejected. With a pass
definition, its options are parsed, and its check of their combination applies.
"""
function parse_options(str::AbstractString; fp16::Symbol=:auto, bf16::Symbol=:auto,
                       gc_barrier::Symbol=:stock, options::NamedTuple=(;),
                       values::NamedTuple=option_defaults(option_specs(options)))
    specs = option_specs(options)
    given = Dict{Symbol,Any}(pairs(values))
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
        if value === nothing && startswith(key, "no-") && !haskey(specs, name)
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
        elseif haskey(specs, name)
            given[name] = parse_value(specs[name], name, key, value, negated)
        else
            known = [POLICY_KEYS..., (option_key(k) for k in keys(specs))...]
            throw(ArgumentError("unknown option $key; expected one of $(join(known, ", "))"))
        end
    end
    for (k, spec) in pairs(specs)
        check_value(spec, given[k], "option $(option_key(k))")
    end
    dialect = Dialect(VERSION; fp16, bf16, gc_barrier)
    return PassOptions(dialect, NamedTuple{keys(specs)}(Tuple(given[k] for k in keys(specs))))
end

# the options as text, the inverse of `parse_options` with the same `options`, without the
# options that are unspecified or keyword-only
function options_string(opts::PassOptions, options::NamedTuple)
    specs = option_specs(options)
    policies = options_string(opts.dialect)
    parts = isempty(policies) ? String[] : [policies]
    for (k, v) in pairs(opts.extra)
        spec = specs[k]
        (spec.text && v !== nothing) || continue
        push!(parts, text_form(spec.type) === :flag ?
                         (v ? option_key(k) : "no-" * option_key(k)) :
                         "$(option_key(k))=$(value_string(spec, v))")
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
- `lifetime_on_alloca`: whether the lifetime intrinsics must be given an `alloca` itself,
  not a pointer derived from one such as an `addrspacecast` (LLVM 22 and later);
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
    return (; llvm, lifetime_size = llvm < v"22", lifetime_on_alloca = llvm >= v"22",
             masked_load_alignment = llvm < v"22", null_pointer_alignment = llvm < v"22")
end


## ledger

# When the environment variable JULIAIR_LEDGER names a file when the package is loaded,
# every invocation of a pass appends a line to it, so that tests can prove that the port
# ran (and not, e.g., Julia's C++ pass of a similar name). Not printed to stdout or
# stderr, which some tests check.
#
# Several processes (e.g. test workers) may append to the same ledger. `open(path, "a")`
# doesn't open with O_APPEND but seeks to the end once, so a concurrent writer can
# overwrite a line. Each line is instead one unbuffered write to a file opened with
# O_APPEND (FILE_APPEND_DATA on Windows), which a local file system appends as a whole
# unless the write comes up short (e.g. on a full disk). Network file systems (e.g. NFS)
# don't guarantee that.
const LEDGER = Ref("")

function ledger_write(fields...)
    isempty(LEDGER[]) && return
    line = join((getpid(), fields...), '\t') * '\n'
    fs = Base.Filesystem
    file = fs.open(LEDGER[], fs.JL_O_WRONLY | fs.JL_O_CREAT | fs.JL_O_APPEND, 0o666)
    try
        write(file, line)
    finally
        close(file)
    end
    return
end

function ledger_record(name::String, dialect::Dialect)
    # before formatting the line: this runs for every function a pass runs on
    isempty(LEDGER[]) && return
    ledger_write("pass", name, "julia=$(dialect.julia)", "llvm=$(LLVM.version())")
end


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
    # the declarations of the pass-specific options (`OptionSpec`s)
    options::NamedTuple
    cpp_name::String
    # `check(values)` throws an `ArgumentError` for values of the pass-specific options
    # that are invalid together
    check::Any

    PassDefinition(name, kind, required, impl, options=(;), cpp_name="", check=nothing) =
        new(name, kind, required, impl, option_specs(options), cpp_name, check)
end

# the same pass with another implementation (e.g. one that captures a pass argument that
# can't be a pipeline option)
with_impl(def::PassDefinition, impl) =
    PassDefinition(def.name, def.kind, def.required, impl, def.options, def.cpp_name,
                   def.check)

# all passes, in the order they were defined
const PASSES = PassDefinition[]

function define_pass(name, kind, impl; required::Bool, options::NamedTuple=(;),
                     cpp_name::String, check=nothing)
    startswith(name, "jl-") || error("pass names must start with jl-")
    kind in (:module, :function, :loop) || error("invalid pass kind $kind")
    def = PassDefinition(name, kind, required, impl, options, cpp_name, check)
    filter!(p -> p.name != name || p.kind != kind, PASSES)
    push!(PASSES, def)
    return def
end

function run_pass(def::PassDefinition, @nospecialize(ir), am, opts::PassOptions)
    require_opaque(context(ir isa Loop ? ir.header : ir))
    ledger_record(def.name, opts.dialect)
    return def.impl(ir, am, opts)
end

function parse_options(def::PassDefinition, str::AbstractString; kwargs...)
    opts = parse_options(str; options=def.options, kwargs...)
    def.check === nothing || def.check(opts.extra)
    return opts
end

# The LLVM.jl pass for a definition, with the defaults for options not given in the
# pipeline: the policies, and the pass-specific options (keyword arguments named like
# the options, converted to their types). Keyword-only options can only be set this way.
function custom_pass(def::PassDefinition; fp16::Symbol=:auto, bf16::Symbol=:auto,
                     gc_barrier::Symbol=:stock, kwargs...)
    given = Dict{Symbol,Any}(pairs(option_defaults(def.options)))
    for (k, v) in pairs(kwargs)
        haskey(def.options, k) ||
            throw(ArgumentError("unknown option $k for pass $(def.name)"))
        given[k] = convert_option(def.options[k], v, "option $k of pass $(def.name)")
    end
    values = NamedTuple{keys(def.options)}(Tuple(given[k] for k in keys(def.options)))
    parse = str -> parse_options(def, str; fp16, bf16, gc_barrier, values)
    # validate the defaults now, rather than when the pass is first used
    parse("")
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
    JuliaIR.register!(pb::PassBuilder; fp16=:auto, bf16=:auto, gc_barrier=:stock,
                      options=Dict())

Register every pass of this package with the pass builder `pb`, so that they can be used
by name in its pipeline, as well as the marker passes of Julia's pipeline (see
[`JuliaIR.build_pipeline!`](@ref)). The keyword arguments are the defaults of the policy
options for occurrences of the passes that do not specify them (see
[`JuliaIR.Dialect`](@ref)), and `options` maps the names of passes to the defaults of their
own options, as a `NamedTuple` of the keyword arguments of their constructors (e.g.
`Dict("jl-cpu-features" => (; target_cpu="haswell"))`).
"""
function register!(pb::PassBuilder; fp16::Symbol=:auto, bf16::Symbol=:auto,
                   gc_barrier::Symbol=:stock, options::AbstractDict=Dict{String,NamedTuple}())
    for name in keys(options)
        any(def -> def.name == name, PASSES) ||
            throw(ArgumentError("options for unknown pass $name"))
    end
    for def in PASSES
        LLVM.register!(pb, custom_pass(def; fp16, bf16, gc_barrier,
                                       get(options, def.name, (;))...))
    end
    for marker in marker_passes()
        LLVM.register!(pb, marker)
    end
    return pb
end
