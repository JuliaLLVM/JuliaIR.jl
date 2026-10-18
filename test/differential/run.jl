# Differential test of the ports against Julia's C++ passes, on the running Julia's LLVM.
#
#   julia --project=test/differential test/differential/run.jl [options] INPUT...
#
# For each pass in passes.jl and each module in the inputs (`.ll` files, or directories
# searched for them), run the C++ pass and the port on independent copies of the module,
# behind the same C++ prefix pipeline, and compare the results: the IR after normalizing
# local value names, whether it verifies, the errors, and the remarks. Differences that
# exceptions.toml records for the pass are reported as such; any other difference is a
# finding, and makes the run fail.
#
# Options:
#   --pass NAME        only this pass (Julia's name; repeatable)
#   --out DIR          where results, diffs and the worker log go (default: a temp dir)
#   --exceptions FILE  the recorded differences (default: exceptions.toml next to this file)
#   --timeout SECONDS  how long one pass may run on one module (default 300)
#   --quiet            don't print the diffs of unexplained differences
#   --report           only report the results of an earlier run in --out (e.g. after
#                      changing exceptions.toml)
#
# Julia's C++ passes abort the process on some inputs (a verifier rejecting IR, a crash),
# and can hang, so the passes run in a worker process: when it dies or hangs, the
# supervising process records that for the module it was processing and starts a new
# worker, which continues with the next one.

using JuliaIR, LLVM, LLVM.IR, LLVM.Passes, TOML
using LLVM: API

include("passes.jl")

## arguments

Base.@kwdef mutable struct Options
    passes::Vector{String} = String[]
    out::String = ""
    exceptions::String = joinpath(@__DIR__, "exceptions.toml")
    timeout::Float64 = 300
    quiet::Bool = false
    report::Bool = false
    worker::Bool = false
    inputs::Vector{String} = String[]
end

function parse_args(args)
    opts = Options()
    i = 1
    function value!()
        i += 1
        i <= length(args) || error("missing value for $(args[i-1])")
        args[i]
    end
    while i <= length(args)
        arg = args[i]
        if arg == "--pass"
            push!(opts.passes, value!())
        elseif arg == "--out"
            opts.out = value!()
        elseif arg == "--exceptions"
            opts.exceptions = value!()
        elseif arg == "--timeout"
            opts.timeout = parse(Float64, value!())
        elseif arg == "--quiet"
            opts.quiet = true
        elseif arg == "--report"
            opts.report = true
        elseif arg == "--worker"
            opts.worker = true
        elseif startswith(arg, "--")
            error("unknown option $arg")
        else
            push!(opts.inputs, arg)
        end
        i += 1
    end
    isempty(opts.inputs) && error("no inputs given")
    for name in opts.passes
        any(s -> s.name == name, PASS_SPECS) ||
            error("unknown pass $name; known: $(join([s.name for s in PASS_SPECS], ", "))")
    end
    return opts
end


## jobs

struct Input
    id::String      # name in reports and exceptions: <directory name>/<relative path>
    path::String
end

function collect_inputs(paths)
    inputs = Input[]
    for path in paths
        if isfile(path)
            push!(inputs, Input(basename(path), path))
        elseif isdir(path)
            path = rstrip(path, '/')
            for (root, _, files) in walkdir(path), file in sort(files)
                endswith(file, ".ll") || continue
                full = joinpath(root, file)
                push!(inputs, Input(joinpath(basename(path), relpath(full, path)), full))
            end
        else
            error("input $path does not exist")
        end
    end
    sort!(inputs; by=i -> i.id)
end

struct Job
    spec::PassSpec
    input::Input
    prefix::String
    prepare::String
    variant::String
    key::String
end

