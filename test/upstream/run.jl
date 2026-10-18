# Run Julia's own pass tests (test/llvmpasses of a JuliaLang/julia checkout) with this
# package's ports, as recorded in manifest.toml next to this file.
#
#   julia --project=test test/upstream/run.jl JULIA_SRC [options]
#
#   --mode A       mode A (the only one so far): the Julia version that is running is
#                  the one of the pin, and the passes run on its own LLVM
#   --cpp          run the fixtures with Julia's C++ passes instead of the ports (except
#                  those testing the code generator): checks jlopt and the harness against
#                  upstream's expectations, independently of the ports
#   --filter RE    only fixtures whose file name matches RE
#   --report       print the coverage of the pin's fixtures as a table, and exit
#   --workdir DIR  where to write the executed suite (default: a temporary directory)
#   --manifest F   use another manifest (for testing the harness)
#
# JULIA_SRC is a git checkout of JuliaLang/julia (test/llvmpasses and test/testhelpers
# suffice) at the commit pinned for the running Julia's minor version, or, for the
# development version, at the commit the running nightly build was built from
# (`Base.GIT_VERSION_INFO.commit`).

module UpstreamHarness

using TOML
using JuliaIR
include(joinpath(@__DIR__, "..", "litsetup.jl"))

const MANIFEST_PATH = joinpath(@__DIR__, "manifest.toml")

const KINDS = ("port", "mixed", "cpu", "emitter", "infra")
const STATUSES = ("run", "skip", "exclude", "override", "derived")
const FIXTURE_KEYS = ("kind", "ports", "status", "missing", "reason", "ref", "patch",
                      "ledger_empty", "cpp", "pins")

struct HarnessError <: Exception
    msg::String
end
Base.showerror(io::IO, e::HarnessError) = print(io, e.msg)


## manifest

function load_manifest(path=MANIFEST_PATH)
    manifest = TOML.parsefile(path)
    for (name, entry) in manifest["fixtures"]
        for key in keys(entry)
            key in FIXTURE_KEYS || throw(HarnessError("$name: unknown key $key in the manifest"))
        end
        entry["kind"] in KINDS || throw(HarnessError("$name: invalid kind $(entry["kind"])"))
        for (minor, overrides) in get(entry, "pins", Dict())
            haskey(manifest["pins"], minor) ||
                throw(HarnessError("$name: unknown pin $minor"))
            for key in keys(overrides)
                key in FIXTURE_KEYS && key != "pins" ||
                    throw(HarnessError("$name: unknown key $key for pin $minor"))
            end
        end
    end
    return manifest
end

# the manifest entry of a fixture for a pin, with the pin's overrides applied
function fixture_entry(manifest, name, minor)
    haskey(manifest["fixtures"], name) ||
        throw(HarnessError("$name is not in the manifest; add it to $MANIFEST_PATH"))
    entry = copy(manifest["fixtures"][name])
    overrides = get(get(entry, "pins", Dict()), minor, Dict())
    delete!(entry, "pins")
    merge!(entry, overrides)
    status = entry["status"]
    status in STATUSES || throw(HarnessError("$name: invalid status $status"))
    if status in ("exclude", "override", "derived")
        haskey(entry, "reason") || throw(HarnessError("$name: status $status needs a reason"))
    elseif status == "skip"
        haskey(entry, "missing") || haskey(entry, "reason") ||
            throw(HarnessError("$name: status skip needs `missing` or a reason"))
    end
    status in ("override", "derived") && !haskey(entry, "patch") &&
        throw(HarnessError("$name: status $status needs a patch"))
    return entry
end

# the names of Julia's passes that are ported
ported_passes() = Set(keys(JuliaIR.cpp_mapping()))


## RUN lines

struct RunLine
    index::Int          # among the RUN lines of the file
    lines::Vector{Int}  # line numbers in the file, for continued lines
    command::String
end

const RUN_RE = r"^\s*(?:;|#|//)+\s*RUN:\s?(.*)$"

