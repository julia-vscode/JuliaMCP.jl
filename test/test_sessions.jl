@testitem "a session runs code and keeps its state" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))
        session_id = created["session_id"]
        @test created["alive"]

        first = MCPTestHelpers.result_json(
            MCPTestHelpers.call_tool(client, "eval_code", Dict("session_id" => session_id, "code" => "x = 41")))
        @test first["status"] == "success"
        @test first["result"] == "41"

        second = MCPTestHelpers.result_json(
            MCPTestHelpers.call_tool(client, "eval_code", Dict("session_id" => session_id, "code" => "x + 1")))
        @test second["result"] == "42"

        MCPTestHelpers.call_tool(client, "kill_session", Dict("session_id" => session_id))
    end
end

@testitem "session tools work without a workspace" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    # Deliberately no set_workspace_folders — sessions are independent of test detection.
    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))
        result = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(
            client, "eval_code", Dict("session_id" => created["session_id"], "code" => "1 + 1")))

        @test result["result"] == "2"
    end
end

@testitem "an error in evaluated code is a result, not a tool failure" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))
        raw = MCPTestHelpers.call_tool(client, "eval_code",
            Dict("session_id" => created["session_id"], "code" => "println(\"before\"); error(\"boom\")"))

        @test !MCPTestHelpers.is_error(raw)
        result = MCPTestHelpers.result_json(raw)
        @test result["status"] == "error"
        @test occursin("boom", result["error"])
        # Output printed before the failure is still reported.
        @test occursin("before", result["output"])
    end
end

@testitem "output is attributed to the call that produced it" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))
        session_id = created["session_id"]

        one = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(
            client, "eval_code", Dict("session_id" => session_id, "code" => "println(\"first-call\")")))
        two = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(
            client, "eval_code", Dict("session_id" => session_id, "code" => "println(\"second-call\")")))

        @test occursin("first-call", one["output"])
        @test !occursin("second-call", one["output"])
        @test occursin("second-call", two["output"])
        @test !occursin("first-call", two["output"])
    end
end

@testitem "output is truncated to the requested cap" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))
        result = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "eval_code", Dict(
            "session_id" => created["session_id"],
            "code" => "for i in 1:500; println(\"line \$i \", \"x\"^80); end",
            "max_output_bytes" => 2_000,
        )))

        @test result["output_truncated"]
        @test result["output_bytes"] > 2_000
        @test sizeof(result["output"]) < 4_000
    end
end

@testitem "a timeout interrupts the code and leaves the session usable" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))
        session_id = created["session_id"]

        raw = MCPTestHelpers.call_tool(client, "eval_code",
            Dict("session_id" => session_id, "code" => "sleep(60)", "timeout" => 2))
        @test MCPTestHelpers.is_error(raw)
        @test MCPTestHelpers.result_json(raw)["timed_out"]

        recovered = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(
            client, "eval_code", Dict("session_id" => session_id, "code" => "6 * 7")))
        @test recovered["result"] == "42"
    end
end

@testitem "sessions do not share state" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        one = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))["session_id"]
        two = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))["session_id"]

        MCPTestHelpers.call_tool(client, "eval_code", Dict("session_id" => one, "code" => "secret = 99"))
        result = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(
            client, "eval_code", Dict("session_id" => two, "code" => "isdefined(Main, :secret)")))

        @test result["result"] == "false"
    end
end

@testitem "list_sessions reports the environment a session can be recreated from" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    project = MCPTestHelpers.copy_testdata("BasicPkg")

    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(
            client, "create_session", Dict("project" => project, "package_name" => "BasicPkg")))
        session_id = created["session_id"]

        sessions = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "list_sessions"))
        @test length(sessions) == 1
        entry = only(sessions)
        @test entry["session_id"] == session_id
        # This is what stands in for a restart tool.
        @test occursin("BasicPkg", entry["environment"]["project"])
        @test entry["environment"]["package_name"] == "BasicPkg"

        MCPTestHelpers.call_tool(client, "kill_session", Dict("session_id" => session_id))
        @test isempty(MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "list_sessions")))
    end
