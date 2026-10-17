; How AllocOpt lays out and initializes the stack memory that replaces an allocation,
; which changed between Julia versions (see `alloc_layout` and `alloc_initialization`).
; The lifetime markers lost their size argument in LLVM 22.

; RUN: opt -julia=1.10 -passes='function(jl-alloc-opt)' -S %s | FileCheck %s --check-prefixes=CHECK,V110,LEGACY
; RUN: opt -julia=1.11 -passes='function(jl-alloc-opt)' -S %s | FileCheck %s --check-prefixes=CHECK,V111,LEGACY
; RUN: opt -julia=1.12 -passes='function(jl-alloc-opt)' -S %s | FileCheck %s --check-prefixes=CHECK,V112,CHUNKED
; RUN: opt -julia=1.14.0-DEV -passes='function(jl-alloc-opt)' -S %s | FileCheck %s --check-prefixes=CHECK,V112,CHUNKED

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"

@tag = external addrspace(10) global {}

declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare ptr @julia.pointer_from_objref(ptr addrspace(11))
declare ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10), ptr)
declare void @external(ptr)

; moved to the stack (its address escapes into a call through pointer_from_objref)
; CHECK-LABEL: @move(
; LEGACY: %v = alloca [12 x i8], align 16
; CHUNKED: %v = alloca [2 x i64], align 16
; CHECK: call void @llvm.lifetime.start.p0({{(i64 12, )?}}ptr %v)
; V110-NOT: store [12 x i8]
; V111-NEXT: store [12 x i8] zeroinitializer, ptr %v, align 1
; V112-NEXT: call void @llvm.memset.p0.i64(ptr align 16 %v, i8 0, i64 16, i1 false)
; CHECK: store i64 %x, ptr %v, align 8
; CHECK: call void @external(ptr %v)
; CHECK-NOT: @julia.gc_alloc_obj
; CHECK: ret i64
define i64 @move(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 12, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %p = call ptr @julia.pointer_from_objref(ptr addrspace(11) %d)
  call void @external(ptr %p)
  %l = load i64, ptr addrspace(11) %d, align 8
  ret i64 %l
}

; with call-site attributes (Julia 1.11 and later): zeroed, aligned to 32
; CHECK-LABEL: @move_zeroed(
; LEGACY: %v = alloca [24 x i8], align 16
; CHUNKED: %v = alloca [3 x i64], align 32
; V111: store [24 x i8] zeroinitializer, ptr %v, align 1
; V112: call void @llvm.memset.p0.i64(ptr align 32 %v, i8 0, i64 24, i1 false)
; CHECK: ret i64
define i64 @move_zeroed(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias align 32 ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 24, ptr addrspace(10) @tag) #0
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %p = call ptr @julia.pointer_from_objref(ptr addrspace(11) %d)
  call void @external(ptr %p)
  %l = load i64, ptr addrspace(11) %d, align 8
  ret i64 %l
}

; uninitialized: no initialization
; CHECK-LABEL: @move_uninitialized(
; CHECK: %v = alloca i64, align 16
; CHECK-NOT: store i64 0
; CHECK-NOT: memset
; CHECK: store i64 %x, ptr %v, align 8
define i64 @move_uninitialized(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag) #1
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %p = call ptr @julia.pointer_from_objref(ptr addrspace(11) %d)
  call void @external(ptr %p)
  %l = load i64, ptr addrspace(11) %d, align 8
  ret i64 %l
}

; split into its fields
; CHECK-LABEL: @split(
; LEGACY: [[A:%.*]] = alloca i64, align 8
; LEGACY: [[B:%.*]] = alloca i32, align 4
; CHUNKED: [[A:%.*]] = alloca i64, align 16
; CHUNKED: [[B:%.*]] = alloca i32, align 16
; V111: store i64 0, ptr [[A]], align 8
; V111: store i32 0, ptr [[B]], align 4
; V112: call void @llvm.memset.p0.i64(ptr align 16 [[A]], i8 0, i64 8, i1 false)
; V112: call void @llvm.memset.p0.i64(ptr align 16 [[B]], i8 0, i64 4, i1 false)
; CHECK: store i64 %x, ptr [[A]], align 8
; CHECK: store i32 %y, ptr [[B]], align 4
; CHECK: load i64, ptr [[A]], align 8
; CHECK: load i32, ptr [[B]], align 4
define i64 @split(i64 %x, i32 %y) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 16, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %f = getelementptr inbounds i8, ptr addrspace(11) %d, i64 8
  store i32 %y, ptr addrspace(11) %f, align 4
  %l = load i64, ptr addrspace(11) %d, align 8
  %m = load i32, ptr addrspace(11) %f, align 4
  %e = zext i32 %m to i64
  %r = add i64 %l, %e
  ret i64 %r
}

; julia.gc_loaded: handled since 1.12, and with the port also for 1.11's IR
; CHECK-LABEL: @gc_loaded(
; Julia 1.10 has no julia.gc_loaded: an unknown call
; V110: call noalias ptr addrspace(10) @julia.gc_alloc_obj
; V110: call ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10) %v, ptr %p)
; V111: %v = alloca i64, align 16
; V111: call ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10) null, ptr %v)
; V112: %v = alloca i64, align 16
; V112: call ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10) null, ptr %v)
define i64 @gc_loaded(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %p = call ptr @julia.pointer_from_objref(ptr addrspace(11) %d)
  %ld = call ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10) %v, ptr %p)
  %l = load i64, ptr addrspace(13) %ld, align 8
  ret i64 %l
}

attributes #0 = { allockind("alloc,zeroed") }
attributes #1 = { allockind("alloc,uninitialized") }
