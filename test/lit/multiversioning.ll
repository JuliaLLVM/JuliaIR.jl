; JuliaMultiVersioning (jl-multiversioning) on an annotated module: the clones and their
; attributes, the uses of the cloned functions through relocation slots, the trampolines,
; and the tables of each version. Upstream's fixtures (test/upstream) cover the rest at
; each version's pin, and test/multiversioning.jl the versions' tables in detail.

; RUN: %if julia-1.10 %{ opt -passes=JuliaMultiVersioning -S %s | FileCheck %s --check-prefixes=CHECK,OFFSETS,NOINIT %}
; RUN: %if julia-1.11 %{ opt -passes=JuliaMultiVersioning -S %s | FileCheck %s --check-prefixes=CHECK,POINTERS,NOINIT %}
; RUN: %if julia-ge-1.12 %{ opt -passes=JuliaMultiVersioning -S %s | FileCheck %s --check-prefixes=CHECK,POINTERS,AUTOINIT %}
; RUN: opt -passes=jl-multiversioning -S %s | FileCheck %s

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@jl_fvars = global [6 x ptr] [ptr @leaf, ptr @caller, ptr @in_global, ptr @ce_uses, ptr @abi, ptr @va]
@jl_fvar_idxs = global [1 x i32] zeroinitializer
@jl_gvars = global [1 x ptr] [ptr @table]
@jl_gvar_idxs = global [1 x i32] zeroinitializer

; the loader writes the version of @in_global it picks
; CHECK: @table = global [2 x ptr] zeroinitializer
@table = global [2 x ptr] [ptr null, ptr @in_global]

; NOINIT: @leaf.reloc_slot = hidden global ptr null
; AUTOINIT: @leaf.reloc_slot = hidden global ptr @leaf.autoinit_trampoline
; CHECK: @extern_f.reloc_slot = external hidden global ptr

