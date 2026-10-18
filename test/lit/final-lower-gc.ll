; FinalLowerGC (jl-final-lower-gc) on the IR of every Julia version: the behaviours that
; differ between versions, and the fixes adopted from later versions. Upstream's
; fixtures (test/upstream) cover the rest at each version's pin.
;
; The pools that allocations come from are the running Julia's (they differ between
; builds), so their offsets and sizes are matched with patterns.

; RUN: split-file %s %t
; RUN: opt -passes=FinalLowerGC -S %t/frames.ll | FileCheck %t/frames.ll --check-prefixes=CHECK,%if julia-1.10 %{V110%} %else %{NAMES%}
; RUN: opt -passes=FinalLowerGC -S %t/debugloc.ll | FileCheck %t/debugloc.ll --check-prefixes=%if julia-1.10 %{V110%} %else %{NEXT%}
; RUN: %if julia-1.10 %{ opt -passes=FinalLowerGC -S %t/alloc-1.10.ll | FileCheck %t/alloc-1.10.ll %}
; RUN: %if julia-ge-1.11 %{ opt -passes=FinalLowerGC -S %t/alloc.ll | FileCheck %t/alloc.ll --check-prefixes=CHECK,%if julia-1.11 %{V111%} %else %{SMALL%} %}
; RUN: opt -passes=FinalLowerGC -S %t/declarations.ll | FileCheck %t/declarations.ll --check-prefixes=%if julia-1.10 %{V110%}%if julia-1.11 %{GCSTACK%}%if julia-1.12 %{GCSTACK%}%if julia-ge-1.13 %{USES%}
; RUN: opt -passes=FinalLowerGC -S %t/no-julia.ll | FileCheck %t/no-julia.ll --check-prefixes=%if julia-1.10 %{V110%} %else %{NONE%}
; RUN: %if julia-ge-1.13 %{ opt -passes=FinalLowerGC -S %t/gcstack-arg.ll | FileCheck %t/gcstack-arg.ll %}
; RUN: %if julia-ge-1.14 %{ opt -passes=FinalLowerGC -S %t/barriers.ll | FileCheck %t/barriers.ll %}
; RUN: opt -passes=FinalLowerGC -S %t/amdgcn.ll | FileCheck %t/amdgcn.ll
; RUN: opt -passes=FinalLowerGC -S %t/i686.ll | FileCheck %t/i686.ll
; RUN: opt -passes='function(LateLowerGCFrame,FinalLowerGC)' -S %t/overaligned.ll | FileCheck %t/overaligned.ll

; the module pass and the function pass lower functions the same way (except for the
; declarations on Julia 1.10)
; RUN: opt -passes='FinalLowerGC' -S %t/frames.ll -o %t/module.ll
; RUN: opt -passes='function(FinalLowerGC)' -S %t/frames.ll -o %t/function.ll
; RUN: %if julia-ge-1.11 %{ diff %t/module.ll %t/function.ll %}

; jlopt maps Julia's name to the port, at both levels
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes='FinalLowerGC,function(FinalLowerGC)' -S %t/frames.ll -o /dev/null
; RUN: grep -c 'pass	jl-final-lower-gc	julia=' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 6

;--- frames.ll
target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"

declare ptr @julia.get_pgcstack()
declare noalias nonnull ptr @julia.new_gc_frame(i32)
declare void @julia.push_gc_frame(ptr, i32)
declare ptr @julia.get_gc_frame_slot(ptr, i32)
declare void @julia.pop_gc_frame(ptr)
declare void @julia.safepoint(ptr)
declare void @julia.queue_gc_root(ptr addrspace(10))
declare void @use(ptr)