function collect_jobs(opts)
    inputs = collect_inputs(opts.inputs)
    jobs = Job[]
    skipped = String[]
    for spec in PASS_SPECS
        isempty(opts.passes) || spec.name in opts.passes || continue
        cpp = last(first(pipelines(spec, spec.cpp)))
        if !available(cpp)
            push!(skipped, spec.name)
            continue
        end
        for input in inputs, prefix in spec.prefixes
            pipeline = prefix_pipeline(prefix)
            isempty(pipeline) || available(pipeline) || continue
            for (plabel, _) in spec.prepare, (vlabel, _) in pipelines(spec, spec.cpp)
                key = join([spec.name, input.id, prefix, plabel, vlabel], " | ")
                push!(jobs, Job(spec, input, prefix, plabel, vlabel, key))
            end
        end
    end
    return jobs, skipped
end

# the base name of the files with a job's outputs and their diff
output_name(job::Job) =
    replace(join([job.spec.name, job.input.id, job.prefix, job.prepare, job.variant], "."),
            r"[^A-Za-z0-9_.+-]" => "_", r"\.+" => ".")


## running the passes (worker)

# the module's text with the local names (arguments, blocks, instructions) removed, so
# that LLVM numbers them: differences in naming are not differences in behaviour
function normalized(mod::LLVM.Module)
    for f in LLVM.functions(mod)
        LLVM.isdeclaration(f) && continue
        for arg in LLVM.parameters(f)
            LLVM.name!(arg, "")
        end
        for bb in LLVM.blocks(f)
            LLVM.name!(bb, "")
            for inst in LLVM.instructions(bb)
                LLVM.name!(inst, "")
            end
        end
    end
    return inline_attribute_groups(string(mod))
end

# Attribute groups are numbered in the order LLVM meets them, so a declaration that one
# side adds renumbers the others: refer to each group by its contents instead (which
# makes the `; Function Attrs:` comments redundant).
function inline_attribute_groups(text::String)
    groups = Dict(m[1] => m[2] for m in eachmatch(r"^attributes #(\d+) = \{ (.*) \}$"m, text))
    lines = filter(l -> !startswith(l, "attributes #") && !startswith(l, "; Function Attrs:"),
                   split(text, '\n'))
    return replace(join(lines, '\n'), r"(?<= )#(\d+)(?=[ ,]|$)"m => function (ref)
        group = get(groups, ref[2:end], nothing)
        group === nothing ? ref : "#{ $group }"
    end)
end

# a message on one line, for comparisons and exceptions
one_line(msg, n=2000) = first(join(split(strip(msg), r"\s*\n\s*"), " | "), n)

function error_text(spec::PassSpec, err)
    if err isa LLVM.PassException
        # the backtrace goes to the worker log, the error into the comparison
        showerror(stderr, err)
        println(stderr)
        err = err.ex
    end
    msg = sprint(showerror, err)
    if spec.aborts && err isa JuliaIR.GCInvariantError
        # the C++ prints the same messages, without the header naming the function
        return "! rejected | " * one_line(split(msg, '\n'; limit=2)[end])
    end
    return "! error: " * one_line(msg)
end

# run a pipeline on a copy of `text` (in its own context, so that type names don't clash)
function run_side(spec::PassSpec, text::String, pipeline::String)
    remarks = LLVM.Remark[]
    out = @dispose ctx=Context(; opaque_pointers=true) begin
        mod = parse(LLVM.Module, text)
        tm = JuliaIR.target_machine(mod)
        try
            @dispose pb=PassBuilder(; remarks=r -> push!(remarks, r)) begin
                JuliaIR.register!(pb)
                add!(pb, pipeline)
                tm === nothing ? run!(pb, mod) : run!(pb, mod, tm)
            end
            invalid = try
                verify(mod)
                ""
            catch err
                "\n! invalid IR: " * one_line(sprint(showerror, err), 500)
            end
            normalized(mod) * invalid
        catch err
            error_text(spec, err)
        finally
            tm === nothing || dispose(tm)
            dispose(mod)
        end
    end
    for r in remarks
        r.pass_name in spec.remarks || continue
        out *= "\n! remark $(r.kind) $(r.pass_name) $(r.name) in $(r.function_name): $(r.message)"
    end
    return out
