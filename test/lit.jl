include("litsetup.jl")

@testset "lit" begin
    # RUN lines are gated by the running Julia's version: a feature that doesn't exist
    # would skip them without a trace
    @test isempty(unknown_julia_features(joinpath(@__DIR__, "lit")))
    mktempdir() do dir
        write(joinpath(dir, "typo.ll"), """
            ; REQUIRES: julia-ge-1.12
            ; RUN: %if julia-1.13 %{ opt -passes=jl-remove-ni -S %s %}
            ; RUN: %if julia-1.31 || julia-ge-1.1 %{ opt -passes=jl-remove-ni -S %s %}
            ; RUN: opt -map-julia-passes=0 --load-pass-plugin=libjulia-codegen%shlibext -S %s
            """)
        @test unknown_julia_features(dir) == ["typo.ll:3: julia-1.31", "typo.ll:3: julia-ge-1.1"]
    end

    python = find_python()
    if python === nothing
        # CI runners have Python; locally, the lit tests are optional
        get(ENV, "CI", "") == "true" && error("python3 is required to run the lit tests")
        @warn "python3 not found; skipping the lit tests"
        @test_skip "lit"
    else
        mktempdir() do dir
            bindir = jlopt_bindir(joinpath(dir, "bin"))
            params = lit_params(; exec_root=joinpath(dir, "out"), bindir)

            ok, output = run_lit(joinpath(@__DIR__, "lit"); python, params)
            ok || println(output)
            @test ok

            # a failing check fails the suite
            broken = joinpath(dir, "broken")
            mkpath(broken)
            cp(joinpath(@__DIR__, "lit", "lit.cfg.py"), joinpath(broken, "lit.cfg.py"))
            write(joinpath(broken, "broken.ll"), """
                ; RUN: opt -passes=jl-remove-ni -S %s | FileCheck %s
                target datalayout = "e-i64:64-ni:10:11:12:13"
                ; CHECK: target datalayout = "e-i64:64-ni:10:11:12:13"
                """)
            params = lit_params(; exec_root=joinpath(dir, "out-broken"), bindir)
            ok, output = run_lit(broken; python, params)
            @test !ok
            @test occursin("FAIL: JuliaIR :: broken.ll", output)
        end
    end
end
