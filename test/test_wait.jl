# `julia_run_testitems` waits at most `max_wait_seconds` and otherwise hands the run back
# still running. Every test that touches the hanging fixture goes through that bounded path
# or a `timed_wait`; nothing here ever blocks on the hanging item finishing.

@testitem "run_testitems returns early with the run still going" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers
    using JuliaMCP: PROGRESS_HEARTBEAT_INTERVAL

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "HangPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        MCPTestHelpers.drain_notifications(client)

        poll(id) = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_get_testrun_results",
            Dict{String,Any}("testrun_id" => id)))
        cancel(id) = MCPTestHelpers.call_tool(client, "julia_cancel_testrun", Dict{String,Any}("testrun_id" => id))

        result = MCPTestHelpers.call_tool(client, "julia_run_testitems",
            Dict{String,Any}("max_wait_seconds" => 2, "name_pattern" => "^hangs");
            progress_token="tok-hang")
        @test !MCPTestHelpers.is_error(result)

        report = MCPTestHelpers.result_json(result)
        @test report["status"] == "running"
        @test report["summary"]["status"] == "running"
        @test report["summary"]["total"] == 1
        @test report["summary"]["completed_at"] === nothing
        @test report["waited_seconds"] == 2
        @test occursin("julia_get_testrun_results", report["message"])
        @test occursin("julia_cancel_testrun", report["message"])
        @test haskey(report, "in_progress_hint")
        id = report["testrun_id"]
        @test id == report["summary"]["testrun_id"]

        runs = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testruns"))
        @test length(runs) == 1
        @test runs[1]["status"] == "running"

        # The run continued after the response: the worker eventually starts the item, and
        # the poll tool reports it in the same shape, still running.
        @test MCPTestHelpers.timed_wait(120.0; interval=0.5) do
            poll(id)["summary"]["running"] == 1
        end
        live = poll(id)
        @test live["status"] == "running"
        @test haskey(live, "in_progress_hint")
        @test any(i -> i["label"] == "hangs forever" && i["status"] == "running", live["items"])

        # Progress for the answered request stopped with the response.
        MCPTestHelpers.drain_notifications(client)
        sleep(3 * PROGRESS_HEARTBEAT_INTERVAL)
        late = filter(MCPTestHelpers.drain_notifications(client)) do m
            m.method == "notifications/progress" && m.params["progressToken"] == "tok-hang"
        end
        @test isempty(late)

        # Cancelling is what ends the item. The detached finalizer then drops the run from
        # the active set, which is when a second cancel starts to fail.
        @test !MCPTestHelpers.is_error(cancel(id))
        @test MCPTestHelpers.timed_wait(60.0; interval=0.2) do
            MCPTestHelpers.is_error(cancel(id))
        end
        final = poll(id)
        @test final["status"] == "cancelled"
        @test final["summary"]["running"] == 0
        @test final["summary"]["pending"] == 0
        @test final["summary"]["completed_at"] !== nothing
        @test !haskey(final, "in_progress_hint")

        # `max_wait_seconds = 0` is fire-and-forget: the run is handed back at once, and the
        # detached finalizer records a run that completes on its own just as it records a
        # cancelled one.
        result = MCPTestHelpers.call_tool(client, "julia_run_testitems",
            Dict{String,Any}("max_wait_seconds" => 0, "name_pattern" => "^quick"))
        @test !MCPTestHelpers.is_error(result)
        report = MCPTestHelpers.result_json(result)
        @test report["status"] == "running"
        @test report["waited_seconds"] == 0
        quick_id = report["testrun_id"]
        @test MCPTestHelpers.timed_wait(120.0; interval=0.5) do
            poll(quick_id)["status"] != "running"
        end
        done = poll(quick_id)
        @test done["status"] == "completed"
        @test done["summary"]["passed"] == 1
        @test done["summary"]["completed_at"] !== nothing
        @test MCPTestHelpers.is_error(cancel(quick_id))
    end
end

@testitem "a run that finishes within max_wait_seconds is unchanged" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))

        result = MCPTestHelpers.call_tool(client, "julia_run_testitems",
            Dict{String,Any}("max_wait_seconds" => 300))
        @test !MCPTestHelpers.is_error(result)

        report = MCPTestHelpers.result_json(result)
        summary = report["summary"]
        @test report["status"] == "completed"
        @test report["testrun_id"] == summary["testrun_id"]
        @test summary["total"] == 7
        @test summary["passed"] == 5
        @test summary["failed"] == 1
        @test summary["errored"] == 1
        @test summary["completed_at"] !== nothing
        @test !haskey(report, "message")
        @test !haskey(report, "waited_seconds")
        @test !haskey(report, "in_progress_hint")

        # The run is finished, so there is nothing left to cancel.
        @test MCPTestHelpers.is_error(MCPTestHelpers.call_tool(client, "julia_cancel_testrun",
            Dict{String,Any}("testrun_id" => report["testrun_id"])))
    end
end

@testitem "rerun_failed forwards max_wait_seconds" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers
    using JuliaMCP: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        first_result = JuliaMCP.tool_run_testitems(state, Dict{String,Any}("max_wait_seconds" => 123))
        @test !MCPTestHelpers.is_error(first_result)
        first_id = MCPTestHelpers.result_json(first_result)["testrun_id"]

        rerun_result = JuliaMCP.tool_rerun_failed(state, Dict{String,Any}("testrun_id" => first_id))
        @test !MCPTestHelpers.is_error(rerun_result)
        rerun_id = MCPTestHelpers.result_json(rerun_result)["testrun_id"]
        @test rerun_id != first_id

        rerun = lock(state.lock) do
            state.runs[rerun_id]
        end
        @test rerun.profile_params["max_wait_seconds"] == 123
    end
end

@testitem "max_wait_seconds is validated before anything starts" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))

        for bad in (-1, "abc", true)
            result = MCPTestHelpers.call_tool(client, "julia_run_testitems",
                Dict{String,Any}("max_wait_seconds" => bad))
            @test MCPTestHelpers.is_error(result)
            @test occursin("max_wait_seconds", MCPTestHelpers.result_text(result))
        end
        @test MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testruns")) == []
    end
end

@testitem "max_wait_seconds is advertised" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    tools = Dict(t["name"] => t for t in JuliaMCP.tool_definitions())
    for name in ("julia_run_testitems", "julia_rerun_failed")
        prop = tools[name]["inputSchema"]["properties"]["max_wait_seconds"]
        @test prop["type"] == "number"
        @test occursin(string(JuliaMCP.MAX_WAIT_SECONDS_DEFAULT), prop["description"])
    end
    @test occursin("max_wait_seconds", tools["julia_run_testitems"]["description"])
    @test occursin("julia_cancel_testrun", tools["julia_run_testitems"]["description"])

    MCPTestHelpers.with_mcp_server(initialize=false) do client
        result = MCPTestHelpers.initialize!(client)
        @test occursin("max_wait_seconds", result["instructions"])
        @test occursin("julia_cancel_testrun", result["instructions"])
        @test occursin("julia_get_testrun_results", result["instructions"])
    end
end
