; LowerExcHandlers on the IR of Julia 1.12, whose `julia.except_enter` takes the current
; task and returns the result of setjmp together with the handler buffer. The runtime
; profile is given explicitly, so the output doesn't depend on the host: a Unix-like
; one, and a Windows one, whose triple drops setjmp's savemask argument. The lifetime
; markers lost their size argument in LLVM 22.

; RUN: opt -julia=1.12 -passes='function(jl-lower-exc-handlers<handler-size=264;handler-align=16;setjmp=__sigsetjmp>)' -S %s | FileCheck %s --check-prefixes=CHECK,UNIX
; RUN: opt -julia=1.12 -mtriple=x86_64-w64-windows-gnu -passes='function(jl-lower-exc-handlers<handler-size=264;handler-align=16;setjmp=jl_setjmp>)' -S %s | FileCheck %s --check-prefixes=CHECK,WINDOWS

; Julia 1.13 and later have no LowerExcHandlers: nothing changes, and no runtime facts
; are needed
; RUN: opt -julia=1.13 -passes='function(jl-lower-exc-handlers)' -S %s | FileCheck %s --check-prefix=NOOP
; RUN: opt -julia=1.14.0-DEV -passes='function(jl-lower-exc-handlers)' -S %s | FileCheck %s --check-prefix=NOOP
; NOOP-LABEL: @simple(
; NOOP: %rb = call { i32, ptr } @julia.except_enter(ptr %ct)
; NOOP-NOT: alloca
; NOOP-NOT: setjmp

declare {i32, ptr} @julia.except_enter(ptr) returns_twice
declare void @ijl_pop_handler(ptr, i32)
declare void @ijl_pop_handler_noexcept(ptr, i32)
declare void @use(ptr)
declare void @g()

; the extracted results become the result of setjmp and the buffer
; CHECK-LABEL: @simple(
; CHECK-NEXT: top:
; CHECK-NEXT: [[BUF:%.*]] = alloca i8, i32 264, align 16
; CHECK-NEXT: call void @llvm.lifetime.start.p0({{(i64 264, )?}}ptr [[BUF]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[BUF]])
; UNIX-NEXT: [[SJ:%.*]] = call i32 @__sigsetjmp(ptr [[BUF]], i32 0) [[RT:#[0-9]+]]
; WINDOWS-NEXT: [[SJ:%.*]] = call i32 @jl_setjmp(ptr [[BUF]]) [[RT:#[0-9]+]]
; CHECK-NEXT: %cmp = icmp eq i32 [[SJ]], 0
; CHECK: try:
; CHECK-NEXT: call void @use(ptr [[BUF]])
; CHECK: after:
; CHECK-NEXT: call void @ijl_pop_handler(ptr %ct, i32 1)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 264, )?}}ptr [[BUF]])
; CHECK-NEXT: ret void
define void @simple(ptr %ct) {
top:
  %rb = call {i32, ptr} @julia.except_enter(ptr %ct)
  %r = extractvalue {i32, ptr} %rb, 0
  %b = extractvalue {i32, ptr} %rb, 1
  %cmp = icmp eq i32 %r, 0
  br i1 %cmp, label %try, label %catch
try:
  call void @use(ptr %b)
  br label %after
catch:
  br label %after
after:
  call void @ijl_pop_handler(ptr %ct, i32 1)
  ret void
}

; other uses of the result get it rebuilt from its parts
; CHECK-LABEL: @aggregate(
; CHECK: [[SJ:%.*]] = call i32 @{{.*}}setjmp(ptr [[BUF:%[0-9]+]]{{.*}}) [[RT]]
; CHECK-NEXT: [[AGG:%.*]] = insertvalue { i32, ptr } undef, i32 [[SJ]], 0
; CHECK-NEXT: [[AGG2:%.*]] = insertvalue { i32, ptr } [[AGG]], ptr [[BUF]], 1
; CHECK-NEXT: %r = icmp eq i32 [[SJ]], 0
; CHECK: %lcssa = phi { i32, ptr } [ [[AGG2]], %top ]
define { i32, ptr } @aggregate(ptr %ct) {
top:
  %rb = call {i32, ptr} @julia.except_enter(ptr %ct)
  %r0 = extractvalue {i32, ptr} %rb, 0
  %r = icmp eq i32 %r0, 0
  br i1 %r, label %try, label %catch
try:
  %lcssa = phi {i32, ptr} [ %rb, %top ]
  call void @ijl_pop_handler(ptr %ct, i32 1)
  ret { i32, ptr } %lcssa
catch:
  call void @ijl_pop_handler(ptr %ct, i32 1)
  ret { i32, ptr } zeroinitializer
}

; one buffer per nesting level; leaving two levels at once ends both lifetimes, the
; outer one first
; CHECK-LABEL: @nested(
; CHECK-NEXT: top:
; CHECK-NEXT: [[OUTER:%.*]] = alloca i8, i32 264, align 16
; CHECK-NEXT: [[INNER:%.*]] = alloca i8, i32 264, align 16
; CHECK-NEXT: call void @llvm.lifetime.start.p0({{(i64 264, )?}}ptr [[OUTER]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[OUTER]])
; CHECK: try1:
; CHECK-NEXT: call void @llvm.lifetime.start.p0({{(i64 264, )?}}ptr [[INNER]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[INNER]])
; CHECK: try2:
; CHECK-NEXT: call void @g()
; CHECK-NEXT: call void @ijl_pop_handler_noexcept(ptr %ct, i32 2)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 264, )?}}ptr [[OUTER]])
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 264, )?}}ptr [[INNER]])
; CHECK-NEXT: ret void
; CHECK: catch2:
; CHECK-NEXT: call void @ijl_pop_handler(ptr %ct, i32 1)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 264, )?}}ptr [[INNER]])
; CHECK: catch1:
; CHECK-NEXT: call void @ijl_pop_handler(ptr %ct, i32 1)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 264, )?}}ptr [[OUTER]])
define void @nested(ptr %ct) {
top:
  %rb1 = call {i32, ptr} @julia.except_enter(ptr %ct)
  %r1 = extractvalue {i32, ptr} %rb1, 0
  %c1 = icmp eq i32 %r1, 0
  br i1 %c1, label %try1, label %catch1
try1:
  %rb2 = call {i32, ptr} @julia.except_enter(ptr %ct)
  %r2 = extractvalue {i32, ptr} %rb2, 0
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

; a handler in a loop reuses its buffer in every iteration, and a handler that is left
; on several paths ends its lifetime on each
; CHECK-LABEL: @loop(
; CHECK-NEXT: top:
; CHECK-NEXT: [[BUF:%.*]] = alloca i8, i32 264, align 16
; CHECK-NOT: alloca
; CHECK: body:
; CHECK: call void @llvm.lifetime.start.p0({{(i64 264, )?}}ptr [[BUF]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[BUF]])
; CHECK: try:
; CHECK-NEXT: call void @g()
; CHECK-NEXT: call void @ijl_pop_handler_noexcept(ptr %ct, i32 1)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 264, )?}}ptr [[BUF]])
; CHECK: catch:
; CHECK-NEXT: call void @ijl_pop_handler(ptr %ct, i32 1)
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 264, )?}}ptr [[BUF]])
define void @loop(ptr %ct, i64 %n) {
top:
  br label %body
body:
  %i = phi i64 [ 0, %top ], [ %next, %latch ]
  %rb = call {i32, ptr} @julia.except_enter(ptr %ct)
  %r = extractvalue {i32, ptr} %rb, 0
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

; the new calls take the debug location of julia.except_enter
; CHECK-LABEL: @debuginfo(
; CHECK: call void @ijl_enter_handler(ptr %ct, ptr [[BUF:%[0-9]+]]), !dbg [[LOC:![0-9]+]]
; CHECK-NEXT: call i32 @{{.*}}setjmp(ptr [[BUF]]{{.*}}) [[RT]], !dbg [[LOC]]
define void @debuginfo(ptr %ct) !dbg !5 {
top:
  %rb = call {i32, ptr} @julia.except_enter(ptr %ct), !dbg !8
  call void @ijl_pop_handler(ptr %ct, i32 1)
  ret void
}

; functions without handlers are left alone
; CHECK-LABEL: @nohandlers(
; CHECK-NEXT: call void @g()
; CHECK-NEXT: ret void
define void @nohandlers() {
  call void @g()
  ret void
}

; CHECK: declare void @ijl_enter_handler(ptr, ptr)
; UNIX: declare i32 @__sigsetjmp(ptr, i32) [[RT]]
; WINDOWS: declare i32 @jl_setjmp(ptr) [[RT]]
; CHECK: attributes [[RT]] = { returns_twice }

!llvm.module.flags = !{!0}
!llvm.dbg.cu = !{!1}
!0 = !{i32 2, !"Debug Info Version", i32 3}
!1 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !2, producer: "julia", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!2 = !DIFile(filename: "test.jl", directory: ".")
!3 = !DISubroutineType(types: !4)
!4 = !{}
!5 = distinct !DISubprogram(name: "debuginfo", scope: null, file: !2, line: 1, type: !3, spFlags: DISPFlagDefinition, unit: !1)
!8 = !DILocation(line: 2, scope: !5)
