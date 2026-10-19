using Documenter, JuliaIR

function main()
    ci = get(ENV, "CI", "") == "true"

    makedocs(
        sitename = "JuliaIR.jl",
        # explicit, so that local builds work in a checkout without a remote
        repo = Remotes.GitHub("JuliaLLVM", "JuliaIR.jl"),
        authors = "Tim Besard",
        format = Documenter.HTML(prettyurls = ci, edit_link = "main"),
        modules = [JuliaIR],
        pages = [
            "Home" => "index.md",
            "LateLowerGCFrame" => "late_lower_gc_frame.md",
            "CancellationLowering" => "cancellation_lowering.md",
            "Runtime facts" => "runtime.md",
            "Testing" => "testing.md",
            "API reference" => "api.md",
        ],
        doctest = true,
    )

    if ci
        deploydocs(repo = "github.com/JuliaLLVM/JuliaIR.jl.git")
    end
end

isinteractive() || main()
