# The entry point of the `jlopt` app (`[apps]` in Project.toml), which Pkg's shim runs as
# `julia -m JuliaIR`. bin/jlopt calls `jlopt_main` itself, which works on Julia 1.10 too.
function (@main)(args)
    return jlopt_main(args)
end
