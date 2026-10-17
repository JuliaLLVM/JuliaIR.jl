; Which functions DemoteFloat16 demotes, per Julia version and policy. Julia 1.10 and
; 1.11 read the target features (and the presence of `julia.hasfp16`/`julia.hasbf16`),
; 1.12 and later the value of those attributes and the target triple; explicit
; `fp16`/`bf16` policies override both. The host's CPU features are never used.

; RUN: opt -julia=1.12 -passes='function(DemoteFloat16)' -S %s | FileCheck %s --check-prefixes=CHECK,V112
; RUN: opt -julia=1.14.0-DEV -mtriple=powerpc64le-unknown-linux-gnu -passes='function(DemoteFloat16)' -S %s | FileCheck %s --check-prefixes=CHECK,V112PPC
; RUN: opt -julia=1.12 -mtriple=ppu-unknown-linux-gnu -passes='function(DemoteFloat16)' -S %s | FileCheck %s --check-prefixes=CHECK,V112PPC
; RUN: opt -julia=1.11 -passes='function(DemoteFloat16)' -S %s | FileCheck %s --check-prefixes=CHECK,V111
; RUN: opt -julia=1.11 -mtriple=aarch64-unknown-linux-gnu -passes='function(DemoteFloat16)' -S %s | FileCheck %s --check-prefixes=CHECK,V111ARM
; RUN: opt -julia=1.10 -passes='function(DemoteFloat16)' -S %s | FileCheck %s --check-prefixes=CHECK,V110
; RUN: opt -julia=1.13 -passes='function(jl-demote-float16<fp16=keep;bf16=keep>)' -S %s | FileCheck %s --check-prefixes=CHECK,KEEP
; RUN: opt -julia=1.12 -passes='function(jl-demote-float16<fp16=demote;bf16=demote>)' -S %s | FileCheck %s --check-prefixes=CHECK,DEMOTE
; RUN: opt -passes='function(jl-demote-float16<julia=1.10;bf16=demote>)' -S %s | FileCheck %s --check-prefixes=CHECK,BF16

; the port ran, also on optnone functions (it is required)
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -julia=1.12 -passes=DemoteFloat16 -S %s -o /dev/null
; RUN: grep -c 'pass	jl-demote-float16	julia=1.12.0' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 13

target triple = "x86_64-unknown-linux-gnu"

