; RemoveAddrspaces maps every address space to 0.

; RUN: opt -passes='jl-remove-all-addrspaces,verify' -S %s | FileCheck %s --implicit-check-not='addrspace(' --implicit-check-not=.bad

; Julia's name for the pass runs the port
; RUN: opt --load-pass-plugin=libjulia-codegen%shlibext -passes=RemoveAddrspaces -S %s | FileCheck %s --implicit-check-not='addrspace(' --implicit-check-not=.bad

; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=RemoveAddrspaces -S %s -o /dev/null
; RUN: FileCheck --check-prefix=LEDGER %s < %t.ledger
; LEDGER: jlopt jl-remove-all-addrspaces
; LEDGER-NEXT: pass jl-remove-all-addrspaces julia=

target datalayout = "e-p5:32:32-A5"

%S = type { ptr addrspace(1), ptr addrspace(3) }

; CHECK: @global = global i64 0
; CHECK-NEXT: @shared = global [4 x ptr] zeroinitializer
; CHECK-NEXT: @cast = global ptr @global
@global = addrspace(1) global i64 0
@shared = addrspace(3) global [4 x ptr addrspace(10)] zeroinitializer
@cast = global ptr addrspacecast (ptr addrspace(1) @global to ptr)

; CHECK-LABEL: define void @kernel(ptr byref(%S) %s, ptr %p, ptr %q)
; CHECK-NEXT: %a = alloca i64, align 8
; CHECK-NEXT: store i64 1, ptr %a
; CHECK-NEXT: %v = load ptr, ptr %s
; CHECK-NEXT: store ptr %v, ptr %p
; CHECK-NEXT: store ptr %p, ptr %q
; CHECK-NEXT: call void @llvm.memcpy.p0.p0.i64(ptr %p, ptr %q, i64 8, i1 false)
define void @kernel(ptr addrspace(4) byref(%S) %s, ptr addrspace(1) %p, ptr addrspace(3) %q) {
  %a = alloca i64, align 8, addrspace(5)
  store i64 1, ptr addrspace(5) %a
  %v = load ptr addrspace(1), ptr addrspace(4) %s
  store ptr addrspace(1) %v, ptr addrspace(1) %p
  %generic = addrspacecast ptr addrspace(1) %p to ptr
  store ptr %generic, ptr addrspace(3) %q
  call void @llvm.memcpy.p1.p3.i64(ptr addrspace(1) %p, ptr addrspace(3) %q, i64 8, i1 false)
  ret void
}

declare void @llvm.memcpy.p1.p3.i64(ptr addrspace(1), ptr addrspace(3), i64, i1 immarg)
