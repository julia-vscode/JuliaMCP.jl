@testitem "run payload is compact and carries no detail" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: TestRunRecord, TestItemResult, collect_run_payload, run_summary
    using Dates

    MCPTestHelpers.with_app_state() do state
        items = Dict{String,TestItemResult}(
            "p" => TestItemResult("p", "passing", "file:///a.jl", :passed, 0.1, Any[], ["out"]),
            "f" => TestItemResult("f", "failing", "file:///a.jl", :failed, 0.2,
                Any[Dict("message" => "nope")], ["lots of output"]),
            "e" => TestItemResult("e", "erroring", "file:///a.jl", :errored, 0.3,
                Any[Dict("message" => "boom")], String[]),
        )
        run = TestRunRecord("run-1", :completed, Dict{String,Any}(), items, nothing, Dates.now(), nothing)

        payload = collect_run_payload(state, run, run_summary(run), Dict{String,Any}())

        @test [i["label"] for i in payload["items"]] == ["erroring", "failing"]
        @test payload["total_matching_items"] == 2
        @test payload["items_truncated"] == false
        @test all(i -> !haskey(i, "messages") && !haskey(i, "output"), payload["items"])
        @test occursin("get_testitem_detail", payload["detail_hint"])

        with_passing = collect_run_payload(state, run, run_summary(run),
            Dict{String,Any}("include_passing" => true))
        @test length(with_passing["items"]) == 3
        @test !haskey(with_passing, "note")

        capped = collect_run_payload(state, run, run_summary(run), Dict{String,Any}("max_items" => 1))
        @test length(capped["items"]) == 1
        @test capped["items"][1]["label"] == "erroring"
        @test capped["items_truncated"] == true
        @test capped["total_matching_items"] == 2
    end
end

@testitem "get_testitem_detail batches, truncates and reports unknown ids" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: TestRunRecord, TestItemResult, handle_tool_call
    using Dates

    MCPTestHelpers.with_app_state() do state
        frames = [Dict("label" => "f$i", "uri" => "file:///a.jl", "line" => i, "column" => 1) for i in 1:50]
        items = Dict{String,TestItemResult}(
            "a" => TestItemResult("a", "a", "file:///a.jl", :errored, 1.0,
                Any[Dict{String,Any}("message" => "boom", "stack_trace" => frames)],
                [repeat("x", 5_000), repeat("y", 5_000), "TAIL-MARKER"]),
            "b" => TestItemResult("b", "b", "file:///a.jl", :passed, 0.1, Any[], ["short"]),
        )
        run = TestRunRecord("run-1", :completed, Dict{String,Any}(), items, nothing, Dates.now(), nothing)
        state.runs["run-1"] = run

        details = MCPTestHelpers.result_json(handle_tool_call(state, "get_testitem_detail",
            Dict{String,Any}("testrun_id" => "run-1", "testitem_ids" => ["a", "b", "missing"])))
        @test length(details) == 3

        a, b, missing_item = details
        @test a["found"] && b["found"]
        @test missing_item["found"] == false
        @test missing_item["testitem_id"] == "missing"

        # The tail is what matters — that is where the failure lands.
        @test a["output_truncated"] == true
        @test a["output_total_bytes"] == 10_011
        @test occursin("TAIL-MARKER", a["output"])
        @test occursin("bytes elided", a["output"])
        @test sizeof(a["output"]) < 9_000
        @test a["output_resource"] == "testrun://run-1/items/a/output"

        msg = only(a["messages"])
        @test length(msg["stack_trace"]) == 20
        @test msg["stack_trace_truncated"] == true
        @test msg["total_stack_frames"] == 50

        # Caps are overridable.
        wide = only(MCPTestHelpers.result_json(handle_tool_call(state, "get_testitem_detail",
            Dict{String,Any}("testrun_id" => "run-1", "testitem_ids" => ["a"],
                "max_stack_frames" => 100, "max_output_bytes" => 100_000))))
        @test length(only(wide["messages"])["stack_trace"]) == 50
        @test wide["output_truncated"] == false
    end
end

@testitem "get_testitem_detail needs at least one id" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: handle_tool_call

    MCPTestHelpers.with_app_state() do state
        result = handle_tool_call(state, "get_testitem_detail", Dict{String,Any}("testrun_id" => "run-1"))
        @test MCPTestHelpers.is_error(result)
        @test occursin("testitem_ids", MCPTestHelpers.result_text(result))
    end
end

@testitem "a fully failing noisy suite stays within a byte budget" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "NoisyPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))

        result = MCPTestHelpers.call_tool(client, "run_testitems", Dict{String,Any}())
        text = MCPTestHelpers.result_text(result)

        report = MCPTestHelpers.result_json(result)
        @test report["summary"]["total"] == 3
        @test report["summary"]["passed"] == 0
        @test length(report["items"]) == 3

        # Every item fails after printing megabytes; the report must not carry any of it.
        @test sizeof(text) < 8_000
        @test !occursin("noisy 1 line", text)

        detail = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "get_testitem_detail",
            Dict{String,Any}(
                "testrun_id" => report["summary"]["testrun_id"],
                "testitem_ids" => [i["testitem_id"] for i in report["items"]],
            )))
        @test length(detail) == 3
        @test any(d -> d["output_truncated"], detail)
    end
end

@testitem "process output is readable as a resource" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        MCPTestHelpers.call_tool(client, "run_testitems", Dict{String,Any}("name_pattern" => "^passing\$"))

        procs = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "list_test_processes"))
        @test !isempty(procs)

        uri = "testprocess://$(procs[1]["id"])/output"
        @test uri in [r["uri"] for r in
            MCPTestHelpers.request(client, "resources/list", Dict{String,Any}())["resources"]]

        contents = MCPTestHelpers.read_resource(client, uri)
        @test contents["contents"][1]["mimeType"] == "text/plain"
    end
end
