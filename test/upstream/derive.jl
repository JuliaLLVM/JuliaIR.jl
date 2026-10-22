# Generate compatibility patches for an LLVM version. They adapt Julia's upstream
# fixtures to IR printed by that LLVM instead of the pin's bundled LLVM.
#
#   julia --project=test test/upstream/derive.jl JULIA_REPO [--llvm 23] [--check]
#
# JULIA_REPO is a git clone of JuliaLang/julia that has the pinned commits (a sparse or
# blobless clone will do). The patches are written to llvm-compat/llvm<N>/<minor>/ for
# every pin whose LLVM is older than N, replacing what is there; `--check` only compares
# them with what is committed.
#
# Each rule below follows one change of LLVM and rewrites the lines it affects, and only
# those: the fixtures it applies to, and how many lines it changes in each, are listed
# with it, and any other match is an error. Where Julia's own fixtures were adapted to the
# same change when Julia moved to that LLVM, the rule rewrites them the same way. The
# output of the passes is never rewritten: the patches change what the fixtures expect.
# `run.jl --reference-llvm OPT` validates them against Julia's C++ output. Standalone
# runs then check the ports with these same compatibility patches.

module FixturePatches

using Printf
using TOML

include(joinpath(@__DIR__, "run.jl"))
using .UpstreamHarness: run_lines, load_manifest, apply_patch, layer_dir, AFTER_PORT,
                        MANIFEST_PATH, HarnessError, slashed_relpath


## rules

struct Rule
    name::String
    llvm::Int           # the LLVM version that made the change
    why::String         # the change upstream, and Julia's own adaptation of its fixtures
    # the lines it changes, per "<minor>/<fixture>" (only pins older than `llvm`), and per
    # "<minor>/<fixture> after port" in a fixture with its port patch applied
    expected::Dict{String,Int}
    # `rewrite(line, kind)` returns the line, changed or not; `kind` is `:check` for the
    # directives of FileCheck prefixes that RUN lines with opaque pointers use, `:input`
    # for IR, and `:other` for other lines (comments, RUN lines, unused prefixes)
    rewrite::Function
end

# a literal string in a FileCheck pattern
escape_pattern(s) = replace(s, r"[\\^$.|?*+()\[\]{}]" => s -> "\\" * s)

# LLVM 23 prints floating-point constants in decimal where that is exact
function decimal_literal(type, hex)
    bits = parse(UInt16, hex; base=16)
    value = type == "half" ? Float64(reinterpret(Float16, bits)) :
                             Float64(reinterpret(Float32, UInt32(bits) << 16))
    text = @sprintf("%.6e", value)
    parse(Float64, text) == value ||
        throw(HarnessError("$type 0x$hex has no exact decimal spelling; extend the rule"))
    return text
end

