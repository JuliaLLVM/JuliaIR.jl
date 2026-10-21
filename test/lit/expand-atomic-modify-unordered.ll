; REQUIRES: julia-ge-1.13
; RUN: opt -passes='function(jl-expand-atomic-modify),verify' -S %s | FileCheck %s

; LLVM requires monotonic or stronger ordering for atomicrmw. Promote unordered
; modifications on the fast path, just as the compare-exchange path does.
declare {i64, i64} @julia.atomicmodify.i64(ptr, ptr, i8, i8, ...)

define internal i64 @add(i64 %old, i64 %value) {
  %new = add i64 %old, %value
  ret i64 %new
}

; CHECK-LABEL: define { i64, i64 } @unordered_add(
; CHECK: atomicrmw add ptr %ptr, i64 %value monotonic
; CHECK-NOT: call {{.*}}@julia.atomicmodify
; CHECK: ret { i64, i64 }
define {i64, i64} @unordered_add(ptr %ptr, i64 %value) {
  %pair = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(
    ptr align(8) %ptr, ptr @add, i8 1, i8 1, i64 %value)
  ret {i64, i64} %pair
}
