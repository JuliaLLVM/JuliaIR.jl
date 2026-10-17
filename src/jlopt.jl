# jlopt: an `opt`-compatible driver for the passes of this package, so that lit tests
# written for `opt` (including Julia's own test/llvmpasses) can run them.

"""
    JuliaIR.JloptError(msg)

A usage error of [`JuliaIR.jlopt`](@ref), e.g. an unknown command-line option.
"""
struct JloptError <: Exception
    msg::String
end
Base.showerror(io::IO, e::JloptError) = print(io, "jlopt: ", e.msg)

# Julia's pass names in pipelines of the legacy pass manager (`opt -enable-new-pm=0
# -AllocOpt ...`, used by Julia 1.10's tests), and the kind of pass in the new one.
const LEGACY_PASSES = Dict(
    "AllocOpt" => :function,
    "CombineMulAdd" => :function,
    "CPUFeatures" => :module,
    "dce" => :function,
    "DemoteFloat16" => :function,
    "FinalLowerGC" => :module,
    "GCInvariantVerifier" => :function,
    "JuliaLICM" => :loop,
    "JuliaMultiVersioning" => :module,
    "LateLowerGCFrame" => :function,
    "LowerExcHandlers" => :function,
    "LowerPTLSPass" => :module,
    "LowerSIMDLoop" => :loop,
    "PropagateJuliaAddrspaces" => :function,
    "RemoveJuliaAddrspaces" => :module,
    "RemoveNI" => :module,
    "simplifycfg" => :function,
)

# translate a sequence of legacy pass names into a new pass manager pipeline, nesting
# function and loop passes the way the legacy pass manager runs them
function legacy_pipeline(names::Vector{String})
    elements = String[]
    fn = String[]      # pending function passes
    loop = String[]    # pending loop passes, run inside a function pass manager
    function flush_loop!()
        isempty(loop) || push!(fn, "loop(" * join(loop, ",") * ")")
        empty!(loop)
    end
    function flush_function!()
        flush_loop!()
        isempty(fn) || push!(elements, "function(" * join(fn, ",") * ")")
        empty!(fn)
    end
    for name in names
        kind = get(LEGACY_PASSES, name, nothing)
        kind === nothing && throw(JloptError("unknown legacy pass -$name"))
        if kind === :module
            flush_function!()
            push!(elements, name)
        elseif kind === :function
            flush_loop!()
            push!(fn, name)
        else
            push!(loop, name)
        end
    end
    flush_function!()
    return join(elements, ",")
end

# replace the names of Julia's C++ passes that this package ports by the names of the
# ports, keeping their options (`GCInvariantVerifier<strong>` -> `jl-...<strong>`)
function map_pipeline(pipeline::AbstractString, mapping::Dict{String,String})
    return replace(pipeline, r"[A-Za-z0-9_.-]+" => function (name)
        get(mapping, name, name)
    end)
end

cpp_mapping() = Dict(def.cpp_name => def.name for def in PASSES if !isempty(def.cpp_name))

# raise an error that `opt` would report as a crash, for `not --crash` tests
struct FatalPassError <: Exception
    ex::Any
end

Base.@kwdef mutable struct JloptOptions
    pipeline::Union{Nothing,String} = nothing
    legacy::Vector{String} = String[]
    new_pm::Bool = true
    text::Bool = false
    output::String = "-"
    input::Union{Nothing,String} = nothing
    triple::Union{Nothing,String} = nothing
    julia::VersionNumber = VERSION
    map_passes::Bool = true
    llvm_options::Vector{String} = String[]
end

const JLOPT_USAGE = """
    usage: jlopt [options] [input]

    Runs a pipeline of LLVM passes, including the passes of JuliaIR, on the module in
    `input` (textual IR or bitcode; `-` or nothing for stdin), like LLVM's `opt`. The
    names of Julia's C++ passes that JuliaIR ports are replaced by the ports'.

      -passes=PIPELINE, --passes=PIPELINE, -p PIPELINE
                                the pipeline, in the syntax of the new pass manager
      -S                        write textual IR instead of bitcode
      -o FILE                   write the output to FILE (default: stdout)
      -mtriple=TRIPLE           override the module's target triple
      -julia=VERSION            the Julia dialect of the input for JuliaIR's passes
                                (default: \$JULIAIR_JULIA, or the running Julia's version)
      -map-julia-passes=0       don't replace Julia's C++ passes by the ports
      -verify-memoryssa         verify MemorySSA after every update (LLVM option)
      -enable-new-pm=0, -PASS   run the passes in a legacy pass manager pipeline
                                (translated into the new pass manager's syntax)
      --opaque-pointers=1       accepted; =0 is an error (opaque pointers only)
      --load-pass-plugin=libjulia-codegen*, -load libjulia-codegen*
                                accepted and ignored: Julia's passes are always available
                                when running on Julia's LLVM
    """

