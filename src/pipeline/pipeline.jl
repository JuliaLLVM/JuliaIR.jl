# Julia's optimization pipeline (`buildPipeline` in Julia's `src/pipeline.cpp`, the
# `julia<...>` pipeline element), rebuilt from this package's passes and LLVM's.
#
# Each Julia version has its own recipe (`src/pipeline/julia-1.*.jl`), written like that
# version's `pipeline.cpp`, stage by stage, so that the two can be read side by side. A
# stage that a version didn't change is defined as the previous version's. The recipes say
# what the C++ builds; how a pass with given options is written in a pipeline on the LLVM
# that is loaded is up to the spelling helpers below and LLVM.jl's pass constructors.


## options

# The options of Julia's pipeline (`OptimizationOptions` in `src/jitlayers.h`) and their
# defaults, which are those of stock Julia builds (the sanitizers are build options before
# Julia 1.14, and off in stock builds).
const PIPELINE_OPTIONS = (; lower_intrinsics=true, dump_native=false, external_use=false,
                          llvm_only=false, always_inline=true,
                          enable_early_simplifications=true,
                          enable_early_optimizations=true,
                          enable_scalar_optimizations=true,
                          enable_loop_optimizations=true, enable_vector_pipeline=true,
                          remove_ni=true, cleanup=true, warn_missed_transformations=false,
                          sanitize_memory=false, sanitize_thread=false,
                          sanitize_address=false)

# the options that the pipeline of a Julia version has; the others keep their defaults,
# which is what that version's pipeline does
function pipeline_option_names(minor::VersionNumber)
    minor == v"1.10" && return (:lower_intrinsics, :dump_native, :external_use, :llvm_only)
    names = (:lower_intrinsics, :dump_native, :external_use, :llvm_only, :always_inline,
             :enable_early_simplifications, :enable_early_optimizations,
             :enable_scalar_optimizations, :enable_loop_optimizations,
             :enable_vector_pipeline, :remove_ni, :cleanup, :warn_missed_transformations)
    minor <= v"1.13" && return names
    return (names..., :sanitize_memory, :sanitize_thread, :sanitize_address)
end

"""
    JuliaIR.JuliaPipeline(; level=2, ports=true, options...)

The optimization pipeline of the running Julia (what its `julia<level=...;...>` pipeline
element builds), at optimization level `level` (0 to 3; other values are clamped, like
Julia does), with Julia's passes replaced by this package's ports (`ports=true`), or named
by their C++ names (`ports=false`, which only works on Julia's own LLVM).

The other keyword arguments are the options of Julia's pipeline (`OptimizationOptions` in
Julia's `src/jitlayers.h`), which Julia 1.10 has four of and later versions more:

- `lower_intrinsics` (`true`): lower Julia's intrinsics (GC, exception handling, ...);
- `dump_native` (`false`): optimize for a system image or package image, which
  multiversions functions for several targets and accesses thread-local state through the
  image;
- `external_use` (`false`): with `dump_native`, the image is used externally;
- `llvm_only` (`false`): leave out Julia's passes;
- from Julia 1.11 on, `always_inline`, `enable_early_simplifications`,
  `enable_early_optimizations`, `enable_scalar_optimizations`,
  `enable_loop_optimizations`, `enable_vector_pipeline`, `remove_ni`, `cleanup` (`true`):
  run the corresponding stage (the stage's start and end markers always run), and
  `warn_missed_transformations` (`false`);
- from Julia 1.14 on, `sanitize_memory`, `sanitize_thread`, `sanitize_address` (`false`),
  which must be `false`: only stock Julia builds are supported.

Options that the running Julia's pipeline doesn't have are rejected, as is turning off
`remove_ni` while lowering intrinsics (an assertion in Julia's C++).

See [`JuliaIR.build_pipeline!`](@ref) to build the pipeline, and
[`JuliaIR.optimize!`](@ref) to run it like Julia does.
"""
struct JuliaPipeline
    "The minor version of the Julia whose dialect and recipe this is (the newest known
    one for a newer Julia)."
    minor::VersionNumber
    "The optimization level, 0 to 3."
    level::Int
    "Whether Julia's passes are this package's ports, or Julia's C++ passes."
    ports::Bool
    "The options, as in `PIPELINE_OPTIONS`."
    options::typeof(PIPELINE_OPTIONS)
end

