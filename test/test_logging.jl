@testitem "log level gating" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: set_log_level!, MCP_LOG_LEVELS

    MCPTestHelpers.with_app_state() do state
        @test state.log_level == :info

        set_log_level!(state, "error")
        @test state.log_level == :error

        @test_throws ErrorException set_log_level!(state, "not-a-level")
        @test state.log_level == :error

        for level in keys(MCP_LOG_LEVELS)
            set_log_level!(state, string(level))
            @test state.log_level == level
        end
    end
end

@testitem "MCP log levels are ordered by severity" begin
    using TestItemMCPApp: MCP_LOG_LEVELS

    ordered = [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
    @test sort(collect(keys(MCP_LOG_LEVELS)), by = k -> MCP_LOG_LEVELS[k]) == ordered
end

@testitem "log messages below the threshold are suppressed" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.request(client, "logging/setLevel", Dict{String,Any}("level" => "emergency"))
        MCPTestHelpers.drain_notifications(client)

        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        msgs = MCPTestHelpers.drain_notifications(client)
        @test isempty(filter(m -> m.method == "notifications/message", msgs))
    end
end

@testitem "log messages at or above the threshold are delivered" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.request(client, "logging/setLevel", Dict{String,Any}("level" => "debug"))
        MCPTestHelpers.drain_notifications(client)

        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        msg = MCPTestHelpers.wait_for_notification(client, "notifications/message")
        @test msg !== nothing
        @test haskey(msg.params, "level")
        @test haskey(msg.params, "logger")
        @test haskey(msg.params, "data")
    end
end