; the frame is zeroed by a non-volatile memset with the frame's TBAA tag (Julia master's
; fix, adopted for every version); its names are Julia 1.11's
; CHECK-LABEL: @frame(
; CHECK: %gcframe = alloca ptr addrspace(10), i32 4, align 16
; CHECK-NEXT: call void @llvm.memset.p0.i64(ptr align 16 %gcframe, i8 0, i64 32, i1 false), !tbaa [[GCFRAME:![0-9]+]]
; V110-NEXT: [[NROOTS:%[0-9]+]] = getelementptr inbounds ptr addrspace(10), ptr %gcframe, i32 0
; V110-NEXT: store i64 8, ptr [[NROOTS]], align 8, !tbaa [[GCFRAME]]
; V110-NEXT: [[PREV:%[0-9]+]] = getelementptr inbounds ptr addrspace(10), ptr %gcframe, i32 1
; V110-NEXT: [[TASK:%[0-9]+]] = load ptr, ptr %pgcstack, align 8
; V110-NEXT: store ptr [[TASK]], ptr [[PREV]], align 8, !tbaa [[GCFRAME]]
; NAMES-NEXT: %frame.nroots = getelementptr inbounds ptr addrspace(10), ptr %gcframe, i32 0
; NAMES-NEXT: store i64 8, ptr %frame.nroots, align 8, !tbaa [[GCFRAME]]
; NAMES-NEXT: %frame.prev = getelementptr inbounds ptr addrspace(10), ptr %gcframe, i32 1
; NAMES-NEXT: %task.gcstack = load ptr, ptr %pgcstack, align 8
; NAMES-NEXT: store ptr %task.gcstack, ptr %frame.prev, align 8, !tbaa [[GCFRAME]]
; CHECK-NEXT: store ptr %gcframe, ptr %pgcstack, align 8
; CHECK-NEXT: %slot = getelementptr inbounds ptr addrspace(10), ptr %gcframe, i32 3
; CHECK-NEXT: [[INDEX:%[0-9]+]] = add i32 %i, 2
; CHECK-NEXT: %dynamic = getelementptr inbounds ptr addrspace(10), ptr %gcframe, i32 [[INDEX]]
; CHECK: load volatile i64, ptr %page, align 8
; CHECK-NEXT: [[PREVADDR:%[0-9]+]] = getelementptr inbounds ptr addrspace(10), ptr %gcframe, i32 1
; V110-NEXT: [[PREV:%[0-9]+]] = load ptr addrspace(10), ptr [[PREVADDR]], align 8, !tbaa [[GCFRAME]]
; NAMES-NEXT: [[PREV:%frame.prev[0-9]*]] = load ptr addrspace(10), ptr [[PREVADDR]], align 8, !tbaa [[GCFRAME]]
; CHECK-NEXT: store ptr addrspace(10) [[PREV]], ptr %pgcstack, align 8, !tbaa [[GCFRAME]]
; CHECK-NEXT: ret void
define void @frame(ptr %page, i32 %i) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %gcframe = call ptr @julia.new_gc_frame(i32 2)
  call void @julia.push_gc_frame(ptr %gcframe, i32 2)
  %slot = call ptr @julia.get_gc_frame_slot(ptr %gcframe, i32 1)
  %dynamic = call ptr @julia.get_gc_frame_slot(ptr %gcframe, i32 %i)
  call void @use(ptr %slot)
  call void @use(ptr %dynamic)
  call void @julia.safepoint(ptr %page)
  call void @julia.pop_gc_frame(ptr %gcframe)
  ret void
}

; the alignment that LateLowerGCFrame records for the frame (Julia 1.13) is kept on every
; version
; CHECK-LABEL: @overaligned_frame(
; CHECK: %gcframe = alloca ptr addrspace(10), i32 3, align 64
define void @overaligned_frame() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %gcframe = call align 64 ptr @julia.new_gc_frame(i32 1)
  call void @julia.push_gc_frame(ptr %gcframe, i32 1)
  call void @use(ptr %gcframe)
  call void @julia.pop_gc_frame(ptr %gcframe)
  ret void
}

; the call to the runtime keeps the call's attributes and metadata
; CHECK-LABEL: @queue_root(
; CHECK: call void @ijl_gc_queue_root(ptr addrspace(10) nonnull %x) #[[NOUNWIND:[0-9]+]], !foo
define void @queue_root(ptr addrspace(10) %x) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @julia.queue_gc_root(ptr addrspace(10) nonnull %x) #0, !foo !0
  ret void
}

