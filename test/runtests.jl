using Test
using JuliaIR
using LLVM: LLVM

# lit, and the predicates that tests share (e.g. `julia_llvm_in_use`)
include("litsetup.jl")

# the tests that run entirely in this process, with the current library
const IN_PROCESS_TESTS = ["dialect.jl", "irutils.jl", "gc.jl", "registration.jl",
                          "passes.jl", "multiversioning.jl", "pipeline.jl", "runtime.jl",
                          "type_lowering.jl", "differential.jl", "compatibility.jl"]

# `JULIAIR_TEST_LIBRARY` names another LLVM library, e.g. a standalone build of a newer
# LLVM, to run the in-process tests with instead, selected after loading the package with
# Julia's library: intrinsic IDs and what depends on the LLVM version must then follow the
# selected library, not the one that the package was precompiled with.
const TEST_LIBRARY = get(ENV, "JULIAIR_TEST_LIBRARY", "")

if isempty(TEST_LIBRARY)

@testset "JuliaIR" begin

foreach(include, IN_PROCESS_TESTS)
include("jlopt.jl")
include("crossing.jl")
include("lit.jl")
include("upstream.jl")

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(JuliaIR)
end

end

else

let lib = LLVM.register_library!(:test, TEST_LIBRARY)
    @testset "JuliaIR on LLVM $(LLVM.version(lib)), next to Julia's LLVM $(Base.libllvm_version)" begin
        LLVM.library!(() -> foreach(include, IN_PROCESS_TESTS), lib)
    end
end

end
