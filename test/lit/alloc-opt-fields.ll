; How AllocOpt's escape analysis divides an allocation into fields, as since Julia 1.13
; for every version. Before, an access was merged with a field below it that it didn't
; overlap (JuliaLang/julia#62166), and the first access of a reference field marked it as
; mixing references and bits (#61131), so that allocations with references were neither
; split nor moved to the stack.

; RUN: opt -passes='function(jl-alloc-opt)' -S %s | FileCheck %s

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"

@tag = external addrspace(10) global {}

declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare token @llvm.julia.gc_preserve_begin(...)
declare void @llvm.julia.gc_preserve_end(token)
declare void @external()

; a box with a reference, preserved: removed
; CHECK-LABEL: @preserve_ref(
; CHECK-NOT: @julia.gc_alloc_obj
; CHECK: call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %x)
; CHECK: ret ptr addrspace(10) %x
define ptr addrspace(10) @preserve_ref(ptr addrspace(10) %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store ptr addrspace(10) %x, ptr addrspace(11) %d, align 8
  %t = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %v)
  call void @external()
  %l = load ptr addrspace(10), ptr addrspace(11) %d, align 8
  call void @llvm.julia.gc_preserve_end(token %t)
  ret ptr addrspace(10) %l
}

; two adjacent fields of bits, accessed in increasing order: one slot per field
; CHECK-LABEL: @adjacent_bits(
; CHECK: alloca
; CHECK: alloca
; CHECK-NOT: alloca
; CHECK-NOT: @julia.gc_alloc_obj
; CHECK: ret i64
define i64 @adjacent_bits(i64 %a, i64 %b) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 16, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %a, ptr addrspace(11) %d, align 8
  %p = getelementptr inbounds i8, ptr addrspace(11) %d, i64 8
  store i64 %b, ptr addrspace(11) %p, align 8
  %t = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %v)
  call void @external()
  %l0 = load i64, ptr addrspace(11) %d, align 8
  %l = load i64, ptr addrspace(11) %p, align 8
  call void @llvm.julia.gc_preserve_end(token %t)
  %s = add i64 %l0, %l
  ret i64 %s
}

; bits, then a reference above them (#62166's example): split
; CHECK-LABEL: @bits_then_ref(
; CHECK-NOT: @julia.gc_alloc_obj
; CHECK: store i64 %a, ptr %
; CHECK: ret i64
define i64 @bits_then_ref(i64 %a, ptr addrspace(10) %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 16, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %a, ptr addrspace(11) %d, align 8
  %p = getelementptr inbounds i8, ptr addrspace(11) %d, i64 8
  store ptr addrspace(10) %x, ptr addrspace(11) %p, align 8
  call void @external()
  %l = load i64, ptr addrspace(11) %d, align 8
  ret i64 %l
}
