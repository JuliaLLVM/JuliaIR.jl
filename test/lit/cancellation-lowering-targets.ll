; What of CancellationLowering's output depends on the target, the names of what it
; creates, and the cancellation points it rejects.

; REQUIRES: julia-1.14
; RUN: split-file %s %t

; Points are lowered in the use-list order of `julia.cancellation_point`, which is the
; reverse of the order in the IR here: the last point gets the plain names.
; RUN: opt -passes='function(CancellationLowering<task-gcstack=192;task-ptls=208;task-eh=224;task-reset-ctx=264;tls-safepoint=16;reset-ctx-size=224;reset-ctx-align=8;reset-ctx-gcstack=8;reset-ctx-eh=16;reset-ctx-mctx=24;setjmp=__sigsetjmp>)' -S %t/names.ll | FileCheck %t/names.ll

; Like the code generator's, setjmp takes no savemask argument for a Windows triple. As
; in Julia's pass, the triple isn't normalized: `x86_64-w64-mingw32` (which Windows Julia
; reports) isn't Windows to it, `x86_64-w64-windows-gnu` is. The runtime's setjmp name
; is used whatever the triple.
; RUN: opt -passes='function(CancellationLowering<task-gcstack=192;task-ptls=208;task-eh=224;task-reset-ctx=264;tls-safepoint=16;reset-ctx-size=224;reset-ctx-align=8;reset-ctx-gcstack=8;reset-ctx-eh=16;reset-ctx-mctx=32;setjmp=ijl_setjmp>)' -mtriple=x86_64-w64-windows-gnu -S %t/point.ll | FileCheck %t/point.ll --check-prefix=WINDOWS
; RUN: opt -passes='function(CancellationLowering<task-gcstack=192;task-ptls=208;task-eh=224;task-reset-ctx=264;tls-safepoint=16;reset-ctx-size=224;reset-ctx-align=8;reset-ctx-gcstack=8;reset-ctx-eh=16;reset-ctx-mctx=32;setjmp=ijl_setjmp>)' -mtriple=x86_64-w64-mingw32 -S %t/point.ll | FileCheck %t/point.ll --check-prefix=MINGW

; As with `getOrInsertFunction`, whatever global has setjmp's name is called, also an
; alias.
; RUN: opt -passes='function(CancellationLowering<task-gcstack=192;task-ptls=208;task-eh=224;task-reset-ctx=264;tls-safepoint=16;reset-ctx-size=224;reset-ctx-align=8;reset-ctx-gcstack=8;reset-ctx-eh=16;reset-ctx-mctx=24;setjmp=__sigsetjmp>)' -S %t/alias.ll | FileCheck %t/alias.ll

; Pointers are loaded and stored with the data layout's pointer alignment (Julia's pass
; uses the host's, 8 on 64-bit hosts), and the buffer's address is stored as an integer
; of the pointer's size.
; RUN: opt -passes='function(CancellationLowering<task-gcstack=96;task-ptls=104;task-eh=112;task-reset-ctx=136;tls-safepoint=8;reset-ctx-size=128;reset-ctx-align=8;reset-ctx-gcstack=4;reset-ctx-eh=8;reset-ctx-mctx=12;setjmp=__sigsetjmp>)' -S %t/i686.ll | FileCheck %t/i686.ll

; A point in a function without a GC stack in its entry block, or an invoked one, is
; rejected before anything changes (Julia's pass emits invalid IR for the first and
; leaves the second alone).
; RUN: not opt -passes='function(CancellationLowering<task-gcstack=192;task-ptls=208;task-eh=224;task-reset-ctx=264;tls-safepoint=16;reset-ctx-size=224;reset-ctx-align=8;reset-ctx-gcstack=8;reset-ctx-eh=16;reset-ctx-mctx=24;setjmp=__sigsetjmp>)' -S %t/no-gcstack.ll 2>&1 | FileCheck %t/no-gcstack.ll
; RUN: not opt -passes='function(CancellationLowering<task-gcstack=192;task-ptls=208;task-eh=224;task-reset-ctx=264;tls-safepoint=16;reset-ctx-size=224;reset-ctx-align=8;reset-ctx-gcstack=8;reset-ctx-eh=16;reset-ctx-mctx=24;setjmp=__sigsetjmp>)' -S %t/late-gcstack.ll 2>&1 | FileCheck %t/late-gcstack.ll
; RUN: not opt -passes='function(CancellationLowering<task-gcstack=192;task-ptls=208;task-eh=224;task-reset-ctx=264;tls-safepoint=16;reset-ctx-size=224;reset-ctx-align=8;reset-ctx-gcstack=8;reset-ctx-eh=16;reset-ctx-mctx=24;setjmp=__sigsetjmp>)' -S %t/invoke.ll 2>&1 | FileCheck %t/invoke.ll

;--- names.ll
declare i32 @julia.cancellation_point()
declare ptr @julia.get_pgcstack()
declare void @unsafe_call()

