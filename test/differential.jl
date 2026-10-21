module DifferentialHarnessTests
using Test
include("differential/run.jl")

@testset "differential normalization" begin
    function frame(; aligned=false, second=4)
        split("""
            define void @f() {
              %0 = call $(aligned ? "align 32 " : "")ptr @julia.new_gc_frame(i32 8)
              %1 = call ptr @julia.get_gc_frame_slot(ptr %0, i32 0)
              %2 = call ptr @julia.get_gc_frame_slot(ptr %0, i32 $second)
              store [4 x ptr] zeroinitializer, ptr %1
              store ptr null, ptr %2
              ret void
            }
            """, '\n')
    end
    function swapped(lines, second)
        out = copy(lines)
        out[3] = replace(out[3], "i32 0" => "i32 $second")
        out[4] = replace(out[4], "i32 $second" => "i32 0")
        out
    end

    # Equal-sized slots may exchange places if their uses follow the exchange.
    original = frame()
    @test canonical_frame_slots(original) == canonical_frame_slots(swapped(original, 4))

    # Moving a four-pointer store to slot 6 overflows an eight-pointer frame.
    # Comparing just the set of indices would miss this, even with extra alignment.
    for aligned in (false, true)
        original = frame(; aligned, second=6)
        @test canonical_frame_slots(original) != canonical_frame_slots(swapped(original, 6))
    end
    aligned = frame(; aligned=true)
    @test canonical_frame_slots(aligned) == aligned

    # The upstream padding fixture has equal-sized buffers at slots 6 and 14.
    padding = split("""
        define void @overaligned_gc_padding(<4 x ptr addrspace(10)> %0) {
          %2 = call align 64 ptr @julia.new_gc_frame(i32 18)
          %3 = call ptr @julia.get_gc_frame_slot(ptr %2, i32 14)
          %4 = call ptr @julia.get_gc_frame_slot(ptr %2, i32 6)
          %5 = call ptr @julia.get_pgcstack()
          call void @julia.push_gc_frame(ptr %2, i32 18)
          store <4 x ptr addrspace(10)> %0, ptr %3, align 64
          store <4 x ptr addrspace(10)> %0, ptr %4, align 64
          call void @aligned_short_root_array(ptr nonnull align 64 %3)
          call void @aligned_short_root_array(ptr nonnull align 64 %4)
          call void @julia.pop_gc_frame(ptr %2)
          ret void
        }""", '\n')
    exchanged = copy(padding)
    exchanged[7:10] = replace.(exchanged[7:10], "%3" => "%4", "%4" => "%3")
    @test padding != exchanged
    @test canonical_padding_fixture(padding) == canonical_padding_fixture(exchanged)
    for (old, new) in ("i32 18" => "i32 17", "i32 14" => "i32 15",
                       "<4 x ptr" => "<8 x ptr", "align 64" => "align 32")
        damaged = replace.(exchanged, old => new)
        @test canonical_padding_fixture(damaged) == damaged
        @test canonical_padding_fixture(damaged) != canonical_padding_fixture(padding)
    end
    extra_use = copy(exchanged)
    insert!(extra_use, 11, "  store ptr null, ptr %3")
    @test canonical_padding_fixture(extra_use) == extra_use
    @test canonical_padding_fixture([exchanged; "! error: unrelated"]) ==
          [canonical_padding_fixture(padding); "! error: unrelated"]

    original = ["!named = !{!2}", "!2 = !{!3, !\"literal !3\"}", "!3 = !{i32 1}"]
    renumbered = ["!named = !{!9}", "!8 = !{i32 1}", "!9 = !{!8, !\"literal !3\"}"]
    @test canonical_metadata_numbers(original) == canonical_metadata_numbers(renumbered)
    changed_string = replace.(renumbered, "literal !3" => "literal !8")
    @test canonical_metadata_numbers(original) != canonical_metadata_numbers(changed_string)
end
end
