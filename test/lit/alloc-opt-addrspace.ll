; Stack memory is allocated in the alloca address space of the data layout. Julia 1.10 and
; 1.11's AllocOpt produced invalid IR here (a bitcast between address spaces); the port's
; IR is valid for every dialect.

; RUN: opt -julia=1.11 -passes='function(jl-alloc-opt)' -S %s | FileCheck %s --check-prefixes=CHECK,LEGACY
; RUN: opt -julia=1.12 -passes='function(jl-alloc-opt)' -S %s | FileCheck %s --check-prefixes=CHECK,CHUNKED
; RUN: opt -julia=1.12 -passes='function(jl-alloc-opt)' %s | llvm-dis | FileCheck %s --check-prefixes=CHECK,CHUNKED

target datalayout = "e-p:64:64-p1:64:64-p2:32:32-p3:32:32-p4:64:64-p5:32:32-p6:32:32-i64:64-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-v512:512-v1024:1024-v2048:2048-n32:64-S32-A5-G1-ni:7-ni:10:11:12:13"

@tag = external addrspace(10) global {}

declare ptr @julia.get_pgcstack()
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare ptr @julia.pointer_from_objref(ptr addrspace(11))
declare void @external(ptr)

; CHECK-LABEL: @move(
; CHECK: %v = alloca i64, align 16, addrspace(5)
; CHECK-NEXT: [[P:%.*]] = addrspacecast ptr addrspace(5) %v to ptr
; CHECK-NOT: bitcast
; CHECK: call void @llvm.lifetime.start.p5({{(i64 8, )?}}ptr addrspace(5) %v)
; LEGACY: store i64 0, ptr addrspace(5) %v, align 8
; CHUNKED: call void @llvm.memset.p5.i64(ptr addrspace(5) align 16 %v, i8 0, i64 8, i1 false)
; CHECK: store i64 %x, ptr addrspace(5) %v, align 8
; CHECK: call void @external(ptr [[P]])
define i64 @move(i64 %x) {
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %d = addrspacecast ptr addrspace(10) %v to ptr addrspace(11)
  store i64 %x, ptr addrspace(11) %d, align 8
  %p = call ptr @julia.pointer_from_objref(ptr addrspace(11) %d)
  call void @external(ptr %p)
  %l = load i64, ptr addrspace(11) %d, align 8
  ret i64 %l
}
