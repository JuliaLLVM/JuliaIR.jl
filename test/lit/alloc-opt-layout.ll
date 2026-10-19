; Julia 1.10 and 1.11 use an integer type for stack memory if the data layout has one of
; that width, and a byte array otherwise. Non-integral address spaces (`ni:`) are not
; native integer widths (`n8:...`).

; REQUIRES: julia-1.10 || julia-1.11
; RUN: opt -passes='function(jl-alloc-opt)' -S %s | FileCheck %s

target datalayout = "e-ni:10:11:12:13"

@tag = external addrspace(10) global {}

declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare ptr @julia.pointer_from_objref(ptr addrspace(11))
declare void @external(ptr)

; CHECK-LABEL: @move(
; CHECK: %v = alloca [8 x i8], align 16
define i64 @move(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %p = call ptr @julia.pointer_from_objref(ptr addrspace(11) %d)
  call void @external(ptr %p)
  %l = load i64, ptr addrspace(11) %d, align 8
  ret i64 %l
}
