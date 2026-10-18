; The jlopt driver, as `opt`.

; input from stdin, by name or implicitly
; RUN: opt -passes=jl-remove-ni -S - < %s | FileCheck %s
; RUN: opt -passes=jl-remove-ni -S < %s | FileCheck %s
; RUN: cat %s | opt --passes=jl-remove-ni -S | FileCheck %s

; output to a file, and as bitcode
; RUN: opt -passes=jl-remove-ni -S %s -o %t.ll
; RUN: FileCheck %s < %t.ll
; RUN: opt -passes=jl-remove-ni %s -o %t.bc
; RUN: opt -passes=jl-remove-ni -S %t.bc | FileCheck %s
; RUN: opt -passes=jl-remove-ni %s | opt -passes=jl-remove-ni -S | FileCheck %s

; Julia 1.10's tests: legacy pass manager and the plugin, with opaque pointers
; RUN: opt -enable-new-pm=0 --opaque-pointers=1 -load libjulia-codegen%shlibext -RemoveNI -S %s | FileCheck %s
; RUN: opt -enable-new-pm=1 --opaque-pointers=1 --load-pass-plugin=libjulia-codegen%shlibext -passes=RemoveNI -S %s | FileCheck %s

; overriding the triple (see also jlopt-target.ll), and a triple LLVM has no target for
; RUN: opt -mtriple=x86_64-unknown-linux-gnu -passes=jl-remove-ni -S %s | FileCheck %s --check-prefix=TRIPLE
; TRIPLE: target triple = "x86_64-unknown-linux-gnu"
; RUN: opt -mtriple=nonsense-unknown-none -passes=jl-remove-ni -S %s 2>&1 | FileCheck %s --check-prefix=NOTARGET
; NOTARGET: jlopt: WARNING: failed to create target machine for 'nonsense-unknown-none'
; NOTARGET: target triple = "nonsense-unknown-none"

; errors
; RUN: not opt -passes=jl-remove-ni --opaque-pointers=0 -S %s 2>&1 | FileCheck %s --check-prefix=TYPED
; TYPED: jlopt: typed pointers are not supported
; RUN: not opt -passes=jl-remove-ni -frobnicate -S %s 2>&1 | FileCheck %s --check-prefix=UNKNOWN
; UNKNOWN: jlopt: unknown option -frobnicate
; RUN: not opt --load-pass-plugin=libfoo%shlibext -passes=jl-remove-ni -S %s 2>&1 | FileCheck %s --check-prefix=PLUGIN
; PLUGIN: jlopt: cannot load plugin libfoo
; RUN: not opt -passes='jl-remove-ni<julia=1.12>' -S %s 2>&1 | FileCheck %s --check-prefix=OPTION
; OPTION: unknown option julia
; RUN: not opt -passes=jl-no-such-pass -S %s 2>&1 | FileCheck %s --check-prefix=PIPELINE
; PIPELINE: jl-no-such-pass
; RUN: not opt -passes=jl-remove-ni -S %t.missing 2>&1 | FileCheck %s --check-prefix=MISSING
; MISSING: jlopt: {{.*}}.missing: No such file
; RUN: echo "define void @f( {" | not opt -passes=jl-remove-ni -S 2>&1 | FileCheck %s --check-prefix=PARSE
; PARSE: jlopt: <stdin>:

target datalayout = "e-i64:64-ni:10:11:12:13"
; CHECK: target datalayout = "e-i64:64"
