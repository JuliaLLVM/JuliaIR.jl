; The metadata of global variables is mapped without the type mapper and materializer,
; like Julia does, so it is mapped after the initializers, function bodies and aliasees:
; otherwise those would reuse the constant expressions it maps, which keep their old
; types. Julia's pass maps it right after the initializer of each global variable, so the
; metadata of @first breaks the initializer of @h there, and would break the function
; and the alias too; the port also maps the metadata of declarations like @d.

; RUN: opt -passes='jl-remove-addrspaces,verify' -S %s | FileCheck %s

; CHECK: @d = external global i64, !foo ![[MD:[0-9]+]], !bar ![[OTHER:[0-9]+]]
; CHECK-NEXT: @first = global i64 0, !foo ![[MD]]
; CHECK-NEXT: @g = global i64 0
; CHECK-NEXT: @h = global ptr @g, !foo ![[MD]]
; CHECK-NEXT: @own = global ptr @g, !foo ![[MD]]
@d = external addrspace(10) global i64, !foo !0, !bar !2
@first = global i64 0, !foo !0
@g = addrspace(10) global i64 0
@h = global ptr addrspace(11) addrspacecast (ptr addrspace(10) @g to ptr addrspace(11)), !foo !0
@own = global ptr addrspace(12) addrspacecast (ptr addrspace(10) @g to ptr addrspace(12)), !foo !1

; CHECK: @a = alias i64, ptr @first
@a = alias i64, ptr addrspace(11) addrspacecast (ptr @first to ptr addrspace(11))

; CHECK-LABEL: define ptr @f()
; CHECK-NEXT: ret ptr @g
define ptr addrspace(13) @f() {
  ret ptr addrspace(13) addrspacecast (ptr addrspace(10) @g to ptr addrspace(13))
}

; CHECK-DAG: ![[MD]] = !{ptr @g}
; CHECK-DAG: ![[OTHER]] = !{ptr @g, ptr @first}
!0 = !{ptr addrspace(11) addrspacecast (ptr addrspace(10) @g to ptr addrspace(11))}
!1 = !{ptr addrspace(12) addrspacecast (ptr addrspace(10) @g to ptr addrspace(12))}
!2 = !{ptr addrspace(13) addrspacecast (ptr addrspace(10) @g to ptr addrspace(13)), ptr addrspace(11) addrspacecast (ptr @first to ptr addrspace(11))}