function run_lines(text::String)
    runs = RunLine[]
    pending = nothing
    for (i, line) in enumerate(split(text, '\n'))
        m = match(RUN_RE, line)
        m === nothing && continue
        cmd = rstrip(m[1])
        if pending === nothing
            pending = (Int[], String[])
        end
        push!(pending[1], i)
        if endswith(cmd, '\\')
            push!(pending[2], cmd[1:end-1])
        else
            push!(pending[2], cmd)
            push!(runs, RunLine(length(runs) + 1, pending[1], join(pending[2], " ")))
            pending = nothing
        end
    end
    pending === nothing || throw(HarnessError("unterminated RUN line continuation"))
    return runs
end

# split a command into shell words, separating pipes and lists
function shell_words(cmd::AbstractString)
    words = String[]
    word = IOBuffer()
    inword = false
    quote_char = nothing
    i = firstindex(cmd)
    while i <= lastindex(cmd)
        c = cmd[i]
        if quote_char !== nothing
            c == quote_char ? (quote_char = nothing) : print(word, c)
        elseif c == '\'' || c == '"'
            quote_char = c
            inword = true
        elseif isspace(c)
            inword && push!(words, String(take!(word)))
            inword = false
        elseif c in ('|', ';') || (c == '&' && i < lastindex(cmd) && cmd[nextind(cmd, i)] == '&')
            inword && push!(words, String(take!(word)))
            inword = false
            if c == '&' || (c == '|' && i < lastindex(cmd) && cmd[nextind(cmd, i)] == '|')
                push!(words, string(c, c))
                i = nextind(cmd, i)
            else
                push!(words, string(c))
            end
        else
            print(word, c)
            inword = true
        end
        i = nextind(cmd, i)
    end
    inword && push!(words, String(take!(word)))
    return words
end

# the argument lists of the `opt` invocations in a command
function opt_invocations(cmd::AbstractString)
    invocations = Vector{String}[]
    words = shell_words(cmd)
    segment = String[]
    function flush!()
        # skip wrappers: not [--crash], env VAR=value
        i = 1
        while i <= length(segment)
            w = segment[i]
            if w == "not" || w == "--crash" || w == "env" || occursin(r"^[A-Za-z_][A-Za-z0-9_]*=", w)
                i += 1
            else
                break
            end
        end
        if i <= length(segment) && segment[i] == "opt"
            args = String[]
            j = i + 1
            while j <= length(segment)
                w = segment[j]
                if w in ("<", ">", "2>", "&>") || occursin(r"^\d?>&\d$", w)
                    j += w in ("<", ">", "2>", "&>") ? 2 : 1
                    continue
                elseif startswith(w, "2>") || startswith(w, ">") || startswith(w, "<")
                    j += 1
                    continue
                end
                push!(args, w)
                j += 1
            end
            push!(invocations, args)
        end
        empty!(segment)
    end
    for w in words
        if w in ("|", ";", "&&", "||")
            flush!()
        else
            push!(segment, w)
        end
    end
    flush!()
    return invocations
end

# What happens to a RUN line in mode A: `(status, reason, pipelines)`, where pipelines
# are those of its `opt` invocations after mapping Julia's pass names to the ports.
function classify_run(run::RunLine; map_passes::Bool=true)
    occursin(r"--?opaque-pointers=0", run.command) &&
        return (:skip, "typed pointers (S-D1)", String[])
    pipelines = String[]
    for args in opt_invocations(run.command)
        opts = try
            JuliaIR.parse_jlopt_args(args)
        catch err
            err isa JuliaIR.JloptError || rethrow()
            throw(HarnessError("RUN line $(run.index) cannot run with jlopt: $(err.msg)"))
        end
        pipeline = something(opts.pipeline, "")
        map_passes && (pipeline = JuliaIR.map_pipeline(pipeline, JuliaIR.cpp_mapping()))
        push!(pipelines, pipeline)
    end
    return (:run, "", pipelines)
end

ported_names(pipeline) = unique(m.match for m in eachmatch(r"\bjl-[a-z0-9-]+", pipeline))

# keep line numbers, which some checks depend on: disable a RUN line by renaming it
function disable_runs(text::String, runs::Vector{RunLine})
    lines = split(text, '\n')
    for run in runs, i in run.lines
        lines[i] = replace(lines[i], "RUN:" => "RUN-SKIPPED-BY-JULIAIR:"; count=1)
    end
    return join(lines, '\n')
