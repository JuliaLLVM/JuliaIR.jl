; ExpandAtomicModify turns the `julia.atomicmodify` calls of Julia 1.13 and later into an
; `atomicrmw` when the modify function is a single operation that `atomicrmw` supports,
; and otherwise into a compare-exchange loop around a call of the function.

; REQUIRES: julia-ge-1.13
; RUN: opt -passes=ExpandAtomicModify -S %s | FileCheck %s
; RUN: opt -passes='function(jl-expand-atomic-modify)' -S %s | FileCheck %s

; the port ran on every function but the optnone one (it is not required)
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=ExpandAtomicModify -S %s -o /dev/null
; RUN: grep -c 'pass	jl-expand-atomic-modify	julia=' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 95

declare {i8, i8} @julia.atomicmodify.i8(ptr, ptr, i8, i8, ...)
declare {i32, i32} @julia.atomicmodify.i32(ptr, ptr, i8, i8, ...)
declare {i64, i64} @julia.atomicmodify.i64(ptr, ptr, i8, i8, ...)
declare {float, float} @julia.atomicmodify.f32(ptr, ptr, i8, i8, ...)
declare {double, double} @julia.atomicmodify.f64(ptr, ptr, i8, i8, ...)
declare {ptr, ptr} @julia.atomicmodify.p0(ptr, ptr, i8, i8, ...)

declare double @llvm.minnum.f64(double, double)
declare double @llvm.maxnum.f64(double, double)
declare i64 @llvm.smax.i64(i64, i64)
declare i64 @llvm.smin.i64(i64, i64)
declare i64 @llvm.umax.i64(i64, i64)
declare i64 @llvm.umin.i64(i64, i64)
declare i64 @llvm.usub.sat.i64(i64, i64)
declare i64 @llvm.fshl.i64(i64, i64, i64)

; the operations
define i64 @add(i64 %x, i64 %y) {
  %z = add i64 %x, %y
  ret i64 %z
}
define i64 @add_swapped(i64 %x, i64 %y) {
  %z = add i64 %y, %x
  ret i64 %z
}
define i64 @sub(i64 %x, i64 %y) {
  %z = sub i64 %x, %y
  ret i64 %z
}
define i64 @sub_swapped(i64 %x, i64 %y) {
  %z = sub i64 %y, %x
  ret i64 %z
}
define i64 @and(i64 %x, i64 %y) {
  %z = and i64 %x, %y
  ret i64 %z
}
define i64 @or(i64 %x, i64 %y) {
  %z = or i64 %y, %x
  ret i64 %z
}
define i64 @xor(i64 %x, i64 %y) {
  %z = xor i64 %x, %y
  ret i64 %z
}
define i64 @nand(i64 %x, i64 %y) {
  %a = and i64 %y, %x
  %z = xor i64 %a, -1
  ret i64 %z
}
define i64 @mul(i64 %x, i64 %y) {
  %z = mul i64 %x, %y
  ret i64 %z
}
define i64 @second(i64 %x, i64 %y) {
  ret i64 %y
}
define i64 @identity(i64 %x, i64 %y) {
  ret i64 %x
}
define i64 @smax(i64 %x, i64 %y) {
  %z = call i64 @llvm.smax.i64(i64 %y, i64 %x)
  ret i64 %z
}
define i64 @smin(i64 %x, i64 %y) {
  %z = call i64 @llvm.smin.i64(i64 %x, i64 %y)
  ret i64 %z
}
define i64 @umax(i64 %x, i64 %y) {
  %z = call i64 @llvm.umax.i64(i64 %x, i64 %y)
  ret i64 %z
}
define i64 @umin(i64 %x, i64 %y) {
  %z = call i64 @llvm.umin.i64(i64 %y, i64 %x)
  ret i64 %z
}
define i64 @usub_sat(i64 %x, i64 %y) {
  %z = call i64 @llvm.usub.sat.i64(i64 %x, i64 %y)
  ret i64 %z
}
define i64 @usub_sat_swapped(i64 %x, i64 %y) {
  %z = call i64 @llvm.usub.sat.i64(i64 %y, i64 %x)
  ret i64 %z
}
define i64 @fshl(i64 %x, i64 %y) {
  %z = call i64 @llvm.fshl.i64(i64 %x, i64 %y, i64 3)
  ret i64 %z
}
define double @fadd(double %x, double %y) {
  %z = fadd double %y, %x
  ret double %z
}
define double @fsub(double %x, double %y) {
  %z = fsub double %x, %y
  ret double %z
}
define double @fmin(double %x, double %y) {
  %z = call double @llvm.minnum.f64(double %x, double %y)
  ret double %z
}
define double @fmax(double %x, double %y) {
  %z = call double @llvm.maxnum.f64(double %y, double %x)
  ret double %z
}
define float @fmul(float %x, float %y) {
  %z = fmul float %x, %y
  ret float %z
}
define ptr @gep(ptr %x, i64 %y) {
  %z = getelementptr i8, ptr %x, i64 %y
  ret ptr %z
}

