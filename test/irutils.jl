using LLVM, LLVM.IR

@testset "IR utilities" begin

@testset "constant_uses" begin
    @dispose ctx=Context(; opaque_pointers=true) begin
        mod = parse(LLVM.Module, """
            target datalayout = "e-p:64:64-i64:64"

            @s = global { i64, ptr } { i64 1, ptr @f }
            @a = global [2 x ptr] [ptr null, ptr @f]
            @g = global ptr getelementptr (i8, ptr @f, i64 8)
            @p = global i64 ptrtoint (ptr @f to i64)
            @n = global i32 ptrtoint (ptr @f to i32)

            define void @f() {
              ret void
            }

            define i64 @u() {
              call void @f()
              %x = add i64 ptrtoint (ptr @f to i64), 1
              ret i64 %x
            }""")
        f = mod.functions["f"]

        users = []
        walk = JuliaIR.constant_uses(f, mod, GlobalValue)
        while !JuliaIR.isdone(walk)
            info = JuliaIR.use_info(walk)
            push!(users, (info.user.name, info.offset, info.samebits,
                          length(walk.stack)))
            JuliaIR.next!(walk)
        end
        # a pointer cast to a narrower integer doesn't keep the pointer's bits
        @test sort(users) == [("a", 8, true, 2), ("g", 0, false, 2), ("n", 0, false, 2),
                              ("p", 0, true, 2), ("s", 8, true, 2)]

        users = []
        walk = JuliaIR.constant_uses(f, mod, Instruction)
        while !JuliaIR.isdone(walk)
            info = JuliaIR.use_info(walk)
            push!(users, (string(info.user.opcode), length(walk.stack)))
            JuliaIR.next!(walk)
        end
        @test sort(users) == sort([(string(LLVM.Opcode.Call), 1),
                                   (string(LLVM.Opcode.Add), 2)])

        # the current use can be dropped before the walk continues
        walk = JuliaIR.constant_uses(f, mod, GlobalValue)
        n = 0
        while !JuliaIR.isdone(walk)
            info = JuliaIR.use_info(walk)
            info.user.initializer = null(info.user.initializer.value_type)
            n += 1
            JuliaIR.next!(walk)
        end
        @test n == 5
        @test JuliaIR.isdone(JuliaIR.constant_uses(f, mod, GlobalValue))
        dispose(mod)
    end
end

@testset "aggregate_element" begin
    @dispose ctx=Context(; opaque_pointers=true) begin
        T_i8, T_i64 = LLVM.Int8Type(), LLVM.Int64Type()
        elt(c, i) = JuliaIR.aggregate_element(c, i)

        data = ConstantDataArray(Int32[1, 2])
        @test convert(Int, elt(data, 1)) == 2
        @test elt(data, 2) === nothing

        agg = ConstantStruct([ConstantInt(Int8(1)), ConstantInt(Int64(2))])
        @test convert(Int, elt(agg, 1)) == 2
        @test elt(agg, 2) === nothing

        zero_struct = null(LLVM.StructType([T_i8, T_i64]))
        @test elt(zero_struct, 1) == null(T_i64)

        # scalable vectors have the minimum number of elements
        scalable = LLVM.ScalableVectorType(T_i64, 2)
        @test elt(null(scalable), 1) == null(T_i64)
        @test elt(null(scalable), 2) === nothing
        @test elt(PoisonValue(scalable), 0) === nothing

        undef = elt(UndefValue(LLVM.ArrayType(T_i8, 3)), 2)
        @test undef == UndefValue(T_i8) && !(undef isa PoisonValue)
    end
end

end
