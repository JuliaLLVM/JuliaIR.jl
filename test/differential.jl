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

    original = ["!named = !{!2}", "!2 = !{!3, !\"literal !3\"}", "!3 = !{i32 1}"]
    renumbered = ["!named = !{!9}", "!8 = !{i32 1}", "!9 = !{!8, !\"literal !3\"}"]
    @test canonical_metadata_numbers(original) == canonical_metadata_numbers(renumbered)
    changed_string = replace.(renumbered, "literal !3" => "literal !8")
    @test canonical_metadata_numbers(original) != canonical_metadata_numbers(changed_string)
end
end
