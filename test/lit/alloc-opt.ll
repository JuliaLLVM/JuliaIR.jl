; What AllocOpt does with allocations, depending on how they are used.

; The checks expect the stack memory layout of Julia 1.12 and later (alloc-opt-dialects.ll
; has the older ones).
; RUN: %if julia-1.14 %{ opt -passes='function(jl-alloc-opt)' -S %s | FileCheck %s --check-prefixes=CHECK,MASTER %}
; RUN: %if julia-1.12 || julia-1.13 %{ opt -passes='function(jl-alloc-opt)' -S %s | FileCheck %s --check-prefixes=CHECK,V113 %}
; RUN: %if julia-1.12 || julia-1.13 %{ opt -passes='function(AllocOpt)' -S %s | FileCheck %s --check-prefixes=CHECK,V113 %}

; the port ran, also under Julia's name, in every function but the optnone one
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes='function(AllocOpt)' -S %s -o /dev/null
; RUN: FileCheck %s --check-prefix=LEDGER < %t.ledger
; LEDGER-COUNT-11: pass jl-alloc-opt julia=
; LEDGER-NOT: pass

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"

@tag = external addrspace(10) global {}

declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare ptr addrspace(10) @julia.typeof(ptr addrspace(10))
declare void @julia.write_barrier(ptr addrspace(10), ...)
declare void @julia.object_write_barrier(ptr addrspace(10), ...)
declare void @julia.field_write_barrier.p11(ptr addrspace(10), ...)
declare token @llvm.julia.gc_preserve_begin(...)
declare void @llvm.julia.gc_preserve_end(token)
declare void @external(ptr addrspace(10))
declare void @ccall_roots()
declare void @error() noreturn
declare void @llvm.memcpy.p0.p11.i64(ptr, ptr addrspace(11), i64, i1)

