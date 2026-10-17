# The IR dialect of a Julia version: everything about Julia's LLVM IR that the passes
# depend on and that changed between Julia versions.

# Julia minor versions whose dialect is known. The last one is the development version,
# whose dialect is the one of the master commit pinned in test/upstream/manifest.toml.
const KNOWN_MINORS = (v"1.10", v"1.11", v"1.12", v"1.13", v"1.14")
const DEVELOPMENT_MINOR = last(KNOWN_MINORS)

# GC write-barrier build configurations (`GC_BARRIER_SNAPSHOT`, `GC_BARRIER_FIELD_PRECISE`
# in Julia's `src/options.h`); stock Julia builds use neither.
const GC_BARRIER_CONFIGS = (:stock, :snapshot, :field_precise, :snapshot_field_precise)

# How DemoteFloat16 decides which functions to demote, see `fp16_rule`.
const FP16_POLICIES = (:auto, :keep, :demote)

"""
    JuliaIR.Dialect(julia::VersionNumber; fp16=:auto, gc_barrier=:stock)
    JuliaIR.Dialect(julia::AbstractString; ...)

The IR dialect emitted by Julia version `julia`, which every pass of this package takes
as its `julia` option. Every Julia version from 1.10 up to the development version this
package knows about is supported; a prerelease like `v"1.13.0-DEV.123"` has the dialect
of the release it precedes, and the development version has the dialect of the Julia
master commit this package is tested against. Newer versions get the development
version's dialect: a new minor version starts out emitting the same IR as its
predecessor, and only diverges as changes land on master.

The dialect only describes Julia's IR. What depends on the version of LLVM (e.g., the
signature of the lifetime intrinsics) is determined by the library the passes run on,
see [`JuliaIR.library_facts`](@ref).

The keyword arguments are policies, which are not determined by the Julia version:

- `fp16`: whether DemoteFloat16 demotes `half` arithmetic to `float`. `:auto` follows
  the rule of the Julia version (`fp16_rule`), `:keep` and `:demote` override it.
- `gc_barrier`: the GC write-barrier configuration Julia was built with (`:stock`,
  `:snapshot`, `:field_precise` or `:snapshot_field_precise`).
"""
struct Dialect
    "The Julia version, as requested."
    julia::VersionNumber
    "The minor version whose dialect is used."
    minor::VersionNumber

    # intrinsics
    "The write-barrier intrinsics: `:write_barrier` (`julia.write_barrier`), or
    `:object_field` (`julia.object_write_barrier` and `julia.field_write_barrier.p*`)."
    barrier_flavour::Symbol
    "Names of the write-barrier intrinsics."
    write_barriers::Vector{String}
    "Whether `julia.call3` exists."
    has_call3::Bool
    "Whether `julia.gc_loaded` exists."
    has_gc_loaded::Bool
    "Whether `julia.atomicmodify.*` intrinsics exist (lowered by ExpandAtomicModify)."
    has_atomicmodify::Bool

    # allocations
    "Whether `julia.gc_alloc_obj` calls carry `allockind` and return alignment
    attributes at the call site (instead of only on the declaration)."
    alloc_callsite_attrs::Bool
    "How AllocOpt initializes the stack memory of an allocation that wasn't marked
    uninitialized: `:none` (Julia 1.10), `:store` (store zero, or a frozen `undef` for
    allocations of unknown kind; 1.11), or `:memset` (zero it; 1.12 and later). Reference
    slots are always null-initialized, as since 1.13."
    alloc_initialization::Symbol
    "The layout of the stack memory AllocOpt allocates: `:legacy` (a legal integer or a
    byte array, aligned to a power of two up to 16; Julia 1.10 and 1.11), or `:chunked`
    (alignment-sized integer chunks, aligned like the allocation but at least to 16)."
    alloc_layout::Symbol
    "Whether allocations carry the `julia.gc_alloc_ptr_offsets` and
    `julia.gc_alloc_zeroinit` operand bundles."
    alloc_bundles::Bool

    # operand bundles
    "Whether calls carry `gc-transition` operand bundles."
    has_gc_transition_bundle::Bool
    "Whether calls carry `julia.gc_alloc_zeroinit_indirect` operand bundles."
    has_zeroinit_indirect_bundle::Bool

    # metadata
    "The TBAA type names whose access tags LateLowerGC's cleanup makes mutable."
    tbaa_downgrade::Vector{String}

    # loops
    "Whether LowerSIMDLoop marks the multiplication feeding a reduction as `contract`."
    simdloop_check_combine::Bool

    # verification
    "Whether GCInvariantVerifier also checks vectors of pointers (`julia.call3` is
    covered by `has_call3`)."
    verifier_vector_pointers::Bool

    # DemoteFloat16
    "How the Julia version decides to demote `half`: `:target_features` (from the
    function's target features; Julia 1.10), `:target_features_bf16` (same, and always
    demote `bfloat`; 1.11), or `:attributes` (`julia.hasfp16`/`julia.hasbf16` function
    attributes, and always on PowerPC; 1.12 and later)."
    fp16_rule::Symbol

    # PropagateJuliaAddrspaces
    "The address space PropagateJuliaAddrspaces rewrites to. Always `:common_leaf` (the
    common address space of the leaves, as on Julia master); kept for the record since
    Julia 1.13 and older used the alloca address space."
    propagate_addrspaces_target::Symbol

    # policies
    "DemoteFloat16 policy, see [`JuliaIR.Dialect`](@ref)."
    fp16::Symbol
    "GC write-barrier configuration, see [`JuliaIR.Dialect`](@ref)."
    gc_barrier::Symbol