const RULES = [
    Rule("memoryssa-alias", 16,
         "LLVM 16 no longer prints the alias result of an optimized MemorySSA access " *
         "(`MemoryUse(2) MayAlias`), as AA stopped tracking must-alias in mod/ref results " *
         "(D130713, llvm/llvm-project@f96ea53e892e); Julia's fixture dropped it in 8e4221f676",
         Dict("1.10/julia-simdloop-memoryssa.ll" => 3),
         function (line, kind)
             kind == :check || return line
             return replace(line, r"(Memory(?:Use|Def)\([^()]*\)) (?:May|Must|Partial)Alias" => s"\1")
         end),
    Rule("lifetime-size", 22,
         "LLVM 22 removed the size argument of llvm.lifetime.start/end " *
         "(llvm/llvm-project#150248); Julia's fixtures dropped it in f77337691e",
         Dict("1.10/alloc-opt-gcframe.ll" => 5, "1.10/alloc-opt-gcframe-addrspaces.ll" => 1,
              "1.11/alloc-opt-gcframe.ll" => 5, "1.11/alloc-opt-gcframe-addrspaces.ll" => 1,
              "1.12/alloc-opt-gcframe.ll" => 5, "1.12/alloc-opt-gcframe-addrspaces.ll" => 1,
              "1.13/alloc-opt-gcframe.ll" => 5, "1.13/alloc-opt-gcframe-addrspaces.ll" => 1),
         function (line, kind)
             kind == :check && occursin("@llvm.lifetime.", line) || return line
             size = raw"\(i64 (?:\d+|\{\{[^}]*\}\}),"
             # the pointer is the only argument left
             line = replace(line, Regex(size * raw"\s*$") => "(ptr")
             return replace(line, Regex(size * " ") => "(")
         end),
    Rule("masked-align", 22,
         "LLVM 22 replaced the alignment argument of the masked load and gather " *
         "intrinsics by an `align` attribute of the pointer (llvm/llvm-project#163802); " *
         "Julia's fixtures followed in f77337691e",
         Dict("1.10/gcroots.ll" => 3, "1.11/gcroots.ll" => 3, "1.12/gcroots.ll" => 3,
              "1.13/gcroots.ll" => 3),
         function (line, kind)
             kind == :check || return line
             return replace(line, r"(@llvm\.masked\.(?:load|gather)[\w.]*\(.*?) (%[\w.]+), i32 (\d+), " =>
                                  s"\1 align \3 \2, ")
         end),
    Rule("splat", 20,
         "LLVM 20 prints vector constants of equal elements as `splat (...)` " *
         "(llvm/llvm-project#112548); Julia's fixtures accept both since 5c6d5de87f",
         Dict("1.10/gcroots.ll" => 1, "1.11/gcroots.ll" => 1, "1.12/gcroots.ll" => 1),
         function (line, kind)
             kind == :check || return line
             return replace(line, r"<(\d+) x ([^<>{}]+)> <([^<>{}]+)>" => function (m)
                 c = match(r"<(\d+) x ([^<>{}]+)> <([^<>{}]+)>", m)
                 elements = split(c[3], ", ")
                 length(elements) == parse(Int, c[1]) && allequal(elements) || return m
                 old = "<$(c[3])>"
                 new = "splat ($(elements[1]))"
                 return "<$(c[1]) x $(c[2])> {{($(escape_pattern(old))|$(escape_pattern(new)))}}"
             end)
         end),
    Rule("null-pointer-splat", 23,
         "LLVM 23 represents vectors of null pointers as splats of a null pointer " *
         "(llvm/llvm-project#195486) and prints them so; Julia's fixtures accept both " *
         "since 9091e10929",
         Dict("1.10/gcroots.ll" => 3, "1.11/gcroots.ll" => 3, "1.12/gcroots.ll" => 3,
              "1.13/gcroots.ll" => 3, "1.12/late-lower-gc.ll" => 1, "1.13/late-lower-gc.ll" => 1),
         function (line, kind)
             kind == :check || return line
             return replace(line, r"<(\d+) x (ptr(?: addrspace\(\d+\))?)> zeroinitializer" => function (m)
                 c = match(r"<(\d+) x (ptr(?: addrspace\(\d+\))?)> zeroinitializer", m)
                 return "<$(c[1]) x $(c[2])> {{zeroinitializer|$(escape_pattern("splat ($(c[2]) null)"))}}"
             end)
         end),
    Rule("decimal-fp", 23,
         "LLVM 23 prints half and bfloat constants in decimal (llvm/llvm-project#190649); " *
         "Julia's fixtures accept both since 9091e10929",
         Dict("1.12/float16.ll" => 2, "1.13/float16.ll" => 2),
         function (line, kind)
             kind == :check || return line
             return replace(line, r"\b0x([HR])([0-9A-F]{4})\b" => function (m)
                 c = match(r"0x([HR])([0-9A-F]{4})", m)
                 decimal = decimal_literal(c[1] == "H" ? "half" : "bfloat", c[2])
                 return "{{$(m)|$(escape_pattern(decimal))}}"
             end)
         end),
    Rule("target-features-sign", 22,
         "LLVM 22's verifier requires every entry of \"target-features\" to start with " *
         "`+` or `-` (llvm/llvm-project#173119), which the clone targets of this fixture " *
         "don't; Julia's fixture prefixes them with `-` since f77337691e (an input repair)",
         Dict("1.10/multiversioning-clone-only.ll" => 13,
              "1.11/multiversioning-clone-only.ll" => 13,
              "1.12/multiversioning-clone-only.ll" => 13,
              "1.13/multiversioning-clone-only.ll" => 13),
         function (line, kind)
             features = r"(nofeatures|cloneall|fastmathclone)"
             if kind == :check
                 return replace(line, Regex("(\"target-features\"=\")" * features.pattern * "\"") =>
                                      s"\1-\2\"")
             elseif kind == :input
                 # the features of the clone targets, in the module's `julia.mv.specs`
                 return replace(line, Regex("(!\\{!\"cpu\\w+\", !\")" * features.pattern * "\"") =>
                                      s"\1-\2\"")
             end
             return line
         end),
]


