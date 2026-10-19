# Tests of the harness for Julia's own pass tests (test/upstream/run.jl), on a synthetic
# checkout. The harness itself runs on CI, against the pinned JuliaLang/julia checkouts.

include(joinpath(@__DIR__, "upstream", "run.jl"))
using .UpstreamHarness: HarnessError, RunLine, run_lines, shell_words, opt_invocations,
                        classify_run, apply_patch, disable_runs, find_python, lit_params,
                        reprint_tools, JULIA_CPP_PASSES, ported_passes, LLVM,
                        LLVM_utils_unified_jll
include(joinpath(@__DIR__, "upstream", "derive.jl"))

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

    st, _, pipelines = classify_run(run("opt --load-pass-plugin=libjulia-codegen%shlibext -passes='module(RemoveNI,FinalLowerGC,JuliaMultiVersioning)' -S %s | FileCheck %s"))
    @test st == :run && pipelines == ["module(jl-remove-ni,jl-final-lower-gc,jl-multiversioning)"]
    _, _, pipelines = classify_run(run("opt -passes=RemoveNI -S %s"); map_passes=false)
    @test pipelines == ["RemoveNI"]

    # legacy pass manager, with opaque pointers
    _, _, pipelines = classify_run(run("opt -enable-new-pm=0 --opaque-pointers=1 -load libjulia-codegen%shlibext -RemoveNI -AllocOpt -S %s"))
    @test pipelines == ["jl-remove-ni,function(jl-alloc-opt)"]

    # what jlopt cannot run is an error
    @test_throws HarnessError classify_run(run("opt -frobnicate -S %s"))

    # mode B: lines that need Julia's C++ passes are skipped, those of the ports run
    # Julia's pipeline is rebuilt from the ports, and the C++ passes not ported yet
    st, why, pipelines = classify_run(run("opt -passes='RemoveNI,julia<level=2>' -S %s"); mode="B")
    @test st == (isempty(JuliaIR.CPP_FALLBACKS) ? :run : :skip)
    @test startswith(only(pipelines), "jl-remove-ni,BeforeOptimization,")
    for name in setdiff(JULIA_CPP_PASSES, ported_passes())
        @test classify_run(run("opt -passes='$name' -S %s"); mode="B")[1] == :skip
    end
    st, _, pipelines = classify_run(run("opt -passes='module(RemoveNI)' -S %s"); mode="B")
    @test st == :run && pipelines == ["module(jl-remove-ni)"]
    # names no LLVM knows are not skipped, but fail when the line runs
    @test classify_run(run("opt -passes=frobnicate -S %s"); mode="B")[1] == :run

    # patches are reported with `/`, as the manifest names them, also on Windows
    @test UpstreamHarness.slashed_relpath(joinpath(pwd(), raw"derived-B\llvm18\1.12\x.ll.patch"), pwd()) ==
          "derived-B/llvm18/1.12/x.ll.patch"
    @test UpstreamHarness.slashed_relpath(joinpath(pwd(), "derived-B", "llvm18", "1.12"), pwd()) ==
          "derived-B/llvm18/1.12"
end

