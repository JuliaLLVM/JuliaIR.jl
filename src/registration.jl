# Pass definitions, their options, and registration with LLVM.jl.

## options

"""
    JuliaIR.PassOptions

Options for one occurrence of a pass in a pipeline. `dialect` describes the running
Julia's IR and the selected policies; `extra` is a `NamedTuple` of pass-specific options.
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

Declare a pass-specific option of type `T` with a default value. If `T` includes
`Nothing`, the value `nothing` leaves the choice to the pass, for example by querying
the running Julia. The type determines the pipeline syntax:

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

`valid(value)` validates values other than `nothing`. `requirement` describes the
constraint in errors, e.g. `"a non-negative integer"`; it defaults to a description of
`T`. Do not include `nothing` in this description: keyword errors add it when allowed,
and pipeline syntax cannot express it.
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

# The dialect of the running Julia with the given policies, which every parse of a pass's
# options needs: computing it takes longer than the rest of the parse. Shared between the
# passes, which don't modify it.
const DIALECTS = Dict{Tuple{Symbol,Symbol,Symbol},Dialect}()
const DIALECTS_LOCK = ReentrantLock()

function running_dialect(fp16::Symbol, bf16::Symbol, gc_barrier::Symbol)
    key = (fp16, bf16, gc_barrier)
    @lock DIALECTS_LOCK begin
        get!(() -> Dialect(VERSION; fp16, bf16, gc_barrier), DIALECTS, key)
    end
end

"""
    JuliaIR.parse_options(str; fp16=:auto, bf16=:auto, gc_barrier=:stock, options=(;),
                          values)
    JuliaIR.parse_options(def::PassDefinition, str; kwargs...)

Parse the text between a pass's `<` and `>` into [`JuliaIR.PassOptions`](@ref), using
the running Julia's dialect. Separate options with `;`, e.g. `fp16=demote;strong`.

The policy keywords supply defaults. `options` declares pass-specific options using
[`JuliaIR.option`](@ref) or plain default values; `values` can override those defaults.
Unknown, repeated and keyword-only options are rejected. The `PassDefinition` overload
also checks whether the selected options are valid together.
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
    dialect = running_dialect(fp16, bf16, gc_barrier)
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
  alignment argument (before LLVM 22).
"""
function library_facts(ctx::Context)
    llvm = LLVM.version(ctx)
    return (; llvm, lifetime_size = llvm < v"22", lifetime_on_alloca = llvm >= v"22",
             masked_load_alignment = llvm < v"22")
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
# the name of Julia's C++ pass it ports (empty for passes of this package only), which
# `jlopt` maps to this pass, and `cpp_options` the options (flags) that the C++ pass takes
# in a pipeline. A pass can be defined with the same name for several kinds (FinalLowerGC
# is a module pass in Julia 1.10 and a function pass later); LLVM's pipeline parser picks
# the one of the pass manager it is nested in, and the module pass at the top level.
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
    cpp_options::Tuple{Vararg{Symbol}}

    PassDefinition(name, kind, required, impl, options=(;), cpp_name="", check=nothing,
                   cpp_options=()) =
        new(name, kind, required, impl, option_specs(options), cpp_name, check, cpp_options)
end

# the same pass with another implementation (e.g. one that captures a pass argument that
# can't be a pipeline option)
with_impl(def::PassDefinition, impl) =
    PassDefinition(def.name, def.kind, def.required, impl, def.options, def.cpp_name,
                   def.check, def.cpp_options)

# all passes, in the order they were defined
const PASSES = PassDefinition[]

function define_pass(name, kind, impl; required::Bool, options::NamedTuple=(;),
                     cpp_name::String, check=nothing, cpp_options=())
    startswith(name, "jl-") || error("pass names must start with jl-")
    kind in (:module, :function, :loop) || error("invalid pass kind $kind")
    all(k -> haskey(options, k), cpp_options) ||
        error("the options of the C++ pass must be options of the port")
    def = PassDefinition(name, kind, required, impl, options, cpp_name, check, cpp_options)
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
    values = option_values(def, kwargs)
    # validate the defaults now, rather than when the pass is first used; their parse is
    # also that of every occurrence without options (each gets its own module facts)
    defaults = parse_options(def, ""; fp16, bf16, gc_barrier, values)
    parse = str -> isempty(str) ? PassOptions(defaults.dialect, defaults.extra) :
                                  parse_options(def, str; fp16, bf16, gc_barrier, values)
    callback = (ir, am, opts) -> run_pass(def, ir, am, opts)
    constructor = def.kind === :module ? ModulePass :
                  def.kind === :function ? FunctionPass : LoopPass
    return constructor(def.name, callback; def.required, analyses=true,
                       parse_options=parse)
end

# the values of the pass-specific options of `def`: the defaults, overridden by keyword
# arguments (converted to the options' types)
function option_values(def::PassDefinition, kwargs)
    given = Dict{Symbol,Any}(pairs(option_defaults(def.options)))
    for (k, v) in pairs(kwargs)
        haskey(def.options, k) ||
            throw(ArgumentError("unknown option $k for pass $(def.name)"))
        given[k] = convert_option(def.options[k], v, "option $k of pass $(def.name)")
    end
    return NamedTuple{keys(def.options)}(Tuple(given[k] for k in keys(def.options)))
end

"""
    JuliaIR.passes()

