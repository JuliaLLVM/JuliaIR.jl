using Test
using JuliaIR

@testset "JuliaIR" begin

include("dialect.jl")
include("irutils.jl")
include("registration.jl")
include("jlopt.jl")
include("passes.jl")
include("multiversioning.jl")
include("runtime.jl")
include("type_lowering.jl")
include("lit.jl")
include("upstream.jl")

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(JuliaIR)
end

end
