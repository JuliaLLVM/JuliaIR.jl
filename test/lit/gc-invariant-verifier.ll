; GCInvariantVerifier reports every violation in a function, then aborts `jlopt` (the
; C++ pass prints them and calls abort()); a valid function passes unchanged.

; RUN: split-file %s %t
; RUN: opt -passes='function(jl-gc-invariant-verifier)' -S %t/valid.ll | FileCheck %s --check-prefix=VALID
; RUN: opt -passes='function(GCInvariantVerifier)' -S %t/valid.ll | FileCheck %s --check-prefix=VALID
; RUN: not --crash opt -passes='function(GCInvariantVerifier)' -S %t/invalid.ll 2>&1 | FileCheck %s --check-prefix=INVALID
; RUN: not --crash opt -passes='function(GCInvariantVerifier<no-strong>)' -S %t/invalid.ll 2>&1 | FileCheck %s --check-prefix=INVALID

; GEPs of tracked pointers are only rejected by the strong check
; RUN: opt -passes='function(jl-gc-invariant-verifier)' -S %t/gep.ll -o /dev/null
; RUN: not --crash opt -passes='function(jl-gc-invariant-verifier<strong>)' -S %t/gep.ll 2>&1 | FileCheck %s --check-prefix=GEP

; vectors of pointers are checked from Julia 1.12 on
; RUN: %if julia-1.10 || julia-1.11 %{ opt -passes='function(jl-gc-invariant-verifier)' -S %t/vector.ll -o /dev/null %}
; RUN: %if julia-ge-1.12 %{ not --crash opt -passes='function(jl-gc-invariant-verifier)' -S %t/vector.ll 2>&1 | FileCheck %s --check-prefix=VECTOR %}
; RUN: %if julia-1.10 || julia-1.11 %{ opt -passes='function(jl-gc-invariant-verifier)' -S %t/scalable.ll -o /dev/null %}
; RUN: %if julia-ge-1.12 %{ not --crash opt -passes='function(jl-gc-invariant-verifier)' -S %t/scalable.ll 2>&1 | FileCheck %s --check-prefix=SCALABLE %}

; jlcall arguments: on Julia 1.10, the function (in address space 0) and tracked
; arguments; from 1.11 on, the variadic arguments after the fixed ones
; RUN: %if julia-1.10 %{ opt -passes='function(jl-gc-invariant-verifier)' -S %t/jlcall110.ll -o /dev/null %}
; RUN: %if julia-ge-1.11 %{ not --crash opt -passes='function(jl-gc-invariant-verifier)' -S %t/jlcall110.ll 2>&1 | FileCheck %s --check-prefix=JLCALL %}
; RUN: %if julia-ge-1.11 %{ opt -passes='function(jl-gc-invariant-verifier)' -S %t/jlcall.ll -o /dev/null %}
; RUN: %if julia-1.10 %{ not --crash opt -passes='function(jl-gc-invariant-verifier)' -S %t/jlcall.ll 2>&1 | FileCheck %s --check-prefix=JLCALL %}
; RUN: %if julia-ge-1.11 %{ opt -passes='function(jl-gc-invariant-verifier)' -S %t/jlcall3.ll -o /dev/null %}
; RUN: %if julia-ge-1.11 %{ not --crash opt -passes='function(jl-gc-invariant-verifier)' -S %t/jlcall3-invalid.ll 2>&1 | FileCheck %s --check-prefix=JLCALL %}

; field barriers (Julia 1.14 and later) must be whole-object barriers in field-precise
; builds
; RUN: %if julia-1.14 %{ opt -passes='function(jl-gc-invariant-verifier)' -S %t/object-barrier.ll -o /dev/null %}
; RUN: %if julia-1.14 %{ not --crash opt -passes='function(jl-gc-invariant-verifier<gc-barrier=field-precise>)' -S %t/object-barrier.ll 2>&1 | FileCheck %s --check-prefix=PRECISE %}

; the port ran, and on optnone functions too
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=GCInvariantVerifier -S %t/valid.ll -o /dev/null
; RUN: grep -c 'pass	jl-gc-invariant-verifier	julia=' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 2

