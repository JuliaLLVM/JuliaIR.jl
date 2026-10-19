# The passes the differential compares, and the C++ pipelines that run before them.
#
# Adding a port: a `PassSpec` with Julia's name of the pass (the key in exceptions.toml),
# a regex that finds the pass's inputs in a module, and the prefixes it runs behind.

using LLVM, LLVM.IR

struct PassSpec
    # Julia's name of the C++ pass; also the key of its section in exceptions.toml
    name::String
    # the pipeline elements of both sides (the pass, with options if any)
    cpp::String
    port::String
    # :module, :function or :loop; a loop pass runs under `loop(...)` and `loop-mssa(...)`
    kind::Symbol
    # modules that don't match (after the prefix) contain nothing for the pass to do; only
    # for passes that provably do nothing without it (an early return in the C++), as
    # the others are compared on every module
    inputs::Regex
    # names of the C++ pipelines (`prefix_pipeline`) that run before the pass
    prefixes::Vector{String}
    # transformations of the module, applied to both sides' copies after the prefix:
    # label => function(mod)
    prepare::Vector{Pair{String,Any}}
    # the `pass_name`s of the remarks to compare (the C++ only sends remarks for which
    # `-pass-remarks*` are set)
    remarks::Vector{String}
    # how often to run the C++ pass when its output differs from the port's, for passes
    # whose C++ output varies between runs
    cpp_runs::Int
    # the C++ pass aborts the process on input it rejects (a verifier): compare the
    # messages it printed with those of the port's exception
    aborts::Bool
    # passes whose recorded deviations (exceptions.toml) apply to this one too, which
    # runs them (a pipeline)
    inherits::Vector{String}
end

function PassSpec(name; cpp=name, port=nothing, kind=:function, inputs=r"", prefixes=["raw"],
                  prepare=Pair{String,Any}["" => identity], remarks=String[], cpp_runs=1,
                  aborts=false, inherits=String[])
    port === nothing && (port = JuliaIR.cpp_mapping()[name])
    PassSpec(name, cpp, port, kind, inputs, prefixes, prepare, remarks, cpp_runs, aborts,
             inherits)
end

# the pipelines a pass runs in, labelled
function pipelines(spec::PassSpec, element::String)
    if spec.kind === :module
        return ["" => element]
    elseif spec.kind === :function
        return ["" => "function($element)"]
    else
        return ["loop" => "function(loop($element))",
                "loop-mssa" => "function(loop-mssa($element))"]
    end
end


## prefixes

# InstCombine verifies that it reached a fixpoint since LLVM 18, and reports a fatal error
# when it didn't
instcombine() = LLVM.version() >= v"18" ? "instcombine<no-verify-fixpoint>" : "instcombine"

# whether this Julia's LLVM knows a pipeline (e.g. a C++ pass that later versions removed)
const AVAILABLE = Dict{String,Bool}()
function available(pipeline::String)
    get!(AVAILABLE, pipeline) do
        @dispose ctx=Context() begin
            mod = LLVM.Module("probe")
            try
                @dispose pb=PassBuilder() begin
                    add!(pb, pipeline)
                    run!(pb, mod)
                end
                true
            catch err
                err isa LLVMException || rethrow()
                false
            finally
                dispose(mod)
            end
        end
    end
end

function prefix_pipeline(name::String)
    ic = instcombine()
    if name == "raw"
        return ""
    elseif name == "simplified"
        # unoptimized code's allocas promoted, as most passes see it in Julia's pipeline
        return "function(sroa,early-cse,$ic,simplifycfg)"
    elseif name == "early"
        # Julia's early simplification pipeline, which precedes the first AllocOpt
        return "function(lower-expect,PropagateJuliaAddrspaces,dce,simplifycfg,sroa)"
    elseif name == "simd"
        # loops marked by LowerSIMDLoop, which CombineMulAdd followed in 1.10 and 1.11
        return "function(sroa,$ic,loop-simplify,lcssa,loop(LowerSIMDLoop))"
    elseif name == "optimized"
        # an approximation of what precedes the intrinsic lowering (GC verification and
        # lowering): allocations optimized, scalar and SLP-vectorized code (vectors of
        # tracked pointers)
        exc = available("function(LowerExcHandlers)") ? "LowerExcHandlers," : ""
        return "function($(exc)AllocOpt,sroa,early-cse,$ic,simplifycfg,gvn," *
               "slp-vectorizer,$ic,PropagateJuliaAddrspaces)"
    elseif name == "gc-lowered"
        # GC frames lowered, as ExpandAtomicModify sees them in Julia's pipeline
        return available("function(FinalLowerGC)") ?
            "function(LateLowerGCFrame,FinalLowerGC)" :
            "function(LateLowerGCFrame),FinalLowerGC"
    else
        error("unknown prefix $name")
    end
end


## preparations

