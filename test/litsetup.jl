# Running lit suites with bin/jlopt standing in for `opt`. Used by runtests.jl for
# test/lit, and by test/upstream/run.jl for Julia's own test/llvmpasses.

using LLVM_utils_unified_jll
using LLVM: LLVM
using JuliaIR: JuliaIR

const JULIAIR_DIR = dirname(@__DIR__)

# Whether LLVM.jl uses Julia's own LLVM, rather than a library selected with its `libLLVM`
# preference (e.g. a newer, standalone LLVM). Only Julia's LLVM has Julia's C++ passes, so
# tests that run them, as references or between ports, need it.
julia_llvm_in_use() = !isdefined(LLVM, :julia_llvm) || getfield(LLVM, :julia_llvm)::Bool

function find_python()
    for name in ("python3", "python")
        path = Sys.which(name)
        path === nothing && continue
        # the Windows Store stub for python.exe exists but doesn't run
        success(ignorestatus(`$path -c "import sys; sys.exit(sys.version_info < (3, 8))"`)) &&
            return path
    end
    return nothing
end

# The command that runs bin/jlopt with the running Julia, using the same flags (so that
# precompiled code is reused) and the active project.
function jlopt_cmd(; julia_cmd::Cmd=Base.julia_cmd(), project::String=Base.active_project())
    jlopt = joinpath(JULIAIR_DIR, "bin", "jlopt")
    return `$julia_cmd --startup-file=no --project=$project $jlopt`
end

# Write a directory with an `opt` (and `jlopt`) that runs bin/jlopt. Not on Windows, where
# lit cannot execute scripts; there, lit.cfg substitutes the command into RUN lines.
function jlopt_bindir(dir::String; kwargs...)
    mkpath(dir)
    Sys.iswindows() && return dir
    line = Base.shell_escape(jlopt_cmd(; kwargs...))
    for name in ("opt", "jlopt")
        path = joinpath(dir, name)
        write(path, "#!/bin/sh\nexec $line \"\$@\"\n")
        chmod(path, 0o755)
    end
    return dir
end

lit_minor(v::VersionNumber) = "$(v.major).$(v.minor)"

# The lit features named `julia-*` that `test/lit` can use: of the Julia versions
# (`julia-1.12`, `julia-ge-1.12`), and `julia-llvm`. A misspelled or unknown one would
# silently skip the RUN lines it gates.
const LIT_JULIA_FEATURES = Set(["julia-llvm"; ["julia-$prefix$(lit_minor(v))" for v in JuliaIR.KNOWN_MINORS
                                               for prefix in ("", "ge-")]])

# the `julia-*` features named in lit test files that aren't known, as `file:line: feature`
function unknown_julia_features(dir::String)
    unknown = String[]
    for file in sort(readdir(dir; join=true))
        endswith(file, ".ll") || continue
        for (i, line) in enumerate(eachline(file))
            occursin(r"\b(RUN|REQUIRES|UNSUPPORTED|XFAIL)\b", line) || continue
            for m in eachmatch(r"(?<![\w.-])julia-[\w.-]*", line)
                m.match in LIT_JULIA_FEATURES ||
                    push!(unknown, "$(basename(file)):$i: $(m.match)")
            end
        end
    end
    return unknown
end

# The LLVM tools that RUN lines use besides `opt` (FileCheck, llvm-dis, ...) and the library
# path they need. They must be of the LLVM that the passes run on: bitcode that a newer LLVM
# writes doesn't load in an older one. LLVM_utils_unified_jll has the tools of Julia's LLVM;
# with another library, `JULIAIR_LLVM_TOOLS` names a directory with the tools of its version
# that find their libraries themselves, without a library path: e.g. the `tools` directory
# of LLVM_full_jll on Linux and macOS, the platforms that standalone libraries are built for.
function llvm_tools()
    if julia_llvm_in_use()
        return (; dir=joinpath(LLVM_utils_unified_jll.artifact_dir, "tools"),
                  libpath=LLVM_utils_unified_jll.LIBPATH_list)
    end
    major = LLVM.version().major
    dir = get(ENV, "JULIAIR_LLVM_TOOLS", "")
    isempty(dir) && error("LLVM.jl uses LLVM $major instead of Julia's LLVM; set JULIAIR_LLVM_TOOLS to a directory with the LLVM tools of that version")
    tool = joinpath(dir, "llvm-dis" * (Sys.iswindows() ? ".exe" : ""))
    version = isfile(tool) ? read(`$tool --version`, String) : ""
    m = match(r"LLVM version (\d+)\.", version)
    m !== nothing && parse(Int, m[1]) == major ||
        error("JULIAIR_LLVM_TOOLS ($dir) doesn't have the tools of LLVM $major")
    return (; dir, libpath=String[])
end

function lit_params(; exec_root::String, bindir::String)
    tools = llvm_tools()
    return Dict(
        "exec_root" => exec_root,
        "bindir" => bindir,
        "toolsdir" => tools.dir,
        "libpath" => join(tools.libpath, Sys.iswindows() ? ';' : ':'),
        "libpath_env" => Sys.iswindows() ? "PATH" :
                         Sys.isapple() ? "DYLD_FALLBACK_LIBRARY_PATH" : "LD_LIBRARY_PATH",
        "shlibext" => "." * Base.Libc.Libdl.dlext,
        "common_cfg" => joinpath(JULIAIR_DIR, "test", "lit", "common.cfg.py"),
        # the library's targets differ per platform (macOS lacks X86, for one)
        "targets" => join(lowercase.(string.(LLVM.backends())), ","),
        "llvm_major" => string(LLVM.version().major),
        "julia_llvm" => julia_llvm_in_use() ? "1" : "0",
        # the passes process the running Julia's IR: its dialect's minor version, and the
        # known ones
        "julia_minor" => lit_minor(JuliaIR.Dialect(VERSION).minor),
        "julia_minors" => join(lit_minor.(JuliaIR.KNOWN_MINORS), ","),
        # for lit's internal shell on Windows, with forward slashes (which Windows accepts,
        # and lit's lexer does not take for escapes)
        "jlopt_cmd" => join(map(arg -> "\"" * replace(arg, '\\' => '/') * "\"",
                                jlopt_cmd().exec), " "),
    )
end

lit_jobs() = parse(Int, get(ENV, "JULIAIR_LIT_JOBS", string(min(Sys.CPU_THREADS, 4))))

"""
    run_lit(paths...; python, params, args=String[]) -> (success, output)

Run lit on the given test directories or files.
"""
function run_lit(paths::String...; python::String, params::Dict, args::Vector{String}=String[])
    litpy = joinpath(LLVM_utils_unified_jll.artifact_dir, "tools", "lit", "lit.py")
    param_args = ["--param=$k=$v" for (k, v) in params]
    # -E -s: ignore PYTHON* variables and user site-packages, but not -I, which would drop
    # lit.py's directory from sys.path: the JLL's lit package is found through it, and
    # without it Python picks up a system-wide lit or none.
    # -B: don't write bytecode of the lit configuration's modules into the source tree
    cmd = `$python -E -s -B $litpy -v -j $(lit_jobs()) $param_args $args $paths`
    output = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout=output, stderr=output))
    return success(proc), String(take!(output))
end
