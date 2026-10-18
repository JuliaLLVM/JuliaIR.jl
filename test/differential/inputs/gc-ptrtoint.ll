; GC invariant violations, which the C++ GCInvariantVerifier rejects by aborting
define i64 @ptrtoint_tracked(ptr addrspace(10) %x) {
  %y = ptrtoint ptr addrspace(10) %x to i64
  ret i64 %y
}
