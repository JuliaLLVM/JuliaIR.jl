; GC invariant violations, which the C++ GCInvariantVerifier rejects by aborting
define ptr addrspace(10) @cast_decayed(ptr addrspace(11) %x) {
  %y = addrspacecast ptr addrspace(11) %x to ptr addrspace(10)
  ret ptr addrspace(10) %y
}