The names of the passes of this package, as used in pipelines.
"""
passes() = unique(def.name for def in PASSES)


## Julia's C++ passes

# Whether the running Julia has the C++ pass that `def` ports, of the same kind. Julia's
# passes were added, removed or changed kind in development versions that `VERSION`
# doesn't always tell apart (CancellationLowering is in Julia 1.14's alphas, but not in
# its release), so Julia's pipeline parser is asked, once per pass.
const CPP_PASSES = Dict{Tuple{String,Symbol},Bool}()
const CPP_PASSES_LOCK = ReentrantLock()

function cpp_available(def::PassDefinition)
    isempty(def.cpp_name) && return false
    key = (def.cpp_name, def.kind)
    @lock CPP_PASSES_LOCK begin
        get!(() -> parses_cpp_pass(key...), CPP_PASSES, key)
    end
end

function parses_cpp_pass(name::String, kind::Symbol)
    text = kind === :module ? "module($name)" :
           kind === :function ? "function($name)" : "function(loop($name))"
    # (parsed, not run)
    LLVM.library!(LLVM.julia_library) do
        @dispose pb=PassBuilder() begin
            add!(pb, text)
            try
                print_pipeline(devnull, pb)
                true
            catch err
                err isa LLVMException || rethrow()
                false
            end
        end
    end
end

# whether `ports` selects this package's ports: `nothing` selects them unless `lib` is
# Julia's LLVM, the only one with Julia's C++ passes
use_ports(ports::Union{Nothing,Bool}, lib::LLVM.Library=LLVM.library()) =
    something(ports, lib !== LLVM.julia_library)


## passes in pipelines

"""
    JuliaIR.Pass

One of Julia's passes, as returned by the pass constructors of this package (e.g.
[`JuliaIR.AllocOptPass`](@ref)): either this package's port or Julia's C++ pass, with
options. `string(pass)` is its pipeline text (e.g. `jl-gc-invariant-verifier<strong>` or
`GCInvariantVerifier<strong>`). `add!(pm, pass)` adds it to a pipeline, nested in pass
managers of its kind where needed (e.g. `function(...)` for a function pass added to a
module pass manager), and `run!(pass, mod)` runs it on its own.

The constructors take a keyword argument `ports` that selects the implementation:

- `nothing` (the default): Julia's C++ pass if the current library (`LLVM.library()`) is
  Julia's own LLVM, which is the only one that has Julia's C++ passes, and this package's
  port otherwise. The choice is made by the library active when the pass is constructed,
  and the pass keeps it, also in another library's scope: construct it with the library
  selected that will run it. ([`JuliaIR.register!`](@ref) decides by the library of its
  pass builder instead.)
