; RemoveJuliaAddrspaces maps Julia's address spaces (10 to 13) to 0 and keeps the others,
; rebuilding every global value of the module.

; RUN: opt -passes=jl-remove-addrspaces -S %s | FileCheck %s --implicit-check-not=.bad --implicit-check-not='addrspace(1{{[0-3]}})'
; RUN: opt -passes='jl-remove-addrspaces,verify' -S %s -o /dev/null
; RUN: opt -passes='jl-remove-addrspaces,function(instcombine,simplifycfg)' -S %s -o /dev/null

; Julia's name for the pass runs the port
; RUN: opt --load-pass-plugin=libjulia-codegen%shlibext -passes=RemoveJuliaAddrspaces -S %s | FileCheck %s --implicit-check-not=.bad --implicit-check-not='addrspace(1{{[0-3]}})'

; the port ran (it is a module pass, which runs at -O0 and on optnone functions too)
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes=RemoveJuliaAddrspaces -S %s -o /dev/null
; RUN: FileCheck --check-prefix=LEDGER %s < %t.ledger
; LEDGER: jlopt jl-remove-addrspaces
; LEDGER-NEXT: pass jl-remove-addrspaces julia=

; Identified structs that contain something are recreated, also when nothing in them
; changes, and take the name of the old one (which is renamed `.bad` and no longer
; appears); opaque structs are kept
; CHECK-DAG: %list = type { i64, ptr }
; CHECK-DAG: %rec = type { ptr, ptr }
; CHECK-DAG: %plain = type { i64, i32 }
; CHECK-DAG: %T = type { ptr, i64 }
; CHECK-DAG: %opaque = type opaque
%list = type { i64, ptr addrspace(10) }
%rec = type { ptr addrspace(10), ptr }
%opaque = type opaque
%plain = type { i64, i32 }
%T = type { ptr addrspace(10), i64 }

; CHECK-DAG: $c_any = comdat any
; CHECK-DAG: $c_nodedup = comdat nodeduplicate
; CHECK-DAG: $f_comdat = comdat any
$c_any = comdat any
$c_nodedup = comdat nodeduplicate
$f_comdat = comdat any

; global variables lose the address space of their own, and keep their attributes
; and metadata, also declarations (unlike Julia's pass, which drops the metadata of
; declarations)
; CHECK: @ext = external global i64, !foo ![[ONE:[0-9]+]]
; CHECK-NEXT: @g = global [4 x ptr] zeroinitializer, align 16, !foo ![[ONE]], !foo ![[G:[0-9]+]]
@ext = external addrspace(10) global i64, !foo !0
@g = addrspace(10) global [4 x ptr addrspace(10)] zeroinitializer, align 16, !foo !0, !foo !1

; constant expressions in initializers: casts to the same address space are folded,
; getelementptrs rebuilt, other casts kept
; CHECK-NEXT: @folded = global ptr @g
; CHECK-NEXT: @gep = global ptr getelementptr inbounds ([4 x ptr], ptr @g, i64 0, i64 2)
; CHECK-NEXT: @nested = global i64 ptrtoint (ptr @g to i64)
; CHECK-NEXT: @kept = global ptr addrspace(1) addrspacecast (ptr @g to ptr addrspace(1))
; casts of vectors of pointers too (LLVM 23 turns the vector getelementptr into a vector
; of scalar ones when it parses it)
; CHECK-NEXT: @vec_folded = global <2 x ptr> {{getelementptr \(i8, ptr @g, <2 x i64> <i64 0, i64 8>\)|<ptr @g, ptr getelementptr \(i8, ptr @g, i64 8\)>}}
@folded = global ptr addrspace(11) addrspacecast (ptr addrspace(10) @g to ptr addrspace(11))
@gep = global ptr addrspace(10) getelementptr inbounds ([4 x ptr addrspace(10)], ptr addrspace(10) @g, i64 0, i64 2)
@nested = global i64 ptrtoint (ptr addrspace(11) addrspacecast (ptr addrspace(10) @g to ptr addrspace(11)) to i64)
@kept = global ptr addrspace(1) addrspacecast (ptr addrspace(10) @g to ptr addrspace(1))
@vec_folded = global <2 x ptr addrspace(11)> addrspacecast (<2 x ptr addrspace(10)> getelementptr (i8, ptr addrspace(10) @g, <2 x i64> <i64 0, i64 8>) to <2 x ptr addrspace(11)>)

