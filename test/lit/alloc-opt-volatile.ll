; Volatile accesses remain observable even when an allocation does not escape.
; RUN: opt -passes='function(jl-alloc-opt)' -S %s | FileCheck %s

target datalayout = "e-p:64:64-i64:64-n8:16:32:64-S128-ni:10:11:12:13"
@tag = external addrspace(10) global {}
declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare void @llvm.memset.p11.i64(ptr addrspace(11), i8, i64, i1 immarg)

; CHECK-LABEL: @volatile_store(
; CHECK: store volatile i64 1,
define void @volatile_store() {
  %pgcstack = call ptr @julia.get_pgcstack()
  %obj = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %base = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  store volatile i64 1, ptr addrspace(11) %base
  ret void
}

; CHECK-LABEL: @volatile_load(
; CHECK: load volatile i64,
define i64 @volatile_load() {
  %pgcstack = call ptr @julia.get_pgcstack()
  %obj = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %base = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  store i64 1, ptr addrspace(11) %base
  %v = load volatile i64, ptr addrspace(11) %base
  ret i64 %v
}

; CHECK-LABEL: @volatile_memset(
; CHECK: call void @llvm.memset.p11.i64(ptr addrspace(11) %base, i8 0, i64 8, i1 true)
define void @volatile_memset() {
  %pgcstack = call ptr @julia.get_pgcstack()
  %obj = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %base = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  call void @llvm.memset.p11.i64(ptr addrspace(11) %base, i8 0, i64 8, i1 true)
  ret void
}

; CHECK-LABEL: @volatile_atomic(
; CHECK: atomicrmw volatile add
define i64 @volatile_atomic() {
  %pgcstack = call ptr @julia.get_pgcstack()
  %obj = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %base = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  store i64 1, ptr addrspace(11) %base
  %v = atomicrmw volatile add ptr addrspace(11) %base, i64 1 monotonic
  ret i64 %v
}
