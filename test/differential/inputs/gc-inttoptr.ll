; GC invariant violations, which the C++ GCInvariantVerifier rejects by aborting
define ptr addrspace(10) @inttoptr_tracked(i64 %x) {
  %y = inttoptr i64 %x to ptr addrspace(10)
  ret ptr addrspace(10) %y
}
