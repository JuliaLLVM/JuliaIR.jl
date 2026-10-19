; LateLowerGCFrame (jl-late-lower-gc-frame) on the IR of every Julia version: the
; behaviours that differ between versions. Upstream's fixtures (test/upstream) cover the
; rest at each version's pin.

; The runtime facts are given as pass options (x86-64 Linux's values), so that the output
; doesn't depend on the running Julia.
; RUN: split-file %s %t
; RUN: %if julia-1.10 %{ opt -passes='function(LateLowerGCFrame<task-gcstack=112;task-ptls=128;tls-safepoint=16;tls-gc-state=25>)' -S %t/lowering.ll | FileCheck %t/lowering.ll --check-prefixes=CHECK,V110 %}
; RUN: %if julia-1.11 %{ opt -passes='function(LateLowerGCFrame<task-gcstack=112;task-ptls=128;tls-safepoint=16;tls-gc-state=25>)' -S %t/lowering.ll | FileCheck %t/lowering.ll --check-prefixes=CHECK,V111 %}
; RUN: %if julia-1.12 %{ opt -passes='function(LateLowerGCFrame<task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25>)' -S %t/lowering.ll | FileCheck %t/lowering.ll --check-prefixes=CHECK,V112 %}
; RUN: %if julia-1.13 %{ opt -passes='function(LateLowerGCFrame<task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25>)' -S %t/lowering.ll | FileCheck %t/lowering.ll --check-prefixes=CHECK,V113 %}
; RUN: %if julia-1.14 %{ opt -passes='function(LateLowerGCFrame<task-gcstack=192;task-ptls=208;tls-safepoint=16;tls-gc-state=128>)' -S %t/lowering.ll | FileCheck %t/lowering.ll --check-prefixes=CHECK,V114 %}

; the facts serve any target: the running Julia's (like the C++ pass, which compiles in
; its own) and explicit ones (in bytes from Julia 1.12 on)
; RUN: opt -passes='function(LateLowerGCFrame)' -S %t/unknown-target.ll | FileCheck %t/unknown-target.ll --check-prefix=NATIVE
; RUN: %if julia-ge-1.12 %{ opt -passes='function(LateLowerGCFrame<task-ptls=100>)' -S %t/unknown-target.ll | FileCheck %t/unknown-target.ll --check-prefix=OPTION %}
; RUN: %if julia-ge-1.12 %{ opt -passes='function(LateLowerGCFrame<task-ptls=124>)' -S %t/i686.ll | FileCheck %t/i686.ll %}

; jlopt maps Julia's name to the port
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes='function(LateLowerGCFrame<task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25>)' -S %t/lowering.ll -o /dev/null
; RUN: grep -c 'pass	jl-late-lower-gc-frame	julia=' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 7

;--- lowering.ll
target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"
target triple = "x86_64-unknown-linux-gnu"

@tag = external addrspace(10) global {}, align 16

declare ptr @julia.get_pgcstack()
declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare void @julia.write_barrier(ptr addrspace(10), ...)
declare void @julia.object_write_barrier(ptr addrspace(10), ...)
declare ptr addrspace(10) @julia.typeof(ptr addrspace(10))
declare void @safepoint()
declare void @use(ptr addrspace(10))
declare void @ext(ptr)

; allocations: Julia 1.10 doesn't pass the tag to julia.gc_alloc_bytes; the thread-local
; state is a pointer-sized GEP before Julia 1.12
; CHECK-LABEL: @alloc(
; V110: %ptls_field = getelementptr inbounds ptr, ptr %task, i64 16
; V110: %v = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls_load, i64 8)
; V110-NEXT: [[TAGADDR:%[0-9]+]] = getelementptr inbounds ptr addrspace(10), ptr addrspace(10) %v, i64 -1
; V110-NEXT: store atomic ptr addrspace(10) @tag, ptr addrspace(10) [[TAGADDR]] unordered, align 8
; V111: %ptls_field = getelementptr inbounds ptr, ptr %task, i64 16
; V112: %ptls_field = getelementptr inbounds i8, ptr %task, i32 168
; V113: %ptls_field = getelementptr inbounds i8, ptr %task, i32 168
; V114: %ptls_field = getelementptr inbounds i8, ptr %task, i32 208
; V111: %v = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls_load, i64 8, i64 ptrtoint (ptr addrspace(10) @tag to i64))
; V111-NEXT: %v.tag_addr = getelementptr inbounds ptr addrspace(10), ptr addrspace(10) %v, i64 -1
define ptr addrspace(10) @alloc(ptr %task) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 8, ptr addrspace(10) @tag)
  ret ptr addrspace(10) %v
}

