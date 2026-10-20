# The IR dialect of a Julia version: everything about Julia's LLVM IR that the passes
# depend on and that changed between Julia versions.

# Julia minor versions whose dialect is known. Newer versions, current Julia master (as
# tested with the nightly build) among them, have the newest one's dialect until their IR
# diverges from it; only then does their minor version need to be added.
const KNOWN_MINORS = (v"1.10", v"1.11", v"1.12", v"1.13", v"1.14")
const NEWEST_MINOR = last(KNOWN_MINORS)

# GC write-barrier build configurations (`GC_BARRIER_SNAPSHOT`, `GC_BARRIER_FIELD_PRECISE`
# in Julia's `src/options.h`); stock Julia builds use neither.
const GC_BARRIER_CONFIGS = (:stock, :snapshot, :field_precise, :snapshot_field_precise)

# How DemoteFloat16 decides which functions to demote, for `half` (`fp16`) and `bfloat`
# (`bf16`) separately, see `fp16_rule`.
const FP16_POLICIES = (:auto, :keep, :demote)

"""
    JuliaIR.Dialect(julia::VersionNumber; fp16=:auto, bf16=:auto, gc_barrier=:stock)

The IR dialect emitted by Julia version `julia`. The passes process the IR of the running
Julia, so they use `Dialect(VERSION)`, with the policies of their options; constructing
the dialect of another version is useful to inspect how the versions differ.

Every Julia version from 1.10 up to the newest version this package knows about has a
dialect; a prerelease like `v"1.13.0-DEV.123"` has the dialect of the release it
precedes. Newer versions, including the development version (Julia master), get the
newest known version's dialect: a new minor version starts out emitting the same IR as
its predecessor, and only diverges as changes land on master.

The dialect only describes Julia's IR. What depends on the version of LLVM (e.g., the
signature of the lifetime intrinsics) is determined by the library the passes run on,
see [`JuliaIR.library_facts`](@ref).

The keyword arguments are policies, which are not determined by the Julia version:

- `fp16`: whether DemoteFloat16 demotes `half` arithmetic to `float`. `:auto` follows
  the rule of the Julia version (`fp16_rule`), `:keep` and `:demote` override it,
  including the function attributes that rule reads.
- `bf16`: the same for `bfloat` arithmetic.
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
    "The exception handlers that LowerExcHandlers lowers, by the signature of
    `julia.except_enter`: `:no_task` (`() -> i32`; Julia 1.10), `:task` (`(ptr) -> i32`,
    taking the current task; 1.11), `:task_buffer` (`(ptr) -> {i32, ptr}`, also returning
    the handler buffer; 1.12), or `:none` (1.13 and later, whose code generator emits
    handlers directly, and which have no LowerExcHandlers)."
    except_enter::Symbol

    # passes
    "Whether Julia's pipeline has CombineMulAdd (Julia 1.10 and 1.11)."
    has_combine_muladd::Bool
    "Whether the code generator emits `julia.cancellation_point` calls, lowered by
    CancellationLowering (Julia 1.14 and later)."
    has_cancellation_lowering::Bool

    # CPUFeatures
    "How CPUFeatures decides whether a target has FMA: `:tokens` (by looking for
    `+fma`, `+fma4`, `+vfp4` or `+vfp4sp` in the function's `target-features`, or else
    in the JIT's feature string; Julia 1.13 and older) or `:subtarget` (by asking LLVM's
    subtarget tables about the function's `target-cpu` and `target-features`, or the
    target machine's CPU and features; Julia 1.14 and later, which also know RISC-V)."
    cpu_features_rule::Symbol
    "Whether `julia.cpu.supports.*` intrinsics exist (`Base.@cpu_supports`, lowered by
    CPUFeatures; Julia 1.14 and later)."
    has_cpu_supports::Bool

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
    "How the Julia version decides to demote `half` and `bfloat` (under the `:auto`
    policies): `:target_features` (`half` unless the function's target features or a
    `julia.hasfp16` attribute say it is supported, never `bfloat`; Julia 1.10),
    `:target_features_bf16` (same, and `bfloat` unless there is a `julia.hasbf16`
    attribute; 1.11), or `:attributes` (when the value of `julia.hasfp16`/`julia.hasbf16`
    is not `true`; without these attributes, `half` on PowerPC only and never `bfloat`;
    1.12 and later)."
    fp16_rule::Symbol

    # LateLowerGCFrame
    "Which loads LateLowerGCFrame refines to the object they load from (rooted by it):
    `:tbaa` (loads with `!invariant.load` or a TBAA type that derives from one of
    `gc_immutable_tbaa`; Julia 1.13 and older) or `:regions` (`!invariant.load` or
    `!alias.scope` regions of the `jnoalias` domain that are never overwritten)."
    gc_rooted_loads::Symbol
    "The TBAA types of immutable memory, for `gc_rooted_loads == :tbaa`."
    gc_immutable_tbaa::Vector{String}
    "Whether loads of tracked pointers through untracked pointers derived from an
    argument (a jlcall argument array) count as rooted by the caller (Julia 1.12 and
    older)."
    gc_frame_ref_refinement::Bool
    "Whether no GC frame is created when no safepoint follows the first definition that
    needs rooting (Julia 1.13 and later)."
    gc_frame_elision::Bool
    "How calls report the roots they return in memory: `:sret` (the roots of an `sret`
    argument that is not all tracked pointers are in an alloca passed as the second
    argument; Julia 1.13 and older) or `:attribute` (a `julia.return_roots` argument
    attribute gives the number of roots in that argument)."
    gc_return_roots::Symbol
    "Whether GC frame slots whose value dies are reset to null before the next
    safepoint (Julia 1.12 and later)."
    gc_slot_resets::Bool
    "Whether null stores to rooted allocas in the entry block are removed, since frame
    slots start out null (Julia 1.12 and later)."
    gc_prologue_store_elision::Bool
    "Whether allocas of single tracked pointers get their frame slots before the other
    rooted allocas (Julia 1.11 and older)."
    gc_root_allocas_first::Bool
    "Whether an argument with the `gcstack` attribute provides the GC stack (Julia 1.13
    and later; before, only a `julia.get_pgcstack` call in the entry block)."
    gc_stack_argument::Bool
    "Whether the values that GC lowering creates are named (`jlcallframe`,
    `gc_slot_addr`, `.tag_addr`, ...; Julia 1.11 and later)."
    gc_names::Bool
    "Whether loads of type tags are volatile (Julia 1.11 and later)."
    gc_tag_load_volatile::Bool
    "Whether `julia.gc_alloc_bytes` takes the type tag as an argument and carries the
    allocation attributes (Julia 1.11 and later)."
    gc_alloc_bytes_tag::Bool
    "Whether the field extractions that GC lowering creates are simplified (with LLVM's
    `InstSimplifyFolder`; Julia 1.12 and later)."
    gc_extract_simplify::Bool
    "How the thread-local state of a task is addressed: `:pointer` (a GEP over pointers;
    Julia 1.11 and older) or `:byte` (a GEP over bytes)."
    gc_ptls_gep::Symbol
    "How LateLowerGCFrame lowers write barriers: `:unnamed` (Julia 1.10), `:debug_named`
    (values named at debug level 2; 1.11), `:named` (1.12), `:image` (also queueing
    parents in the system image that are not yet in its remembered set; 1.13), or
    `:deferred` (only elided when unnecessary, and lowered by FinalLowerGC; 1.14 and
    later)."
    gc_barrier_lowering::Symbol
    "How calls with a `gc-transition` operand bundle are lowered: `:none` (the bundle is
    dropped; Julia 1.11 and older), `:pgcstack` (the GC state is switched through the
    task of the GC stack; 1.12), or `:bundle` (through the bundle's thread-local state;
    1.13 and later)."
    gc_transition_lowering::Symbol
    "How the safepoint page is loaded at GC state transitions: `:plain` (Julia 1.12),
    `:monotonic` (an atomic load; 1.13), `:monotonic_named` (with a named address;
    1.14 and later)."
    gc_safepoint_load::Symbol
    "Whether every function processed gets a declaration of `ijl_gc_small_alloc`
    (Julia 1.12 and later)."
    gc_declare_small_alloc::Bool
    "The condition under which a GC state transition polls a safepoint: `:and` (when
    leaving a GC-safe state for the unsafe one: `(old != 0) & (new == 0)`; Julia 1.10),
    `:or` (`(old == 0) | (new == 0)`, always when entering the unsafe state; 1.11), or
    `:ne` (whenever the state changes, `old != new`, with named values; 1.13 and later,
    and 1.12, whose C++ inverts the comparison, see the docs)."
    gc_state_condition::Symbol

    # LowerPTLS
    "The parameter attribute of a function's argument that holds the GC stack, which
    LowerPTLS uses instead of a call of the getter: `:swiftself` (Julia 1.12 and older) or
    `:gcstack` (a string attribute; 1.13 and later)."
    ptls_stack_argument::Symbol
    "Whether that argument takes the name of the getter call it replaces (Julia 1.11 and
    later)."
    ptls_argument_takes_name::Bool
    "The runtime function that adopts a foreign thread for `julia.get_pgcstack_or_new`:
    `ijl_adopt_thread` (Julia 1.11 and older) or `ijl_autoinit_and_adopt_thread`."
    ptls_adopt_thread::String
    "The image's variable for the TLS offset in imaging mode: `jl_tls_offset`, or
    `jl_image_tls_offset` (Julia 1.14 and later)."
    ptls_image_offset_slot::String
    "How the JIT calls the GC stack getter when it can't read the thread pointer:
    `:address` (the getter's address in the process, with its key on Darwin; Julia 1.13
    and older), or `:resolved` (the symbol `jl_get_pgcstack_resolved`, and the
    `tls_getters` option that always calls it; 1.14 and later)."
    ptls_jit_getter::Symbol
    "Whether the GEP that adds the TLS offset to the thread pointer is `inbounds`, and
    RISC-V's thread pointer is supported (Julia 1.12 and later)."
    ptls_tp_inbounds::Bool
    "Whether the GC state restored at the returns of a C-callable function is followed
    by a safepoint (Julia 1.12 and later)."
    ptls_exit_safepoint::Bool

    # type lowering
    "How `Ptr{T}` is lowered: `:integer` (an integer of the pointer's size; Julia 1.10 and
    1.11) or `:pointer` (`ptr`)."
    cpointer_type::Symbol
    "Which types besides `Union{}` lower to `void` as aliases of the bottom type:
    `:bottom` (none; Julia 1.10 and 1.11), `:typeofbottom_super` (`typeof(Union{})` and its
    supertype `Type{Union{}}`; 1.12 and 1.13) or `:some_type` (`typeof(Union{})` and
    `Type{Union{}}`, which is a `Core.TypeEq`)."
    bottom_aliases::Symbol
    "Whether values of the kinds (`DataType`, `Union`, `UnionAll`, `typeof(Union{})` and,
    from Julia 1.14 on, `Core.TypeEq`/`Core.TypeEgal`) are always boxed, instead of being
    lowered like other immutable structs."
    boxes_kinds::Bool

    # FinalLowerGC
    "Whether FinalLowerGC is a module pass, which declares the runtime functions it lowers
    to in every module and lists them in `llvm.compiler.used` while it runs (Julia 1.10);
    later, a function pass that declares them in each function it lowers."
    gc_final_module::Bool
    "Whether FinalLowerGC skips functions when no GC intrinsic in the module has a use
    (Julia 1.13 and later)."
    gc_final_skip_unused::Bool
    "Whether FinalLowerGC inserts the lowered frame allocation and push after the
    intrinsic, with the debug location of the next instruction (Julia 1.10)."
    gc_final_debugloc_next::Bool
    "The runtime's allocation functions: `:pool` (`ijl_gc_pool_alloc`,
    `ijl_gc_big_alloc`, without the type tag; Julia 1.10), `:pool_instrumented`
    (`ijl_gc_pool_alloc_instrumented`, `ijl_gc_big_alloc_instrumented`, with it; 1.11) or
    `:small` (`ijl_gc_small_alloc`, `ijl_gc_big_alloc`; 1.12 and later)."
    gc_alloc_entry_points::Symbol
    "Whether allocations and root queuing in a cancellation reset region
    (`!julia.reset_region`) use the runtime's `*_reset_safe` functions (Julia 1.14 and
    later)."
    gc_alloc_reset_safe::Bool

    # policies
    "DemoteFloat16 policies, see [`JuliaIR.Dialect`](@ref)."
    fp16::Symbol
    bf16::Symbol
    "GC write-barrier configuration, see [`JuliaIR.Dialect`](@ref)."
    gc_barrier::Symbol
end

function Dialect(julia::VersionNumber; fp16::Symbol=:auto, bf16::Symbol=:auto,
                 gc_barrier::Symbol=:stock)
    minor = dialect_minor(julia)
    fp16 in FP16_POLICIES ||
        throw(ArgumentError("invalid fp16 policy :$fp16; expected one of $(join(FP16_POLICIES, ", "))"))
    bf16 in FP16_POLICIES ||
        throw(ArgumentError("invalid bf16 policy :$bf16; expected one of $(join(FP16_POLICIES, ", "))"))
    gc_barrier in GC_BARRIER_CONFIGS ||
        throw(ArgumentError("invalid GC barrier configuration :$gc_barrier; expected one of $(join(GC_BARRIER_CONFIGS, ", "))"))

    barrier_flavour = minor >= v"1.14" ? :object_field : :write_barrier
    write_barriers = minor >= v"1.14" ?
        ["julia.object_write_barrier", "julia.field_write_barrier.p11",
         "julia.field_write_barrier.p13"] :
        ["julia.write_barrier"]

    # LateLowerGC's CleanupIR also lists "tbaa_memoryown" on 1.11 to 1.13, a misspelling
    # of jtbaa_memoryown that never matches, so it is left out here.
    tbaa_downgrade = if minor == v"1.10"
        ["jtbaa_const"]
    elseif minor >= v"1.14"
        ["jtbaa_const", "jtbaa_memory"]
    else
        ["jtbaa_const", "jtbaa_memoryptr", "jtbaa_memorylen"]
    end

    gc_immutable_tbaa = ["jtbaa_immut", "jtbaa_const", "jtbaa_datatype"]
    minor >= v"1.11" && append!(gc_immutable_tbaa, ["jtbaa_memoryptr", "jtbaa_memorylen",
                                                    "jtbaa_memoryown"])
    gc_barrier_lowering = minor == v"1.10" ? :unnamed :
                          minor == v"1.11" ? :debug_named :
                          minor == v"1.12" ? :named :
                          minor == v"1.13" ? :image : :deferred
    gc_transition_lowering = minor <= v"1.11" ? :none :
                             minor == v"1.12" ? :pgcstack : :bundle
    gc_state_condition = minor == v"1.10" ? :and : minor == v"1.11" ? :or : :ne

    fp16_rule = minor == v"1.10" ? :target_features :
                minor == v"1.11" ? :target_features_bf16 : :attributes

    return Dialect(julia, minor,
                   barrier_flavour, write_barriers,
                   minor >= v"1.11",                      # has_call3
                   minor >= v"1.11",                      # has_gc_loaded
                   minor >= v"1.13",                      # has_atomicmodify
                   minor == v"1.10" ? :no_task :
                   minor == v"1.11" ? :task :
                   minor == v"1.12" ? :task_buffer : :none, # except_enter
                   minor <= v"1.11",                      # has_combine_muladd
                   minor >= v"1.14",                      # has_cancellation_lowering
                   minor >= v"1.14" ? :subtarget : :tokens, # cpu_features_rule
                   minor >= v"1.14",                      # has_cpu_supports
                   minor >= v"1.11",                      # alloc_callsite_attrs
                   minor == v"1.10" ? :none :
                   minor == v"1.11" ? :store : :memset,   # alloc_initialization
                   minor <= v"1.11" ? :legacy : :chunked, # alloc_layout
                   minor >= v"1.14",                      # alloc_bundles
                   minor >= v"1.12",                      # has_gc_transition_bundle
                   minor >= v"1.14",                      # has_zeroinit_indirect_bundle
                   tbaa_downgrade,
                   minor >= v"1.12",                      # simdloop_check_combine
                   minor >= v"1.12",                      # verifier_vector_pointers
                   fp16_rule,
                   minor >= v"1.14" ? :regions : :tbaa,  # gc_rooted_loads
                   gc_immutable_tbaa,
                   minor <= v"1.12",                      # gc_frame_ref_refinement
                   minor >= v"1.13",                      # gc_frame_elision
                   minor >= v"1.14" ? :attribute : :sret, # gc_return_roots
                   minor >= v"1.12",                      # gc_slot_resets
                   minor >= v"1.12",                      # gc_prologue_store_elision
                   minor <= v"1.11",                      # gc_root_allocas_first
                   minor >= v"1.13",                      # gc_stack_argument
                   minor >= v"1.11",                      # gc_names
                   minor >= v"1.11",                      # gc_tag_load_volatile
                   minor >= v"1.11",                      # gc_alloc_bytes_tag
                   minor >= v"1.12",                      # gc_extract_simplify
                   minor <= v"1.11" ? :pointer : :byte,   # gc_ptls_gep
                   gc_barrier_lowering,
                   gc_transition_lowering,
                   minor >= v"1.14" ? :monotonic_named :
                   minor == v"1.13" ? :monotonic : :plain, # gc_safepoint_load
                   minor >= v"1.12",                      # gc_declare_small_alloc
                   gc_state_condition,
                   minor >= v"1.13" ? :gcstack : :swiftself, # ptls_stack_argument
                   minor >= v"1.11",                      # ptls_argument_takes_name
                   minor >= v"1.12" ? "ijl_autoinit_and_adopt_thread" :
                                      "ijl_adopt_thread", # ptls_adopt_thread
                   minor >= v"1.14" ? "jl_image_tls_offset" :
                                      "jl_tls_offset",    # ptls_image_offset_slot
                   minor >= v"1.14" ? :resolved : :address, # ptls_jit_getter
                   minor >= v"1.12",                      # ptls_tp_inbounds
                   minor >= v"1.12",                      # ptls_exit_safepoint
                   minor <= v"1.11" ? :integer : :pointer, # cpointer_type
                   minor <= v"1.11" ? :bottom :
                   minor >= v"1.14" ? :some_type : :typeofbottom_super, # bottom_aliases
                   minor >= v"1.14",                      # boxes_kinds
                   minor == v"1.10",                      # gc_final_module
                   minor >= v"1.13",                      # gc_final_skip_unused
                   minor == v"1.10",                      # gc_final_debugloc_next
                   minor == v"1.10" ? :pool :
                   minor == v"1.11" ? :pool_instrumented : :small, # gc_alloc_entry_points
                   minor >= v"1.14",                      # gc_alloc_reset_safe
                   fp16, bf16, gc_barrier)
end

# the known minor version whose dialect a Julia version has
function dialect_minor(julia::VersionNumber)
    minor = VersionNumber(julia.major, julia.minor)
    minor < first(KNOWN_MINORS) &&
        throw(ArgumentError("Julia $julia is not supported; the oldest supported dialect is Julia $(first(KNOWN_MINORS))"))
    return min(minor, NEWEST_MINOR)
end

# dialects are compared by what they describe, not by the version they were requested with
function Base.:(==)(a::Dialect, b::Dialect)
    a.minor == b.minor && a.fp16 == b.fp16 && a.bf16 == b.bf16 && a.gc_barrier == b.gc_barrier
end
Base.hash(d::Dialect, h::UInt) =
    hash(d.minor, hash(d.fp16, hash(d.bf16, hash(d.gc_barrier, hash(Dialect, h)))))

function Base.show(io::IO, d::Dialect)
    print(io, "JuliaIR.Dialect(v\"", d.julia, "\"")
    kwargs = String[]
    d.fp16 === :auto || push!(kwargs, "fp16=:$(d.fp16)")
    d.bf16 === :auto || push!(kwargs, "bf16=:$(d.bf16)")
    d.gc_barrier === :stock || push!(kwargs, "gc_barrier=:$(d.gc_barrier)")
    isempty(kwargs) || print(io, "; ", join(kwargs, ", "))
    print(io, ")")
end

# the policies of a dialect as option text, e.g. `fp16=demote;gc-barrier=snapshot`
function options_string(d::Dialect)
    parts = String[]
    d.fp16 === :auto || push!(parts, "fp16=$(d.fp16)")
    d.bf16 === :auto || push!(parts, "bf16=$(d.bf16)")
    d.gc_barrier === :stock || push!(parts, "gc-barrier=$(replace(string(d.gc_barrier), '_' => '-'))")
    return join(parts, ";")
end
