; AllocOpt keeps an allocation whose references are accessed as an array or a vector:
; it can neither split it nor move it to the stack.

; RUN: opt -passes='function(jl-alloc-opt)' -S %s | FileCheck %s

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"

@tag = external addrspace(10) global {}

declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare void @external(ptr addrspace(10))

; CHECK-LABEL: @store_array(
; CHECK: %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj
; CHECK: store [2 x ptr addrspace(10)] %a, ptr addrspace(11) %d
; CHECK: load ptr addrspace(10), ptr addrspace(11) %p
define ptr addrspace(10) @store_array([2 x ptr addrspace(10)] %a) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 16, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store [2 x ptr addrspace(10)] %a, ptr addrspace(11) %d, align 8
  call void @external(ptr addrspace(10) null)
  %p = getelementptr inbounds i8, ptr addrspace(11) %d, i64 8
  %l = load ptr addrspace(10), ptr addrspace(11) %p, align 8
  ret ptr addrspace(10) %l
}

; CHECK-LABEL: @store_vector(
; CHECK: %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj
; CHECK: store <2 x ptr addrspace(10)> %a, ptr addrspace(11) %d
define ptr addrspace(10) @store_vector(<2 x ptr addrspace(10)> %a) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 16, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store <2 x ptr addrspace(10)> %a, ptr addrspace(11) %d, align 16
  call void @external(ptr addrspace(10) null)
  %l = load ptr addrspace(10), ptr addrspace(11) %d, align 8
  ret ptr addrspace(10) %l
}

; an array without references goes to the stack
; CHECK-LABEL: @store_array_bits(
; CHECK-NOT: @julia.gc_alloc_obj
; CHECK: store [2 x i64] %a, ptr %
; CHECK: ret i64
define i64 @store_array_bits([2 x i64] %a) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 16, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store [2 x i64] %a, ptr addrspace(11) %d, align 8
  call void @external(ptr addrspace(10) null)
  %l = load i64, ptr addrspace(11) %d, align 8
  ret i64 %l
}
