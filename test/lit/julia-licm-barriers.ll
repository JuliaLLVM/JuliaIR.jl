; JuliaLICM on the object and field write barriers of Julia master: a barrier is hoisted
; once its parent, children and (for a field barrier) slots are, or can be made, loop
; invariant; a field barrier whose slots vary in the loop is demoted to an object barrier
; of the same parent and children. The GC's barrier configuration (`gc-barrier`) can
; forbid both: snapshot barriers aren't hoisted, field-precise ones aren't demoted.
; REQUIRES: julia-1.14

; RUN: split-file %s %t
; RUN: opt -passes=JuliaLICM -S %t/barriers.ll | FileCheck %s --check-prefixes=CHECK,STOCK
; RUN: opt -passes='function(loop-mssa(JuliaLICM)),verify' -verify-memoryssa -S %t/barriers.ll | FileCheck %s --check-prefixes=CHECK,STOCK
; RUN: opt -passes='loop(jl-licm<gc-barrier=snapshot>)' -S %t/barriers.ll | FileCheck %s --check-prefix=SNAPSHOT
; RUN: opt -passes='loop(jl-licm<gc-barrier=snapshot-field-precise>)' -S %t/barriers.ll | FileCheck %s --check-prefix=SNAPSHOT
; RUN: opt -passes='loop(jl-licm<gc-barrier=field-precise>)' -S %t/barriers.ll | FileCheck %s --check-prefixes=CHECK,PRECISE

; a demotion declares the object barrier when the module lacks it, and reuses a
; declaration of the right type
; RUN: opt -passes=JuliaLICM -S %t/declare.ll | FileCheck %s --check-prefix=DECLARE
; RUN: opt -passes=JuliaLICM -S %t/reuse.ll | FileCheck %s --check-prefix=REUSE

; a declaration of another type can't be called: an error, before anything changes
; (the C++ pass builds an invalid call)
; RUN: not opt -passes=JuliaLICM -S %t/mistyped.ll 2>&1 | FileCheck %s --check-prefix=MISTYPED
; MISTYPED: julia.object_write_barrier is declared as void (ptr), not as void (ptr addrspace(10), ...)

;--- barriers.ll
declare void @julia.object_write_barrier(ptr addrspace(10), ...)
declare void @julia.field_write_barrier.p11(ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...)
declare ptr addrspace(10) @get(i64)