end

# the module after the prefix and the preparation, or a status if there is nothing to
# compare
function prepared_input(job::Job)
    text = read(job.input.path, String)
    @dispose ctx=Context(; opaque_pointers=true) begin
        mod = try
            parse(LLVM.Module, text)
        catch
            return :unparsable
        end
        try
            try
                verify(mod)
            catch
                return :invalid_input
            end
            prefix = prefix_pipeline(job.prefix)
            if !isempty(prefix)
                try
                    tm = JuliaIR.target_machine(mod)
                    @dispose pb=PassBuilder() begin
                        add!(pb, prefix)
                        tm === nothing ? run!(pb, mod) : run!(pb, mod, tm)
                    end
                    tm === nothing || dispose(tm)
                    verify(mod)
                catch
                    return :prefix_failed
                end
            end
            prepare = Dict(job.spec.prepare)[job.prepare]
            prepare(mod)
            return string(mod)
        finally
            dispose(mod)
        end
    end
end

struct Paths
    out::String
    results::String
    inflight::String
    inflight_port::String
    diffs::String
    log::String
end
Paths(out) = Paths(out, joinpath(out, "results.tsv"), joinpath(out, "inflight"),
                   joinpath(out, "inflight.port"), joinpath(out, "diffs"),
                   joinpath(out, "worker.log"))

const MARKER = "##JULIAIR-DIFFERENTIAL"

function mark!(paths::Paths, job::Job, side::String)
    write(paths.inflight, job.key * "\t" * side)
    println(stderr, "\n", MARKER, " ", job.key, " ", side)
    flush(stderr)
end

function unified_diff(a::String, b::String)
    dir = mktempdir()
    fa = joinpath(dir, "cpp"); fb = joinpath(dir, "port")
    write(fa, a * "\n"); write(fb, b * "\n")
    d = read(ignorestatus(`diff -U2 --label C++ --label port $fa $fb`), String)
    rm(dir; recursive=true)
    return d
end

status_only(out) =
    join(["! ok"; filter(l -> startswith(l, "! invalid IR"), split(out, '\n'))], '\n')

function record!(paths::Paths, job::Job, status::Symbol; changed::Bool=false,
                 cpp::String="", port::String="")
    file = ""
    if status === :compared
        # when only one side failed, the other's module is not what differs, but whether
        # it verifies still is
        startswith(cpp, "! ") && !startswith(port, "! ") && (port = status_only(port))
        startswith(port, "! ") && !startswith(cpp, "! ") && (cpp = status_only(cpp))
        if cpp == port
            status = :identical
        else
            status = :different
            file = output_name(job)
            mkpath(paths.diffs)
            write(joinpath(paths.diffs, file * ".cpp.txt"), cpp)
            write(joinpath(paths.diffs, file * ".port.txt"), port)
            write(joinpath(paths.diffs, file * ".diff"), unified_diff(cpp, port))
        end
    end
    open(paths.results, "a") do io
        println(io, join([job.key, status, changed ? "changed" : "", file], '\t'))
    end
end

