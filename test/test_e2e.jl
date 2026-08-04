@testitem "run_testitems executes tests and reports results" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))

        result = MCPTestHelpers.call_tool(client, "julia_run_testitems", Dict{String,Any}())
        @test !MCPTestHelpers.is_error(result)

        report = MCPTestHelpers.result_json(result)
        summary = report["summary"]

        @test summary["total"] == 7
        @test summary["passed"] == 5
        @test summary["failed"] == 1
        @test summary["errored"] == 1

        # The run payload is a compact status list; detail lives behind get_testitem_detail.
        listed = Dict(i["label"] => i for i in report["items"])
        @test haskey(listed, "failing")
        @test haskey(listed, "erroring")
        @test !haskey(listed["erroring"], "messages")
        @test !haskey(listed["erroring"], "output")
        @test !haskey(report, "failures")

        detail = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_get_testitem_detail",
            Dict{String,Any}(
                "testrun_id" => summary["testrun_id"],
                "testitem_ids" => [listed["erroring"]["testitem_id"], listed["failing"]["testitem_id"]],
            )))
        @test length(detail) == 2
        @test all(d -> d["found"], detail)
        @test !isempty(detail[1]["messages"])
    end
end

@testitem "test run results and resources are retrievable" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        MCPTestHelpers.call_tool(client, "julia_run_testitems",
            Dict{String,Any}("name_pattern" => "^passing\$"))

        runs = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testruns"))
        @test length(runs) == 1
        run_id = runs[1]["testrun_id"]

        results = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_get_testrun_results",
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

@testitem "tests run when launched through a Pkg app shim" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    # The `juliamcp` shim pins these to this app's own environment. A test process
    # that inherited them could not load its own environment and would die on startup.
    shim_env = (
        "JULIA_LOAD_PATH" => dirname(dirname(pathof(JuliaMCP))),
        "JULIA_PROJECT" => dirname(dirname(pathof(JuliaMCP))),
        "JULIA_DEPOT_PATH" => first(DEPOT_PATH),
    )

    withenv(shim_env...) do
        MCPTestHelpers.with_mcp_server() do client
            pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
            MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
                Dict{String,Any}("folders" => [pkg], "watch" => false))

            report = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_run_testitems",
                Dict{String,Any}("name_pattern" => "^passing\$")))

            @test report["summary"]["passed"] == 1
            @test report["summary"]["errored"] == 0
        end
    end
end

@testitem "rerun_failed re-runs only the failures" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        MCPTestHelpers.call_tool(client, "julia_run_testitems", Dict{String,Any}())

        run_id = MCPTestHelpers.result_json(
            MCPTestHelpers.call_tool(client, "julia_list_testruns"))[1]["testrun_id"]

        rerun = MCPTestHelpers.call_tool(client, "julia_rerun_failed",
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
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        MCPTestHelpers.call_tool(client, "julia_run_testitems",
            Dict{String,Any}("name_pattern" => "^passing\$"))

        procs = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_test_processes"))
        @test !isempty(procs)
        @test all(p -> p["package_name"] == "BasicPkg", procs)

        result = MCPTestHelpers.call_tool(client, "julia_terminate_test_process",
            Dict{String,Any}("process_id" => procs[1]["id"]))
        @test !MCPTestHelpers.is_error(result)

        @test MCPTestHelpers.timed_wait(30.0) do
            isempty(MCPTestHelpers.result_json(
                MCPTestHelpers.call_tool(client, "julia_list_test_processes")))
        end
    end
end
