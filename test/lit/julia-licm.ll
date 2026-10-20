; JuliaLICM hoists `llvm.julia.gc_preserve_begin` out of loops and sinks the matching
; `gc_preserve_end` to the exits, and hoists GC allocations whose object doesn't escape
; the loop, clearing them in the preheader. Write barriers are in julia-licm-barriers.ll
; and julia-licm-write-barrier.ll.

; RUN: opt -passes=JuliaLICM -S %s | FileCheck %s --check-prefixes=CHECK,%if julia-ge-1.11 %{LOADED%} %else %{NOLOADED%}
; RUN: opt -passes='loop(jl-licm)' -S %s | FileCheck %s --check-prefixes=CHECK,%if julia-ge-1.11 %{LOADED%} %else %{NOLOADED%}
; RUN: opt -passes='function(loop-mssa(JuliaLICM)),verify' -verify-memoryssa -S %s | FileCheck %s --check-prefixes=CHECK,%if julia-ge-1.11 %{LOADED%} %else %{NOLOADED%}
; RUN: opt -passes='function(loop-mssa(JuliaLICM),print<memoryssa>)' -S %s -o /dev/null 2>&1 | FileCheck %s --check-prefix=MSSA

; the port runs once per loop (13), but not in the optnone function: it is not required
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=JuliaLICM -S %s -o /dev/null
; RUN: grep -c 'pass	jl-licm	julia=' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 13

@tag = external addrspace(10) global {}, align 16

declare token @llvm.julia.gc_preserve_begin(...)
declare void @llvm.julia.gc_preserve_end(token)
declare ptr @julia.get_pgcstack()
declare noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10)) allocsize(1)
declare ptr @julia.pointer_from_objref(ptr addrspace(10)) readnone
declare ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10), ptr) readnone
declare void @use(ptr addrspace(10))
declare i32 @__CxxFrameHandler3(...)

; a begin of loop-invariant values is hoisted, its end sunk to the only exit
; CHECK-LABEL: @preserve(
; CHECK: preheader:
; CHECK-NEXT: %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj, i64 1)
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK-NEXT: call void @use(ptr addrspace(10) %obj)
; CHECK-NEXT: br i1 %c, label %exit, label %loop
; CHECK: exit:
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %token)
; CHECK-NEXT: ret void
; MSSA-LABEL: MemorySSA for function: preserve
; MSSA: preheader:
; MSSA-NEXT: ; [[BEGIN:[0-9]+]] = MemoryDef(liveOnEntry)
; MSSA-NEXT: %token = call token (...) @llvm.julia.gc_preserve_begin
; MSSA: loop:
; MSSA-NEXT: ; [[PHI:[0-9]+]] = MemoryPhi({preheader,[[BEGIN]]},{loop,[[USE:[0-9]+]]})
; MSSA-NEXT: ; [[USE]] = MemoryDef([[PHI]])
; MSSA-NEXT: call void @use
; MSSA: exit:
; MSSA-NEXT: ; [[END:[0-9]+]] = MemoryDef([[USE]])
; MSSA-NEXT: call void @llvm.julia.gc_preserve_end(token %token)
define void @preserve(ptr addrspace(10) %obj, i1 %c) {
top:
  br label %preheader
preheader:
  br label %loop
loop:
  %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj, i64 1)
  call void @use(ptr addrspace(10) %obj)
  call void @llvm.julia.gc_preserve_end(token %token)
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; a begin of a value computed in the loop stays, and so does its end
; CHECK-LABEL: @preserve_variant(
; CHECK: loop:
; CHECK-NEXT: %obj = phi
; CHECK-NEXT: %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %token)
; CHECK: exit:
; CHECK-NEXT: ret void
define void @preserve_variant(ptr addrspace(10) %a, ptr addrspace(10) %b, i1 %c) {
top:
  br label %loop
loop:
  %obj = phi ptr addrspace(10) [ %a, %top ], [ %b, %loop ]
  %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
  call void @llvm.julia.gc_preserve_end(token %token)
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; an end is sunk to every exit: moved to the first, cloned without operand bundles and
; metadata for the others; a second end of the same token is sunk as well
; CHECK-LABEL: @preserve_exits(
; CHECK: top:
; CHECK-NEXT: %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK-NEXT: br i1 %c, label %exit1, label %latch
; CHECK: latch:
; CHECK-NEXT: br i1 %d, label %exit2, label %loop
; CHECK: exit1:
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %token)
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %token) [ "foo"(i32 1) ], !foo !0
; CHECK-NEXT: ret void
; CHECK: exit2:
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %token){{$}}
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %token){{$}}
; CHECK-NEXT: ret void
; MSSA-LABEL: MemorySSA for function: preserve_exits
; MSSA: loop:
; MSSA-NEXT: ; [[PHI:[0-9]+]] = MemoryPhi({top,{{[0-9]+}}},{latch,[[PHI]]})
; MSSA: exit1:
; MSSA-NEXT: ; [[E1:[0-9]+]] = MemoryDef([[PHI]])
; MSSA-NEXT: call void @llvm.julia.gc_preserve_end(token %token)
; MSSA-NEXT: ; {{[0-9]+}} = MemoryDef([[E1]])
; MSSA-NEXT: call void @llvm.julia.gc_preserve_end(token %token) [ "foo"(i32 1) ]
; MSSA: exit2:
; MSSA-NEXT: ; [[E2:[0-9]+]] = MemoryDef([[PHI]])
; MSSA-NEXT: call void @llvm.julia.gc_preserve_end(token %token)
; MSSA-NEXT: ; {{[0-9]+}} = MemoryDef([[E2]])
; MSSA-NEXT: call void @llvm.julia.gc_preserve_end(token %token)
define void @preserve_exits(ptr addrspace(10) %obj, i1 %c, i1 %d) {
top:
  %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
  br label %loop
loop:
  call void @llvm.julia.gc_preserve_end(token %token) [ "foo"(i32 1) ], !foo !0
  call void @llvm.julia.gc_preserve_end(token %token)
  br i1 %c, label %exit1, label %latch
latch:
  br i1 %d, label %exit2, label %loop
exit1:
  ret void
exit2:
  ret void
}

