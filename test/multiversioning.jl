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

# the module flags of a module for the pass, after the module's own `extra` flags
function mv_flags(extra::String...; enable=true)
    flags = String[]
    enable && push!(flags, """!{i32 1, !"julia.mv.enable", i32 1}""")
    append!(flags, extra)
    names = ["!$(100+i)" for i in eachindex(flags)]
    return "!llvm.module.flags = !{$(join(names, ", "))}\n" *
           join(("$n = $f" for (n, f) in zip(names, flags)), "\n") * "\n"
end
SKIPCLONING = """!{i32 1, !"julia.mv.skipcloning", i32 1}"""

# run the pass on a module, and return what `f` says about the result
function multiversion(f, ir::String; kwargs...)
    @dispose ctx=Context(; opaque_pointers=true) begin
        mod = parse(LLVM.Module, ir)
        try
            run!(JuliaIR.MultiVersioningPass(; kwargs...), mod)
            verify(mod)
            return f(mod)
        finally
            dispose(mod)
        end
    end
end

attribute(f::LLVM.Function, kind) = JuliaIR.string_attribute(f, kind)

# the annotations of the functions of a module: the targets they are cloned for, and
# whether they get a relocation slot (`:reloc`) or are only in the function table (`:fvar`)
function annotations(mod)
    result = Dict{String,Any}()
    for f in mod.functions
        isdeclaration(f) && continue
        clones = attribute(f, "julia.mv.clones")
        bits = clones === nothing ? Int[] :
               [i - 1 for i in 1:64 if (parse(UInt64, clones; base=16) >> (i - 1)) & 1 == 1]
        reloc = attribute(f, "julia.mv.reloc") !== nothing ? :reloc :
                attribute(f, "julia.mv.fvar") !== nothing ? :fvar : :none
        result[f.name] = (bits, reloc)
    end
    return result
end

flag_count(mod, name) =
    count(op -> op.operands[2] == MDString(name), mod.metadata["llvm.module.flags"].operands)

