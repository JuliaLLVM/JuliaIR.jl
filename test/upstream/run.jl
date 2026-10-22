# Run Julia's own pass tests (test/llvmpasses of a JuliaLang/julia checkout) with this
# package's ports, as recorded in manifest.toml next to this file.
#
#   julia --project=test test/upstream/run.jl JULIA_SRC [options]
#
# The selected LLVM library determines execution: Julia's bundled LLVM uses the native
# fixtures; a standalone LLVM also applies llvm-compat/llvm<major>/<minor> patches and
# skips RUN lines that need C++ passes without ports.
#
#   --reference          validate pristine fixtures with Julia's C++ passes
#   --reference-llvm OPT validate C++ output after OPT reprints it for another LLVM;
#                        uses FileCheck beside OPT and implies --reference
#   --filter RE   only fixtures whose file name matches RE
#   --report       print the coverage of the pin's fixtures as a table, and exit
#   --workdir DIR  where to write the executed suite (default: a temporary directory)
#   --manifest F   use another manifest (for testing the harness)
#
# JULIA_SRC is a git checkout of JuliaLang/julia (test/llvmpasses and test/testhelpers
# suffice) at the commit pinned for the running Julia's minor version, or, for a pin
# without a commit (a prerelease: master, or a release branch before its first tag), at
# the commit the running nightly build was built from (`Base.GIT_VERSION_INFO.commit`).

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

# The passes that Julia's code generator library registers with LLVM, at any pin (the
# union of their `passes.def`), and Julia's pipeline. A standalone LLVM doesn't have them,
# so standalone runs skip those without a port. Unknown LLVM pass names still fail.
const JULIA_CPP_PASSES = Set([
    "AllocOpt", "CancellationLowering", "CombineMulAdd", "CPUFeatures", "DemoteFloat16",
    "ExpandAtomicModify", "FinalLowerGC", "GCInvariantVerifier", "JuliaLICM",
    "JuliaMultiVersioning", "LateLowerGCFrame", "LowerExcHandlers", "LowerPTLSPass",
    "LowerSIMDLoop", "PropagateJuliaAddrspaces", "RemoveAddrspaces",
    "RemoveJuliaAddrspaces", "RemoveNI", "julia"])

# the names of Julia's C++ passes in a pipeline whose ported passes have been mapped
cpp_only_passes(pipeline) =
    unique(m.match for m in eachmatch(r"[A-Za-z0-9_.-]+", pipeline) if m.match in JULIA_CPP_PASSES)


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

# What happens to a RUN line: `(status, reason, pipelines)`, where pipelines are those of
# its `opt` invocations after mapping Julia's pass names and pipeline to the ports.
# A standalone LLVM does not provide Julia's C++ passes.
#
# `other_llvm` means the selected LLVM differs from the pin's. Julia's pipeline then
# includes different LLVM optimizations, whose output the fixture does not expect.
function classify_run(run::RunLine; map_passes::Bool=true, standalone::Bool=!julia_llvm_in_use(),
                      other_llvm::Bool=false)
    occursin(r"--?opaque-pointers=0", run.command) &&
        return (:skip, "typed pointers are not supported", String[])
    pipelines = String[]
    julia_pipeline = false
    for args in opt_invocations(run.command)
        opts = try
            JuliaIR.parse_jlopt_args(args)
        catch err
            err isa JuliaIR.JloptError || rethrow()
            throw(HarnessError("RUN line $(run.index) cannot run with jlopt: $(err.msg)"))
        end
        pipeline = something(opts.pipeline, "")
        julia_pipeline |= occursin(r"(^|[,(])julia(<|[,)]|$)", pipeline)
        map_passes && (pipeline = JuliaIR.port_pipeline(pipeline))
        push!(pipelines, pipeline)
    end
    if standalone
        cpp = unique(name for pipeline in pipelines for name in cpp_only_passes(pipeline))
        isempty(cpp) ||
            return (:skip, "no port of Julia's $(join(cpp, ", "))", pipelines)
        other_llvm && julia_pipeline &&
            return (:skip, "Julia's pipeline, whose LLVM passes optimize differently on another LLVM", pipelines)
    end
    return (:run, "", pipelines)
end

# A RUN line that checks what `opt` prints on stderr (`print<memoryssa>`, `-print-after`,
# diagnostics). The C++ reference check re-prints only the IR that `opt` writes as output.
checks_stderr(run::RunLine) =
    occursin("2>&1", run.command) && !isempty(opt_invocations(run.command))

# Whether a reference check reprints any checked output. If all RUN lines check stderr,
# they see only the original LLVM's printing, so compatibility patches cannot be validated.
reprints(runs) = any(((run, status, _, _),) -> status == :run && !checks_stderr(run), runs)

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


## patch layers

