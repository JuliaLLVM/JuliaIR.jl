; PropagateJuliaAddrspaces lifts chains into the common address space of their leaves
; on every dialect (Julia master's behaviour, JuliaLang/julia#62807).

; RUN: opt -passes='function(jl-propagate-addrspaces,dce)' -S %s | FileCheck %s
; RUN: opt -passes='function(PropagateJuliaAddrspaces,dce)' -S %s | FileCheck %s

; the port ran (also for Julia's name of the pass), and not on optnone functions
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=PropagateJuliaAddrspaces -S %s -o /dev/null
; RUN: FileCheck --check-prefix=LEDGER %s < %t.ledger
; RUN: grep -c 'pass	jl-propagate-addrspaces' %t.ledger | FileCheck --check-prefix=COUNT %s
; LEDGER: jlopt jl-propagate-addrspaces
; LEDGER-NEXT: pass jl-propagate-addrspaces julia=
; COUNT: 11

declare void @llvm.memset.p11.i64(ptr addrspace(11), i8, i64, i1)
declare void @llvm.memset.inline.p11.i64(ptr addrspace(11), i8, i64, i1)
declare void @llvm.memcpy.p11.p11.i64(ptr addrspace(11), ptr addrspace(11), i64, i1)
declare void @llvm.memmove.p0.p11.i64(ptr, ptr addrspace(11), i64, i1)

; memset is redeclared for the new pointer, overloaded on the length (Julia's C++ pass
; uses the type of the value operand, which gives an invalid call); attributes,
; metadata and the debug location are kept
; CHECK-LABEL: @memset(
; CHECK-NEXT: %stack = alloca [4 x i64]
; CHECK-NEXT: call void @llvm.memset.p0.i64(ptr align 8 %stack, i8 0, i64 %n, i1 false), !dbg !{{[0-9]+}}, !tbaa !{{[0-9]+}}
; CHECK-NEXT: ret void
define void @memset(i64 %n) !dbg !5 {
  %stack = alloca [4 x i64]
  %casted = addrspacecast ptr %stack to ptr addrspace(11)
  call void @llvm.memset.p11.i64(ptr addrspace(11) align 8 %casted, i8 0, i64 %n, i1 false), !tbaa !0, !dbg !8
  ret void
}

; memset.inline stays memset.inline (the C++ pass makes it a memset)
; CHECK-LABEL: @memset_inline(
; CHECK: call void @llvm.memset.inline.p0.i64(ptr %stack, i8 0, i64 32, i1 false)
define void @memset_inline() {
  %stack = alloca [4 x i64]
  %casted = addrspacecast ptr %stack to ptr addrspace(11)
  call void @llvm.memset.inline.p11.i64(ptr addrspace(11) %casted, i8 0, i64 32, i1 false)
  ret void
}

; the destination and source of memory transfers are lifted independently
; CHECK-LABEL: @memcpy_dest_only(
; CHECK: call void @llvm.memcpy.p0.p11.i64(ptr %stack, ptr addrspace(11) %obj_derived, i64 32, i1 false)
define void @memcpy_dest_only(ptr addrspace(10) %obj) {
  %stack = alloca [4 x i64]
  %casted = addrspacecast ptr %stack to ptr addrspace(11)
  %obj_derived = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  call void @llvm.memcpy.p11.p11.i64(ptr addrspace(11) %casted, ptr addrspace(11) %obj_derived, i64 32, i1 false)
  ret void
}

; CHECK-LABEL: @memmove(
; CHECK-NEXT: %stack = alloca [4 x i64]
; CHECK-NEXT: [[GEP:%.*]] = getelementptr inbounds i8, ptr %stack, i64 8, !foo !{{[0-9]+}}
; CHECK-NEXT: call void @llvm.memmove.p0.p0.i64(ptr %dst, ptr [[GEP]], i64 16, i1 false)
define void @memmove(ptr %dst) {
  %stack = alloca [4 x i64]
  %casted = addrspacecast ptr %stack to ptr addrspace(11)
  %gep = getelementptr inbounds i8, ptr addrspace(11) %casted, i64 8, !foo !9
  call void @llvm.memmove.p0.p11.i64(ptr %dst, ptr addrspace(11) %gep, i64 16, i1 false)
  ret void
}

; CHECK-LABEL: @atomics(
; CHECK: store atomic i64 %v, ptr %stack release, align 8
; CHECK: atomicrmw add ptr %stack, i64 %v seq_cst
; CHECK: cmpxchg ptr %stack, i64 %old, i64 %v acq_rel monotonic
define i64 @atomics(i64 %v) {
  %stack = alloca i64
  %casted = addrspacecast ptr %stack to ptr addrspace(11)
  store atomic i64 %v, ptr addrspace(11) %casted release, align 8
  %old = atomicrmw add ptr addrspace(11) %casted, i64 %v seq_cst
  %pair = cmpxchg ptr addrspace(11) %casted, i64 %old, i64 %v acq_rel monotonic
  %r = extractvalue { i64, i1 } %pair, 0
  ret i64 %r
}

; a cycle of phis and GEPs (the original cycle is left for a later cleanup)
; CHECK-LABEL: @loop(
; CHECK: loop:
; CHECK-NEXT: [[PHI:%.*]] = phi ptr [ %stack, %top ], [ [[NEXT:%.*]], %loop ]
; CHECK-NEXT: %ptr = phi ptr addrspace(11)
; CHECK-NEXT: [[NEXT]] = getelementptr i64, ptr [[PHI]], i64 1
; CHECK-NEXT: %next = getelementptr i64, ptr addrspace(11) %ptr
; CHECK-NEXT: %val = load i64, ptr [[PHI]]
define i64 @loop(i64 %n) {
top:
  %stack = alloca [4 x i64]
  %casted = addrspacecast ptr %stack to ptr addrspace(11)
  br label %loop
loop:
  %ptr = phi ptr addrspace(11) [ %casted, %top ], [ %next, %loop ]
  %next = getelementptr i64, ptr addrspace(11) %ptr, i64 1
  %val = load i64, ptr addrspace(11) %ptr
  %done = icmp eq i64 %val, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i64 %val
}

; nested selects, with a null arm
; CHECK-LABEL: @selects(
; CHECK-NEXT: %stack = alloca i64
; CHECK-NEXT: [[INNER:%.*]] = select i1 %b, ptr %stack, ptr null, !prof !{{[0-9]+}}
; CHECK-NEXT: [[OUTER:%.*]] = select i1 %a, ptr [[INNER]], ptr %stack
; CHECK-NEXT: load i64, ptr [[OUTER]]
define i64 @selects(i1 %a, i1 %b) {
  %stack = alloca i64
  %casted = addrspacecast ptr %stack to ptr addrspace(11)
  %inner = select i1 %b, ptr addrspace(11) %casted, ptr addrspace(11) null, !prof !10
  %outer = select i1 %a, ptr addrspace(11) %inner, ptr addrspace(11) %casted
  %load = load i64, ptr addrspace(11) %outer
  ret i64 %load
}

; a tracked leaf is not lifted, and neither are values derived from it later
; CHECK-LABEL: @tracked(
; CHECK: %load1 = load i64, ptr addrspace(11) %gep
; CHECK: %load2 = load i64, ptr addrspace(11) %phi
define i64 @tracked(ptr addrspace(10) %obj, i1 %c) {
top:
  %stack = alloca i64
  %casted = addrspacecast ptr %stack to ptr addrspace(11)
  %derived = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  %gep = getelementptr i8, ptr addrspace(11) %derived, i64 8
  %load1 = load i64, ptr addrspace(11) %gep
  br i1 %c, label %a, label %b
a:
  br label %b
b:
  %phi = phi ptr addrspace(11) [ %casted, %top ], [ %gep, %a ]
  %load2 = load i64, ptr addrspace(11) %phi
  %sum = add i64 %load1, %load2
  ret i64 %sum
}

; leaves in different address spaces can't be lifted
@global = addrspace(1) global i64 0
; CHECK-LABEL: @mixed(
; CHECK: %phi = phi ptr addrspace(11)
; CHECK: load i64, ptr addrspace(11) %phi
define i64 @mixed(i1 %c) {
top:
  %stack = alloca i64
  %casted = addrspacecast ptr %stack to ptr addrspace(11)
  br i1 %c, label %a, label %b
a:
  %global_casted = addrspacecast ptr addrspace(1) @global to ptr addrspace(11)
  br label %b
b:
  %phi = phi ptr addrspace(11) [ %casted, %top ], [ %global_casted, %a ]
  %load = load i64, ptr addrspace(11) %phi
  ret i64 %load
}

; a chain of only null pointers is lifted into the alloca address space
; CHECK-LABEL: @null(
; CHECK: load i64, ptr null
define i64 @null() {
  %casted = addrspacecast ptr null to ptr addrspace(11)
  %load = load i64, ptr addrspace(11) %casted
  ret i64 %load
}

; constant data leaves can't be lifted (and their users in other functions are
; unaffected)
; CHECK-LABEL: @undef_leaf(
; CHECK: load i64, ptr addrspace(11) undef
define i64 @undef_leaf() {
  %load = load i64, ptr addrspace(11) undef
  ret i64 %load
}

; not an optimization the pass applies to optnone functions
; CHECK-LABEL: @skipped(
; CHECK: load i64, ptr addrspace(11) %casted
define i64 @skipped() noinline optnone {
  %stack = alloca i64
  %casted = addrspacecast ptr %stack to ptr addrspace(11)
  %load = load i64, ptr addrspace(11) %casted
  ret i64 %load
}


!llvm.module.flags = !{!3, !4}
!llvm.dbg.cu = !{!1}

!0 = !{!11, !11, i64 0}
!11 = !{!"jtbaa_stack", !12, i64 0}
!12 = !{!"jtbaa"}
!1 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !2, producer: "julia", isOptimized: true, runtimeVersion: 0, emissionKind: NoDebug, nameTableKind: None)
!2 = !DIFile(filename: "test.jl", directory: ".")
!3 = !{i32 2, !"Dwarf Version", i32 4}
!4 = !{i32 2, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "memset", scope: null, file: !2, line: 1, type: !6, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !1, retainedNodes: !7)
!6 = !DISubroutineType(types: !7)
!7 = !{}
!8 = !DILocation(line: 1, scope: !5)
!9 = !{!"foo"}
!10 = !{!"branch_weights", i32 1, i32 2}