; operand bundles that are not Julia's are kept (unlike the C++ pass)
; CHECK-LABEL: @alloc_bundles(
; V110: call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls_load, i64 8) [ "deopt"(i32 %s) ]
; V114: call noalias nonnull ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls_load, i64 8, i64 ptrtoint (ptr addrspace(10) @tag to i64)) #{{[0-9]+}} [ "deopt"(i32 %s) ]
define ptr addrspace(10) @alloc_bundles(ptr %task, i32 %s) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 8, ptr addrspace(10) @tag) [ "deopt"(i32 %s) ]
  ret ptr addrspace(10) %v
}

; a and b are live at the first safepoint, only b at the second: from Julia 1.12 on,
; a's slot is reset in between; slots are named from Julia 1.11 on
; CHECK-LABEL: @resets(
; CHECK: call void @safepoint()
; CHECK-NEXT: call void @use(ptr addrspace(10) %a)
; V110-NEXT: call void @safepoint()
; V111-NEXT: call void @safepoint()
; V112-NEXT: %gc_slot_addr_01 = call ptr @julia.get_gc_frame_slot(ptr %gcframe, i32 0)
; V112-NEXT: store ptr addrspace(10) null, ptr %gc_slot_addr_01
; V114-NEXT: %gc_slot_addr_01 = call ptr @julia.get_gc_frame_slot(ptr %gcframe, i32 0)
; V114-NEXT: store ptr addrspace(10) null, ptr %gc_slot_addr_01
define void @resets(ptr %task) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %a = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 8, ptr addrspace(10) @tag)
  %b = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 8, ptr addrspace(10) @tag)
  call void @safepoint()
  call void @use(ptr addrspace(10) %a)
  call void @safepoint()
  call void @use(ptr addrspace(10) %b)
  ret void
}

; an alloca of a root that is only stored after the last safepoint: from Julia 1.13 on,
; it doesn't need a GC frame
; CHECK-LABEL: @late_root(
; V110: %gcframe = call ptr @julia.new_gc_frame(i32 1)
; V112: %gcframe = call ptr @julia.new_gc_frame(i32 1)
; V113-NOT: julia.new_gc_frame
; V113: ret void
; V114-NOT: julia.new_gc_frame
; V114: ret void
define void @late_root(ptr addrspace(10) %x) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %root = alloca ptr addrspace(10), align 8
  call void @safepoint()
  store ptr addrspace(10) %x, ptr %root, align 8
  ret void
}

; write barriers: lowered with names from Julia 1.12 on, checking whether the parent is
; in the system image from 1.13 on, and only elided (lowered by FinalLowerGC) from 1.14 on
; CHECK-LABEL: @barrier(
; V110: [[BITS:%[0-9]+]] = and i64 {{%[0-9]+}}, 3
; V110: icmp eq i64 {{%[0-9]+}}, 0
; V111: %parent.tag = load atomic volatile i64
; V111: %child_not_marked = icmp eq i64
; V112: %parent_bits = and i64 %parent.tag, 3
; V112-NEXT: %parent_old_marked = icmp eq i64 %parent_bits, 3
; V112-NEXT: br i1 %parent_old_marked, label %may_trigger_wb
; V112-NOT: parent_in_image
; V112: br i1 %child_not_marked, label %trigger_wb, label %{{[0-9]+}}, !prof
; V113: %parent_in_image = and i64 %parent.tag, 12
; V113-NEXT: %parent_is_image = icmp eq i64 %parent_in_image, 4
; V113: %should_trigger_wb = or i1 %parent_is_image, %child_not_marked
; V113-NEXT: br i1 %should_trigger_wb, label %trigger_wb
; V110: call void @julia.queue_gc_root(ptr addrspace(10) %parent)
; V113: call void @julia.queue_gc_root(ptr addrspace(10) %parent)
; V114: %pgcstack = call ptr @julia.get_pgcstack()
; V114-NEXT: call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
; V114-NEXT: call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
define void @barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
  call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
  ret void
}