; CHECK-LABEL: @f(
; CHECK: %reset_ctx_prev3 = load atomic volatile ptr, ptr %reset_ctx_ptr
; CHECK-NEXT: %region_live4 = icmp eq ptr %reset_ctx_prev3, %cancel_ucontext
; CHECK-NEXT: br i1 %region_live4, label %cancel_pt_cont1, label %cancel_establish2
; CHECK: cancel_establish2:
; CHECK: %ptls5 = load ptr, ptr %ptls_field_ptr
; CHECK: cancel_pt_cont1:
; CHECK-NEXT: %{{[0-9]+}} = phi i32 [ 0, %entry ], [ %{{[0-9]+}}, %cancel_establish2 ]
; CHECK: %reset_ctx_prev = load atomic volatile ptr, ptr %reset_ctx_ptr
; CHECK-NEXT: %region_live = icmp eq ptr %reset_ctx_prev, %cancel_ucontext
; CHECK-NEXT: br i1 %region_live, label %cancel_pt_cont, label %cancel_establish
; CHECK: cancel_pt_cont:
; CHECK-NEXT: %{{[0-9]+}} = phi i32 [ 0, %cancel_pt_cont1 ], [ %{{[0-9]+}}, %cancel_establish ]
define i32 @f() {
entry:
  %pgcstack = call ptr @julia.get_pgcstack()
  %a = call i32 @julia.cancellation_point()
  call void @unsafe_call()
  %b = call i32 @julia.cancellation_point()
  %s = add i32 %a, %b
  ret i32 %s
}

;--- point.ll
declare i32 @julia.cancellation_point()
declare ptr @julia.get_pgcstack()

; WINDOWS-LABEL: @f(
; WINDOWS: %cancel_mctx = getelementptr i8, ptr %cancel_ucontext, i64 32
; WINDOWS-NEXT: %{{[0-9]+}} = call i32 @ijl_setjmp(ptr %cancel_mctx) #[[ATTR:[0-9]+]]
; WINDOWS: declare i32 @ijl_setjmp(ptr)
; WINDOWS: attributes #[[ATTR]] = { returns_twice }
; MINGW-LABEL: @f(
; MINGW: %{{[0-9]+}} = call i32 @ijl_setjmp(ptr %cancel_mctx, i32 0) #[[ATTR:[0-9]+]]
; MINGW: declare i32 @ijl_setjmp(ptr, i32)
define void @f() {
entry:
  %pgcstack = call ptr @julia.get_pgcstack()
  %r = call i32 @julia.cancellation_point()
  ret void
}

;--- i686.ll
target datalayout = "e-m:e-p:32:32-p270:32:32-p271:32:32-p272:64:64-i128:128-f64:32:64-f80:32-n8:16:32-S128"
target triple = "i686-unknown-linux-gnu"

declare i32 @julia.cancellation_point()
declare ptr @julia.get_pgcstack()

; CHECK-LABEL: @f(
; CHECK: %cancel_ucontext = alloca [128 x i8], align 8
; CHECK: %reset_ctx_prev = load atomic volatile ptr, ptr %reset_ctx_ptr monotonic, align 4
; CHECK: store atomic volatile ptr null, ptr %reset_ctx_ptr release, align 4
; CHECK: %ptls = load ptr, ptr %ptls_field_ptr, align 4
; CHECK: %safepoint_addr = getelementptr inbounds i8, ptr %ptls, i32 8
; CHECK: %safepoint = load atomic ptr, ptr %safepoint_addr monotonic, align 4
; CHECK: %0 = ptrtoint ptr %cancel_ucontext to i32
; CHECK-NEXT: store atomic volatile i32 %0, ptr %cancel_ucontext monotonic, align 8
; CHECK-NEXT: %saved_gcstack = load ptr, ptr %pgcstack, align 4
; CHECK-NEXT: %cancel_gcstack_slot = getelementptr i8, ptr %cancel_ucontext, i64 4
; CHECK-NEXT: store volatile ptr %saved_gcstack, ptr %cancel_gcstack_slot, align 4
; CHECK: store atomic volatile ptr %cancel_ucontext, ptr %reset_ctx_ptr release, align 4
define void @f() {
entry:
  %pgcstack = call ptr @julia.get_pgcstack()
  %r = call i32 @julia.cancellation_point()
  ret void
}

;--- no-gcstack.ll
declare i32 @julia.cancellation_point()

; CHECK: CancellationLoweringError: cancellation point in a function without a GC stack in function f
define void @f() {
entry:
  %r = call i32 @julia.cancellation_point()
  ret void
}

;--- late-gcstack.ll
declare i32 @julia.cancellation_point()
declare ptr @julia.get_pgcstack()

; CHECK: CancellationLoweringError: cancellation point in a function without a GC stack in function f
define void @f() {
entry:
  br label %next
next:
  %pgcstack = call ptr @julia.get_pgcstack()
  %r = call i32 @julia.cancellation_point()
  ret void
}

;--- alias.ll
declare i32 @julia.cancellation_point()
declare ptr @julia.get_pgcstack()

@__sigsetjmp = alias i32 (ptr, i32), ptr @real_setjmp

define i32 @real_setjmp(ptr %buf, i32 %savemask) {
  ret i32 0
}

; CHECK-LABEL: @f(
; CHECK: %{{[0-9]+}} = call i32 @__sigsetjmp(ptr %cancel_mctx, i32 0) #[[ATTR:[0-9]+]]
; CHECK: attributes #[[ATTR]] = { returns_twice }
define void @f() {
entry:
  %pgcstack = call ptr @julia.get_pgcstack()
  %r = call i32 @julia.cancellation_point()
  ret void
}

;--- invoke.ll
declare i32 @julia.cancellation_point()
declare ptr @julia.get_pgcstack()
declare i32 @__gxx_personality_v0(...)

; CHECK: CancellationLoweringError: `julia.cancellation_point` is invoked in function f
define void @f() personality ptr @__gxx_personality_v0 {
entry:
  %pgcstack = call ptr @julia.get_pgcstack()
  %r = invoke i32 @julia.cancellation_point() to label %ok unwind label %bad
ok:
  ret void
bad:
  %lp = landingpad { ptr, i32 } cleanup
  ret void
}
