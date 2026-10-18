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

    # a function passed to a callee with `!callback` metadata is called by it, like LLVM's
    # call graph says: `cb` is called by and calls the loop, so it is cloned too
    callback_ir(callback) = """
        declare $(callback ? "!callback !0 " : "")void @broker(ptr, i32)
        define void @loop(i32 %n) {
        top:
          br label %body
        body:
          call void @broker(ptr @cb, i32 %n)
          %c = icmp eq i32 %n, 0
          br i1 %c, label %exit, label %body
        exit:
          ret void
        }
        define void @cb() {
          call void @loop(i32 0)
          ret void
        }
        !0 = !{!1}
        !1 = !{i64 0, i1 false}
        """ * mv_flags(SKIPCLONING)
    @test multiversion(annotations, callback_ir(true); targets=loop_targets)["cb"][1] == [1]
    @test multiversion(annotations, callback_ir(false); targets=loop_targets)["cb"][1] == []

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


# An annotated module for cloning: `ir` with the function table `fvars` (and an empty
# `jl_gvars` for Julia 1.10), for the targets `two_targets` unless the module flags say
# otherwise
two_targets = [MultiVersioningTarget("base", "+base"),
               MultiVersioningTarget("math", "+math"; clone=(:math,))]
function cloning_ir(ir::String, fvars::Vector{String}; flags::Vector{String}=String[],
                    tables::Bool=true)
    entries = join(("ptr @$f" for f in fvars), ", ")
    idxs = join(("i32 $i" for i in eachindex(fvars) .- 1), ", ")
    head = tables ? """
        @jl_fvars = hidden constant [$(length(fvars)) x ptr] [$entries]
        @jl_fvar_idxs = global [$(length(fvars)) x i32] [$idxs]
        @jl_gvars = hidden constant [0 x ptr] zeroinitializer
        @jl_gvar_idxs = global [0 x i32] zeroinitializer
        """ : ""
    annotated = """!{i32 1, !"julia.mv.annotated", i32 1}"""
    return head * ir * mv_flags(annotated, flags...)
end

# Clone a module for the IR of Julia version `d` (by calling the pass's implementation, as
# the pass itself uses the running Julia's), and return what `f` says about the result.
function clone_module(f, ir::String, d::Dialect=dialect; targets=two_targets, external=false,
               datalayout=nothing)
    @dispose ctx=Context(; opaque_pointers=true) begin
        mod = parse(LLVM.Module, ir)
        try
            datalayout === nothing || (mod.datalayout = datalayout)
            JuliaIR.set_target_specs!(mod, targets, d)
            JuliaIR.run_multiversioning!(mod, nothing, d, external, MultiVersioningTarget[])
            verify(mod)
            return f(mod)
        finally
            dispose(mod)
        end
    end
end

# the elements of an array initializer, as text (global values by name)
function table(mod, name)
    init = mod.globals[name].initializer
    elements = (Value(LLVM.API.LLVMGetAggregateElement(init, i))
                for i in 0:init.value_type.length-1)
    return [e isa GlobalValue ? "@" * e.name : string(e) for e in elements]
end