@testset "annotation" begin
    # one function per trigger of a category, and the categories it triggers
    categories_ir = """
        declare float @llvm.fma.f32(float, float, float)
        declare float @llvm.muladd.f32(float, float, float)
        declare <4 x float> @vector_decl(<4 x float>)
        declare i1 @julia.cpu.have_fma.f64()
        declare i1 @julia.cpu.supports.avx()
        declare i32 @personality(...)

        define i32 @boring(i32 %x) {
          ret i32 %x
        }
        define float @fastmath(float %x) {
          %y = fadd nnan float %x, %x
          ret float %y
        }
        define float @fma(float %x) {
          %y = call float @llvm.fma.f32(float %x, float %x, float %x)
          ret float %y
        }
        define float @muladd(float %x) {
          %y = call float @llvm.muladd.f32(float %x, float %x, float %x)
          ret float %y
        }
        define i32 @loop(i32 %n) {
        top:
          br label %body
        body:
          %i = phi i32 [ 0, %top ], [ %j, %body ]
          %j = add i32 %i, 1
          %c = icmp eq i32 %j, %n
          br i1 %c, label %exit, label %body
        exit:
          ret i32 %j
        }
        define i32 @vector_signature(<4 x i32> %v) {
          %x = extractelement <4 x i32> %v, i64 0
          ret i32 %x
        }
        define float @vector_call(float %x) {
          %v = call <4 x float> @vector_decl(<4 x float> zeroinitializer)
          ret float %x
        }
        define void @vector_store(ptr %p) {
          store <2 x i32> zeroinitializer, ptr %p
          ret void
        }
        define <2 x i32> @vector_result_call() {
          %v = insertelement <2 x i32> zeroinitializer, i32 1, i64 0
          ret <2 x i32> %v
        }
        define i32 @vector_value(i32 %x) {
          %v = insertelement <2 x i32> zeroinitializer, i32 %x, i64 0
          %y = extractelement <2 x i32> %v, i64 1
          ret i32 %y
        }
        define float @vector_invoke(float %x) personality ptr @personality {
          %v = invoke <4 x float> @vector_decl(<4 x float> zeroinitializer)
                  to label %ok unwind label %bad
        ok:
          ret float %x
        bad:
          %lp = landingpad { ptr, i32 } cleanup
          ret float %x
        }
        define i1 @have_fma() {
          %x = call i1 @julia.cpu.have_fma.f64()
          ret i1 %x
        }
        define i1 @supports() {
          %x = call i1 @julia.cpu.supports.avx()
          ret i1 %x
        }
        define half @float16(half %x) {
          %y = fadd half %x, %x
          ret half %y
        }
        define i16 @float16_vector(<2 x half> %v) {
          %y = bitcast <2 x half> %v to i32
          %z = trunc i32 %y to i16
          ret i16 %z
        }
        define bfloat @bfloat16(bfloat %x) {
          %y = fadd bfloat %x, %x
          ret bfloat %y
        }
        """
    expected = Dict("boring" => (), "fastmath" => (:math,), "fma" => (:math,),
                    "muladd" => (:math,), "loop" => (:loop,),
                    "vector_signature" => (:simd,), "vector_call" => (:simd,),
                    "vector_store" => (:simd,), "vector_result_call" => (:simd,),
                    "vector_value" => (:simd,), "vector_invoke" => (:simd,),
                    "have_fma" => (:cpu,), "supports" => (:cpu,),
                    "float16" => (:float16,), "float16_vector" => (:simd,),
                    "bfloat16" => dialect.mv_bf16 ? (:bfloat16,) : ())

    category_targets(categories) =
        [MultiVersioningTarget("base", ""), MultiVersioningTarget("all", ""; clone_all=true),
         (MultiVersioningTarget(string(c), "+$c"; clone=(c,)) for c in categories)...]
    categories = [:loop, :simd, :math, :cpu, :float16]
    dialect.mv_bf16 && push!(categories, :bfloat16)
    targets = category_targets(categories)
    normalized = [JuliaIR.normalize_target(t, dialect) for t in targets]

    for (triple, fma_category) in [("x86_64-unknown-linux-gnu", (:cpu,)),
                                   ("aarch64-unknown-linux-gnu", ())]
        ir = "target triple = \"$triple\"\n" * categories_ir * mv_flags(SKIPCLONING)
        result = multiversion(annotations, ir; targets)
        for (name, cats) in expected
            name == "have_fma" && (cats = fma_category)
            # the targets that clone everything, or one of the function's categories
            bits = [i - 1 for (i, t) in enumerate(normalized)
                    if i > 1 && (t.clone_all || any(in(t.clone), cats))]
            @test (name, result[name][1]) == (name, bits)
            # no function uses another
            @test (name, result[name][2]) == (name, :none)
        end
    end

    # the flags it adds
    multiversion(categories_ir * mv_flags(SKIPCLONING); targets) do mod
        @test JuliaIR.target_specs(mod) == normalized
        @test flag_count(mod, "julia.mv.annotated") == 1
        @test flag_count(mod, "julia.mv.veccall") == 1
        @test JuliaIR.module_flag(mod, "julia.mv.veccall") ==
              (; behavior=JuliaIR.MODULE_FLAG_MAX, value=Metadata(ConstantInt(Int32(1))))
    end
    multiversion("define void @f() {\n ret void\n}\n" * mv_flags(SKIPCLONING); targets) do mod
        @test flag_count(mod, "julia.mv.veccall") == 0
    end
    # an identical veccall flag is kept, a conflicting one rejected (the C++ adds another)
    multiversion(categories_ir * mv_flags(SKIPCLONING, """!{i32 7, !"julia.mv.veccall", i32 1}""");
                 targets) do mod
        @test flag_count(mod, "julia.mv.veccall") == 1
    end
    @test_throws "julia.mv.veccall flag, which differs" multiversion(identity, categories_ir *
        mv_flags(SKIPCLONING, """!{i32 1, !"julia.mv.veccall", i32 1}"""); targets)
    # without the enable flag, nothing happens
    multiversion(categories_ir * mv_flags(SKIPCLONING; enable=false); targets) do mod
        @test !haskey(mod.metadata, "llvm.module.flags") ||
              flag_count(mod, "julia.mv.annotated") == 0
        @test all(isempty(first(a)) for a in values(annotations(mod)))
    end

    # The callers and callees of cloned functions in between them are cloned too, also when
    # they are only found in a later round. The C++ pass visits functions in the order of
    # their addresses and doesn't revisit them, so whether it clones `c` varies.
    callgraph_ir(order) = join(order, "\n") * """
        define void @loop1(i32 %n) {
        top:
          br label %body
        body:
          call void @c()
          %c = icmp eq i32 %n, 0
          br i1 %c, label %exit, label %body
        exit:
          ret void
        }
        define void @loop2(i32 %n) {
        top:
          br label %body
        body:
          call void @g()
          %c = icmp eq i32 %n, 0
          br i1 %c, label %exit, label %body
        exit:
          ret void
        }
        define void @leaf() {
          ret void
        }
        """ * mv_flags(SKIPCLONING)
    c = "define void @c() {\n  call void @g()\n  call void @leaf()\n  ret void\n}"
    g = "define void @g() {\n  call void @loop1(i32 0)\n  ret void\n}"
    loop_targets = [MultiVersioningTarget("base", ""),
                    MultiVersioningTarget("loop", ""; clone=(:loop, :cpu))]
    for order in ([c, g], [g, c])
        result = multiversion(annotations, callgraph_ir(order); targets=loop_targets)
        @test result["loop1"][1] == result["loop2"][1] == [1]
        @test result["g"][1] == result["c"][1] == [1]
        # leaf calls nothing that is cloned
        @test result["leaf"][1] == []
        # functions used by cloned callers through instructions get slots
        @test result["c"][2] == result["g"][2] == result["loop1"][2] == :reloc
        @test result["loop2"][2] == :none
    end

    # relocation slots and the function table
    reloc_ir = """
        @gv = global ptr @in_global
        @alias = alias void (), ptr @aliased
        define void @in_global() {
          ret void
        }
        define void @aliased() {
          ret void
        }
        define float @called(float %x) {
          %y = fadd fast float %x, %x
          ret float %y
        }
        define float @caller(float %x) {
          %y = call float @called(float %x)
          ret float %y
        }
        define float @cloned_in_global(float %x) {
          %y = fadd fast float %x, %x
          ret float %y
        }
        @gv2 = global ptr @cloned_in_global
        """ * mv_flags(SKIPCLONING)
    math_targets = [MultiVersioningTarget("base", ""),
                    MultiVersioningTarget("math", ""; clone=(:math, :loop, :cpu))]
    result = multiversion(annotations, reloc_ir; targets=math_targets)
    @test result["in_global"] == ([], :fvar)
    @test result["aliased"] == ([], :reloc)
    @test result["called"] == ([1], :reloc)
    @test result["caller"] == ([], :none)
    @test result["cloned_in_global"] == ([1], :fvar)
    # with one target, nothing needs a slot
    result = multiversion(annotations, reloc_ir; targets=math_targets[1:1])
    @test all(==(([], :none)), values(result))

    # clone sets of more than four targets need more than one hexadecimal digit
    multiversion(categories_ir * mv_flags(SKIPCLONING); targets) do mod
        @test attribute(mod.functions["boring"], "julia.mv.clones") == "2"
        @test attribute(mod.functions["fastmath"], "julia.mv.clones") ==
              uppercase(string(2 | 1 << 4; base=16))
    end
end

end