end

function Dialect(julia::VersionNumber; fp16::Symbol=:auto, gc_barrier::Symbol=:stock)
    minor = dialect_minor(julia)
    fp16 in FP16_POLICIES ||
        throw(ArgumentError("invalid fp16 policy :$fp16; expected one of $(join(FP16_POLICIES, ", "))"))
    gc_barrier in GC_BARRIER_CONFIGS ||
        throw(ArgumentError("invalid GC barrier configuration :$gc_barrier; expected one of $(join(GC_BARRIER_CONFIGS, ", "))"))

    development = minor == DEVELOPMENT_MINOR
    barrier_flavour = development ? :object_field : :write_barrier
    write_barriers = development ?
        ["julia.object_write_barrier", "julia.field_write_barrier.p11",
         "julia.field_write_barrier.p13"] :
        ["julia.write_barrier"]

    # LateLowerGC's CleanupIR also lists "tbaa_memoryown" on 1.11 to 1.13, a misspelling
    # of jtbaa_memoryown that never matches, so it is left out here.
    tbaa_downgrade = if minor == v"1.10"
        ["jtbaa_const"]
    elseif development
        ["jtbaa_const", "jtbaa_memory"]
    else
        ["jtbaa_const", "jtbaa_memoryptr", "jtbaa_memorylen"]
    end

    fp16_rule = minor == v"1.10" ? :target_features :
                minor == v"1.11" ? :target_features_bf16 : :attributes

    return Dialect(julia, minor,
                   barrier_flavour, write_barriers,
                   minor >= v"1.11",                      # has_call3
                   minor >= v"1.11",                      # has_gc_loaded
                   minor >= v"1.13",                      # has_atomicmodify
                   minor >= v"1.11",                      # alloc_callsite_attrs
                   minor == v"1.10" ? :none :
                   minor == v"1.11" ? :store : :memset,   # alloc_initialization
                   minor <= v"1.11" ? :legacy : :chunked, # alloc_layout
                   development,                           # alloc_bundles
                   minor >= v"1.12",                      # has_gc_transition_bundle
                   development,                           # has_zeroinit_indirect_bundle
                   tbaa_downgrade,
                   minor >= v"1.12",                      # simdloop_check_combine
                   minor >= v"1.12",                      # verifier_vector_pointers
                   fp16_rule,
                   :common_leaf,
                   fp16, gc_barrier)
end

Dialect(julia::AbstractString; kwargs...) = Dialect(parse_julia_version(julia); kwargs...)

function parse_julia_version(str::AbstractString)
    v = tryparse(VersionNumber, str)
    v === nothing && throw(ArgumentError("invalid Julia version \"$str\""))
    return v
end

# the known minor version whose dialect a Julia version has
function dialect_minor(julia::VersionNumber)
    minor = VersionNumber(julia.major, julia.minor)
    minor < first(KNOWN_MINORS) &&
        throw(ArgumentError("Julia $julia is not supported; the oldest supported dialect is Julia $(first(KNOWN_MINORS))"))
    return min(minor, DEVELOPMENT_MINOR)
end

# dialects are compared by what they describe, not by the version they were requested with
function Base.:(==)(a::Dialect, b::Dialect)
    a.minor == b.minor && a.fp16 == b.fp16 && a.gc_barrier == b.gc_barrier
end
Base.hash(d::Dialect, h::UInt) = hash(d.minor, hash(d.fp16, hash(d.gc_barrier, hash(Dialect, h))))

function Base.show(io::IO, d::Dialect)
    print(io, "JuliaIR.Dialect(v\"", d.julia, "\"")
    d.fp16 === :auto || print(io, "; fp16=:", d.fp16)
    d.gc_barrier === :stock || print(io, d.fp16 === :auto ? "; " : ", ", "gc_barrier=:", d.gc_barrier)
    print(io, ")")
end

# the dialect as option text, e.g. `julia=1.12;fp16=demote`
function options_string(d::Dialect)
    str = "julia=$(d.julia)"
    d.fp16 === :auto || (str *= ";fp16=$(d.fp16)")
    d.gc_barrier === :stock || (str *= ";gc-barrier=$(replace(string(d.gc_barrier), '_' => '-'))")
    return str
end