; CHECK-NEXT: @tls = thread_local(initialexec) global ptr null
; CHECK-NEXT: @attrs = internal unnamed_addr constant i64 1, section "jl_data", align 32
; CHECK-NEXT: @dso = dso_local externally_initialized global ptr null
; CHECK-NEXT: @hidden = hidden global %T zeroinitializer
; CHECK-NEXT: @in_any = global i64 0, comdat($c_any)
; CHECK-NEXT: @in_nodedup = global i64 0, comdat($c_nodedup)
; CHECK-NEXT: @0 = private global ptr null
; CHECK-NEXT: @unnamed_ref = global ptr @0
; CHECK-NEXT: @opq = external global %opaque
; CHECK-NEXT: @llvm.used = appending global [2 x ptr] [ptr @g, ptr @tls], section "llvm.metadata"
@tls = thread_local(initialexec) global ptr addrspace(10) null
@attrs = internal unnamed_addr constant i64 1, section "jl_data", align 32
@dso = dso_local externally_initialized global ptr addrspace(10) null
@hidden = hidden global %T zeroinitializer
@in_any = global i64 0, comdat($c_any)
@in_nodedup = global i64 0, comdat($c_nodedup)
@0 = private global ptr addrspace(10) null
@unnamed_ref = global ptr @0
@opq = external global %opaque
@llvm.used = appending global [2 x ptr] [ptr addrspacecast (ptr addrspace(10) @g to ptr), ptr @tls], section "llvm.metadata"

; CHECK: @alias = alias [4 x ptr], ptr @g
; CHECK-NEXT: @alias_expr = internal alias ptr, getelementptr (i8, ptr @g, i64 8)
@alias = alias [4 x ptr addrspace(10)], ptr addrspace(10) @g
@alias_expr = internal alias ptr addrspace(10), getelementptr (i8, ptr addrspace(10) @g, i64 8)

; intrinsics are renamed after their new types, reusing a declaration that exists
; CHECK: declare void @llvm.memcpy.p0.p0.i64(
declare void @llvm.memcpy.p10.p10.i64(ptr addrspace(10), ptr addrspace(10), i64, i1 immarg)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1 immarg)
declare void @llvm.memmove.p10.p0.i64(ptr addrspace(10), ptr, i64, i1 immarg)
declare ptr addrspace(10) @llvm.ptrmask.p10.i64(ptr addrspace(10), i64)
declare <2 x i64> @llvm.masked.gather.v2i64.v2p10(<2 x ptr addrspace(10)>, i32, <2 x i1>, <2 x i64>)

