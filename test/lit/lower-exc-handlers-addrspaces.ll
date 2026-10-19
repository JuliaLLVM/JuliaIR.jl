; LowerExcHandlers on a target whose allocas live in another address space (AMDGPU's 5):
; the handler buffer is cast to a generic pointer for the runtime. Julia's pass marks the
; lifetime of that cast; LLVM 22 and later only accept lifetime markers on the alloca
; itself (and upgrade the C++ pass's output to that), so the port marks the alloca there.

; REQUIRES: julia-ge-1.12
; RUN: %if julia-1.12 && !llvm-ge-22 %{ opt -passes='function(jl-lower-exc-handlers<handler-size=264;handler-align=16;setjmp=__sigsetjmp>)' -S %s | FileCheck %s --check-prefixes=CHECK,CAST %}
; RUN: %if julia-1.12 && llvm-ge-22 %{ opt -passes='function(jl-lower-exc-handlers<handler-size=264;handler-align=16;setjmp=__sigsetjmp>)' -S %s | FileCheck %s --check-prefixes=CHECK,ALLOCA %}
; RUN: %if julia-ge-1.13 %{ opt -passes='function(jl-lower-exc-handlers)' -S %s | FileCheck %s --check-prefix=NOOP %}
; NOOP-NOT: alloca

target triple = "amdgcn-amd-amdhsa"
target datalayout = "e-p:64:64-p1:64:64-p2:32:32-p3:32:32-p4:64:64-p5:32:32-p6:32:32-i64:64-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-v512:512-v1024:1024-v2048:2048-n32:64-S32-A5-G1-ni:7-ni:10:11:12:13"

declare {i32, ptr} @julia.except_enter(ptr) returns_twice
declare void @ijl_pop_handler(ptr, i32)
declare void @use(ptr)

; CHECK-LABEL: @simple(
; CHECK-NEXT: top:
; CHECK-NEXT: [[ALLOCA:%.*]] = alloca i8, i32 264, align 16, addrspace(5)
; CHECK-NEXT: [[BUF:%.*]] = addrspacecast ptr addrspace(5) [[ALLOCA]] to ptr
; CAST-NEXT: call void @llvm.lifetime.start.p0({{(i64 264, )?}}ptr [[BUF]])
; ALLOCA-NEXT: call void @llvm.lifetime.start.p5(ptr addrspace(5) [[ALLOCA]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[BUF]])
; CHECK-NEXT: [[SJ:%.*]] = call i32 @__sigsetjmp(ptr [[BUF]], i32 0)
; CHECK: try:
; CHECK-NEXT: call void @use(ptr [[BUF]])
; CHECK: after:
; CHECK-NEXT: call void @ijl_pop_handler(ptr %ct, i32 1)
; CAST-NEXT: call void @llvm.lifetime.end.p0({{(i64 264, )?}}ptr [[BUF]])
; ALLOCA-NEXT: call void @llvm.lifetime.end.p5(ptr addrspace(5) [[ALLOCA]])
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

; nested handlers have a buffer each, and leaving both ends both lifetimes
; CHECK-LABEL: @nested(
; CHECK-NEXT: top:
; CHECK-NEXT: [[ALLOCA0:%.*]] = alloca i8, i32 264, align 16, addrspace(5)
; CHECK-NEXT: [[BUF0:%.*]] = addrspacecast ptr addrspace(5) [[ALLOCA0]] to ptr
; CHECK-NEXT: [[ALLOCA1:%.*]] = alloca i8, i32 264, align 16, addrspace(5)
; CHECK-NEXT: [[BUF1:%.*]] = addrspacecast ptr addrspace(5) [[ALLOCA1]] to ptr
; CAST-NEXT: call void @llvm.lifetime.start.p0({{(i64 264, )?}}ptr [[BUF0]])
; ALLOCA-NEXT: call void @llvm.lifetime.start.p5(ptr addrspace(5) [[ALLOCA0]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[BUF0]])
; CHECK: inner:
; CAST-NEXT: call void @llvm.lifetime.start.p0({{(i64 264, )?}}ptr [[BUF1]])
; ALLOCA-NEXT: call void @llvm.lifetime.start.p5(ptr addrspace(5) [[ALLOCA1]])
; CHECK-NEXT: call void @ijl_enter_handler(ptr %ct, ptr [[BUF1]])
; CHECK: after:
; CHECK-NEXT: call void @ijl_pop_handler(ptr %ct, i32 2)
; CAST-NEXT: call void @llvm.lifetime.end.p0({{(i64 264, )?}}ptr [[BUF0]])
; CAST-NEXT: call void @llvm.lifetime.end.p0({{(i64 264, )?}}ptr [[BUF1]])
; ALLOCA-NEXT: call void @llvm.lifetime.end.p5(ptr addrspace(5) [[ALLOCA0]])
; ALLOCA-NEXT: call void @llvm.lifetime.end.p5(ptr addrspace(5) [[ALLOCA1]])
; CHECK-NEXT: ret void
define void @nested(ptr %ct) {
top:
  %rb0 = call {i32, ptr} @julia.except_enter(ptr %ct)
  br label %inner
inner:
  %rb1 = call {i32, ptr} @julia.except_enter(ptr %ct)
  br label %after
after:
  call void @ijl_pop_handler(ptr %ct, i32 2)
  ret void
}
