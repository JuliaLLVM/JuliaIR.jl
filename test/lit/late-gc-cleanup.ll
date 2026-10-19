; LateGCCleanup: the part of Julia's LateLowerGCFrame that applies to functions without a
; GC frame, as GPU back-ends have them after their own GC lowering.

; RUN: split-file %s %t
; RUN: opt -julia=1.14.0-DEV -passes='function(jl-late-gc-cleanup)' -S %t/rewrites.ll | FileCheck %t/rewrites.ll --check-prefixes=CHECK,V111
; RUN: opt -julia=1.11 -passes='function(jl-late-gc-cleanup)' -S %t/rewrites.ll | FileCheck %t/rewrites.ll --check-prefixes=CHECK,V111
; RUN: opt -julia=1.10 -passes='function(jl-late-gc-cleanup)' -S %t/rewrites.ll | FileCheck %t/rewrites.ll --check-prefixes=CHECK,V110

; the TBAA types whose tags are made mutable depend on the Julia version
; RUN: opt -julia=1.10 -passes='function(jl-late-gc-cleanup)' -S %t/tbaa.ll | FileCheck %t/tbaa.ll --check-prefix=V110
; RUN: opt -julia=1.11 -passes='function(jl-late-gc-cleanup)' -S %t/tbaa.ll | FileCheck %t/tbaa.ll --check-prefix=V111
; RUN: opt -julia=1.13 -passes='function(jl-late-gc-cleanup)' -S %t/tbaa.ll | FileCheck %t/tbaa.ll --check-prefix=V111
; RUN: opt -julia=1.14.0-DEV -passes='function(jl-late-gc-cleanup)' -S %t/tbaa.ll | FileCheck %t/tbaa.ll --check-prefix=V114

; what needs Julia's runtime or a GC frame is rejected, without changing the function
; RUN: not opt -julia=1.13 -passes='function(jl-late-gc-cleanup)' -S %t/unsupported.ll 2>&1 | FileCheck %t/unsupported.ll --check-prefix=V113
; RUN: not opt -julia=1.14.0-DEV -passes='function(jl-late-gc-cleanup)' -S %t/unsupported.ll 2>&1 | FileCheck %t/unsupported.ll --check-prefix=V114
; RUN: opt -julia=1.13 -passes='function(jl-late-gc-cleanup)' -S %t/supported.ll | FileCheck %t/supported.ll
; RUN: not opt -julia=1.14.0-DEV -passes='function(jl-late-gc-cleanup)' -S %t/unsupported-calls.ll 2>&1 | FileCheck %t/unsupported-calls.ll
; a GC stack needs a GC frame as soon as values must be rooted, also when it is not used
; RUN: not opt -julia=1.13 -passes='function(jl-late-gc-cleanup)' -S %t/unused-gcstack.ll 2>&1 | FileCheck %t/unused-gcstack.ll
; RUN: not opt -julia=1.13 -passes='function(jl-late-gc-cleanup)' -S %t/frame-intrinsics.ll 2>&1 | FileCheck %t/frame-intrinsics.ll
; RUN: not opt -julia=1.14.0-DEV -passes='function(jl-late-gc-cleanup)' -S %t/thunk.ll 2>&1 | FileCheck %t/thunk.ll