; the end in a loop without exits is removed
; CHECK-LABEL: @preserve_no_exit(
; CHECK: preheader:
; CHECK-NEXT: %token = call token (...) @llvm.julia.gc_preserve_begin
; CHECK: loop:
; CHECK-NEXT: call void @use(ptr addrspace(10) %obj)
; CHECK-NEXT: br label %loop
; CHECK-NOT: gc_preserve_end
; CHECK: }
define void @preserve_no_exit(ptr addrspace(10) %obj) {
top:
  br label %preheader
preheader:
  br label %loop
loop:
  %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
  call void @use(ptr addrspace(10) %obj)
  call void @llvm.julia.gc_preserve_end(token %token)
  br label %loop
}

; Tokens don't leave the loop that defines them (Julia 1.13's rule, for every version):
; the inner loop's begin is hoisted to the inner preheader, and its end is only sunk to
; the inner loop's exit in the outer loop, not to the exit of both loops (%fail), since
; LCSSA can't add phis of tokens. The end of the token from before both loops is sunk to
; every exit: first to those of the inner loop, then from %outer.latch to those of the
; outer loop, so %fail gets two.
; CHECK-LABEL: @preserve_nested(
; CHECK: inner.preheader:
; CHECK-NEXT: %inner_token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
; CHECK-NEXT: br label %inner
; CHECK: inner:
; CHECK-NEXT: call void @use(ptr addrspace(10) %obj)
; CHECK-NEXT: br i1 %err, label %fail, label %inner.latch
; CHECK: outer.latch:
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %inner_token)
; CHECK-NEXT: br i1 %outer_exit
; CHECK: fail:
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %outer_token)
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %outer_token)
; CHECK-NEXT: ret void
; CHECK: return:
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %outer_token)
; CHECK-NEXT: ret void
define void @preserve_nested(ptr addrspace(10) %obj1, ptr addrspace(10) %obj2, i1 %inner_exit, i1 %outer_exit, i1 %err) {
top:
  %outer_token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj1)
  br label %outer
outer:
  %obj = phi ptr addrspace(10) [ %obj1, %top ], [ %obj2, %outer.latch ]
  br label %inner.preheader
inner.preheader:
  br label %inner
inner:
  %inner_token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
  call void @use(ptr addrspace(10) %obj)
  call void @llvm.julia.gc_preserve_end(token %inner_token)
  call void @llvm.julia.gc_preserve_end(token %outer_token)
  br i1 %err, label %fail, label %inner.latch
