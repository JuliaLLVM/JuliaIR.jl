; Types without pointers in them are kept as they are, including target extension types
; (as SPIR-V uses them) and x86's AMX type, also as elements of structs that are
; recreated.

; REQUIRES: llvm-ge-16
; RUN: opt -passes='jl-remove-addrspaces,verify' -S %s | FileCheck %s --implicit-check-not='addrspace(1{{[0-3]}})' --implicit-check-not=.bad

; CHECK: %S = type { target("spirv.Event"), ptr }
%S = type { target("spirv.Event"), ptr addrspace(10) }

; CHECK: declare target("spirv.Event") @event(ptr, target("spirv.Event"))
declare target("spirv.Event") @event(ptr addrspace(10), target("spirv.Event"))

; CHECK-LABEL: define void @f(ptr %p, target("spirv.Event") %e)
; CHECK-NEXT: %a = alloca %S
; CHECK-NEXT: %e2 = call target("spirv.Event") @event(ptr %p, target("spirv.Event") %e)
; CHECK-NEXT: %t = call x86_amx @llvm.x86.tileloadd64.internal(i16 8, i16 8, ptr %p, i64 64)
define void @f(ptr addrspace(10) %p, target("spirv.Event") %e) {
  %a = alloca %S
  %e2 = call target("spirv.Event") @event(ptr addrspace(10) %p, target("spirv.Event") %e)
  %c = addrspacecast ptr addrspace(10) %p to ptr
  %t = call x86_amx @llvm.x86.tileloadd64.internal(i16 8, i16 8, ptr %c, i64 64)
  ret void
}

declare x86_amx @llvm.x86.tileloadd64.internal(i16, i16, ptr, i64)