; the old value passed on through calls
define i64 @wrap1(i64 %x, i64 %y) {
  %z = call i64 @add(i64 %x, i64 %y)
  ret i64 %z
}
define i64 @wrap2(i64 %x, i64 %y) {
  %z = call i64 @wrap1(i64 %x, i64 %y)
  ret i64 %z
}
define i64 @wrap3(i64 %x, i64 %y) {
  %z = call i64 @wrap2(i64 %x, i64 %y)
  ret i64 %z
}
define i64 @wrap4(i64 %x, i64 %y) {
  %z = call i64 @wrap3(i64 %x, i64 %y)
  ret i64 %z
}
; the old value is the second argument of the inner call
define i64 @wrap_second(i64 %x, i64 %y) {
  %z = call i64 @sub_swapped(i64 %y, i64 %x)
  ret i64 %z
}
; the inner call is one that can't be inlined
define i64 @wrap_mul(i64 %x, i64 %y) {
  %z = call i64 @mul(i64 %x, i64 %y)
  ret i64 %z
}
define i64 @wrap_gc(i64 %x, i64 %y) {
  %z = call i64 @add_gc(i64 %x, i64 %y)
  ret i64 %z
}
define i64 @add_gc(i64 %x, i64 %y) gc "other" {
  %z = add i64 %x, %y
  ret i64 %z
}

; operations that can't be reordered with the atomic access
@g = global i64 0
define i64 @add_load(i64 %x, i64 %y) {
  %v = load i64, ptr @g
  %z = add i64 %x, %v
  ret i64 %z
}
define i64 @add_load_nosync(i64 %x, i64 %y) nosync {
  %v = load i64, ptr @g
  %z = add i64 %x, %v
  ret i64 %z
}
define i64 @add_store(i64 %x, i64 %y) {
  store i64 %y, ptr @g
  %z = add i64 %x, %y
  ret i64 %z
}
; the operation is not known
define weak i64 @add_weak(i64 %x, i64 %y) {
  %z = add i64 %x, %y
  ret i64 %z
}
declare i64 @add_extern(i64, i64)
; the old value is used twice, or the result has another use
define i64 @add_twice(i64 %x, i64 %y) {
  %z = add i64 %x, %x
  ret i64 %z
}
; more than one return
define i64 @add_rets(i64 %x, i64 %y, i1 %c) {
  br i1 %c, label %a, label %b
a:
  %z = add i64 %x, %y
  ret i64 %z
b:
  ret i64 %x
}
; calling convention
define fastcc i64 @mul_fast(i64 %x, i64 %y) {
  %z = mul i64 %x, %y
  ret i64 %z
}

; the tests

