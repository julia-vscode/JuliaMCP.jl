@testitem "report_progress! only ever increases" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: TestRunRecord, TestItemResult, report_progress!
    using Dates

    MCPTestHelpers.with_app_state() do state
        items = Dict{String,TestItemResult}(
            "a" => TestItemResult("a", "a", "file:///a.jl", :pending, nothing, Any[], String[]),
            "b" => TestItemResult("b", "b", "file:///a.jl", :pending, nothing, Any[], String[]),
        )
        run = TestRunRecord("run-1", :running, Dict{String,Any}(), items, nothing, Dates.now(), nothing)
        state.runs["run-1"] = run

        # Without a token the whole mechanism is inert.
        report_progress!(state, run)
        @test run.progress_value == -1.0

        run.progress_token = "tok"
        report_progress!(state, run; heartbeat=true)
        first_value = run.progress_value
        @test 0.0 < first_value < 1.0

        report_progress!(state, run; heartbeat=true)
        @test run.progress_value > first_value
        @test run.progress_value < 1.0

        # A non-heartbeat call with no state change must not emit again.
        stalled = run.progress_value
        report_progress!(state, run)
        @test run.progress_value == stalled

        # Finishing an item resets the sub-item offset and lands on a whole number.
        items["a"].status = :passed
        report_progress!(state, run)
        @test run.progress_value == 1.0
        @test run.progress_frac == 0.0

        items["b"].status = :failed
        report_progress!(state, run; final=true)
        @test run.progress_value == 2.0
    end
end

@testitem "a heartbeat after the last item cannot push progress past total" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: TestRunRecord, TestItemResult, report_progress!
    using Dates

    # A heartbeat firing after the last item finished used to take the `elseif heartbeat`
    # branch with `done == total`, adding half the ceiling on top of a value already equal to
    # `total`: progress went to 7.475/7, and that impossible value was the client's last word
    # on the run, since the final call reports `total` and could no longer beat it.
    MCPTestHelpers.with_app_state() do state
        items = Dict{String,TestItemResult}(
            "a" => TestItemResult("a", "a", "file:///a.jl", :pending, nothing, Any[], String[]),
            "b" => TestItemResult("b", "b", "file:///a.jl", :pending, nothing, Any[], String[]),
        )
        run = TestRunRecord("run-1", :running, Dict{String,Any}(), items, nothing, Dates.now(), nothing)
        run.progress_token = "tok"
        state.runs["run-1"] = run

        items["a"].status = :passed
        items["b"].status = :passed
        report_progress!(state, run)
        @test run.progress_value == 2.0

        # Heartbeats with nothing left to run must not move the value at all.
        for _ in 1:3
            report_progress!(state, run; heartbeat=true)
            @test run.progress_value == 2.0
        end

        # The last value a client sees is therefore exactly `total`, which is what
        # "run_testitems streams progress notifications" asserts end-to-end. The final call
        # reports `total` too, so the strictly-increasing guard drops it — that is unchanged
        # and deliberate: the spec forbids sending the same value twice.
        report_progress!(state, run; final=true)
        @test run.progress_value == 2.0
    end
end

@testitem "run_testitems streams progress notifications" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        MCPTestHelpers.drain_notifications(client)

        result = MCPTestHelpers.call_tool(client, "julia_run_testitems", MCPTestHelpers.to_completion();
            progress_token="tok-1")
        @test !MCPTestHelpers.is_error(result)

        notifications = filter(m -> m.method == "notifications/progress",
            MCPTestHelpers.drain_notifications(client))
        @test !isempty(notifications)

        @test all(n -> n.params["progressToken"] == "tok-1", notifications)
        @test all(n -> n.params["total"] == 7, notifications)

        values = [n.params["progress"] for n in notifications]
        @test issorted(values, lt = <=)   # strictly increasing, as the spec requires
        @test last(values) == 7
        @test all(n -> haskey(n.params, "message"), notifications)
    end
end

@testitem "no progress notifications without a token" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        MCPTestHelpers.drain_notifications(client)

        MCPTestHelpers.call_tool(client, "julia_run_testitems",
            MCPTestHelpers.to_completion(Dict{String,Any}("name_pattern" => "^passing\$")))

        msgs = MCPTestHelpers.drain_notifications(client)
        @test isempty(filter(m -> m.method == "notifications/progress", msgs))
    end
end

@testitem "progress_token_of accepts strings and integers only" begin
    using JuliaMCP: progress_token_of

    @test progress_token_of(Dict{String,Any}()) === nothing
    @test progress_token_of(Dict{String,Any}("_meta" => Dict{String,Any}())) === nothing
    @test progress_token_of(Dict{String,Any}("_meta" => Dict{String,Any}("progressToken" => "abc"))) == "abc"
    @test progress_token_of(Dict{String,Any}("_meta" => Dict{String,Any}("progressToken" => 7))) == 7
    @test progress_token_of(Dict{String,Any}("_meta" => Dict{String,Any}("progressToken" => [1]))) === nothing
end
