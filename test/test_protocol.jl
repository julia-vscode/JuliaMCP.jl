@testitem "initialize handshake" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server(initialize=false) do client
        result = MCPTestHelpers.initialize!(client)

        @test result["protocolVersion"] == JuliaMCP.MCP_PROTOCOL_VERSION
        @test result["serverInfo"]["name"] == "JuliaMCP"
        @test haskey(result["serverInfo"], "version")
        @test result["capabilities"]["resources"]["subscribe"] == true
        @test result["capabilities"]["resources"]["listChanged"] == true
        @test haskey(result["capabilities"], "tools")
        # MCP Logging is deprecated as of spec 2026-07-28; we log to stderr instead.
        @test !haskey(result["capabilities"], "logging")
        @test occursin("set_workspace_folders", result["instructions"])
    end
end

@testitem "ping" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        @test MCPTestHelpers.request(client, "ping", Dict{String,Any}()) == Dict{String,Any}()
    end
end

@testitem "unknown method returns -32601" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JSONRPC

    MCPTestHelpers.with_mcp_server() do client
        err = try
            MCPTestHelpers.request(client, "no/such/method", nothing)
            nothing
        catch e
            e
        end
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32601
        @test occursin("no/such/method", err.msg)
    end
end

@testitem "tools/list matches tool_definitions" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        result = MCPTestHelpers.request(client, "tools/list", Dict{String,Any}())
        names = [t["name"] for t in result["tools"]]
        expected = [t["name"] for t in JuliaMCP.tool_definitions()]

        @test sort(names) == sort(expected)
        @test length(names) == length(unique(names))
    end
end

@testitem "resources/templates/list" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        result = MCPTestHelpers.request(client, "resources/templates/list", Dict{String,Any}())
        templates = [t["uriTemplate"] for t in result["resourceTemplates"]]

        @test "testrun://{testrun_id}/summary" in templates
        @test "testrun://{testrun_id}/failures" in templates
        @test "testrun://{testrun_id}/coverage" in templates
        @test "testrun://{testrun_id}/items/{testitem_id}/output" in templates
        @test "testprocess://{process_id}/output" in templates
    end
end

@testitem "logging/setLevel is gone" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JSONRPC

    # Removed with the deprecated MCP Logging capability.
    MCPTestHelpers.with_mcp_server() do client
        err = try
            MCPTestHelpers.request(client, "logging/setLevel", Dict{String,Any}("level" => "error"))
            nothing
        catch e
            e
        end
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32601
    end
end

@testitem "server shuts down cleanly when the client disconnects" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    # `with_mcp_server` waits for the server task to finish on teardown and would
    # report a failure if the task errored out instead of exiting cleanly.
    task = MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.request(client, "ping", Dict{String,Any}())
        client.server_task
    end

    @test istaskdone(task)
    @test !istaskfailed(task)
end
