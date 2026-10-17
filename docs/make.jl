using Documenter, JuliaIR

function main()
    ci = get(ENV, "CI", "") == "true"

    makedocs(
        sitename = "JuliaIR.jl",
        # explicit, so that local builds work in a checkout without a remote
        repo = Remotes.GitHub("JuliaLLVM", "JuliaIR.jl"),
        authors = "Tim Besard",
        format = Documenter.HTML(prettyurls = ci),
        modules = [JuliaIR],
        pages = [
            "Home" => "index.md",
        ],
        doctest = true,
    )

    if ci
        deploydocs(repo = "github.com/JuliaLLVM/JuliaIR.jl.git")
    end
end

isinteractive() || main()
