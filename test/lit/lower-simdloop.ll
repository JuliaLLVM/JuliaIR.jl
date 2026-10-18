; LowerSIMDLoop removes the `julia.simdloop`/`julia.ivdep` markers from loop IDs, tags the
; memory accesses of ivdep loops as parallel, and allows reassociating and contracting
; floating-point reductions of simd loops. From Julia 1.12 on, it also marks the `fmul`
; that only feeds an addition of a reduction as `contract`.

; RUN: opt -julia=1.10 -passes='loop(LowerSIMDLoop)' -S %s | FileCheck %s --check-prefixes=CHECK,NOCOMBINE
; RUN: opt -julia=1.11 -passes=LowerSIMDLoop -S %s | FileCheck %s --check-prefixes=CHECK,NOCOMBINE
; RUN: opt -julia=1.12 -passes='function(loop-mssa(LowerSIMDLoop))' -verify-memoryssa -S %s | FileCheck %s --check-prefixes=CHECK,COMBINE
; RUN: opt -passes='jl-lower-simdloop<julia=1.13>' -S %s | FileCheck %s --check-prefixes=CHECK,COMBINE
; RUN: opt -julia=1.14.0-DEV -passes='function(loop-mssa(LowerSIMDLoop),print<memoryssa>)' -S %s -o /dev/null 2>&1 | FileCheck %s --check-prefix=MSSA

; the port ran once per loop, except in the optnone function
; (it is not required)
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -julia=1.12 -passes='loop(LowerSIMDLoop)' -S %s -o /dev/null
; RUN: grep -c 'pass	jl-lower-simdloop	julia=1.12.0' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 14

; CHECK-LABEL: @ivdep(
; CHECK: %v = load double, ptr %p, align 8, !llvm.mem.parallel_loop_access [[IVDEP_ACCESS:![0-9]+]]
; CHECK-NEXT: store double %v, ptr %q, align 8, !llvm.mem.parallel_loop_access [[IVDEP_ACCESS]]
; CHECK-NEXT: %rmw = atomicrmw add ptr %q, i64 1 monotonic, align 8, !llvm.mem.parallel_loop_access [[IVDEP_ACCESS]]
; CHECK-NEXT: %pure = call double @pure(double %v){{$}}
; CHECK-NEXT: %rooted = call double @pure(double %v) [ "jl_roots"(ptr %p) ], !llvm.mem.parallel_loop_access [[IVDEP_ACCESS]]
; CHECK-NEXT: %reads = call double @reads(ptr %p), !llvm.mem.parallel_loop_access [[IVDEP_ACCESS]]
; CHECK-NEXT: call void @llvm.assume(i1 true) [ "align"(ptr %p, i64 8) ], !llvm.mem.parallel_loop_access [[IVDEP_ACCESS]]
; CHECK-NEXT: %sqrt = call double @llvm.sqrt.f64(double %v){{$}}
; CHECK-NEXT: %sqrt2 = call double @pure(double %v) #[[NONE:[0-9]+]]{{$}}
; CHECK-NEXT: %unknown = call double @unknown(double %v) #[[READNONE_SITE:[0-9]+]]{{$}}
; CHECK: br i1 %done, label %exit, label %loop, !llvm.loop [[IVDEP_ID:![0-9]+]]
; MSSA-LABEL: MemorySSA for function: ivdep
; MSSA: MemoryUse
; MSSA: MemoryDef
define void @ivdep(ptr %p, ptr %q) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %v = load double, ptr %p, align 8
  store double %v, ptr %q, align 8
  %rmw = atomicrmw add ptr %q, i64 1 monotonic, align 8
  %pure = call double @pure(double %v)
  ; operand bundles make a call read memory
  %rooted = call double @pure(double %v) [ "jl_roots"(ptr %p) ]
  %reads = call double @reads(ptr %p)
  ; ... except on llvm.assume, which writes inaccessible memory anyway
  call void @llvm.assume(i1 true) [ "align"(ptr %p, i64 8) ]
  %sqrt = call double @llvm.sqrt.f64(double %v)
  %sqrt2 = call double @pure(double %v) readnone
  ; call-site attributes count too
  %unknown = call double @unknown(double %v) readnone
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, 100
  br i1 %done, label %exit, label %loop, !llvm.loop !0
exit:
  ret void
}