end

@testitem "a session activates the project it was given" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    project = MCPTestHelpers.copy_testdata("BasicPkg")

    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(
            client, "create_session", Dict("project" => project, "package_name" => "BasicPkg")))
        result = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "eval_code",
            Dict("session_id" => created["session_id"], "code" => "Base.active_project()")))

        @test occursin("BasicPkg", result["result"])
    end
end

@testitem "session variables can be listed" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))
        session_id = created["session_id"]
        MCPTestHelpers.call_tool(client, "eval_code", Dict("session_id" => session_id, "code" => "answer = 42"))

        variables = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(
            client, "get_session_variables", Dict("session_id" => session_id)))
        names = [v["name"] for v in variables]

        @test "answer" in names
        @test only(v["value"] for v in variables if v["name"] == "answer") == "42"
    end
end

@testitem "profiling reports the hottest functions" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))
        session_id = created["session_id"]
        MCPTestHelpers.call_tool(client, "eval_code", Dict(
            "session_id" => session_id,
            "code" => "burn(n) = (s = 0.0; for i in 1:n; s += sin(i); end; s); burn(10)",
        ))

        result = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "profile_code", Dict(
            "session_id" => session_id,
            "code" => "burn(20_000_000)",
            "max_entries" => 100,
        )))

        @test result["total_samples"] > 0
        hot = result["hot_functions"]
        @test !isempty(hot)
        # Sorted by self samples, so the arithmetic inside `sin` outranks `burn` itself.
        @test issorted([f["self_samples"] for f in hot], rev=true)
        @test any(f -> f["function"] == "burn", hot)
        # Every sample is under `burn`, so its total must cover the whole profile.
        burn = only(f for f in hot if f["function"] == "burn")
        @test burn["total_samples"] >= burn["self_samples"]
    end
end

@testitem "profile entries are capped" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        session_id = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))["session_id"]
        MCPTestHelpers.call_tool(client, "eval_code", Dict(
            "session_id" => session_id,
            "code" => "burn(n) = (s = 0.0; for i in 1:n; s += sin(i); end; s); burn(10)",
        ))

        result = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "profile_code", Dict(
            "session_id" => session_id, "code" => "burn(5_000_000)", "max_entries" => 5,
        )))

        @test length(result["hot_functions"]) <= 5
    end
end

@testitem "an unknown session id is reported, not thrown" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        for (tool, args) in (
            ("eval_code", Dict("session_id" => "nope", "code" => "1")),
            ("kill_session", Dict("session_id" => "nope")),
            ("interrupt_session", Dict("session_id" => "nope")),
            ("get_session_variables", Dict("session_id" => "nope")),
        )
            raw = MCPTestHelpers.call_tool(client, tool, args)
            @test MCPTestHelpers.is_error(raw)
            @test occursin("Unknown session", MCPTestHelpers.result_text(raw))
        end
    end
end

@testitem "session resources expose status and output" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        created = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))
        session_id = created["session_id"]

        info = MCPTestHelpers.resource_json(MCPTestHelpers.read_resource(client, "session://$session_id/info"))
        @test info["session_id"] == session_id
        @test info["alive"]

        resources = MCPTestHelpers.request(client, "resources/list", nothing)["resources"]
        uris = [r["uri"] for r in resources]
        @test "session://$session_id/info" in uris
        @test "session://$session_id/output" in uris
    end
end

@testitem "a killed session is gone" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        session_id = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "create_session"))["session_id"]
        MCPTestHelpers.call_tool(client, "eval_code", Dict("session_id" => session_id, "code" => "y = 1"))
        MCPTestHelpers.call_tool(client, "kill_session", Dict("session_id" => session_id))

        raw = MCPTestHelpers.call_tool(client, "eval_code", Dict("session_id" => session_id, "code" => "y"))
        @test MCPTestHelpers.is_error(raw)
    end
end
