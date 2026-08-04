# Fixtures for the result-bounding tests: every item fails, prints far more than the
# default output cap, and errors from deep in the stack.

@testitem "noisy 1" begin
    using NoisyPkg
    for i in 1:400
        println("noisy 1 line $i — ", "x"^60)
    end
    NoisyPkg.deep(30)
end

@testitem "noisy 2" begin
    using NoisyPkg
    for i in 1:400
        println("noisy 2 line $i — ", "y"^60)
    end
    NoisyPkg.deep(30)
end

@testitem "noisy 3" begin
    using NoisyPkg
    for i in 1:400
        println("noisy 3 line $i — ", "z"^60)
    end
    @test 1 == 2
end