function JuliaPipeline(; level::Integer=2, ports::Bool=true, options...)
    minor = dialect_minor(VERSION)
    known = pipeline_option_names(minor)
    for (name, value) in pairs(options)
        haskey(PIPELINE_OPTIONS, name) || name in known ||
            throw(ArgumentError("unknown option $name of Julia's pipeline"))
        name in known ||
            throw(ArgumentError("Julia $(minor)'s pipeline has no option $name"))
        value isa Bool ||
            throw(ArgumentError("option $name of Julia's pipeline must be a Bool"))
    end
    opts = merge(PIPELINE_OPTIONS, values(options))
    for name in (:sanitize_memory, :sanitize_thread, :sanitize_address)
        opts[name] &&
            throw(ArgumentError("option $name is not supported: only stock Julia builds are"))
    end
    opts.lower_intrinsics && !opts.remove_ni &&
        throw(ArgumentError("option remove_ni can't be turned off while lowering intrinsics"))
    return JuliaPipeline(minor, clamp(level, 0, 3), ports, opts)
end

"""
    JuliaIR.parse_pipeline_options(str) -> NamedTuple

Parse the options of Julia's `julia<...>` pipeline element (the text between `<` and `>`,
e.g. `level=3;no_always_inline`) into the keyword arguments of
[`JuliaIR.JuliaPipeline`](@ref). Options are separated by `;` and turned off with `no_`,
like Julia does. Unlike Julia (whose release builds ignore them), unknown options and a
level that isn't an integer are rejected.
"""
function parse_pipeline_options(str::AbstractString)
    known = pipeline_option_names(dialect_minor(VERSION))
    parsed = Pair{Symbol,Any}[]
    for opt in split(str, ';'; keepempty=false)
        if startswith(opt, "level=")
            level = tryparse(Int, opt[7:end])
            level === nothing &&
                throw(ArgumentError("level of Julia's pipeline must be an integer, got $(opt[7:end])"))
            push!(parsed, :level => level)
            continue
        end
        enable = !startswith(opt, "no_")
        name = Symbol(enable ? opt : opt[4:end])
        name in known || throw(ArgumentError("unknown option $opt of Julia's pipeline"))
        push!(parsed, name => enable)
    end
    return NamedTuple(parsed)
end

JuliaPipeline(str::AbstractString; ports::Bool=true) =
    JuliaPipeline(; ports, parse_pipeline_options(str)...)


## the passes in a recipe

# The recipe of a Julia version's pipeline, `Recipe{minor}` for Julia 1.minor. A Julia
# newer than the newest known dialect uses that dialect's recipe.
struct Recipe{minor} end

recipe(p::JuliaPipeline) = Recipe{Int(p.minor.minor)}()

# Ports of Julia's passes that this package doesn't define yet, by the ports' names, which
# the recipes use, to the names of Julia's C++ passes that run in their place (only
# available on Julia's own LLVM). Every pass of the pipelines up to Julia 1.15 is ported;
# a pass that a newer Julia adds can be named here until its port lands.
const CPP_FALLBACKS = Dict{String,String}()

# The pipeline text of one of Julia's passes, by the name of its port, with options
# written like in Julia's pipeline (which are the same for the ports): the port, or
# Julia's C++ pass when the pipeline doesn't use the ports or the port doesn't exist yet.
function julia_pass(p::JuliaPipeline, name::String; options...)
    i = findfirst(def -> def.name == name, PASSES)
    cpp = i === nothing ? get(CPP_FALLBACKS, name, nothing) : PASSES[i].cpp_name
    cpp === nothing && error("$name is neither a pass of this package nor one of its fallbacks")
    pass = p.ports && i !== nothing ? name : cpp
    isempty(options) && return pass
    opts = [v ? string(k) : "no-$k" for (k, v) in pairs(options)]
    return pass * "<" * join(opts, ";") * ">"
end

# add one of Julia's passes (`JULIA_PASS` in `pipeline.cpp`), unless the pipeline leaves
# them out (`llvm_only`; Julia's loop passes and RemoveJuliaAddrspaces are not among them,
# and are added with `add!` instead)
function julia_pass!(pm, p::JuliaPipeline, name::String; options...)
    p.options.llvm_only || add!(pm, julia_pass(p, name; options...))
    return pm
end


## spelling of LLVM's passes
#
# What the C++ constructors of Julia's pipeline mean, as pipeline text on the LLVM that is
# loaded. Where a version's `pipeline.cpp` predates that LLVM, its passes keep the meaning
# they had on its own LLVM.