end


## patches

# Apply a unified diff to `text`, exactly: every hunk's context must match at its line.
function apply_patch(text::String, patch::String; name="")
    lines = split(text, '\n')
    out = SubString{String}[]
    pos = 1   # next line of `lines` to copy
    plines = split(patch, '\n')
    i = 1
    while i <= length(plines)
        m = match(r"^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@", plines[i])
        if m === nothing
            i += 1
            continue
        end
        start = parse(Int, m[1])
        count = m[2] === nothing ? 1 : parse(Int, m[2])
        count == 0 && (start += 1)
        start >= pos || throw(HarnessError("$name: overlapping hunks in patch"))
        append!(out, lines[pos:start-1])
        pos = start
        i += 1
        while i <= length(plines) && !startswith(plines[i], "@@")
            l = plines[i]
            if startswith(l, ' ') || startswith(l, '-')
                pos <= length(lines) && lines[pos] == l[2:end] ||
                    throw(HarnessError("$name: patch does not apply at line $pos"))
                startswith(l, ' ') && push!(out, lines[pos])
                pos += 1
            elseif startswith(l, '+')
                push!(out, l[2:end])
            elseif startswith(l, '\\') || isempty(l)
                # "\ No newline at end of file", or the end of the patch
            else
                break
            end
            i += 1
        end
    end
    append!(out, lines[pos:end])
    return join(out, '\n')
end


## the suite

struct Fixture
    name::String
    entry::Dict{String,Any}
    included::Bool          # part of the executed suite
    reason::String          # why not, or what it runs
    runs::Vector{Tuple{RunLine,Symbol,String,Vector{String}}}
    text::String            # what is executed (patched, RUN lines disabled)
    pristine::Union{Nothing,String}  # for overrides: the pristine file, RUN lines disabled
end

function plan_fixture(manifest, src::String, name::String, minor::String; cpp::Bool,
                      manifest_dir::String=@__DIR__)
    entry = fixture_entry(manifest, name, minor)
    status = entry["status"]
    kind = entry["kind"]
    ported = ported_passes()

    # stale entries
    if status == "skip" && haskey(entry, "missing")
        missing = entry["missing"]
        all(in(ported), missing) &&
            throw(HarnessError("$name: skipped for missing ports $(join(missing, ", ")), which exist now; run it"))
    end
    if status in ("run", "override") && kind == "port"
        missing = filter(!in(ported), entry["ports"])
        isempty(missing) ||
            throw(HarnessError("$name: runs, but the ports of $(join(missing, ", ")) do not exist"))
    end

    path = joinpath(src, "test", "llvmpasses", name)
    isfile(path) && (endswith(name, ".ll") || endswith(name, ".jl")) ||
        return Fixture(name, entry, false, "not a test", [], "", nothing)

    included = if cpp
        !haskey(entry, "cpp") && !(kind in ("emitter", "infra"))
    else
        status in ("run", "override", "derived")
    end

    pristine = read(path, String)
    # with Julia's own passes, upstream's expectations hold as they are
    text = status in ("override", "derived") && !cpp ?
        apply_patch(pristine, read(joinpath(manifest_dir, entry["patch"]), String); name) :
        pristine

    function classify(text)
        # local: the closure would otherwise assign the fixture's `runs` below
        local runs = Tuple{RunLine,Symbol,String,Vector{String}}[]
        for run in run_lines(text)
            st, why, pipelines = try
                classify_run(run; map_passes=!cpp)
            catch err
                err isa HarnessError || rethrow()
                # only an error for fixtures that are run
                included && throw(HarnessError("$name: $(err.msg)"))
                (:skip, err.msg, String[])
            end
            push!(runs, (run, st, why, pipelines))
        end
        return runs
    end
    runs = classify(text)

    if !included
        reason = cpp ? "not run with Julia's passes: $(get(entry, "cpp", get(entry, "reason", kind)))" :
                 status == "skip" && haskey(entry, "missing") ?
                    "port missing: $(join(entry["missing"], ", "))" * (haskey(entry, "reason") ? "; $(entry["reason"])" : "") :
                 entry["reason"]
        return Fixture(name, entry, false, reason, runs, "", nothing)
    end

    if status == "derived" && !cpp &&
       !any(r -> any(p -> !isempty(ported_names(p)), r[4]), runs)
        throw(HarnessError("$name: the derived copy runs no port"))
    end

    skipped = [r[1] for r in runs if r[2] == :skip]
    text = disable_runs(text, skipped)
    if length(skipped) == length(runs)
        return Fixture(name, entry, false, "every RUN line skipped", runs, "", nothing)
    end

    pristine_text = nothing
    if status == "override" && !cpp
        pristine_runs = classify(pristine)
        pristine_skipped = [r[1] for r in pristine_runs if r[2] == :skip]
        if length(pristine_skipped) < length(pristine_runs)
            pristine_text = disable_runs(pristine, pristine_skipped)
        end
    end
    return Fixture(name, entry, true, "", runs, text, pristine_text)
