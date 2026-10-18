; From Julia 1.14 on, CPUFeatures asks LLVM's subtarget tables whether a function's
; target has a feature: features imply others, the last setting of a feature wins, and
; CPUs have features. The target is the function's `target-cpu` and `target-features`,
; each where present, and otherwise the target machine's (here given with -mcpu and
; -mattr; by name, as in opt, there is none: the generic CPU). Triples whose target
; isn't registered have no features.

; REQUIRES: julia-ge-1.14, x86-registered-target
; RUN: rm -rf %t && split-file %s %t
; RUN: opt -passes=CPUFeatures -S %t/x86.ll | FileCheck %t/x86.ll
; RUN: opt -passes=CPUFeatures -S %t/supports.ll | FileCheck %t/supports.ll
; RUN: opt -passes=CPUFeatures -S %t/i686.ll | FileCheck %t/i686.ll

; the options are the target machine's CPU and features, which attributes replace
; RUN: opt -passes=CPUFeatures -S %t/options.ll | FileCheck %t/options.ll --check-prefix=NONE
; RUN: opt -mcpu=haswell -passes=CPUFeatures -S %t/options.ll | FileCheck %t/options.ll --check-prefix=HASWELL
; RUN: opt -mattr=+fma -passes=CPUFeatures -S %t/options.ll | FileCheck %t/options.ll --check-prefix=FMA

; without a triple, the options are for the JIT's (have_fma looks at the module's)
; RUN: opt -passes=CPUFeatures -S %t/notriple.ll | FileCheck %t/notriple.ll --check-prefix=NONE
; RUN: %if x86_64 %{ opt -mattr=+fma -passes=CPUFeatures -S %t/notriple.ll | FileCheck %t/notriple.ll --check-prefix=FMA %}

; AArch64 always has FMA, if its target is registered
; RUN: %if aarch64-registered-target %{ opt -passes=CPUFeatures -S %t/aarch64.ll | FileCheck %t/aarch64.ll --check-prefix=REGISTERED %}
; RUN: %if !aarch64-registered-target %{ opt -passes=CPUFeatures -S %t/aarch64.ll 2>%t/stderr | FileCheck %t/aarch64.ll --check-prefix=MISSING %}
; RUN: %if riscv-registered-target %{ opt -passes=CPUFeatures -S %t/riscv.ll | FileCheck %t/riscv.ll --check-prefix=REGISTERED %}
; RUN: %if !riscv-registered-target %{ opt -passes=CPUFeatures -S %t/riscv.ll 2>%t/stderr | FileCheck %t/riscv.ll --check-prefix=MISSING %}

;--- x86.ll
target triple = "x86_64-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f64()
declare i1 @julia.cpu.have_fma.f32()
declare i1 @julia.cpu.have_fma.f16()

