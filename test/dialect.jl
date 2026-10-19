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

    # unsupported versions
    @test_throws "not supported" Dialect(v"1.9.4")
    @test Dialect(v"1.10.0-DEV.100").minor == v"1.10"

    # newer versions, Julia master among them, get the newest known dialect
    @test Dialect(v"1.15.0-DEV.14") == Dialect(v"1.14.0-DEV")
    @test Dialect(v"1.15.0-DEV.14").julia == v"1.15.0-DEV.14"
    @test Dialect(v"2.0").minor == v"1.14"
end

@testset "drift" begin
    d10, d11, d12, d13, dm = Dialect.((v"1.10", v"1.11", v"1.12", v"1.13", v"1.14.0-DEV"))

    @test d13.write_barriers == ["julia.write_barrier"]
    @test d13.barrier_flavour === :write_barrier
    @test dm.barrier_flavour === :object_field
    @test "julia.field_write_barrier.p13" in dm.write_barriers

    @test !d10.has_gc_loaded && d11.has_gc_loaded && dm.has_gc_loaded
    @test !d10.has_call3 && d11.has_call3
    @test !d12.has_atomicmodify && d13.has_atomicmodify && dm.has_atomicmodify
    @test d10.has_combine_muladd && d11.has_combine_muladd && !d12.has_combine_muladd
    @test !d13.has_cancellation_lowering && dm.has_cancellation_lowering
    @test (d10.except_enter, d11.except_enter, d12.except_enter, d13.except_enter,
           dm.except_enter) == (:no_task, :task, :task_buffer, :none, :none)

    @test (d10.alloc_initialization, d11.alloc_initialization, d12.alloc_initialization) ==
          (:none, :store, :memset)
    @test (d10.alloc_layout, d11.alloc_layout, d12.alloc_layout, dm.alloc_layout) ==
          (:legacy, :legacy, :chunked, :chunked)
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

    # LateLowerGCFrame
    @test (d13.gc_rooted_loads, dm.gc_rooted_loads) == (:tbaa, :regions)
    @test !("jtbaa_memoryptr" in d10.gc_immutable_tbaa) && "jtbaa_memoryptr" in d11.gc_immutable_tbaa
    @test d12.gc_frame_ref_refinement && !d13.gc_frame_ref_refinement
    @test !d12.gc_frame_elision && d13.gc_frame_elision
    @test (d13.gc_return_roots, dm.gc_return_roots) == (:sret, :attribute)
    @test !d11.gc_slot_resets && d12.gc_slot_resets && d12.gc_prologue_store_elision
    @test d11.gc_root_allocas_first && !d12.gc_root_allocas_first
    @test !d12.gc_stack_argument && d13.gc_stack_argument
    @test !d10.gc_names && d11.gc_names && !d10.gc_tag_load_volatile && d11.gc_tag_load_volatile
    @test !d10.gc_alloc_bytes_tag && d11.gc_alloc_bytes_tag
    @test !d11.gc_extract_simplify && d12.gc_extract_simplify
    @test (d11.gc_ptls_gep, d12.gc_ptls_gep) == (:pointer, :byte)
    @test map(d -> d.gc_barrier_lowering, (d10, d11, d12, d13, dm)) ==
          (:unnamed, :debug_named, :named, :image, :deferred)
    @test map(d -> d.gc_transition_lowering, (d11, d12, d13, dm)) ==
          (:none, :pgcstack, :bundle, :bundle)
    @test map(d -> d.gc_safepoint_load, (d12, d13, dm)) == (:plain, :monotonic, :monotonic_named)
    @test !d11.gc_declare_small_alloc && d12.gc_declare_small_alloc

    # type lowering
    @test (d11.cpointer_type, d12.cpointer_type) == (:integer, :pointer)
    @test map(d -> d.bottom_aliases, (d11, d12, d13, dm)) ==
          (:bottom, :typeofbottom_super, :typeofbottom_super, :some_type)
    @test !d13.boxes_kinds && dm.boxes_kinds

    # FinalLowerGC
    @test d10.gc_final_module && !d11.gc_final_module
    @test d10.gc_final_debugloc_next && !d11.gc_final_debugloc_next
    @test !d12.gc_final_skip_unused && d13.gc_final_skip_unused
    @test map(d -> d.gc_alloc_entry_points, (d10, d11, d12, d13, dm)) ==
          (:pool, :pool_instrumented, :small, :small, :small)
    @test !d13.gc_alloc_reset_safe && dm.gc_alloc_reset_safe
end

@testset "policies" begin
    @test Dialect(v"1.12").fp16 === :auto
    @test Dialect(v"1.12"; fp16=:demote).fp16 === :demote
    @test Dialect(v"1.12").gc_barrier === :stock
    @test Dialect(v"1.12"; gc_barrier=:snapshot).gc_barrier === :snapshot
    @test_throws "invalid fp16 policy" Dialect(v"1.12"; fp16=:sometimes)
    @test Dialect(v"1.12").bf16 === :auto
    @test Dialect(v"1.12"; bf16=:keep).bf16 === :keep
    @test_throws "invalid bf16 policy" Dialect(v"1.12"; bf16=:sometimes)
    @test_throws "invalid GC barrier" Dialect(v"1.12"; gc_barrier=:none)
end

@testset "equality and printing" begin
    @test Dialect(v"1.12.0") == Dialect(v"1.12.7")
    @test hash(Dialect(v"1.12.0")) == hash(Dialect(v"1.12.7"))
    @test Dialect(v"1.12") != Dialect(v"1.13")
    @test Dialect(v"1.12") != Dialect(v"1.12"; fp16=:keep)
    @test Dialect(v"1.12") != Dialect(v"1.12"; bf16=:keep)
    @test hash(Dialect(v"1.12")) != hash(Dialect(v"1.12"; bf16=:keep))
    @test repr(Dialect(v"1.12.7")) == "JuliaIR.Dialect(v\"1.12.7\")"
    @test repr(Dialect(v"1.12.7"; fp16=:keep, gc_barrier=:snapshot)) ==
          "JuliaIR.Dialect(v\"1.12.7\"; fp16=:keep, gc_barrier=:snapshot)"
    @test repr(Dialect(v"1.12.7"; bf16=:demote, gc_barrier=:snapshot)) ==
          "JuliaIR.Dialect(v\"1.12.7\"; bf16=:demote, gc_barrier=:snapshot)"
end

end
