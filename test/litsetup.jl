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

# Write a directory with an `opt` that runs bin/jlopt with the running Julia, using the
# same flags (so that precompiled code is reused) and the active project.
function jlopt_bindir(dir::String; julia_cmd::Cmd=Base.julia_cmd(),
                      project::String=Base.active_project())
    mkpath(dir)
    jlopt = joinpath(JULIAIR_DIR, "bin", "jlopt")
    cmd = `$julia_cmd --startup-file=no --project=$project $jlopt`
    if Sys.iswindows()
        line = join(map(arg -> "\"$arg\"", cmd.exec), " ")
        for name in ("opt", "jlopt")
            write(joinpath(dir, "$name.cmd"), "@$line %*\r\n")
        end
    else
        line = Base.shell_escape(cmd)
        for name in ("opt", "jlopt")
            path = joinpath(dir, name)
            write(path, "#!/bin/sh\nexec $line \"\$@\"\n")
            chmod(path, 0o755)
        end
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
    cmd = `$python -I $litpy -v -j $(lit_jobs()) $param_args $args $paths`
    output = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout=output, stderr=output))
    return success(proc), String(take!(output))
end