; a simd loop (no ivdep) gets no access tags
; CHECK-LABEL: @fadd_reduction(
; CHECK: %v = load double, ptr %p, align 8{{$}}
; NOCOMBINE-NEXT: %m = fmul double %v, %v
; COMBINE-NEXT: %m = fmul contract double %v, %v
; CHECK-NEXT: %acc.next = fadd reassoc contract double %acc, %m
; CHECK: br i1 %done, label %exit, label %loop, !llvm.loop [[SIMD_ID:![0-9]+]]
define double @fadd_reduction(ptr %p) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %acc = phi double [ 0.0, %entry ], [ %acc.next, %loop ]
  %v = load double, ptr %p, align 8
  %m = fmul double %v, %v
  %acc.next = fadd double %acc, %m
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, 100
  br i1 %done, label %exit, label %loop, !llvm.loop !1
exit:
  ret double %acc.next
}

; a chain of several operations, with the existing flags kept; the running value must be
; the first operand of an fsub
; CHECK-LABEL: @fsub_chain(
; CHECK: %a1 = fsub reassoc nnan contract float %acc, %v
; CHECK-NEXT: %a2 = fadd reassoc contract float %v, %a1
; CHECK-NEXT: %a3 = fsub reassoc contract float %a2, %v
define float @fsub_chain(ptr %p) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %acc = phi float [ 0.0, %entry ], [ %a3, %loop ]
  %v = load float, ptr %p, align 4
  %a1 = fsub nnan float %acc, %v
  %a2 = fadd float %v, %a1
  %a3 = fsub float %a2, %v
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, 100
  br i1 %done, label %exit, label %loop, !llvm.loop !1
exit:
  ret float %a3
}

; CHECK-LABEL: @fsub_rhs(
; CHECK: %acc.next = fsub float %v, %acc
define float @fsub_rhs(ptr %p) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %acc = phi float [ 0.0, %entry ], [ %acc.next, %loop ]
  %v = load float, ptr %p, align 4
  %acc.next = fsub float %v, %acc
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, 100
  br i1 %done, label %exit, label %loop, !llvm.loop !1
exit:
  ret float %acc.next
}

; multiplications and divisions (of the running value) form a chain too; the fmul of a
; multiplication chain is not a candidate for contraction
; CHECK-LABEL: @fmul_chain(
; CHECK: %m1 = fmul reassoc contract <2 x double> %acc, %v
; CHECK-NEXT: %m2 = fdiv reassoc contract <2 x double> %m1, %v
define <2 x double> @fmul_chain(ptr %p) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %acc = phi <2 x double> [ <double 1.0, double 1.0>, %entry ], [ %m2, %loop ]
  %v = load <2 x double>, ptr %p, align 16
  %m1 = fmul <2 x double> %acc, %v
  %m2 = fdiv <2 x double> %m1, %v
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, 100
  br i1 %done, label %exit, label %loop, !llvm.loop !1
exit:
  ret <2 x double> %m2
}

; CHECK-LABEL: @fdiv_rhs(
; CHECK: %acc.next = fdiv double %v, %acc
define double @fdiv_rhs(ptr %p) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %acc = phi double [ 1.0, %entry ], [ %acc.next, %loop ]
  %v = load double, ptr %p, align 8
  %acc.next = fdiv double %v, %acc
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, 100
  br i1 %done, label %exit, label %loop, !llvm.loop !1
exit:
  ret double %acc.next
}

; additions and multiplications don't mix
; CHECK-LABEL: @mixed_chain(
; CHECK: %a1 = fadd double %acc, %v
; CHECK-NEXT: %a2 = fmul double %a1, %v
define double @mixed_chain(ptr %p) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %acc = phi double [ 0.0, %entry ], [ %a2, %loop ]
  %v = load double, ptr %p, align 8
  %a1 = fadd double %acc, %v
  %a2 = fmul double %a1, %v
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, 100
  br i1 %done, label %exit, label %loop, !llvm.loop !1
exit:
  ret double %a2
}

