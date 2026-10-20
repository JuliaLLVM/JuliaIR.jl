; Up to Julia 1.13, CPUFeatures decides whether a function has FMA by looking for the
; features that provide it in its `target-features` (or, without that attribute, in the
; JIT's feature string, here given with -mattr): the first one found decides, implied
; features don't count, and the CPU isn't consulted. AArch64 always has FMA, other
; architectures than x86 and 32-bit ARM never. `julia.cpu.supports` doesn't exist yet.

; UNSUPPORTED: julia-ge-1.14
; RUN: rm -rf %t && split-file %s %t
; RUN: opt -passes=CPUFeatures -S %t/x86.ll | FileCheck %t/x86.ll
; RUN: opt -passes=CPUFeatures -S %t/aarch64.ll | FileCheck %t/aarch64.ll
; RUN: opt -passes=CPUFeatures -S %t/arm.ll | FileCheck %t/arm.ll

; features are not trimmed; from LLVM 22, the verifier rejects such features
; RUN: %if !llvm-ge-22 %{ opt -passes=CPUFeatures -S %t/space.ll | FileCheck %t/space.ll %}

; other spellings of x86
; RUN: opt -passes=CPUFeatures -S %t/i686.ll | FileCheck %t/i686.ll
; RUN: opt -passes=CPUFeatures -S %t/amd64.ll | FileCheck %t/amd64.ll
; RUN: opt -passes=CPUFeatures -S %t/x86_64h.ll | FileCheck %t/x86_64h.ll

; other architectures never have FMA; Thumb is not ARM here
; RUN: opt -passes=CPUFeatures -S %t/thumb.ll 2>%t/stderr | FileCheck %t/thumb.ll
; RUN: opt -passes=CPUFeatures -S %t/riscv.ll 2>%t/stderr | FileCheck %t/riscv.ll
; RUN: opt -passes=CPUFeatures -S %t/ppc.ll 2>%t/stderr | FileCheck %t/ppc.ll
; RUN: opt -passes=CPUFeatures -S %t/nvptx.ll 2>%t/stderr | FileCheck %t/nvptx.ll
; RUN: opt -passes=CPUFeatures -S %t/none.ll | FileCheck %t/none.ll

; without target-features, the JIT's feature string (the options) is searched; the CPU
; doesn't matter. Like opt, jlopt also appends the options to the target-features that a
; function has.
; RUN: opt -mattr=+avx2,+fma -passes=CPUFeatures -S %t/jit.ll | FileCheck %t/jit.ll --check-prefixes=CHECK,FMA
; RUN: opt -mattr=+fma4 -passes=CPUFeatures -S %t/jit.ll | FileCheck %t/jit.ll --check-prefixes=CHECK,FMA
; RUN: opt -mattr=-fma,+avx512f -passes=CPUFeatures -S %t/jit.ll | FileCheck %t/jit.ll --check-prefixes=CHECK,NOFMA
; RUN: opt -mcpu=haswell -mattr= -passes=CPUFeatures -S %t/jit.ll | FileCheck %t/jit.ll --check-prefixes=CHECK,NOFMA

;--- x86.ll
target triple = "x86_64-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f64()
declare i1 @julia.cpu.have_fma.f32()
declare i1 @julia.cpu.have_fma.f16()
declare i1 @julia.cpu.supports.avx2()

; CHECK-LABEL: @fma(
; CHECK-NEXT: ret i1 true
define i1 @fma() "target-features"="+fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; CHECK-LABEL: @fma4(
; CHECK-NEXT: ret i1 true
define i1 @fma4() "target-features"="+sse2,+fma4" {
  %r = call i1 @julia.cpu.have_fma.f32()
  ret i1 %r
}

; the first setting decides
; CHECK-LABEL: @fma_then_nofma(
; CHECK-NEXT: ret i1 true
define i1 @fma_then_nofma() "target-features"="+fma,-fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; CHECK-LABEL: @nofma_then_fma(
; CHECK-NEXT: ret i1 true
define i1 @nofma_then_fma() "target-features"="-fma,+fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; implied features don't count
; CHECK-LABEL: @avx512f(
; CHECK-NEXT: ret i1 false
define i1 @avx512f() "target-features"="+avx512f" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; an empty attribute is no feature (not the JIT's), and the CPU doesn't matter
; CHECK-LABEL: @empty(
; CHECK-NEXT: ret i1 false
define i1 @empty() "target-cpu"="haswell" "target-features"="" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; CHECK-LABEL: @f16(
; CHECK-NEXT: ret i1 false
define i1 @f16() "target-features"="+fma" {
  %r = call i1 @julia.cpu.have_fma.f16()
  ret i1 %r
}

; CHECK-LABEL: @supports(
; CHECK-NEXT: %r = call i1 @julia.cpu.supports.avx2()
define i1 @supports() "target-cpu"="haswell" {
  %r = call i1 @julia.cpu.supports.avx2()
  ret i1 %r
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

;--- amd64.ll
target triple = "amd64-unknown-freebsd"

declare i1 @julia.cpu.have_fma.f64()

; CHECK-LABEL: @fma(
; CHECK-NEXT: ret i1 true
define i1 @fma() "target-features"="+fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- x86_64h.ll
target triple = "x86_64h-apple-darwin"

declare i1 @julia.cpu.have_fma.f64()

; CHECK-LABEL: @fma(
; CHECK-NEXT: ret i1 true
define i1 @fma() "target-features"="+fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- space.ll
target triple = "x86_64-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f64()

; CHECK-LABEL: @space(
; CHECK-NEXT: ret i1 false
define i1 @space() "target-features"="+sse2, +fma" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- aarch64.ll
target triple = "aarch64-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f64()
declare i1 @julia.cpu.have_fma.f32()
declare i1 @julia.cpu.have_fma.f16()

; CHECK-LABEL: @f64(
; CHECK-NEXT: ret i1 true
define i1 @f64() "target-features"="" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; CHECK-LABEL: @f32(
; CHECK-NEXT: ret i1 true
define i1 @f32() {
  %r = call i1 @julia.cpu.have_fma.f32()
  ret i1 %r
}

; CHECK-LABEL: @f16(
; CHECK-NEXT: ret i1 false
define i1 @f16() "target-features"="+fullfp16" {
  %r = call i1 @julia.cpu.have_fma.f16()
  ret i1 %r
}

;--- arm.ll
target triple = "armv7l-unknown-linux-gnueabihf"

declare i1 @julia.cpu.have_fma.f64()
declare i1 @julia.cpu.have_fma.f32()

; CHECK-LABEL: @vfp4(
; CHECK-NEXT: ret i1 true
define i1 @vfp4() "target-features"="+neon,+vfp4" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; single precision only
; CHECK-LABEL: @vfp4sp_f64(
; CHECK-NEXT: ret i1 false
define i1 @vfp4sp_f64() "target-features"="+vfp4sp,+vfp4" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; CHECK-LABEL: @vfp4sp_f32(
; CHECK-NEXT: ret i1 true
define i1 @vfp4sp_f32() "target-features"="+vfp4sp" {
  %r = call i1 @julia.cpu.have_fma.f32()
  ret i1 %r
}

; x86's features don't count
; CHECK-LABEL: @x86_fma(
; CHECK-NEXT: ret i1 false
define i1 @x86_fma() "target-features"="+fma" {
  %r = call i1 @julia.cpu.have_fma.f32()
  ret i1 %r
}

;--- thumb.ll
target triple = "thumbv7-unknown-linux-gnueabihf"

declare i1 @julia.cpu.have_fma.f64()

; CHECK-LABEL: @f(
; CHECK-NEXT: ret i1 false
define i1 @f() "target-features"="+fma,+vfp4,+d" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- riscv.ll
target triple = "riscv64-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f64()

; CHECK-LABEL: @f(
; CHECK-NEXT: ret i1 false
define i1 @f() "target-features"="+fma,+vfp4,+d" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- ppc.ll
target triple = "powerpc64le-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f64()

; CHECK-LABEL: @f(
; CHECK-NEXT: ret i1 false
define i1 @f() "target-features"="+fma,+vfp4,+d" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- nvptx.ll
target triple = "nvptx64-nvidia-cuda"

declare i1 @julia.cpu.have_fma.f64()

; CHECK-LABEL: @f(
; CHECK-NEXT: ret i1 false
define i1 @f() "target-features"="+fma,+vfp4,+d" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- none.ll

declare i1 @julia.cpu.have_fma.f64()

; CHECK-LABEL: @f(
; CHECK-NEXT: ret i1 false
define i1 @f() "target-features"="+fma,+vfp4,+d" {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

;--- jit.ll
target triple = "x86_64-unknown-linux-gnu"

declare i1 @julia.cpu.have_fma.f32()

; CHECK-LABEL: @jit(
; FMA-NEXT: ret i1 true
; NOFMA-NEXT: ret i1 false
define i1 @jit() {
  %r = call i1 @julia.cpu.have_fma.f32()
  ret i1 %r
}

; CHECK-LABEL: @attribute(
; FMA-NEXT: ret i1 true
; NOFMA-NEXT: ret i1 false
define i1 @attribute() "target-features"="-fma" {
  %r = call i1 @julia.cpu.have_fma.f32()
  ret i1 %r
}
