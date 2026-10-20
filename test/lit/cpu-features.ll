; CPUFeatures folds the calls of `julia.cpu.have_fma.<type>` to constants of the call's
; type, per calling function, and keeps the declarations. These cases decide the same way
; on every Julia version (explicit `+fma`/`-fma` on x86); the two ways of deciding are in
; cpu-features-tokens.ll and cpu-features-subtarget.ll.

; REQUIRES: x86-registered-target
; RUN: rm -rf %t && split-file %s %t
; RUN: opt -passes=CPUFeatures -S %t/main.ll | FileCheck %t/main.ll
; RUN: opt -passes=jl-cpu-features -S %t/main.ll | FileCheck %t/main.ll

; the port ran, once per module
; RUN: env JULIAIR_LEDGER=%t/ledger opt -passes=CPUFeatures -S %t/main.ll -o /dev/null
; RUN: grep -c 'pass	jl-cpu-features	julia=' %t/ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 1

; uses it can't fold are errors, before anything changes (Julia's C++ pass crashes or
; erases the wrong instruction)
; RUN: not opt -passes=CPUFeatures -S %t/noncall.ll 2>&1 | FileCheck --check-prefix=NONCALL %s
; NONCALL: CPUFeaturesError: julia.cpu.have_fma.f64 is used by `@fp = global ptr @julia.cpu.have_fma.f64`; it can only be called
; RUN: not opt -passes=CPUFeatures -S %t/argument.ll 2>&1 | FileCheck --check-prefix=ARGUMENT %s
; ARGUMENT: CPUFeaturesError: julia.cpu.have_fma.f64 is passed as an argument by `call void @g(ptr @julia.cpu.have_fma.f64)` in function f; it can only be called
; RUN: not opt -passes=CPUFeatures -S %t/invoke.ll 2>&1 | FileCheck --check-prefix=INVOKE %s
; INVOKE: CPUFeaturesError: julia.cpu.have_fma.f64 is called with `invoke` in function f, which is not supported
; RUN: not opt -passes=CPUFeatures -S %t/float.ll 2>&1 | FileCheck --check-prefix=FLOAT %s
; FLOAT: CPUFeaturesError: julia.cpu.have_fma.f64 returns float in `%r = call float @julia.cpu.have_fma.f64()` in function f; it must return an integer

; the target can only be given to the constructor, or with jlopt's flags
; RUN: not opt -passes='jl-cpu-features<target-cpu=haswell>' -S %t/main.ll 2>&1 | FileCheck --check-prefix=OPTION %s
; OPTION: option target-cpu can't be given in a pipeline

;--- main.ll
target triple = "x86_64-unknown-linux-gnu"

; CHECK: declare i1 @julia.cpu.have_fma.f64()
; CHECK: declare i8 @julia.cpu.have_fma.f32()
; CHECK: declare i1 @julia.cpu.have_fma.f16(i32)
declare i1 @julia.cpu.have_fma.f64()
declare i8 @julia.cpu.have_fma.f32()
declare i1 @julia.cpu.have_fma.f16(i32)

; CHECK-LABEL: define i1 @with_fma(
; CHECK-NEXT: ret i1 true
define i1 @with_fma() #0 {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; CHECK-LABEL: define i1 @without_fma(
; CHECK-NEXT: ret i1 false
define i1 @without_fma() #1 {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

; a constant of the call's type, for every call
; CHECK-LABEL: define i8 @several(
; CHECK-NEXT: %s = add i8 1, 1
; CHECK-NEXT: %t = add i1 true, true
define i8 @several() #0 {
  %r = call i8 @julia.cpu.have_fma.f32()
  %q = call i8 @julia.cpu.have_fma.f32()
  %s = add i8 %r, %q
  %a = call i1 @julia.cpu.have_fma.f64()
  %b = call i1 @julia.cpu.have_fma.f64()
  %t = add i1 %a, %b
  ret i8 %s
}

; arguments are ignored
; CHECK-LABEL: define i1 @f16(
; CHECK-NEXT: ret i1 false
define i1 @f16() #0 {
  %r = call i1 @julia.cpu.have_fma.f16(i32 1)
  ret i1 %r
}

; the pass is required
; CHECK-LABEL: define i1 @optnone(
; CHECK-NEXT: ret i1 false
define i1 @optnone() #2 {
  %r = call i1 @julia.cpu.have_fma.f64()
  ret i1 %r
}

attributes #0 = { "target-features"="+fma" }
attributes #1 = { "target-features"="-fma" }
attributes #2 = { noinline optnone "target-features"="-fma" }

;--- noncall.ll
target triple = "x86_64-unknown-linux-gnu"
declare i1 @julia.cpu.have_fma.f64()
@fp = global ptr @julia.cpu.have_fma.f64

;--- argument.ll
target triple = "x86_64-unknown-linux-gnu"
declare i1 @julia.cpu.have_fma.f64()
declare void @g(ptr)
define void @f() #0 {
  call void @g(ptr @julia.cpu.have_fma.f64)
  ret void
}
attributes #0 = { "target-features"="+fma" }

;--- invoke.ll
target triple = "x86_64-unknown-linux-gnu"
declare i1 @julia.cpu.have_fma.f64()
declare i32 @__gxx_personality_v0(...)
define i1 @f() #0 personality ptr @__gxx_personality_v0 {
  %r = invoke i1 @julia.cpu.have_fma.f64() to label %ok unwind label %bad
ok:
  ret i1 %r
bad:
  %lp = landingpad { ptr, i32 } cleanup
  ret i1 false
}
attributes #0 = { "target-features"="+fma" }

;--- float.ll
target triple = "x86_64-unknown-linux-gnu"
declare float @julia.cpu.have_fma.f64()
define float @f() #0 {
  %r = call float @julia.cpu.have_fma.f64()
  ret float %r
}
attributes #0 = { "target-features"="+fma" }