@testset "mode-B rules" begin
    rules = Dict(rule.name => rule for rule in DeriveB.RULES)
    rewrite(name, line, kind=:check) = rules[name].rewrite(line, kind)

    @test rewrite("lifetime-size", "; OPAQUE: call void @llvm.lifetime.start.p5(i64 4, ptr addrspace(5) %var1)") ==
          "; OPAQUE: call void @llvm.lifetime.start.p5(ptr addrspace(5) %var1)"
    @test rewrite("lifetime-size", "; CHECK-NEXT: call void @llvm.lifetime.end{{.*}}(i64 8,") ==
          "; CHECK-NEXT: call void @llvm.lifetime.end{{.*}}(ptr"
    # never the input, which LLVM upgrades when it reads it
    input = "  call void @llvm.lifetime.start.p0(i64 8, ptr %a)"
    @test rewrite("lifetime-size", input, :input) == input

    @test rewrite("memoryssa-alias", "; CHECK: MemoryUse([[MPHI]]) MayAlias") ==
          "; CHECK: MemoryUse([[MPHI]])"
    @test rewrite("memoryssa-alias", "; CHECK: [[MSSA_USE]] = MemoryDef([[MPHI]])") ==
          "; CHECK: [[MSSA_USE]] = MemoryDef([[MPHI]])"

    @test rewrite("masked-align", "; CHECK: call <2 x ptr> @llvm.masked.gather.v2p0.v2p11(<2 x ptr addrspace(11)> %ptrs, i32 16, <2 x i1> %m, <2 x ptr> %p)") ==
          "; CHECK: call <2 x ptr> @llvm.masked.gather.v2p0.v2p11(<2 x ptr addrspace(11)> align 16 %ptrs, <2 x i1> %m, <2 x ptr> %p)"

    @test rewrite("splat", "; CHECK: <2 x i1> <i1 true, i1 true>, <4 x i8> <i8 1, i8 2, i8 1, i8 1>") ==
          "; CHECK: <2 x i1> {{(<i1 true, i1 true>|splat \\(i1 true\\))}}, <4 x i8> <i8 1, i8 2, i8 1, i8 1>"

    @test rewrite("null-pointer-splat", "; CHECK: insertelement <4 x ptr addrspace(10)> zeroinitializer, ptr") ==
          "; CHECK: insertelement <4 x ptr addrspace(10)> {{zeroinitializer|splat \\(ptr addrspace\\(10\\) null\\)}}, ptr"
    @test rewrite("null-pointer-splat", "; CHECK: <4 x i32> zeroinitializer") == "; CHECK: <4 x i32> zeroinitializer"

    @test rewrite("decimal-fp", "; CHECK: fadd half %x, 0xH3C00") ==
          "; CHECK: fadd half %x, {{0xH3C00|1\\.000000e\\+00}}"
    @test rewrite("decimal-fp", "; CHECK: fadd bfloat %x, 0xR4040") ==
          "; CHECK: fadd bfloat %x, {{0xR4040|3\\.000000e\\+00}}"
    # a value whose decimal spelling isn't exact would need another form
    @test_throws DeriveB.HarnessError rewrite("decimal-fp", "; CHECK: half 0xH3555")

    @test rewrite("target-features-sign", "; CHECK-DAG: \"target-features\"=\"cloneall\"") ==
          "; CHECK-DAG: \"target-features\"=\"-cloneall\""
    @test rewrite("target-features-sign", "!5 = !{!\"cpucloneall\", !\"cloneall\", i32 0, i32 2}", :input) ==
          "!5 = !{!\"cpucloneall\", !\"-cloneall\", i32 0, i32 2}"

    # rules apply to the check prefixes of RUN lines with opaque pointers, to the fixtures
    # they list, and to pins whose LLVM is older than the change
    text = """
        ; RUN: opt --opaque-pointers=0 -passes=AllocOpt -S %s | FileCheck %s --check-prefixes=CHECK,TYPED
        ; RUN: opt --opaque-pointers=1 -passes=AllocOpt -S %s | FileCheck %s --check-prefixes=CHECK,OPAQUE
        ; TYPED: call void @llvm.lifetime.start{{.*}}(i64 8, i8*
        ; OPAQUE: call void @llvm.lifetime.start{{.*}}(i64 8, ptr
        ; CHECK: call void @llvm.lifetime.end{{.*}}(i64 8, ptr
        """
    derived, counts = DeriveB.apply_rules(text, "alloc-opt-gcframe.ll", 15, 23)
    @test counts == Dict("lifetime-size" => 2)
    @test occursin("; TYPED: call void @llvm.lifetime.start{{.*}}(i64 8, i8*", derived)
    @test occursin("; OPAQUE: call void @llvm.lifetime.start{{.*}}(ptr\n", derived)
    @test occursin("; CHECK: call void @llvm.lifetime.end{{.*}}(ptr\n", derived)
    @test DeriveB.apply_rules(text, "other.ll", 15, 23)[1] == text
    @test DeriveB.apply_rules(text, "alloc-opt-gcframe.ll", 22, 23)[1] == text
    @test DeriveB.apply_rules(text, "alloc-opt-gcframe.ll", 15, 21)[1] == text

    # a fixture with a mode-A patch gets an after-A patch when the composed fixture needs
    # one, also when the pristine one doesn't; its counts are checked like the others'
    rule = DeriveB.Rule("test", 23, "test", Dict("1.10/x.ll after A" => 1),
                        (line, kind) -> kind == :check ? replace(line, "old" => "new") : line)
    pristine = "; RUN: opt -S %s | FileCheck %s\n; CHECK: kept\n"
    a_patch = "--- a/x.ll\n+++ b/x.ll\n@@ -2,1 +2,1 @@\n-; CHECK: kept\n+; CHECK: old\n"
    patches, seen = Dict{String,String}(), Dict{Tuple{String,String},Int}()
    DeriveB.derive_fixture!(patches, seen, pristine, "x.ll", "1.10", 15, 23; a_patch, rules=[rule])
    @test collect(keys(patches)) == ["1.10/x.ll.after-A.patch"]
    @test apply_patch(apply_patch(pristine, a_patch), patches["1.10/x.ll.after-A.patch"]) ==
          "; RUN: opt -S %s | FileCheck %s\n; CHECK: new\n"
    pins = Dict("1.10" => Dict("llvm" => 15))
    DeriveB.check_counts(seen, pins, 23; rules=[rule])
    @test_throws "rule test changes 2 lines of 1.10/x.ll after A, expected 1" DeriveB.check_counts(
        Dict(("test", "1.10/x.ll after A") => 2), pins, 23; rules=[rule])
    @test_throws "rule test changes no line of 1.10/x.ll after A" DeriveB.check_counts(
        Dict{Tuple{String,String},Int}(), pins, 23; rules=[rule])
    @test_throws "rule test changes 1 lines of 1.10/x.ll, expected 0" DeriveB.check_counts(
        merge(seen, Dict(("test", "1.10/x.ll") => 1)), pins, 23; rules=[rule])

    # the generated patches apply with the harness
    long = join(["line $i" for i in 1:20], '\n') * '\n'
    changed = replace(long, "line 3\n" => "LINE 3\n", "line 4\n" => "LINE 4\n", "line 18\n" => "LINE 18\n")
    diff = DeriveB.line_diff(long, changed, "x.ll"; header="generated\n")
    @test startswith(diff, "generated\n--- a/x.ll\n+++ b/x.ll\n@@ -1,7 +1,7 @@\n")
    @test count("@@ -", diff) == 2
    @test apply_patch(long, diff) == changed
