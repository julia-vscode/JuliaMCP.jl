@testitem "log level gating" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: set_log_level!, MCP_LOG_LEVELS

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
    using JuliaMCP: MCP_LOG_LEVELS

    ordered = [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
    @test sort(collect(keys(MCP_LOG_LEVELS)), by = k -> MCP_LOG_LEVELS[k]) == ordered
end

@testitem "no notifications/message is ever sent" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    # MCP Logging is deprecated as of spec 2026-07-28; diagnostics go to stderr now.
    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))
        MCPTestHelpers.call_tool(client, "list_testitems")

        msgs = MCPTestHelpers.drain_notifications(client)
        @test isempty(filter(m -> m.method == "notifications/message", msgs))
    end
end

@testitem "log helpers write to stderr" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: mcp_warn, mcp_debug, set_log_level!

    MCPTestHelpers.with_app_state() do state
        set_log_level!(state, "debug")
        @test_logs (:warn,) mcp_warn(state, "testing", "a warning")

        # Below the threshold, nothing is emitted at all.
        set_log_level!(state, "error")
        @test_logs mcp_debug(state, "testing", "suppressed")
    end
end