; a value of the chain with another use in the loop (or used twice by one instruction)
; is not a reduction; uses outside of the loop don't matter
; CHECK-LABEL: @two_uses(
; CHECK: %a1 = fadd double %acc, %v
; CHECK-NEXT: store double %a1, ptr %p
; CHECK: %b1 = fadd double %b, %b
; CHECK: %c1 = fadd reassoc contract double %c, %v
; NOCOMBINE-NEXT: %m = fmul double %v, %v
; COMBINE-NEXT: %m = fmul contract double %v, %v
; CHECK-NEXT: %c2 = fadd reassoc contract double %c1, %m
define double @two_uses(ptr %p) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %acc = phi double [ 0.0, %entry ], [ %a1, %loop ]
  %b = phi double [ 0.0, %entry ], [ %b1, %loop ]
  %c = phi double [ 0.0, %entry ], [ %c2, %loop ]
  %v = load double, ptr %p, align 8
  %a1 = fadd double %acc, %v
  store double %a1, ptr %p
  %b1 = fadd double %b, %b
  %c1 = fadd double %c, %v
  %m = fmul double %v, %v
  %c2 = fadd double %c1, %m
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, 100
  br i1 %done, label %exit, label %loop, !llvm.loop !1
exit:
  %r = fadd double %a1, %c1
  ret double %r
}