; CHECK-LABEL: @fma(
; CHECK-NEXT: ret i1 true
define i1 @fma() "target-features"="+fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; CHECK-LABEL: @fma4(
; CHECK-NEXT: ret i1 true
define i1 @fma4() "target-features"="+fma4" {
  %r = call i1 @julia.cpu.have_fma.f32()
  ret i1 %r
}

; the last setting wins
; CHECK-LABEL: @fma_then_nofma(
; CHECK-NEXT: ret i1 false
define i1 @fma_then_nofma() "target-features"="+fma,-fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; implied features count
; CHECK-LABEL: @avx512f(
; CHECK-NEXT: ret i1 true
define i1 @avx512f() "target-features"="+avx512f" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; and so do the CPU's
; CHECK-LABEL: @haswell(
; CHECK-NEXT: ret i1 true
define i1 @haswell() "target-cpu"="haswell" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; CHECK-LABEL: @haswell_nofma(
; CHECK-NEXT: ret i1 false
define i1 @haswell_nofma() "target-cpu"="haswell" "target-features"="-fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; the generic CPU has no FMA
; CHECK-LABEL: @generic(
; CHECK-NEXT: ret i1 false
define i1 @generic() {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; CHECK-LABEL: @f16(
; CHECK-NEXT: ret i1 false
define i1 @f16() "target-features"="+fma" {
  %r = call i1 @julia.cpu.have_fma.f16()
  ret i1 %r
}

;--- supports.ll
target triple = "x86_64-unknown-linux-gnu"

declare i1 @"julia.cpu.supports.avx2,fma"()
declare i1 @julia.cpu.supports.avx()
declare i1 @julia.cpu.supports.avx2()
declare i1 @julia.cpu.supports.sse2()
declare i1 @julia.cpu.supports.nosuchfeature()
declare i1 @julia.cpu.supports.()
declare i1 @"julia.cpu.supports.avx2,"()
declare i1 @"julia.cpu.supports.+avx2"()
declare i1 @julia.cpu.supports.haswell()

; every feature of the list
; CHECK-LABEL: @list(
; CHECK-NEXT: ret i1 true
define i1 @list() "target-cpu"="haswell" {
  %r = call i1 @"julia.cpu.supports.avx2,fma"()
  ret i1 %r
}

; CHECK-LABEL: @list_missing(
; CHECK-NEXT: ret i1 false
define i1 @list_missing() "target-features"="+avx2" {
  %r = call i1 @"julia.cpu.supports.avx2,fma"()
  ret i1 %r
}

; implied, and disabled with what it implies
; CHECK-LABEL: @implied(
; CHECK-NEXT: ret i1 true
define i1 @implied() "target-features"="+avx2" {
  %r = call i1 @julia.cpu.supports.avx()
  ret i1 %r
}

; CHECK-LABEL: @implied_disabled(
; CHECK-NEXT: ret i1 false
define i1 @implied_disabled() "target-features"="+avx2,-avx" {
  %r = call i1 @julia.cpu.supports.avx2()
  ret i1 %r
}

; the triple's baseline
; CHECK-LABEL: @baseline(
; CHECK-NEXT: ret i1 true
define i1 @baseline() {
  %r = call i1 @julia.cpu.supports.sse2()
  ret i1 %r
}

; names that aren't features are never supported
; CHECK-LABEL: @unknown(
; CHECK-NEXT: %r = and i1 false, false
; CHECK-NEXT: %s = and i1 %r, false
; CHECK-NEXT: %t = and i1 %s, false
; CHECK-NEXT: %u = and i1 %t, false
define i1 @unknown() "target-cpu"="haswell" {
  %a = call i1 @julia.cpu.supports.nosuchfeature()
  %b = call i1 @julia.cpu.supports.()
  %r = and i1 %a, %b
  %c = call i1 @"julia.cpu.supports.avx2,"()
  %s = and i1 %r, %c
  %d = call i1 @"julia.cpu.supports.+avx2"()
  %t = and i1 %s, %d
  %e = call i1 @julia.cpu.supports.haswell()
  %u = and i1 %t, %e
  ret i1 %u
}

;--- i686.ll
target triple = "i686-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f64()

; CHECK-LABEL: @fma(
; CHECK-NEXT: ret i1 true
define i1 @fma() "target-features"="+fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- options.ll
target triple = "x86_64-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f64()

; NONE-LABEL: @none(
; NONE-NEXT: ret i1 false
; HASWELL-LABEL: @none(
; HASWELL-NEXT: ret i1 true
; FMA-LABEL: @none(
; FMA-NEXT: ret i1 true
define i1 @none() {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; the attribute replaces the features, the CPU stays
; NONE-LABEL: @features(
; NONE-NEXT: ret i1 false
; HASWELL-LABEL: @features(
; HASWELL-NEXT: ret i1 false
; FMA-LABEL: @features(
; FMA-NEXT: ret i1 false
define i1 @features() "target-features"="-fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; NONE-LABEL: @features_avx2(
; NONE-NEXT: ret i1 false
; HASWELL-LABEL: @features_avx2(
; HASWELL-NEXT: ret i1 true
; FMA-LABEL: @features_avx2(
; FMA-NEXT: ret i1 false
define i1 @features_avx2() "target-features"="+avx2" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; the attribute replaces the CPU, the features stay
; NONE-LABEL: @cpu(
; NONE-NEXT: ret i1 false
; HASWELL-LABEL: @cpu(
; HASWELL-NEXT: ret i1 false
; FMA-LABEL: @cpu(
; FMA-NEXT: ret i1 true
define i1 @cpu() "target-cpu"="x86-64" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- notriple.ll
declare i1 @julia.cpu.have_fma.f64()
declare i1 @julia.cpu.supports.fma()

; NONE-LABEL: @have_fma(
; NONE-NEXT: ret i1 false
; FMA-LABEL: @have_fma(
; FMA-NEXT: ret i1 false
define i1 @have_fma() {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; NONE-LABEL: @supports(
; NONE-NEXT: ret i1 false
; FMA-LABEL: @supports(
; FMA-NEXT: ret i1 true
define i1 @supports() {
  %r = call i1 @julia.cpu.supports.fma()
  ret i1 %r
}

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
