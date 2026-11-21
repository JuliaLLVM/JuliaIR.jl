; Where AllocOpt ends the lifetime of an allocation that it moves to the stack, when
; `gc_preserve_begin` keeps the allocation alive: the blocks dominated by the begin, up to a
; block dominated by an end, have invisible uses of it, found by walking the dominator tree
; from the begin. The lifetime markers lost their size argument in LLVM 22.

; RUN: opt -passes='function(jl-alloc-opt)' -S %s | FileCheck %s

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"

@tag = external addrspace(10) global {}

declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare ptr @julia.pointer_from_objref(ptr addrspace(11))
declare token @llvm.julia.gc_preserve_begin(...)
declare void @llvm.julia.gc_preserve_end(token)
declare void @external(ptr)
declare void @safepoint()

; %exit is two levels below the begin in the dominator tree, and doesn't reach the end: the
; allocation stays live there
; CHECK-LABEL: @nested(
; CHECK: L2:
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 8, )?}}ptr %v)
; CHECK-NEXT: call void @safepoint()
; CHECK: exit:
; CHECK-NOT: @llvm.lifetime.end
; CHECK: unreachable
define void @nested(i64 %x, i1 %cond) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %p = call ptr @julia.pointer_from_objref(ptr addrspace(11) %d)
  call void @external(ptr %p)
  %tok = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %v)
  br label %L1
L1:
  br i1 %cond, label %L2, label %exit
L2:
  call void @llvm.julia.gc_preserve_end(token %tok)
  call void @safepoint()
  ret void
exit:
  call void @safepoint()
  unreachable
}

; Two preserves of the same allocation in one block. Like the C++, the walk from a preserve
; stops at the blocks that the walk from another one marked already: %tok1 comes first in
; the allocation's use list, and its walk marks %top, so the walk from %tok2 marks nothing.
; %exit, which only %tok2 reaches without an end, then has no invisible uses, and the
; lifetime ends there.
; CHECK-LABEL: @two_preserves(
; CHECK: L2:
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 8, )?}}ptr %v)
; CHECK-NEXT: call void @safepoint()
; CHECK: exit:
; CHECK-NEXT: call void @llvm.lifetime.end.p0({{(i64 8, )?}}ptr %v)
; CHECK-NEXT: call void @safepoint()
define void @two_preserves(i64 %x, i1 %cond) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %p = call ptr @julia.pointer_from_objref(ptr addrspace(11) %d)
  call void @external(ptr %p)
  %tok2 = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %v)
  %tok1 = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %v)
  br label %L1
L1:
  call void @llvm.julia.gc_preserve_end(token %tok1)
  br i1 %cond, label %L2, label %exit
L2:
  call void @llvm.julia.gc_preserve_end(token %tok2)
  call void @safepoint()
  ret void
exit:
  call void @safepoint()
  unreachable
}