; the multiplication must be in the loop and have no other use to be contracted
; CHECK-LABEL: @no_combine(
; CHECK: %out = fmul double %x, %x
; CHECK: %m = fmul double %v, %v
; CHECK-NEXT: store double %m, ptr %p
; CHECK-NEXT: %a1 = fadd reassoc contract double %acc, %out
; CHECK-NEXT: %a2 = fadd reassoc contract double %a1, %m
define double @no_combine(ptr %p, double %x) {
entry:
  %out = fmul double %x, %x
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %acc = phi double [ 0.0, %entry ], [ %a2, %loop ]
  %v = load double, ptr %p, align 8
  %m = fmul double %v, %v
  store double %m, ptr %p
  %a1 = fadd double %acc, %out
  %a2 = fadd double %a1, %m
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, 100
  br i1 %done, label %exit, label %loop, !llvm.loop !1
exit:
  ret double %a2
}

; nested loops: the inner loop is processed first; the outer loop's access tags replace
; the inner one's (like the C++ pass)
; CHECK-LABEL: @nested(
; CHECK: %v = load double, ptr %p, align 8, !llvm.mem.parallel_loop_access [[OUTER_ACCESS:![0-9]+]]
; CHECK: %a = fadd reassoc contract double %inner.acc, %v
; CHECK: br i1 %inner.done, label %outer.latch, label %inner, !llvm.loop [[INNER_ID:![0-9]+]]
; CHECK: br i1 %outer.done, label %exit, label %outer, !llvm.loop [[OUTER_ID:![0-9]+]]
define double @nested(ptr %p) {
entry:
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  %outer.acc = phi double [ 0.0, %entry ], [ %a, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %inner.acc = phi double [ %outer.acc, %outer ], [ %a, %inner ]
  %v = load double, ptr %p, align 8
  %a = fadd double %inner.acc, %v
  %i.next = add i64 %i, 1
  %inner.done = icmp eq i64 %i.next, 100
  br i1 %inner.done, label %outer.latch, label %inner, !llvm.loop !0
outer.latch:
  %j.next = add i64 %j, 1
  %outer.done = icmp eq i64 %j.next, 100
  br i1 %outer.done, label %exit, label %outer, !llvm.loop !2
exit:
  ret double %a
}

; loop IDs without Julia's markers, or without a self reference, are left alone
; CHECK-LABEL: @other_loops(
; CHECK: %a = fadd double %acc, %v
; CHECK: br i1 %done, label %{{.*}}, label %loop, !llvm.loop [[UNROLL:![0-9]+]]
; CHECK: %b = fadd double %acc2, %v
; CHECK: br i1 %done2, label %exit, label %second, !llvm.loop [[NOT_AN_ID:![0-9]+]]
define double @other_loops(ptr %p) {
entry:
  br label %loop
loop:
  %acc = phi double [ 0.0, %entry ], [ %a, %loop ]
  %v = load double, ptr %p, align 8
  %a = fadd double %acc, %v
  %done = fcmp ogt double %a, 0.0
  br i1 %done, label %second, label %loop, !llvm.loop !4
second:
  %acc2 = phi double [ %a, %loop ], [ %b, %second ]
  %b = fadd double %acc2, %v
  %done2 = fcmp ogt double %b, 0.0
  br i1 %done2, label %exit, label %second, !llvm.loop !6
exit:
  ret double %b
}

; not a required pass
; CHECK-LABEL: @skipped(
; CHECK: %a = fadd double %acc, %v
; CHECK: br i1 %done, label %exit, label %loop, !llvm.loop [[SKIPPED_ID:![0-9]+]]
define double @skipped(ptr %p) noinline optnone {
entry:
  br label %loop
loop:
  %acc = phi double [ 0.0, %entry ], [ %a, %loop ]
  %v = load double, ptr %p, align 8
  %a = fadd double %acc, %v
  %done = fcmp ogt double %a, 0.0
  br i1 %done, label %exit, label %loop, !llvm.loop !0
exit:
  ret double %a
}

; a loop ID left with only the self reference is distinct, for every Julia version (as on
; Julia master; older versions turn the uniqued `!{null}`, here also the type array of
; the subroutine type, into the loop ID)
; CHECK-LABEL: @debuginfo(
; CHECK: br i1 %done, label %exit, label %loop, !llvm.loop [[DEBUGINFO_ID:![0-9]+]]
define void @debuginfo(ptr %p) !dbg !10 {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  store double 0.0, ptr %p
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, 100
  br i1 %done, label %exit, label %loop, !llvm.loop !7
exit:
  ret void
}

declare double @pure(double) readnone
declare double @reads(ptr) argmemonly readonly
declare double @unknown(double)
declare void @llvm.assume(i1)
declare double @llvm.sqrt.f64(double)

; CHECK-DAG: attributes #[[NONE]] = { {{memory\(none\)|readnone}} }
; CHECK-DAG: [[IVDEP_ACCESS]] = !{[[IVDEP_ID]]}
; CHECK-DAG: [[IVDEP_ID]] = distinct !{[[IVDEP_ID]]}
; CHECK-DAG: [[SIMD_ID]] = distinct !{[[SIMD_ID]]}
; CHECK-DAG: [[SKIPPED_ID]] = distinct !{[[SKIPPED_ID]], !"julia.simdloop", !"julia.ivdep"}
; CHECK-DAG: [[OUTER_ACCESS]] = !{[[OUTER_ID]]}
; CHECK-DAG: [[OUTER_ID]] = distinct !{[[OUTER_ID]], [[VECTORIZE:![0-9]+]]}
; CHECK-DAG: [[VECTORIZE]] = !{!"llvm.loop.vectorize.enable", i1 true}
; CHECK-DAG: [[INNER_ID]] = distinct !{[[INNER_ID]]}
; CHECK-DAG: [[UNROLL]] = distinct !{[[UNROLL]], [[UNROLL_COUNT:![0-9]+]]}
; CHECK-DAG: [[UNROLL_COUNT]] = !{!"llvm.loop.unroll.count", i32 4}
; CHECK-DAG: [[NOT_AN_ID]] = !{!"julia.simdloop"}
; CHECK-DAG: !DISubroutineType(types: [[TYPES:![0-9]+]])
; CHECK-DAG: [[TYPES]] = !{null}
; CHECK-DAG: [[DEBUGINFO_ID]] = distinct !{[[DEBUGINFO_ID]]}

!0 = distinct !{!0, !"julia.simdloop", !"julia.ivdep"}
!1 = distinct !{!1, !"julia.simdloop"}
!2 = distinct !{!2, !"julia.ivdep", !"julia.something-else", !3}
!3 = !{!"llvm.loop.vectorize.enable", i1 true}
!4 = distinct !{!4, !5}
!5 = !{!"llvm.loop.unroll.count", i32 4}
!6 = !{!"julia.simdloop"}
!7 = distinct !{!7, !"julia.ivdep"}

!llvm.dbg.cu = !{!11}
!llvm.module.flags = !{!14}
!10 = distinct !DISubprogram(name: "debuginfo", scope: !12, file: !12, type: !13, spFlags: DISPFlagDefinition, unit: !11)
!11 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !12, emissionKind: FullDebug)
!12 = !DIFile(filename: "a.jl", directory: ".")
!13 = !DISubroutineType(types: !15)
!14 = !{i32 2, !"Debug Info Version", i32 3}
!15 = !{null}
