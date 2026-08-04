module JuliaMCP

import JSON, JSONRPC, JuliaWorkspaces, TestItemControllers
import JuliaSessionControllers
import UUIDs, Dates, Logging

# Never `using` this one: it exports `shutdown`, `wait_for_shutdown`, `list_sessions` and
# `ControllerCallbacks`, all of which collide with TestItemControllers.
const JSC = JuliaSessionControllers

# TestItemControllers vendors its own copy of CancellationTokens, and tokens
# cross that boundary in `execute_testrun` — so we must use the same one it does
# rather than a separately resolved package.
const CancellationTokens = TestItemControllers.CancellationTokens

include("types.jl")
include("state.jl")
include("mcp_logging.jl")
include("mcp_protocol.jl")
include("bridge.jl")
include("session_bridge.jl")
include("diagnostics.jl")
include("watcher.jl")
include("callbacks.jl")
include("mcp_tools.jl")
include("mcp_resources.jl")
include("tool_handlers.jl")
include("mcp_server.jl")

function (@main)(ARGS)
    # All logging goes to stderr — stdout is exclusively for MCP messages
    debuglogger = Logging.ConsoleLogger(stderr, Logging.Debug)
    Logging.with_logger(debuglogger) do
        run_server(stdin, stdout)
    end
end

end # module JuliaMCP