## applying them

const DIRECTIVE_RE = r"^\s*(?:;|#|//)+\s*([A-Za-z0-9_-]+?)(?:-NEXT|-SAME|-NOT|-DAG|-LABEL|-EMPTY|-COUNT-\d+)?:"

# the FileCheck prefixes of the RUN lines that don't use typed pointers
function active_prefixes(text)
    prefixes = Set{String}()
    for run in run_lines(text)
        occursin(r"--?opaque-pointers=0", run.command) && continue
        for m in eachmatch(r"\bFileCheck\b([^|;&]*)", run.command)
            given = [p for c in eachmatch(r"--?check-prefix(?:es)?[= ]([\w,-]+)", m[1])
                     for p in split(c[1], ',')]
            isempty(given) ? push!(prefixes, "CHECK") : union!(prefixes, given)
        end
    end
    return prefixes
end

function line_kind(line, prefixes)
    m = match(DIRECTIVE_RE, line)
    m !== nothing && return m[1] in prefixes ? :check : :other
    return occursin(r"^\s*(;|#|//)", line) ? :other : :input
end

# Apply the rules for LLVM `target` to the fixture `name` of a pin whose LLVM is `source`:
# those that follow a change after `source`, and list the fixture. Returns the text and
# the number of lines each rule changed.
function apply_rules(text, name, source::Int, target::Int; rules=RULES)
    applies(rule) = source < rule.llvm <= target &&
                    any(key -> endswith(key, "/" * name) || endswith(key, "/$name after port"),
                        keys(rule.expected))
    applicable = filter(applies, rules)
    counts = Dict(r.name => 0 for r in applicable)
    prefixes = active_prefixes(text)
    lines = split(text, '\n')
    for (i, line) in enumerate(lines)
        kind = line_kind(line, prefixes)
        for rule in applicable
            new = rule.rewrite(line, kind)
            new == line && continue
            counts[rule.name] += 1
            line = new
        end
        lines[i] = line
    end
    return join(lines, '\n'), counts
end

# A unified diff between two texts with the same number of lines.
function line_diff(old, new, name; header="", context=3)
    a, b = split(old, '\n'), split(new, '\n')
    length(a) == length(b) || throw(HarnessError("$name: the rules must keep the number of lines"))
    changed = [i for i in eachindex(a) if a[i] != b[i]]
    io = IOBuffer()
    print(io, header)
    println(io, "--- a/$name")
    println(io, "+++ b/$name")
    # the last element is the empty string after the final newline
    nlines = isempty(a[end]) ? length(a) - 1 : length(a)
    i = 1
    while i <= length(changed)
        first_line = max(1, changed[i] - context)
        j = i
        while j < length(changed) && changed[j+1] - changed[j] <= 2 * context
            j += 1
        end
        last_line = min(nlines, changed[j] + context)
        n = last_line - first_line + 1
        println(io, "@@ -$first_line,$n +$first_line,$n @@")
        k = first_line
        while k <= last_line
            if a[k] == b[k]
                println(io, " ", a[k])
                k += 1
                continue
            end
            # a run of changed lines: the old ones, then the new ones
            stop = k
            while stop < last_line && a[stop+1] != b[stop+1]
                stop += 1
            end
            foreach(l -> println(io, "-", a[l]), k:stop)
            foreach(l -> println(io, "+", b[l]), k:stop)
            k = stop + 1
        end
        i = j + 1
    end
    return String(take!(io))
end


## the layer

git_show(repo, commit, path) = read(`git -C $repo show $commit:$path`, String)

# The LLVM compatibility patches of one fixture at a pin, added to `patches`: `<minor>/<name>.patch`
# against the pristine fixture, and, for a fixture with a port patch (`port_patch`),
# `<minor>/<name>.after-port.patch` against the fixture with that patch, which may need other
# changes. The lines each rule changed go to `seen`, by "<minor>/<name>" and
# "<minor>/<name> after port".
function derive_fixture!(patches, seen, pristine, name, minor, source, target;
                         port_patch=nothing, rules=RULES)
    variants = [(pristine, "", ".patch", "")]
    port_patch === nothing ||
        push!(variants, (apply_patch(pristine, port_patch; name), " after port", AFTER_PORT,
                         " on top of its port patch,"))
    for (text, key, extension, on) in variants
        derived, counts = apply_rules(text, name, source, target; rules)
        for (rule, n) in counts
            n > 0 && (seen[(rule, "$minor/$name$key")] = n)
        end
        derived == text && continue
        used = join(["$rule ($n)" for (rule, n) in sort(collect(counts)) if n > 0], ", ")
        header = "LLVM compatibility patch of $name for Julia $minor on LLVM $target,$on generated by " *
                 "test/upstream/derive.jl\nfrom the rules (lines changed): $used\n"
        patches["$minor/$name$extension"] = line_diff(text, derived, name; header)
    end