; binary operators become the atomicrmw of the same operation, with the ordering
; and synchronization scope of the call
; CHECK-LABEL: @rmw_add(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw add ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = add i64 [[OLD]], %v
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @rmw_add(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; also when the old value is the second operand of a commutative operation; the new
; value is computed from the old one
; CHECK-LABEL: @rmw_add_new(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw add ptr %p, i64 %v monotonic, align 8
; CHECK-NEXT: [[NEW:%.*]] = add i64 %v, [[OLD]]
; CHECK-NEXT: ret i64 [[NEW]]
define i64 @rmw_add_new(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add_swapped, i8 2, i8 1, i64 %v)
  %new = extractvalue {i64, i64} %r, 1
  ret i64 %new
}

; CHECK-LABEL: @rmw_sub(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw sub ptr %p, i64 %v acquire, align 8
; CHECK-NEXT: {{%.*}} = sub i64 [[OLD]], %v
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @rmw_sub(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @sub, i8 4, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @rmw_and(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw and ptr %p, i64 %v release, align 8
; CHECK-NEXT: {{%.*}} = and i64 [[OLD]], %v
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @rmw_and(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @and, i8 5, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @rmw_or(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw or ptr %p, i64 %v acq_rel, align 8
; CHECK-NEXT: {{%.*}} = or i64 %v, [[OLD]]
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @rmw_or(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @or, i8 6, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @rmw_xor(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw xor ptr %p, i64 %v syncscope("singlethread") seq_cst, align 8
; CHECK-NEXT: {{%.*}} = xor i64 [[OLD]], %v
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @rmw_xor(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @xor, i8 7, i8 0, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; `xor (and x, y), -1`
; CHECK-LABEL: @rmw_nand(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw nand ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: [[AND:%.*]] = and i64 %v, [[OLD]]
; CHECK-NEXT: [[NEW:%.*]] = xor i64 [[AND]], -1
; CHECK-NEXT: %s = add i64 [[OLD]], [[NEW]]
define i64 @rmw_nand(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @nand, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  %new = extractvalue {i64, i64} %r, 1
  %s = add i64 %old, %new
  ret i64 %s
}

; an operation that ignores the old value is an exchange
; CHECK-LABEL: @rmw_xchg(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw xchg ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @rmw_xchg(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @second, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; an operation that returns the old value leaves the memory unchanged
; CHECK-LABEL: @rmw_fence(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw or ptr %p, i64 0 seq_cst, align 8
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @rmw_fence(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @identity, i8 7, i8 1, i64 %v)
  %new = extractvalue {i64, i64} %r, 1
  ret i64 %new
}

; minimum and maximum intrinsics, and saturating subtraction
; CHECK-LABEL: @rmw_max(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw max ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = call i64 @llvm.smax.i64(i64 %v, i64 [[OLD]])
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @rmw_max(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @smax, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @rmw_min(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw min ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = call i64 @llvm.smin.i64(i64 [[OLD]], i64 %v)
define i64 @rmw_min(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @smin, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @rmw_umax(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw umax ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = call i64 @llvm.umax.i64(i64 [[OLD]], i64 %v)
define i64 @rmw_umax(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @umax, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @rmw_umin(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw umin ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = call i64 @llvm.umin.i64(i64 %v, i64 [[OLD]])
define i64 @rmw_umin(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @umin, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @rmw_usub_sat(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw usub_sat ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = call i64 @llvm.usub.sat.i64(i64 [[OLD]], i64 %v)
define i64 @rmw_usub_sat(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @usub_sat, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; floating-point operations
; CHECK-LABEL: @rmw_fadd(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw fadd ptr %p, double %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = fadd double %v, [[OLD]]
; CHECK-NEXT: ret double [[OLD]]
define double @rmw_fadd(ptr %p, double %v) {
  %r = call {double, double} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.f64(ptr align(8) %p, ptr @fadd, i8 7, i8 1, double %v)
  %old = extractvalue {double, double} %r, 0
  ret double %old
}

; CHECK-LABEL: @rmw_fsub(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw fsub ptr %p, double %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = fsub double [[OLD]], %v
define double @rmw_fsub(ptr %p, double %v) {
  %r = call {double, double} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.f64(ptr align(8) %p, ptr @fsub, i8 7, i8 1, double %v)
  %old = extractvalue {double, double} %r, 0
  ret double %old
}

; CHECK-LABEL: @rmw_fmin(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw fmin ptr %p, double %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = call double @llvm.minnum.f64(double [[OLD]], double %v)
define double @rmw_fmin(ptr %p, double %v) {
  %r = call {double, double} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.f64(ptr align(8) %p, ptr @fmin, i8 7, i8 1, double %v)
  %old = extractvalue {double, double} %r, 0
  ret double %old
}

; CHECK-LABEL: @rmw_fmax(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw fmax ptr %p, double %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = call double @llvm.maxnum.f64(double %v, double [[OLD]])
define double @rmw_fmax(ptr %p, double %v) {
  %r = call {double, double} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.f64(ptr align(8) %p, ptr @fmax, i8 7, i8 1, double %v)
  %old = extractvalue {double, double} %r, 0
  ret double %old
}

; other operations are called in a compare-exchange loop, with a monotonic failure
; ordering
; CHECK-LABEL: @loop_mul(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @mul(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: %s = add i64 %newloaded, [[NEW]]
define i64 @loop_mul(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @mul, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  %new = extractvalue {i64, i64} %r, 1
  %s = add i64 %old, %new
  ret i64 %s
}

; the old value as the second operand of a non-commutative operation; an unordered
; modification is a monotonic cmpxchg
; CHECK-LABEL: @loop_sub_swapped(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @sub_swapped(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] monotonic monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @loop_sub_swapped(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @sub_swapped, i8 1, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @loop_usub_sat_swapped(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @usub_sat_swapped(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @loop_usub_sat_swapped(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @usub_sat_swapped, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; intrinsics with more than two arguments
; CHECK-LABEL: @loop_fshl(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @fshl(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @loop_fshl(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @fshl, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; floating-point values are compared as integers
; CHECK-LABEL: @loop_fmul(
; CHECK-NEXT: [[INIT:%.*]] = load atomic float, ptr %p unordered, align 4
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi float [ [[INIT]], %0 ], [ [[NEWLOADED:%.*]], %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call float @fmul(float %loaded, float %v)
; CHECK-NEXT: [[NEWI:%.*]] = bitcast float [[NEW]] to i32
; CHECK-NEXT: [[LOADEDI:%.*]] = bitcast float %loaded to i32
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i32 [[LOADEDI]], i32 [[NEWI]] syncscope("singlethread") acquire monotonic, align 4
; CHECK-NEXT: %success = extractvalue { i32, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i32, i1 } [[PAIR]], 0
; CHECK-NEXT: [[NEWLOADED]] = bitcast i32 %newloaded to float
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret float [[NEW]]
define float @loop_fmul(ptr %p, float %v) {
  %r = call {float, float} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.f32(ptr align(4) %p, ptr @fmul, i8 4, i8 0, float %v)
  %new = extractvalue {float, float} %r, 1
  ret float %new
}

; pointers
; CHECK-LABEL: @loop_ptr(
; CHECK-NEXT: [[INIT:%.*]] = load atomic ptr, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi ptr [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call ptr @gep(ptr %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, ptr %loaded, ptr [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { ptr, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { ptr, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret ptr %newloaded
define ptr @loop_ptr(ptr %p, i64 %v) {
  %r = call {ptr, ptr} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.p0(ptr align(8) %p, ptr @gep, i8 7, i8 1, i64 %v)
  %old = extractvalue {ptr, ptr} %r, 0
  ret ptr %old
}

; calls that pass the old value on are inlined, up to three levels deep
; CHECK-LABEL: @nested(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw add ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = add i64 [[OLD]], %v
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @nested(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @wrap3, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; one level more is too deep: the innermost call is called in the loop
; CHECK-LABEL: @nested_too_deep(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @add(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @nested_too_deep(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @wrap4, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; the old value can be any argument of the inner call
; CHECK-LABEL: @nested_second(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw sub ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: {{%.*}} = sub i64 [[OLD]], %v
define i64 @nested_second(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @wrap_second, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; an inner operation that atomicrmw doesn't support
; CHECK-LABEL: @nested_mul(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @mul(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @nested_mul(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @wrap_mul, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; an inner call that can't be inlined (incompatible garbage collectors)
; CHECK-LABEL: @nested_not_inlined(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @add_gc(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @nested_not_inlined(ptr %p, i64 %v) gc "mine" {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @wrap_gc, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; a modify function that can't be inlined
; CHECK-LABEL: @not_inlined_gc(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @add_gc(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @not_inlined_gc(ptr %p, i64 %v) gc "mine" {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add_gc, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; the call gets the operand bundles of the `julia.atomicmodify` call, which inlining
; doesn't support
; CHECK-LABEL: @not_inlined_bundle(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @add(i64 %loaded, i64 %v) [ "jl_roots"(ptr addrspace(10) %root) ]
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @not_inlined_bundle(ptr %p, i64 %v, ptr addrspace(10) %root) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v) [ "jl_roots"(ptr addrspace(10) %root) ]
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; the operation can only be reordered with the atomic access when the function doesn't
; access memory otherwise: it may read memory if it is `nosync`, and only write it if the
; operation itself is `nosync` and doesn't access memory
; CHECK-LABEL: @reorder_load(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @add_load(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @reorder_load(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add_load, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @reorder_load_nosync(
; CHECK-NEXT: [[V:%.*]] = load i64, ptr @g
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw add ptr %p, i64 [[V]] seq_cst, align 8
define i64 @reorder_load_nosync(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add_load_nosync, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @reorder_store(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @add_store(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @reorder_store(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add_store, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; the definition of the modify function must be known
; CHECK-LABEL: @weak_op(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @add_weak(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @weak_op(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add_weak, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @extern_op(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @add_extern(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @extern_op(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add_extern, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; the old value may only be used once
; CHECK-LABEL: @used_twice(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @add_twice(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @used_twice(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add_twice, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; the function must have a single return
; CHECK-LABEL: @two_returns(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @add_rets(i64 %loaded, i64 %v, i1 %c)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @two_returns(ptr %p, i64 %v, i1 %c) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add_rets, i8 7, i8 1, i64 %v, i1 %c)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; the call has the calling convention of the function
; CHECK-LABEL: @callconv(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call fastcc i64 @mul_fast(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @callconv(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @mul_fast, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; in a strictfp function, the call is strictfp too
; CHECK-LABEL: @strictfp(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @mul(i64 %loaded, i64 %v) #[[STRICTFP:[0-9]+]]
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: ret i64 %newloaded
define i64 @strictfp(ptr %p, i64 %v) strictfp {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @mul, i8 7, i8 1, i64 %v) strictfp
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @strictfp_add(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw add ptr %p, i64 %v seq_cst, align 8
define i64 @strictfp_add(ptr %p, i64 %v) strictfp {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v) strictfp
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; the atomic instructions get the metadata of the call; every new instruction gets its
; debug location, `!pcsections` and, where possible, `!mmra`
; CHECK-LABEL: @metadata_rmw(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw add ptr %p, i64 %v seq_cst, align 8, !dbg [[LOC:![0-9]+]], !tbaa [[TBAA:![0-9]+]], !pcsections [[PCS:![0-9]+]], !mmra [[MMRA:![0-9]+]]
; CHECK-NEXT: {{%.*}} = add i64 [[OLD]], %v, !dbg [[LOC]]
define i64 @metadata_rmw(ptr %p, i64 %v) !dbg !6 {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v), !mmra !0, !pcsections !1, !tbaa !2, !dbg !10
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @metadata_loop(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8, !dbg [[LOC2:![0-9]+]], !pcsections [[PCS]], !mmra [[MMRA]]{{$}}
; CHECK-NEXT: br label %atomicrmw.start, !dbg [[LOC2]], !pcsections [[PCS]]{{$}}
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ], !dbg [[LOC2]], !pcsections [[PCS]]{{$}}
; CHECK-NEXT: [[NEW:%.*]] = call i64 @mul(i64 %loaded, i64 %v), !dbg [[LOC2]], !pcsections [[PCS]], !mmra [[MMRA]]{{$}}
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8, !dbg [[LOC2]], !tbaa [[TBAA]], !pcsections [[PCS]], !mmra [[MMRA]]{{$}}
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1, !dbg [[LOC2]], !pcsections [[PCS]]{{$}}
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0, !dbg [[LOC2]], !pcsections [[PCS]]{{$}}
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start, !dbg [[LOC2]], !pcsections [[PCS]]{{$}}
define i64 @metadata_loop(ptr %p, i64 %v) !dbg !8 {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @mul, i8 7, i8 1, i64 %v), !mmra !0, !pcsections !1, !tbaa !2, !dbg !11
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; other uses of the result get the pair of the old and the new value
; CHECK-LABEL: @whole_result(
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %0 ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @mul(i64 %loaded, i64 %v)
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
; CHECK-NEXT: %success = extractvalue { i64, i1 } [[PAIR]], 1
; CHECK-NEXT: %newloaded = extractvalue { i64, i1 } [[PAIR]], 0
; CHECK-NEXT: br i1 %success, label %atomicrmw.end, label %atomicrmw.start
; CHECK: atomicrmw.end:
; CHECK-NEXT: [[R:%.*]] = insertvalue { i64, i64 } undef, i64 %newloaded, 0
; CHECK-NEXT: [[R2:%.*]] = insertvalue { i64, i64 } [[R]], i64 [[NEW]], 1
; CHECK-NEXT: ret { i64, i64 } [[R2]]
define {i64, i64} @whole_result(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @mul, i8 7, i8 1, i64 %v)
  ret {i64, i64} %r
}

; CHECK-LABEL: @whole_result_rmw(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw add ptr %p, i64 %v seq_cst, align 8
; CHECK-NEXT: [[NEW:%.*]] = add i64 [[OLD]], %v
; CHECK-NEXT: [[R:%.*]] = insertvalue { i64, i64 } undef, i64 [[OLD]], 0
; CHECK-NEXT: [[R2:%.*]] = insertvalue { i64, i64 } [[R]], i64 [[NEW]], 1
; CHECK-NEXT: ret { i64, i64 } [[R2]]
define {i64, i64} @whole_result_rmw(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 %v)
  ret {i64, i64} %r
}

; without an alignment for the pointer, an atomicrmw is aligned to the size of the value
; CHECK-LABEL: @no_align(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw add ptr %p, i32 %v seq_cst, align 4
define i32 @no_align(ptr %p, i32 %v) {
  %r = call {i32, i32} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i32(ptr %p, ptr @add32, i8 7, i8 1, i32 %v)
  %old = extractvalue {i32, i32} %r, 0
  ret i32 %old
}
define i32 @add32(i32 %x, i32 %y) {
  %z = add i32 %x, %y
  ret i32 %z
}

; the pass is not required
; CHECK-LABEL: @optnone(
; CHECK-NEXT: %r = call { i8, i8 } (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i8(
define i8 @optnone(ptr %p, i8 %v) noinline optnone {
  %r = call {i8, i8} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i8(ptr align(1) %p, ptr @add8, i8 7, i8 1, i8 %v)
  %old = extractvalue {i8, i8} %r, 0
  ret i8 %old
}
define i8 @add8(i8 %x, i8 %y) {
  %z = add i8 %x, %y
  ret i8 %z
}

define i64 @add_store_nosync(i64 %x, i64 %y) nosync {
  store i64 %y, ptr @g
  %z = add i64 %x, %y
  ret i64 %z
}
define i64 @shl1(i64 %x, i64 %y) {
  %z = shl i64 %y, 1
  ret i64 %z
}

; CHECK-LABEL: @reorder_store_nosync(
; CHECK-NEXT: store i64 %v, ptr @g
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw add ptr %p, i64 %v seq_cst, align 8
define i64 @reorder_store_nosync(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add_store_nosync, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; inlining may simplify the operation: `x + 0` leaves the memory unchanged, `x | -1`
; doesn't depend on the old value
; CHECK-LABEL: @simplified_fence(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw or ptr %p, i64 0 seq_cst, align 8
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @simplified_fence(ptr %p) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @add, i8 7, i8 1, i64 0)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

; CHECK-LABEL: @simplified_xchg(
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw xchg ptr %p, i64 -1 seq_cst, align 8
; CHECK-NEXT: %s = add i64 [[OLD]], -1
define i64 @simplified_xchg(ptr %p) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @or, i8 7, i8 1, i64 -1)
  %old = extractvalue {i64, i64} %r, 0
  %new = extractvalue {i64, i64} %r, 1
  %s = add i64 %old, %new
  ret i64 %s
}

; the exchanged value is computed before the exchange (Julia master; Julia 1.13's C++
; pass emits the atomicrmw before it)
; CHECK-LABEL: @xchg_computed(
; CHECK-NEXT: [[NEW:%.*]] = shl i64 %v, 1
; CHECK-NEXT: [[OLD:%.*]] = atomicrmw xchg ptr %p, i64 [[NEW]] seq_cst, align 8
; CHECK-NEXT: ret i64 [[OLD]]
define i64 @xchg_computed(ptr %p, i64 %v) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @shl1, i8 7, i8 1, i64 %v)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

define i64 @branchy(i64 %x, i64 %y, i1 %c) {
entry:
  br i1 %c, label %a, label %b
a:
  br label %b
b:
  %w = phi i64 [ 1, %entry ], [ 2, %a ]
  %z = call i64 @mul(i64 %x, i64 %w)
  ret i64 %z
}

; a modify function with several blocks, inlined before the loop (Julia's C++ pass
; doesn't terminate)
; CHECK-LABEL: @multiple_blocks(
; CHECK: [[W:%.*]] = phi i64 [ 1, %0 ], [ 2, %a.i ]
; CHECK-NEXT: [[INIT:%.*]] = load atomic i64, ptr %p unordered, align 8
; CHECK-NEXT: br label %atomicrmw.start
; CHECK: atomicrmw.start:
; CHECK-NEXT: %loaded = phi i64 [ [[INIT]], %branchy.exit ], [ %newloaded, %atomicrmw.start ]
; CHECK-NEXT: [[NEW:%.*]] = call i64 @mul(i64 %loaded, i64 [[W]])
; CHECK-NEXT: [[PAIR:%.*]] = cmpxchg ptr %p, i64 %loaded, i64 [[NEW]] seq_cst monotonic, align 8
define i64 @multiple_blocks(ptr %p, i64 %v, i1 %c) {
  %r = call {i64, i64} (ptr, ptr, i8, i8, ...) @julia.atomicmodify.i64(ptr align(8) %p, ptr @branchy, i8 7, i8 1, i64 %v, i1 %c)
  %old = extractvalue {i64, i64} %r, 0
  ret i64 %old
}

!llvm.dbg.cu = !{!3}
!llvm.module.flags = !{!5}

!0 = !{!"foo", !"bar"}
!1 = !{!"section"}
!2 = !{!12, !12, i64 0}
!12 = !{!"scalar", !13}
!13 = !{!"root"}
!3 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !4, emissionKind: FullDebug)
!4 = !DIFile(filename: "atomic.jl", directory: ".")
!5 = !{i32 2, !"Debug Info Version", i32 3}
!6 = distinct !DISubprogram(name: "metadata_rmw", scope: null, file: !4, line: 1, type: !7, spFlags: DISPFlagDefinition, unit: !3)
!7 = !DISubroutineType(types: !{})
!8 = distinct !DISubprogram(name: "metadata_loop", scope: null, file: !4, line: 2, type: !7, spFlags: DISPFlagDefinition, unit: !3)
!10 = !DILocation(line: 10, scope: !6)
!11 = !DILocation(line: 20, scope: !8)

; CHECK: attributes #[[STRICTFP]] = { strictfp }
; CHECK: [[TBAA]] = !{!{{[0-9]+}}, !{{[0-9]+}}, i64 0}
; CHECK: [[PCS]] = !{!"section"}
; CHECK: [[MMRA]] = !{!"foo", !"bar"}
