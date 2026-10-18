; JuliaLICM clears a hoisted allocation assuming the alignment of a pointer in address
; space 0 of the module's data layout: 4 bytes on 32-bit targets.

; RUN: opt -passes=JuliaLICM -S %s | FileCheck %s

target datalayout = "e-m:e-p:32:32-p270:32:32-p271:32:32-p272:64:64-i128:128-f80:32-n8:16:32-a:0:32-S32-ni:10:11:12:13"

@tag = external addrspace(10) global {}, align 16

declare ptr @julia.get_pgcstack()
declare noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr, i32, ptr addrspace(10)) allocsize(1)

; CHECK-LABEL: @alloc(
; CHECK: top:
; CHECK: %obj = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i32 8, ptr addrspace(10) @tag)
; CHECK-NEXT: call void @llvm.memset.p10.i32(ptr addrspace(10) align 4 %obj, i8 0, i32 8, i1 false)
; CHECK-NEXT: br label %loop
define void @alloc(i1 %c) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  br label %loop
loop:
  %obj = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i32 8, ptr addrspace(10) @tag)
  store i32 1, ptr addrspace(10) %obj
  br i1 %c, label %exit, label %loop
exit:
  ret void
}
