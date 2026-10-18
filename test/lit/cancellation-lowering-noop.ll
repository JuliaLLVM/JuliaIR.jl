; Julia 1.13 and earlier have no cancellation points (and no CancellationLowering): for
; their IR, the port changes nothing, and needs no runtime facts.

; UNSUPPORTED: julia-ge-1.14
; RUN: opt -passes=CancellationLowering -S %s | FileCheck %s
; RUN: opt -passes=jl-cancellation-lowering -S %s | FileCheck %s

; the port ran
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=CancellationLowering -S %s -o /dev/null
; RUN: grep -c 'pass	jl-cancellation-lowering	julia=' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 2

declare i32 @julia.cancellation_point()
declare ptr @julia.get_pgcstack()
declare void @unsafe_call()

; CHECK-LABEL: @f(
; CHECK-NEXT: entry:
; CHECK-NEXT: %pgcstack = call ptr @julia.get_pgcstack()
; CHECK-NEXT: %r = call i32 @julia.cancellation_point()
; CHECK-NEXT: call void @unsafe_call()
; CHECK-NEXT: ret i32 %r
define i32 @f() {
entry:
  %pgcstack = call ptr @julia.get_pgcstack()
  %r = call i32 @julia.cancellation_point()
  call void @unsafe_call()
  ret i32 %r
}

; CHECK-LABEL: @g(
; CHECK-NEXT: entry:
; CHECK-NEXT: %pgcstack = call ptr @julia.get_pgcstack()
; CHECK-NEXT: call void @unsafe_call()
; CHECK-NEXT: ret void
define void @g() "julia.ipo_reset_safe" {
entry:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @unsafe_call()
  ret void
}
