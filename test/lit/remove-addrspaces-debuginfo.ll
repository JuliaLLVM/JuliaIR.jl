; RemoveJuliaAddrspaces keeps the compile units and the debug info of global variables,
; instead of duplicating them when it maps the metadata of the new global values.

; RUN: opt -passes='jl-remove-addrspaces,verify' -S %s | FileCheck %s --implicit-check-not=DICompileUnit --implicit-check-not=DIGlobalVariable

%T = type { ptr addrspace(10), i64 }

; CHECK: @g = global %T zeroinitializer, !dbg ![[GVE:[0-9]+]]
@g = addrspace(10) global %T zeroinitializer, !dbg !10

; The subprogram of a function is cloned, as by Julia's pass.
; CHECK: define void @f(ptr %x) !dbg ![[SP:[0-9]+]]
; CHECK-NEXT: %y = getelementptr i8, ptr %x, i64 8, !dbg ![[LOC:[0-9]+]]
define void @f(ptr addrspace(10) %x) !dbg !4 {
  %y = getelementptr i8, ptr addrspace(10) %x, i64 8, !dbg !7
  ret void, !dbg !7
}

; CHECK: !llvm.dbg.cu = !{![[CU:[0-9]+]], ![[CU2:[0-9]+]]}
!llvm.dbg.cu = !{!1, !20}
!llvm.module.flags = !{!3}

; The variable of `@g` stays the one listed by its compile unit (Julia 1.13 and later map
; the metadata of global variables before keeping the compile units, so the variable of
; `@g` becomes a copy in a copy of the compile unit, which isn't in `!llvm.dbg.cu`).
; CHECK-DAG: ![[CU]] = distinct !DICompileUnit({{.*}}globals: ![[GLOBALS:[0-9]+]])
; CHECK-DAG: ![[CU2]] = distinct !DICompileUnit({{.*}}emissionKind: NoDebug
; CHECK-DAG: ![[GLOBALS]] = !{![[GVE]]}
; CHECK-DAG: ![[GVE]] = !DIGlobalVariableExpression(var: ![[GV:[0-9]+]], expr: !DIExpression())
; CHECK-DAG: ![[GV]] = distinct !DIGlobalVariable(name: "g", scope: ![[CU]],
; CHECK-DAG: ![[SP]] = distinct !DISubprogram(name: "f",{{.*}} unit: ![[CU]])
; CHECK-DAG: ![[LOC]] = !DILocation(line: 2, scope: ![[SP]])
!0 = !{}
!1 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !2, producer: "julia", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug, globals: !13)
!2 = !DIFile(filename: "f.jl", directory: ".")
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "f", scope: !2, file: !2, line: 1, type: !5, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !1)
!5 = !DISubroutineType(types: !0)
!7 = !DILocation(line: 2, scope: !4)
!10 = !DIGlobalVariableExpression(var: !11, expr: !DIExpression())
!11 = distinct !DIGlobalVariable(name: "g", scope: !1, file: !2, line: 1, type: !14, isLocal: false, isDefinition: true)
!13 = !{!10}
!14 = !DIBasicType(name: "Int64", size: 64, encoding: DW_ATE_signed)
!20 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !2, producer: "julia", isOptimized: true, runtimeVersion: 0, emissionKind: NoDebug)
