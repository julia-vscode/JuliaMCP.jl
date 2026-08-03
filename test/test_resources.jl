@testitem "resources/list includes workspace resources" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        result = MCPTestHelpers.request(client, "resources/list", Dict{String,Any}())
        uris = [r["uri"] for r in result["resources"]]

        @test "workspace://testitems" in uris
        @test "workspace://detection-errors" in uris
    end
end

@testitem "reading workspace resources" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        items = MCPTestHelpers.resource_json(MCPTestHelpers.read_resource(client, "workspace://testitems"))
        @test length(items) == 7

        errors = MCPTestHelpers.resource_json(MCPTestHelpers.read_resource(client, "workspace://detection-errors"))
        @test errors == []
    end
end

@testitem "reading an unknown resource errors" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JSONRPC

    MCPTestHelpers.with_mcp_server() do client
        @test_throws JSONRPC.JSONRPCError MCPTestHelpers.read_resource(client, "bogus://nothing")
        @test_throws JSONRPC.JSONRPCError MCPTestHelpers.read_resource(client, "testrun://missing/summary")
    end
end

@testitem "read_resource URI routing" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: read_resource, TestRunRecord, TestItemResult, run_summary
    using Dates

    MCPTestHelpers.with_app_state() do state
        run = TestRunRecord("run-1", :completed, Dict{String,Any}(), Dict{String,TestItemResult}(),
            nothing, Dates.now(), nothing)
        run.items["item-1"] = TestItemResult("item-1", "passing", "file:///a.jl", :passed, 0.5, Any[], ["hello"])
        run.items["item-2"] = TestItemResult("item-2", "failing", "file:///a.jl", :failed, 0.2,
            Any[Dict("message" => "nope")], String[])
        state.runs["run-1"] = run

        summary = MCPTestHelpers.JSON.parse(only(read_resource(state, "testrun://run-1/summary"))["text"])
        @test summary isa Dict

        failures = MCPTestHelpers.JSON.parse(only(read_resource(state, "testrun://run-1/failures"))["text"])
        @test length(failures) == 1
        @test only(failures)["testitem_id"] == "item-2"

        output = only(read_resource(state, "testrun://run-1/items/item-1/output"))
        @test occursin("hello", output["text"])

        # Coverage was never collected for this run.
        @test_throws ErrorException read_resource(state, "testrun://run-1/coverage")
        @test_throws ErrorException read_resource(state, "testrun://run-1/items/nope/output")
        @test_throws ErrorException read_resource(state, "not-a-known-scheme://x")
    end
end

@testitem "dynamic_resources lists known runs" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: dynamic_resources, TestRunRecord, TestItemResult
    using Dates

    MCPTestHelpers.with_app_state() do state
        state.runs["run-9"] = TestRunRecord("run-9", :running, Dict{String,Any}(),
            Dict{String,TestItemResult}(), nothing, Dates.now(), nothing)

        uris = [r["uri"] for r in dynamic_resources(state)]
        @test "testrun://run-9/summary" in uris
        @test "workspace://testitems" in uris
    end
end

@testitem "subscribe and unsubscribe gate update notifications" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: notify_resource_updated

    MCPTestHelpers.with_app_state() do state
        @test isempty(state.subscriptions)

        TestItemMCPApp.handle_resources_subscribe(state, Dict("uri" => "workspace://testitems"))
        @test "workspace://testitems" in state.subscriptions

        TestItemMCPApp.handle_resources_unsubscribe(state, Dict("uri" => "workspace://testitems"))
        @test !("workspace://testitems" in state.subscriptions)

        # Unsubscribing something that was never subscribed must not throw.
        TestItemMCPApp.handle_resources_unsubscribe(state, Dict("uri" => "workspace://testitems"))
        # Notifying an unsubscribed URI is a no-op rather than an error.
        notify_resource_updated(state, "workspace://testitems")
    end
end

@testitem "subscribers receive resource update notifications" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.subscribe(client, "workspace://testitems")
        MCPTestHelpers.drain_notifications(client)

        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        msg = MCPTestHelpers.wait_for_notification(client, "notifications/resources/updated")
        @test msg !== nothing
        @test msg.params["uri"] == "workspace://testitems"
    end
end