end

if !Sys.iswindows()
@testset "re-printing" begin
    mktempdir() do dir
        # the upgrade oracle's opt runs jlopt, here a stand-in, and re-prints its textual
        # output with the other opt (here, one that marks what it re-printed)
        write(joinpath(dir, "jlopt"), raw"""
            #!/bin/bash
            [ "$1" = crash ] && kill -ABRT $$
            [ "$1" = fail ] && { echo "partial output"; exit 3; }
            out=-; output="jlopt output"
            while [ $# -gt 0 ]; do
                case "$1" in
                    -o) out=$2; shift;;
                    -o*) out=${1#-o};;
                    -) output="jlopt read $(cat)";;
                esac
                shift
            done
            if [ "$out" = - ]; then echo "$output"; else echo "$output" > "$out"; fi
            """)
        write(joinpath(dir, "newer-opt"), raw"""
            #!/bin/bash
            in=$2; out=$4
            if [ "$out" = - ]; then echo "re-printed: $(cat "$in")"; else echo "re-printed: $(cat -- "$in")" > "$out.new"; mv -- "$out.new" "$out"; fi
            """)
        chmod(joinpath(dir, "jlopt"), 0o755)
        chmod(joinpath(dir, "newer-opt"), 0o755)
        reprint_tools(dir, joinpath(dir, "newer-opt"))
        opt = joinpath(dir, "opt")
        @test readchomp(`$opt -passes=x -S in.ll`) == "re-printed: jlopt output"
        @test readchomp(`$opt -passes=x -S in.ll -o -`) == "re-printed: jlopt output"
        @test readchomp(pipeline(`$opt -passes=x -S -`; stdin=IOBuffer("input"))) ==
              "re-printed: jlopt read input"
        file = joinpath(dir, "out.ll")
        run(`$opt -passes=x -S in.ll -o $file`)
        @test readchomp(file) == "re-printed: jlopt output"
        rm(file)
        run(`$opt -passes=x -S in.ll -o$file`)
        @test readchomp(file) == "re-printed: jlopt output"
        # an output file whose name looks like an option
        cd(dir) do
            run(`$opt -passes=x -S in.ll -o -out.ll`)
            @test readchomp("-out.ll") == "re-printed: jlopt output"
        end
        # bitcode, and output that is thrown away, aren't re-printed
        @test readchomp(`$opt -passes=x in.ll`) == "jlopt output"
        @test readchomp(`$opt -passes=x -S in.ll -o /dev/null`) == ""
        # a failure, and a crash, are passed on
        out = IOBuffer()
        proc = run(pipeline(ignorestatus(`$opt fail -S`); stdout=out))
        @test proc.exitcode == 3
        @test String(take!(out)) == "partial output\n"
        proc = run(pipeline(ignorestatus(`$opt crash -S`); stdout=devnull))
        @test proc.termsignal == 6  # SIGABRT
    end
