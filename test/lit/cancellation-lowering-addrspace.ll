; REQUIRES: julia-1.14
; RUN: opt -passes='function(jl-cancellation-lowering<task-gcstack=192;task-ptls=208;task-eh=224;task-reset-ctx=264;tls-safepoint=16;reset-ctx-size=224;reset-ctx-align=8;reset-ctx-gcstack=8;reset-ctx-eh=16;reset-ctx-mctx=24;setjmp=__sigsetjmp>),verify' -S %s | FileCheck %s

; The reset buffer lives on the stack, but the task and setjmp use generic pointers.
target datalayout = "e-p:64:64-A5"
declare ptr @julia.get_pgcstack()
declare i32 @julia.cancellation_point()

; CHECK-LABEL: define void @f()
; CHECK: %cancel_ucontext = alloca [224 x i8], align 8, addrspace(5)
; CHECK-NEXT: %cancel_ucontext_generic = addrspacecast ptr addrspace(5) %cancel_ucontext to ptr
; CHECK: icmp eq ptr %reset_ctx_prev, %cancel_ucontext_generic
; CHECK: %cancel_mctx = getelementptr i8, ptr %cancel_ucontext_generic, i64 24
; CHECK: call i32 @__sigsetjmp(ptr %cancel_mctx, i32 0)
; CHECK: store atomic volatile ptr %cancel_ucontext_generic, ptr %reset_ctx_ptr release
; CHECK: ret void
define void @f() {
  %gcstack = call ptr @julia.get_pgcstack()
  %point = call i32 @julia.cancellation_point()
  ret void
}
