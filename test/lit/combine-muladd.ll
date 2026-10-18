; CombineMulAdd marks an `fmul` as `contract` when its only use is an `fadd`/`fsub` with
; the `contract` flag (Julia 1.10 and 1.11). Julia 1.12 removed the pass: for later
; dialects the port leaves the IR alone.

; RUN: opt -julia=1.11 -passes=CombineMulAdd -S %s | FileCheck %s --check-prefixes=CHECK,COMBINE
; RUN: opt -julia=1.10 -passes='function(CombineMulAdd)' -S %s | FileCheck %s --check-prefixes=CHECK,COMBINE
; RUN: opt -passes='jl-combine-muladd<julia=1.12>' -S %s | FileCheck %s --check-prefixes=CHECK,NOOP
; RUN: opt -julia=1.14.0-DEV -passes=CombineMulAdd -S %s | FileCheck %s --check-prefixes=CHECK,NOOP

; the port ran on every function but the optnone one (it is not required), also when it
; has nothing to do
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -julia=1.11 -passes=CombineMulAdd -S %s -o /dev/null
; RUN: env JULIAIR_LEDGER=%t.ledger opt -julia=1.13 -passes=CombineMulAdd -S %s -o /dev/null
; RUN: grep -c 'pass	jl-combine-muladd	julia=1.11.0' %t.ledger | FileCheck --check-prefix=COUNT %s
; RUN: grep -c 'pass	jl-combine-muladd	julia=1.13.0' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 18

