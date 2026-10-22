; Julia 1.10 temporarily retains runtime declarations while the module pass runs.
; Entries retained by the input module must survive that cleanup.
; RUN: opt -passes='module(jl-final-lower-gc)' -S %s | FileCheck %s

; CHECK: @llvm.compiler.used = appending global [1 x ptr] [ptr @ijl_gc_queue_root], section "llvm.metadata"
@llvm.compiler.used = appending global [1 x ptr] [ptr @ijl_gc_queue_root], section "llvm.metadata"
declare void @ijl_gc_queue_root(ptr addrspace(10))