;--- valid.ll
; VALID-LABEL: @valid(
define ptr addrspace(10) @valid(ptr addrspace(10) %obj, ptr %p) {
  %derived = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  %rooted = addrspacecast ptr addrspace(10) %obj to ptr addrspace(12)
  %generic = addrspacecast ptr %p to ptr addrspace(10)
  %gep = getelementptr i8, ptr addrspace(11) %derived, i64 8
  %field = load ptr addrspace(10), ptr addrspace(11) %gep
  store ptr addrspace(10) %field, ptr addrspace(11) %gep
  %int = ptrtoint ptr %p to i64
  ret ptr addrspace(10) %field
}

; VALID-LABEL: @skipped(
define void @skipped() noinline optnone {
  ret void
}

;--- invalid.ll
; INVALID: GC invariants are violated in function invalid
; INVALID-NEXT: Illegal address space cast involving loaded ptr
; INVALID-NEXT: %loaded = addrspacecast ptr addrspace(13) %l to ptr addrspace(11)
; INVALID-NEXT: Illegal address space cast from tracked ptr
; INVALID-NEXT: %untracked = addrspacecast ptr addrspace(10) %obj to ptr
; INVALID-NEXT: Illegal address space cast from decayed ptr
; INVALID-NEXT: %retracked = addrspacecast ptr addrspace(11) %derived to ptr addrspace(10)
; INVALID-NEXT: Illegal load of gc relevant value
; INVALID-NEXT: %decayed = load ptr addrspace(11), ptr %p
; INVALID-NEXT: Illegal load of callee rooted value
; INVALID-NEXT: %fromrooted = load i64, ptr addrspace(12) %rooted
; INVALID-NEXT: Illegal store of decayed value
; INVALID-NEXT: store ptr addrspace(11) %derived, ptr %p
; INVALID-NEXT: Illegal store to callee rooted value
; INVALID-NEXT: store i64 0, ptr addrspace(12) %rooted
; INVALID-NEXT: Illegal store of decayed value
; INVALID-NEXT: %xchg = atomicrmw xchg ptr addrspace(12) %rooted, {{(ptr addrspace\(12\) )?}}%rooted
; INVALID-NEXT: Illegal store to callee rooted value
; INVALID-NEXT: %xchg = atomicrmw xchg ptr addrspace(12) %rooted, {{(ptr addrspace\(12\) )?}}%rooted
; INVALID-NEXT: Illegal store of decayed value
; INVALID-NEXT: %pair = cmpxchg ptr %p, ptr addrspace(11) %derived, ptr addrspace(11) %derived
; INVALID-NEXT: Illegal inttoptr
; INVALID-NEXT: %fromint = inttoptr i64 0 to ptr addrspace(10)
; INVALID-NEXT: Illegal ptrtoint
; INVALID-NEXT: %toint = ptrtoint ptr addrspace(10) %obj to i64
; INVALID-NEXT: Only gc tracked values may be directly returned
; INVALID-NEXT: ret ptr addrspace(11) %derived
define ptr addrspace(11) @invalid(ptr addrspace(10) %obj, ptr addrspace(13) %l, ptr %p) {
  %loaded = addrspacecast ptr addrspace(13) %l to ptr addrspace(11)
  %untracked = addrspacecast ptr addrspace(10) %obj to ptr
  %derived = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  %retracked = addrspacecast ptr addrspace(11) %derived to ptr addrspace(10)
  %rooted = addrspacecast ptr addrspace(10) %obj to ptr addrspace(12)
  %decayed = load ptr addrspace(11), ptr %p
  %fromrooted = load i64, ptr addrspace(12) %rooted
  store ptr addrspace(11) %derived, ptr %p
  store i64 0, ptr addrspace(12) %rooted
  %xchg = atomicrmw xchg ptr addrspace(12) %rooted, ptr addrspace(12) %rooted seq_cst
  %pair = cmpxchg ptr %p, ptr addrspace(11) %derived, ptr addrspace(11) %derived seq_cst seq_cst
  %fromint = inttoptr i64 0 to ptr addrspace(10)
  %toint = ptrtoint ptr addrspace(10) %obj to i64
  ret ptr addrspace(11) %derived
}

;--- gep.ll
; GEP: GC tracked values may not appear in GEP expressions
; GEP-NEXT: %gep = getelementptr i8, ptr addrspace(10) %obj, i64 8
define void @gep(ptr addrspace(10) %obj) {
  %gep = getelementptr i8, ptr addrspace(10) %obj, i64 8
  ret void
}

;--- vector.ll
; VECTOR: Illegal store of decayed value
; VECTOR-NEXT: store <2 x ptr addrspace(11)> %v, ptr %p
; VECTOR-NEXT: Only gc tracked values may be directly returned
define <2 x ptr addrspace(11)> @vector(<2 x ptr addrspace(11)> %v, ptr %p) {
  store <2 x ptr addrspace(11)> %v, ptr %p
  ret <2 x ptr addrspace(11)> %v
}

;--- scalable.ll
; SCALABLE: Illegal store of decayed value
; SCALABLE-NEXT: store <vscale x 2 x ptr addrspace(11)> %v, ptr %p
define void @scalable(<vscale x 2 x ptr addrspace(11)> %v, ptr %p) {
  store <vscale x 2 x ptr addrspace(11)> %v, ptr %p
  ret void
}

;--- jlcall110.ll
; JLCALL: Invalid derived pointer in jlcall
declare ptr addrspace(10) @julia.call(...)
define ptr addrspace(10) @jlcall(ptr %f, ptr addrspace(10) %x) {
  %r = call ptr addrspace(10) (...) @julia.call(ptr %f, ptr addrspace(10) %x)
  ret ptr addrspace(10) %r
}

;--- jlcall.ll
declare ptr addrspace(10) @julia.call(ptr addrspace(10), ...)
define ptr addrspace(10) @jlcall(ptr addrspace(10) %f, ptr addrspace(10) %x) {
  %r = call ptr addrspace(10) (ptr addrspace(10), ...) @julia.call(ptr addrspace(10) %f, ptr addrspace(10) %x)
  ret ptr addrspace(10) %r
}

;--- jlcall3.ll
declare ptr addrspace(10) @julia.call3(ptr, ptr addrspace(10), ...)
define ptr addrspace(10) @jlcall3(ptr %f, ptr addrspace(10) %x) {
  %r = call ptr addrspace(10) (ptr, ptr addrspace(10), ...) @julia.call3(ptr %f, ptr addrspace(10) %x, ptr addrspace(10) %x)
  ret ptr addrspace(10) %r
}

;--- jlcall3-invalid.ll
declare ptr addrspace(10) @julia.call3(ptr, ptr addrspace(10), ...)
define ptr addrspace(10) @jlcall3(ptr %f, ptr addrspace(10) %x, ptr addrspace(11) %d) {
  %r = call ptr addrspace(10) (ptr, ptr addrspace(10), ...) @julia.call3(ptr %f, ptr addrspace(10) %x, ptr addrspace(11) %d)
  ret ptr addrspace(10) %r
}

;--- object-barrier.ll
; PRECISE: Object write barrier is not permitted with field-precise barriers
declare void @julia.object_write_barrier(ptr addrspace(10), ...)
define void @barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child) {
  call void (ptr addrspace(10), ...) @julia.object_write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %child)
  ret void
}