function parse_jlopt_args(args::Vector{String})
    opts = JloptOptions()
    opts.julia = let v = get(ENV, "JULIAIR_JULIA", "")
        isempty(v) ? VERSION : parse_julia_version(v)
    end
    i = 1
    # the next argument, as the value of option `arg`
    function value!(arg)
        i += 1
        i <= length(args) || throw(JloptError("missing value for $arg"))
        return args[i]
    end
    plugin(name) = startswith(basename(name), "libjulia-codegen") ||
        throw(JloptError("cannot load plugin $name: only Julia's own passes are available"))
    while i <= length(args)
        arg = args[i]
        if (m = match(r"^--?passes=(.*)$", arg)) !== nothing
            opts.pipeline = m[1]
        elseif arg == "-p" || arg == "--passes" || arg == "-passes"
            opts.pipeline = value!(arg)
        elseif arg == "-S"
            opts.text = true
        elseif arg == "-o"
            opts.output = value!(arg)
        elseif (m = match(r"^-o(.+)$", arg)) !== nothing
            opts.output = m[1]
        elseif (m = match(r"^--?mtriple=(.*)$", arg)) !== nothing
            opts.triple = m[1]
        elseif (m = match(r"^--?julia=(.*)$", arg)) !== nothing
            opts.julia = parse_julia_version(m[1])
        elseif (m = match(r"^--?map-julia-passes=([01])$", arg)) !== nothing
            opts.map_passes = m[1] == "1"
        elseif arg in ("-verify-memoryssa", "--verify-memoryssa")
            push!(opts.llvm_options, "-verify-memoryssa")
        elseif (m = match(r"^--?enable-new-pm=([01])$", arg)) !== nothing
            opts.new_pm = m[1] == "1"
        elseif (m = match(r"^--?opaque-pointers=([01])$", arg)) !== nothing
            m[1] == "1" || throw(JloptError("typed pointers are not supported"))
        elseif (m = match(r"^--load-pass-plugin=(.*)$", arg)) !== nothing
            plugin(m[1])
        elseif arg == "--load-pass-plugin" || arg == "-load" || arg == "--load"
            plugin(value!(arg))
        elseif (m = match(r"^--?load=(.*)$", arg)) !== nothing
            plugin(m[1])
        elseif arg == "-h" || arg == "--help"
            throw(JloptError(JLOPT_USAGE))
        elseif arg == "-"
            opts.input === nothing || throw(JloptError("more than one input file"))
            opts.input = arg
        elseif (m = match(r"^-([A-Za-z][A-Za-z0-9]*)$", arg)) !== nothing &&
               haskey(LEGACY_PASSES, m[1])
            push!(opts.legacy, m[1])
        elseif startswith(arg, "-")
            throw(JloptError("unknown option $arg"))
        else
            opts.input === nothing || throw(JloptError("more than one input file"))
            opts.input = arg
        end
        i += 1
    end
    if !isempty(opts.legacy)
        opts.new_pm && throw(JloptError("legacy pass names require -enable-new-pm=0"))
        opts.pipeline === nothing ||
            throw(JloptError("-passes cannot be combined with legacy pass names"))
        opts.pipeline = legacy_pipeline(opts.legacy)
    end
    return opts
end

# parse the input like `opt` does, which names the module after the input file
function parse_input(data::Vector{UInt8}, name::String)
    bitcode = length(data) >= 4 && (data[1:4] == b"BC\xc0\xde" || data[1:4] == b"\xde\xc0\x17\x0b")
    text = bitcode ? "" : String(copy(data))
    mod = try
        bitcode ? parse(LLVM.Module, data) : parse(LLVM.Module, text)
    catch err
        err isa LLVMException || rethrow()
        throw(JloptError("$name: $(err.info)"))
    end
    mod.name = name
    if !bitcode && !occursin(r"^source_filename"m, text)
        API.LLVMSetSourceFileName(mod, name, length(name))
    end
    return mod
end

"""
    JuliaIR.jlopt(args::Vector{String}; stdin=stdin, stdout=stdout)

Run the `jlopt` driver in this process: parse the module from the input named in `args`
(or read from `stdin`), run the pipeline, and write the result to `stdout` or the file
named by `-o`. Throws a [`JuliaIR.JloptError`](@ref) for usage errors, and the
exception of a failing pass otherwise. See `bin/jlopt --help` for the options.
"""
function jlopt(args::Vector{String}; stdin::IO=stdin, stdout::IO=stdout)
    opts = parse_jlopt_args(args)
    opts.pipeline === nothing && throw(JloptError("no pipeline given; use -passes=..."))
    pipeline = opts.map_passes ? map_pipeline(opts.pipeline, cpp_mapping()) : opts.pipeline
    isempty(opts.llvm_options) || LLVM.clopts(opts.llvm_options...)

    input = something(opts.input, "-")
    data = if input == "-"
        read(stdin)
    else
        isfile(input) || throw(JloptError("$input: No such file"))
        read(input)
    end
    name = input == "-" ? "<stdin>" : input

    ledger_write("jlopt", pipeline)
    @dispose ctx=Context(; opaque_pointers=true) begin
        mod = parse_input(data, name)
        try
            opts.triple === nothing || (mod.triple = opts.triple)
            # like opt, refuse broken input, and verify the output
            verify(mod)
            @dispose pb=PassBuilder() begin
                register!(pb; julia=opts.julia)
                add!(pb, pipeline)
                run!(pb, mod)
            end
            verify(mod)
            write_output(mod, opts, stdout)
        finally
            dispose(mod)
        end
    end
    return
end

function write_output(mod::LLVM.Module, opts::JloptOptions, stdout::IO)
    function emit(io)
        if opts.text
            print(io, string(mod))
        else
            write(io, mod)
        end
    end
    if opts.output == "-"
        emit(stdout)
    else
        open(emit, opts.output, "w")
    end
end

# the entry point of bin/jlopt: report errors like `opt` does, and abort (so that
# `not --crash` holds) when a pass found the IR to be invalid
function jlopt_main(args::Vector{String})
    try
        jlopt(args)
        return 0
    catch err
        if err isa JloptError
            showerror(Base.stderr, err)
            println(Base.stderr)
            return 1
        end
        ex = err isa PassException ? err.ex : err
        if ex isa FatalPassError
            showerror(Base.stderr, ex.ex)
            println(Base.stderr)
            flush(Base.stderr)
            ccall(:abort, Cvoid, ())
        end
        print(Base.stderr, "jlopt: ")
        showerror(Base.stderr, err, catch_backtrace())
        println(Base.stderr)
        return 1
    end
end