; Without the cleanup, a load of constant data through a by-pointer argument, inlined
; into a caller that passes a stack slot, is folded to undef (JuliaLang/julia#44285).
; Metal relies on the cleanup before it inlines (GPUCompiler's src/metal.jl).
; RUN: opt -passes='cgscc(inline),function(gvn)' -S %t/metal.ll | FileCheck %t/metal.ll --check-prefix=HAZARD
; RUN: opt -passes='function(jl-late-gc-cleanup),cgscc(inline),function(gvn)' -S %t/metal.ll | FileCheck %t/metal.ll

; the port ran, and on optnone functions too
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -julia=1.12 -passes='function(jl-late-gc-cleanup)' -S %t/supported.ll -o /dev/null
; RUN: grep -c 'pass	jl-late-gc-cleanup	julia=1.12.0' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 3

;--- rewrites.ll
@obj = external addrspace(10) global i64

declare nonnull ptr addrspace(10) @julia.call(ptr, ptr addrspace(10), ...)
declare nonnull ptr addrspace(10) @julia.call2(ptr, ptr addrspace(10), ptr addrspace(10), ...)
declare nonnull ptr addrspace(10) @julia.call3(ptr, ptr addrspace(11), ...)
declare ptr addrspace(10) @ijl_apply_generic(ptr addrspace(10), ptr, i32)
declare ptr addrspace(10) @ijl_invoke(ptr addrspace(10), ptr, i32, ptr addrspace(10))
declare ptr addrspace(10) @jlfunc3(ptr addrspace(11), ptr, i32)
declare token @llvm.julia.gc_preserve_begin(...)
declare void @llvm.julia.gc_preserve_end(token)
declare void @julia.gcroot_flush()
declare ptr @julia.pointer_from_objref(ptr addrspace(10))
declare ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10), ptr)
declare ptr addrspace(10) @jl_alloc_genericmemory_unchecked(ptr, i64, ptr addrspace(10))
declare void @use(ptr addrspace(10))
declare void @llvm.assume(i1)

; loads through Julia's address spaces lose `!invariant.load`, others keep it
; CHECK-LABEL: @metadata(
; CHECK-NEXT: %tracked = load i64, ptr addrspace(10) %a, align 8{{$}}
; CHECK-NEXT: %derived = load i64, ptr addrspace(11) %b, align 8{{$}}
; CHECK-NEXT: %loaded = load i64, ptr addrspace(13) %c, align 8{{$}}
; CHECK-NEXT: %global = load i64, ptr addrspace(1) %d, align 8, !invariant.load
define i64 @metadata(ptr addrspace(10) %a, ptr addrspace(11) %b, ptr addrspace(13) %c, ptr addrspace(1) %d) {
  %tracked = load i64, ptr addrspace(10) %a, align 8, !invariant.load !0
  %derived = load i64, ptr addrspace(11) %b, align 8, !invariant.load !0
  %loaded = load i64, ptr addrspace(13) %c, align 8, !invariant.load !0
  %global = load i64, ptr addrspace(1) %d, align 8, !invariant.load !0
  ret i64 %tracked
}

; chains of insertvalues start from zero instead of undef or poison
; CHECK-LABEL: @aggregates(
; CHECK-NEXT: %a = insertvalue { ptr addrspace(10), i64 } zeroinitializer, ptr addrspace(10) %obj, 0
; CHECK-NEXT: %b = insertvalue { ptr addrspace(10), i64 } %a, i64 1, 1
; CHECK-NEXT: %c = insertvalue [2 x i64] zeroinitializer, i64 1, 0
define { ptr addrspace(10), i64 } @aggregates(ptr addrspace(10) %obj) {
  %a = insertvalue { ptr addrspace(10), i64 } undef, ptr addrspace(10) %obj, 0
  %b = insertvalue { ptr addrspace(10), i64 } %a, i64 1, 1
  %c = insertvalue [2 x i64] poison, i64 1, 0
  ret { ptr addrspace(10), i64 } %b
}

; GC intrinsics that only matter to GC root placement
; CHECK-LABEL: @intrinsics(
; CHECK-NEXT: %ptr = addrspacecast ptr addrspace(10) %obj to ptr
; CHECK-NEXT: %global = addrspacecast ptr addrspace(10) @obj to ptr
; V111-NEXT: %field = addrspacecast ptr %ptr to ptr addrspace(13)
; V110-NEXT: %field = call ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10) %obj, ptr %ptr)
; CHECK-NEXT: %val = load i64, ptr addrspace(13) %field
; CHECK-NEXT: ret i64 %val
define i64 @intrinsics(ptr addrspace(10) %obj) {
  %tok = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
  %ptr = call ptr @julia.pointer_from_objref(ptr addrspace(10) %obj)
  %global = call ptr @julia.pointer_from_objref(ptr addrspace(10) @obj)
  %field = call ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10) %obj, ptr %ptr)
  call void @julia.gcroot_flush()
  %val = load i64, ptr addrspace(13) %field
  call void @llvm.julia.gc_preserve_end(token %tok)
  ret i64 %val
}

