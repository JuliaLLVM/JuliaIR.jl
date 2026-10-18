# RemoveJuliaAddrspaces and RemoveAddrspaces: rebuild a module with the address spaces of
# its pointer types mapped by a function, Julia's address spaces 10 to 13 to 0 for the
# former, every address space to 0 for the latter. Port of Julia's
# `src/llvm-remove-addrspaces.cpp` (opaque pointers), whose behaviour is the same at every
# supported version except for keeping the compile units, which Julia 1.13 added and the
# port does for every version (see `remove_addrspaces!`).
#
# Types can't be changed in place, so every global variable, alias and function is
# recreated with the mapped types (the old one is renamed `<name>.bad` and deleted at the
# end), and the bodies, initializers, aliasees and metadata are mapped onto the new ones
# with one value map. Identified structs that have a body are recreated as well,
# taking the name of the old one, which is renamed `<name>.bad` (in the whole context).

# The type remapper (C++ `AddrspaceRemoveTypeRemapper`): maps the pointer types in a type,
# caching the result for the whole run of the pass, so that an identified struct is
# recreated only once.
struct AddrspaceRemapper{F}
    asmap::F
    mapped::Dict{LLVMType,LLVMType}
end

AddrspaceRemapper(asmap) = AddrspaceRemapper(asmap, Dict{LLVMType,LLVMType}())

function map_addrspace(r::AddrspaceRemapper, as::Integer)
    new = r.asmap(Int(as))
    new isa Integer && 0 <= new < 2^24 ||
        throw(ArgumentError("the address space mapping returned $(repr(new)) for address space $as, expected an address space (an integer from 0 to 2^24-1)"))
    return Int(new)
end

function (r::AddrspaceRemapper)(@nospecialize(typ::LLVMType))
    new = get(r.mapped, typ, nothing)
    new === nothing || return new

    new = typ
    if typ isa LLVM.PointerType
        new = LLVM.PointerType(map_addrspace(r, typ.addrspace))
    elseif typ isa LLVM.FunctionType
        new = LLVM.FunctionType(r(typ.return_type), LLVMType[r(t) for t in typ.parameters];
                                vararg=isvararg(typ))
    elseif typ isa LLVM.StructType
        if isliteral(typ)
            new = LLVM.StructType(LLVMType[r(t) for t in typ.elements];
                                  packed=ispacked(typ))
        elseif !isopaque(typ)
            # always a new struct, even if none of its elements change
            new = LLVM.StructType("")
            name = typ.name
            if name !== nothing && !isempty(name)
                typ.name = name * ".bad"
                new.name = name
            end
            # the struct may contain pointers to itself
            r.mapped[typ] = new
            elements!(new, LLVMType[r(t) for t in typ.elements]; packed=ispacked(typ))
        end
    elseif typ isa LLVM.ArrayType
        new = LLVM.ArrayType(r(typ.element_type), typ.length)
    elseif typ isa LLVM.VectorType
        new = LLVM.VectorType(r(typ.element_type), typ.length)
    elseif typ isa LLVM.ScalableVectorType
        new = LLVM.ScalableVectorType(r(typ.element_type), typ.min_length)
    end
    # other types, like target extension types, are kept
    r.mapped[typ] = new
    return new
end

# The value materializer (C++ `AddrspaceRemoveValueMaterializer`): rebuilds constant
# expressions with their operands and type mapped, folding address space casts that
# become casts to the same address space. Getelementptr expressions are left to LLVM,
# which maps their source element type.
struct AddrspaceMaterializer{R<:AddrspaceRemapper}
    remapper::R
    vmap::ValueMap
end

map_constant(m::AddrspaceMaterializer, @nospecialize(val::Value)) =
    map_value(val, m.vmap; type_mapper=m.remapper, materializer=m)

function (m::AddrspaceMaterializer)(@nospecialize(val::Value))
    val isa ConstantExpr || return nothing
    typ = m.remapper(val.value_type)
    op = val.opcode
    if op == LLVM.Opcode.AddrSpaceCast
        src = map_constant(m, val.operands[1])
        src === nothing && return nothing
        return pointer_addrspace(src) == pointer_addrspace(typ) ? src : nothing
    end
    ops = Constant[something(map_constant(m, op), op) for op in val.operands]
    op == LLVM.Opcode.GetElementPtr && return nothing
    return with_operands(val, ops; type=typ)
end

# Rename a global value to `<name>.bad`, returning its name, so that the new one can take
# it. Unnamed values stay unnamed.
function rename_bad!(@nospecialize(gv::GlobalValue))
    name = gv.name
    isempty(name) || (gv.name = name * ".bad")
    return name
