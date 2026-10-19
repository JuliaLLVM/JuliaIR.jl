# The types whose layout the IR-crossing test (test/crossing.jl) carries from Julia's LLVM
# to the library that LLVM.jl uses. Included by both of its processes.
module CrossingCorpus

# Int128's alignment differs between Julia versions (8 before 1.12 on x86, 16 from then)
struct Wide
    a::Int8
    b::Int128
end
struct Nested
    a::Int8
    w::Wide
end
# an isbits union field, which isn't lowered one element per field
struct WithUnion
    a::Int8
    b::Union{Int8,Int128}
end
struct WithVector
    a::Int16
    v::NTuple{4,VecElement{Float32}}
    p::Ptr{Int}
end

# the types, and whether each field is lowered to one element of the LLVM struct (so that
# the element offsets are the field offsets)
const TYPES = [(Wide, true), (Nested, true), (WithUnion, false), (WithVector, true),
               (Tuple{Int8,UInt128,Int16}, true)]

end