; CHECK-LABEL: @h_plain(
; V112-NEXT: %r = fadd half %a, %b
; V112PPC-NEXT: fpext half %a to float
; V112PPC: %r = fptrunc float %{{[0-9]+}} to half
; V111-NEXT: fpext half %a to float
; V111: %r = fptrunc float %{{[0-9]+}} to half
; V111ARM-NEXT: fpext half %a to float
; V111ARM: %r = fptrunc float %{{[0-9]+}} to half
; V110-NEXT: fpext half %a to float
; V110: %r = fptrunc float %{{[0-9]+}} to half
; KEEP-NEXT: %r = fadd half %a, %b
; DEMOTE-NEXT: fpext half %a to float
; DEMOTE: %r = fptrunc float %{{[0-9]+}} to half
; BF16-NEXT: fpext half %a to float
; BF16: %r = fptrunc float %{{[0-9]+}} to half
define half @h_plain(half %a, half %b) {
  %r = fadd half %a, %b
  ret half %r
}

; CHECK-LABEL: @h_avx512fp16(
; V112-NEXT: %r = fadd half %a, %b
; V112PPC-NEXT: fpext half %a to float
; V112PPC: %r = fptrunc float %{{[0-9]+}} to half
; V111-NEXT: %r = fadd half %a, %b
; V111ARM-NEXT: fpext half %a to float
; V111ARM: %r = fptrunc float %{{[0-9]+}} to half
; V110-NEXT: %r = fadd half %a, %b
; KEEP-NEXT: %r = fadd half %a, %b
; DEMOTE-NEXT: fpext half %a to float
; DEMOTE: %r = fptrunc float %{{[0-9]+}} to half
; BF16-NEXT: %r = fadd half %a, %b
define half @h_avx512fp16(half %a, half %b) #0 {
  %r = fadd half %a, %b
  ret half %r
}

; CHECK-LABEL: @h_fullfp16(
; V112-NEXT: %r = fadd half %a, %b
; V112PPC-NEXT: fpext half %a to float
; V112PPC: %r = fptrunc float %{{[0-9]+}} to half
; V111-NEXT: fpext half %a to float
; V111: %r = fptrunc float %{{[0-9]+}} to half
; V111ARM-NEXT: %r = fadd half %a, %b
; V110-NEXT: fpext half %a to float
; V110: %r = fptrunc float %{{[0-9]+}} to half
; KEEP-NEXT: %r = fadd half %a, %b
; DEMOTE-NEXT: fpext half %a to float
; DEMOTE: %r = fptrunc float %{{[0-9]+}} to half
; BF16-NEXT: fpext half %a to float
; BF16: %r = fptrunc float %{{[0-9]+}} to half
define half @h_fullfp16(half %a, half %b) #1 {
  %r = fadd half %a, %b
  ret half %r
}

; CHECK-LABEL: @h_hasfp16_true(
; V112-NEXT: %r = fadd half %a, %b
; V112PPC-NEXT: %r = fadd half %a, %b
; V111-NEXT: %r = fadd half %a, %b
; V111ARM-NEXT: %r = fadd half %a, %b
; V110-NEXT: %r = fadd half %a, %b
; KEEP-NEXT: %r = fadd half %a, %b
; DEMOTE-NEXT: fpext half %a to float
; DEMOTE: %r = fptrunc float %{{[0-9]+}} to half
; BF16-NEXT: %r = fadd half %a, %b
define half @h_hasfp16_true(half %a, half %b) #2 {
  %r = fadd half %a, %b
  ret half %r
}

; CHECK-LABEL: @h_hasfp16_false(
; V112-NEXT: fpext half %a to float
; V112: %r = fptrunc float %{{[0-9]+}} to half
; V112PPC-NEXT: fpext half %a to float
; V112PPC: %r = fptrunc float %{{[0-9]+}} to half
; V111-NEXT: %r = fadd half %a, %b
; V111ARM-NEXT: %r = fadd half %a, %b
; V110-NEXT: %r = fadd half %a, %b
; KEEP-NEXT: %r = fadd half %a, %b
; DEMOTE-NEXT: fpext half %a to float
; DEMOTE: %r = fptrunc float %{{[0-9]+}} to half
; BF16-NEXT: %r = fadd half %a, %b
define half @h_hasfp16_false(half %a, half %b) #3 {
  %r = fadd half %a, %b
  ret half %r
}

; CHECK-LABEL: @h_hasfp16_empty(
; V112-NEXT: fpext half %a to float
; V112: %r = fptrunc float %{{[0-9]+}} to half
; V112PPC-NEXT: fpext half %a to float
; V112PPC: %r = fptrunc float %{{[0-9]+}} to half
; V111-NEXT: %r = fadd half %a, %b
; V111ARM-NEXT: %r = fadd half %a, %b
; V110-NEXT: %r = fadd half %a, %b
; KEEP-NEXT: %r = fadd half %a, %b
; DEMOTE-NEXT: fpext half %a to float
; DEMOTE: %r = fptrunc float %{{[0-9]+}} to half
; BF16-NEXT: %r = fadd half %a, %b
define half @h_hasfp16_empty(half %a, half %b) #4 {
  %r = fadd half %a, %b
  ret half %r
}

; CHECK-LABEL: @b_plain(
; V112-NEXT: %r = fadd bfloat %a, %b
; V112PPC-NEXT: %r = fadd bfloat %a, %b
; V111-NEXT: fpext bfloat %a to float
; V111: %r = fptrunc float %{{[0-9]+}} to bfloat
; V111ARM-NEXT: fpext bfloat %a to float
; V111ARM: %r = fptrunc float %{{[0-9]+}} to bfloat
; V110-NEXT: %r = fadd bfloat %a, %b
; KEEP-NEXT: %r = fadd bfloat %a, %b
; DEMOTE-NEXT: fpext bfloat %a to float
; DEMOTE: %r = fptrunc float %{{[0-9]+}} to bfloat
; BF16-NEXT: fpext bfloat %a to float
; BF16: %r = fptrunc float %{{[0-9]+}} to bfloat
define bfloat @b_plain(bfloat %a, bfloat %b) {
  %r = fadd bfloat %a, %b
  ret bfloat %r
}

; CHECK-LABEL: @b_hasbf16_true(
; V112-NEXT: %r = fadd bfloat %a, %b
; V112PPC-NEXT: %r = fadd bfloat %a, %b
; V111-NEXT: %r = fadd bfloat %a, %b
; V111ARM-NEXT: %r = fadd bfloat %a, %b
; V110-NEXT: %r = fadd bfloat %a, %b
; KEEP-NEXT: %r = fadd bfloat %a, %b
; DEMOTE-NEXT: fpext bfloat %a to float
; DEMOTE: %r = fptrunc float %{{[0-9]+}} to bfloat
; BF16-NEXT: fpext bfloat %a to float
; BF16: %r = fptrunc float %{{[0-9]+}} to bfloat
define bfloat @b_hasbf16_true(bfloat %a, bfloat %b) #5 {
  %r = fadd bfloat %a, %b
  ret bfloat %r
}

; CHECK-LABEL: @b_hasbf16_false(
; V112-NEXT: fpext bfloat %a to float
; V112: %r = fptrunc float %{{[0-9]+}} to bfloat
; V112PPC-NEXT: fpext bfloat %a to float
; V112PPC: %r = fptrunc float %{{[0-9]+}} to bfloat
; V111-NEXT: %r = fadd bfloat %a, %b
; V111ARM-NEXT: %r = fadd bfloat %a, %b
; V110-NEXT: %r = fadd bfloat %a, %b
; KEEP-NEXT: %r = fadd bfloat %a, %b
; DEMOTE-NEXT: fpext bfloat %a to float
; DEMOTE: %r = fptrunc float %{{[0-9]+}} to bfloat
; BF16-NEXT: fpext bfloat %a to float
; BF16: %r = fptrunc float %{{[0-9]+}} to bfloat
define bfloat @b_hasbf16_false(bfloat %a, bfloat %b) #6 {
  %r = fadd bfloat %a, %b
  ret bfloat %r
}

; every operation, on scalars and vectors, keeping names, flags and metadata
; DEMOTE-LABEL: @ops(
; DEMOTE-NEXT: %1 = fpext half %a to float
; DEMOTE-NEXT: %2 = fneg nnan float %1, !foo !0
; DEMOTE-NEXT: %neg = fptrunc float %2 to half{{$}}
; DEMOTE-NEXT: %3 = fpext half %neg to float
; DEMOTE-NEXT: %4 = fpext half %b to float
; DEMOTE-NEXT: %5 = fsub float %3, %4
; DEMOTE-NEXT: %sub = fptrunc float %5 to half
; DEMOTE: %mul = fptrunc float
; DEMOTE: %div = fptrunc float
; DEMOTE: %rem = fptrunc float
; DEMOTE: fcmp contract olt float %{{[0-9]+}}, %{{[0-9]+}}
; DEMOTE: %vec = fptrunc <2 x float> %{{[0-9]+}} to <2 x half>
; DEMOTE: %scalable = fptrunc <vscale x 2 x float> %{{[0-9]+}} to <vscale x 2 x half>
define i1 @ops(half %a, half %b, <2 x half> %v, <vscale x 2 x half> %s) {
  %neg = fneg nnan half %a, !foo !0
  %sub = fsub half %neg, %b
  %mul = fmul half %sub, %b
  %div = fdiv half %mul, %b
  %rem = frem half %div, %b
  %cmp = fcmp contract olt half %rem, %a
  %vec = fadd <2 x half> %v, %v
  %scalable = fadd <vscale x 2 x half> %s, %s
  ret i1 %cmp
}

; constant operations are folded (the C++ pass treats the folded constant as an
; instruction); arithmetic with all fast-math flags is left alone
; DEMOTE-LABEL: @special(
; DEMOTE-NEXT: %fast = fmul fast half %a, {{0xH4200|3.000000e\+00}}
; DEMOTE-NEXT: ret half %fast
define half @special(half %a) {
  %c = fadd half 0xH3C00, 0xH4000
  %fast = fmul fast half %a, %c
  ret half %fast
}

; not skipped on optnone functions
; DEMOTE-LABEL: @skipped(
; DEMOTE-NEXT: fpext half %a to float
define half @skipped(half %a) noinline optnone {
  %r = fadd half %a, %a
  ret half %r
}

; other operations on 16-bit values are not demoted
; DEMOTE-LABEL: @others(
; DEMOTE-NEXT: %r = call half @llvm.fma.f16(half %a, half %a, half %a)
; DEMOTE-NEXT: %c = fptrunc float %f to half
; DEMOTE-NEXT: ret half %r
declare half @llvm.fma.f16(half, half, half)
define half @others(half %a, float %f) {
  %r = call half @llvm.fma.f16(half %a, half %a, half %a)
  %c = fptrunc float %f to half
  ret half %r
}

attributes #0 = { "target-features"="+avx512fp16" }
attributes #1 = { "target-features"="+fullfp16" }
attributes #2 = { "julia.hasfp16"="true" }
attributes #3 = { "julia.hasfp16"="false" }
attributes #4 = { "julia.hasfp16" }
attributes #5 = { "julia.hasbf16"="true" }
attributes #6 = { "julia.hasbf16"="false" }

!0 = !{!"foo"}