# process every job without a result, in order
function worker(opts::Options)
    paths = Paths(opts.out)
    # the C++ passes only report remarks that are enabled
    names = unique(vcat([s.remarks for s in PASS_SPECS]...))
    isempty(names) || LLVM.clopts(["-pass-remarks$k=" * join(names, '|')
                                   for k in ("", "-missed", "-analysis")]...)
    jobs, _ = collect_jobs(opts)
    done = Set(first(split(l, '\t')) for l in eachline(paths.results))
    cache = Dict{Tuple{String,String,String},Any}()
    for job in jobs
        job.key in done && continue
        mark!(paths, job, "prefix")
        before = get!(cache, (job.input.id, job.prefix, job.prepare)) do
            prepared_input(job)
        end
        if before isa Symbol
            record!(paths, job, before)
            continue
        end
        if !occursin(job.spec.inputs, before)
            record!(paths, job, :no_input)
            continue
        end
        port_pipe = Dict(pipelines(job.spec, job.spec.port))[job.variant]
        cpp_pipe = Dict(pipelines(job.spec, job.spec.cpp))[job.variant]
        mark!(paths, job, "port")
        port = run_side(job.spec, before, port_pipe)
        write(paths.inflight_port, port)
        local cpp
        for _ in 1:job.spec.cpp_runs
            mark!(paths, job, "cpp")
            cpp = run_side(job.spec, before, cpp_pipe)
            cpp == port && break
        end
        unchanged = @dispose ctx=Context(; opaque_pointers=true) begin
            normalized(parse(LLVM.Module, before))
        end
        record!(paths, job, :compared; changed=(cpp != unchanged), cpp, port)
    end
    rm(paths.inflight; force=true)
    rm(paths.inflight_port; force=true)
    return
end


## supervision

# what the worker printed for a job's side before it died, and the signal that killed it
# (from Julia's report, `[pid] signal 6 (-6): Aborted` or `[pid] signal (6.-6): Aborted`)
function crash_output(paths::Paths, key::String, side::String)
    log = read(paths.log, String)
    marker = "$MARKER $key $side\n"
    i = findlast(marker, log)
    text = i === nothing ? "" : log[last(i)+1:end]
    lines = String[]
    signal = nothing
    for line in split(text, '\n')
        m = match(r"^\[\d+\] signal \(?(\d+)", line)
        if m !== nothing
            signal = parse(Int, m[1])
            push!(lines, "signal $signal")
            break
        end
        push!(lines, line)
    end
    return one_line(join(lines, '\n')), signal
end

function supervise(opts::Options, jobs)
    paths = Paths(opts.out)
    project = dirname(Base.active_project())
    args = ["--worker", "--out", opts.out, "--timeout", string(opts.timeout)]
    for p in opts.passes
        push!(args, "--pass", p)
    end
    append!(args, opts.inputs)
    cmd = `$(Base.julia_cmd()) --project=$project $(@__FILE__) $args`
    # the C++ passes abort on some inputs, and each abort would dump a core of the worker
    Sys.isunix() && (cmd = `sh -c 'ulimit -c 0 && exec "$@"' sh $cmd`)
    byname = Dict(job.key => job for job in jobs)
    while true
        rm(paths.inflight; force=true)
        hung = false
        proc = open(paths.log, "a") do log
            p = run(pipeline(cmd; stdout=log, stderr=log); wait=false)
            while !process_exited(p)
                sleep(0.2)
                if isfile(paths.inflight) && time() - mtime(paths.inflight) > opts.timeout
                    hung = true
                    kill(p, 9)
                    wait(p)
                end
            end
            p
        end
        success(proc) && !hung && break
        isfile(paths.inflight) ||
            error("the worker failed outside of a job; see $(paths.log)")
        key, side = split(read(paths.inflight, String), '\t')
        job = byname[key]
        what, signal = hung ? ("timed out after $(opts.timeout) s", nothing) :
                              crash_output(paths, String(key), String(side))
        # errors of the passes are caught, so an uncaught one is the harness's own
        occursin("ERROR: LoadError", what) &&
            error("the worker failed on $key ($side):\n$what")
        if side == "prefix"
            record!(paths, job, :prefix_failed)
        elseif side == "port"
            record!(paths, job, :compared; changed=true, cpp="! not run",
                    port="! crashed | " * what)
        else
            port = isfile(paths.inflight_port) ? read(paths.inflight_port, String) : ""
            # a verifier rejects input with abort(); any other end is a crash
            if job.spec.aborts && signal == 6
                cpp = "! rejected | " * chopsuffix(what, " | signal 6")
            else
                cpp = "! crashed | " * what
            end
            record!(paths, job, :compared; changed=true, cpp, port)
        end
    end
