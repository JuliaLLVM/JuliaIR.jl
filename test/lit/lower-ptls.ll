; LowerPTLS (jl-lower-ptls) on the IR of every Julia version: the lowering of the GC stack
; getters in JIT mode (through the thread pointer or the runtime's getter), in imaging
; mode (through the variables of the system image), and the thread adoption and GC state
; transitions of `julia.get_pgcstack_or_new`.

; The runtime facts are given as pass options (x86-64 Linux's values), so that the output
; doesn't depend on the running Julia.
; RUN: split-file %s %t

; JIT mode, through the thread pointer
; RUN: %if julia-1.10 %{ opt -passes='jl-lower-ptls<tls-offset=-8>' -S %t/jit.ll | FileCheck %t/jit.ll --check-prefixes=CHECK,NOINB,SWIFT,KEEPNAME %}
; RUN: %if julia-1.11 %{ opt -passes='jl-lower-ptls<tls-offset=-8>' -S %t/jit.ll | FileCheck %t/jit.ll --check-prefixes=CHECK,NOINB,SWIFT,TAKENAME %}
; RUN: %if julia-1.12 %{ opt -passes='jl-lower-ptls<tls-offset=-8>' -S %t/jit.ll | FileCheck %t/jit.ll --check-prefixes=CHECK,INB,SWIFT,TAKENAME %}
; RUN: %if julia-ge-1.13 %{ opt -passes='jl-lower-ptls<tls-offset=-8>' -S %t/jit.ll | FileCheck %t/jit.ll --check-prefixes=CHECK,INB,GCSTACK %}

; the thread pointer of each architecture (RISC-V's from Julia 1.12 on)
; RUN: opt -mtriple=aarch64-unknown-linux-gnu -passes='jl-lower-ptls<tls-offset=-8>' -S %t/arch.ll | FileCheck %t/arch.ll --check-prefix=AARCH64
; RUN: opt -mtriple=armv7l-unknown-linux-gnueabihf -passes='jl-lower-ptls<tls-offset=-8>' -S %t/arch.ll | FileCheck %t/arch.ll --check-prefix=ARM
; RUN: opt -mtriple=i686-unknown-linux-gnu -passes='jl-lower-ptls<tls-offset=-8>' -S %t/arch.ll | FileCheck %t/arch.ll --check-prefix=I686
; RUN: %if julia-ge-1.12 %{ opt -mtriple=riscv64-unknown-linux-gnu -passes='jl-lower-ptls<tls-offset=-8>' -S %t/arch.ll | FileCheck %t/arch.ll --check-prefix=RISCV %}
; RUN: %if julia-1.10 || julia-1.11 %{ not opt -mtriple=riscv64-unknown-linux-gnu -passes='jl-lower-ptls<tls-offset=-8>' -S %t/arch.ll 2>&1 | FileCheck %t/arch.ll --check-prefix=NOTP-RISCV %}
; RUN: not opt -mtriple=powerpc64le-unknown-linux-gnu -passes='jl-lower-ptls<tls-offset=-8>' -S %t/arch.ll 2>&1 | FileCheck %t/arch.ll --check-prefix=NOTP-PPC
; a module without a triple is for the running Julia's host
; RUN: %if x86_64 %{ opt -passes='jl-lower-ptls<tls-offset=-8>' -S %t/no-triple.ll | FileCheck %t/no-triple.ll %}

; JIT mode, through the getter: at the process address up to Julia 1.13 (with the key on
; Darwin), through `jl_get_pgcstack_resolved` on master (always with `tls-getters`)
; RUN: %if julia-1.10 || julia-1.11 || julia-1.12 || julia-1.13 %{ opt -passes='jl-lower-ptls<tls-offset=-1;pgcstack-getter=0x1000;pgcstack-key=0x2000>' -S %t/getter.ll | FileCheck %t/getter.ll --check-prefix=ADDRESS %}
; RUN: %if julia-1.10 || julia-1.11 || julia-1.12 || julia-1.13 %{ opt -mtriple=x86_64-apple-darwin -passes='jl-lower-ptls<tls-offset=-1;pgcstack-getter=0x1000;pgcstack-key=0x2000>' -S %t/getter.ll | FileCheck %t/getter.ll --check-prefix=ADDRESS-KEY %}
; RUN: %if julia-1.14 %{ opt -passes='jl-lower-ptls<tls-offset=-1>' -S %t/getter.ll | FileCheck %t/getter.ll --check-prefix=RESOLVED %}
; RUN: %if julia-1.14 %{ opt -passes='jl-lower-ptls<tls-offset=-8;tls-getters>' -S %t/getter.ll | FileCheck %t/getter.ll --check-prefix=RESOLVED %}
; RUN: %if julia-1.10 || julia-1.11 || julia-1.12 || julia-1.13 %{ not opt -passes='jl-lower-ptls<tls-offset=-8;tls-getters>' -S %t/getter.ll 2>&1 | FileCheck %t/getter.ll --check-prefix=NO-TLS-GETTERS %}

; imaging mode, with ELF TLS (the TLS offset, or the getter where the loader left it 0)
; and without (the getter, with the key on Darwin)
; RUN: %if julia-1.10 || julia-1.11 %{ opt -passes='jl-lower-ptls<imaging;tls-elf-support=yes>' -S %t/imaging.ll | FileCheck %t/imaging.ll --check-prefixes=ELF,NOINB -DOFFSET=jl_tls_offset %}
; RUN: %if julia-1.12 || julia-1.13 %{ opt -passes='jl-lower-ptls<imaging;tls-elf-support=yes>' -S %t/imaging.ll | FileCheck %t/imaging.ll --check-prefixes=ELF,INB -DOFFSET=jl_tls_offset %}
; RUN: %if julia-1.14 %{ opt -passes='jl-lower-ptls<imaging;tls-elf-support=yes>' -S %t/imaging.ll | FileCheck %t/imaging.ll --check-prefixes=ELF,INB -DOFFSET=jl_image_tls_offset %}
; RUN: opt -passes='jl-lower-ptls<imaging;tls-elf-support=no>' -S %t/imaging.ll | FileCheck %t/imaging.ll --check-prefix=NOELF
; RUN: opt -mtriple=x86_64-apple-darwin -passes='jl-lower-ptls<imaging;tls-elf-support=no>' -S %t/imaging.ll | FileCheck %t/imaging.ll --check-prefix=NOELF-KEY
; the image's variables are reused when the module declares them, and must match
; RUN: opt -passes='jl-lower-ptls<imaging;tls-elf-support=no>' -S %t/reuse.ll | FileCheck %t/reuse.ll
; RUN: not opt -passes='jl-lower-ptls<imaging;tls-elf-support=no>' -S %t/conflict.ll 2>&1 | FileCheck %t/conflict.ll

; `julia.get_pgcstack_or_new`: adopting the thread, entering and leaving the GC-unsafe
; state (1.12 has 1.13's fix of the entry safepoint); the safepoint page is loaded
; atomically from 1.13 on, through an address named on master
; RUN: %if julia-1.10 %{ opt -passes='jl-lower-ptls<tls-offset=-8;task-gcstack=112;task-ptls=128;tls-safepoint=16;tls-gc-state=25>' -S %t/or-new.ll | FileCheck %t/or-new.ll --check-prefixes=CHECK,LEGACY,V110,PLAINSP -DTASK=-14 -DPTLS=16 -DSTATE=25 %}
; RUN: %if julia-1.11 %{ opt -passes='jl-lower-ptls<tls-offset=-8;task-gcstack=112;task-ptls=128;tls-safepoint=16;tls-gc-state=25>' -S %t/or-new.ll | FileCheck %t/or-new.ll --check-prefixes=CHECK,LEGACY,V111,PLAINSP -DTASK=-14 -DPTLS=16 -DSTATE=25 %}
; RUN: %if julia-1.12 %{ opt -passes='jl-lower-ptls<tls-offset=-8;task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25>' -S %t/or-new.ll | FileCheck %t/or-new.ll --check-prefixes=CHECK,NEW,UNNAMEDSP,PLAINSP,V112 -DTASK=-152 -DPTLS=168 -DSTATE=25 %}
; RUN: %if julia-1.13 %{ opt -passes='jl-lower-ptls<tls-offset=-8;task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25>' -S %t/or-new.ll | FileCheck %t/or-new.ll --check-prefixes=CHECK,NEW,UNNAMEDSP,ATOMICSP -DTASK=-152 -DPTLS=168 -DSTATE=25 %}
; RUN: %if julia-1.14 %{ opt -passes='jl-lower-ptls<tls-offset=-8;task-gcstack=192;task-ptls=208;tls-safepoint=16;tls-gc-state=128>' -S %t/or-new.ll | FileCheck %t/or-new.ll --check-prefixes=CHECK,NEW,NAMEDSP,ATOMICSP -DTASK=-192 -DPTLS=208 -DSTATE=128 %}
; in imaging mode, the GC stack found through the image's variables
; RUN: opt -passes='jl-lower-ptls<imaging;tls-elf-support=yes;task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25>' -S %t/or-new-imaging.ll | FileCheck %t/or-new-imaging.ll

; uses that the pass can't lower are rejected before it changes anything
; RUN: not opt -passes='jl-lower-ptls<tls-offset=-8>' -S %t/errors.ll 2>&1 | FileCheck %t/errors.ll --check-prefix=NONCALL
; RUN: not opt -passes='jl-lower-ptls<tls-offset=-8>' -S %t/invoke.ll 2>&1 | FileCheck %t/invoke.ll
; RUN: not opt -passes='jl-lower-ptls<tls-offset=-8;task-gcstack=152;task-ptls=168;tls-safepoint=16;tls-gc-state=25>' -S %t/dominate.ll 2>&1 | FileCheck %t/dominate.ll

; a module without getters is left alone, without reading any fact
; RUN: opt -passes=jl-lower-ptls -S %t/none.ll | FileCheck %t/none.ll

; jlopt maps Julia's name, with its options, to the port
; RUN: rm -f %t.ledger
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes='LowerPTLSPass<imaging;tls-elf-support=no>' -S %t/reuse.ll -o /dev/null
; RUN: env JULIAIR_LEDGER=%t.ledger opt -passes='LowerPTLSPass<no-imaging;tls-offset=-8>' -S %t/reuse.ll -o /dev/null
; RUN: grep -c 'pass	jl-lower-ptls	julia=' %t.ledger | FileCheck --check-prefix=COUNT %s
; COUNT: 2

;--- jit.ll
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare ptr @julia.get_pgcstack()
declare i32 @sigsetjmp(ptr, i32) returns_twice
declare void @use(ptr)

; CHECK-NOT: @julia.get_pgcstack

; CHECK-LABEL: define ptr @get() {
; CHECK-NEXT:  top:
; CHECK-NEXT:    %thread_ptr = call ptr asm "movq %fs:0, $0", "=r"()
; NOINB-NEXT:    %tls_ppgcstack = getelementptr i8, ptr %thread_ptr, i64 -8
; INB-NEXT:      %tls_ppgcstack = getelementptr inbounds i8, ptr %thread_ptr, i64 -8
; CHECK-NEXT:    %tls_pgcstack = load ptr, ptr %tls_ppgcstack, align 8
; CHECK-NEXT:    ret ptr %tls_pgcstack
define ptr @get() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  ret ptr %pgcstack
}

; in a function that calls `setjmp`, the addition of the offset is hidden in the asm
; CHECK-LABEL: define ptr @returns_twice(
; CHECK-NEXT:  top:
; CHECK-NEXT:    %tls_pgcstack = call ptr asm "movq %fs:0, $0;\0Aaddq $$-8, $0", "=r,~{dirflag},~{fpsr},~{flags}"()
; CHECK-NEXT:    %tls_pgcstack1 = load ptr, ptr %tls_pgcstack, align 8
; CHECK-NEXT:    %r = call i32 @sigsetjmp(
; CHECK-NEXT:    ret ptr %tls_pgcstack1
define ptr @returns_twice(ptr %buf) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %r = call i32 @sigsetjmp(ptr %buf, i32 0)
  ret ptr %pgcstack
}

; also when `setjmp` is called with another type than it is declared with (LLVM still
; finds the attribute on the called function)
; CHECK-LABEL: define ptr @returns_twice_cast(
; CHECK-NEXT:  top:
; CHECK-NEXT:    %tls_pgcstack = call ptr asm "movq %fs:0, $0;\0Aaddq $$-8, $0", "=r,~{dirflag},~{fpsr},~{flags}"()
define ptr @returns_twice_cast(ptr %buf) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %r = call i32 @sigsetjmp(ptr %buf)
  ret ptr %pgcstack
}

; CHECK-LABEL: define void @dead() {
; CHECK-NEXT:  top:
; CHECK-NEXT:    ret void
define void @dead() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  ret void
}

; a function that gets its GC stack as an argument (`swiftself` up to Julia 1.12,
; `"gcstack"` from 1.13 on) uses it, under the name of the call from 1.11 on
; KEEPNAME-LABEL: define void @swiftself_arg(ptr swiftself %pgcstack_arg) {
; TAKENAME-LABEL: define void @swiftself_arg(ptr swiftself %pgcstack) {
; SWIFT-NEXT:     top:
; KEEPNAME-NEXT:    call void @use(ptr %pgcstack_arg)
; TAKENAME-NEXT:    call void @use(ptr %pgcstack)
; GCSTACK-LABEL:  define void @swiftself_arg(ptr swiftself %pgcstack_arg) {
; GCSTACK-NEXT:   top:
; GCSTACK-NEXT:     %thread_ptr = call ptr asm
define void @swiftself_arg(ptr swiftself %pgcstack_arg) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @use(ptr %pgcstack)
  ret void
}

; SWIFT-LABEL:   define void @gcstack_arg(ptr "gcstack" %pgcstack_arg) {
; SWIFT-NEXT:    top:
; SWIFT-NEXT:      %thread_ptr = call ptr asm
; GCSTACK-LABEL: define void @gcstack_arg(ptr "gcstack" %pgcstack) {
; GCSTACK-NEXT:  top:
; GCSTACK-NEXT:    call void @use(ptr %pgcstack)
define void @gcstack_arg(ptr "gcstack" %pgcstack_arg) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @use(ptr %pgcstack)
  ret void
}

;--- arch.ll
declare ptr @julia.get_pgcstack()
declare i32 @sigsetjmp(ptr, i32) returns_twice

; AARCH64-LABEL: define ptr @get()
; AARCH64:         %thread_ptr = call ptr asm "mrs $0, tpidr_el0", "=r"()
; AARCH64-NEXT:    %tls_ppgcstack = getelementptr {{(inbounds )?}}i8, ptr %thread_ptr, i64 -8
; ARM-LABEL:     define ptr @get()
; ARM:             %thread_ptr = call ptr asm "mrc p15, 0, $0, c13, c0, 3", "=r"()
; I686-LABEL:    define ptr @get()
; I686:            %thread_ptr = call ptr asm "movl %gs:0, $0", "=r"()
; RISCV-LABEL:   define ptr @get()
; RISCV:           %thread_ptr = call ptr asm "mv $0, tp", "=r"()
; NOTP-RISCV:    LowerPTLSError: can't read the thread pointer for target riscv64-unknown-linux-gnu; use the getter instead
; NOTP-PPC:      LowerPTLSError: can't read the thread pointer for target powerpc64le-unknown-linux-gnu; use the getter instead
define ptr @get() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  ret ptr %pgcstack
}

; only x86 hides the offset from a `setjmp`
; AARCH64-LABEL: define ptr @returns_twice(
; AARCH64:         %thread_ptr = call ptr asm "mrs $0, tpidr_el0", "=r"()
; I686-LABEL:    define ptr @returns_twice(
; I686:            %tls_pgcstack = call ptr asm "movl %gs:0, $0;\0Aaddl $$-8, $0", "=r,~{dirflag},~{fpsr},~{flags}"()
define ptr @returns_twice(ptr %buf) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %r = call i32 @sigsetjmp(ptr %buf, i32 0)
  ret ptr %pgcstack
}

;--- no-triple.ll
declare ptr @julia.get_pgcstack()

; CHECK-LABEL: define ptr @get()
; CHECK:         %thread_ptr = call ptr asm "movq %fs:0, $0", "=r"()
define ptr @get() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  ret ptr %pgcstack
}

;--- getter.ll
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare ptr @julia.get_pgcstack()
declare void @use(ptr)

; ADDRESS-LABEL:     define void @get()
; ADDRESS-NEXT:      top:
; ADDRESS-NEXT:        %pgcstack = call ptr inttoptr (i64 4096 to ptr)() #[[ATTRS:[0-9]+]]
; ADDRESS-NEXT:        call void @use(ptr %pgcstack)
; ADDRESS:           attributes #[[ATTRS]] = { nounwind {{memory\(none\)|readnone}} }
; ADDRESS-KEY-LABEL: define void @get()
; ADDRESS-KEY-NEXT:  top:
; ADDRESS-KEY-NEXT:    %pgcstack = call ptr inttoptr (i64 4096 to ptr)(i64 8192) #[[ATTRS:[0-9]+]]
; ADDRESS-KEY:       attributes #[[ATTRS]] = { nounwind {{memory\(none\)|readnone}} }
; RESOLVED-LABEL:    define void @get()
; RESOLVED-NEXT:     top:
; RESOLVED-NEXT:       %pgcstack = call ptr @jl_get_pgcstack_resolved() #[[ATTRS:[0-9]+]]
; RESOLVED:          declare void @jl_get_pgcstack_resolved()
; RESOLVED:          attributes #[[ATTRS]] = { nounwind memory(none) }
; NO-TLS-GETTERS:    the option tls-getters only exists on Julia master
define void @get() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @use(ptr %pgcstack)
  ret void
}

;--- imaging.ll
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare ptr @julia.get_pgcstack()
declare i32 @sigsetjmp(ptr, i32) returns_twice
declare void @use(ptr)

; ELF:       @jl_pgcstack_func_slot = external hidden global ptr
; ELF-NEXT:  @jl_pgcstack_key_slot = external hidden global i64
; ELF-NEXT:  @[[OFFSET]] = external hidden global i64
; NOELF:     @jl_pgcstack_func_slot = external hidden global ptr
; NOELF-KEY: @jl_pgcstack_func_slot = external hidden global ptr

; ELF-LABEL:   define void @get()
; ELF-NEXT:    top:
; ELF-NEXT:      %0 = load i64, ptr @[[OFFSET]], align 8, !tbaa ![[CONST:[0-9]+]], !invariant.load ![[EMPTY:[0-9]+]]
; ELF-NEXT:      %1 = icmp ne i64 %0, 0
; ELF-NEXT:      br i1 %1, label %2, label %3, !prof ![[WEIGHTS:[0-9]+]]
; ELF-EMPTY:
; ELF-NEXT:    2:
; ELF-NEXT:      %thread_ptr = call ptr asm "movq %fs:0, $0", "=r"()
; NOINB-NEXT:    %tls_ppgcstack = getelementptr i8, ptr %thread_ptr, i64 %0
; INB-NEXT:      %tls_ppgcstack = getelementptr inbounds i8, ptr %thread_ptr, i64 %0
; ELF-NEXT:      %tls_pgcstack = load ptr, ptr %tls_ppgcstack, align 8
; ELF-NEXT:      br label %5
; ELF-EMPTY:
; ELF-NEXT:    3:
; ELF-NEXT:      %4 = load ptr, ptr @jl_pgcstack_func_slot, align 8, !tbaa ![[CONST]], !invariant.load ![[EMPTY]]
; ELF-NEXT:      %pgcstack = call ptr %4() #[[ATTRS:[0-9]+]]
; ELF-NEXT:      br label %5
; ELF-EMPTY:
; ELF-NEXT:    5:
; ELF-NEXT:      %pgcstack1 = phi ptr [ %tls_pgcstack, %2 ], [ %pgcstack, %3 ]
; ELF-NEXT:      call void @use(ptr %pgcstack1)
; NOELF-LABEL: define void @get()
; NOELF-NEXT:  top:
; NOELF-NEXT:    %0 = load ptr, ptr @jl_pgcstack_func_slot, align 8, !tbaa ![[CONST:[0-9]+]], !invariant.load
; NOELF-NEXT:    %pgcstack = call ptr %0() #[[ATTRS:[0-9]+]]
; NOELF-NEXT:    call void @use(ptr %pgcstack)
; NOELF-KEY-LABEL: define void @get()
; NOELF-KEY-NEXT:  top:
; NOELF-KEY-NEXT:    %0 = load ptr, ptr @jl_pgcstack_func_slot, align 8, !tbaa ![[CONST:[0-9]+]], !invariant.load
; NOELF-KEY-NEXT:    %1 = load i64, ptr @jl_pgcstack_key_slot, align 8, !tbaa ![[CONST]], !invariant.load
; NOELF-KEY-NEXT:    %pgcstack = call ptr %0(i64 %1) #[[ATTRS:[0-9]+]]
define void @get() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @use(ptr %pgcstack)
  ret void
}

; ELF-LABEL: define void @returns_twice(
; ELF:         %pgcstack1 = call ptr asm "movq %fs:0, $0;\0Aaddq $1, $0", "=&r,r,~{dirflag},~{fpsr},~{flags}"(i64 %0)
; ELF-NEXT:    %tls_pgcstack = load ptr, ptr %pgcstack1, align 8
define void @returns_twice(ptr %buf) {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  %r = call i32 @sigsetjmp(ptr %buf, i32 0)
  call void @use(ptr %pgcstack)
  ret void
}

; ELF:       attributes #[[ATTRS]] = { nounwind {{memory\(none\)|readnone}} }
; ELF:       ![[CONST]] = !{![[CONST_T:[0-9]+]], ![[CONST_T]], i64 0, i64 1}
; ELF:       ![[CONST_T]] = !{!"jtbaa_const"
; ELF:       ![[EMPTY]] = !{}
; ELF:       ![[WEIGHTS]] = !{!"branch_weights", i32 9, i32 1}
; NOELF:     ![[CONST]] = !{![[CONST_T:[0-9]+]], ![[CONST_T]], i64 0, i64 1}
; NOELF:     ![[CONST_T]] = !{!"jtbaa_const"
; NOELF-KEY: ![[CONST]] = !{![[CONST_T:[0-9]+]], ![[CONST_T]], i64 0, i64 1}

;--- reuse.ll
target triple = "x86_64-unknown-linux-gnu"

; CHECK:      @jl_pgcstack_func_slot = external hidden global ptr
; CHECK-NEXT: @jl_pgcstack_key_slot = external hidden global i64
; CHECK-NEXT: @jl_{{(image_)?}}tls_offset = external hidden global i64
; CHECK-NOT:  @jl_pgcstack_func_slot.
@jl_pgcstack_func_slot = external global ptr
@jl_pgcstack_key_slot = external global i64

declare ptr @julia.get_pgcstack()
declare void @use(ptr)

; CHECK-LABEL: define void @get()
; CHECK:         load ptr, ptr @jl_pgcstack_func_slot
define void @get() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @use(ptr %pgcstack)
  ret void
}

;--- conflict.ll
target triple = "x86_64-unknown-linux-gnu"

; CHECK: LowerPTLSError: @jl_pgcstack_key_slot is declared in the module, but not as an external, not thread-local variable of type i64: @jl_pgcstack_key_slot = external global i32
@jl_pgcstack_key_slot = external global i32

declare ptr @julia.get_pgcstack()
declare void @use(ptr)

define void @get() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @use(ptr %pgcstack)
  ret void
}

;--- or-new.ll
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare ptr @julia.get_pgcstack()
declare ptr @julia.get_pgcstack_or_new()
declare void @use(ptr)
declare ptr addrspace(10) @box(ptr)

; CHECK-LABEL: define i64 @cfunction(
; CHECK-NEXT:  top:
; CHECK-NEXT:    %thread_ptr = call ptr asm "movq %fs:0, $0", "=r"()
; CHECK-NEXT:    %tls_ppgcstack = getelementptr {{(inbounds )?}}i8, ptr %thread_ptr, i64 -8
; CHECK-NEXT:    %tls_pgcstack = load ptr, ptr %tls_ppgcstack, align 8
; CHECK-NEXT:    %0 = icmp ne ptr %tls_pgcstack, null
; CHECK-NEXT:    br i1 %0, label %1, label %[[ADOPT:[0-9]+]], !prof ![[WEIGHTS:[0-9]+]]
; CHECK-EMPTY:
; CHECK-NEXT:  1:
; LEGACY-NEXT:   %current_task = getelementptr inbounds ptr, ptr %tls_pgcstack, i64 [[TASK]]
; LEGACY-NEXT:   %ptls_field = getelementptr inbounds ptr, ptr %current_task, i64 [[PTLS]]
; NEW-NEXT:      %current_task = getelementptr inbounds i8, ptr %tls_pgcstack, i32 [[TASK]]
; NEW-NEXT:      %ptls_field = getelementptr inbounds i8, ptr %current_task, i32 [[PTLS]]
; CHECK-NEXT:    %ptls_load = load ptr, ptr %ptls_field, align 8, !tbaa ![[GCFRAME:[0-9]+]]
; CHECK-NEXT:    %gc_state = getelementptr inbounds i8, ptr %ptls_load, i32 [[STATE]]
; LEGACY-NEXT:   %[[OLD:[0-9]+]] = load atomic i8, ptr %gc_state monotonic, align 1
; NEW-NEXT:      %[[OLD:old_state]] = load atomic i8, ptr %gc_state monotonic, align 1
; CHECK-NEXT:    store atomic i8 0, ptr %gc_state release, align 1
; V110-NEXT:     %[[NE:[0-9]+]] = icmp ne i8 %[[OLD]], 0
; V110-NEXT:     %[[COND:[0-9]+]] = and i1 %[[NE]], true
; V111-NEXT:     %[[EQ:[0-9]+]] = icmp eq i8 %[[OLD]], 0
; V111-NEXT:     %[[COND:[0-9]+]] = or i1 %[[EQ]], true
; NEW-NEXT:      %[[COND:is_new_state]] = icmp ne i8 %old_state, 0
; CHECK-NEXT:    br i1 %[[COND]], label %safepoint, label %after_safepoint
; CHECK-EMPTY:
; CHECK-NEXT:  [[ADOPT]]:
; LEGACY-NEXT:   %[[ADOPTED:[0-9]+]] = call ptr @ijl_adopt_thread()
; NEW-NEXT:      %[[ADOPTED:[0-9]+]] = call ptr @ijl_autoinit_and_adopt_thread()
; CHECK-NEXT:    br label %[[JOIN:[0-9]+]]
; CHECK-EMPTY:
; CHECK-NEXT:  [[JOIN]]:
; CHECK-NEXT:    %[[LAST:[0-9]+]] = phi i8 [ 2, %[[ADOPT]] ], [ %[[OLD]], %after_safepoint ]
; CHECK-NEXT:    %[[STACK:pgcstack[0-9]+]] = phi ptr [ %[[ADOPTED]], %[[ADOPT]] ], [ %tls_pgcstack, %after_safepoint ]
; CHECK-NEXT:    call void @use(ptr %[[STACK]])
; CHECK-NEXT:    %y = add i64 %x, 1
; LEGACY-NEXT:   %[[TASK2:current_task[0-9]+]] = getelementptr inbounds ptr, ptr %[[STACK]], i64 [[TASK]]
; LEGACY-NEXT:   %[[FIELD2:ptls_field[0-9]+]] = getelementptr inbounds ptr, ptr %[[TASK2]], i64 [[PTLS]]
; NEW-NEXT:      %[[TASK2:current_task[0-9]+]] = getelementptr inbounds i8, ptr %[[STACK]], i32 [[TASK]]
; NEW-NEXT:      %[[FIELD2:ptls_field[0-9]+]] = getelementptr inbounds i8, ptr %[[TASK2]], i32 [[PTLS]]
; CHECK-NEXT:    %[[PTLS2:ptls_load[0-9]+]] = load ptr, ptr %[[FIELD2]], align 8, !tbaa ![[GCFRAME]]
; CHECK-NEXT:    %[[STATE2:gc_state[0-9]+]] = getelementptr inbounds i8, ptr %[[PTLS2]], i32 [[STATE]]
; CHECK-NEXT:    store atomic i8 %[[LAST]], ptr %[[STATE2]] release, align 1
; UNNAMEDSP-NEXT: %[[ADDR2:[0-9]+]] = getelementptr inbounds i8, ptr %[[PTLS2]], i32 16
; NAMEDSP-NEXT:  %[[ADDR2:safepoint_addr[0-9]+]] = getelementptr inbounds i8, ptr %[[PTLS2]], i32 16
; V112-NEXT:     %[[PAGE2:safepoint[0-9]+]] = load ptr, ptr %[[ADDR2]], align 8, !tbaa ![[GCFRAME]]
; ATOMICSP-NEXT: %[[PAGE2:safepoint[0-9]+]] = load atomic ptr, ptr %[[ADDR2]] monotonic, align 8, !tbaa ![[GCFRAME]]
; NEW-NEXT:      fence syncscope("singlethread") seq_cst
; NEW-NEXT:      load volatile i64, ptr %[[PAGE2]], align 8
; NEW-NEXT:      fence syncscope("singlethread") seq_cst
; CHECK-NEXT:    ret i64 %y
; CHECK-EMPTY:
; CHECK-NEXT:  safepoint:
; LEGACY-NEXT:   %[[ADDR:[0-9]+]] = getelementptr inbounds ptr, ptr %ptls_load, i64 2
; UNNAMEDSP-NEXT: %[[ADDR:[0-9]+]] = getelementptr inbounds i8, ptr %ptls_load, i32 16
; NAMEDSP-NEXT:  %[[ADDR:safepoint_addr]] = getelementptr inbounds i8, ptr %ptls_load, i32 16
; PLAINSP-NEXT:  %[[PAGE:safepoint[0-9]+]] = load ptr, ptr %[[ADDR]], align 8, !tbaa ![[CONST:[0-9]+]], !invariant.load
; ATOMICSP-NEXT: %[[PAGE:safepoint[0-9]+]] = load atomic ptr, ptr %[[ADDR]] monotonic, align 8, !tbaa ![[CONST:[0-9]+]], !invariant.load
; CHECK-NEXT:    fence syncscope("singlethread") seq_cst
; CHECK-NEXT:    load volatile i64, ptr %[[PAGE]], align 8
; CHECK-NEXT:    fence syncscope("singlethread") seq_cst
; CHECK-NEXT:    br label %after_safepoint
; CHECK-EMPTY:
; CHECK-NEXT:  after_safepoint:
; CHECK-NEXT:    br label %[[JOIN]]
; CHECK-NEXT:  }
define i64 @cfunction(i64 %x) {
top:
  %pgcstack = call ptr @julia.get_pgcstack_or_new()
  call void @use(ptr %pgcstack)
  %y = add i64 %x, 1
  ret i64 %y
}

; the GC state is restored at every return
; CHECK-LABEL: define i64 @two_returns(
; CHECK:         %[[LAST:[0-9]+]] = phi i8
; CHECK:       {{^}}a:
; CHECK:         store atomic i8 %[[LAST]], ptr %{{gc_state[0-9]+}} release, align 1
; NEW:           load volatile i64
; CHECK:         ret i64 1
; CHECK:       {{^}}b:
; CHECK:         store atomic i8 %[[LAST]], ptr %{{gc_state[0-9]+}} release, align 1
; NEW:           load volatile i64
; CHECK:         ret i64 2
define i64 @two_returns(i1 %c) {
top:
  %pgcstack = call ptr @julia.get_pgcstack_or_new()
  call void @use(ptr %pgcstack)
  br i1 %c, label %a, label %b
a:
  ret i64 1
b:
  ret i64 2
}

; CHECK-LABEL: define void @no_return() {
; CHECK:         call void @use(ptr %{{pgcstack[0-9]+}})
; CHECK-NEXT:    unreachable
; CHECK-EMPTY:
; CHECK-NEXT:  safepoint:
define void @no_return() {
top:
  %pgcstack = call ptr @julia.get_pgcstack_or_new()
  call void @use(ptr %pgcstack)
  unreachable
}

; CHECK-LABEL: define void @plain() {
; CHECK-NEXT:  top:
; CHECK-NEXT:    %thread_ptr = call ptr asm "movq %fs:0, $0", "=r"()
; CHECK-NEXT:    %tls_ppgcstack = getelementptr {{(inbounds )?}}i8, ptr %thread_ptr, i64 -8
; CHECK-NEXT:    %tls_pgcstack = load ptr, ptr %tls_ppgcstack, align 8
; CHECK-NEXT:    call void @use(ptr %tls_pgcstack)
define void @plain() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @use(ptr %pgcstack)
  ret void
}

; a function that returns tracked pointers doesn't restore the GC state at its returns
; (which is up to its caller), so the call needn't dominate them
; CHECK-LABEL: define ptr addrspace(10) @boxed() {
; CHECK-NOT:     phi i8
; CHECK:         %[[STACK:pgcstack[0-9]+]] = phi ptr
; CHECK-NEXT:    %b = call ptr addrspace(10) @box(ptr %[[STACK]])
; CHECK-NEXT:    ret ptr addrspace(10) %b
define ptr addrspace(10) @boxed() {
top:
  %pgcstack = call ptr @julia.get_pgcstack_or_new()
  %b = call ptr addrspace(10) @box(ptr %pgcstack)
  ret ptr addrspace(10) %b
}

; CHECK-LABEL: define { ptr addrspace(10), i64 } @aggregate(i1 %c) {
; CHECK-NOT:     phi i8
; CHECK:       {{^}}done:
; CHECK-NEXT:    ret { ptr addrspace(10), i64 } zeroinitializer
define { ptr addrspace(10), i64 } @aggregate(i1 %c) {
top:
  br i1 %c, label %adopt, label %done
adopt:
  %pgcstack = call ptr @julia.get_pgcstack_or_new()
  call void @use(ptr %pgcstack)
  br label %done
done:
  ret { ptr addrspace(10), i64 } zeroinitializer
}

; LEGACY: declare ptr @ijl_adopt_thread()
; NEW:    declare ptr @ijl_autoinit_and_adopt_thread()
; CHECK:  ![[WEIGHTS]] = !{!"branch_weights", i32 9, i32 1}
; CHECK:  ![[GCFRAME]] = !{![[GCFRAME_T:[0-9]+]], ![[GCFRAME_T]], i64 0}
; CHECK:  ![[GCFRAME_T]] = !{!"jtbaa_gcframe"
; CHECK:  ![[CONST]] = !{![[CONST_T:[0-9]+]], ![[CONST_T]], i64 0, i64 1}
; CHECK:  ![[CONST_T]] = !{!"jtbaa_const"

;--- or-new-imaging.ll
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare ptr @julia.get_pgcstack_or_new()
declare void @use(ptr)

; the GC stack from the thread pointer or the image's getter is the one that is checked
; for a thread to adopt
; CHECK-LABEL: define void @cfunction() {
; CHECK:         load i64, ptr @jl_{{(image_)?}}tls_offset
; CHECK:         %[[STACK:pgcstack[0-9]+]] = phi ptr [ %tls_pgcstack, %{{[0-9]+}} ], [ %pgcstack, %{{[0-9]+}} ]
; CHECK-NEXT:    %{{[0-9]+}} = icmp ne ptr %[[STACK]], null
; CHECK:         call ptr @{{ijl_adopt_thread|ijl_autoinit_and_adopt_thread}}()
; CHECK:         phi ptr [ %{{[0-9]+}}, %{{[0-9]+}} ], [ %[[STACK]], %after_safepoint ]
define void @cfunction() {
top:
  %pgcstack = call ptr @julia.get_pgcstack_or_new()
  call void @use(ptr %pgcstack)
  ret void
}

;--- errors.ll
target triple = "x86_64-unknown-linux-gnu"

declare ptr @julia.get_pgcstack()
declare void @use(ptr)

; NONCALL: LowerPTLSError: @julia.get_pgcstack is used other than as the function of a call: call void @use(ptr @julia.get_pgcstack)
define void @lowered() {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
  call void @use(ptr %pgcstack)
  ret void
}

define void @escape() {
top:
  call void @use(ptr @julia.get_pgcstack)
  ret void
}

;--- invoke.ll
target triple = "x86_64-unknown-linux-gnu"

declare ptr @julia.get_pgcstack()
declare void @use(ptr)
declare i32 @__gxx_personality_v0(...)

; CHECK: LowerPTLSError: @julia.get_pgcstack is used other than as the function of a call: %pgcstack = invoke ptr @julia.get_pgcstack()
define void @invoked() personality ptr @__gxx_personality_v0 {
top:
  %pgcstack = invoke ptr @julia.get_pgcstack() to label %ok unwind label %lpad
ok:
  call void @use(ptr %pgcstack)
  ret void
lpad:
  %lp = landingpad { ptr, i32 } cleanup
  ret void
}

;--- dominate.ll
target triple = "x86_64-unknown-linux-gnu"

declare ptr @julia.get_pgcstack_or_new()
declare void @use(ptr)

; CHECK: LowerPTLSError: @julia.get_pgcstack_or_new is called in function late where it doesn't dominate a return
define void @late(i1 %c) {
top:
  br i1 %c, label %adopt, label %done
adopt:
  %pgcstack = call ptr @julia.get_pgcstack_or_new()
  call void @use(ptr %pgcstack)
  br label %done
done:
  ret void
}

;--- none.ll
target triple = "powerpc64le-unknown-linux-gnu"

declare void @use(ptr)

; CHECK-LABEL: define void @nothing() {
; CHECK-NEXT:  top:
; CHECK-NEXT:    call void @use(ptr null)
define void @nothing() {
top:
  call void @use(ptr null)
  ret void
}
