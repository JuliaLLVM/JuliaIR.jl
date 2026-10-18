; What GPUCompiler expects of RemoveJuliaAddrspaces, which it runs before handing the IR
; to a back-end: no Julia address space remains, the address spaces of the back-end are
; kept, and kernel parameters keep their attributes.

; RUN: opt -passes='jl-remove-addrspaces,verify' -S %s | FileCheck %s --implicit-check-not='addrspace(1{{[0-3]}})'

; an AMDGPU-like data layout: allocas in address space 5
target datalayout = "e-p:64:64-p1:64:64-p3:32:32-p4:64:64-p5:32:32-ni:10:11:12:13-A5-G1"

%S = type { ptr addrspace(10), i64 }

; CHECK: @shared = internal addrspace(3) global [32 x i64] undef
@shared = internal addrspace(3) global [32 x i64] undef

; a struct argument passed by reference (address space 11) keeps its byref type, now
; without the tracked pointer in it, and stays in address space 0 (GPUCompiler then
; moves it to the kernel argument address space); boxed arguments become generic
; pointers
; CHECK-LABEL: define void @kernel(ptr byref(%S) align 8 %s, ptr %boxed, ptr addrspace(1) %global)
; CHECK-NEXT: %stack = alloca i64, align 8, addrspace(5)
; CHECK-NEXT: %field = getelementptr inbounds %S, ptr %s, i64 0, i32 1
; CHECK-NEXT: %v = load i64, ptr %field
; CHECK-NEXT: store i64 %v, ptr addrspace(5) %stack
; CHECK-NEXT: %obj = load ptr, ptr %s
; CHECK-NEXT: %x = load i64, ptr %obj
; CHECK-NEXT: store i64 %x, ptr addrspace(1) %global
; CHECK-NEXT: %y = load i64, ptr %boxed
; CHECK-NEXT: %shared = getelementptr i64, ptr addrspace(3) @shared, i64 %y
; CHECK-NEXT: store i64 %x, ptr addrspace(3) %shared
define void @kernel(ptr addrspace(11) byref(%S) align 8 %s, ptr addrspace(10) %boxed, ptr addrspace(1) %global) {
  %stack = alloca i64, align 8, addrspace(5)
  %field = getelementptr inbounds %S, ptr addrspace(11) %s, i64 0, i32 1
  %v = load i64, ptr addrspace(11) %field
  store i64 %v, ptr addrspace(5) %stack
  %obj = load ptr addrspace(10), ptr addrspace(11) %s
  %derived = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  %x = load i64, ptr addrspace(11) %derived
  store i64 %x, ptr addrspace(1) %global
  %y = load i64, ptr addrspace(10) %boxed
  %shared = getelementptr i64, ptr addrspace(3) @shared, i64 %y
  store i64 %x, ptr addrspace(3) %shared
  ret void
}

