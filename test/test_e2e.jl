@testitem "run_testitems executes tests and reports results" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))

        result = MCPTestHelpers.call_tool(client, "run_testitems", Dict{String,Any}())
        @test !MCPTestHelpers.is_error(result)

        report = MCPTestHelpers.result_json(result)
        summary = report["summary"]

        @test summary["total"] == 7
        @test summary["passed"] == 5
        @test summary["failed"] == 1
        @test summary["errored"] == 1

        failures = Dict(f["label"] => f for f in report["failures"])
        @test haskey(failures, "failing")
        @test haskey(failures, "erroring")
        @test !isempty(failures["erroring"]["messages"])
    end
end

@testitem "test run results and resources are retrievable" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        MCPTestHelpers.call_tool(client, "run_testitems",
            Dict{String,Any}("name_pattern" => "^passing\$"))

        runs = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "list_testruns"))
        @test length(runs) == 1
        run_id = runs[1]["testrun_id"]

        results = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "get_testrun_results",
            Dict{String,Any}("testrun_id" => run_id)))
        @test results isa Dict

        summary = MCPTestHelpers.resource_json(
            MCPTestHelpers.read_resource(client, "testrun://$run_id/summary"))
        @test summary["total"] == 1
        @test summary["passed"] == 1

        failures = MCPTestHelpers.resource_json(
            MCPTestHelpers.read_resource(client, "testrun://$run_id/failures"))
        @test isempty(failures)
    end
end

@testitem "rerun_failed re-runs only the failures" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        MCPTestHelpers.call_tool(client, "run_testitems", Dict{String,Any}())

        run_id = MCPTestHelpers.result_json(
            MCPTestHelpers.call_tool(client, "list_testruns"))[1]["testrun_id"]

        rerun = MCPTestHelpers.call_tool(client, "rerun_failed",
            Dict{String,Any}("testrun_id" => run_id))
        @test !MCPTestHelpers.is_error(rerun)

        report = MCPTestHelpers.result_json(rerun)
        @test report["summary"]["total"] == 2
        @test report["summary"]["passed"] == 0
    end
end

@testitem "test processes are reported and cleaned up" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        MCPTestHelpers.call_tool(client, "run_testitems",
            Dict{String,Any}("name_pattern" => "^passing\$"))

        procs = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "list_test_processes"))
        @test !isempty(procs)
        @test all(p -> p["package_name"] == "BasicPkg", procs)

        result = MCPTestHelpers.call_tool(client, "terminate_test_process",
            Dict{String,Any}("process_id" => procs[1]["id"]))
        @test !MCPTestHelpers.is_error(result)

        @test MCPTestHelpers.timed_wait(30.0) do
            isempty(MCPTestHelpers.result_json(
                MCPTestHelpers.call_tool(client, "list_test_processes")))
        end
    end
end
