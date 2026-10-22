# RemoveJuliaAddrspaces

Julia's code generator keeps GC-managed objects in pointers in special address spaces:
tracked pointers to objects (10), pointers derived from them (11), pointers rooted by a
caller (12) and pointers loaded from an object (13). These address spaces mean nothing to
LLVM's back-ends, so before Julia's IR is handed to one (for a GPU, for example), Julia's
`RemoveJuliaAddrspaces` pass turns them into pointers in address space 0. Other address
spaces (a GPU's global or shared memory, the stack of AMDGPU) are kept. Julia also has
`RemoveAddrspaces`, which turns every address space into 0, and which can take another
mapping of address spaces.

`jl-remove-addrspaces` (`JuliaIR.RemoveJuliaAddrspacesPass`) and
`jl-remove-all-addrspaces` (`JuliaIR.RemoveAddrspacesPass`) port these two passes, and
`jlopt` runs them for Julia's names (`RemoveJuliaAddrspaces`, `RemoveAddrspaces`). Both are
required module passes. `JuliaIR.RemoveAddrspacesPass(asmap)` takes the mapping as a
function from an address space to another (`as -> as == 3 ? 0 : as`); in a pipeline, the
pass always maps every address space to 0.

The port uses the same rules for every Julia version from 1.10 on. It includes the
debug-info fixes added in Julia 1.13, as described below.

## How it works

To keep types and uses consistent, the pass rebuilds the module:

1. Every global variable, alias and function is renamed `<name>.bad`, and a new one with
   the old name and the mapped types is created. Functions keep their own (program)
   address space.
2. The initializers of the global variables, the bodies of the functions and the
   aliasees are mapped onto the new values with LLVM's value mapper (LLVM.jl's
   `map_value` and `clone_into!`), and so are the metadata of the global values and the
   named metadata. Constant expressions are rebuilt; an address space cast that becomes
   a cast to the same address space is folded away.
3. Address space casts between equal address spaces are removed from the function
   bodies, the old global values are deleted, and intrinsics whose overloaded types
   changed are renamed after their new types (`llvm.memcpy.p10.p10.i64` becomes
   `llvm.memcpy.p0.p0.i64`), reusing a declaration of that name if the module has one.

Types are mapped recursively: pointer types get the mapped address space, and function,
array, vector and literal struct types are rebuilt from their mapped elements. An
identified struct (`%T = type { ... }`) that has a body is always recreated, also when
nothing in it changes, and the new struct takes the name of the old one, which is renamed
`%T.bad`. Structs live in the LLVM context, not the module, so other modules of the same
context that use `%T` then refer to `%T.bad`. Opaque structs and the other kinds of types
(integers, floating-point types, target extension types like `target("spirv.Event")`, ...)
are kept.

As every global value is replaced, references to the global values of the module (and to
anything in them) taken before the pass are invalid afterwards; look them up by name
again. The analyses of the deleted functions are removed from the pipeline's analysis
manager.

## Differences with Julia's C++ passes

- The compile units of `!llvm.dbg.cu` are mapped to themselves, for every Julia version.
  From LLVM 20 on, cloning a function only does so for the compile units that it visits,
  so one that only the subprograms of inlined code refer to would be duplicated, and the
  module rejected by the verifier. Julia 1.13 added this, which matters for older Julia
  versions too when they run with a newer LLVM.
- The compile units are kept before the metadata of global variables is mapped, and so
  are the variables (`DIGlobalVariable`) of their debug info. Julia 1.13 and later map
  the debug info of global variables first, which duplicates the variable and its
  compile unit: the global variable then refers to a compile unit that isn't in
  `!llvm.dbg.cu`, while the listed one describes a variable that no longer exists.
- The metadata of global variable declarations is kept; Julia's pass drops it. The code
  generator of Julia 1.14 and later attaches `!julia.constgv` to declarations of global
  variables, so this is the one difference for the IR it emits.
- The types of all type attributes of functions are mapped: Julia's pass only maps the
  first of `byval`, `sret` and `byref`, leaving `inalloca` and `preallocated` with the
  old struct.
- The metadata of the global variables is mapped after their initializers, the function
  bodies and the aliasees. Like Julia, the ports map it without the type mapper and the
  materializer, and Julia's pass maps it right after the initializer of each global
  variable: a constant expression in the metadata of one global variable
  (`!{ptr addrspace(11) addrspacecast (...)}`) is then reused, with its old type, for the
  initializer of a later one or in a function or aliasee, which the verifier rejects.
- Indirect functions (`ifunc`) are recreated with the mapped type and resolver, like
  aliases. Julia's pass leaves them referring to the resolver it deletes.

Apart from the metadata of declarations from Julia 1.14 on, the IR that Julia's code
generator emits has none of these constructs (except compile units, which the ports keep
like Julia 1.13), so for it the ports give the same result as the C++ passes.

With LLVM 15 (Julia 1.10), `clone_into!` copies prefix and prologue data of functions
without mapping them, like Julia's pass there; later versions of LLVM map them.