; CHECK-LABEL: @fadd_contract(
; COMBINE-NEXT: %m = fmul contract double %a, %b
; NOOP-NEXT: %m = fmul double %a, %b
; CHECK-NEXT: %r = fadd contract double %m, %c
define double @fadd_contract(double %a, double %b, double %c) {
  %m = fmul double %a, %b
  %r = fadd contract double %m, %c
  ret double %r
}

; the flags the multiplication has are kept
; CHECK-LABEL: @fadd_fast_rhs(
; COMBINE-NEXT: %m = fmul nnan contract float %a, %b
; NOOP-NEXT: %m = fmul nnan float %a, %b
; CHECK-NEXT: %r = fadd fast float %c, %m
define float @fadd_fast_rhs(float %a, float %b, float %c) {
  %m = fmul nnan float %a, %b
  %r = fadd fast float %c, %m
  ret float %r
}

; CHECK-LABEL: @fsub_lhs(
; COMBINE-NEXT: %m = fmul contract half %a, %b
; NOOP-NEXT: %m = fmul half %a, %b
define half @fsub_lhs(half %a, half %b, half %c) {
  %m = fmul half %a, %b
  %r = fsub contract half %m, %c
  ret half %r
}

; CHECK-LABEL: @fsub_rhs(
; COMBINE-NEXT: %m = fmul contract double %a, %b
; NOOP-NEXT: %m = fmul double %a, %b
define double @fsub_rhs(double %a, double %b, double %c) {
  %m = fmul double %a, %b
  %r = fsub fast double %c, %m
  ret double %r
}

; CHECK-LABEL: @vector(
; COMBINE-NEXT: %m = fmul contract <4 x float> %a, %b
; NOOP-NEXT: %m = fmul <4 x float> %a, %b
define <4 x float> @vector(<4 x float> %a, <4 x float> %b, <4 x float> %c) {
  %m = fmul <4 x float> %a, %b
  %r = fsub fast <4 x float> %c, %m
  ret <4 x float> %r
}

; CHECK-LABEL: @scalable_vector(
; COMBINE-NEXT: %m = fmul contract <vscale x 2 x double> %a, %b
; NOOP-NEXT: %m = fmul <vscale x 2 x double> %a, %b
define <vscale x 2 x double> @scalable_vector(<vscale x 2 x double> %a, <vscale x 2 x double> %b, <vscale x 2 x double> %c) {
  %m = fmul <vscale x 2 x double> %a, %b
  %r = fadd contract <vscale x 2 x double> %m, %c
  ret <vscale x 2 x double> %r
}

; the multiplication may be in another block
; CHECK-LABEL: @other_block(
; COMBINE: %m = fmul contract double %a, %b
; NOOP: %m = fmul double %a, %b
define double @other_block(double %a, double %b, double %c) {
entry:
  %m = fmul double %a, %b
  br label %next
next:
  %r = fadd contract double %m, %c
  ret double %r
}

; only the first operand is marked when both could be
; CHECK-LABEL: @both_operands(
; COMBINE-NEXT: %m1 = fmul contract double %a, %b
; NOOP-NEXT: %m1 = fmul double %a, %b
; CHECK-NEXT: %m2 = fmul double %c, %d
define double @both_operands(double %a, double %b, double %c, double %d) {
  %m1 = fmul double %a, %b
  %m2 = fmul double %c, %d
  %r = fadd contract double %m1, %m2
  ret double %r
}

; ... but the second is when the first is already contractable
; CHECK-LABEL: @first_contracted(
; CHECK-NEXT: %m1 = fmul contract double %a, %b
; COMBINE-NEXT: %m2 = fmul contract double %c, %d
; NOOP-NEXT: %m2 = fmul double %c, %d
define double @first_contracted(double %a, double %b, double %c, double %d) {
  %m1 = fmul contract double %a, %b
  %m2 = fmul double %c, %d
  %r = fadd contract double %m1, %m2
  ret double %r
}

; ... or has other uses
; CHECK-LABEL: @first_multiuse(
; CHECK-NEXT: %m1 = fmul double %a, %b
; COMBINE-NEXT: %m2 = fmul contract double %c, %d
; NOOP-NEXT: %m2 = fmul double %c, %d
define double @first_multiuse(double %a, double %b, double %c, double %d, ptr %p) {
  %m1 = fmul double %a, %b
  %m2 = fmul double %c, %d
  store double %m1, ptr %p
  %r = fadd contract double %m1, %m2
  ret double %r
}

; a multiplication with another use is not marked, even if that use is the addition
; CHECK-LABEL: @multiuse(
; CHECK-NEXT: %m = fmul double %a, %b
; CHECK-NEXT: %r1 = fadd fast double %m, %c
; CHECK-NEXT: %r2 = fadd fast double %m, %b
define double @multiuse(double %a, double %b, double %c) {
  %m = fmul double %a, %b
  %r1 = fadd fast double %m, %c
  %r2 = fadd fast double %m, %b
  %r = fadd fast double %r1, %r2
  ret double %r
}

; CHECK-LABEL: @same_operand_twice(
; CHECK-NEXT: %m = fmul double %a, %b
define double @same_operand_twice(double %a, double %b) {
  %m = fmul double %a, %b
  %r = fadd contract double %m, %m
  ret double %r
}

; the addition must allow contraction; other fast-math flags don't
; CHECK-LABEL: @no_contract(
; CHECK-NEXT: %m = fmul double %a, %b
; CHECK-NEXT: %r = fadd reassoc nnan ninf nsz arcp afn double %m, %c
define double @no_contract(double %a, double %b, double %c) {
  %m = fmul double %a, %b
  %r = fadd reassoc nnan ninf nsz arcp afn double %m, %c
  ret double %r
}

; only additions and subtractions combine
; CHECK-LABEL: @other_users(
; CHECK-NEXT: %m1 = fmul double %a, %b
; CHECK-NEXT: %n = fneg contract double %m1
; CHECK-NEXT: %m2 = fmul double %a, %c
; CHECK-NEXT: %r = fmul contract double %m2, %n
define double @other_users(double %a, double %b, double %c) {
  %m1 = fmul double %a, %b
  %n = fneg contract double %m1
  %m2 = fmul double %a, %c
  %r = fmul contract double %m2, %n
  ret double %r
}

; ... and only multiplications are marked
; CHECK-LABEL: @add_add(
; CHECK-NEXT: %v = fadd double %a, %b
; CHECK-NEXT: %d = fdiv double %a, %b
; CHECK-NEXT: %r1 = fadd fast double %v, %c
; CHECK-NEXT: %r2 = fadd fast double %d, %c
define double @add_add(double %a, double %b, double %c) {
  %v = fadd double %a, %b
  %d = fdiv double %a, %b
  %r1 = fadd fast double %v, %c
  %r2 = fadd fast double %d, %c
  %r = fmul double %r1, %r2
  ret double %r
}

; CHECK-LABEL: @multiplication_of_call(
; CHECK-NEXT: %m = call contract double @llvm.fmuladd.f64(double %a, double %b, double %c)
define double @multiplication_of_call(double %a, double %b, double %c) {
  %m = call contract double @llvm.fmuladd.f64(double %a, double %b, double %c)
  %r = fadd contract double %m, %c
  ret double %r
}

; the multiplication in a chain of additions
; CHECK-LABEL: @chain(
; COMBINE-NEXT: %m1 = fmul contract double %a, %b
; COMBINE-NEXT: %m2 = fmul contract double %c, %d
; NOOP-NEXT: %m1 = fmul double %a, %b
; NOOP-NEXT: %m2 = fmul double %c, %d
; CHECK-NEXT: %s = fadd contract double %m1, %c
; CHECK-NEXT: %r = fsub contract double %s, %m2
define double @chain(double %a, double %b, double %c, double %d) {
  %m1 = fmul double %a, %b
  %m2 = fmul double %c, %d
  %s = fadd contract double %m1, %c
  %r = fsub contract double %s, %m2
  ret double %r
}

; CHECK-LABEL: @nothing(
define void @nothing() {
  ret void
}

; skipped on optnone functions, like the C++ pass
; CHECK-LABEL: @skipped(
; CHECK-NEXT: %m = fmul double %a, %b
define double @skipped(double %a, double %b, double %c) noinline optnone {
  %m = fmul double %a, %b
  %r = fadd fast double %m, %c
  ret double %r
}

declare double @llvm.fmuladd.f64(double, double, double)
