; RemoveJuliaAddrspaces keeps the compile units, also those that only the subprograms of
; inlined code refer to. From LLVM 20 on, cloning a function only maps the compile units
; it visits to themselves, so without this, `!llvm.dbg.cu` would list a copy of the
; compile unit of `@g`, and the module would be invalid (Julia 1.13's fix, for every
; version).

; RUN: opt -passes='jl-remove-addrspaces,verify' -S %s | FileCheck %s --implicit-check-not=DICompileUnit

; CHECK: define void @f(ptr %x) !dbg ![[SP:[0-9]+]]
; CHECK-NEXT: ret void, !dbg ![[LOC:[0-9]+]]
define void @f(ptr addrspace(10) %x) !dbg !4 {
  ret void, !dbg !7
}

; CHECK: !llvm.dbg.cu = !{![[CU:[0-9]+]], ![[CU2:[0-9]+]]}
!llvm.dbg.cu = !{!1, !10}
!llvm.module.flags = !{!3}

; CHECK-DAG: ![[CU]] = distinct !DICompileUnit(
; CHECK-DAG: ![[CU2]] = distinct !DICompileUnit(
; CHECK-DAG: ![[SP]] = distinct !DISubprogram(name: "f",{{.*}} unit: ![[CU]])
; CHECK-DAG: ![[LOC]] = !DILocation(line: 3, scope: ![[SPG:[0-9]+]], inlinedAt: ![[AT:[0-9]+]])
; CHECK-DAG: ![[SPG]] = distinct !DISubprogram(name: "g",{{.*}} unit: ![[CU2]])
; CHECK-DAG: ![[AT]] = distinct !DILocation(line: 2, scope: ![[SP]])
!0 = !{}
!1 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !2, producer: "julia", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!2 = !DIFile(filename: "f.jl", directory: ".")
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "f", scope: !2, file: !2, line: 1, type: !5, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !1)
!5 = !DISubroutineType(types: !0)
!6 = distinct !DILocation(line: 2, scope: !4)
!7 = !DILocation(line: 3, scope: !11, inlinedAt: !6)
!10 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !2, producer: "julia", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!11 = distinct !DISubprogram(name: "g", scope: !2, file: !2, line: 1, type: !5, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !10)