; CHECK-LABEL: @object(
; CHECK: preheader:
; CHECK-NEXT: call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %a, ptr addrspace(10) %b)
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK-NOT: write_barrier
; CHECK: exit:
; SNAPSHOT-LABEL: @object(
; SNAPSHOT: loop:
; SNAPSHOT-NEXT: call void (ptr addrspace(10), ...) @julia.object_write_barrier(
define void @object(ptr addrspace(10) %parent, ptr addrspace(10) %a, ptr addrspace(10) %b, i1 %c) {
preheader:
  br label %loop
loop:
  call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %a, ptr addrspace(10) %b)
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; a field barrier with invariant slots stays a field barrier
; CHECK-LABEL: @field(
; CHECK: preheader:
; CHECK-NEXT: %slot = getelementptr i8, ptr addrspace(10) %parent, i64 8
; CHECK-NEXT: %slot.derived = addrspacecast ptr addrspace(10) %slot to ptr addrspace(11)
; CHECK-NEXT: call void (ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %slot.derived, ptr addrspace(10) %child)
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK-NOT: write_barrier
; CHECK: exit:
; SNAPSHOT-LABEL: @field(
; SNAPSHOT: loop:
; SNAPSHOT: call void {{.*}} @julia.field_write_barrier.p11(
define void @field(ptr addrspace(10) %parent, ptr addrspace(10) %child, i1 %c) {
preheader:
  br label %loop
loop:
  %slot = getelementptr i8, ptr addrspace(10) %parent, i64 8
  %slot.derived = addrspacecast ptr addrspace(10) %slot to ptr addrspace(11)
  call void (ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %slot.derived, ptr addrspace(10) %child)
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; varying slots demote the barrier to an object barrier, which keeps the reset region;
; every slot that can be is still hoisted. Field-precise barriers keep the field
; barrier in the loop, but its invariant operands are hoisted all the same.
; CHECK-LABEL: @varying_slots(
; CHECK: preheader:
; CHECK-NEXT: %slot1 = getelementptr i8, ptr addrspace(10) %parent, i64 8
; CHECK-NEXT: %slot1.derived = addrspacecast ptr addrspace(10) %slot1 to ptr addrspace(11)
; STOCK-NEXT: call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %a, ptr addrspace(10) %b), !julia.reset_region ![[REGION:[0-9]+]]
; CHECK-NEXT: br label %loop
; CHECK: loop:
; STOCK-NOT: write_barrier
; PRECISE: call void (ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %slot1.derived, ptr addrspace(10) %a, ptr addrspace(11) %slot2.derived, ptr addrspace(10) %b), !julia.reset_region
; CHECK: exit:
define void @varying_slots(ptr addrspace(10) %parent, ptr addrspace(10) %a, ptr addrspace(10) %b, i1 %c) {
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %i.next, %loop ]
  %slot1 = getelementptr i8, ptr addrspace(10) %parent, i64 8
  %slot1.derived = addrspacecast ptr addrspace(10) %slot1 to ptr addrspace(11)
  %slot2 = getelementptr ptr addrspace(10), ptr addrspace(10) %parent, i64 %i
  %slot2.derived = addrspacecast ptr addrspace(10) %slot2 to ptr addrspace(11)
  call void (ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %slot1.derived, ptr addrspace(10) %a, ptr addrspace(11) %slot2.derived, ptr addrspace(10) %b), !julia.reset_region !0
  %i.next = add i64 %i, 1
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; a child that varies in the loop keeps either barrier there
; CHECK-LABEL: @varying_child(
; CHECK: preheader:
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK: call void {{.*}} @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
; CHECK: call void {{.*}} @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %slot, ptr addrspace(10) %child)
define void @varying_child(ptr addrspace(10) %parent, ptr addrspace(11) %slot, i1 %c) {
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %i.next, %loop ]
  %child = call ptr addrspace(10) @get(i64 %i)
  call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
  call void (ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %slot, ptr addrspace(10) %child)
  %i.next = add i64 %i, 1
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; STOCK: ![[REGION]] = !{i64 1}
!0 = !{i64 1}

;--- declare.ll
declare void @julia.field_write_barrier.p11(ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...)

; DECLARE-LABEL: @varying_slot(
; DECLARE: preheader:
; DECLARE-NEXT: call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
; DECLARE-NEXT: br label %loop
; DECLARE: declare void @julia.object_write_barrier(ptr addrspace(10) readonly, ...) #[[ATTRS:[0-9]+]]
; DECLARE: attributes #[[ATTRS]] = { norecurse nounwind memory(argmem: read, inaccessiblemem: readwrite) }
define void @varying_slot(ptr addrspace(10) %parent, ptr addrspace(10) %child, i1 %c) {
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %i.next, %loop ]
  %slot = getelementptr ptr addrspace(10), ptr addrspace(10) %parent, i64 %i
  %slot.derived = addrspacecast ptr addrspace(10) %slot to ptr addrspace(11)
  call void (ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %slot.derived, ptr addrspace(10) %child)
  %i.next = add i64 %i, 1
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

;--- reuse.ll
declare void @julia.object_write_barrier(ptr addrspace(10), ...) #0
declare void @julia.field_write_barrier.p11(ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...)

; REUSE: declare void @julia.object_write_barrier(ptr addrspace(10), ...) #[[ATTRS:[0-9]+]]
; REUSE-LABEL: @varying_slot(
; REUSE: preheader:
; REUSE-NEXT: call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
; REUSE-NOT: declare void @julia.object_write_barrier
; REUSE: attributes #[[ATTRS]] = { nounwind }
define void @varying_slot(ptr addrspace(10) %parent, ptr addrspace(10) %child, i1 %c) {
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %i.next, %loop ]
  %slot = getelementptr ptr addrspace(10), ptr addrspace(10) %parent, i64 %i
  %slot.derived = addrspacecast ptr addrspace(10) %slot to ptr addrspace(11)
  call void (ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %slot.derived, ptr addrspace(10) %child)
  %i.next = add i64 %i, 1
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

attributes #0 = { nounwind }

;--- mistyped.ll
declare void @julia.object_write_barrier(ptr)
declare void @julia.field_write_barrier.p11(ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...)

define void @varying_slot(ptr addrspace(10) %parent, ptr addrspace(10) %child, i1 %c) {
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %i.next, %loop ]
  %slot = getelementptr ptr addrspace(10), ptr addrspace(10) %parent, i64 %i
  %slot.derived = addrspacecast ptr addrspace(10) %slot to ptr addrspace(11)
  call void (ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %slot.derived, ptr addrspace(10) %child)
  %i.next = add i64 %i, 1
  br i1 %c, label %exit, label %loop
exit:
  ret void
}
