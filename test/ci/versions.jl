# Julia versions and fixture commits share one source of truth.
using TOML

function versions(manifest=joinpath(@__DIR__, "..", "upstream", "manifest.toml"))
    pins = TOML.parsefile(manifest)["pins"]
    map(sort!(collect(keys(pins)); by=VersionNumber)) do minor
        pin = pins[minor]
        version = if haskey(pin, "julia")
            pin["julia"]
        elseif pin["tag"] == "master"
            "nightly"
        elseif pin["tag"] == "release-$minor"
            "$minor-nightly"
        else
            error("No Julia channel for pin $minor: $(pin["tag"])")
        end
        (; minor, version, ref=get(pin, "commit", ""))
    end
end

function ci_outputs(io)
    rows = versions()
    # All values come from the checked-in manifest; restrict them before emitting JSON.
    for row in rows, value in row
        occursin(r"^[A-Za-z0-9.-]*$", value) || error("Invalid matrix value: $value")
    end
    matrix = join(["{\"minor\":\"$(r.minor)\",\"version\":\"$(r.version)\",\"ref\":\"$(r.ref)\"}" for r in rows], ",")
    println(io, "matrix=[$matrix]")
    println(io, "coverage=", last(filter(r -> !isempty(r.ref), rows)).version)
    println(io, "llvm-major=", VersionNumber(ENV["LLVM_VERSION"]).major)
end

if abspath(PROGRAM_FILE) == @__FILE__
    open(ci_outputs, ENV["GITHUB_OUTPUT"], "a")
end