; the pass is required: it runs on optnone functions
; CHECK-LABEL: @optnone(
; CHECK: load volatile i64, ptr %page
define void @optnone(ptr %page) #1 {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @julia.safepoint(ptr %page)
  ret void
}

; functions without a GC stack are left alone, intrinsics included
; CHECK-LABEL: @no_gcstack(
; CHECK: call void @julia.safepoint(ptr %page)
; CHECK: call void @julia.queue_gc_root(ptr addrspace(10) %x)
define void @no_gcstack(ptr %page, ptr addrspace(10) %x) {
top:
  call void @julia.safepoint(ptr %page)
  call void @julia.queue_gc_root(ptr addrspace(10) %x)
  ret void
}

; CHECK: [[GCFRAME]] = !{[[GCFRAME_TY:![0-9]+]], [[GCFRAME_TY]], i64 0}
; CHECK: [[GCFRAME_TY]] = !{!"jtbaa_gcframe"

attributes #0 = { nounwind }
attributes #1 = { noinline optnone }
!0 = !{}

;--- debugloc.ll
target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"

declare ptr @julia.get_pgcstack()
declare noalias nonnull ptr @julia.new_gc_frame(i32)
declare void @julia.push_gc_frame(ptr, i32)
declare void @julia.pop_gc_frame(ptr)
declare void @use(ptr)

; Julia 1.10 inserts the frame's allocation and push after the intrinsics, with the debug
; location of the next instruction; later versions take the intrinsic's
; V110: %gcframe = alloca ptr addrspace(10), i32 3, align 16, !dbg [[L12:![0-9]+]]
; V110-NEXT: call void @llvm.memset.p0.i64({{.*}}), !dbg [[L12]]
; V110: store ptr %gcframe, ptr %pgcstack, align 8, !dbg [[L14:![0-9]+]]
; V110: [[L12]] = !DILocation(line: 12,
; V110: [[L14]] = !DILocation(line: 14,
; NEXT: %gcframe = alloca ptr addrspace(10), i32 3, align 16, !dbg [[L11:![0-9]+]]
; NEXT-NEXT: call void @llvm.memset.p0.i64({{.*}}), !dbg [[L11]]
; NEXT: store ptr %gcframe, ptr %pgcstack, align 8, !dbg [[L13:![0-9]+]]
; NEXT: [[L11]] = !DILocation(line: 11,
; NEXT: [[L13]] = !DILocation(line: 13,
define void @f() !dbg !4 {
top:
  %pgcstack = call ptr @julia.get_pgcstack(), !dbg !10
  %gcframe = call ptr @julia.new_gc_frame(i32 1), !dbg !11
  call void @use(ptr null), !dbg !12
  call void @julia.push_gc_frame(ptr %gcframe, i32 1), !dbg !13
  call void @use(ptr null), !dbg !14
  call void @julia.pop_gc_frame(ptr %gcframe), !dbg !16
  ret void, !dbg !17
}

!llvm.dbg.cu = !{!1}
!llvm.module.flags = !{!3}
!0 = !{}
!1 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !2, producer: "julia", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!2 = !DIFile(filename: "f.jl", directory: ".")
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "f", scope: !2, file: !2, line: 1, type: !5, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !1)
!5 = !DISubroutineType(types: !0)
!10 = !DILocation(line: 10, scope: !4)
!11 = !DILocation(line: 11, scope: !4)
!12 = !DILocation(line: 12, scope: !4)
!13 = !DILocation(line: 13, scope: !4)
!14 = !DILocation(line: 14, scope: !4)
!16 = !DILocation(line: 16, scope: !4)
!17 = !DILocation(line: 17, scope: !4)

;--- alloc-1.10.ll
target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"

declare ptr @julia.get_pgcstack()
declare ptr @ptls()
declare noalias nonnull ptr addrspace(10) @julia.gc_alloc_bytes(ptr, i64) #0

; allocations of a constant size come from the pool of their size class, or are big;
; others are typed allocations, whose size is converted to a pointer-sized integer. The
; result is dereferenceable for the object's size (Julia 1.11's rule; 1.10 claims the size
; of the pool's objects, or the allocation's size, past the object's start)
; CHECK-LABEL: @alloc(
; CHECK: %small = call noalias nonnull dereferenceable(8) ptr addrspace(10) @ijl_gc_pool_alloc(ptr %ptls, i32 {{[0-9]+}}, i32 {{[0-9]+}}) #[[POOL:[0-9]+]]
; CHECK-NEXT: %empty = call noalias nonnull ptr addrspace(10) @ijl_gc_pool_alloc(ptr %ptls, i32 {{[0-9]+}}, i32 {{[0-9]+}}) #[[POOL]]
; CHECK-NEXT: %big = call noalias nonnull dereferenceable(100000) ptr addrspace(10) @ijl_gc_big_alloc(ptr %ptls, i64 100008) #[[BIG:[0-9]+]]
; CHECK-NEXT: [[N:%[0-9]+]] = zext i32 %n to i64
; CHECK-NEXT: %dynamic = call noalias nonnull dereferenceable(8) ptr addrspace(10) @ijl_gc_alloc_typed(ptr %ptls, i64 [[N]], ptr null) #[[BIG]]
; CHECK-NEXT: [[W:%[0-9]+]] = trunc i128 %w to i64
; CHECK-NEXT: %wide = call noalias nonnull dereferenceable(8) ptr addrspace(10) @ijl_gc_alloc_typed(ptr %ptls, i64 [[W]], ptr null) #[[BIG]]
; the metadata and the alignment of the intrinsic's call are dropped
; CHECK-NEXT: %aligned = call noalias nonnull dereferenceable(16) ptr addrspace(10) @ijl_gc_pool_alloc(ptr %ptls, i32 {{[0-9]+}}, i32 {{[0-9]+}}) #[[POOL]]{{$}}
; CHECK: declare noalias nonnull ptr addrspace(10) @ijl_gc_pool_alloc(ptr, i32, i32) #[[POOL]]
; CHECK: declare noalias nonnull ptr addrspace(10) @ijl_gc_big_alloc(ptr, i64) #[[BIG]]
; CHECK: declare noalias nonnull ptr addrspace(10) @ijl_gc_alloc_typed(ptr, i64, ptr) #[[BIG]]
; CHECK: attributes #[[POOL]] = { allocsize(2) }
define void @alloc(i32 %n, i128 %w) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %ptls = call ptr @ptls()
  %small = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 8)
  %empty = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 0)
  %big = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 100000)
  %dynamic = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i32 %n)
  %wide = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i128 %w)
  %aligned = call align 64 ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 16), !foo !0
  ret void
}
attributes #0 = { allocsize(1) }
!0 = !{}

