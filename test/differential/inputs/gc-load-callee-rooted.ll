; GC invariant violations, which the C++ GCInvariantVerifier rejects by aborting
define ptr addrspace(10) @load_callee_rooted(ptr addrspace(12) %p) {
  %y = load ptr addrspace(10), ptr addrspace(12) %p
  ret ptr addrspace(10) %y
}