# What GPUCompiler does before Julia's LateLowerGCFrame, to the extent that it takes the
# C++ pass onto its cleanup-only path (no GC frame): no GC stack, and none of the
# intrinsics that `jl-late-gc-cleanup` rejects (GPUCompiler lowers allocations itself, and
# its runtime has no write barriers or type tags). Both sides then see plain calls.
const GPU_RENAMED = r"^julia\.(get_pgcstack(_or_new)?|gc_alloc_obj|\w*write_barrier[\w.]*|typeof|blackbox)$"
function gpu_like!(mod::LLVM.Module)
    for f in collect(LLVM.functions(mod))
        if occursin(GPU_RENAMED, LLVM.name(f))
            LLVM.name!(f, "gpu." * chopprefix(LLVM.name(f), "julia."))
        end
        # the allocation's bundles (`julia.gc_alloc_ptr_offsets`, ...) go with it
        if LLVM.name(f) == "gpu.gc_alloc_obj"
            @dispose builder=LLVM.IRBuilder() begin
                for use in collect(LLVM.uses(f))
                    call = LLVM.user(use)
                    call isa LLVM.CallInst || continue
                    bundles = filter(b -> !startswith(LLVM.tag(b), "julia."),
                                     collect(LLVM.operand_bundles(call)))
                    length(bundles) == length(LLVM.operand_bundles(call)) && continue
                    new = JuliaIR.clone_call!(builder, call, bundles)
                    JuliaIR.copy_metadata!(new, call)
                    LLVM.replace_uses!(call, new)
                    name = LLVM.name(call)
                    LLVM.erase!(call)
                    LLVM.name!(new, name)
                end
            end
        end
        for i in 1:length(LLVM.parameters(f))
            LLVM.API.LLVMRemoveStringAttributeAtIndex(f, i, "gcstack", length("gcstack"))
        end
    end
    return mod
end

# a PowerPC triple, where Float16 arithmetic is demoted by default on 1.12 and later
function powerpc!(mod::LLVM.Module)
    LLVM.triple!(mod, "powerpc64le-unknown-linux-gnu")
    return mod
end


## the passes

const PASS_SPECS = [
    PassSpec("RemoveNI"; kind=:module, inputs=r"^target datalayout = \".*ni:"m),
    PassSpec("AllocOpt"; inputs=r"julia\.gc_alloc_obj", prefixes=["raw", "early"]),
    PassSpec("PropagateJuliaAddrspaces";
             inputs=r"addrspace\(1[0-3]\)", prefixes=["raw", "simplified"]),
    PassSpec("DemoteFloat16"; inputs=r"\b(half|bfloat)\b", prefixes=["raw", "simplified"],
             prepare=Pair{String,Any}["" => identity, "powerpc" => powerpc!]),
    # the GC passes also check or rewrite IR that names nothing of Julia's (e.g.
    # `julia.call` arguments, aggregates built with `insertvalue`), so they see everything
    PassSpec("GCInvariantVerifier"; prefixes=["raw", "optimized"], aborts=true),
    PassSpec("GCInvariantVerifier<strong>"; cpp="GCInvariantVerifier<strong>",
             port="jl-gc-invariant-verifier<strong>", prefixes=["raw", "optimized"],
             aborts=true),
    # Julia's C++ orders the frame slots of allocas by their addresses (a pointer-keyed
    # map), so its output can differ between runs
    PassSpec("LateLowerGCFrame"; prefixes=["raw", "optimized"], cpp_runs=8),
    PassSpec("LateGCCleanup"; cpp="LateLowerGCFrame", port="jl-late-gc-cleanup",
             prefixes=["raw", "optimized"], prepare=Pair{String,Any}["gpu" => gpu_like!]),
    PassSpec("CombineMulAdd"; inputs=r"\b(contract|fast)\b", prefixes=["raw", "simd"],
             remarks=["combine-muladd"]),
    PassSpec("LowerExcHandlers"; inputs=r"julia\.except_enter",
             prefixes=["raw", "simplified"]),
    PassSpec("LowerSIMDLoop"; kind=:loop, inputs=r"julia\.(simdloop|ivdep)",
             prefixes=["raw", "simplified"], remarks=["lower_simd_loop"]),
    PassSpec("ExpandAtomicModify"; inputs=r"julia\.atomicmodify",
             prefixes=["raw", "simplified", "gc-lowered"]),
    # also changes functions without cancellation points (calls in IPO-safe functions)
    PassSpec("CancellationLowering"; prefixes=["raw", "optimized"]),
]

# Julia's optimization pipeline (`julia<level=N>`), rebuilt from the ports, at every
# optimization level.
# The deviations of the ports it runs are its own; it runs LateLowerGCFrame (hence the
# retries) and GCInvariantVerifier (which aborts).
const PIPELINE_PASSES = ["RemoveNI", "AllocOpt", "PropagateJuliaAddrspaces", "DemoteFloat16",
                         "GCInvariantVerifier", "LateLowerGCFrame", "CombineMulAdd",
                         "LowerExcHandlers", "LowerSIMDLoop", "ExpandAtomicModify",
                         "CancellationLowering"]
for level in 0:3
    push!(PASS_SPECS, PassSpec("julia<level=$level>"; cpp="julia<level=$level>",
                               port=JuliaIR.pipeline(; level), kind=:module, cpp_runs=8,
                               aborts=true, inherits=PIPELINE_PASSES))
end