; declarations keep their attributes, and the types of all type attributes are mapped
; (Julia's pass only maps those of byval, sret and byref)
; CHECK: declare void @convergent() #[[CONVERGENT:[0-9]+]]
; CHECK: declare void @typed_attrs(ptr byval(%T), ptr sret(%T), ptr byref(%T))
; CHECK: declare void @inalloca(ptr inalloca(%T))
; CHECK: declare void @preallocated(ptr preallocated(%T))
; CHECK: declare ptr @returns(ptr nonnull dereferenceable(16))
; CHECK: declare i32 @personality(...)
; CHECK: declare void @vararg(ptr, ...)
declare void @convergent() #0
declare void @typed_attrs(ptr addrspace(10) byval(%T), ptr addrspace(11) sret(%T), ptr addrspace(11) byref(%T))
declare void @inalloca(ptr inalloca(%T))
declare void @preallocated(ptr preallocated(%T))
declare ptr addrspace(10) @returns(ptr addrspace(10) nonnull dereferenceable(16))
declare i32 @personality(...)
declare void @vararg(ptr addrspace(10), ...)

; CHECK: define void @signature(ptr nonnull align 16 dereferenceable(32) %boxed, ptr %derived, ptr %rooted, ptr %loaded, ptr addrspace(1) %global, ptr addrspace(3) %shared, ptr %generic)
define void @signature(ptr addrspace(10) nonnull align 16 dereferenceable(32) %boxed, ptr addrspace(11) %derived, ptr addrspace(12) %rooted, ptr addrspace(13) %loaded, ptr addrspace(1) %global, ptr addrspace(3) %shared, ptr %generic) {
  ret void
}

; casts that become casts to the same address space are removed, of vectors too
; CHECK-LABEL: define ptr @casts(ptr %p, <2 x ptr> %v, ptr %q)
; CHECK-NEXT: %global = addrspacecast ptr %q to ptr addrspace(1)
; CHECK-NEXT: %back = addrspacecast ptr addrspace(1) %global to ptr
; CHECK-NEXT: %elt = extractelement <2 x ptr> %v, i32 0
; CHECK-NEXT: store ptr addrspace(1) %global, ptr %elt
; CHECK-NEXT: store ptr %back, ptr %p
; CHECK-NEXT: ret ptr %p
define ptr addrspace(11) @casts(ptr addrspace(10) %p, <2 x ptr addrspace(10)> %v, ptr %q) {
  %derived = addrspacecast ptr addrspace(10) %p to ptr addrspace(11)
  %vec = addrspacecast <2 x ptr addrspace(10)> %v to <2 x ptr addrspace(11)>
  %global = addrspacecast ptr %q to ptr addrspace(1)
  %back = addrspacecast ptr addrspace(1) %global to ptr addrspace(10)
  %elt = extractelement <2 x ptr addrspace(11)> %vec, i32 0
  store ptr addrspace(1) %global, ptr addrspace(11) %elt
  store ptr addrspace(10) %back, ptr addrspace(11) %derived
  ret ptr addrspace(11) %derived
}

; CHECK-LABEL: define i64 @structs(ptr %p)
; CHECK-NEXT: %list = alloca %list
; CHECK-NEXT: %rec = alloca %rec
; CHECK-NEXT: %plain = alloca %plain
; CHECK-NEXT: %lit = alloca { ptr, <2 x ptr> }
; CHECK-NEXT: %packed = alloca <{ i8, ptr }>
; CHECK-NEXT: %arr = alloca [2 x ptr]
; CHECK-NEXT: %next = getelementptr %list, ptr %list, i32 0, i32 1
; CHECK-NEXT: store ptr %p, ptr %next
; CHECK-NEXT: %v = load %list, ptr %list
; CHECK-NEXT: %car = extractvalue %list %v, 0
; CHECK-NEXT: %o = load ptr, ptr %rec
; CHECK-NEXT: %f = getelementptr %plain, ptr %plain, i32 0, i32 1
define i64 @structs(ptr addrspace(10) %p) {
  %list = alloca %list
  %rec = alloca %rec
  %plain = alloca %plain
  %lit = alloca { ptr addrspace(10), <2 x ptr addrspace(11)> }
  %packed = alloca <{ i8, ptr addrspace(10) }>
  %arr = alloca [2 x ptr addrspace(10)]
  %next = getelementptr %list, ptr %list, i32 0, i32 1
  store ptr addrspace(10) %p, ptr %next
  %v = load %list, ptr %list
  %car = extractvalue %list %v, 0
  %o = load ptr, ptr %rec
  %f = getelementptr %plain, ptr %plain, i32 0, i32 1
  ret i64 %car
}

; CHECK: define <vscale x 2 x ptr> @scalable(<vscale x 2 x ptr> %v)
define <vscale x 2 x ptr addrspace(10)> @scalable(<vscale x 2 x ptr addrspace(10)> %v) {
  ret <vscale x 2 x ptr addrspace(10)> %v
}

; (LLVM 16 and older rebuild a mapped `poison` as `undef`, as for Julia's pass; LLVM 23
; turns the alignment operand of `llvm.masked.gather` into an attribute.)
; CHECK-LABEL: define void @calls(ptr %p, ptr %q, i1 %c) personality ptr @personality
; CHECK-NEXT: entry:
; CHECK-NEXT: call void @llvm.memcpy.p0.p0.i64(ptr %p, ptr %p, i64 8, i1 false)
; CHECK-NEXT: call void @llvm.memcpy.p0.p0.i64(ptr %q, ptr %q, i64 8, i1 false)
; CHECK-NEXT: call void @llvm.memmove.p0.p0.i64(ptr %p, ptr %q, i64 8, i1 false)
; CHECK-NEXT: %masked = call ptr @llvm.ptrmask.p0.i64(ptr %p, i64 -8)
; CHECK-NEXT: %ps = insertelement <2 x ptr> {{poison|undef}}, ptr %p, i32 0
; CHECK-NEXT: %gathered = call <2 x i64> @llvm.masked.gather.v2i64.v2p0(<2 x ptr> {{(align 8 )?}}%ps,
; CHECK-NEXT: call void @typed_attrs(ptr byval(%T) %p, ptr sret(%T) null, ptr byref(%T) null)
; CHECK-NEXT: call void @inalloca(ptr inalloca(%T) %q)
; CHECK-NEXT: call void @vararg(ptr %p, ptr %p, i64 1)
; CHECK-NEXT: call void asm sideeffect "", "r,*m"(ptr %p, ptr elementtype(%T) null)
; CHECK-NEXT: %r = call ptr @returns(ptr %p)
; CHECK-NEXT: invoke void @convergent()
; CHECK: ok:
; CHECK-NEXT: %sel = select i1 %c, ptr %p, ptr %r
; CHECK-NEXT: %rmw = atomicrmw xchg ptr %q, {{(ptr )?}}%sel seq_cst
; CHECK-NEXT: %cas = cmpxchg ptr %q, ptr %rmw, ptr null acquire monotonic
; CHECK-NEXT: store atomic ptr @g, ptr %q unordered, align 8
; CHECK-NEXT: %fptr = load ptr, ptr @tls
; CHECK: lpad:
; CHECK-NEXT: %lp = landingpad { ptr, i32 }
; CHECK: exit:
; CHECK-NEXT: %phi = phi ptr [ %fptr, %ok ], [ null, %lpad ]
define void @calls(ptr addrspace(10) %p, ptr %q, i1 %c) personality ptr @personality {
entry:
  call void @llvm.memcpy.p10.p10.i64(ptr addrspace(10) %p, ptr addrspace(10) %p, i64 8, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr %q, ptr %q, i64 8, i1 false)
  call void @llvm.memmove.p10.p0.i64(ptr addrspace(10) %p, ptr %q, i64 8, i1 false)
  %masked = call ptr addrspace(10) @llvm.ptrmask.p10.i64(ptr addrspace(10) %p, i64 -8)
  %ps = insertelement <2 x ptr addrspace(10)> poison, ptr addrspace(10) %p, i32 0
  %gathered = call <2 x i64> @llvm.masked.gather.v2i64.v2p10(<2 x ptr addrspace(10)> %ps, i32 8, <2 x i1> <i1 true, i1 false>, <2 x i64> poison)
  call void @typed_attrs(ptr addrspace(10) byval(%T) %p, ptr addrspace(11) sret(%T) null, ptr addrspace(11) byref(%T) null)
  call void @inalloca(ptr inalloca(%T) %q)
  call void @vararg(ptr addrspace(10) %p, ptr addrspace(10) %p, i64 1)
  call void asm sideeffect "", "r,*m"(ptr addrspace(10) %p, ptr addrspace(11) elementtype(%T) null)
  %r = call ptr addrspace(10) @returns(ptr addrspace(10) %p)
  invoke void @convergent() to label %ok unwind label %lpad

ok:
  %sel = select i1 %c, ptr addrspace(10) %p, ptr addrspace(10) %r
  %rmw = atomicrmw xchg ptr %q, ptr addrspace(10) %sel seq_cst
  %cas = cmpxchg ptr %q, ptr addrspace(10) %rmw, ptr addrspace(10) null acquire monotonic
  store atomic ptr addrspace(10) @g, ptr %q unordered, align 8
  %fptr = load ptr addrspace(10), ptr @tls
  br label %exit

lpad:
  %lp = landingpad { ptr, i32 } cleanup
  br label %exit

exit:
  %phi = phi ptr addrspace(10) [ %fptr, %ok ], [ null, %lpad ]
  ret void
}

; linkage, calling convention, GC, comdat and the order of functions are kept
; CHECK: define private fastcc void @private_fastcc(ptr %p) gc "julia"
define private fastcc void @private_fastcc(ptr addrspace(10) %p) gc "julia" {
  ret void
}

; CHECK: define internal void @in_comdat() comdat($f_comdat)
define internal void @in_comdat() comdat($f_comdat) {
  ret void
}

; a required pass: optnone functions are rewritten too
; CHECK-LABEL: define void @optnone(ptr %p)
; CHECK-NEXT: ret void
define void @optnone(ptr addrspace(10) %p) #1 {
  %d = addrspacecast ptr addrspace(10) %p to ptr addrspace(11)
  ret void
}

; intrinsic declarations that didn't exist come last
; CHECK: declare void @llvm.memmove.p0.p0.i64(
; CHECK: declare ptr @llvm.ptrmask.p0.i64(ptr, i64)
; CHECK: declare <2 x i64> @llvm.masked.gather.v2i64.v2p0(<2 x ptr>,

; CHECK: attributes #[[CONVERGENT]] = { convergent }
attributes #0 = { convergent }
attributes #1 = { noinline optnone }

; CHECK: ![[ONE]] = !{i64 1}
; CHECK: ![[G]] = !{ptr @g}
!0 = !{i64 1}
!1 = !{ptr addrspace(10) @g}
