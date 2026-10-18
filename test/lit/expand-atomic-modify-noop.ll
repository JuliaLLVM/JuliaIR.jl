; Julia 1.12 and earlier have no ExpandAtomicModify (their code generator emits no
; `julia.atomicmodify` calls): for their IR, the port leaves the calls alone.

; UNSUPPORTED: julia-ge-1.13
; RUN: opt -passes=ExpandAtomicModify -S %s | FileCheck %s
; RUN: opt -passes=jl-expand-atomic-modify -S %s | FileCheck %s

; the port ran
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=ExpandAtomicModify -S %s -o /dev/null
; RUN: grep -c 'pass	jl-expand-atomic-modify	julia=' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 2

declare {i64, i64} @julia.atomicmodify.i64(ptr, ptr, i8, i8, ...)

define i64 @add(i64 %x, i64 %y) {
  %z = add i64 %x, %y
  ret i64 %z
}

; CHECK-LABEL: @modify(
; CHECK-NEXT: %r = call { i64, i64 } (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align 8 %p, ptr @add, i8 7, i8 1, i64 %v)
; CHECK-NEXT: %old = extractvalue { i64, i64 } %r, 0
; CHECK-NEXT: ret i64 %old
define i64 @modify(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}
