# Fixture for the bounded-wait tests: an item that parks forever. `take!` on a channel
# nothing writes to is not an error in Julia — the scheduler idles and the worker stays
# alive, silent, using no CPU. Only run this through a call that is itself bounded.
@testitem "hangs forever" begin
    take!(Channel{Any}(Inf))
end

@testitem "quick" begin
    @test true
end
