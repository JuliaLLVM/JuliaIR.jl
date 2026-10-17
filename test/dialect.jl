using JuliaIR: Dialect

@testset "dialect" begin

@testset "resolution" begin
    # every known minor version, as released and as prerelease
    for (v, minor) in [(v"1.10.12", v"1.10"), (v"1.10.0", v"1.10"),
                       (v"1.11.9", v"1.11"), (v"1.11.0-DEV.200", v"1.11"),
                       (v"1.12.7", v"1.12"), (v"1.13.2", v"1.13"),
                       (v"1.13.0-DEV.1", v"1.13"), (v"1.13.0-rc1", v"1.13"),
                       (v"1.14.0-DEV.3782", v"1.14")]
        d = Dialect(v)
        @test d.julia == v
        @test d.minor == minor
    end

    # the running Julia is supported
    @test Dialect(VERSION).julia == VERSION

    # from option text
    @test Dialect("1.12").minor == v"1.12"
    @test Dialect("1.14.0-DEV.3782").minor == v"1.14"
    @test_throws ArgumentError Dialect("one.twelve")

    # unsupported versions
    @test_throws "not supported" Dialect(v"1.9.4")
    @test Dialect(v"1.10.0-DEV.100").minor == v"1.10"
    @test_throws "newer than" Dialect(v"1.15.0-DEV.1")
    @test_throws "newer than" Dialect(v"2.0")
end

@testset "drift" begin
    d10, d11, d12, d13, dm = Dialect.((v"1.10", v"1.11", v"1.12", v"1.13", v"1.14.0-DEV"))

    @test d13.write_barriers == ["julia.write_barrier"]
    @test d13.barrier_flavour === :write_barrier
    @test dm.barrier_flavour === :object_field
    @test "julia.field_write_barrier.p13" in dm.write_barriers

    @test !d10.has_gc_loaded && d11.has_gc_loaded && dm.has_gc_loaded
    @test d11.gc_loaded_is_escape && !d12.gc_loaded_is_escape && !d10.gc_loaded_is_escape
    @test !d10.has_call3 && d11.has_call3
    @test !d12.has_atomicmodify && d13.has_atomicmodify && dm.has_atomicmodify

    @test (d10.alloc_initialization, d11.alloc_initialization, d12.alloc_initialization) ==
          (:none, :freeze, :memset)
    @test !d10.alloc_callsite_attrs && d11.alloc_callsite_attrs
    @test !d13.alloc_bundles && dm.alloc_bundles
    @test !d11.has_gc_transition_bundle && d12.has_gc_transition_bundle
    @test !d13.has_zeroinit_indirect_bundle && dm.has_zeroinit_indirect_bundle

    @test d10.tbaa_downgrade == ["jtbaa_const"]
    @test d11.tbaa_downgrade == d13.tbaa_downgrade == ["jtbaa_const", "jtbaa_memoryptr", "jtbaa_memorylen"]
    @test dm.tbaa_downgrade == ["jtbaa_const", "jtbaa_memory"]

    @test !d11.simdloop_check_combine && d12.simdloop_check_combine
    @test !d11.verifier_vector_pointers && d12.verifier_vector_pointers
    @test (d10.fp16_rule, d11.fp16_rule, d12.fp16_rule) ==
          (:target_features, :target_features_bf16, :attributes)
    @test all(d -> d.propagate_addrspaces_target === :common_leaf, (d10, d13, dm))
end

@testset "policies" begin
    @test Dialect(v"1.12").fp16 === :auto
    @test Dialect(v"1.12"; fp16=:demote).fp16 === :demote
    @test Dialect(v"1.12").gc_barrier === :stock
    @test Dialect(v"1.12"; gc_barrier=:snapshot).gc_barrier === :snapshot
    @test_throws "invalid fp16 policy" Dialect(v"1.12"; fp16=:sometimes)
    @test_throws "invalid GC barrier" Dialect(v"1.12"; gc_barrier=:none)
end

@testset "equality and printing" begin
    @test Dialect(v"1.12.0") == Dialect(v"1.12.7")
    @test hash(Dialect(v"1.12.0")) == hash(Dialect(v"1.12.7"))
    @test Dialect(v"1.12") != Dialect(v"1.13")
    @test Dialect(v"1.12") != Dialect(v"1.12"; fp16=:keep)
    @test repr(Dialect(v"1.12.7")) == "JuliaIR.Dialect(v\"1.12.7\")"
    @test repr(Dialect(v"1.12.7"; fp16=:keep, gc_barrier=:snapshot)) ==
          "JuliaIR.Dialect(v\"1.12.7\"; fp16=:keep, gc_barrier=:snapshot)"
end

end
