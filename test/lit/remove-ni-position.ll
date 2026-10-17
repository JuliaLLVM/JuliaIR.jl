; The non-integral address spaces are removed wherever they are in the data layout,
; and a data layout without them is left alone.

; RUN: split-file %s %t
; RUN: opt -passes=jl-remove-ni -S %t/last.ll | FileCheck %s --check-prefix=LAST
; RUN: opt -passes=jl-remove-ni -S %t/none.ll | FileCheck %s --check-prefix=NONE
; RUN: opt -passes=jl-remove-ni -S %t/nolayout.ll | FileCheck %s --check-prefix=NOLAYOUT

;--- last.ll
target datalayout = "e-i64:64-ni:10:11:12:13"
; LAST: target datalayout = "e-i64:64"
; LAST-NOT: ni:

;--- none.ll
target datalayout = "e-i64:64-n8:16:32:64"
; NONE: target datalayout = "e-i64:64-n8:16:32:64"

;--- nolayout.ll
define void @f() {
  ret void
}
; NOLAYOUT-NOT: datalayout
; NOLAYOUT: define void @f()
