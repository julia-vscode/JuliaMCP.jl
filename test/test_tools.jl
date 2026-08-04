@testitem "tool schemas are well formed" begin
    defs = TestItemMCPApp.tool_definitions()

    @test !isempty(defs)
    names = [d["name"] for d in defs]
    @test length(names) == length(unique(names))

    for d in defs
        @test haskey(d, "name") && d["name"] isa String && !isempty(d["name"])
        @test haskey(d, "description") && !isempty(d["description"])
        schema = d["inputSchema"]
        @test schema["type"] == "object"
        @test haskey(schema, "properties")
        for req in get(schema, "required", String[])
            @test haskey(schema["properties"], req)
        end
        for (_, prop) in schema["properties"]
            @test haskey(prop, "type")
        end
    end
end

@testitem "every advertised tool is routed" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_app_state() do state
        for d in TestItemMCPApp.tool_definitions()
            # A routed tool either succeeds or fails on its own arguments/state;
            # only an unrouted one raises "Unknown tool".
            err = try
                TestItemMCPApp.handle_tool_call(state, d["name"], Dict{String,Any}())
                nothing
            catch e
                e
            end
            if err isa ErrorException
                @test !occursin("Unknown tool", err.msg)
            end
        end

        @test_throws ErrorException TestItemMCPApp.handle_tool_call(state, "no_such_tool", Dict{String,Any}())
    end
end

@testitem "set_workspace_folders and list_testitems" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        result = MCPTestHelpers.call_tool(client, "set_workspace_folders",
            Dict{String,Any}("folders" => [pkg]))

        @test !MCPTestHelpers.is_error(result)
        @test occursin("7 test item", MCPTestHelpers.result_text(result))

        items = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "list_testitems"))
        @test length(items) == 7
        @test all(i -> i["package_name"] == "BasicPkg", items)
    end
end

@testitem "list_testitems honours filters" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        by_tag = MCPTestHelpers.result_json(
            MCPTestHelpers.call_tool(client, "list_testitems", Dict{String,Any}("tags" => ["fast"])))
        @test [i["name"] for i in by_tag] == ["also passing"]

        by_name = MCPTestHelpers.result_json(
            MCPTestHelpers.call_tool(client, "list_testitems", Dict{String,Any}("name_pattern" => "^erroring\$")))
        @test [i["name"] for i in by_name] == ["erroring"]

        by_package = MCPTestHelpers.result_json(
            MCPTestHelpers.call_tool(client, "list_testitems", Dict{String,Any}("package" => "NoSuchPkg")))
        @test isempty(by_package)

        by_id = MCPTestHelpers.result_json(
            MCPTestHelpers.call_tool(client, "list_testitems", Dict{String,Any}("items" => [first(by_tag)["id"]])))
        @test length(by_id) == 1
    end
end

@testitem "get_testitem_detail reports results for a run" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: TestRunRecord, TestItemResult, handle_tool_call
    using Dates

    MCPTestHelpers.with_app_state() do state
        run = TestRunRecord("run-1", :completed, Dict{String,Any}(), Dict{String,TestItemResult}(),
            nothing, Dates.now(), nothing)
        run.items["item-1"] = TestItemResult("item-1", "passing", "file:///a.jl", :passed, 0.5,
            Any[], ["some output"])
        state.runs["run-1"] = run

        result = handle_tool_call(state, "get_testitem_detail",
            Dict{String,Any}("testrun_id" => "run-1", "testitem_id" => "item-1"))
        @test !MCPTestHelpers.is_error(result)
        detail = only(MCPTestHelpers.result_json(result))
        @test detail["label"] == "passing"
        @test detail["status"] == "passed"
        @test detail["output"] == "some output"

        # An unknown item is reported in-band; only an unknown run is a tool error.
        unknown = only(MCPTestHelpers.result_json(handle_tool_call(state, "get_testitem_detail",
            Dict{String,Any}("testrun_id" => "run-1", "testitem_id" => "nope"))))
        @test unknown["found"] == false

        @test MCPTestHelpers.is_error(handle_tool_call(state, "get_testitem_detail",
            Dict{String,Any}("testrun_id" => "nope", "testitem_id" => "item-1")))
    end
end

@testitem "missing required arguments produce a tool error" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        for (tool, arg) in (("set_workspace_folders", "folders"),
                            ("update_file", "path"),
                            ("get_testrun_results", "testrun_id"),
                            ("terminate_test_process", "process_id"))
            result = MCPTestHelpers.call_tool(client, tool, Dict{String,Any}())
            @test MCPTestHelpers.is_error(result)
            @test occursin(arg, MCPTestHelpers.result_text(result))
        end

        # Supplying the arguments gets past validation into the handler.
        result = MCPTestHelpers.call_tool(client, "get_testitem_detail",
            Dict{String,Any}("testrun_id" => "a", "testitem_id" => "b"))
        @test MCPTestHelpers.is_error(result)
        @test !occursin("Missing required argument", MCPTestHelpers.result_text(result))
    end
end

@testitem "update_file picks up on-disc edits" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    pkg = MCPTestHelpers.copy_testdata("BasicPkg")
    testfile = joinpath(pkg, "test", "test_basics.jl")

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))
        @test length(MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "list_testitems"))) == 7

        open(testfile, "a") do io
            println(io, "\n@testitem \"added later\" begin\n    @test true\nend")
        end
        result = MCPTestHelpers.call_tool(client, "update_file", Dict{String,Any}("path" => testfile))
        @test !MCPTestHelpers.is_error(result)

        items = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "list_testitems"))
        @test length(items) == 8
        @test "added later" in [i["name"] for i in items]
    end
end

@testitem "workspace tools error before configuration" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        for tool in ("list_testitems", "run_testitems", "update_file")
            args = tool == "update_file" ? Dict{String,Any}("path" => "nope.jl") : Dict{String,Any}()
            result = MCPTestHelpers.call_tool(client, tool, args)
            @test MCPTestHelpers.is_error(result)
            @test occursin("set_workspace_folders", MCPTestHelpers.result_text(result))
        end
    end
end

@testitem "run/coverage tools reject unknown ids" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        for tool in ("get_testrun_results", "cancel_testrun", "rerun_failed", "get_coverage_results")
            result = MCPTestHelpers.call_tool(client, tool, Dict{String,Any}("testrun_id" => "nope"))
            @test MCPTestHelpers.is_error(result)
        end
    end
end

@testitem "list_testruns and list_test_processes start empty" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        @test MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "list_testruns")) == []
        @test MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "list_test_processes")) == []
    end
end

@testitem "run_testitems reports when nothing matches" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        result = MCPTestHelpers.call_tool(client, "run_testitems",
            Dict{String,Any}("name_pattern" => "definitely-no-such-test"))
        @test occursin("No test items matched", MCPTestHelpers.result_text(result))
    end
end
