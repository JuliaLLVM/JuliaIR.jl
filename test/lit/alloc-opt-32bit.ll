; AllocOpt on IR for a 32-bit target, processed by any Julia: a reference field is a
; pointer of the data layout's size (4 bytes here), not of the host's, so an allocation of
; two references is split into two reference slots (which are then promoted to
; registers) rather than kept on the stack as an array of references.

; RUN: opt -julia=1.12 -passes='function(jl-alloc-opt)' -S %s | FileCheck %s
; RUN: opt -julia=1.10 -passes='function(jl-alloc-opt)' -S %s | FileCheck %s

target datalayout = "e-m:e-p:32:32-p270:32:32-p271:32:32-p272:64:64-i128:128-f64:32:64-f80:32-n8:16:32-S128-ni:10:11:12:13"
target triple = "i686-unknown-linux-gnu"

@tag = external addrspace(10) global {}

declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i32, ptr addrspace(10))
declare token @llvm.julia.gc_preserve_begin(...)
declare void @llvm.julia.gc_preserve_end(token)
declare void @ccall_roots()

; CHECK-LABEL: @two_refs(
; CHECK-NOT: alloca
; CHECK-NOT: @julia.gc_alloc_obj
; CHECK: call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %a, ptr addrspace(10) %b)
; CHECK: call void @ccall_roots() [ "jl_roots"(ptr addrspace(10) %a, ptr addrspace(10) %b) ]
; CHECK: ret ptr addrspace(10) %b
define ptr addrspace(10) @two_refs(ptr addrspace(10) %a, ptr addrspace(10) %b) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i32 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store ptr addrspace(10) %a, ptr addrspace(11) %d, align 4
  %f = getelementptr inbounds i8, ptr addrspace(11) %d, i32 4
  store ptr addrspace(10) %b, ptr addrspace(11) %f, align 4
  %tok = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %v)
  call void @ccall_roots() [ "jl_roots"(ptr addrspace(10) %v) ]
  call void @llvm.julia.gc_preserve_end(token %tok)
  %r = load ptr addrspace(10), ptr addrspace(11) %f, align 4
  ret ptr addrspace(10) %r
}