- `true`: the port, which needs to be registered with the pass builder that runs it (see
  [`JuliaIR.register!`](@ref)).
- `false`: Julia's C++ pass, which only works with Julia's LLVM.

The options are those of the port; a C++ pass only takes the options that Julia's
pipeline parser supports (`strong` of GCInvariantVerifier, `imaging` of LowerPTLS,
`external` of MultiVersioning). Selecting a C++ pass that the running Julia doesn't have
(e.g. CombineMulAdd on Julia 1.12) is an error, as are passes that only this package has
(e.g. [`JuliaIR.LateGCCleanupPass`](@ref)) with `ports=false`.

Options that can't be written in a pipeline (keyword-only options, like the target of
CPUFeatures, or the address space mapping of `RemoveAddrspacesPass(asmap)`) are part of
the registration of the port instead: such a pass can't be added to a pipeline with
`add!`, but it can be run with `run!`, or registered on its own with
`LLVM.register!(pb, pass)` (in place of registering all passes with
`JuliaIR.register!(pb)`) and then added as `string(pass)`.
"""
struct Pass
    def::PassDefinition
    # whether this is the port, or else Julia's C++ pass
    ports::Bool
    text::String
    # the policies and the options given to the constructor, for a registration of the port
    policies::@NamedTuple{fp16::Symbol, bf16::Symbol, gc_barrier::Symbol}
    kwargs::NamedTuple
    # whether the pass needs a registration of its own: it has options that its pipeline
    # text can't carry
    configured::Bool
end

Base.string(p::Pass) = p.text
function Base.show(io::IO, p::Pass)
    print(io, "JuliaIR.Pass(", repr(p.text))
    p.ports || print(io, ", C++")
    p.configured && print(io, ", configured")
    print(io, ")")
end

# characters that separate the options and passes of a pipeline
const PIPELINE_SYNTAX = (';', ',', '(', ')', '<', '>')

# The pass for a definition (constructors of this package's passes). `configured` marks a
# definition with a custom implementation.
function make_pass(def::PassDefinition, ports::Union{Nothing,Bool};
                    configured::Bool=false, fp16::Union{Nothing,Symbol}=nothing,
                    bf16::Union{Nothing,Symbol}=nothing,
                    gc_barrier::Union{Nothing,Symbol}=nothing, kwargs...)
    port = isempty(def.cpp_name) ? true : use_ports(ports)
    policies = (; fp16, bf16, gc_barrier)
    if !port
        cpp = def.cpp_name
        cpp_available(def) ||
            throw(ArgumentError("Julia $VERSION has no C++ $(def.kind) pass $cpp; use `ports=true` for this package's port"))
        configured &&
            throw(ArgumentError("this form of $(def.name) is only supported by this package's port; use `ports=true`"))
        opts = String[]
        for (k, v) in [(k => v for (k, v) in pairs(policies) if v !== nothing)...,
                       pairs(kwargs)...]
            k in keys(policies) || haskey(def.options, k) ||
                throw(ArgumentError("unknown option $k for pass $(def.name)"))
            k in def.cpp_options ||
                throw(ArgumentError("option $k is only supported by this package's port of $cpp; use `ports=true`"))
            v isa Bool ||
                throw(ArgumentError("option $k of pass $cpp must be true or false"))
            push!(opts, v ? string(k) : "no-$k")
        end
        text = isempty(opts) ? cpp : "$cpp<$(join(opts, ";"))>"
        return Pass(def, false, text, (; fp16=:auto, bf16=:auto, gc_barrier=:stock), (;),
                    false)
    end
    ports === false && isempty(def.cpp_name) &&
        throw(ArgumentError("$(def.name) is a pass of this package only, without a C++ counterpart; use `ports=true` or `nothing`"))

    # the options that are given, in the text where they can be written; all of them are
    # the defaults of a registration of the pass on its own
    resolved = (; fp16=something(fp16, :auto), bf16=something(bf16, :auto),
                gc_barrier=something(gc_barrier, :stock))
    # (validates the policies)
    fp16 === bf16 === gc_barrier === nothing || running_dialect(resolved...)
    opts = String[]
    for (k, v) in pairs(policies)
        v === nothing || push!(opts, "$(option_key(k))=$(replace(string(v), '_' => '-'))")
    end
    keyword_only = false
    values = option_values(def, kwargs)
    for k in keys(kwargs)
        spec, v = def.options[k], values[k]
        if !spec.text
            keyword_only = true
        elseif v !== nothing
            str = text_form(spec.type) === :flag ? (v ? option_key(k) : "no-" * option_key(k)) :
                  "$(option_key(k))=$(value_string(spec, v))"
            any(in(PIPELINE_SYNTAX), str) &&
                throw(ArgumentError("option $k of pass $(def.name) can't be written in a pipeline: $(repr(string(v))) contains one of $(join(PIPELINE_SYNTAX, ' '))"))
            push!(opts, str)
        end
    end
    optstr = join(opts, ";")
    # validate the options together, as the port's parser will (the defaults are valid)
    isempty(optstr) && !keyword_only || parse_options(def, optstr; resolved..., values)
    text = isempty(optstr) ? def.name : "$(def.name)<$optstr>"
    given = NamedTuple{Tuple(keys(kwargs))}(Tuple(values[k] for k in keys(kwargs)))
    return Pass(def, true, text, resolved, given, configured || keyword_only)
end

# The text of `p` in a pipeline of the given level (`:module`, `:function` or `:loop`):
# nested in the pass managers of its kind, which also selects the kind of a pass that has
# two under the same name (FinalLowerGC's port).
function nested_text(p::Pass, level::Symbol)
    kind = p.def.kind
    kind === level && return p.text
    if level === :module && kind === :function
        return "function($(p.text))"
    elseif level === :module && kind === :loop
        return "function(loop($(p.text)))"
    elseif level === :function && kind === :loop
        return "loop($(p.text))"
    end
    throw(ArgumentError("Cannot add $kind pass $(p.text) to a $level pass manager"))
end

pipeline_level(::PassBuilder) = :module
function pipeline_level(pm::LLVM.PassManager)
    pm.type == "module" && return :module
    startswith(pm.type, "function") && return :function
    startswith(pm.type, "loop") && return :loop
    throw(ArgumentError("Cannot add Julia's passes to a $(pm.type) pass manager"))
end

function LLVM.add!(pm::LLVM.AbstractPassManager, p::Pass)
    p.configured &&
        throw(ArgumentError("$p has options that its pipeline text can't carry; register it with `LLVM.register!(pb, pass)` and add `string(pass)`, or run it with `run!`"))
    return add!(pm, nested_text(p, pipeline_level(pm)))
end

"""
    LLVM.register!(pb::PassBuilder, pass::JuliaIR.Pass)