end

# Every rule must change exactly the lines it expects, at the pins older than its LLVM.
function check_counts(seen, pins, target; rules=RULES)
    errors = String[]
    for rule in rules
        rule.llvm <= target || continue
        for ((name, key), n) in seen
            name == rule.name || continue
            expected = get(rule.expected, key, 0)
            n == expected || push!(errors, "rule $name changes $n lines of $key, expected $expected")
        end
        for (key, n) in rule.expected
            minor = first(split(key, '/'))
            haskey(pins, minor) && pins[minor]["llvm"] < rule.llvm || continue
            haskey(seen, (rule.name, key)) ||
                push!(errors, "rule $(rule.name) changes no line of $key, expected $n")
        end
    end
    isempty(errors) || throw(HarnessError(join(sort(errors), "\n")))
end

# The patches of the layer for LLVM `target`, as a Dict of relative paths to contents.
function derive(repo, target::Int; manifest=load_manifest(), manifest_dir=dirname(MANIFEST_PATH),
                rules=RULES)
    patches = Dict{String,String}()
    seen = Dict{Tuple{String,String},Int}()
    for (minor, pin) in sort(collect(manifest["pins"]); by=first)
        haskey(pin, "llvm") || throw(HarnessError("pin $minor has no `llvm`"))
        pin["llvm"] < target || continue
        haskey(pin, "commit") ||
            throw(HarnessError("pin $minor (LLVM $(pin["llvm"])) has no commit to derive patches from"))
        commit = pin["commit"]
        names = map(basename, readlines(`git -C $repo ls-tree --name-only $commit test/llvmpasses/`))
        for name in sort(names)
            endswith(name, ".ll") || endswith(name, ".jl") || continue
            pristine = git_show(repo, commit, "test/llvmpasses/$name")
            entry = manifest["fixtures"][name]
            entry = merge(entry, get(get(entry, "pins", Dict()), minor, Dict()))
            port_patch = entry["status"] in ("override", "derived") ?
                read(joinpath(manifest_dir, entry["patch"]), String) : nothing
            derive_fixture!(patches, seen, pristine, name, minor, pin["llvm"], target;
                            port_patch, rules)
        end
    end
    check_counts(seen, manifest["pins"], target; rules)
    return patches
end

function main(args)
    repo = nothing
    target = 23
    check = false
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--llvm"
            target = parse(Int, args[i += 1])
        elseif arg == "--check"
            check = true
        elseif startswith(arg, "-")
            throw(HarnessError("unknown option $arg"))
        else
            repo = abspath(arg)
        end
        i += 1
    end
    repo === nothing && throw(HarnessError("usage: derive.jl JULIA_REPO [--llvm N] [--check]"))

    patches = derive(repo, target)
    dir = joinpath(dirname(MANIFEST_PATH), "llvm-compat", "llvm$target")
    existing = Dict{String,String}()
    if isdir(dir)
        for (root, _, files) in walkdir(dir), file in files
            path = joinpath(root, file)
            existing[slashed_relpath(path, dir)] = read(path, String)
        end
    end
    if check
        differ = sort([path for path in union(keys(patches), keys(existing))
                       if get(patches, path, nothing) != get(existing, path, nothing)])
        isempty(differ) && (println("llvm-compat/llvm$target is up to date ($(length(patches)) patches)"); return 0)
        println("llvm-compat/llvm$target differs from what the rules generate:")
        foreach(path -> println("  ", path), differ)
        return 1
    end
    rm(dir; recursive=true, force=true)
    for (path, text) in patches
        mkpath(dirname(joinpath(dir, path)))
        write(joinpath(dir, path), text)
    end
    println("wrote $(length(patches)) patches to llvm-compat/llvm$target")
    return 0
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    code = try
        FixturePatches.main(ARGS)
    catch err
        err isa FixturePatches.HarnessError || rethrow()
        println(stderr, "error: ", err.msg)
        2
    end
    exit(code)
end