end


## exceptions and the report

struct Recorded
    pass::String
    glob::String
    input::Regex
    julia::Vector{String}
    prefix::String
    side::String
    lines::Regex
    action::Symbol      # :delete, :replace or :accept
    replacement::String
    reason::String
    decision::String
end

glob_regex(glob) = Regex("^" * join(["\\Q$(part)\\E" for part in split(glob, '*')], ".*") * "\$")

function load_exceptions(file)
    isfile(file) || return Recorded[]
    exceptions = Recorded[]
    for (pass, entries) in TOML.parsefile(file), e in entries
        where = "an entry of $pass in $file"
        for k in keys(e)
            k in ("input", "julia", "prefix", "side", "lines", "replace", "accept", "reason",
                  "decision") || error("unknown key $k in $where")
        end
        all(k -> haskey(e, k), ("side", "reason", "decision")) ||
            error("$where lacks side, reason or decision")
        e["side"] in ("cpp", "port", "both") || error("$where: side must be cpp, port or both")
        haskey(e, "lines") + haskey(e, "accept") == 1 ||
            error("$where needs either lines or accept")
        if haskey(e, "accept")
            e["side"] == "both" && error("$where: accept needs side cpp or port")
            action, pattern, replacement = :accept, e["accept"], ""
        else
            action = haskey(e, "replace") ? :replace : :delete
            pattern, replacement = e["lines"], get(e, "replace", "")
        end
        glob = get(e, "input", "*")
        push!(exceptions, Recorded(pass, glob, glob_regex(glob), get(e, "julia", String[]),
                                   get(e, "prefix", ""), e["side"], Regex(pattern), action,
                                   replacement, e["reason"], e["decision"]))
    end
    return exceptions
end

minor() = "$(VERSION.major).$(VERSION.minor)"

applies(e::Recorded, job::Job) = e.pass == job.spec.name &&
    occursin(e.input, job.input.id) && (isempty(e.julia) || minor() in e.julia) &&
    (isempty(e.prefix) || e.prefix == job.prefix)

# The lines of an output that are compared (blank lines carry nothing), after the rewrites
# of `exceptions` for that side. Returns them and the indices of the exceptions that
# changed a line.
function rewritten(text, side, exceptions)
    lines = filter(l -> !isempty(strip(l)), split(text, '\n'))
    used = Int[]
    for (i, e) in enumerate(exceptions)
        e.action === :accept && continue
        e.side == side || e.side == "both" || continue
        out = String[]
        for line in lines
            if occursin(e.lines, line)
                push!(used, i)
                e.action === :delete && continue
                line = replace(line, e.lines => SubstitutionString(e.replacement))
            end
            push!(out, line)
        end
        lines = out
    end
    return lines, used
end

# Whether the recorded deviations explain the difference of two outputs, which exceptions
# that took, and the diff that remains if they don't.
#
# An exception either rewrites the lines it matches in one side's output (deletes them, or
# replaces the matched text), after which both outputs must be identical, so that it only
# ever allows the deviation it describes; or, for an output that can't be compared because
# the C++ produced something broken (invalid IR), accepts the difference when a line of
# that side matches, as long as the other side's output verifies.
function explain(cpp, port, exceptions)
    sides = Dict("cpp" => cpp, "port" => port)
    for (i, e) in enumerate(exceptions)
        e.action === :accept || continue
        other = sides[e.side == "cpp" ? "port" : "cpp"]
        if any(l -> occursin(e.lines, l), split(sides[e.side], '\n')) &&
           !startswith(other, "! ") && !occursin("\n! invalid IR", other)
            return true, [i], ""
        end
    end
    cpp_lines, cpp_used = rewritten(cpp, "cpp", exceptions)
    port_lines, port_used = rewritten(port, "port", exceptions)
    cpp_lines == port_lines && return true, union(cpp_used, port_used), ""
    return false, Int[], unified_diff(join(cpp_lines, '\n'), join(port_lines, '\n'))
