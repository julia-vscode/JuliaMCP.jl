# mcp_logging.jl — Diagnostic logging to stderr
#
# MCP's `logging` capability (`notifications/message`) is Deprecated as of spec revision
# 2026-07-28 (SEP-2577); the prescribed migration for stdio servers is to log to stderr.
# The MCP severity vocabulary is kept as a verbosity dial, but is no longer wire-visible.

# MCP severity levels in order (lowest → highest)
const MCP_LOG_LEVELS = Dict{Symbol,Int}(
    :debug => 0,
    :info => 1,
    :notice => 2,
    :warning => 3,
    :error => 4,
    :critical => 5,
    :alert => 6,
    :emergency => 7,
)

function mcp_log(state::AppState, level::Symbol, logger::String, data)
    level_rank = get(MCP_LOG_LEVELS, level, 1)
    min_rank = get(MCP_LOG_LEVELS, state.log_level, 1)
    level_rank < min_rank && return

    # stdout is exclusively for MCP messages, so everything diagnostic goes to stderr.
    if level_rank <= MCP_LOG_LEVELS[:debug]
        @debug data _group = logger
    elseif level_rank <= MCP_LOG_LEVELS[:notice]
        @info data _group = logger
    elseif level_rank <= MCP_LOG_LEVELS[:warning]
        @warn data _group = logger
    else
        @error data _group = logger
    end
    return
end

mcp_debug(state::AppState, logger::String, data) = mcp_log(state, :debug, logger, data)
mcp_info(state::AppState, logger::String, data) = mcp_log(state, :info, logger, data)
mcp_notice(state::AppState, logger::String, data) = mcp_log(state, :notice, logger, data)
mcp_warn(state::AppState, logger::String, data) = mcp_log(state, :warning, logger, data)
mcp_error(state::AppState, logger::String, data) = mcp_log(state, :error, logger, data)

function set_log_level!(state::AppState, level::String)
    sym = Symbol(level)
    if !haskey(MCP_LOG_LEVELS, sym)
        error("Invalid log level: $level")
    end
    state.log_level = sym
end