# `SROAPass(SROAOptions::PreserveCFG)`, and `SROAPass()` on LLVM 15, which only has that
# mode (Julia 1.10's pipeline uses the latter on any LLVM)
sroa_preserve_cfg() = LLVM.version() < v"16" ? SROAPass() : SROAPass(; preserve_cfg=true)

# `SROAPass(SROAOptions::ModifyCFG)` (LLVM 16 and later, as are the versions that use it)
sroa_modify_cfg() = SROAPass(; modify_cfg=true)

# `SimplifyCFGPass(basicSimplifyCFGOptions())`
basic_simplifycfg() = SimplifyCFGPass(; forward_switch_cond=true, switch_range_to_icmp=true,
                                      switch_to_lookup=true)

# `GlobalsAA`, required by Julia 1.11 to 1.13
const REQUIRE_GLOBALS_AA = "require<globals-aa>"

# `InferAlignmentPass()`
const INFER_ALIGNMENT = "infer-alignment"


## markers
#
# Julia's pipeline brackets each stage by marker passes, which do nothing but make the
# stages visible to LLVM's instrumentation, e.g. `-print-before=BeforeLICM`. Julia names
# them in its instrumentation only, so they can't be used in a pipeline; this package
# registers them as passes of the same names.

const MODULE_MARKERS = ("BeforeOptimization", "BeforeEarlySimplification",
                        "AfterEarlySimplification", "BeforeEarlyOptimization",
                        "AfterEarlyOptimization", "BeforeIntrinsicLowering",
                        "AfterIntrinsicLowering", "BeforeCleanup", "AfterCleanup",
                        "AfterOptimization")
const FUNCTION_MARKERS = ("BeforeLoopOptimization", "AfterLoopOptimization",
                          "BeforeScalarOptimization", "AfterScalarOptimization",
                          "BeforeVectorization", "AfterVectorization")
const LOOP_MARKERS = ("BeforeLICM", "AfterLICM", "BeforeLoopSimplification",
                      "AfterLoopSimplification")

function marker_passes()
    markers = LLVM.CustomPass[]
    for name in MODULE_MARKERS
        push!(markers, ModulePass(name, mod -> false; required=true))
    end
    for name in FUNCTION_MARKERS
        push!(markers, FunctionPass(name, f -> false; required=true))
    end
    for name in LOOP_MARKERS
        push!(markers, LoopPass(name, (loop, ar) -> PreservedAnalyses(AllAnalyses);
                                required=true))
    end
    return markers
end


## IRCE with cleanup
#
# Julia 1.14 runs IRCE through a pass of its pipeline (`IRCEWithCleanupPass`, not
# registered under a name) that cleans up after it with SimplifyCFG and InstCombine, but
# only if it changed the function.

function irce_with_cleanup!(f::LLVM.Function, am, opts::PassOptions)
    preserved = run!(IRCEPass(), f, am)
    preserved == PreservedAnalyses(AllAnalyses) && return preserved
    @dispose pb=PassBuilder() begin
        add!(pb, basic_simplifycfg())
        add!(pb, InstCombinePass())
        return intersect(preserved, run!(pb, f, am))
    end
end

const IRCE_WITH_CLEANUP = define_pass("jl-irce-with-cleanup", :function,
                                      irce_with_cleanup!; required=false, cpp_name="")


## building the pipeline

"""
    JuliaIR.build_pipeline!(pm, p::JuliaPipeline)
    JuliaIR.build_pipeline!(pm; level=2, ports=true, options...)

Add the passes of Julia's optimization pipeline `p` (see [`JuliaIR.JuliaPipeline`](@ref)
for the keyword arguments) to a module pass manager or a pass builder `pm`, which needs
this package's passes to be registered (see [`JuliaIR.register!`](@ref)).

The pipeline is built in stages, which are available on their own (an experimental API):
`early_simplification!`, `early_optimization!`, `intrinsic_lowering!` and `cleanup!` add
to a module pass manager, `loop_optimization!`, `scalar_optimization!` and
`vectorization!` to a function pass manager, each `(pm, p::JuliaPipeline)`.
"""
function build_pipeline!(pm, p::JuliaPipeline, r::Recipe=recipe(p))
    add!(pm, "BeforeOptimization")
    early_simplification!(pm, p, r)
    p.options.always_inline && add!(pm, AlwaysInlinerPass())
    early_optimization!(pm, p, r)
    add!(pm, FunctionPassManager()) do fpm
        loop_optimization!(fpm, p, r)
        scalar_optimization!(fpm, p, r)
        p.level >= 2 && vectorization!(fpm, p, r)
        p.options.warn_missed_transformations && add!(fpm, WarnMissedTransformationsPass())
    end
    intrinsic_lowering!(pm, p, r)
    cleanup!(pm, p, r)
    add!(pm, "AfterOptimization")
    return pm
