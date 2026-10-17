# Tests of the harness for Julia's own pass tests (test/upstream/run.jl), on a synthetic
# checkout. The harness itself runs on CI, against the pinned JuliaLang/julia checkouts.

include(joinpath(@__DIR__, "upstream", "run.jl"))
using .UpstreamHarness: HarnessError, RunLine, run_lines, shell_words, opt_invocations,
                        classify_run, apply_patch, disable_runs, find_python

@testset "upstream harness" begin

@testset "RUN lines" begin
    text = """
        ; RUN: opt -passes=foo %s \\
        ; RUN:   | FileCheck %s
        # RUN: julia --startup-file=no %s %t && llvm-link -S %t/* -o %t/module.ll
        define void @f() {
        ; CHECK: RUN: is not a RUN line here
          ret void
        }
        """
    runs = run_lines(text)
    @test length(runs) == 2
    @test runs[1].lines == [1, 2]
    @test runs[1].command == "opt -passes=foo %s    | FileCheck %s"
    @test runs[2].index == 2

    # disabled RUN lines keep the line numbers
    disabled = disable_runs(text, runs[1:1])
    @test length(split(disabled, '\n')) == length(split(text, '\n'))
    @test length(run_lines(disabled)) == 1

    @test_throws HarnessError run_lines("; RUN: opt \\\n")
end

@testset "commands" begin
    @test shell_words("not --crash opt -passes='function(A,B)' -S %s 2>&1 | FileCheck %s") ==
          ["not", "--crash", "opt", "-passes=function(A,B)", "-S", "%s", "2>&1", "|", "FileCheck", "%s"]
    @test shell_words("a && b; c || d") == ["a", "&&", "b", ";", "c", "||", "d"]
    @test shell_words("echo \"a b\" 'c d'") == ["echo", "a b", "c d"]

    @test opt_invocations("cat %t/module.ll | opt -passes='loop(LowerSIMDLoop)' -S - | FileCheck %s") ==
          [["-passes=loop(LowerSIMDLoop)", "-S", "-"]]
    @test opt_invocations("opt -passes=A -S -o /dev/null %s 2>&1 | FileCheck %s") ==
          [["-passes=A", "-S", "-o", "/dev/null", "%s"]]
    @test opt_invocations("not --crash opt -passes=A %t/x.ll 2>&1") == [["-passes=A", "%t/x.ll"]]
    @test opt_invocations("env FOO=1 opt -passes=A < %s > %t") == [["-passes=A"]]
    @test isempty(opt_invocations("julia %s | FileCheck %s"))
    @test length(opt_invocations("opt -passes=A %s | opt -passes=B -S")) == 2
end

@testset "classification" begin
    run(cmd) = RunLine(1, [1], cmd)
    st, why, pipelines = classify_run(run("opt -enable-new-pm=1 --opaque-pointers=0 --load-pass-plugin=libjulia-codegen%shlibext -passes=RemoveNI -S %s | FileCheck %s"))
    @test st == :skip && occursin("typed pointers", why)

    st, _, pipelines = classify_run(run("opt --load-pass-plugin=libjulia-codegen%shlibext -passes='module(RemoveNI,FinalLowerGC)' -S %s | FileCheck %s"))
    @test st == :run && pipelines == ["module(jl-remove-ni,FinalLowerGC)"]
    _, _, pipelines = classify_run(run("opt -passes=RemoveNI -S %s"); map_passes=false)
    @test pipelines == ["RemoveNI"]

    # legacy pass manager, with opaque pointers
    _, _, pipelines = classify_run(run("opt -enable-new-pm=0 --opaque-pointers=1 -load libjulia-codegen%shlibext -RemoveNI -AllocOpt -S %s"))
    @test pipelines == ["jl-remove-ni,function(AllocOpt)"]

    # what jlopt cannot run is an error
    @test_throws HarnessError classify_run(run("opt -frobnicate -S %s"))
end

@testset "patches" begin
    text = "a\nb\nc\nd\ne"
    patch = """
        --- a/x.ll
        +++ b/x.ll
        @@ -2,2 +2,3 @@
         b
        -c
        +C
        +C2
        """
    @test apply_patch(text, patch) == "a\nb\nC\nC2\nd\ne"
    # context must match exactly
    @test_throws HarnessError apply_patch("a\nB\nc\nd\ne", patch)
end