@testset "cloning" begin
    # `f` is cloned and called by `g`; `h` is in a global initializer
    ir = cloning_ir("""
        @gv = global { i64, ptr } { i64 1, ptr @h }
        define void @f() #0 {
          ret void
        }
        define void @g() #1 {
          call void @f()
          ret void
        }
        define void @h() #2 {
          ret void
        }
        attributes #0 = { "julia.mv.clones"="2" "julia.mv.reloc" }
        attributes #1 = { "julia.mv.clones"="0" }
        attributes #2 = { "julia.mv.clones"="2" "julia.mv.fvar" }
        """, ["f", "g", "h"])
    for d in dialects
        clone_module(ir, d) do mod
            fs = mod.functions
            @test haskey(fs, "f.1") && haskey(fs, "h.1") && !haskey(fs, "g.1")
            @test attribute(fs["f.1"], "target-cpu") == "math"
            @test attribute(fs["f.1"], "julia.mv.clone") == "1"
            @test attribute(fs["f"], "target-features") == "+base"
            # g calls f through its slot, which the loader fills in with f or f.1
            slot = mod.globals["f.reloc_slot"]
            @test any(i -> i isa LoadInst && i.operands[1] == slot,
                      fs["g"].entry.instructions)
            # Julia 1.12 and later initialize the runtime when the slot is called first
            if d.mv_autoinit
                @test slot.initializer == fs["f.autoinit_trampoline"]
            else
                @test LLVM.isnull(slot.initializer)
            end
            # the global is written by the loader too
            @test string(mod.globals["gv"].initializer) == "{ i64, ptr } { i64 1, ptr null }"
            if d.mv_tables === :offsets
                @test haskey(mod.aliases, "jl_fvar_base")
                @test table(mod, "jl_fvar_offsets")[1:2] == ["i32 3", "i32 0"]
                @test table(mod, "jl_gvar_offsets") == ["i32 0"]
                @test length(table(mod, "jl_clone_offsets")) == 2
                @test !haskey(mod.globals, "jl_gvars")
            else
                @test mod.globals["jl_fvar_count"].initializer == ConstantInt(Int64(3))
                @test table(mod, "jl_fvar_ptrs") == ["@f", "@g", "@h"]
                @test table(mod, "jl_clone_ptrs") == ["@f.1", "@h.1"]
                @test haskey(mod.globals, "jl_gvars")   # not a table there
            end
            # two relocations (the slot of f, and the global's pointer to h at offset 8)
            slots = table(mod, "jl_clone_slots")
            @test slots[1] == "i32 2" && slots[2] == "i32 0" && slots[4] == "i32 2"
            @test occursin("i64 8", slots[5])
            # target 0 lists the relocated functions, target 1 its base and its clones,
            # with the relocated ones tagged
            tag(i) = "i32 $(reinterpret(Int32, 0x80000000 | UInt32(i)))"
            @test table(mod, "jl_clone_idxs") == [tag(2), "i32 0", "i32 2",
                                                  "i32 2", "i32 0", tag(0), tag(2)]
        end
    end

    # with a suffix, the tables are named after it
    suffixed = replace(ir, "!llvm.module.flags = !{" => "!llvm.module.flags = !{!99, ") *
               """!99 = !{i32 1, !"julia.mv.suffix", !"_sfx"}\n"""
    clone_module(suffixed) do mod
        @test haskey(mod.globals, "jl_clone_idxs_sfx") && haskey(mod.globals, "jl_fvar_idxs_sfx")
        @test !haskey(mod.globals, "jl_clone_idxs")
    end

    # Julia 1.10 truncates the offsets of 32-bit IR when it runs on a 64-bit host, which is
    # invalid IR; the port goes by the module's pointer size
    clone_module(ir, dialects[1]; datalayout="e-p:32:32-i64:64-n8:16:32-S128") do mod
        @test !any(occursin("trunc", e) for e in table(mod, "jl_clone_offsets"))
        @test !any(occursin("trunc", e) for e in table(mod, "jl_clone_slots"))
    end

    # aliases become trampolines that call through the slot, with the calling convention
    # and the attributes of the function (also before Julia 1.13), and their uses call
    # the trampoline
    alias_ir = cloning_ir("""
        @a = alias void (ptr), ptr @f
        define cc 10 void @f(ptr byval(i64) "julia.return_roots"="1" %x) #0 {
          ret void
        }
        define void @user(ptr %p) #1 {
          call cc 10 void @a(ptr byval(i64) %p)
          ret void
        }
        attributes #0 = { "julia.mv.clones"="2" "julia.mv.reloc" }
        attributes #1 = { "julia.mv.clones"="0" }
        """, ["f", "user"])
    for d in dialects
        clone_module(alias_ir, d) do mod
            a = mod.functions["a"]
            @test attribute(a, "julia.mv.alias") == ""
            @test !haskey(mod.aliases, "a")
            call = last(collect(a.entry.instructions)).prev
            @test call.callconv == 10
            @test haskey(call.argument_attributes[1], :byval)
            @test !haskey(call.argument_attributes[1], "julia.return_roots")
            user_call = first(mod.functions["user"].entry.instructions)
            @test user_call isa CallInst && user_call.called_operand == a
        end
    end

    # vararg functions are called with musttail by their trampolines, also on ARM and
    # PowerPC (like Julia's release builds; its assertions reject them there)
    vararg_ir = cloning_ir("""
        @a = alias void (i32, ...), ptr @f
        define void @f(i32 %x, ...) #0 {
          ret void
        }
        attributes #0 = { "julia.mv.clones"="2" "julia.mv.reloc" }
        """, ["f"])
    for triple in ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu",
                   "armv7l-unknown-linux-gnueabihf", "powerpc64le-unknown-linux-gnu")
        clone_module("target triple = \"$triple\"\n" * vararg_ir) do mod
            call = last(collect(mod.functions["a"].entry.instructions)).prev
            @test call.tailcall_kind == LLVM.TailCallKind.MustTail
        end
    end

    # Uses through constant expressions and aggregates become instructions, and phi
    # operands are loaded in the incoming block.
    uses_ir = cloning_ir("""
        define void @f() #0 {
          ret void
        }
        define ptr @user(i1 %c, ptr %p) #1 {
        top:
          store i64 add (i64 ptrtoint (ptr @f to i64), i64 1), ptr %p
          store { ptr, i64 } { ptr @f, i64 1 }, ptr %p
          store <2 x ptr> <ptr null, ptr @f>, ptr %p
          br i1 %c, label %a, label %b
        a:
          br label %join
        b:
          br label %join
        join:
          %r = phi ptr [ @f, %a ], [ null, %b ]
          ret ptr %r
        }
        attributes #0 = { "julia.mv.clones"="2" "julia.mv.reloc" }
        attributes #1 = { "julia.mv.clones"="0" }
        """, ["f", "user"])
    clone_module(uses_ir) do mod
        user = mod.functions["user"]
        slot = mod.globals["f.reloc_slot"]
        loads = [i for bb in user.blocks for i in bb.instructions
                 if i isa LoadInst && i.operands[1] == slot]
        @test length(loads) == 4
        @test any(i -> i isa InsertValueInst, user.entry.instructions)
        @test any(i -> i isa InsertElementInst, user.entry.instructions)
        @test any(i -> i isa PtrToIntInst, user.entry.instructions)
        a = only(bb for bb in user.blocks if bb.name == "a")
        @test first(a.instructions) isa LoadInst
        @test all(u -> !(u.user isa Instruction), mod.functions["f"].uses)
    end

    # functions that are declared get slots of their own, which the loader fills in
    extern_ir = cloning_ir("""
        declare void @ext() #0
        define void @user() #1 {
          call void @ext()
          ret void
        }
        attributes #0 = { "julia.mv.clones"="2" "julia.mv.reloc" }
        attributes #1 = { "julia.mv.clones"="0" }
        """, ["user"])
    clone_module(extern_ir) do mod
        @test isdeclaration(mod.functions["ext.1"])
        @test isdeclaration(mod.globals["ext.reloc_slot"])
    end

    # targets that clone everything, and targets based on them
    group_targets = [MultiVersioningTarget("base", ""),
                     MultiVersioningTarget("all", ""; clone_all=true),
                     MultiVersioningTarget("part", ""; base=1, min_size=true, clone=(:math,))]
    group_ir = cloning_ir("""
        define void @f() #0 {
          ret void
        }
        define void @g() #1 {
          call void @f()
          ret void
        }
        define void @n() #2 {
          ret void
        }
        define void @r() #3 {
          ret void
        }
        attributes #0 = { "julia.mv.clones"="6" "julia.mv.reloc" }
        attributes #1 = { "julia.mv.clones"="2" }
        attributes #2 = { noinline optnone "julia.mv.clones"="6" }
        attributes #3 = { "julia.mv.clones"="2" "julia.mv.reloc" }
        """, ["f", "g", "n", "r"])
    clone_module(group_ir; targets=group_targets) do mod
        fs = mod.functions
        @test haskey(fs, "g.1") && !haskey(fs, "g.2")
        # g.1 calls f.1 or f.2 through the slot
        @test any(i -> i isa LoadInst, fs["g.1"].entry.instructions)
        @test haskey(fs["f.2"].function_attributes, :minsize)
        @test !haskey(fs["n.2"].function_attributes, :minsize)
        # per target: the relocated functions f and r (tagged counts); for target 2, its
        # base, f and r, which it relocates (tagged), and n, which it only has a clone of
        tag(x) = "i32 $(reinterpret(Int32, UInt32(x) | 0x80000000))"
        @test table(mod, "jl_clone_idxs") == [tag(2), "i32 0", "i32 3",
                                              tag(2), "i32 0", "i32 3",
                                              "i32 3", "i32 1", tag(0), "i32 2", tag(3)]
        # target 2 relocates r to target 1's version, as it has none of its own
        if dialect.mv_tables === :offsets
            @test length(table(mod, "jl_clone_offsets")) == 7
        else
            @test table(mod, "jl_clone_ptrs") ==
                  ["@f.1", "@g.1", "@n.1", "@r.1", "@f.2", "@n.2", "@r.1"]
        end
    end

    # `external`: entries of the function table that aren't definitions are left out
    # (the C++ pass leaves out every entry after the first of them), and modules without
    # a table are only annotated
    external_ir = cloning_ir("""
        declare void @decl()
        define void @f() #0 {
          ret void
        }
        define void @g() #0 {
          ret void
        }
        attributes #0 = { "julia.mv.clones"="2" }
        """, ["f", "decl", "g"])
    @test_throws "entry that is not a function" clone_module(identity, replace(external_ir, "ptr @decl" => "ptr null"))
    clone_module(external_ir, dialects[2]; external=true) do mod
        @test table(mod, "jl_fvar_ptrs") == ["@f", "@g"]
    end
    no_table = cloning_ir("define void @f() #0 {\n  ret void\n}\n" *
                          """attributes #0 = { "julia.mv.clones"="2" }\n""", String[];
                          tables=false)
    @test_throws "jl_fvars is missing" clone_module(identity, no_table)
    clone_module(no_table; external=true) do mod
        @test !haskey(mod.functions, "f.1")
    end