Register the port `pass` with `pb`, with the options given to its constructor as the
defaults of the registration (including those that can't be written in a pipeline). The
pass can then be added by name, with or without options in the pipeline text
(`string(pass)`). Julia's C++ passes need no registration, but Julia's LLVM.
"""
function LLVM.register!(pb::PassBuilder, p::Pass)
    if !p.ports
        pb.library === LLVM.julia_library ||
            throw(ArgumentError("Julia's C++ pass $(p.def.cpp_name) requires the LLVM library that Julia uses; use `ports=true` for this package's port"))
        return pb
    end
    return LLVM.register!(pb, custom_pass(p.def; p.policies..., p.kwargs...))
end

"""
    run!(pass::JuliaIR.Pass, target::Union{LLVM.Module,LLVM.Function}, [tm]; kwargs...)
    run!(pass::JuliaIR.Pass, f::LLVM.Function, am::FunctionAnalysisManager, [tm]; kwargs...)

Run `pass` on its own. The pass builder is one of the target's library, created with
`kwargs` (see `PassBuilder`). A function pass runs on each function of a module, a loop
pass on each loop of the function(s) (without MemorySSA); a module pass can't run on a
function. With an analysis manager, a function pass runs on `f` with the analyses of an
enclosing pass, and returns the preserved analyses.
"""
function LLVM.run!(p::Pass, target::Union{LLVM.Module,LLVM.Function},
                   tm::Union{Nothing,LLVM.TargetMachine}=nothing; kwargs...)
    p.def.kind === :module && target isa LLVM.Function &&
        throw(ArgumentError("Cannot run module pass $(p.def.name) on a function"))
    text = nested_text(p, target isa LLVM.Module ? :module : :function)
    LLVM.library!(LLVM.route_library(target, tm)) do
        @dispose pb=PassBuilder(; kwargs...) begin
            LLVM.register!(pb, p)
            add!(pb, text)
            run!(pb, target, tm)
        end
    end
end

function LLVM.run!(p::Pass, f::LLVM.Function, am::FunctionAnalysisManager,
                   tm::Union{Nothing,LLVM.TargetMachine}=nothing; kwargs...)
    p.def.kind === :function ||
        throw(ArgumentError("Cannot run $(p.def.kind) pass $(p.def.name) on a function with an analysis manager"))
    @dispose pb=PassBuilder(; kwargs...) begin
        LLVM.register!(pb, p)
        add!(pb, p.text)
        run!(pb, f, am, tm)
    end
end


## registration

# The registrations of `register!` without per-pass options, by whether the ports are
# registered and the policies: every pass builder can use the same ones (LLVM.jl creates
# the state of a run for each run). Filled when first used, so not by precompilation.
const REGISTRATIONS = Dict{Tuple{Bool,Symbol,Symbol,Symbol},Vector{LLVM.CustomPass}}()
const REGISTRATIONS_LOCK = ReentrantLock()

# whether `register!` registers the port `def`: the ports of Julia's C++ passes only if
# they're asked for, the passes of this package only always
registers(def::PassDefinition, ports::Bool) = ports || isempty(def.cpp_name)

function registrations(ports::Bool, fp16::Symbol, bf16::Symbol, gc_barrier::Symbol,
                       options::AbstractDict)
    passes = LLVM.CustomPass[custom_pass(def; fp16, bf16, gc_barrier,
                                         get(options, def.name, (;))...)
                             for def in PASSES if registers(def, ports)]
    return append!(passes, marker_passes())
end

"""
    JuliaIR.register!(pb::PassBuilder; ports=nothing, fp16=:auto, bf16=:auto,
                      gc_barrier=:stock, options=Dict())

Register this package's passes with `pb`, for use by name (see
[`JuliaIR.build_pipeline!`](@ref)). These are the ports of Julia's passes if `ports`
selects them (by default, if `pb.library` is another library than Julia's LLVM, whatever
the current library; see [`JuliaIR.Pass`](@ref)), and always the passes that only this
package has and the pipeline marker passes. The policy keywords supply defaults for
passes that do not specify them; see [`JuliaIR.Dialect`](@ref).

`options` maps pass names to default constructor keywords, e.g.
`Dict("jl-cpu-features" => (; target_cpu="haswell"))`.
"""
function register!(pb::PassBuilder; ports::Union{Nothing,Bool}=nothing,
                   fp16::Symbol=:auto, bf16::Symbol=:auto, gc_barrier::Symbol=:stock,
                   options::AbstractDict=Dict{String,NamedTuple}())
    ports = use_ports(ports, pb.library)
    for name in keys(options)
        any(def -> def.name == name, PASSES) ||
            throw(ArgumentError("options for unknown pass $name"))
        any(def -> def.name == name && registers(def, ports), PASSES) ||
            throw(ArgumentError("options for pass $name, which isn't registered without `ports=true`"))
    end
    passes = if isempty(options)
        key = (ports, fp16, bf16, gc_barrier)
        @lock REGISTRATIONS_LOCK begin
            get!(() -> registrations(key..., options), REGISTRATIONS, key)
        end
    else
        registrations(ports, fp16, bf16, gc_barrier, options)
    end
    for pass in passes
        LLVM.register!(pb, pass)
    end
    return pb
end
