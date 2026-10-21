; The non-integral component need not have a preceding hyphen.
; RUN: opt -passes=jl-remove-ni -S %s | FileCheck %s
; CHECK: target datalayout = "e-p:64:64"
target datalayout = "ni:10:11:12:13-e-p:64:64"
