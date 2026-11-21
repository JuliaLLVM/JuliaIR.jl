; The debug location of the code that LowerPTLS inserts after a `julia.get_pgcstack_or_new`
; call that a debug intrinsic follows: like C++'s `IRBuilder` positioned at the intrinsic,
; the intrinsic's own location before LLVM 18, and from LLVM 18 on, the one of the next
; instruction that isn't a debug intrinsic (`Instruction::getStableDebugLoc`). From LLVM 19
; on, the intrinsic is parsed into a debug record, which isn't an instruction.

; RUN: opt -passes='jl-lower-ptls<tls-offset=-8;tls-elf-support=yes>' -S %s | FileCheck %s --check-prefix=%if llvm-ge-18 %{STABLE%} %else %{INTRINSIC%}

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128-ni:10:11:12:13"
target triple = "x86_64-unknown-linux-gnu"

declare ptr @julia.get_pgcstack_or_new()
declare void @use(ptr)
declare void @llvm.dbg.value(metadata, metadata, metadata)

; STABLE: icmp ne ptr %{{[a-z_0-9]+}}, null, !dbg [[USE:![0-9]+]]
; STABLE: [[USE]] = !DILocation(line: 4,
; INTRINSIC: icmp ne ptr %{{[a-z_0-9]+}}, null, !dbg [[DBG:![0-9]+]]
; INTRINSIC: [[DBG]] = !DILocation(line: 3,
define i64 @cfunction(i64 %x) !dbg !4 {
top:
  %pgcstack = call ptr @julia.get_pgcstack_or_new(), !dbg !8
  call void @llvm.dbg.value(metadata i64 %x, metadata !6, metadata !DIExpression()), !dbg !10
  call void @use(ptr %pgcstack), !dbg !9
  %y = add i64 %x, 1, !dbg !9
  ret i64 %y, !dbg !9
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3}
!0 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !1, emissionKind: FullDebug)
!1 = !DIFile(filename: "test.jl", directory: "/")
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "cfunction", scope: !1, file: !1, line: 1, type: !5, unit: !0, spFlags: DISPFlagDefinition)
!5 = !DISubroutineType(types: !{null})
!6 = !DILocalVariable(name: "x", scope: !4, file: !1, line: 1, type: !7)
!7 = !DIBasicType(name: "Int64", size: 64, encoding: DW_ATE_signed)
!8 = !DILocation(line: 2, scope: !4)
!9 = !DILocation(line: 4, scope: !4)
!10 = !DILocation(line: 3, scope: !4)
