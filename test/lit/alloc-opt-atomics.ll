; AllocOpt on allocations accessed with atomicrmw and cmpxchg, as since Julia 1.13 for
; every version: their field counts as read and written (JuliaLang/julia#62752; before,
; the C++ pass gave a field accessed only by them no stack slot and crashed), the atomics
; moved to the slots of a split allocation are lowered to plain loads and stores (#61131;
; before, they stayed atomic), and storing the allocation's address with one is an
; escape (#61131).

; RUN: opt -passes='function(jl-alloc-opt)' -S %s | FileCheck %s

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"

@tag = external addrspace(10) global {}

declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))

; CHECK-LABEL: @rmw_alone(
; CHECK: [[SLOT:%.*]] = alloca i64
; CHECK-NOT: @julia.gc_alloc_obj
; CHECK-NOT: atomicrmw
; CHECK: [[OLD:%.*]] = load i64, ptr [[SLOT]], align 8
; CHECK: %new = add i64 [[OLD]], %x
; CHECK: store i64 %new, ptr [[SLOT]], align 8
; CHECK: ret i64 [[OLD]]
define i64 @rmw_alone(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  %old = atomicrmw add ptr addrspace(11) %d, i64 %x seq_cst, align 8
  ret i64 %old
}

; CHECK-LABEL: @cmpxchg_alone(
; CHECK: [[SLOT:%.*]] = alloca i64
; CHECK-NOT: @julia.gc_alloc_obj
; CHECK-NOT: cmpxchg
; CHECK: [[OLD:%.*]] = load i64, ptr [[SLOT]], align 8
; CHECK: icmp eq i64 [[OLD]], 0
; CHECK: store i64 {{.*}}, ptr [[SLOT]], align 8
; CHECK: ret i64
define i64 @cmpxchg_alone(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  %pair = cmpxchg ptr addrspace(11) %d, i64 0, i64 %x seq_cst monotonic, align 8
  %old = extractvalue { i64, i1 } %pair, 0
  ret i64 %old
}

; the allocation's address is stored elsewhere: it escapes
; CHECK-LABEL: @rmw_publish(
; CHECK: %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj
; CHECK: atomicrmw xchg ptr addrspace(11) %slot, ptr addrspace(10) %v seq_cst, align 8
define void @rmw_publish(ptr addrspace(11) %slot) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %old = atomicrmw xchg ptr addrspace(11) %slot, ptr addrspace(10) %v seq_cst, align 8
  ret void
}

; CHECK-LABEL: @cmpxchg_publish(
; CHECK: %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj
; CHECK: cmpxchg ptr addrspace(11) %slot, ptr addrspace(10) null, ptr addrspace(10) %v seq_cst monotonic, align 8
define void @cmpxchg_publish(ptr addrspace(11) %slot) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %pair = cmpxchg ptr addrspace(11) %slot, ptr addrspace(10) null, ptr addrspace(10) %v seq_cst monotonic, align 8
  ret void
}
