; Indirect functions are recreated like aliases, with the mapped type and resolver (Julia's
; pass leaves them referring to the resolver it deletes).

; RUN: opt -passes='jl-remove-addrspaces,verify' -S %s | FileCheck %s --implicit-check-not='addrspace(1{{[0-3]}})' --implicit-check-not=.bad

; CHECK: @i = ifunc void (ptr), ptr @resolver
@i = ifunc void (ptr addrspace(10)), ptr @resolver

; CHECK-LABEL: define void @f(ptr %p)
; CHECK-NEXT: call void @i(ptr %p)
define void @f(ptr addrspace(10) %p) {
  call void @i(ptr addrspace(10) %p)
  ret void
}

; CHECK: define ptr @resolver()
define ptr @resolver() {
  ret ptr null
}