;--- alloc.ll
target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"

declare ptr @julia.get_pgcstack()
declare ptr @ptls()
declare noalias nonnull ptr addrspace(10) @julia.gc_alloc_bytes(ptr, i64, i64) #0

; as on Julia 1.10, but with the type tag, and aligned to at least a pointer
; CHECK-LABEL: @alloc(
; V111: %small = call noalias nonnull align 8 dereferenceable(8) ptr addrspace(10) @ijl_gc_pool_alloc_instrumented(ptr %ptls, i32 {{[0-9]+}}, i32 {{[0-9]+}}, i64 1234) #[[POOL:[0-9]+]]
; SMALL: %small = call noalias nonnull align 8 dereferenceable(8) ptr addrspace(10) @ijl_gc_small_alloc(ptr %ptls, i32 {{[0-9]+}}, i32 {{[0-9]+}}, i64 1234) #[[POOL:[0-9]+]]
; CHECK-NEXT: %empty = call noalias nonnull align 8 ptr addrspace(10) @[[POOLFN:ijl_gc_pool_alloc_instrumented|ijl_gc_small_alloc]](ptr %ptls, i32 {{[0-9]+}}, i32 {{[0-9]+}}, i64 1234) #[[POOL]]
; V111-NEXT: %big = call noalias nonnull align 8 dereferenceable(100000) ptr addrspace(10) @ijl_gc_big_alloc_instrumented(ptr %ptls, i64 100008, i64 1234) #[[BIG:[0-9]+]]
; SMALL-NEXT: %big = call noalias nonnull align 8 dereferenceable(100000) ptr addrspace(10) @ijl_gc_big_alloc(ptr %ptls, i64 100008, i64 1234) #[[BIG:[0-9]+]]
; CHECK-NEXT: [[N:%[0-9]+]] = zext i32 %n to i64
; CHECK-NEXT: %dynamic = call noalias nonnull align 8 dereferenceable(8) ptr addrspace(10) @ijl_gc_alloc_typed(ptr %ptls, i64 [[N]], i64 1234) #[[BIG]]
; CHECK-NEXT: [[W:%[0-9]+]] = trunc i128 %w to i64
; CHECK-NEXT: %wide = call noalias nonnull align 8 dereferenceable(8) ptr addrspace(10) @ijl_gc_alloc_typed(ptr %ptls, i64 [[W]], i64 1234) #[[BIG]]
; the alignment of the intrinsic's call is kept, its metadata dropped
; CHECK-NEXT: %aligned = call noalias nonnull align 64 dereferenceable(16) ptr addrspace(10) @[[POOLFN]](ptr %ptls, i32 {{[0-9]+}}, i32 {{[0-9]+}}, i64 1234) #[[POOL]]{{$}}
; CHECK: attributes #[[POOL]] = { nounwind willreturn allockind("alloc") allocsize(2) memory(argmem: read, inaccessiblemem: readwrite) }
; CHECK: attributes #[[BIG]] = { nounwind willreturn allockind("alloc") allocsize(1) memory(argmem: read, inaccessiblemem: readwrite) }
define void @alloc(i32 %n, i128 %w) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %ptls = call ptr @ptls()
  %small = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 8, i64 1234)
  %empty = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 0, i64 1234)
  %big = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 100000, i64 1234)
  %dynamic = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i32 %n, i64 1234)
  %wide = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i128 %w, i64 1234)
  %aligned = call align 64 ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 16, i64 1234), !foo !0
  ret void
}
attributes #0 = { allocsize(1) }
!0 = !{}

