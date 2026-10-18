; GC invariant violations, which the C++ GCInvariantVerifier rejects by aborting
define ptr @cast_tracked(ptr addrspace(10) %x) {
  %y = addrspacecast ptr addrspace(10) %x to ptr
  ret ptr %y
}
