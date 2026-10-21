# Verify Julia-generated IR through the full ported pipeline on the selected LLVM.
# Generate the corpus with the same Julia version that runs this script.
#
#   julia --project=test test/compatibility/run.jl CORPUS...

module CompatibilityHarness

using JuliaIR, LLVM, LLVM.IR, LLVM.Passes

function input_files(paths)
    files = String[]
    for path in paths
        if isdir(path)
            for (dir, _, names) in walkdir(path), name in names
                endswith(name, ".ll") && push!(files, joinpath(dir, name))
            end
        elseif isfile(path) && endswith(path, ".ll")
            push!(files, path)
        else
            throw(ArgumentError("expected an LLVM IR file or corpus directory: $path"))
        end
    end
    sort!(unique!(files))
    isempty(files) && throw(ArgumentError("no LLVM IR modules found"))
    return files
end

function source_layout(ir::String)
    m = match(r"(?m)^target datalayout = \"([^\"]*)\"", ir)
    m === nothing && throw(ArgumentError("corpus module has no source data layout"))
    return m[1]
end

function check_pipeline(ir::String, level::Int)
    layout = source_layout(ir)
    @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, ir) begin
        # Parsing with another LLVM can upgrade the layout. Keep the ABI used by Julia
        # when it generated the module, as an IR consumer such as GPUCompiler must do.
        mod.datalayout = layout
        verify(mod)
        JuliaIR.optimize!(mod; level)
        verify(mod)
    end
    return nothing
end

function run_corpus(paths; levels=0:3, io::IO=stdout)
    levels = collect(levels)
    isempty(levels) && throw(ArgumentError("at least one optimization level is required"))
    all(level -> level in 0:3, levels) || throw(ArgumentError("levels must be in 0:3"))
    files = input_files(paths)
    passed = failed = 0
    println(io, "Julia $VERSION, LLVM $(LLVM.version()): $(length(files)) modules")
    for file in files, level in levels
        # Flush before entering LLVM so an abort or timeout identifies the last case.
        println(io, "checking $file at level $level")
        flush(io)
        try
            check_pipeline(read(file, String), level)
            passed += 1
        catch err
            err isa InterruptException && rethrow()
            failed += 1
            println(io, "FAIL: ", sprint(showerror, err))
        end
    end
    println(io, "$(passed + failed) pipelines: $passed passed, $failed failed")
    return (; modules=length(files), passed, failed)
end

function main(args)
    isempty(args) && throw(ArgumentError("usage: run.jl CORPUS..."))
    return run_corpus(args).failed == 0
end

end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && exit(CompatibilityHarness.main(ARGS) ? 0 : 1)
