; JuliaLICM hoists `julia.write_barrier` (the barrier of Julia 1.10 through 1.13) once its
; operands are, or can be made, loop invariant. The GC's barrier configuration only
; exists from Julia 1.14 on, so a non-stock `gc-barrier` changes nothing here.
; UNSUPPORTED: julia-ge-1.14

; RUN: opt -passes=JuliaLICM -S %s | FileCheck %s
; RUN: opt -passes='function(loop-mssa(JuliaLICM)),verify' -verify-memoryssa -S %s | FileCheck %s
; RUN: opt -passes='loop(jl-licm<gc-barrier=snapshot>)' -S %s | FileCheck %s

declare void @julia.write_barrier(ptr addrspace(10), ...)
declare ptr addrspace(10) @get(i64)

; CHECK-LABEL: @hoist(
; CHECK: preheader:
; CHECK-NEXT: call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %a, ptr addrspace(10) %b)
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK-NOT: write_barrier
; CHECK: exit:
define void @hoist(ptr addrspace(10) %parent, ptr addrspace(10) %a, ptr addrspace(10) %b, i1 %c) {
preheader:
  br label %loop
loop:
  call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %a, ptr addrspace(10) %b)
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; a child that varies in the loop keeps the barrier there
; CHECK-LABEL: @variant_child(
; CHECK: preheader:
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK: %child = call ptr addrspace(10) @get(i64 %i)
; CHECK-NEXT: call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
define void @variant_child(ptr addrspace(10) %parent, i1 %c) {
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %i.next, %loop ]
  %child = call ptr addrspace(10) @get(i64 %i)
  call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
  %i.next = add i64 %i, 1
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; operands computed in the loop from invariant values are hoisted with the barrier
; CHECK-LABEL: @hoist_operands(
; CHECK: preheader:
; CHECK-NEXT: %parent = addrspacecast ptr %p to ptr addrspace(10)
; CHECK-NEXT: %child = getelementptr i8, ptr addrspace(10) %parent, i64 8
; CHECK-NEXT: call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK-NOT: write_barrier
; CHECK: br i1
define void @hoist_operands(ptr %p, i1 %c) {
preheader:
  br label %loop
loop:
  %parent = addrspacecast ptr %p to ptr addrspace(10)
  %child = getelementptr i8, ptr addrspace(10) %parent, i64 8
  call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
  br i1 %c, label %exit, label %loop
exit:
  ret void
}