end

function lit_config(name::String; ledger_dir::String, cpp::Bool)
    return """
        # generated by JuliaIR's test/upstream/run.jl
        import os
        import lit.formats

        config.name = $(repr(name))
        config.suffixes = ['.ll', '.jl']
        config.excludes = ['Inputs']
        config.test_source_root = os.path.dirname(__file__)
        config.test_exec_root = lit_config.params['exec_root']

        # every test writes its own ledger, which run.jl checks afterwards
        import sys
        sys.path.insert(0, os.path.dirname(lit_config.params['common_cfg']))
        import juliair_lit
        config.test_format = juliair_lit.LedgerShTest($(repr(ledger_dir)))

        exec(open(lit_config.params['common_cfg']).read())
        $(cpp ? "config.environment['JULIAIR_MAP_PASSES'] = '0'" : "")
        """
end

function julia_wrapper(bindir::String)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    path = joinpath(bindir, "julia")
    write(path, "#!/bin/sh\nexec $(Base.shell_escape(julia)) \"\$@\"\n")
    chmod(path, 0o755)
end

const RESULT_RE = r"^(PASS|FAIL|XFAIL|XPASS|UNSUPPORTED|UNRESOLVED|TIMEOUT): .* :: (\S+) \("

function lit_results(output)
    results = Dict{String,String}()
    for line in eachline(IOBuffer(output))
        m = match(RESULT_RE, line)
        m === nothing || (results[m[2]] = m[1])
    end
    return results
end

# The ledger of a test: per process, the pipeline jlopt ran (if it was jlopt) and the
# number of invocations of each pass.
mutable struct LedgerProcess
    pipeline::Union{Nothing,String}
    counts::Dict{String,Int}
end

function read_ledger(path)
    processes = Dict{String,LedgerProcess}()
    isfile(path) || return processes
    for line in eachline(path)
        fields = split(line, '\t')
        length(fields) >= 3 || continue
        process = get!(() -> LedgerProcess(nothing, Dict{String,Int}()), processes, fields[1])
        if fields[2] == "jlopt"
            process.pipeline = fields[3]
        elseif fields[2] == "pass"
            process.counts[fields[3]] = get(process.counts, fields[3], 0) + 1
        end
    end
    return collect(values(processes))
end

# Check that every `opt` invocation of the fixture's RUN lines ran the ports in its
# pipeline: each needs a jlopt process of its own that ran that pipeline and invoked
# those ports.
function check_ledger(f, processes)
    failures = String[]
    used = falses(length(processes))
    empty = get(f.entry, "ledger_empty", String[])
    for (run, status, _, pipelines) in f.runs
        status == :run || continue
        for pipeline in pipelines
            expected = setdiff(ported_names(pipeline), empty)
            isempty(expected) && continue
            i = findfirst(eachindex(processes)) do i
                !used[i] && processes[i].pipeline == pipeline &&
                    all(name -> get(processes[i].counts, name, 0) > 0, expected)
            end
            if i === nothing
                push!(failures, "$(f.name): the ledger shows no run of $(join(expected, ", ")) for RUN line $(run.index) (`$pipeline`)")
            else
                used[i] = true
            end
        end
    end
    return failures