@testset "manifest" begin
    # the real manifest is well-formed, and covers every pinned minor version
    manifest = UpstreamHarness.load_manifest()
    @test issetequal(keys(manifest["pins"]), ["1.10", "1.11", "1.12", "1.13", "1.14"])
    @test all(pin -> length(pin["commit"]) == 40, values(manifest["pins"]))
    # CI checks out the pinned commits
    ci = read(joinpath(dirname(@__DIR__), ".github", "workflows", "CI.yml"), String)
    refs = [m[1] for m in eachmatch(r"julia_ref: '([0-9a-f]{40})'", ci)]
    @test issetequal(refs, [pin["commit"] for pin in values(manifest["pins"])])
    for (name, entry) in manifest["fixtures"]
        get(entry, "status", "") == "override" && @test isfile(joinpath(@__DIR__, "upstream", entry["patch"]))
        for (_, overrides) in get(entry, "pins", Dict())
            get(overrides, "status", "") == "override" &&
                @test isfile(joinpath(@__DIR__, "upstream", overrides["patch"]))
        end
    end
end

# A synthetic JuliaLang/julia checkout and manifests for it
if Sys.which("git") === nothing || find_python() === nothing
    @warn "git or python3 not found; skipping the end-to-end tests of the upstream harness"
else
mktempdir() do dir
    src = joinpath(dir, "julia")
    passes = mkpath(joinpath(src, "test", "llvmpasses"))
    mkpath(joinpath(src, "test", "testhelpers"))
    write(joinpath(src, "test", "testhelpers", "README"), "")

    # runs the port, and skips the typed variant (whose checks would fail)
    write(joinpath(passes, "good.ll"), """
        ; RUN: opt --load-pass-plugin=libjulia-codegen%shlibext -passes=RemoveNI -S %s | FileCheck %s
        ; RUN: opt --opaque-pointers=0 --load-pass-plugin=libjulia-codegen%shlibext -passes=RemoveNI -S %s | FileCheck %s --check-prefix=TYPED
        target datalayout = "e-i64:64-ni:10:11:12:13"
        ; CHECK: target datalayout = "e-i64:64"
        ; TYPED: this never matches
        """)
    # passes, but its second RUN line runs Julia's pass instead of the port
    write(joinpath(passes, "cpp.ll"), """
        ; RUN: opt -passes=RemoveNI -S %s | FileCheck %s
        ; RUN: opt -map-julia-passes=0 -passes=RemoveNI -S %s | FileCheck %s
        target datalayout = "e-i64:64-ni:10:11:12:13"
        ; CHECK: target datalayout = "e-i64:64"
        """)
    # fails as is: needs an override
    needs_override = """
        ; RUN: opt -passes=RemoveNI -S %s | FileCheck %s
        target datalayout = "e-i64:64-ni:10:11:12:13"
        ; CHECK: target datalayout = "e-i64:64-ni:10:11:12:13"
        """
    write(joinpath(passes, "override.ll"), needs_override)
    # runs the port even when the harness asks for Julia's passes
    write(joinpath(passes, "forced.ll"), """
        ; RUN: opt -map-julia-passes=1 -passes=RemoveNI -S %s | FileCheck %s
        target datalayout = "e-i64:64-ni:10:11:12:13"
        ; CHECK: target datalayout = "e-i64:64"
        """)
    write(joinpath(passes, "excluded.ll"), "; RUN: false\n")
    write(joinpath(passes, "Makefile"), "")
    git(args...) = run(`git -C $src -c user.name=test -c user.email=test@example.com $args`)
    git("init", "-q")
    git("add", ".")
    git("commit", "-q", "-m", "fixtures")
    commit = readchomp(`git -C $src rev-parse HEAD`)

    patch = joinpath(dir, "override.ll.patch")
    write(patch, """
        --- a/override.ll
        +++ b/override.ll
        @@ -3,1 +3,1 @@
        -; CHECK: target datalayout = "e-i64:64-ni:10:11:12:13"
        +; CHECK: target datalayout = "e-i64:64"
        """)
    stale_patch = joinpath(dir, "stale.ll.patch")
    write(stale_patch, """
        --- a/good.ll
        +++ b/good.ll
        @@ -3,1 +3,1 @@
        -target datalayout = "e-i64:64-ni:10:11:12:13"
        +target datalayout = "e-i64:64-ni:10:11:12:13"
        """)

    minor = "$(VERSION.major).$(VERSION.minor)"
    function write_manifest(fixtures; commit=commit)
        path = joinpath(dir, "manifest.toml")
        write(path, """
            [pins."$minor"]
            tag = "test"
            commit = "$commit"
            julia = "$VERSION"

            [fixtures."Makefile"]
            kind = "infra"
            status = "exclude"
            reason = "not a test"

            [fixtures."excluded.ll"]
            kind = "cpu"
            status = "exclude"
            reason = "not ported"

            [fixtures."forced.ll"]
            kind = "cpu"
            status = "exclude"
            reason = "for --cpp"

            $fixtures
            """)
        return path
    end
    good = """
        [fixtures."good.ll"]
        kind = "port"
        ports = ["RemoveNI"]
        status = "run"
        """
    cpp = """
        [fixtures."cpp.ll"]
        kind = "port"
        ports = ["RemoveNI"]
        status = "run"
        """
    override = """
        [fixtures."override.ll"]
        kind = "port"
        ports = ["RemoveNI"]
        status = "override"
        patch = "override.ll.patch"
        reason = "test"
        """
    excluded_cpp = """
        [fixtures."cpp.ll"]
        kind = "cpu"
        status = "exclude"
        reason = "test"
        """

    function harness(manifest, args...)
        out = joinpath(dir, "out.txt")
        code = open(out, "w") do io
            redirect_stdout(io) do
                UpstreamHarness.main([src, "--manifest", manifest, args...])
            end
        end
        return code, read(out, String)
    end

    # the fixtures pass, the typed RUN line is skipped, and the override is needed
    code, out = harness(write_manifest(good * override * excluded_cpp))
    @test code == 0
    @test occursin("2 of 2 fixtures passed", out)
    @test occursin("not run: excluded.ll: not ported", out)

    # proof that the port ran
    code, out = harness(write_manifest(good * cpp * override))
    @test code == 1
    @test occursin("cpp.ll: the ledger shows no run of jl-remove-ni for RUN line 2", out)
    @test !occursin("RUN line 1 ", out)

    # ledgers of a previous run in the same work directory don't count
    workdir = joinpath(dir, "work")
    code, _ = harness(write_manifest(good * override * excluded_cpp), "--workdir", workdir)
    @test code == 0
    code, out = harness(write_manifest(good * cpp * override), "--workdir", workdir)
    @test code == 1
    @test occursin("cpp.ll: the ledger shows no run of jl-remove-ni for RUN line 2", out)

    # with Julia's passes, the ports must not run
    code, out = harness(write_manifest(good * cpp * override), "--cpp", "--filter", "cpp|good")
    @test code == 0
    @test occursin("2 of 2 fixtures passed", out)
    # the overrides describe the ports: Julia's passes run the pristine fixtures
    code, out = harness(write_manifest(good * cpp * override), "--cpp", "--filter", "override")
    @test code == 1
    @test occursin("override.ll: FAIL", out)
    code, out = harness(write_manifest(good * cpp * override), "--cpp", "--filter", "forced")
    @test code == 1
    @test occursin("forced.ll: ports ran although Julia's passes were requested", out)

    # a stale override
    stale = replace(override, "override.ll.patch" => "stale.ll.patch", "override.ll\"]" => "good.ll\"]")
    code, out = harness(write_manifest(stale * replace(override, "status = \"override\"" => "status = \"exclude\"") * excluded_cpp))
    @test code == 1
    @test occursin("good.ll: the override is stale", out)

    # every fixture must be in the manifest
    @test_throws "override.ll is not in the manifest" harness(write_manifest(good * excluded_cpp))

    # a skip for a port that exists is stale
    stale_skip = replace(good, "status = \"run\"" => "status = \"skip\"\nmissing = [\"RemoveNI\"]")
    @test_throws "which exist now" harness(write_manifest(stale_skip * override * excluded_cpp))

    # fixtures of ports that don't exist cannot run
    no_port = replace(good, "[\"RemoveNI\"]" => "[\"RemoveNI\", \"AllocOpt\"]")
    @test_throws "the ports of AllocOpt do not exist" harness(write_manifest(no_port * override * excluded_cpp))

    # the checkout must be at the pinned commit, with its fixtures unchanged
    @test_throws "pinned to" harness(write_manifest(good * override * excluded_cpp; commit="0"^40))
    mv(joinpath(passes, "good.ll"), joinpath(dir, "good.ll"))
    @test_throws "differ from commit" harness(write_manifest(good * override * excluded_cpp))
    mv(joinpath(dir, "good.ll"), joinpath(passes, "good.ll"))
    write(joinpath(passes, "new.ll"), "")
    @test_throws "differ from commit" harness(write_manifest(good * override * excluded_cpp))
    rm(joinpath(passes, "new.ll"))

    # the report covers every fixture
    code, out = harness(write_manifest(good * override * excluded_cpp), "--report")
    @test code == 0
    @test occursin("| good.ll | port | run | 1 run, 1 skipped | `jl-remove-ni` |", out)
    @test occursin("| excluded.ll | cpu | exclude |", out)
end
end

end