# Compatibility patches adapt a pin's expectations to another LLVM's IR (see derive.jl).
# `<file>.patch` applies to the pristine fixture. `<file>.after-port.patch` applies after
# a port patch and replaces the pristine variant for that fixture.
layer_dir(manifest_dir, major, minor) =
    joinpath(manifest_dir, "llvm-compat", "llvm$major", minor)

# A path relative to `dir`, written with `/` as in the manifest, on every platform: for
# the report, and for the keys of a layer's patches.
slashed_relpath(path, dir) = replace(relpath(path, dir), '\\' => '/')

const AFTER_PORT = ".after-port.patch"

# Check that every patch of a layer belongs to a fixture of the pin, and the after-port
# variants to fixtures that have a port patch.
function check_layer(manifest, dir, names, minor)
    isdir(dir) || return
    for file in readdir(dir)
        fixture = endswith(file, AFTER_PORT) ? file[1:end-length(AFTER_PORT)] :
                  endswith(file, ".patch") ? file[1:end-length(".patch")] :
                  throw(HarnessError("$(joinpath(dir, file)): not a patch"))
        fixture in names ||
            throw(HarnessError("$(joinpath(dir, file)): no fixture $fixture at this pin"))
        if endswith(file, AFTER_PORT)
            entry = fixture_entry(manifest, fixture, minor)
            entry["status"] in ("override", "derived") ||
                throw(HarnessError("$(joinpath(dir, file)): $fixture has no port patch at this pin"))
        end
    end
end


## the suite

struct Fixture
    name::String
    entry::Dict{String,Any}
    included::Bool          # part of the executed suite
    reason::String          # why not, or what it runs
    runs::Vector{Tuple{RunLine,Symbol,String,Vector{String}}}
    text::String            # what is executed (patched, RUN lines disabled)
    patches::Vector{String} # the patches applied, relative to the manifest
    # per patch layer (:port or :llvm_compat), the fixture without that layer, RUN lines disabled,
    # which must fail: otherwise the layer is stale
    stale::Vector{Pair{Symbol,String}}
end

Fixture(name, entry, reason, runs=[]) =
    Fixture(name, entry, false, reason, runs, "", String[], Pair{Symbol,String}[])

