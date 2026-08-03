# mcp_protocol.jl — MCP protocol constants and helpers

const MCP_SERVER_NAME = "TestItemMCPApp"
const MCP_SERVER_VERSION = "0.1.0"

function server_capabilities()
    return Dict{String,Any}(
        "tools" => Dict{String,Any}("listChanged" => false),
        "resources" => Dict{String,Any}("subscribe" => true, "listChanged" => true),
        "logging" => Dict{String,Any}(),
    )
end

function handle_initialize(state::AppState, params::Dict)
    client_version = get(params, "protocolVersion", MCP_PROTOCOL_VERSION)
    mcp_info(state, "transport", "Client connected: $(get(get(params, "clientInfo", Dict()), "name", "unknown")) (protocol $client_version)")

    return Dict{String,Any}(
        "protocolVersion" => MCP_PROTOCOL_VERSION,
        "capabilities" => server_capabilities(),
        "serverInfo" => Dict{String,Any}(
            "name" => MCP_SERVER_NAME,
            "version" => MCP_SERVER_VERSION,
        ),
        "instructions" => """
            This server provides tools for discovering and running Julia test items,
            and for analysing Julia source files.
            Start by calling `set_workspace_folders` to configure the workspace, then
            `list_testitems` to discover tests, and `run_testitems` to execute them.
            Test processes are kept alive for fast re-runs via Revise-based hot-reload.
            `get_diagnostics` reports syntax errors and lint warnings; environment-dependent
            checks such as unresolved imports require `wait_for_ready: true`.
            `format_file` returns formatting edits, or applies them when `apply` is true.
        """,
    )
end

function notify_resource_updated(state::AppState, uri::String)
    if uri in state.subscriptions
        try
            JSONRPC.send_notification(state.endpoint, "notifications/resources/updated", Dict{String,Any}(
                "uri" => uri,
            ))
        catch
        end
    end
end

function notify_resource_list_changed(state::AppState)
    try
        JSONRPC.send_notification(state.endpoint, "notifications/resources/list_changed", nothing)
    catch
    end
end