end

# Check that `src` has the fixtures of the running Julia, and return its pin with the
# commit of the fixtures. A pin without a commit (the development version's) takes the
# commit the running Julia was built from (`running_commit`).
function check_pin(manifest, src::String, minor::String;
                   running_commit::AbstractString=Base.GIT_VERSION_INFO.commit)
    haskey(manifest["pins"], minor) ||
        throw(HarnessError("no pin for Julia $minor in the manifest"))
    pin = copy(manifest["pins"][minor])
    if haskey(pin, "commit")
        expected = VersionNumber(pin["julia"])
        VERSION == expected ||
            throw(HarnessError("Julia $VERSION is running, but the fixtures of $(pin["tag"]) are for Julia $expected"))
    else
        isempty(VERSION.prerelease) &&
            throw(HarnessError("Julia $VERSION is running, but the fixtures of Julia $minor are those of a development build"))
        length(running_commit) == 40 ||
            throw(HarnessError("Julia $VERSION doesn't know the commit it was built from"))
        pin["commit"] = String(running_commit)
    end
    head = try
        readchomp(`git -C $src rev-parse HEAD`)
    catch
        throw(HarnessError("$src is not a git checkout of JuliaLang/julia"))
    end
    head == pin["commit"] ||
        throw(HarnessError("$src is at $head, but the fixtures of Julia $VERSION are those of $(pin["commit"]) ($(pin["tag"]))"))
    # the fixtures must be those of the commit
    changes = readchomp(`git -C $src status --porcelain --untracked-files=all -- test/llvmpasses test/testhelpers`)
    isempty(changes) ||
        throw(HarnessError("the fixtures in $src differ from commit $head:\n$changes"))
    return pin
end

function report(fixtures, minor, pin; io=stdout)
    println(io, "## Julia $minor ($(pin["tag"]), $(pin["commit"][1:10]))\n")
    println(io, "| fixture | kind | status | RUN lines | pipelines run | reason |")
    println(io, "|---|---|---|---|---|---|")
    for f in fixtures
        nrun = count(r -> r[2] == :run, f.runs)
        nskip = count(r -> r[2] == :skip, f.runs)
        status = f.included ? f.entry["status"] : f.entry["status"] == "run" ? "skip" : f.entry["status"]
        runs = isempty(f.runs) ? "" : "$nrun run, $nskip skipped"
        pipelines = join(unique(["`$p`" for r in f.runs if r[2] == :run for p in r[4]]), "<br>")
        reason = f.included ? get(f.entry, "reason", "") : f.reason
        skips = unique(r[3] for r in f.runs if r[2] == :skip)
        isempty(skips) || (reason = join(filter(!isempty, [reason; "skipped RUN lines: " * join(skips, ", ")]), "; "))
        println(io, "| $(f.name) | $(f.entry["kind"]) | $status | $runs | $pipelines | $reason |")
    end
end