; dead: only stored to
; CHECK-LABEL: @dead(
; CHECK-NOT: alloca
; CHECK-NOT: @julia.gc_alloc_obj
; CHECK-NOT: store
; CHECK: ret void
define void @dead(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  ret void
}

; escapes into a call, but its type tag is forwarded
; CHECK-LABEL: @escape_typeof(
; CHECK: %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj
; CHECK: call void @external(ptr addrspace(10) %v)
; CHECK-NOT: @julia.typeof
; CHECK: ret ptr addrspace(10) @tag
define ptr addrspace(10) @escape_typeof() {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  call void @external(ptr addrspace(10) %v)
  %t = call ptr addrspace(10) @julia.typeof(ptr addrspace(10) %v)
  ret ptr addrspace(10) %t
}

; escapes through a phi
; CHECK-LABEL: @escape_phi(
; CHECK: %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj
; CHECK: phi ptr addrspace(10) [ %v, %top ], [ %w, %a ]
define i64 @escape_phi(i1 %c, ptr addrspace(10) %w) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  br i1 %c, label %a, label %b
a:
  br label %b
b:
  %p = phi ptr addrspace(10) [ %v, %top ], [ %w, %a ]
  %d = addrspacecast ptr addrspace(10) %p to ptr addrspace(11)
  %l = load i64, ptr addrspace(11) %d, align 8
  ret i64 %l
}

; its address is stored
; CHECK-LABEL: @escape_store(
; CHECK: %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj
; CHECK: store ptr addrspace(10) %v, ptr addrspace(11) %slot
define void @escape_store(ptr addrspace(11) %slot) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  store ptr addrspace(10) %v, ptr addrspace(11) %slot, align 8
  ret void
}

; only used on an error path: left alone
; CHECK-LABEL: @error_path(
; CHECK: %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj
; CHECK: call void @external(ptr addrspace(10) %v)
define void @error_path(i1 %c) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  br i1 %c, label %err, label %ok
err:
  call void @external(ptr addrspace(10) %v)
  unreachable
ok:
  ret void
}

; a field written as i64 and read as i32 at an offset: one field, read and written as bytes
; CHECK-LABEL: @overlapping(
; CHECK: [[SLOT:%.*]] = alloca i64, align 16
; CHECK: store i64 %x, ptr [[SLOT]], align 8
; CHECK: [[F:%.*]] = getelementptr inbounds i32, ptr [[SLOT]], i32 1
; CHECK: [[L:%.*]] = load i32, ptr [[F]], align 4
; CHECK: ret i32 [[L]]
define i32 @overlapping(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %f = getelementptr inbounds i8, ptr addrspace(11) %d, i64 4
  %l = load i32, ptr addrspace(11) %f, align 4
  ret i32 %l
}

; atomics on a field that is split off are lowered to plain loads and stores
; CHECK-LABEL: @atomic_field(
; CHECK: [[SLOT:%.*]] = alloca i64, align 16
; CHECK-NOT: atomic
; CHECK: store i64 %x, ptr [[SLOT]], align 8
; CHECK: [[OLD:%.*]] = load i64, ptr [[SLOT]], align 8
; CHECK: [[NEW:%.*]] = add i64 [[OLD]], 1
; CHECK: store i64 [[NEW]], ptr [[SLOT]], align 8
; CHECK: load i64, ptr [[SLOT]], align 8
; CHECK-NOT: atomic
; CHECK: ret i64
define i64 @atomic_field(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store atomic i64 %x, ptr addrspace(11) %d release, align 8
  %old = atomicrmw add ptr addrspace(11) %d, i64 1 seq_cst, align 8
  %l = load atomic i64, ptr addrspace(11) %d acquire, align 8
  %r = add i64 %old, %l
  ret i64 %r
}

; a reference field, preserved: the preserve and the ccall roots refer to the field, whose
; slot is promoted to a register
; CHECK-LABEL: @preserved_ref(
; CHECK-NOT: alloca
; CHECK: call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %w)
; CHECK: call void @ccall_roots() [ "jl_roots"(ptr addrspace(10) %w) ]
define void @preserved_ref(ptr addrspace(10) %w) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store ptr addrspace(10) %w, ptr addrspace(11) %d, align 8
  %tok = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %v)
  call void @ccall_roots() [ "jl_roots"(ptr addrspace(10) %v) ]
  call void @llvm.julia.gc_preserve_end(token %tok)
  ret void
}

; write barriers: on the object itself it is removed; as one of several children, only that
; child is (the others still need the barrier)
; CHECK-LABEL: @barriers(
; from 1.14 on, julia.write_barrier is not a barrier anymore, but an unknown call
; MASTER: %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj
; MASTER: call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %v, ptr addrspace(10) %w)
; Julia 1.13 removes the barrier altogether, also for the other child (adopted fix from 1.14)
; V113-NOT: @julia.gc_alloc_obj
; V113-NOT: @julia.write_barrier(ptr addrspace(10) %v
; V113: call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) null, ptr addrspace(10) %other)
define void @barriers(ptr addrspace(10) %parent, ptr addrspace(10) %other, ptr addrspace(10) %w) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store ptr addrspace(10) %w, ptr addrspace(11) %d, align 8
  call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %v, ptr addrspace(10) %w)
  call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %v, ptr addrspace(10) %other)
  ret void
}

; the same with the barriers of Julia 1.14 and later
; CHECK-LABEL: @barriers_master(
; MASTER-NOT: @julia.gc_alloc_obj
; MASTER-NOT: @julia.field_write_barrier
; MASTER: call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) null)
; MASTER-NEXT: ret void
; before 1.14, these are unknown calls
; V113: call noalias ptr addrspace(10) @julia.gc_alloc_obj
define void @barriers_master(ptr addrspace(10) %parent, ptr addrspace(11) %slot, ptr addrspace(10) %w) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store ptr addrspace(10) %w, ptr addrspace(11) %d, align 8
  call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %v, ptr addrspace(10) %w)
  call void (ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %v, ptr addrspace(11) %d, ptr addrspace(10) %w)
  call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %v)
  ret void
}

; not optimized in functions that are not optimized
; CHECK-LABEL: @optnone(
; CHECK: %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj
define i64 @optnone(i64 %x) noinline optnone {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %l = load i64, ptr addrspace(11) %d, align 8
  ret i64 %l
}

; intrinsics that use the object are redeclared for the stack's address space; like Julia's
; pass, their parameter attributes are dropped
; CHECK-LABEL: @memcpy_out(
; CHECK: %v = alloca [2 x i64], align 16
; CHECK: call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %v, i64 16, i1 false)
define void @memcpy_out(ptr %dst, i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 16, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  call void @llvm.memcpy.p0.p11.i64(ptr align 8 %dst, ptr addrspace(11) align 8 %d, i64 16, i1 false)
  ret void
}