;--- declarations.ll
target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"

declare ptr @julia.get_pgcstack()

; the runtime functions are declared by the module pass of Julia 1.10, for every function
; with a GC stack up to Julia 1.12, and only when some function uses a GC intrinsic from
; Julia 1.13 on
; V110: declare void @ijl_gc_queue_root
; GCSTACK: declare void @ijl_gc_queue_root
; USES-NOT: declare void @ijl_gc_queue_root
define void @f() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  ret void
}

;--- no-julia.ll
; Julia 1.10's module pass declares the runtime functions in every module, and moves
; `llvm.compiler.used` to the end of the global variables
; V110: @y = global i64 1
; V110-NEXT: @llvm.compiler.used = appending global [1 x ptr] [ptr @x], section "llvm.metadata"
; V110: declare void @ijl_gc_queue_root(ptr addrspace(10))
; V110: declare {{.*}} @ijl_gc_pool_alloc(
; V110: declare {{.*}} @ijl_gc_big_alloc(
; V110: declare {{.*}} @ijl_gc_alloc_typed(
; NONE: @llvm.compiler.used = appending global [1 x ptr] [ptr @x], section "llvm.metadata"
; NONE-NEXT: @y = global i64 1
; NONE-NOT: declare
@x = global i64 0
@llvm.compiler.used = appending global [1 x ptr] [ptr @x], section "llvm.metadata"
@y = global i64 1
define void @f() {
  ret void
}

;--- gcstack-arg.ll
target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"

declare void @julia.safepoint(ptr)

; from Julia 1.13 on, an argument with the gcstack attribute is the GC stack
; CHECK-LABEL: @f(
; CHECK: load volatile i64, ptr %page
define void @f(ptr "gcstack" %pgcstack, ptr %page) {
top:
  call void @julia.safepoint(ptr %page)
  ret void
}

;--- barriers.ll
target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"

declare ptr @julia.get_pgcstack()
declare ptr @ptls()
declare void @julia.object_write_barrier(ptr addrspace(10), ...)
declare void @julia.field_write_barrier.p11(ptr addrspace(10), ...)
declare noalias nonnull ptr addrspace(10) @julia.gc_alloc_bytes(ptr, i64, i64)
declare void @julia.queue_gc_root(ptr addrspace(10))

; Julia master lowers the write barriers here, without the children that are null and
; the slots of field barriers; a barrier without children is removed
; CHECK-LABEL: @barriers(
; CHECK: %p.tag_addr = getelementptr inbounds i64, ptr addrspace(10) %p, i64 -1
; CHECK-NEXT: %p.tag = load atomic volatile i64, ptr addrspace(10) %p.tag_addr unordered, align 8, !tbaa {{![0-9]+}}, !range {{![0-9]+}}
; CHECK-NEXT: %parent_bits = and i64 %p.tag, 3
; CHECK-NEXT: %parent_old_marked = icmp eq i64 %parent_bits, 3
; CHECK-NEXT: br i1 %parent_old_marked, label %may_trigger_wb, label
; CHECK: may_trigger_wb:
; CHECK-NEXT: %parent_in_image = and i64 %p.tag, 12
; CHECK-NEXT: %parent_is_image = icmp eq i64 %parent_in_image, 4
; CHECK-NEXT: %c.tag_addr = getelementptr inbounds i64, ptr addrspace(10) %c, i64 -1
; CHECK-NEXT: %c.tag = load atomic volatile i64
; CHECK-NEXT: %child_bit = and i64 %c.tag, 1
; CHECK-NEXT: %child_not_marked = icmp eq i64 %child_bit, 0
; CHECK-NEXT: %should_trigger_wb = or i1 %parent_is_image, %child_not_marked
; CHECK-NEXT: br i1 %should_trigger_wb, label %trigger_wb, label {{%[0-9]+}}, !prof [[WEIGHTS:![0-9]+]]
; CHECK: trigger_wb:
; CHECK-NEXT: call void @ijl_gc_queue_root(ptr addrspace(10) %p)
; the field barrier: its slot is not a child
; CHECK: may_trigger_wb{{[0-9]+}}:
; CHECK-NOT: %s.tag
; CHECK: %c.tag{{[0-9]+}} = load atomic volatile i64
; CHECK-NOT: %s.tag
; CHECK: trigger_wb{{[0-9]+}}:
; in a cancellation reset region, the runtime's reset-safe functions are called
; CHECK-NEXT: call void @ijl_gc_queue_root_reset_safe(ptr addrspace(10) %p), !julia.reset_region
; CHECK-NOT: @julia.object_write_barrier(
; CHECK: call void @ijl_gc_queue_root_reset_safe(ptr addrspace(10) %c), !julia.reset_region
; CHECK: %a = call noalias nonnull align 8 dereferenceable(8) ptr addrspace(10) @ijl_gc_small_alloc_reset_safe(
; CHECK: %b = call noalias nonnull align 8 dereferenceable(100000) ptr addrspace(10) @ijl_gc_big_alloc_reset_safe(ptr %ptls, i64 100008, i64 1234)
; CHECK: %d = call noalias nonnull align 8 dereferenceable(8) ptr addrspace(10) @ijl_gc_alloc_typed_reset_safe(ptr %ptls, i64 %n, i64 1234)
; CHECK: [[WEIGHTS]] = !{!"branch_weights", i32 1, i32 9}
define void @barriers(ptr addrspace(10) %p, ptr addrspace(10) %c, ptr addrspace(11) %s, i64 %n) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %ptls = call ptr @ptls()
  call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %p, ptr addrspace(10) %c, ptr addrspace(10) null)
  call void (ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %p, ptr addrspace(11) %s, ptr addrspace(10) %c), !julia.reset_region !0
  call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %p, ptr addrspace(10) addrspacecast (ptr null to ptr addrspace(10)))
  call void @julia.queue_gc_root(ptr addrspace(10) %c), !julia.reset_region !0
  %a = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 8, i64 1234), !julia.reset_region !0
  %b = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 100000, i64 1234), !julia.reset_region !0
  %d = call ptr addrspace(10) @julia.gc_alloc_bytes(ptr %ptls, i64 %n, i64 1234), !julia.reset_region !0
  ret void
}
!0 = !{}

;--- amdgcn.ll
target datalayout = "e-p:64:64-p1:64:64-p2:32:32-p3:32:32-p4:64:64-p5:32:32-p6:32:32-i64:64-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-v512:512-v1024:1024-v2048:2048-n32:64-S32-A5-G1-ni:7:10:11:12:13"
target triple = "amdgcn-amd-amdhsa"

declare ptr @julia.get_pgcstack()
declare noalias nonnull ptr @julia.new_gc_frame(i32)
declare void @julia.push_gc_frame(ptr, i32)
declare void @julia.pop_gc_frame(ptr)
declare void @use(ptr)

; the frame is allocated in the alloca address space, and cast to the generic one
; CHECK: [[FRAME:%[0-9]+]] = alloca ptr addrspace(10), i32 3, align 16, addrspace(5)
; CHECK-NEXT: %gcframe = addrspacecast ptr addrspace(5) [[FRAME]] to ptr
; CHECK-NEXT: call void @llvm.memset.p0.i64(ptr align 16 %gcframe, i8 0, i64 24, i1 false)
define void @f() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %gcframe = call ptr @julia.new_gc_frame(i32 1)
  call void @julia.push_gc_frame(ptr %gcframe, i32 1)
  call void @use(ptr %gcframe)
  call void @julia.pop_gc_frame(ptr %gcframe)
  ret void
}

;--- i686.ll
target datalayout = "e-m:e-p:32:32-p270:32:32-p271:32:32-p272:64:64-i128:128-f64:32:64-f80:32-n8:16:32-S128-ni:10:11:12:13"
target triple = "i686-unknown-linux-gnu"

declare ptr @julia.get_pgcstack()
declare noalias nonnull ptr @julia.new_gc_frame(i32)
declare void @julia.push_gc_frame(ptr, i32)
declare void @julia.pop_gc_frame(ptr)
declare void @julia.safepoint(ptr)
declare void @use(ptr)

; pointer sizes and alignments come from the data layout (the C++ uses the host's)
; CHECK: call void @llvm.memset.p0.i64(ptr align 16 %gcframe, i8 0, i64 12, i1 false)
; CHECK: store i32 4, ptr {{%.*}}, align 4
; CHECK: load ptr, ptr %pgcstack, align 4
; CHECK: store ptr %gcframe, ptr %pgcstack, align 4
; CHECK: load volatile i32, ptr %page, align 4
define void @f(ptr %page) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %gcframe = call ptr @julia.new_gc_frame(i32 1)
  call void @julia.push_gc_frame(ptr %gcframe, i32 1)
  call void @use(ptr %gcframe)
  call void @julia.safepoint(ptr %page)
  call void @julia.pop_gc_frame(ptr %gcframe)
  ret void
}

;--- overaligned.ll
target datalayout = "e-m:e-i64:64-n8:16:32:64-S128-ni:10:11:12:13"

declare ptr @julia.get_pgcstack()
declare void @boxed_simple(ptr addrspace(10), ptr addrspace(10))

; LateLowerGCFrame moves an over-aligned alloca into the frame on every version, and
; FinalLowerGC aligns the frame for it
; CHECK: %gcframe = alloca ptr addrspace(10), i32 {{[0-9]+}}, align 64
; CHECK: %roots = getelementptr inbounds ptr addrspace(10), ptr %gcframe, i32 8
define void @overaligned_gc_alloca(<8 x ptr addrspace(10)> %values) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %roots = alloca <8 x ptr addrspace(10)>, align 64
  store <8 x ptr addrspace(10)> %values, ptr %roots, align 64
  %root4addr = getelementptr ptr addrspace(10), ptr %roots, i64 4
  %root4 = load ptr addrspace(10), ptr %root4addr, align 32
  call void @boxed_simple(ptr addrspace(10) %root4, ptr addrspace(10) %root4)
  ret void
}
