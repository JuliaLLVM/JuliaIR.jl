; RUN: opt -passes=jl-remove-ni -S %s | FileCheck %s
; RUN: opt -passes='jl-remove-ni,jl-remove-ni' -S %s | FileCheck %s

; Julia's name for the pass runs the port
; RUN: opt --load-pass-plugin=libjulia-codegen%shlibext -passes=RemoveNI -S %s | FileCheck %s

; the port ran, on the running Julia's dialect
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=RemoveNI -S %s -o /dev/null
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes='jl-remove-ni<gc-barrier=snapshot>' -S %s -o /dev/null
; RUN: FileCheck --check-prefix=LEDGER %s < %t.ledger
; LEDGER: jlopt jl-remove-ni
; LEDGER-NEXT: pass jl-remove-ni julia=
; LEDGER-NEXT: jlopt jl-remove-ni<gc-barrier=snapshot>
; LEDGER-NEXT: pass jl-remove-ni julia=

target datalayout = "e-m:e-i64:64-n8:16:32:64-ni:10:11:12:13-S128"
; CHECK: target datalayout = "e-m:e-i64:64-n8:16:32:64-S128"

define void @f() {
; CHECK: define void @f()
  ret void
}