end

# C++ `copyComdat`
function copy_comdat!(dst::GlobalObject, src::GlobalObject)
    c = src.comdat
    c === nothing && return
    new = Comdat(LLVM.parent(dst), c.name)
    new.selection_kind = c.selection_kind
    dst.comdat = new
    return
end

# Remove the address space casts whose source and destination address spaces became
# the same (C++ `RemoveNoopAddrSpaceCasts`); of vectors of pointers too.
function remove_noop_addrspace_casts!(f::LLVM.Function)
    casts = Instruction[]
    for bb in f.blocks, inst in bb.instructions
        inst isa LLVM.AddrSpaceCastInst || continue
        src = inst.operands[1]
        pointer_addrspace(src) == pointer_addrspace(inst) && push!(casts, inst)
    end
    for cast in casts
        replace_uses!(cast, cast.operands[1])
        erase!(cast)
    end
    return
end

# Map the types of the type attributes (`byval`, `sret`, `byref`, `inalloca`,
# `preallocated`) of the return value and the parameters of `f`.
function remap_type_attributes!(f::LLVM.Function, r::AddrspaceRemapper)
    for attrs in (f.return_attributes, f.parameter_attributes...)
        for attr in collect(attrs)
            attr isa TypeAttribute || continue
            push!(attrs, TypeAttribute(attr.kind, r(attr.value)))
        end
    end
    return
end

function forget_analyses!(am, f::LLVM.Function)
    am === nothing || empty!(am[f])
    return
end

# Rebuild `mod` with the address space `as` of every pointer type replaced by `asmap(as)`
# (C++ `removeAddrspaces`). `am` is the module analysis manager of the pipeline, or
# `nothing`; the analyses of the functions that are deleted are removed from it.
function remove_addrspaces!(mod::LLVM.Module, am, asmap)
    r = AddrspaceRemapper(asmap)
    @dispose vmap=ValueMap() begin
        m = AddrspaceMaterializer(r, vmap)
        map_constant(val) = map_value(val, vmap; type_mapper=r, materializer=m)

        # the new global values, without contents or attributes yet
        globals = collect(mod.globals)
        for gv in globals
            name = rename_bad!(gv)
            new = GlobalVariable(mod, r(gv.global_value_type), name,
                                 r(gv.value_type).addrspace)
            new.constant = gv.constant
            new.linkage = gv.linkage
            new.threadlocal_mode = gv.threadlocal_mode
            copy_attributes!(new, gv)
            vmap[gv] = new
        end
        aliases = collect(mod.aliases)
        for ga in aliases
            name = rename_bad!(ga)
            new = GlobalAlias(mod, r(ga.global_value_type), name;
                              addrspace=r(ga.value_type).addrspace)
            new.linkage = ga.linkage
            copy_attributes!(new, ga)
            vmap[ga] = new
        end
        functions = collect(mod.functions)
        for f in functions
            name = rename_bad!(f)
            # functions keep their (program) address space
            new = LLVM.Function(mod, name, r(f.function_type);
                                addrspace=f.value_type.addrspace)
            new.linkage = f.linkage
            vmap[f] = new
        end
        # indirect functions too, unlike Julia, which leaves them referring to the
        # resolvers it deletes
        ifuncs = collect(mod.ifuncs)
        for gi in ifuncs
            name = rename_bad!(gi)
            new = GlobalIFunc(mod, r(gi.global_value_type), map_constant(gi.resolver), name)
            new.linkage = gi.linkage
            copy_attributes!(new, gi)
            vmap[gi] = new
        end

        # initializers and comdats of the global variables
        for gv in globals
            isdeclaration(gv) && continue
            new = vmap[gv]
            new.initializer = map_constant(gv.initializer)
            copy_comdat!(new, gv)
            gv.initializer = nothing
        end

        # Keep the compile units: from LLVM 20 on, cloning a function only keeps those it
        # visits, so the named metadata would get a copy of one that only inlined
        # subprograms refer to (Julia 1.13 added this; it depends on the LLVM, not the
        # Julia version). Unlike Julia, do it before mapping the metadata of global
        # variables, and also keep the variables of their debug info, so that the compile
        # units, whose `globals` aren't mapped, keep describing them.
        if haskey(mod.metadata, "llvm.dbg.cu")
            for cu in mod.metadata["llvm.dbg.cu"].operands
                vmap.metadata[cu] = cu
            end
        end
        for gv in globals, (kind, md) in gv.metadata
            kind == MD_dbg && md isa DIGlobalVariableExpression || continue
            var = md.variable
            var === nothing || (vmap.metadata[var] = var)
        end

        # the functions, declarations included (for their attributes)
        for f in functions
            new = vmap[f]
            for (arg, new_arg) in zip(f.parameters, new.parameters)
                new_arg.name = arg.name
                vmap[arg] = new_arg
            end
            clone_into!(new, f; value_map=vmap, type_mapper=r, materializer=m,
                        changes=LLVM.CloneFunctionChangeType.GlobalChanges)
            remap_type_attributes!(new, r)
            copy_comdat!(new, f)
            remove_noop_addrspace_casts!(new)
            empty!(f)
        end

        for ga in aliases
            aliasee = ga.aliasee
            aliasee === nothing || (vmap[ga].aliasee = map_constant(aliasee))
            ga.aliasee = nothing
        end

        # Metadata of the global variables, unlike Julia also of declarations, and of the
        # indirect functions, after everything that is mapped with the type mapper and
        # materializer: it is mapped without them (like Julia does), and would leave the
        # map with constant expressions of the old types for those to reuse.
        for gv in globals, (kind, md) in gv.metadata
            add_metadata!(vmap[gv], kind, map_metadata(md, vmap))
        end
        for gi in ifuncs, (kind, md) in gi.metadata
            add_metadata!(vmap[gi], kind, map_metadata(md, vmap))
        end

        for (_, node) in mod.metadata
            ops = node.operands
            for i in eachindex(ops)
                ops[i] = map_metadata(ops[i], vmap)
            end
        end

        foreach(erase!, globals)
        foreach(erase!, aliases)
        foreach(erase!, ifuncs)
        for f in functions
            forget_analyses!(am, f)
            erase!(f)
        end
    end

    # intrinsics whose overloaded types changed get the name that matches them
    for f in collect(mod.functions)
        remangled = remangle_intrinsic(f)
        remangled === nothing && continue
        replace_uses!(f, remangled)
        forget_analyses!(am, f)
        erase!(f)
    end

    return PreservedAnalyses(CFGAnalyses)