end
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
    @test issetequal(keys(manifest["pins"]), ["1.10", "1.11", "1.12", "1.13", "1.14", "1.15"])
    # released versions are pinned, unreleased ones follow the nightly build of their
    # branch
    @test all(pin -> length(pin["commit"]) == 40,
              (pin for (minor, pin) in manifest["pins"] if !(minor in ("1.14", "1.15"))))
    @test !haskey(manifest["pins"]["1.14"], "commit")
    @test manifest["pins"]["1.14"]["tag"] == "release-1.14"
    @test !haskey(manifest["pins"]["1.15"], "commit")
    @test manifest["pins"]["1.15"]["tag"] == "master"
    # CI checks out the pinned commits, and the nightly builds' own
    ci = read(joinpath(dirname(@__DIR__), ".github", "workflows", "CI.yml"), String)
    refs = [m[1] for m in eachmatch(r"julia_ref: '([0-9a-f]{40})'", ci)]
    @test issetequal(refs, [pin["commit"] for pin in values(manifest["pins"])
                            if haskey(pin, "commit")])
    for (minor, pin) in manifest["pins"]
        haskey(pin, "commit") && continue
        version = pin["tag"] == "master" ? "nightly" : "$minor-nightly"
        @test occursin("{version: '$version', julia_ref: ''}", ci)
    end

    # the pin of a Julia version: its minor's, or for a newer prerelease, the newest
    # one if it follows the nightly build
    @test UpstreamHarness.pin_minor(manifest, v"1.13.2") == "1.13"
    @test UpstreamHarness.pin_minor(manifest, v"1.14.0-DEV.3787") == "1.14"
    @test UpstreamHarness.pin_minor(manifest, v"1.15.0-DEV.14") == "1.15"
    @test UpstreamHarness.pin_minor(manifest, v"1.16.0-DEV.1") == "1.15"
    @test_throws "no pin for Julia 1.16" UpstreamHarness.pin_minor(manifest, v"1.16.0")
    @test_throws "no pin for Julia 1.9" UpstreamHarness.pin_minor(manifest, v"1.9.4")
    released = deepcopy(manifest)
    released["pins"]["1.15"]["commit"] = "0"^40
    @test_throws "no pin for Julia 1.16" UpstreamHarness.pin_minor(released, v"1.16.0-DEV.1")
    for (name, entry) in manifest["fixtures"]
        get(entry, "status", "") in ("override", "derived") &&
            @test isfile(joinpath(@__DIR__, "upstream", entry["patch"]))
        for (_, overrides) in get(entry, "pins", Dict())
            get(overrides, "status", "") in ("override", "derived") &&
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
    noport_patch = joinpath(dir, "noport.ll.patch")
    write(noport_patch, """
        --- a/good.ll
        +++ b/good.ll
        @@ -1,1 +1,1 @@
        -; RUN: opt --load-pass-plugin=libjulia-codegen%shlibext -passes=RemoveNI -S %s | FileCheck %s
        +; RUN: opt -passes=verify -S %s | FileCheck %s
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

    # Julia's C++ passes, as the counterpart of the ports, only exist in Julia's LLVM
    if julia_llvm_in_use()
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
    end

    # a stale override
    stale = replace(override, "override.ll.patch" => "stale.ll.patch", "override.ll\"]" => "good.ll\"]")
    code, out = harness(write_manifest(stale * replace(override, "status = \"override\"" => "status = \"exclude\"") * excluded_cpp))
    @test code == 1
    @test occursin("good.ll: the override is stale", out)

    # a derived copy tests a port, so the pristine fixture may pass too; it must run a port
    derived = replace(stale, "status = \"override\"" => "status = \"derived\"")
    code, out = harness(write_manifest(derived * replace(override, "status = \"override\"" => "status = \"exclude\"") * excluded_cpp))
    @test code == 0
    @test occursin("1 of 1 fixtures passed", out)
    noport = replace(derived, "stale.ll.patch" => "noport.ll.patch")
    @test_throws "good.ll: the derived copy runs no port" harness(write_manifest(noport * replace(override, "status = \"override\"" => "status = \"exclude\"") * excluded_cpp))

    # every fixture must be in the manifest
    @test_throws "override.ll is not in the manifest" harness(write_manifest(good * excluded_cpp))

    # a skip for a port that exists is stale
    stale_skip = replace(good, "status = \"run\"" => "status = \"skip\"\nmissing = [\"RemoveNI\"]")
    @test_throws "which exist now" harness(write_manifest(stale_skip * override * excluded_cpp))

    # fixtures of ports that don't exist cannot run
    no_port = replace(good, "[\"RemoveNI\"]" => "[\"RemoveNI\", \"NoSuchPass\"]")
    @test_throws "the ports of NoSuchPass do not exist" harness(write_manifest(no_port * override * excluded_cpp))

    # the checkout must be at the pinned commit, with its fixtures unchanged
    @test_throws "but the fixtures of Julia $VERSION are those of $("0"^40)" harness(write_manifest(good * override * excluded_cpp; commit="0"^40))
    mv(joinpath(passes, "good.ll"), joinpath(dir, "good.ll"))
    @test_throws "differ from commit" harness(write_manifest(good * override * excluded_cpp))
    mv(joinpath(dir, "good.ll"), joinpath(passes, "good.ll"))
    write(joinpath(passes, "new.ll"), "")
    @test_throws "differ from commit" harness(write_manifest(good * override * excluded_cpp))
    rm(joinpath(passes, "new.ll"))

    # a pin without a commit (a prerelease's) takes the commit the running Julia was
    # built from
    dev = UpstreamHarness.load_manifest(write_manifest(good * override * excluded_cpp))
    delete!(dev["pins"][minor], "commit")
    check_pin(running_commit) = UpstreamHarness.check_pin(dev, src, minor; running_commit)
    if isempty(VERSION.prerelease)
        @test_throws "those of a development build" check_pin(commit)
    else
        @test check_pin(commit)["commit"] == commit
        @test !haskey(dev["pins"][minor], "commit")
        @test_throws "are those of $("1"^40) (test)" check_pin("1"^40)
        @test_throws "doesn't know the commit" check_pin("")
    end

    # the report covers every fixture
    code, out = harness(write_manifest(good * override * excluded_cpp), "--report")
    @test code == 0
    @test occursin("| good.ll | port | run | 1 run, 1 skipped | `jl-remove-ni` |", out)
    @test occursin("| excluded.ll | cpu | exclude |", out)

    # Mode B, on the library that LLVM.jl uses: the mode-B patch layer of its LLVM comes
    # after the mode-A patches, and each layer must be needed
    layer = joinpath(dir, "derived-B", "llvm$(LLVM.version().major)", minor)
    function with_layer(f, patches...)
        mkpath(layer)
        for (name, text) in patches
            write(joinpath(layer, name), text)
        end
        try
            f()
        finally
            rm(joinpath(dir, "derived-B"); recursive=true)
        end
    end
    fixed = read(patch, String)    # override.ll's fix, as a layer patch
    noop = read(stale_patch, String)
    noop_after_a = """
        --- a/override.ll
        +++ b/override.ll
        @@ -2,1 +2,1 @@
        -target datalayout = "e-i64:64-ni:10:11:12:13"
        +target datalayout = "e-i64:64-ni:10:11:12:13"
        """
    as_run = replace(override, "status = \"override\"" => "status = \"run\"")

    # without a layer, as mode A
    code, out = harness(write_manifest(good * override * excluded_cpp), "--mode", "B")
    @test code == 0
    @test occursin("mode B on $(julia_llvm_in_use() ? "Julia's own" : "a standalone") LLVM", out)
    @test occursin("2 of 2 fixtures passed", out)

    # a layer patch makes a fixture pass, and must be needed
    code, out = harness(write_manifest(good * as_run * excluded_cpp), "--mode", "B")
    @test code == 1
    with_layer("override.ll.patch" => fixed) do
        code, out = harness(write_manifest(good * as_run * excluded_cpp), "--mode", "B")
        @test code == 0
        @test occursin("patched: override.ll: derived-B/", out)
    end
    with_layer("good.ll.patch" => noop) do
        code, out = harness(write_manifest(good * override * excluded_cpp), "--mode", "B")
        @test code == 1
        @test occursin("good.ll: the mode-B patch is stale, the fixture passes without it", out)
    end
    # mode A ignores the layers
    with_layer("good.ll.patch" => noop) do
        code, _ = harness(write_manifest(good * override * excluded_cpp))
        @test code == 0
    end

    # a fixture with a mode-A patch gets the layer's after-A variant, on top of it; the
    # plain variant must not make the mode-A patch redundant
    with_layer("override.ll.after-A.patch" => noop_after_a) do
        code, out = harness(write_manifest(good * override * excluded_cpp), "--mode", "B")
        @test code == 1
        @test occursin("override.ll: the mode-B patch is stale", out)
    end
    with_layer("override.ll.patch" => fixed) do
        code, out = harness(write_manifest(good * override * excluded_cpp), "--mode", "B")
        @test code == 1
        @test occursin("override.ll: the override is stale, the fixture passes with the mode-B patch alone", out)
    end

    # a layer's patches must belong to fixtures of the pin
    with_layer("nosuch.ll.patch" => noop) do
        @test_throws "no fixture nosuch.ll at this pin" harness(write_manifest(good * override * excluded_cpp), "--mode", "B")
    end
    with_layer("good.ll.after-A.patch" => noop) do
        @test_throws "good.ll has no mode-A patch at this pin" harness(write_manifest(good * override * excluded_cpp), "--mode", "B")
    end

    # Julia's C++ passes are skipped in mode B
    manifest = UpstreamHarness.load_manifest(write_manifest(good * override * excluded_cpp))
    cpponly = mkpath(joinpath(dir, "cpponly", "test", "llvmpasses"))
    write(joinpath(cpponly, "good.ll"), """
        ; RUN: opt -passes='julia<level=2>' -S %s | FileCheck %s
        """)
    f = UpstreamHarness.plan_fixture(manifest, dirname(dirname(cpponly)), "good.ll", minor;
                                     cpp=false, mode="B", manifest_dir=dir)
    @test !f.included
    # (Julia's pipeline, while some of its passes have no port)
    @test startswith(f.reason, "every RUN line skipped: no port of Julia's ")

    # the upgrade oracle re-prints what opt writes as output, not its stderr: a fixture
    # whose RUN lines all check stderr sees the pin's printing only
    for (run, reprinted) in (("opt -passes=jl-remove-ni -S %s | FileCheck %s", true),
                             ("opt -passes='print<memoryssa>' -S -o /dev/null %s 2>&1 | FileCheck %s", false))
        write(joinpath(cpponly, "good.ll"), "; RUN: $run\n")
        f = UpstreamHarness.plan_fixture(manifest, dirname(dirname(cpponly)), "good.ll", minor;
                                         cpp=true, manifest_dir=dir)
        @test UpstreamHarness.reprints(f.runs) == reprinted
    end

    # The upgrade oracle: Julia's passes, their output re-printed by another LLVM's opt
    # (here, the same LLVM's), checked against the fixtures with that LLVM's layer
    if !Sys.iswindows() && julia_llvm_in_use()
        tools = joinpath(LLVM_utils_unified_jll.artifact_dir, "tools")
        newer = mkpath(joinpath(dir, "newer"))
        libpath = "$(lit_params(; exec_root=dir, bindir=dir)["libpath_env"])=" *
                  join(LLVM_utils_unified_jll.LIBPATH_list, ':')
        for tool in ("opt", "FileCheck")
            write(joinpath(newer, tool), "#!/bin/sh\nexec env $libpath $(joinpath(tools, tool)) \"\$@\"\n")
            chmod(joinpath(newer, tool), 0o755)
        end
        reprint = ["--cpp", "--reprint", joinpath(newer, "opt")]
        with_layer("override.ll.patch" => fixed) do
            code, out = harness(write_manifest(good * override * excluded_cpp), reprint...,
                                "--filter", "good|override")
            @test code == 0
            @test occursin("the upgrade oracle", out)
            @test occursin("2 of 2 fixtures passed", out)
        end
        with_layer("good.ll.patch" => noop) do
            code, out = harness(write_manifest(good * override * excluded_cpp), reprint...,
                                "--filter", "good")
            @test code == 1
            @test occursin("good.ll: the mode-B patch is stale", out)
        end
    end
    @test_throws "--reprint requires --cpp" harness(write_manifest(good * override * excluded_cpp), "--reprint", "opt")
    @test_throws "mode B doesn't have" harness(write_manifest(good * override * excluded_cpp), "--cpp", "--mode", "B")
end
end

end
