; From Julia 1.14 on, CPUFeatures only answers for triples whose target is registered
; with LLVM (Julia's x86-64 library has no AArch64 or RISC-V target, for example); for
; the others, every answer is false. AArch64 always has FMA, RISC-V has it for f32 with
; +f and for f64 with +d.

; REQUIRES: julia-ge-1.14
; RUN: rm -rf %t && split-file %s %t
; RUN: %if aarch64-registered-target %{ opt -passes=CPUFeatures -S %t/aarch64.ll | FileCheck %t/aarch64.ll --check-prefix=REGISTERED %}
; RUN: %if !aarch64-registered-target %{ opt -passes=CPUFeatures -S %t/aarch64.ll 2>%t/stderr | FileCheck %t/aarch64.ll --check-prefix=MISSING %}
; RUN: %if riscv-registered-target %{ opt -passes=CPUFeatures -S %t/riscv.ll | FileCheck %t/riscv.ll --check-prefix=REGISTERED %}
; RUN: %if !riscv-registered-target %{ opt -passes=CPUFeatures -S %t/riscv.ll 2>%t/stderr | FileCheck %t/riscv.ll --check-prefix=MISSING %}

;--- aarch64.ll
target triple = "aarch64-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f64()

; REGISTERED-LABEL: @f(
; REGISTERED-NEXT: ret i1 true
; MISSING-LABEL: @f(
; MISSING-NEXT: ret i1 false
define i1 @f() {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- riscv.ll
target triple = "riscv64-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f64()
declare i1 @julia.cpu.have_fma.f32()

; REGISTERED-LABEL: @f64(
; REGISTERED-NEXT: ret i1 true
; MISSING-LABEL: @f64(
; MISSING-NEXT: ret i1 false
define i1 @f64() "target-features"="+d" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; REGISTERED-LABEL: @f32(
; REGISTERED-NEXT: ret i1 true
; MISSING-LABEL: @f32(
; MISSING-NEXT: ret i1 false
define i1 @f32() "target-features"="+f" {
  %r = call i1 @julia.cpu.have_fma.f32()
  ret i1 %r
}

; REGISTERED-LABEL: @f64_single(
; REGISTERED-NEXT: ret i1 false
; MISSING-LABEL: @f64_single(
; MISSING-NEXT: ret i1 false
define i1 @f64_single() "target-features"="+f" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}
