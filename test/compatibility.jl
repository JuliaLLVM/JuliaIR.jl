module CompatibilityHarnessTests

using Test
include("compatibility/run.jl")
using .CompatibilityHarness: input_files, source_layout, run_corpus

@testset "pipeline compatibility harness" begin
    ir = """
        target datalayout = "e-p:64:64-i64:64-n8:16:32:64"
        define i64 @twice(i64 %x) {
            %sum = add i64 %x, %x
            ret i64 %sum
        }
        """
    @test source_layout(ir) == "e-p:64:64-i64:64-n8:16:32:64"
    @test_throws "no source data layout" source_layout("define void @f() { ret void }")
    mktempdir() do dir
        @test_throws "no LLVM IR modules" input_files([dir])
        file = joinpath(dir, "good.ll")
        write(file, ir)
        @test input_files([dir, file]) == [file]
        output = IOBuffer()
        @test run_corpus([dir]; io=output) == (; modules=1, passed=4, failed=0)
        @test occursin("4 pipelines: 4 passed, 0 failed", String(take!(output)))
        # Invalid generated IR must fail the run, not silently shrink its coverage.
        write(joinpath(dir, "bad.ll"), "not LLVM IR")
        @test run_corpus([dir]; levels=[0], io=output) == (; modules=2, passed=1, failed=1)
        @test occursin("FAIL:", String(take!(output)))
        @test_throws "at least one" run_corpus([dir]; levels=[])
        @test_throws "levels must" run_corpus([dir]; levels=[4])
    end
end

end
