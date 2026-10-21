; JuliaLICM hoists an allocation with volatile accesses like any other: hoisting doesn't
; change how many volatile accesses run. (AllocOpt keeps such allocations, see
; alloc-opt-volatile.ll; both share the escape analysis.)

; RUN: opt -passes=JuliaLICM -S %s | FileCheck %s

@tag = external addrspace(10) global {}, align 16

declare ptr @julia.get_pgcstack()
declare noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10)) allocsize(1)
declare void @use(ptr addrspace(10))

; CHECK-LABEL: @alloc_volatile(
; CHECK: top:
; CHECK: %obj = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj
; CHECK: loop:
; CHECK-NEXT: %i = phi i64
; CHECK-NEXT: store volatile i64 %i, ptr addrspace(10) %obj
define void @alloc_volatile(i1 %c) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  br label %loop
loop:
  %i = phi i64 [ 0, %top ], [ %next, %loop ]
  %obj = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  store volatile i64 %i, ptr addrspace(10) %obj
  %next = add i64 %i, 1
  br i1 %c, label %exit, label %loop
exit:
  %last = phi ptr addrspace(10) [ %obj, %loop ]
  call void @use(ptr addrspace(10) %last)
  ret void
}