inner.latch:
  br i1 %inner_exit, label %outer.latch, label %inner
outer.latch:
  br i1 %outer_exit, label %return, label %outer
fail:
  ret void
return:
  ret void
}

; an end whose token isn't an instruction stays where it is (Julia's C++ pass crashes)
; CHECK-LABEL: @preserve_none(
; CHECK: loop:
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token none)
; CHECK-NEXT: br i1
define void @preserve_none(i1 %c) {
top:
  %token = call token (...) @llvm.julia.gc_preserve_begin()
  br label %loop
loop:
  call void @llvm.julia.gc_preserve_end(token none)
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; an exit without an insertion point (a block with only a `catchswitch`) gets no end
; (Julia's C++ pass crashes); the other exits get theirs
; CHECK-LABEL: @preserve_catchswitch(
; CHECK: top:
; CHECK-NEXT: %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
; CHECK: loop:
; CHECK-NEXT: invoke void @use
; CHECK: dispatch:
; CHECK-NEXT: %cs = catchswitch within none [label %handler] unwind to caller
; CHECK: exit.loopexit:
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %token)
; CHECK-NOT: gc_preserve_end
; CHECK: ret void
define void @preserve_catchswitch(ptr addrspace(10) %obj, i1 %c) personality ptr @__CxxFrameHandler3 {
top:
  br label %loop
loop:
  %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
  call void @llvm.julia.gc_preserve_end(token %token)
  invoke void @use(ptr addrspace(10) %obj) to label %latch unwind label %dispatch
latch:
  br i1 %c, label %exit, label %loop
dispatch:
  %cs = catchswitch within none [label %handler] unwind to caller
handler:
  %cp = catchpad within %cs [ptr null, i32 64, ptr null]
  catchret from %cp to label %exit
exit:
  ret void
}

; an end whose begin is in the loop but can't be hoisted stays too
; CHECK-LABEL: @preserve_loaded(
; CHECK: loop:
; CHECK-NEXT: %v = load
; CHECK-NEXT: %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %v)
; CHECK-NEXT: call void @llvm.julia.gc_preserve_end(token %token)
define void @preserve_loaded(ptr %p, i1 %c) {
top:
  br label %loop
loop:
  %v = load ptr addrspace(10), ptr %p
  %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %v)
  call void @llvm.julia.gc_preserve_end(token %token)
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; An allocation whose object doesn't escape the loop is hoisted and cleared in the
; preheader (aligned to the pointer size), with the computation of its size, which loses
; its unknown metadata but keeps its flags. Uses after the loop don't count.
; CHECK-LABEL: @alloc(
; CHECK: top:
; CHECK-NEXT: %pgcstack = call ptr @julia.get_pgcstack()
; CHECK-NEXT: %size = add nuw i64 %n, 8{{$}}
; CHECK-NEXT: %obj = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 %size, ptr addrspace(10) @tag)
; CHECK-NEXT: call void @llvm.memset.p10.i64(ptr addrspace(10) align 8 %obj, i8 0, i64 %size, i1 false)
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK-NEXT: %i = phi i64
; CHECK-NEXT: store i64 %i, ptr addrspace(10) %obj
; MSSA-LABEL: MemorySSA for function: alloc
; MSSA: top:
; MSSA: ; [[ALLOC:[0-9]+]] = MemoryDef([[GCSTACK:[0-9]+]])
; MSSA-NEXT: %obj = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj
; MSSA-NEXT: ; [[CLEAR:[0-9]+]] = MemoryDef([[ALLOC]])
; MSSA-NEXT: call void @llvm.memset.p10.i64
; MSSA: loop:
; MSSA-NEXT: ; {{[0-9]+}} = MemoryPhi({top,[[CLEAR]]},{loop,{{[0-9]+}}})
define void @alloc(i64 %n, i1 %c) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  br label %loop
loop:
  %i = phi i64 [ 0, %top ], [ %next, %loop ]
  %size = add nuw i64 %n, 8, !foo !0
  %obj = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 %size, ptr addrspace(10) @tag)
  store i64 %i, ptr addrspace(10) %obj
  %next = add i64 %i, 1
  br i1 %c, label %exit, label %loop
exit:
  %last = phi ptr addrspace(10) [ %obj, %loop ]
  call void @use(ptr addrspace(10) %last)
  ret void
}

