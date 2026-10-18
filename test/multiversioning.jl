using LLVM, LLVM.IR, LLVM.Passes
using JuliaIR: Dialect, MultiVersioningTarget, MultiVersioningError

@testset "MultiVersioning" begin

# the dialects of every version, and the running Julia's
dialects = Dialect.((v"1.10", v"1.11", v"1.12", v"1.13", v"1.14.0-DEV"))
dialect = Dialect(VERSION)

# a module with the `julia.mv.specs` flag `specs`: a tuple on the first line, followed by
# the definitions of the nodes it refers to
function specs_module(specs)
    tuple, defs = occursin('\n', specs) ? split(specs, '\n'; limit=2) : (specs, "")
    return """
        !llvm.module.flags = !{!0}
        !0 = !{i32 1, !"julia.mv.specs", $tuple}
        $defs
        """
end

@testset "targets" begin
    t = MultiVersioningTarget("haswell", "+avx2"; base=0, clone=(:simd, :loop))
    @test t.clone == (:loop, :simd)   # in a canonical order
    @test t == MultiVersioningTarget("haswell", "+avx2"; clone=[:loop, :simd])
    @test sprint(show, t) == """JuliaIR.MultiVersioningTarget("haswell", "+avx2"; clone=(:loop, :simd))"""
    @test sprint(show, MultiVersioningTarget("a", ""; base=1, opt_size=true)) ==
          """JuliaIR.MultiVersioningTarget("a", ""; base=1, opt_size=true)"""
    @test_throws "unknown clone category :vector" MultiVersioningTarget("a", ""; clone=(:vector,))
    @test_throws "index of 0 or more" MultiVersioningTarget("a", ""; base=-1)

    targets = [MultiVersioningTarget("generic", ""),
               MultiVersioningTarget("sandybridge", "+avx"; clone_all=true),
               MultiVersioningTarget("haswell", "+avx2,+fma"; base=1, min_size=true,
                                     clone=(:loop, :cpu, :math, :simd, :float16)),
               MultiVersioningTarget("znver4", "+avx512bf16"; base=0, opt_size=true,
                                     clone=(:loop, :cpu, :bfloat16))]

    # flag encodings
    d13, dm = dialects[4], dialects[5]
    @test JuliaIR.encode_flags.(targets, Ref(d13)) == [0, 2, 0x80 | 8 | 256 | 4 | 16 | 512,
                                                         0x40 | 8 | 256 | 1024]
    @test JuliaIR.encode_flags.(targets, Ref(dm)) == [0, 1, 4 | 8 | 16 | 32, 2 | 64]
    @test_throws "doesn't clone functions for bfloat16" JuliaIR.encode_flags(targets[4], dialects[1])
    # master clones loops and CPU queries for every target that doesn't clone everything
    @test JuliaIR.normalize_target(MultiVersioningTarget("a", ""; clone=(:math,)), dm).clone ==
          (:loop, :math, :cpu)
    @test JuliaIR.normalize_target(MultiVersioningTarget("a", ""; clone=(:math,)), d13).clone ==
          (:math,)

    # round trips through the module flag
    for d in dialects
        ts = d.mv_bf16 ? targets : targets[1:3]
        @dispose ctx=Context(; opaque_pointers=true) mod=LLVM.Module("test") begin
            JuliaIR.set_target_specs!(mod, ts, d)
            @test JuliaIR.target_specs(mod, d) == [JuliaIR.normalize_target(t, d) for t in ts]
        end
    end

    # the encoding of the running Julia
    @dispose ctx=Context(; opaque_pointers=true) mod=LLVM.Module("test") begin
        @test JuliaIR.target_specs(mod) === nothing
        JuliaIR.set_target_specs!(mod, targets[1:3], dialect)
        @test JuliaIR.target_specs(mod) == JuliaIR.target_specs(mod, dialect)
    end

    # the specs of Julia's tests, in both encodings
    upstream = """!{!1, !2, !3}
        !1 = !{!"cpubase", !"nofeatures", i32 0, i32 FLAGS0}
        !2 = !{!"cpucloneall", !"cloneall", i32 0, i32 FLAGS1}
        !3 = !{!"cpufastmath", !"fastmathclone", i32 0, i32 FLAGS2}"""
    for (d, flags) in [(d13, (2, 2, 4)), (dm, (0, 1, 8))]
        text = replace(upstream, "FLAGS0" => flags[1], "FLAGS1" => flags[2],
                       "FLAGS2" => flags[3])
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, specs_module(text)) begin
            ts = JuliaIR.target_specs(mod, d)
            @test length(ts) == 3
            @test ts[2].clone_all && !ts[3].clone_all
            @test (ts[3].cpu, ts[3].features, ts[3].base) == ("cpufastmath", "fastmathclone", 0)
            @test :math in ts[3].clone
            @test (:loop in ts[3].clone) == (d === dm)
        end
    end

    # malformed flags
    for (specs, msg) in [("!{}", "there are no targets"),
                         ("!{!1}\n!1 = !{!\"a\", !\"b\", i32 0}", "not a tuple of four"),
                         ("!{!1}\n!1 = !{!\"a\", i32 0, i32 0, i32 0}", "are not strings"),
                         ("!{!1}\n!1 = !{!\"a\", !\"b\", i32 0, !\"c\"}", "not 32-bit integers"),
                         ("!{!1}\n!1 = !{!\"a\", !\"b\", i64 4294967296, i32 0}", "not 32-bit integers")]
        @dispose ctx=Context(; opaque_pointers=true) mod=parse(LLVM.Module, specs_module(specs)) begin
            @test_throws MultiVersioningError JuliaIR.target_specs(mod, dialect)
            @test_throws msg JuliaIR.target_specs(mod, dialect)
        end
    end

    # the module's targets, or the option's
    ts = targets[1:3]
    @dispose ctx=Context(; opaque_pointers=true) mod=LLVM.Module("test") begin
        @test_throws "no julia.mv.specs flag and no targets were given" JuliaIR.resolve_targets(mod, MultiVersioningTarget[], dialect)
        @test JuliaIR.resolve_targets(mod, ts, dialect) ==
              ([JuliaIR.normalize_target(t, dialect) for t in ts], true)
        JuliaIR.set_target_specs!(mod, ts, dialect)
        @test JuliaIR.resolve_targets(mod, MultiVersioningTarget[], dialect) ==
              (JuliaIR.target_specs(mod, dialect), false)
        @test JuliaIR.resolve_targets(mod, ts, dialect) ==
              (JuliaIR.target_specs(mod, dialect), false)
        @test_throws "differ from the module's julia.mv.specs" JuliaIR.resolve_targets(mod, ts[1:2], dialect)
    end

    # groups
    @test JuliaIR.check_targets(targets) === nothing
    bad = [MultiVersioningTarget("a", ""), MultiVersioningTarget("b", ""; clone=(:loop,)),
           MultiVersioningTarget("c", ""; base=1, clone=(:loop,))]
    @test_throws "base of target 2 (c) is 1" JuliaIR.check_targets(bad)
    @test_throws "base of target 1 (b) is 1" JuliaIR.check_targets(
        [MultiVersioningTarget("a", ""), MultiVersioningTarget("b", ""; base=1)])
end

end
