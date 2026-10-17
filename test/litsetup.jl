# Running lit suites with bin/jlopt standing in for `opt`. Used by runtests.jl for
# test/lit, and by test/upstream/run.jl for Julia's own test/llvmpasses.

using LLVM_utils_unified_jll

const JULIAIR_DIR = dirname(@__DIR__)

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

function lit_params(; exec_root::String, bindir::String)
    tools = joinpath(LLVM_utils_unified_jll.artifact_dir, "tools")
    return Dict(
        "exec_root" => exec_root,
        "bindir" => bindir,
        "toolsdir" => tools,
        "libpath" => join(LLVM_utils_unified_jll.LIBPATH_list, Sys.iswindows() ? ';' : ':'),
        "libpath_env" => Sys.iswindows() ? "PATH" :
                         Sys.isapple() ? "DYLD_FALLBACK_LIBRARY_PATH" : "LD_LIBRARY_PATH",
        "shlibext" => "." * Base.Libc.Libdl.dlext,
        "common_cfg" => joinpath(JULIAIR_DIR, "test", "lit", "common.cfg.py"),
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
    # -B: don't write bytecode of the lit configuration's modules into the source tree
    cmd = `$python -I -B $litpy -v -j $(lit_jobs()) $param_args $args $paths`
    output = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout=output, stderr=output))
    return success(proc), String(take!(output))
end
