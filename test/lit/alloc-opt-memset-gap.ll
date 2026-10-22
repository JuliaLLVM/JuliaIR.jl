; A memset can start in an unused gap before a field retained by stack splitting.
; RUN: opt -passes='function(jl-alloc-opt,sroa,instcombine)' -S %s | FileCheck %s

target datalayout = "e-p:64:64-i64:64-n8:16:32:64-S128-ni:10:11:12:13"
@tag = external addrspace(10) global {}
declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare void @llvm.memset.p11.i64(ptr addrspace(11), i8, i64, i1 immarg)

; CHECK-LABEL: @memset_gap(
; CHECK-NEXT: call ptr @julia.get_pgcstack()
; CHECK-NEXT: ret i64 1
define i64 @memset_gap() {
  %pgcstack = call ptr @julia.get_pgcstack()
  %obj = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 24, ptr addrspace(10) @tag)
  %base = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  %gap = getelementptr inbounds i8, ptr addrspace(11) %base, i64 8
  %last = getelementptr inbounds i8, ptr addrspace(11) %base, i64 16
  store i64 1, ptr addrspace(11) %base
  store i64 2, ptr addrspace(11) %last
  call void @llvm.memset.p11.i64(ptr addrspace(11) %gap, i8 0, i64 16, i1 false)
  %a = load i64, ptr addrspace(11) %base
  %b = load i64, ptr addrspace(11) %last
  %sum = add i64 %a, %b
  ret i64 %sum
}
