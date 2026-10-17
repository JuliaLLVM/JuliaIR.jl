; Like opt, jlopt optimizes for the target of a module that has a triple: the loop
; vectorizer only vectorizes this loop with a target machine's cost model.

; REQUIRES: x86-registered-target

; RUN: opt -passes=loop-vectorize -S %s | FileCheck %s --check-prefix=GENERIC
; RUN: opt -mtriple=x86_64-unknown-linux-gnu -passes=loop-vectorize -S %s | FileCheck %s --check-prefix=X86

; GENERIC-NOT: vector.body
; X86: vector.body:
; X86: load <{{[0-9]+}} x i32>

define void @add(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %pa = getelementptr inbounds i32, ptr %a, i64 %i
  %pb = getelementptr inbounds i32, ptr %b, i64 %i
  %x = load i32, ptr %pa
  %y = load i32, ptr %pb
  %z = add i32 %x, %y
  store i32 %z, ptr %pa
  %i.next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %i.next, %n
  br i1 %done, label %exit, label %loop

exit:
  ret void
}
