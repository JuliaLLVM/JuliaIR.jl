; Where CancellationLowering puts the task's field addresses relative to the debug records
; of a GC stack argument's entry block: Julia's pass inserts at `entry.begin()`, before the
; records attached to the first instruction, when there is no alloca to skip, and after
; them (an iterator advanced past the allocas) when there is.

; REQUIRES: julia-1.14
; RUN: opt -passes='function(CancellationLowering<task-gcstack=192;task-ptls=208;task-eh=224;task-reset-ctx=264;tls-safepoint=16;reset-ctx-size=224;reset-ctx-align=8;reset-ctx-gcstack=8;reset-ctx-eh=16;reset-ctx-mctx=24;setjmp=__sigsetjmp>)' -S %s | FileCheck %s

declare void @unsafe_call()

; CHECK-LABEL: define void @no_allocas(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    %current_task = getelementptr i8, ptr %pgcstack, i64 -192
; CHECK-NEXT:    %reset_ctx_ptr = getelementptr i8, ptr %current_task, i64 264
; CHECK-NEXT:    %ptls_field_ptr = getelementptr i8, ptr %current_task, i64 208
; CHECK-NEXT:    %eh_field_ptr = getelementptr i8, ptr %current_task, i64 224
; CHECK-NEXT:      #dbg_value(i64 %v,
; CHECK-NEXT:    store i64 %v, ptr %pgcstack
define void @no_allocas(ptr "gcstack" %pgcstack, i64 %v) "julia.ipo_reset_safe" !dbg !5 {
entry:
    #dbg_value(i64 %v, !12, !DIExpression(), !8)
  store i64 %v, ptr %pgcstack, !dbg !8
  call void @unsafe_call(), !dbg !8
  ret void, !dbg !8
}

; CHECK-LABEL: define void @allocas(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    %a = alloca i64
; CHECK-NEXT:      #dbg_value(i64 %v,
; CHECK-NEXT:    %current_task = getelementptr i8, ptr %pgcstack, i64 -192
; CHECK-NEXT:    %reset_ctx_ptr = getelementptr i8, ptr %current_task, i64 264
; CHECK-NEXT:    %ptls_field_ptr = getelementptr i8, ptr %current_task, i64 208
; CHECK-NEXT:    %eh_field_ptr = getelementptr i8, ptr %current_task, i64 224
; CHECK-NEXT:    store i64 %v, ptr %a
define void @allocas(ptr "gcstack" %pgcstack, i64 %v) "julia.ipo_reset_safe" !dbg !9 {
entry:
  %a = alloca i64
    #dbg_value(i64 %v, !13, !DIExpression(), !10)
  store i64 %v, ptr %a, !dbg !10
  call void @unsafe_call(), !dbg !10
  ret void, !dbg !10
}

!llvm.dbg.cu = !{!1}
!llvm.module.flags = !{!4}

!1 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !2, producer: "julia", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!2 = !DIFile(filename: "a.jl", directory: ".")
!3 = !DIBasicType(name: "Int64", size: 64, encoding: DW_ATE_signed)
!4 = !{i32 2, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "no_allocas", scope: !2, file: !2, line: 1, type: !6, unit: !1, spFlags: DISPFlagDefinition)
!6 = !DISubroutineType(types: !7)
!7 = !{}
!8 = !DILocation(line: 1, scope: !5)
!9 = distinct !DISubprogram(name: "allocas", scope: !2, file: !2, line: 1, type: !6, unit: !1, spFlags: DISPFlagDefinition)
!10 = !DILocation(line: 1, scope: !9)
!12 = !DILocalVariable(name: "v", arg: 2, scope: !5, file: !2, line: 1, type: !3)
!13 = !DILocalVariable(name: "v", arg: 2, scope: !9, file: !2, line: 1, type: !3)