; jlcalls pass their arguments in one array per function, as large as needed (named
; since Julia 1.11)
; CHECK-LABEL: @jlcalls(
; CHECK-NEXT: top:
; V111-NEXT: [[FRAME:%jlcallframe]] = alloca ptr addrspace(10), i32 2, align 8
; V110-NEXT: [[FRAME:%0]] = alloca ptr addrspace(10), i32 2, align 8
; CHECK-NEXT: [[SLOT0:%.*]] = getelementptr inbounds ptr addrspace(10), ptr [[FRAME]], i32 0
; CHECK-NEXT: store ptr addrspace(10) %a, ptr [[SLOT0]], align 8, !dbg
; CHECK-NEXT: [[SLOT1:%.*]] = getelementptr inbounds ptr addrspace(10), ptr [[FRAME]], i32 1
; CHECK-NEXT: store ptr addrspace(10) %b, ptr [[SLOT1]], align 8, !dbg
; CHECK-NEXT: %r1 = tail call nonnull ptr addrspace(10) @ijl_apply_generic(ptr addrspace(10) %f, ptr [[FRAME]], i32 2) [[NOUNWIND:#[0-9]+]], !dbg
; CHECK-NEXT: [[SLOT0:%.*]] = getelementptr inbounds ptr addrspace(10), ptr [[FRAME]], i32 0
; CHECK-NEXT: store ptr addrspace(10) %b, ptr [[SLOT0]], align 8
; CHECK-NEXT: %r2 = call nonnull ptr addrspace(10) @ijl_invoke(ptr addrspace(10) %f, ptr [[FRAME]], i32 1, ptr addrspace(10) %a)
; V111-NEXT: %r3 = call nonnull ptr addrspace(10) @jlfunc3(ptr addrspace(11) %d, ptr null, i32 0)
; V110-NEXT: %r3 = call ptr addrspace(10) (ptr, ptr addrspace(11), ...) @julia.call3(
; CHECK-NEXT: %r4 = call nonnull ptr addrspace(10) @ijl_apply_generic(ptr addrspace(10) %f, ptr null, i32 0) [ "deopt"(i32 1) ]
define ptr addrspace(10) @jlcalls(ptr addrspace(10) %f, ptr addrspace(10) %a, ptr addrspace(10) %b, ptr addrspace(11) %d) !dbg !4 {
top:
  %r1 = tail call ptr addrspace(10) (ptr, ptr addrspace(10), ...) @julia.call(ptr @ijl_apply_generic, ptr addrspace(10) %f, ptr addrspace(10) %a, ptr addrspace(10) %b) nounwind, !dbg !7
  %r2 = call ptr addrspace(10) (ptr, ptr addrspace(10), ptr addrspace(10), ...) @julia.call2(ptr @ijl_invoke, ptr addrspace(10) %a, ptr addrspace(10) %f, ptr addrspace(10) %b)
  %r3 = call ptr addrspace(10) (ptr, ptr addrspace(11), ...) @julia.call3(ptr @jlfunc3, ptr addrspace(11) %d)
  %r4 = call ptr addrspace(10) (ptr, ptr addrspace(10), ...) @julia.call(ptr @ijl_apply_generic, ptr addrspace(10) %f) [ "jl_roots"(ptr addrspace(10) %a), "deopt"(i32 1) ]
  ret ptr addrspace(10) %r1
}

; Julia's operand bundles are removed, others are kept
; CHECK-LABEL: @bundles(
; CHECK-NEXT: call void @use(ptr addrspace(10) %a){{$}}
; CHECK-NEXT: call void @use(ptr addrspace(10) %a) [ "deopt"(i32 1) ]
; CHECK-NEXT: call void @llvm.assume(i1 true) [ "align"(ptr addrspace(10) %a, i64 16) ]
define void @bundles(ptr addrspace(10) %a, ptr addrspace(10) %b) {
  call void @use(ptr addrspace(10) %a) [ "jl_roots"(ptr addrspace(10) %b) ]
  call void @use(ptr addrspace(10) %a) [ "jl_roots"(ptr addrspace(10) %b), "deopt"(i32 1) ]
  call void @llvm.assume(i1 true) [ "align"(ptr addrspace(10) %a, i64 16) ]
  ret void
}

; the zeroinit_indirect bundle (Julia master) asks for the memory that the data pointer
; of the allocated object points to to be zeroed
; CHECK-LABEL: @zeroinit_indirect(
; CHECK-NEXT: %mem = call ptr addrspace(10) @jl_alloc_genericmemory_unchecked(ptr %ptls, i64 %n, ptr addrspace(10) %tag), !dbg [[LOC:![0-9]+]]
; CHECK-NEXT: [[DERIVED:%.*]] = addrspacecast ptr addrspace(10) %mem to ptr addrspace(11), !dbg [[LOC]]
; CHECK-NEXT: [[FIELD:%.*]] = getelementptr inbounds i8, ptr addrspace(11) [[DERIVED]], i64 8, !dbg [[LOC]]
; CHECK-NEXT: [[DATA:%.*]] = load ptr, ptr addrspace(11) [[FIELD]], align 8, !dbg [[LOC]]
; CHECK-NEXT: call void @llvm.memset.p0.i64(ptr align 8 [[DATA]], i8 0, i64 %n, i1 false), !dbg [[LOC]]
; CHECK-NEXT: %const = call ptr addrspace(10) @jl_alloc_genericmemory_unchecked(ptr %ptls, i64 32, ptr addrspace(10) %tag)
; CHECK-NEXT: [[DERIVED:%.*]] = addrspacecast ptr addrspace(10) %const to ptr addrspace(11)
; CHECK-NEXT: [[FIELD:%.*]] = getelementptr inbounds i8, ptr addrspace(11) [[DERIVED]], i64 8
; CHECK-NEXT: [[DATA:%.*]] = load ptr, ptr addrspace(11) [[FIELD]], align 8
; CHECK-NEXT: call void @llvm.memset.p0.i64(ptr align 8 [[DATA]], i8 0, i64 32, i1 false)
; CHECK-NEXT: %empty = call ptr addrspace(10) @jl_alloc_genericmemory_unchecked(ptr %ptls, i64 0, ptr addrspace(10) %tag)
; CHECK-NEXT: ret ptr addrspace(10) %mem
define ptr addrspace(10) @zeroinit_indirect(ptr %ptls, i64 %n, ptr addrspace(10) %tag) !dbg !5 {
  %mem = call ptr addrspace(10) @jl_alloc_genericmemory_unchecked(ptr %ptls, i64 %n, ptr addrspace(10) %tag) [ "julia.gc_alloc_zeroinit_indirect"(i64 8, i64 %n) ], !dbg !8
  %const = call ptr addrspace(10) @jl_alloc_genericmemory_unchecked(ptr %ptls, i64 32, ptr addrspace(10) %tag) [ "julia.gc_alloc_zeroinit_indirect"(i64 8, i64 32) ]
  %empty = call ptr addrspace(10) @jl_alloc_genericmemory_unchecked(ptr %ptls, i64 0, ptr addrspace(10) %tag) [ "julia.gc_alloc_zeroinit_indirect"(i64 8, i64 0) ]
  ret ptr addrspace(10) %mem
}

; Julia master doesn't lower thunks
; CHECK-LABEL: @thunk(
; CHECK-NEXT: %v = load i64, ptr addrspace(10) %a, align 8, !invariant.load
define i64 @thunk(ptr addrspace(10) %a) "thunk" {
  %v = load i64, ptr addrspace(10) %a, align 8, !invariant.load !0
  ret i64 %v
}

; the call keeps its function attributes
; CHECK: attributes [[NOUNWIND]] = { nounwind }

!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !3, emissionKind: FullDebug)
!3 = !DIFile(filename: "kernel.jl", directory: ".")
!4 = distinct !DISubprogram(name: "jlcalls", scope: !3, file: !3, line: 1, type: !6, unit: !2, spFlags: DISPFlagDefinition)
!5 = distinct !DISubprogram(name: "zeroinit_indirect", scope: !3, file: !3, line: 10, type: !6, unit: !2, spFlags: DISPFlagDefinition)
!6 = !DISubroutineType(types: !{})
!7 = !DILocation(line: 2, scope: !4)
!8 = !DILocation(line: 11, scope: !5)

;--- tbaa.ll
; V110-LABEL: @tbaa(
; V110-NEXT: load i64, ptr %p, align 8, !tbaa [[CONST:![0-9]+]]
; V110-NEXT: load i64, ptr %p, align 8, !tbaa [[PTR:![0-9]+]]
; V110-NEXT: load i64, ptr %p, align 8, !tbaa [[LEN:![0-9]+]]
; V110-NEXT: load i64, ptr %p, align 8, !tbaa [[MEM:![0-9]+]]
; V110-NEXT: load i64, ptr %p, align 8, !tbaa [[DATA:![0-9]+]]
; V110-DAG: [[CONST]] = !{![[CONSTTY:[0-9]+]], ![[CONSTTY]], i64 0}
; V110-DAG: [[PTR]] = !{!{{[0-9]+}}, !{{[0-9]+}}, i64 0, i64 1}
; V110-DAG: [[LEN]] = !{!{{[0-9]+}}, !{{[0-9]+}}, i64 0, i64 1}
; V110-DAG: [[MEM]] = !{!{{[0-9]+}}, !{{[0-9]+}}, i64 0, i64 1}
; V110-DAG: [[DATA]] = !{!{{[0-9]+}}, !{{[0-9]+}}, i64 0}
; V110-DAG: ![[CONSTTY]] = !{!"jtbaa_const"

; V111-LABEL: @tbaa(
; V111-NEXT: load i64, ptr %p, align 8, !tbaa [[CONST:![0-9]+]]
; V111-NEXT: load i64, ptr %p, align 8, !tbaa [[PTR:![0-9]+]]
; V111-NEXT: load i64, ptr %p, align 8, !tbaa [[LEN:![0-9]+]]
; V111-NEXT: load i64, ptr %p, align 8, !tbaa [[MEM:![0-9]+]]
; V111-DAG: [[CONST]] = !{![[CONSTTY:[0-9]+]], ![[CONSTTY]], i64 0}
; V111-DAG: [[PTR]] = !{![[PTRTY:[0-9]+]], ![[PTRTY]], i64 0}
; V111-DAG: [[LEN]] = !{![[LENTY:[0-9]+]], ![[LENTY]], i64 0}
; V111-DAG: [[MEM]] = !{!{{[0-9]+}}, !{{[0-9]+}}, i64 0, i64 1}
; V111-DAG: ![[PTRTY]] = !{!"jtbaa_memoryptr"
; V111-DAG: ![[LENTY]] = !{!"jtbaa_memorylen"

; V114-LABEL: @tbaa(
; V114-NEXT: load i64, ptr %p, align 8, !tbaa [[CONST:![0-9]+]]
; V114-NEXT: load i64, ptr %p, align 8, !tbaa [[PTR:![0-9]+]]
; V114-NEXT: load i64, ptr %p, align 8, !tbaa [[LEN:![0-9]+]]
; V114-NEXT: load i64, ptr %p, align 8, !tbaa [[MEM:![0-9]+]]
; V114-DAG: [[CONST]] = !{![[CONSTTY:[0-9]+]], ![[CONSTTY]], i64 0}
; V114-DAG: [[PTR]] = !{![[PTRTY:[0-9]+]], ![[PTRTY]], i64 0}
; V114-DAG: [[LEN]] = !{![[LENTY:[0-9]+]], ![[LENTY]], i64 0}
; V114-DAG: [[MEM]] = !{![[MEMTY:[0-9]+]], ![[MEMTY]], i64 0}
; V114-DAG: ![[PTRTY]] = !{!"jtbaa_memoryptr", ![[MEMTY]]
; V114-DAG: ![[LENTY]] = !{!"jtbaa_memorylen", ![[MEMTY]]
; V114-DAG: ![[MEMTY]] = !{!"jtbaa_memory"
define void @tbaa(ptr %p) {
  %const = load i64, ptr %p, align 8, !tbaa !0
  %memoryptr = load i64, ptr %p, align 8, !tbaa !4
  %memorylen = load i64, ptr %p, align 8, !tbaa !7
  %memory = load i64, ptr %p, align 8, !tbaa !9
  %data = load i64, ptr %p, align 8, !tbaa !10
  ret void
}

!0 = !{!1, !1, i64 0, i64 1}
!1 = !{!"jtbaa_const", !2, i64 0}
!2 = !{!"jtbaa", !3, i64 0}
!3 = !{!"jtbaa"}
!4 = !{!5, !5, i64 0, i64 1}
!5 = !{!"jtbaa_memoryptr", !6, i64 0}
!6 = !{!"jtbaa_memory", !2, i64 0}
!7 = !{!8, !8, i64 0, i64 1}
!8 = !{!"jtbaa_memorylen", !6, i64 0}
!9 = !{!6, !6, i64 0, i64 1}
!10 = !{!11, !11, i64 0}
!11 = !{!"jtbaa_data", !2, i64 0}

;--- unsupported.ll
; V113: UnsupportedInputError: function unsupported contains constructs that LateGCCleanup does not support
; V113-NEXT: gcstack argument: the function has a GC stack, which needs GC frame lowering
; V113-NEXT: ptr %gcstack
; V113-NEXT: julia.get_pgcstack: the function has a GC stack, which needs GC frame lowering
; V113-NEXT: %pgcstack = call ptr @julia.get_pgcstack()
; V113-NEXT: julia.gc_alloc_obj: allocations must be lowered first (e.g., by GPUCompiler's GPULowerGCFrame) (at kernel.jl:2)
; V113-NEXT: %v = call ptr addrspace(10) @julia.gc_alloc_obj(
; V113-NEXT: julia.write_barrier: write barriers must be removed first (e.g., by GPUCompiler's GPULowerGCFrame)
; V113-NEXT: call void (ptr addrspace(10), ...) @julia.write_barrier(
; V113-NEXT: julia.typeof: reading the type of an object needs the object headers of Julia's runtime
; V113-NEXT: %t = call ptr addrspace(10) @julia.typeof(
; V113-NEXT: julia.blackbox: julia.blackbox is lowered to inline assembly for the CPU
; V113-NEXT: %b = call ptr addrspace(10) @julia.blackbox(
; V113-NEXT: gc-transition operand bundle: GC state transitions need Julia's runtime
; V113-NEXT: call void @ext(ptr %gcstack) [ "gc-transition"(ptr %gcstack) ]
; V113-NOT: {{.}}

; V114: UnsupportedInputError: function unsupported contains constructs that LateGCCleanup does not support
; V114: julia.gc_alloc_obj: allocations must be lowered first
; V114-NOT: julia.write_barrier
; V114: julia.object_write_barrier: write barriers must be removed first
; V114-NEXT: call void (ptr addrspace(10), ...) @julia.object_write_barrier(
; V114-NEXT: julia.field_write_barrier.p11: write barriers must be removed first
; V114: julia.blackbox: julia.blackbox is lowered to inline assembly for the CPU
declare ptr @julia.get_pgcstack()
declare ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare void @julia.write_barrier(ptr addrspace(10), ...)
declare void @julia.object_write_barrier(ptr addrspace(10), ...)
declare void @julia.field_write_barrier.p11(ptr addrspace(10), ...)
declare ptr addrspace(10) @julia.typeof(ptr addrspace(10))
declare ptr addrspace(10) @julia.blackbox(ptr addrspace(10))
declare void @ext(ptr)

define void @unsupported(ptr addrspace(10) %a, ptr swiftself "gcstack" %gcstack) !dbg !4 {
  %pgcstack = call ptr @julia.get_pgcstack()
  %task = getelementptr i8, ptr %pgcstack, i64 -16
  %v = call ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 8, ptr addrspace(10) %a), !dbg !6
  call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %a, ptr addrspace(10) %v)
  call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %a, ptr addrspace(10) %v)
  %slot = addrspacecast ptr addrspace(10) %a to ptr addrspace(11)
  call void (ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %a, ptr addrspace(11) %slot, ptr addrspace(10) %v)
  %t = call ptr addrspace(10) @julia.typeof(ptr addrspace(10) %a)
  %b = call ptr addrspace(10) @julia.blackbox(ptr addrspace(10) %a)
  call void @ext(ptr %gcstack) [ "gc-transition"(ptr %gcstack) ]
  ret void
}

!llvm.module.flags = !{!0}
!llvm.dbg.cu = !{!1}
!0 = !{i32 2, !"Debug Info Version", i32 3}
!1 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !2, emissionKind: FullDebug)
!2 = !DIFile(filename: "kernel.jl", directory: ".")
!4 = distinct !DISubprogram(name: "unsupported", scope: !2, file: !2, line: 1, type: !5, unit: !1, spFlags: DISPFlagDefinition)
!5 = !DISubroutineType(types: !{})
!6 = !DILocation(line: 2, scope: !4)

;--- frame-intrinsics.ll
; the intrinsics that LateLowerGCFrame creates are lowered by FinalLowerGC
; CHECK: UnsupportedInputError: function frame contains constructs that LateGCCleanup does not support
; CHECK-NEXT: julia.new_gc_frame: GC frames and allocations of Julia's runtime are lowered by FinalLowerGC
declare ptr @julia.new_gc_frame(i32)

define void @frame() {
  %f = call ptr @julia.new_gc_frame(i32 1)
  ret void
}

;--- thunk.ll
; functions that the general pass skips (thunks) are validated too
; CHECK: UnsupportedInputError: function thunk contains constructs
; CHECK-NEXT: julia.typeof: reading the type of an object needs the object headers of Julia's runtime
declare ptr addrspace(10) @julia.typeof(ptr addrspace(10))

define ptr addrspace(10) @thunk(ptr addrspace(10) %a) "thunk" {
  %t = call ptr addrspace(10) @julia.typeof(ptr addrspace(10) %a)
  ret ptr addrspace(10) %t
}

;--- supported.ll
; calls of Julia's runtime are fine without a GC stack
; CHECK-LABEL: @runtime_call(
; CHECK-NEXT: %v = load i64, ptr addrspace(10) %a, align 8{{$}}
; CHECK-NEXT: call void @jl_throw(ptr addrspace(12) null)
declare void @jl_throw(ptr addrspace(12))

define i64 @runtime_call(ptr addrspace(10) %a) {
  %v = load i64, ptr addrspace(10) %a, align 8, !invariant.load !0
  call void @jl_throw(ptr addrspace(12) null)
  ret i64 %v
}

; CHECK-LABEL: @skipped(
; CHECK-NEXT: %v = load i64, ptr addrspace(10) %a, align 8{{$}}
define i64 @skipped(ptr addrspace(10) %a) noinline optnone {
  %v = load i64, ptr addrspace(10) %a, align 8, !invariant.load !0
  ret i64 %v
}

; CHECK-LABEL: @nothing(
; CHECK-NEXT: ret void
define void @nothing() {
  ret void
}

!0 = !{}

;--- unsupported-calls.ll
; the initialization bundles of julia.gc_alloc_obj must be discharged by its lowering,
; and Julia's intrinsics and bundles are only handled on calls
; CHECK: UnsupportedInputError: function unsupported_calls contains constructs that LateGCCleanup does not support
; CHECK-NEXT: julia.gc_alloc_zeroinit operand bundle: only valid on julia.gc_alloc_obj, whose lowering must initialize the object
; CHECK-NEXT: %obj = call ptr addrspace(10) @gc_pool_alloc(i64 16) [ "julia.gc_alloc_zeroinit"(i64 0, i64 16) ]
; CHECK-NEXT: julia.gc_alloc_ptr_offsets operand bundle: only valid on julia.gc_alloc_obj, whose lowering must initialize the object
; CHECK-NEXT: %obj2 = call ptr addrspace(10) @gc_pool_alloc(i64 16) [ "julia.gc_alloc_ptr_offsets"(i64 8) ]
; CHECK-NEXT: invoke of a Julia intrinsic or with Julia's operand bundles: only calls are supported
; CHECK-NEXT: %ptr = invoke ptr @julia.pointer_from_objref(ptr addrspace(10) %obj)
; CHECK-NEXT: to label %cont unwind label %lpad
; CHECK-NEXT: invoke of a Julia intrinsic or with Julia's operand bundles: only calls are supported
; CHECK-NEXT: invoke void @ext() [ "gc-transition"(ptr null) ]
declare ptr addrspace(10) @gc_pool_alloc(i64)
declare ptr @julia.pointer_from_objref(ptr addrspace(10))
declare void @ext()
declare i32 @personality(...)

define void @unsupported_calls() personality ptr @personality {
  %obj = call ptr addrspace(10) @gc_pool_alloc(i64 16) [ "julia.gc_alloc_zeroinit"(i64 0, i64 16) ]
  %obj2 = call ptr addrspace(10) @gc_pool_alloc(i64 16) [ "julia.gc_alloc_ptr_offsets"(i64 8) ]
  %ptr = invoke ptr @julia.pointer_from_objref(ptr addrspace(10) %obj)
          to label %cont unwind label %lpad
cont:
  invoke void @ext() [ "gc-transition"(ptr null) ]
          to label %done unwind label %lpad
done:
  ret void
lpad:
  %lp = landingpad { ptr, i32 } cleanup
  ret void
}

;--- unused-gcstack.ll
; CHECK: julia.get_pgcstack: the function has a GC stack, which needs GC frame lowering
; CHECK-NEXT: %pgcstack = call ptr @julia.get_pgcstack()
declare ptr @julia.get_pgcstack()
declare void @use(ptr addrspace(10))

define void @unused_gcstack(ptr addrspace(10) %a) {
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @use(ptr addrspace(10) %a)
  ret void
}

;--- metal.ll
; CHECK-LABEL: @kernel(
; CHECK: ret i64 %x
; HAZARD-LABEL: @kernel(
; HAZARD: ret i64 {{undef|poison}}
define internal i64 @getfield(ptr addrspace(11) nocapture readonly %agg) {
  %v = load i64, ptr addrspace(11) %agg, align 8, !tbaa !0, !invariant.load !4
  ret i64 %v
}

define i64 @kernel(i64 %x) {
  %slot = alloca i64, align 8
  store i64 %x, ptr %slot, align 8
  %p = addrspacecast ptr %slot to ptr addrspace(11)
  %r = call i64 @getfield(ptr addrspace(11) %p)
  ret i64 %r
}

!0 = !{!1, !1, i64 0, i64 1}
!1 = !{!"jtbaa_const", !2, i64 0}
!2 = !{!"jtbaa", !3, i64 0}
!3 = !{!"jtbaa"}
!4 = !{}