# Select the fixtures for the active library. Reference checks use pristine fixtures
# plus any compatibility layer for the LLVM that reprints their output.
function plan_fixture(manifest, src::String, name::String, minor::String; cpp::Bool,
                      standalone::Bool=!julia_llvm_in_use(), layer::Union{Nothing,String}=nothing,
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
        return Fixture(name, entry, "not a test")

    included = if cpp
        !haskey(entry, "cpp") && !(kind in ("emitter", "infra"))
    else
        status in ("run", "override", "derived")
    end

    # the patch layers: with Julia's own passes, upstream's expectations hold as they are,
    # except for LLVM compatibility patches when reprinting with another LLVM
    rel(file) = slashed_relpath(file, manifest_dir)
    port_patch = status in ("override", "derived") && !cpp ?
                 joinpath(manifest_dir, entry["patch"]) : nothing
    compat = compat_after_port = nothing
    if layer !== nothing
        file = joinpath(layer, name * ".patch")
        isfile(file) && (compat = file)
        file = joinpath(layer, name * AFTER_PORT)
        isfile(file) && !cpp && (compat_after_port = file)
    end
    # A patched fixture needs the compatibility patch derived from that patched input.
    compat_composed = cpp ? compat : port_patch === nothing ? compat : compat_after_port
    patch(text, file) = file === nothing ? text :
        apply_patch(text, read(file, String); name="$name ($(rel(file)))")

    pristine = read(path, String)
    text = patch(patch(pristine, port_patch), compat_composed)
    patches = [rel(file) for file in (port_patch, compat_composed) if file !== nothing]

    function classify(text)
        # local: the closure would otherwise assign the fixture's `runs` below
        local runs = Tuple{RunLine,Symbol,String,Vector{String}}[]
        for run in run_lines(text)
            st, why, pipelines = try
                classify_run(run; map_passes=!cpp, standalone=!cpp && standalone,
                             other_llvm=LLVM.version().major != Base.libllvm_version.major)
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
        return Fixture(name, entry, reason, runs)
    end

    if status == "derived" && !cpp &&
       !any(r -> any(p -> !isempty(ported_names(p)), r[4]), runs)
        throw(HarnessError("$name: the derived copy runs no port"))
    end

    # the RUN lines that can't run, disabled (keeping line numbers, which checks can use)
    function runnable(text, runs=classify(text))
        skipped = [r[1] for r in runs if r[2] == :skip]
        length(skipped) == length(runs) && return nothing
        return disable_runs(text, skipped)
    end
    text = runnable(text, runs)
    if text === nothing
        skips = unique(r[3] for r in runs)
        return Fixture(name, entry, "every RUN line skipped: $(join(skips, ", "))", runs)
    end

    # every layer must still be needed with the others applied: the fixture without it
    # must fail (a derived copy tests something else than the fixture, which may pass too)
    stale = Pair{Symbol,String}[]
    if status == "override" && !cpp
        without = runnable(patch(pristine, standalone ? compat : nothing))
        without === nothing || push!(stale, :port => without)
    end
    if compat_composed !== nothing
        without = runnable(patch(pristine, port_patch))
        without === nothing || push!(stale, :llvm_compat => without)
    end
    return Fixture(name, entry, true, "", runs, text, patches, stale)
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

# The C++ reference check's tools: `opt` runs `jlopt` (from `jlopt_bindir`) and re-prints the
# textual IR it writes, to stdout or to a file, with a newer LLVM's `opt`; `FileCheck`
# is that LLVM's. Bitcode is left as is (a newer LLVM upgrades it when reading it), and
# so is stderr. A crash of jlopt is passed on, for `not --crash`.
function reprint_tools(bindir::String, newer_opt::String)
    opt = Base.shell_escape(newer_opt)
    filecheck = Base.shell_escape(joinpath(dirname(newer_opt), "FileCheck"))
    # the tools of the newer LLVM find their libraries themselves, and must not get those
    # of Julia's LLVM, which lit puts on the library path
    unset = Sys.isapple() ? "DYLD_FALLBACK_LIBRARY_PATH" : "LD_LIBRARY_PATH"
    write(joinpath(bindir, "opt"), """
        #!/bin/bash
        ulimit -c 0
        jlopt=\$(dirname "\$0")/jlopt
        text=0; out=-
        args=("\$@")
        for ((i = 0; i < \${#args[@]}; i++)); do
            case "\${args[i]}" in
                -S) text=1;;
                -o) i=\$((i + 1)); out=\${args[i]};;
                -opaque-pointers*) ;;
                -o*) out=\${args[i]#-o};;
            esac
        done
        [ \$text = 1 ] && [ "\$out" != /dev/null ] || exec "\$jlopt" "\$@"
        tmp=\$(mktemp)
        trap 'rm -f "\$tmp"' EXIT
        # bash reports a crash of jlopt on its own stderr, which isn't jlopt's
        if [ "\$out" = - ]; then
            { "\$jlopt" "\$@" > "\$tmp" 2>&3; } 3>&2 2>/dev/null
        else
            { "\$jlopt" "\$@" 2>&3; } 3>&2 2>/dev/null && cp -- "\$out" "\$tmp"
        fi
        status=\$?
        if [ \$status -ne 0 ]; then
            [ "\$out" = - ] && cat "\$tmp"
            rm -f "\$tmp"
            [ \$status -gt 128 ] && kill -s \$((status - 128)) \$\$
            exit \$status
        fi
        env -u $unset $opt -S "\$tmp" -o "\$out"
        """)
    write(joinpath(bindir, "FileCheck"), """
        #!/bin/sh
        exec env -u $unset $filecheck "\$@"
        """)
    chmod(joinpath(bindir, "opt"), 0o755)
    chmod(joinpath(bindir, "FileCheck"), 0o755)
end

# the major version of an `opt`
function opt_major(opt::String)
    version = try
        readchomp(`$opt --version`)
    catch err
        throw(HarnessError("cannot run $opt: $(sprint(showerror, err))"))
    end
    m = match(r"LLVM version (\d+)\.", version)
    m === nothing && throw(HarnessError("$opt --version doesn't tell the LLVM version"))
    return parse(Int, m[1])
end

# the library LLVM.jl uses, for the report
function library_description()
    version = LLVM.version()
    own = version == Base.libllvm_version && julia_llvm_in_use()
    return own ? "Julia's own LLVM $version" : "a standalone LLVM $version"
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

# The pin (its key in the manifest) whose fixtures and entries a Julia version uses: the
# one of its minor version. A prerelease newer than every pin, like master right after
# its version was bumped, uses the newest pin if that one follows its build's commit, as
# it has the newest pin's dialect too.
function pin_minor(manifest, version::VersionNumber=VERSION)
    minor = "$(version.major).$(version.minor)"
    haskey(manifest["pins"], minor) && return minor
    newest = argmax(VersionNumber, keys(manifest["pins"]))
    if !isempty(version.prerelease) &&
       VersionNumber(version.major, version.minor) > VersionNumber(newest) &&
       !haskey(manifest["pins"][newest], "commit")
        return newest
    end
    throw(HarnessError("no pin for Julia $minor in the manifest"))
end

# Check that `src` has the fixtures of the running Julia, and return its pin with the
# commit of the fixtures. A pin without a commit (one of a prerelease, like master's)
# takes the commit the running Julia was built from (`running_commit`).
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

const USAGE = "usage: run.jl JULIA_SRC [--reference | --reference-llvm OPT] [--filter RE] [--report] [--workdir DIR]"

function main(args; standalone::Bool=!julia_llvm_in_use())
    src = nothing
    cpp = false
    reprint = nothing
    filter_re = nothing
    do_report = false
    workdir = nothing
    manifest_path = MANIFEST_PATH
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--reference"
            cpp = true
        elseif arg == "--reference-llvm"
            cpp = true
            reprint = abspath(args[i += 1])
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
    src === nothing && throw(HarnessError(USAGE))
    cpp && standalone &&
        throw(HarnessError("C++ reference checks require Julia's own LLVM library"))
    reprint === nothing || !Sys.iswindows() ||
        throw(HarnessError("--reference-llvm is not supported on Windows"))

    manifest = load_manifest(manifest_path)
    manifest_dir = dirname(manifest_path)
    minor = pin_minor(manifest)
    pin = check_pin(manifest, src, minor)

    # Select compatibility patches for the standalone library or reference reprinter.
    major = standalone ? LLVM.version().major : reprint !== nothing ? opt_major(reprint) : nothing
    layer = major === nothing ? nothing : layer_dir(manifest_dir, major, minor)
    # the layers are derived for the pin's own LLVM
    if layer !== nothing && get(pin, "llvm", Base.libllvm_version.major) != Base.libllvm_version.major
        throw(HarnessError("Julia $VERSION uses LLVM $(Base.libllvm_version), but the pin of Julia $minor says LLVM $(pin["llvm"]); update the manifest and regenerate the LLVM compatibility patches (derive.jl)"))
    end

    # the fixtures of the pin's commit (which check_pin verified are checked out)
    names = sort(map(basename, readlines(`git -C $src ls-tree --name-only $(pin["commit"]) test/llvmpasses/`)))
    layer === nothing || check_layer(manifest, layer, names, minor)
    fixtures = [plan_fixture(manifest, src, name, minor; cpp, standalone, layer, manifest_dir)
                for name in names]
    if do_report
        report(fixtures, minor, pin)
        return 0
    end
    filter_re === nothing || filter!(f -> occursin(filter_re, f.name), fixtures)
    selected = filter(f -> f.included, fixtures)

    what = if reprint !== nothing
        "the C++ reference check: Julia's C++ passes on LLVM $(Base.libllvm_version), re-printed by LLVM $major ($reprint)"
    elseif cpp
        "native C++ reference check"
    else
        "ports on $(library_description())"
    end
    println("Julia $VERSION, fixtures of $(pin["tag"]) ($(pin["commit"][1:10])), $what: ",
            "running $(length(selected)) of $(length(fixtures)) files")
    layer === nothing ||
        println("  patch layer: ", slashed_relpath(layer, manifest_dir), isdir(layer) ? "" : " (none)")
    for f in selected
        isempty(f.patches) || println("  patched: $(f.name): $(join(f.patches, ", "))")
        if standalone && !cpp
            for (run, status, why, _) in f.runs
                status == :skip && startswith(why, "no port") &&
                    println("  RUN line skipped: $(f.name), RUN line $(run.index): $why")
            end
        end
    end
    for f in fixtures
        f.included || println("  not run: $(f.name): $(f.reason)")
    end
    if reprint !== nothing
        # what the reference check can't re-print, checked against the pin's printing
        for f in selected, (run, status, _, _) in f.runs
            status == :run && checks_stderr(run) &&
                println("  not re-printed: $(f.name), RUN line $(run.index): checks stderr")
        end
        for f in selected
            any(l -> first(l) == :llvm_compat, f.stale) && !reprints(f.runs) &&
                println("  LLVM compatibility patch not validated: $(f.name): every RUN line checks stderr")
        end
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
        reprint === nothing || reprint_tools(bindir, reprint)
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

    # every patch layer must be needed: the fixture without it has to fail
    for (layer_name, dir) in ((:port, "stale-port"), (:llvm_compat, "stale-llvm-compat"))
        stale = [(f, text) for f in selected for (l, text) in f.stale
                 if l == layer_name && !(l == :llvm_compat && reprint !== nothing && !reprints(f.runs))]
        isempty(stale) && continue
        _, _, stale_results, _ = run_suite(joinpath(workdir, dir),
                                           [(f.name, text) for (f, text) in stale])
        for (f, _) in stale
            get(stale_results, f.name, "MISSING") == "PASS" || continue
            push!(failures, layer_name == :port && !standalone ?
                  "$(f.name): the override is stale, the pristine fixture passes" :
                  layer_name == :port ?
                  "$(f.name): the override is stale, the fixture passes with the LLVM compatibility patch alone" :
                  "$(f.name): the LLVM compatibility patch is stale, the fixture passes without it")
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
