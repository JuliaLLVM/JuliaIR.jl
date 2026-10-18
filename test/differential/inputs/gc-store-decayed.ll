; GC invariant violations, which the C++ GCInvariantVerifier rejects by aborting
define void @store_decayed(ptr addrspace(10) %x, ptr %p) {
  %y = addrspacecast ptr addrspace(10) %x to ptr addrspace(11)
  store ptr addrspace(11) %y, ptr %p
  ret void
}