; allocations that escape, whose address escapes, or that get references stored into
; them stay in the loop
; CHECK-LABEL: @alloc_escapes(
; CHECK: loop:
; CHECK-NEXT: %escaped = call {{.*}}@julia.gc_alloc_obj
; CHECK-NEXT: call void @use(ptr addrspace(10) %escaped)
; CHECK-NEXT: %addr_escaped = call {{.*}}@julia.gc_alloc_obj
; CHECK-NEXT: %addr = call ptr @julia.pointer_from_objref(ptr addrspace(10) %addr_escaped)
; CHECK-NEXT: %ref_stored = call {{.*}}@julia.gc_alloc_obj
; CHECK-NEXT: store ptr addrspace(10) %obj, ptr addrspace(10) %ref_stored
; CHECK-NEXT: %atomic_escaped = call {{.*}}@julia.gc_alloc_obj
; CHECK-NEXT: %derived = addrspacecast ptr addrspace(10) %atomic_escaped to ptr addrspace(11)
; CHECK-NEXT: %old = atomicrmw xchg ptr %p, ptr addrspace(11) %derived seq_cst
define void @alloc_escapes(ptr addrspace(10) %obj, ptr %p, i1 %c) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  br label %loop
loop:
  %escaped = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  call void @use(ptr addrspace(10) %escaped)
  %addr_escaped = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %addr = call ptr @julia.pointer_from_objref(ptr addrspace(10) %addr_escaped)
  %ref_stored = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  store ptr addrspace(10) %obj, ptr addrspace(10) %ref_stored
  ; the object's address is the value of an atomic: before Julia 1.13 the C++ pass
  ; took this for a store into the object and hoisted it
  %atomic_escaped = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %derived = addrspacecast ptr addrspace(10) %atomic_escaped to ptr addrspace(11)
  %old = atomicrmw xchg ptr %p, ptr addrspace(11) %derived seq_cst
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; an allocation whose type tag or size varies in the loop stays, as does one that is
; only defined in the loop through a phi
; CHECK-LABEL: @alloc_variant(
; CHECK: loop:
; CHECK-NEXT: %tag = phi
; CHECK-NEXT: %obj = call {{.*}}@julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) %tag)
; CHECK-NEXT: %phi_obj = call {{.*}}@julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
; CHECK-NEXT: br label %latch
define void @alloc_variant(ptr addrspace(10) %tag1, ptr addrspace(10) %tag2, i1 %c) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  br label %loop
loop:
  %tag = phi ptr addrspace(10) [ %tag1, %top ], [ %tag2, %latch ]
  %obj = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) %tag)
  %phi_obj = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  br label %latch
latch:
  %merged = phi ptr addrspace(10) [ %phi_obj, %loop ]
  store i64 1, ptr addrspace(10) %merged
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; From Julia 1.11 on, an allocation stored to through `julia.gc_loaded` is hoisted
; (Julia 1.11's C++ pass takes that use for an escape)
; CHECK-LABEL: @alloc_loaded(
; LOADED: top:
; LOADED: %obj = call {{.*}}@julia.gc_alloc_obj
; LOADED-NEXT: call void @llvm.memset
; LOADED: loop:
; NOLOADED: loop:
; NOLOADED-NEXT: %obj = call {{.*}}@julia.gc_alloc_obj
; CHECK: %loaded = call ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10) %obj, ptr %data)
define void @alloc_loaded(ptr %data, i1 %c) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  br label %loop
loop:
  %obj = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %pgcstack, i64 8, ptr addrspace(10) @tag)
  %loaded = call ptr addrspace(13) @julia.gc_loaded(ptr addrspace(10) %obj, ptr %data)
  store i64 1, ptr addrspace(13) %loaded
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

; the pass is not required: functions marked optnone are skipped
; CHECK-LABEL: @skipped(
; CHECK: loop:
; CHECK-NEXT: %token = call token (...) @llvm.julia.gc_preserve_begin
define void @skipped(ptr addrspace(10) %obj, i1 %c) noinline optnone {
top:
  br label %loop
loop:
  %token = call token (...) @llvm.julia.gc_preserve_begin(ptr addrspace(10) %obj)
  call void @llvm.julia.gc_preserve_end(token %token)
  br i1 %c, label %exit, label %loop
exit:
  ret void
}

!0 = !{}
