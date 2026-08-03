@testmodule SharedFixture begin
    magic_number() = 42
end

@testsnippet SharedSnippet begin
    shared_value = 7
end

@testitem "passing" begin
    using BasicPkg
    @test BasicPkg.add_one(1) == 2
end

@testitem "also passing" tags=[:fast] begin
    using BasicPkg
    @test BasicPkg.double(3) == 6
end

@testitem "failing" tags=[:slow, :flaky] begin
    using BasicPkg
    @test BasicPkg.add_one(1) == 3
end

@testitem "erroring" begin
    error("boom")
end

@testitem "uses setup" setup=[SharedFixture] begin
    @test SharedFixture.magic_number() == 42
end

@testitem "uses snippet" setup=[SharedSnippet] begin
    @test shared_value == 7
end

@testitem "no default imports" default_imports=false begin
    using Test
    @test 1 == 1
end