; Julia 1.10: offsets from the first function and the first global variable
; OFFSETS: @jl_fvar_offsets = hidden constant [7 x i32] [i32 6, i32 0, i32 trunc (i64 sub (i64 ptrtoint (ptr @caller to i64), i64 ptrtoint (ptr @leaf to i64)) to i32),
; OFFSETS: @jl_gvar_offsets = hidden constant [2 x i32] [i32 1, i32 0]
; OFFSETS: @jl_clone_slots = hidden constant [9 x i32] [i32 4, i32 0, i32 trunc (i64 sub (i64 ptrtoint (ptr @leaf.reloc_slot to i64), i64 ptrtoint (ptr @table to i64)) to i32), i32 2, i32 trunc (i64 sub (i64 add (i64 ptrtoint (ptr @table to i64), i64 8), i64 ptrtoint (ptr @table to i64)) to i32), i32 4,
; OFFSETS: @jl_clone_idxs = hidden constant [19 x i32] [i32 -2147483644, i32 0, i32 2, i32 4, i32 5, i32 6, i32 0, i32 -2147483648, i32 1, i32 -2147483646, i32 3, i32 -2147483644, i32 -2147483643, i32 4, i32 0, i32 -2147483648, i32 -2147483646, i32 -2147483644, i32 -2147483643]
; OFFSETS: @jl_clone_offsets = hidden constant [10 x i32] [i32 trunc (i64 sub (i64 ptrtoint (ptr @leaf.1 to i64), i64 ptrtoint (ptr @leaf to i64)) to i32),
; OFFSETS: @jl_fvar_base = hidden alias i64, ptr @leaf
; OFFSETS: @jl_gvar_base = hidden alias i64, ptr @table

; Julia 1.11 and later: pointers, and offsets from the table of relocations
; POINTERS: @jl_fvar_count = hidden constant i64 6
; POINTERS: @jl_fvar_ptrs = hidden global [6 x ptr] [ptr @leaf, ptr @caller, ptr @in_global, ptr @ce_uses, ptr @abi, ptr @va]
; POINTERS: @jl_clone_slots = hidden constant [9 x i32] [i32 4, i32 0, i32 trunc (i64 sub (i64 ptrtoint (ptr @leaf.reloc_slot to i64), i64 ptrtoint (ptr @jl_clone_slots to i64)) to i32), i32 2, i32 trunc (i64 sub (i64 add (i64 ptrtoint (ptr @table to i64), i64 8), i64 ptrtoint (ptr @jl_clone_slots to i64)) to i32), i32 4,
; POINTERS: @jl_clone_idxs = hidden constant [19 x i32] [i32 -2147483644, i32 0, i32 2, i32 4, i32 5, i32 6, i32 0, i32 -2147483648, i32 1, i32 -2147483646, i32 3, i32 -2147483644, i32 -2147483643, i32 4, i32 0, i32 -2147483648, i32 -2147483646, i32 -2147483644, i32 -2147483643]
; target 2 has no clone of @in_global, so the loader writes @in_global for it
; POINTERS: @jl_clone_ptrs = hidden constant [10 x ptr] [ptr @leaf.1, ptr @caller.1, ptr @in_global.1, ptr @ce_uses.1, ptr @abi.1, ptr @va.1, ptr @leaf.2, ptr @in_global, ptr @abi.2, ptr @va.2]

; CHECK: define i32 @leaf(i32 %x) [[LEAF0:#[0-9]+]]
define i32 @leaf(i32 %x) #0 {
  ret i32 %x
}

; calls from cloned functions go through the slot
; CHECK-LABEL: define i32 @caller(
; CHECK-NEXT: [[F:%.*]] = load ptr, ptr @leaf.reloc_slot, align 8, !tbaa [[CONST:![0-9]+]], !invariant.load [[EMPTY:![0-9]+]]
; CHECK-NEXT: %r = call i32 [[F]](i32 %x)
; CHECK-NEXT: [[G:%.*]] = load ptr, ptr @extern_f.reloc_slot, align 8, !tbaa [[CONST]], !invariant.load [[EMPTY]]
; CHECK-NEXT: %s = call i32 [[G]](i32 %r)
define i32 @caller(i32 %x) #1 {
  %r = call i32 @leaf(i32 %x)
  %s = call i32 @extern_f(i32 %r)
  ret i32 %s
}

define i32 @in_global(i32 %x) #2 {
  ret i32 %x
}

; constant expressions become instructions, aggregates are built, and phi operands are
; loaded in the incoming block
; CHECK-LABEL: define ptr @ce_uses(
; CHECK-NEXT: top:
; CHECK-NEXT: [[F:%.*]] = load ptr, ptr @leaf.reloc_slot
; CHECK-NEXT: [[I:%.*]] = ptrtoint ptr [[F]] to i64
; CHECK-NEXT: store i64 [[I]], ptr %p
; CHECK-NEXT: [[F:%.*]] = load ptr, ptr @leaf.reloc_slot
; CHECK-NEXT: [[A:%.*]] = insertvalue { ptr, i64 } { ptr undef, i64 1 }, ptr [[F]], 0
; CHECK-NEXT: store { ptr, i64 } [[A]], ptr %p
; CHECK-NEXT: [[F:%.*]] = load ptr, ptr @leaf.reloc_slot
; CHECK-NEXT: [[V:%.*]] = insertelement <2 x ptr> <ptr null, ptr undef>, ptr [[F]], i64 1
; CHECK-NEXT: store <2 x ptr> [[V]], ptr %p
; CHECK: a:
; CHECK-NEXT: [[F:%.*]] = load ptr, ptr @leaf.reloc_slot
; CHECK-NEXT: br label %join
; CHECK: join:
; CHECK-NEXT: %f = phi ptr [ [[F]], %a ], [ null, %b ]
define ptr @ce_uses(ptr %p, i1 %c) #1 {
top:
  store i64 ptrtoint (ptr @leaf to i64), ptr %p
  store { ptr, i64 } { ptr @leaf, i64 1 }, ptr %p
  store <2 x ptr> <ptr null, ptr @leaf>, ptr %p
  br i1 %c, label %a, label %b
a:
  br label %join
b:
  br label %join
join:
  %f = phi ptr [ @leaf, %a ], [ null, %b ]
  ret ptr %f
}

define cc 10 void @abi(ptr noalias sret({ i64, i64 }) %r, ptr byval({ i64, i64 }) %b, ptr "julia.return_roots"="1" %roots) #0 {
  ret void
}

define i32 @va(i32 %x, ...) #0 {
  ret i32 %x
}

declare i32 @extern_f(i32) #3

@abi_alias = alias void (ptr, ptr, ptr), ptr @abi
@va_alias = alias i32 (i32, ...), ptr @va

; Julia 1.12 and later: the slots first point to a trampoline that initializes the runtime
; AUTOINIT-LABEL: define hidden i32 @leaf.autoinit_trampoline(i32 %0)
; AUTOINIT-NEXT: top:
; AUTOINIT-NEXT: call ptr @ijl_autoinit_and_adopt_thread()
; AUTOINIT-NEXT: [[F:%.*]] = load ptr, ptr @leaf.reloc_slot
; AUTOINIT-NEXT: [[R:%.*]] = tail call i32 [[F]](i32 %0)
; AUTOINIT-NEXT: ret i32 [[R]]

; the clones, for the targets they are cloned for, call the clones of their target
; CHECK: define i32 @leaf.1(i32 %x) [[LEAF1:#[0-9]+]]
; CHECK: define i32 @leaf.2(i32 %x) [[LEAF2:#[0-9]+]]
; CHECK-LABEL: define i32 @caller.1(
; CHECK-NEXT: %r = call i32 @leaf.1(i32 %x)
; CHECK-NEXT: %s = call i32 @extern_f.1(i32 %r)
; CHECK-LABEL: define ptr @ce_uses.1(
; CHECK-NEXT: top:
; CHECK-NEXT: store i64 ptrtoint (ptr @leaf.1 to i64), ptr %p
; CHECK: %f = phi ptr [ @leaf.1, %a ], [ null, %b ]
; CHECK-NOT: @caller.2
; CHECK-NOT: @in_global.2

; functions that are declared get declared clones
; CHECK: declare dso_local i32 @extern_f.1(i32)
; CHECK: declare dso_local i32 @extern_f.2(i32)

; aliases become trampolines with the ABI of the function (also before Julia 1.13), and
; variadic ones forward their arguments
; CHECK: define ghccc void @abi_alias(ptr noalias sret({ i64, i64 }) %0, ptr byval({ i64, i64 }) %1, ptr "julia.return_roots"="1" %2) [[ALIAS:#[0-9]+]]
; CHECK-NEXT: top:
; CHECK-NEXT: [[F:%.*]] = load ptr, ptr @abi.reloc_slot
; CHECK-NEXT: tail call ghccc void [[F]](ptr noalias sret({ i64, i64 }) %0, ptr byval({ i64, i64 }) %1, ptr %2)
; CHECK-NEXT: ret void
; CHECK-LABEL: define i32 @va_alias(i32 %0, ...)
; CHECK: musttail call i32 (i32, ...) {{%.*}}(i32 %0, ...)

; CHECK-DAG: attributes [[LEAF0]] = { "julia.mv.clone"="0" "julia.mv.clones"="6" "julia.mv.reloc" "target-cpu"="cpu0" "target-features"="+existing,+base" }
; CHECK-DAG: attributes [[LEAF1]] = { "julia.mv.clone"="1" "julia.mv.clones"="6" "julia.mv.reloc" "target-cpu"="cpu1" "target-features"="+existing,+one" }
; CHECK-DAG: attributes [[LEAF2]] = { "julia.mv.clone"="2" "julia.mv.clones"="6" "julia.mv.reloc" "target-cpu"="cpu2" "target-features"="+existing,+two" }
; CHECK-DAG: attributes [[ALIAS]] = { "julia.mv.alias" "target-features"="+existing" }
; CHECK-DAG: [[CONST]] = !{[[JTBAA:![0-9]+]], [[JTBAA]], i64 0, i64 1}
; CHECK-DAG: [[JTBAA]] = !{!"jtbaa_const", {{.*}}}
; CHECK-DAG: [[EMPTY]] = !{}

attributes #0 = { "julia.mv.clones"="6" "julia.mv.reloc" "target-features"="+existing" }
attributes #1 = { "julia.mv.clones"="2" }
attributes #2 = { "julia.mv.clones"="2" "julia.mv.fvar" }
attributes #3 = { "julia.mv.clones"="6" "julia.mv.reloc" }

!llvm.module.flags = !{!0, !1, !2}
!0 = !{i32 1, !"julia.mv.enable", i32 1}
!1 = !{i32 1, !"julia.mv.annotated", i32 1}
!2 = !{i32 1, !"julia.mv.specs", !3}
!3 = !{!4, !5, !6}
!4 = !{!"cpu0", !"+base", i32 0, i32 0}
!5 = !{!"cpu1", !"+one", i32 0, i32 0}
!6 = !{!"cpu2", !"+two", i32 0, i32 0}
