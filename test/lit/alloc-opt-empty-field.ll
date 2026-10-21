; Zero-sized aggregate loads are valid and need no byte-offset arithmetic.
; RUN: opt -passes='function(jl-alloc-opt)' -S %s | FileCheck %s

target datalayout = "e-p:64:64-i64:64-n8:16:32:64-S128-ni:10:11:12:13"
@tag = external addrspace(10) global {}
declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))

; CHECK-LABEL: @empty_field(
; CHECK-NOT: call {{.*}}@julia.gc_alloc_obj
; CHECK: load {}, ptr
define {} @empty_field() {
  %pgcstack = call ptr @julia.get_pgcstack()
  %obj = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 0, ptr addrspace(10) @tag)
  %base = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  %value = load {}, ptr addrspace(11) %base
  ret {} %value
}
