; Runtime safepoints need FinalLowerGC and cannot survive GPU cleanup.
; RUN: not opt -passes='function(jl-late-gc-cleanup)' -S %s 2>&1 | FileCheck %s

; CHECK: UnsupportedInputError: function poll contains constructs
; CHECK-NEXT: julia.safepoint: safepoints need Julia's runtime and must be lowered by FinalLowerGC
declare void @julia.safepoint(ptr)
define void @poll(ptr %page) {
  call void @julia.safepoint(ptr %page)
  ret void
}