end

function report(opts::Options, jobs, skipped)
    paths = Paths(opts.out)
    exceptions = load_exceptions(opts.exceptions)
    used = falses(length(exceptions))
    results = Dict{String,Vector{SubString{String}}}()
    for line in eachline(paths.results)
        fields = split(line, '\t')
        results[fields[1]] = fields
    end
    counts = Dict{String,Dict{Symbol,Int}}()
    findings = Tuple{Job,String,String}[]
    for job in jobs
        fields = results[job.key]
        status = Symbol(fields[2])
        c = get!(counts, job.spec.name, Dict{Symbol,Int}())
        if status === :different
            base = joinpath(paths.diffs, fields[4])
            candidates = [i for i in eachindex(exceptions) if applies(exceptions[i], job)]
            explained, took, remaining = explain(read(base * ".cpp.txt", String),
                                                 read(base * ".port.txt", String),
                                                 exceptions[candidates])
            if explained
                status = :excepted
                used[candidates[took]] .= true
            else
                push!(findings, (job, base * ".diff", remaining))
            end
        end
        c[status] = get(c, status, 0) + 1
        status in (:identical, :excepted, :different) && fields[3] == "changed" &&
            (c[:changed] = get(c, :changed, 0) + 1)
    end

    columns = [:identical, :excepted, :different, :changed, :no_input, :unparsable,
               :invalid_input, :prefix_failed]
    println("Julia $VERSION, LLVM $(LLVM.version())")
    println(rpad("pass", 26), join(lpad.(string.(columns), 14)))
    summary = IOBuffer()
    for spec in PASS_SPECS
        haskey(counts, spec.name) || continue
        c = counts[spec.name]
        println(rpad(spec.name, 26), join(lpad.([get(c, k, 0) for k in columns], 14)))
        println(summary, join([minor(), spec.name, [get(c, k, 0) for k in columns]...], '\t'))
    end
    write(joinpath(paths.out, "summary.tsv"), take!(summary))
    isempty(skipped) || println("not in this Julia: ", join(skipped, ", "))
    println("`changed`: the C++ pass changed the module (of identical, excepted and different)")

    for (i, e) in enumerate(exceptions)
        used[i] && continue
        any(job -> applies(e, job), jobs) || continue
        println("unused exception for $(e.pass): input $(e.glob), ",
                e.action === :accept ? "accept" : "lines", " '$(e.lines.pattern)'")
    end
    if !isempty(findings)
        println("\n$(length(findings)) unexplained difference(s):")
        for (job, file, remaining) in findings
            println("\n=== ", job.key, " (", file, ")")
            opts.quiet && continue
            # what remains after the rewrites of the exceptions that apply
            lines = split(remaining, '\n')
            println(join(first(lines, 80), '\n'))
            length(lines) > 80 && println("[... $(length(lines) - 80) more lines]")
        end
    end
    return isempty(findings)
end

function main(args)
    opts = parse_args(args)
    if opts.worker
        worker(opts)
        return true
    end
    jobs, skipped = collect_jobs(opts)
    if opts.report
        isempty(opts.out) && error("--report needs --out")
    else
        isempty(opts.out) && (opts.out = mktempdir())
        mkpath(opts.out)
        paths = Paths(opts.out)
        rm(paths.results; force=true)
        rm(paths.diffs; force=true, recursive=true)
        rm(paths.log; force=true)
        touch(paths.results)
        supervise(opts, jobs)
    end
    println("results in ", opts.out)
    return report(opts, jobs, skipped)
end

isinteractive() || exit(main(ARGS) ? 0 : 1)