; typeof: the tag load is volatile from Julia 1.11 on
; CHECK-LABEL: @typeof(
; V110: [[TAG:%[0-9]+]] = load atomic i64, ptr addrspace(10) {{%[0-9]+}} unordered, align 8
; V111: %x.tag = load atomic volatile i64, ptr addrspace(10) %x.tag_addr unordered, align 8
; CHECK: and i64 {{%.*}}, -16
define ptr addrspace(10) @typeof(ptr addrspace(10) %x) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %t = call ptr addrspace(10) @julia.typeof(ptr addrspace(10) %x)
  ret ptr addrspace(10) %t
}

; GC state transitions around calls with a gc-transition bundle: dropped before Julia
; 1.12, through the task of the GC stack on 1.12, through the bundle's thread-local
; state from 1.13 on (with a valid alignment for the state byte: a deviation)
; CHECK-LABEL: @transition(
; V110-NEXT: top:
; V110-NEXT: %pgcstack = call ptr @julia.get_pgcstack()
; V110-NEXT: call void @ext(ptr null)
; V110-NEXT: ret void
; V112: %current_task = getelementptr inbounds i8, ptr %pgcstack, i32 -152
; V112: %gc_state = getelementptr inbounds i8, ptr %ptls_load, i32 25
; V112-NEXT: [[OLD:%[0-9]+]] = load atomic i8, ptr %gc_state monotonic, align 1
; V112-NEXT: store atomic i8 2, ptr %gc_state release, align 1
; V112-NEXT: [[SPADDR:%[0-9]+]] = getelementptr inbounds i8, ptr %ptls_load, i32 16
; V112-NEXT: %safepoint = load ptr, ptr [[SPADDR]], align 8
; V113: %gc_state = getelementptr inbounds i8, ptr %ptls, i32 25
; V113: %safepoint = load atomic ptr, ptr {{%[0-9]+}} monotonic, align 8
; V114: %gc_state = getelementptr inbounds i8, ptr %ptls, i32 128
; V114-NEXT: [[OLD:%[0-9]+]] = load atomic i8, ptr %gc_state monotonic, align 8
; V114: %safepoint_addr = getelementptr inbounds i8, ptr %ptls, i32 16
; V112: call void @ext(ptr null)
; V112-NEXT: store atomic i8 [[OLD]], ptr %gc_state release, align 1
; V114: call void @ext(ptr null)
; V114-NEXT: store atomic i8 [[OLD]], ptr %gc_state release, align 8
define void @transition(ptr %ptls) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @ext(ptr null) [ "gc-transition"(ptr %ptls) ]
  ret void
}

; ijl_gc_small_alloc is declared from Julia 1.12 on
; V110-NOT: @ijl_gc_small_alloc
; V111-NOT: @ijl_gc_small_alloc
; V112: declare noalias nonnull ptr addrspace(10) @ijl_gc_small_alloc(ptr, i32, i32, i64)

;--- i686.ll
target datalayout = "e-m:e-p:32:32-p270:32:32-p271:32:32-p272:64:64-i128:128-f64:32:64-f80:32-n8:16:32-S128-ni:10:11:12:13"
target triple = "i686-unknown-linux-gnu"

@tag = external addrspace(10) global {}, align 16
declare ptr @julia.get_pgcstack()
declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i32, ptr addrspace(10))

; CHECK-LABEL: @alloc(
; CHECK: %ptls_field = getelementptr inbounds i8, ptr %task, i32 124
; CHECK: @julia.gc_alloc_bytes(ptr %ptls_load, i32 8, i32 ptrtoint (ptr addrspace(10) @tag to i32))
define ptr addrspace(10) @alloc(ptr %task) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i32 8, ptr addrspace(10) @tag)
  ret ptr addrspace(10) %v
}

;--- unknown-target.ll
target datalayout = "e-p:16:16-ni:10:11:12:13"
target triple = "msp430-unknown-unknown"

@tag = external addrspace(10) global {}, align 16
declare ptr @julia.get_pgcstack()
declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i16, ptr addrspace(10))

; NATIVE: %ptls_field = getelementptr inbounds {{.*}}, ptr %task, i{{(16|32|64)}} {{[0-9]+}}
; OPTION: %ptls_field = getelementptr inbounds i8, ptr %task, i32 100
define ptr addrspace(10) @alloc(ptr %task) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %v = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i16 8, ptr addrspace(10) @tag)
  ret ptr addrspace(10) %v
}