end

@testset "malformed input" begin
    # nothing changes before the error
    function rejects(msg, ir::String, d::Dialect=dialect; targets=two_targets)
        @dispose ctx=Context(; opaque_pointers=true) begin
            mod = parse(LLVM.Module, ir)
            JuliaIR.set_target_specs!(mod, targets, d)
            before = string(mod)
            err = try
                JuliaIR.run_multiversioning!(mod, nothing, d, false, MultiVersioningTarget[])
                nothing
            catch err
                err
            end
            @test err isa MultiVersioningError && occursin(msg, err.msg)
            @test string(mod) == before
            dispose(mod)
        end
    end
    f_ir(attrs="\"julia.mv.clones\"=\"2\" \"julia.mv.reloc\"") = """
        define void @f() #0 {
          ret void
        }
        attributes #0 = { $attrs }
        """

    rejects("jl_fvar_idxs is missing",
            replace(cloning_ir(f_ir(), ["f"]), r"@jl_fvar_idxs = .*\n" => ""))
    # the loader reads a 32-bit index for every function
    rejects("jl_fvar_idxs is not an array of at least 2 32-bit indices",
            replace(cloning_ir(f_ir() * "define void @g() {\n  ret void\n}\n", ["f", "g"]),
                    "[2 x i32] [i32 0, i32 1]" => "[1 x i32] [i32 0]"))
    rejects("jl_fvar_idxs is not an array of at least 1 32-bit indices",
            replace(cloning_ir(f_ir(), ["f"]), "[1 x i32] [i32 0]" => "[1 x i64] [i64 0]"))
    rejects("jl_gvar_idxs is not an array of at least 1 32-bit indices",
            replace(cloning_ir(f_ir() * "@v = global i32 0\n", ["f"]),
                    "[0 x ptr] zeroinitializer" => "[1 x ptr] [ptr @v]"), dialects[1])
    rejects("jl_gvars is missing",
            replace(cloning_ir(f_ir(), ["f"]), r"@jl_gvars = .*\n" => ""), dialects[1])
    rejects("jl_fvars is used",
            cloning_ir(f_ir() * "@user = global ptr @jl_fvars\n", ["f"]))
    rejects("is zero-initialized",
            replace(cloning_ir(f_ir(), ["f"]), "[ptr @f]" => "zeroinitializer"))
    rejects("not a string", replace(cloning_ir(f_ir(), ["f"]),
        "!llvm.module.flags = !{" => "!llvm.module.flags = !{!99, ") *
        """!99 = !{i32 1, !"julia.mv.suffix", i32 1}\n""")
    rejects("julia.mv.reloc attribute, but no julia.mv.clones",
            cloning_ir(f_ir("\"julia.mv.reloc\""), ["f"]))
    rejects("f needs a relocation, but is not in the table",
            cloning_ir(f_ir() * "define void @g() {\n  ret void\n}\n", ["g"]))

    # every function needs a version for targets that clone everything
    all_targets = [MultiVersioningTarget("base", ""),
                   MultiVersioningTarget("all", ""; clone_all=true)]
    rejects("f is not cloned for target 1 (all)",
            cloning_ir(f_ir("\"julia.mv.fvar\""), ["f"]); targets=all_targets)

    # calls from cloned functions go through the slot of the callee
    rejects("f is called by g, which is cloned, but has no julia.mv.reloc",
            cloning_ir(f_ir("\"julia.mv.clones\"=\"2\"") * """
                define void @g() #1 {
                  call void @f()
                  ret void
                }
                attributes #1 = { "julia.mv.clones"="2" }
                """, ["f", "g"]))

    # a load from the slot can't come before an exception handling pad (the C++ pass emits
    # invalid IR)
    rejects("used by an exception handling instruction of g",
            cloning_ir(f_ir() * """
                declare i32 @personality(...)
                declare void @throws()
                define void @g() #1 personality ptr @personality {
                  invoke void @throws() to label %ok unwind label %pad
                ok:
                  ret void
                pad:
                  %lp = landingpad { ptr, i32 } catch ptr @f
                  ret void
                }
                attributes #1 = { "julia.mv.clones"="0" }
                """, ["f", "g"]))

    # global values that refer to a cloned function
    rejects("through a constant that changes its address",
            cloning_ir(f_ir() * "@gv = global i64 add (i64 ptrtoint (ptr @f to i64), i64 1)\n",
                       ["f"]))
    rejects("through a constant that changes its address",
            cloning_ir(f_ir() * "@gv = global { i32, i32 } { i32 ptrtoint (ptr @f to i32), i32 1 }\n",
                       ["f"]))
    rejects("a constant global variable",
            cloning_ir(f_ir() * "@gv = constant ptr @f\n", ["f"]))
    rejects("used by llvm.compiler.used", cloning_ir(f_ir() *
        "@llvm.compiler.used = appending global [1 x ptr] [ptr @f], section \"llvm.metadata\"\n",
        ["f"]))
    rejects("an alias, and has no julia.mv.reloc",
            cloning_ir(f_ir("\"julia.mv.clones\"=\"2\"") * "@a = alias void (), ptr @f\n",
                       ["f"]))
    rejects("an alias, and has vector arguments",
            cloning_ir("""
                define <4 x float> @f(<4 x float> %x) #0 {
                  ret <4 x float> %x
                }
                attributes #0 = { "julia.mv.clones"="2" "julia.mv.reloc" }
                @a = alias <4 x float> (<4 x float>), ptr @f
                """, ["f"]))
    rejects("neither a global variable nor an alias",
            cloning_ir(f_ir() * """
                define void @p() personality ptr @f {
                  ret void
                }
                """, ["f", "p"]))
end

end