function main(args)
    src = nothing
    mode = "A"
    cpp = false
    filter_re = nothing
    do_report = false
    workdir = nothing
    manifest_path = MANIFEST_PATH
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--mode"
            mode = args[i += 1]
        elseif arg == "--cpp"
            cpp = true
        elseif arg == "--filter"
            filter_re = Regex(args[i += 1])
        elseif arg == "--report"
            do_report = true
        elseif arg == "--workdir"
            workdir = args[i += 1]
        elseif arg == "--manifest"
            manifest_path = abspath(args[i += 1])
        elseif startswith(arg, "-")
            throw(HarnessError("unknown option $arg"))
        else
            src === nothing || throw(HarnessError("more than one Julia checkout given"))
            src = abspath(arg)
        end
        i += 1
    end
    src === nothing && throw(HarnessError("usage: run.jl JULIA_SRC [--mode A] [--cpp] [--filter RE] [--report] [--workdir DIR]"))
    mode == "A" || throw(HarnessError("mode $mode is not implemented (mode B is item S11)"))

    manifest = load_manifest(manifest_path)
    minor = "$(VERSION.major).$(VERSION.minor)"
    pin = check_pin(manifest, src, minor)

    # the fixtures of the pin's commit (which check_pin verified are checked out)
    names = sort(map(basename, readlines(`git -C $src ls-tree --name-only $(pin["commit"]) test/llvmpasses/`)))
    fixtures = [plan_fixture(manifest, src, name, minor; cpp, manifest_dir=dirname(manifest_path))
                for name in names]
    if do_report
        report(fixtures, minor, pin)
        return 0
    end
    filter_re === nothing || filter!(f -> occursin(filter_re, f.name), fixtures)
    selected = filter(f -> f.included, fixtures)
    println("Julia $VERSION, fixtures of $(pin["tag"]) ($(pin["commit"][1:10])), mode A",
            cpp ? " with Julia's C++ passes" : "", ": running $(length(selected)) of $(length(fixtures)) files")
    for f in fixtures
        f.included || println("  not run: $(f.name): $(f.reason)")
    end
    isempty(selected) && return 0

    python = find_python()
    python === nothing && throw(HarnessError("python3 is required"))
    workdir = workdir === nothing ? mktempdir() : mkpath(abspath(workdir))
    failures = String[]
    unsupported = String[]

    function run_suite(dir, files)
        suite = joinpath(dir, "llvmpasses")
        mkpath(suite)
        cp(joinpath(src, "test", "testhelpers"), joinpath(dir, "testhelpers"); force=true)
        # ledgers are appended to: start from scratch, also in a reused work directory
        ledger_dir = joinpath(dir, "ledger")
        rm(ledger_dir; recursive=true, force=true)
        mkpath(ledger_dir)
        write(joinpath(suite, "lit.cfg.py"), lit_config("Julia-llvmpasses-$minor"; ledger_dir, cpp))
        for (name, text) in files
            write(joinpath(suite, name), text)
        end
        bindir = jlopt_bindir(joinpath(dir, "bin"))
        julia_wrapper(bindir)
        params = lit_params(; exec_root=joinpath(dir, "out"), bindir)
        ok, output = run_lit(suite; python, params)
        return ok, output, lit_results(output), ledger_dir
    end

    ok, output, results, ledger_dir = run_suite(joinpath(workdir, "suite"),
                                                [(f.name, f.text) for f in selected])
    for f in selected
        result = get(results, f.name, "MISSING")
        # tests can require features of the host (`REQUIRES: x86_64`)
        result == "UNSUPPORTED" && (push!(unsupported, f.name); continue)
        if result != "PASS"
            push!(failures, "$(f.name): $result")
            continue
        end
        processes = read_ledger(joinpath(ledger_dir, f.name * ".ledger"))
        if cpp
            ran = unique(name for p in processes for name in keys(p.counts))
            isempty(ran) ||
                push!(failures, "$(f.name): ports ran although Julia's passes were requested: $(join(ran, ", "))")
        else
            append!(failures, check_ledger(f, processes))
        end
    end
    ok && !isempty(failures) && println(output)
    ok || println(output)

    # an override must be needed: the pristine fixture has to fail
    overrides = filter(f -> f.pristine !== nothing, selected)
    if !isempty(overrides)
        _, _, stale_results, _ = run_suite(joinpath(workdir, "pristine"),
                                           [(f.name, f.pristine) for f in overrides])
        for f in overrides
            get(stale_results, f.name, "MISSING") == "PASS" &&
                push!(failures, "$(f.name): the override is stale, the pristine fixture passes")
        end
    end

    failed = unique(first(split(failure, ':')) for failure in failures)
    println("\n$(length(selected) - length(failed) - length(unsupported)) of $(length(selected)) fixtures passed",
            isempty(unsupported) ? "" : ", $(length(unsupported)) unsupported on this host ($(join(unsupported, ", ")))",
            isempty(failures) ? "" : "; failures:")
    for failure in failures
        println("  ", failure)
    end
    return isempty(failures) ? 0 : 1
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    code = try
        UpstreamHarness.main(ARGS)
    catch err
        err isa UpstreamHarness.HarnessError || rethrow()
        println(stderr, "error: ", err.msg)
        2
    end
    exit(code)
end
