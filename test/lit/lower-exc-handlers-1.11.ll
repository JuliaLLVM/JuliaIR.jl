; LowerExcHandlers on the IR of Julia 1.11, whose `julia.except_enter` takes the current
; task and returns the result of setjmp, and which also leaves handlers with
; `jl_pop_handler_noexcept`. See lower-exc-handlers-1.12.ll for the runtime profiles.

; RUN: opt -julia=1.11 -passes='function(jl-lower-exc-handlers<handler-size=256;handler-align=16;setjmp=__sigsetjmp>)' -S %s | FileCheck %s --check-prefixes=CHECK,UNIX
; RUN: opt -julia=1.11 -passes='function(jl-lower-exc-handlers<handler-size=256;handler-align=16;setjmp=jl_setjmp>)' -S %s | FileCheck %s --check-prefixes=CHECK,WINDOWS

declare i32 @julia.except_enter(ptr) returns_twice
declare void @ijl_pop_handler(ptr, i32)
declare void @ijl_pop_handler_noexcept(ptr, i32)
declare void @g()

; CHECK-LABEL: @simple(
; CHECK-NEXT: top:
; CHECK-NEXT: [[BUF:%.*]] = alloca i8, i32 256, align 16
; CHECK-NEXT: call void @llvm.lifetime.start.p0({{(i64 256, )?}}ptr [[BUF]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[BUF]])
; UNIX-NEXT: [[SJ:%.*]] = call i32 @__sigsetjmp(ptr [[BUF]], i32 0) [[RT:#[0-9]+]]
; WINDOWS-NEXT: [[SJ:%.*]] = call i32 @jl_setjmp(ptr [[BUF]]) [[RT:#[0-9]+]]
; CHECK-NEXT: %cmp = icmp eq i32 [[SJ]], 0
; CHECK: after:
; CHECK-NEXT: call void @ijl_pop_handler(ptr %ct, i32 1)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 256, )?}}ptr [[BUF]])
; CHECK-NEXT: ret void
define void @simple(ptr %ct) {
top:
  %r = call i32 @julia.except_enter(ptr %ct)
  %cmp = icmp eq i32 %r, 0
  br i1 %cmp, label %try, label %catch
try:
  br label %after
catch:
  br label %after
after:
  call void @ijl_pop_handler(ptr %ct, i32 1)
  ret void
}

; one buffer per nesting level; leaving two levels at once ends both lifetimes
; CHECK-LABEL: @nested(
; CHECK-NEXT: top:
; CHECK-NEXT: [[OUTER:%.*]] = alloca i8, i32 256, align 16
; CHECK-NEXT: [[INNER:%.*]] = alloca i8, i32 256, align 16
; CHECK-NEXT: call void @llvm.lifetime.start.p0({{(i64 256, )?}}ptr [[OUTER]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[OUTER]])
; CHECK: try1:
; CHECK-NEXT: call void @llvm.lifetime.start.p0({{(i64 256, )?}}ptr [[INNER]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[INNER]])
; CHECK: try2:
; CHECK-NEXT: call void @g()
; CHECK-NEXT: call void @ijl_pop_handler_noexcept(ptr %ct, i32 2)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 256, )?}}ptr [[OUTER]])
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 256, )?}}ptr [[INNER]])
; CHECK-NEXT: ret void
; CHECK: catch2:
; CHECK-NEXT: call void @ijl_pop_handler(ptr %ct, i32 1)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 256, )?}}ptr [[INNER]])
; CHECK: catch1:
; CHECK-NEXT: call void @ijl_pop_handler(ptr %ct, i32 1)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 256, )?}}ptr [[OUTER]])
define void @nested(ptr %ct) {
top:
  %r1 = call i32 @julia.except_enter(ptr %ct)
  %c1 = icmp eq i32 %r1, 0
  br i1 %c1, label %try1, label %catch1
try1:
  %r2 = call i32 @julia.except_enter(ptr %ct)
  %c2 = icmp eq i32 %r2, 0
  br i1 %c2, label %try2, label %catch2
try2:
  call void @g()
  call void @ijl_pop_handler_noexcept(ptr %ct, i32 2)
  ret void
catch2:
  call void @ijl_pop_handler(ptr %ct, i32 1)
  br label %after1
after1:
  call void @g()
  call void @ijl_pop_handler_noexcept(ptr %ct, i32 1)
  ret void
catch1:
  call void @ijl_pop_handler(ptr %ct, i32 1)
  ret void
}

; a handler in a loop reuses its buffer, and is left on two paths
; CHECK-LABEL: @loop(
; CHECK-NEXT: top:
; CHECK-NEXT: [[BUF:%.*]] = alloca i8, i32 256, align 16
; CHECK-NOT: alloca
; CHECK: body:
; CHECK: call void @llvm.lifetime.start.p0({{(i64 256, )?}}ptr [[BUF]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[BUF]])
; CHECK: try:
; CHECK-NEXT: call void @g()
; CHECK-NEXT: call void @ijl_pop_handler_noexcept(ptr %ct, i32 1)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 256, )?}}ptr [[BUF]])
; CHECK: catch:
; CHECK-NEXT: call void @ijl_pop_handler(ptr %ct, i32 1)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 256, )?}}ptr [[BUF]])
define void @loop(ptr %ct, i64 %n) {
top:
  br label %body
body:
  %i = phi i64 [ 0, %top ], [ %next, %latch ]
  %r = call i32 @julia.except_enter(ptr %ct)
  %c = icmp eq i32 %r, 0
  br i1 %c, label %try, label %catch
try:
  call void @g()
  call void @ijl_pop_handler_noexcept(ptr %ct, i32 1)
  br label %latch
catch:
  call void @ijl_pop_handler(ptr %ct, i32 1)
  br label %latch
latch:
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %body
exit:
  ret void
}

; CHECK: declare void @ijl_enter_handler(ptr, ptr)
; UNIX: declare i32 @__sigsetjmp(ptr, i32) [[RT]]
; WINDOWS: declare i32 @jl_setjmp(ptr) [[RT]]
; CHECK: attributes [[RT]] = { returns_twice }