end

build_pipeline!(pm; kwargs...) = build_pipeline!(pm, JuliaPipeline(; kwargs...))

for stage in (:early_simplification!, :early_optimization!, :loop_optimization!,
              :scalar_optimization!, :vectorization!, :intrinsic_lowering!, :cleanup!)
    @eval $stage(pm, p::JuliaPipeline) = $stage(pm, p, recipe(p))
end

"""
    JuliaIR.pipeline(p::JuliaPipeline) -> String
    JuliaIR.pipeline(; level=2, ports=true, options...) -> String

The text of Julia's optimization pipeline `p` (see [`JuliaIR.JuliaPipeline`](@ref) for the
keyword arguments), for a pass builder with this package's passes registered.

The text doesn't say which alias analyses the passes use, which Julia chooses by the
optimization level (see [`JuliaIR.alias_analyses!`](@ref)).
"""
function pipeline(p::JuliaPipeline)
    mpm = ModulePassManager()
    build_pipeline!(mpm, p)
    return join(mpm.passes, ",")
end

pipeline(; kwargs...) = pipeline(JuliaPipeline(; kwargs...))

"""
    JuliaIR.alias_analyses!(pb::PassBuilder, level)

Make the passes of `pb` use the alias analyses that Julia uses at optimization level
`level`: none of LLVM's below level 2, and LLVM's basic, scoped no-alias and type-based
ones from level 2 on, followed by those of the target machine in both cases.
"""
function alias_analyses!(pb::PassBuilder, level::Integer)
    add!(pb, AAManager()) do aam
        if level >= 2
            add!(aam, BasicAA())
            add!(aam, ScopedNoAliasAA())
            add!(aam, TypeBasedAA())
        end
        add!(aam, TargetAA())
    end
    return pb
end

"""
    JuliaIR.optimize!(mod::LLVM.Module, [tm::TargetMachine]; level=2, ports=true, options...)

Optimize `mod` like Julia does, with its optimization pipeline (see
[`JuliaIR.JuliaPipeline`](@ref) for the keyword arguments) and its choice of alias
analyses, for the target machine `tm`.
"""
function optimize!(mod::LLVM.Module, tm::Union{Nothing,LLVM.TargetMachine}=nothing; kwargs...)
    p = JuliaPipeline(; kwargs...)
    @dispose pb=PassBuilder() begin
        register!(pb)
        alias_analyses!(pb, p.level)
        build_pipeline!(pb, p)
        run!(pb, mod, tm)
    end
    return mod
end


## Julia's pipeline element in pipeline text

# split pipeline text into its elements at the top level, e.g. `a,function(b,c),d<x,y>`
# into `a`, `function(b,c)`, `d<x,y>`
function split_pipeline(text::AbstractString)
    elements = String[]
    depth = 0
    start = firstindex(text)
    for i in eachindex(text)
        c = text[i]
        if c in ('(', '<')
            depth += 1
        elseif c in (')', '>')
            depth -= 1
        elseif c == ',' && depth == 0
            push!(elements, text[start:prevind(text, i)])
            start = nextind(text, i)
        end
    end
    push!(elements, text[start:end])
    return elements
end

"""
    JuliaIR.expand_julia_pipeline(text; ports=true) -> String

Replace the `julia` and `julia<...>` elements of the module pipeline `text` (also in nested
`module(...)` managers) by the text of the pipelines they stand for (see
[`JuliaIR.JuliaPipeline`](@ref)).
"""
function expand_julia_pipeline(text::AbstractString; ports::Bool=true)
    elements = map(split_pipeline(text)) do element
        if (m = match(r"^julia(?:<(.*)>)?$", element)) !== nothing
            pipeline(JuliaPipeline(something(m[1], ""); ports))
        elseif (m = match(r"^module\((.*)\)$", element)) !== nothing
            "module(" * expand_julia_pipeline(m[1]; ports) * ")"
        else
            element
        end
    end
    return join(elements, ",")
end