end

remove_all_addrspace(as::Int) = AS_GENERIC
remove_julia_addrspace(as::Int) = is_special_addrspace(as) ? AS_GENERIC : as

const REMOVE_JULIA_ADDRSPACES =
    define_pass("jl-remove-addrspaces", :module,
                (mod, am, opts) -> remove_addrspaces!(mod, am, remove_julia_addrspace);
                required=true, cpp_name="RemoveJuliaAddrspaces")

const REMOVE_ADDRSPACES =
    define_pass("jl-remove-all-addrspaces", :module,
                (mod, am, opts) -> remove_addrspaces!(mod, am, remove_all_addrspace);
                required=true, cpp_name="RemoveAddrspaces")

"""
    JuliaIR.RemoveJuliaAddrspacesPass()

Remove Julia's address spaces from a module (`jl-remove-addrspaces` in a pipeline):
pointers in address spaces 10 to 13 (tracked, derived, callee-rooted and loaded
pointers) become pointers in address space 0, while other address spaces are kept.
Address space casts that become casts to the same address space are removed, and
intrinsics are renamed after their new types (`llvm.memcpy.p10.p10.i64` becomes
`llvm.memcpy.p0.p0.i64`).

The pass recreates every global variable, alias and function of the module, and every
identified struct type that has a body; the old struct types are renamed
`<name>.bad`, also for other modules of the same context. References to the global
values of the module taken before the pass are invalid afterwards: look them up by name
again.
"""
RemoveJuliaAddrspacesPass(; kwargs...) = custom_pass(REMOVE_JULIA_ADDRSPACES; kwargs...)

"""
    JuliaIR.RemoveAddrspacesPass([asmap])

Map the address spaces of the pointer types in a module (`jl-remove-all-addrspaces` in a
pipeline, which maps every address space to 0). `asmap` is a function that takes an
address space (an `Int`) and returns the address space to use instead; without it, every
address space becomes 0. Otherwise the pass works like
[`JuliaIR.RemoveJuliaAddrspacesPass`](@ref).
"""
RemoveAddrspacesPass(; kwargs...) = custom_pass(REMOVE_ADDRSPACES; kwargs...)
function RemoveAddrspacesPass(asmap; kwargs...)
    impl = (mod, am, opts) -> remove_addrspaces!(mod, am, asmap)
    return custom_pass(with_impl(REMOVE_ADDRSPACES, impl); kwargs...)
end
