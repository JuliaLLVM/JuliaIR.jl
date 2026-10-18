; The metadata of global variables is mapped without the type mapper, like Julia does, so
; it is mapped after all initializers: otherwise the initializers would reuse the
; constant expressions it maps, which keep their old types. Julia's pass maps it right
; after the initializer of each global variable, so the metadata of @first breaks the
; initializer of @h there; the port also maps the metadata of declarations like @d.

; RUN: opt -passes='jl-remove-addrspaces,verify' -S %s | FileCheck %s

; CHECK: @d = external global i64, !foo ![[MD:[0-9]+]]
; CHECK-NEXT: @first = global i64 0, !foo ![[MD]]
; CHECK-NEXT: @g = global i64 0
; CHECK-NEXT: @h = global ptr @g, !foo ![[MD]]
; CHECK-NEXT: @own = global ptr @g, !foo ![[MD]]
@d = external addrspace(10) global i64, !foo !0
@first = global i64 0, !foo !0
@g = addrspace(10) global i64 0
@h = global ptr addrspace(11) addrspacecast (ptr addrspace(10) @g to ptr addrspace(11)), !foo !0
@own = global ptr addrspace(12) addrspacecast (ptr addrspace(10) @g to ptr addrspace(12)), !foo !1

; CHECK: ![[MD]] = !{ptr @g}
!0 = !{ptr addrspace(11) addrspacecast (ptr addrspace(10) @g to ptr addrspace(11))}
!1 = !{ptr addrspace(12) addrspacecast (ptr addrspace(10) @g to ptr addrspace(12))}
