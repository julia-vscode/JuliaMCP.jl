# mcp_protocol.jl — MCP protocol constants and helpers

const MCP_SERVER_NAME = "TestItemMCPApp"
const MCP_SERVER_VERSION = "0.1.0"

function server_capabilities()
    return Dict{String,Any}(
        "tools" => Dict{String,Any}("listChanged" => false),
        "resources" => Dict{String,Any}("subscribe" => true, "listChanged" => true),
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
            `run_testitems` and `get_testrun_results` return a summary plus a compact
            per-item status list. They deliberately omit failure messages, stack traces
            and captured output — call `get_testitem_detail` with the ids you care about
            to retrieve those. If a whole test process failed to start (for example a
            precompilation error), read the `testprocess://{process_id}/output` resource.
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

# --- Progress ---

const PROGRESS_HEARTBEAT_INTERVAL = 2.0
# Heartbeats advance progress within the current item, never far enough to imply the next
# one finished.
const PROGRESS_FRAC_CEILING = 0.95

function notify_progress(state::AppState, token, progress::Real, total::Real, message::String)
    try
        JSONRPC.send_notification(state.endpoint, "notifications/progress", Dict{String,Any}(
            "progressToken" => token,
            "progress" => progress,
            "total" => total,
            "message" => message,
        ))
    catch
        # Endpoint may be closed
    end
end

function progress_message(run::TestRunRecord, done::Int, total::Int)
    if done == 0 && !isempty(run.progress_note)
        return "$total test item(s) — $(run.progress_note)"
    end
    failed = count(v -> v.status in (:failed, :errored), values(run.items))
    text = "$done/$total done, $failed failing"
    running = [v.label for v in values(run.items) if v.status === :running]
    if !isempty(running)
        shown = join(first(running, 3), ", ")
        text *= length(running) > 3 ? " — running: $shown, +$(length(running) - 3) more" : " — running: $shown"
    end
    return text
end

"""
Send a `notifications/progress` for `run`, if the client asked for progress on the call
that started it.

Progress is reported as `done + frac`, where `done` counts finished test items and `frac`
is a heartbeat offset within the current item. The spec requires the value to strictly
increase, so nothing is sent unless the candidate beats the last value actually sent.
"""
function report_progress!(state::AppState, run::TestRunRecord; heartbeat::Bool=false, final::Bool=false)
    token = run.progress_token
    token === nothing && return

    payload = lock(state.lock) do
        total = length(run.items)
        done = count(v -> v.status in (:passed, :failed, :errored, :skipped), values(run.items))

        if done != run.progress_done
            run.progress_done = done
            run.progress_frac = 0.0
        elseif heartbeat
            run.progress_frac += (PROGRESS_FRAC_CEILING - run.progress_frac) / 2
        end

        value = final ? float(total) : done + run.progress_frac
        value > run.progress_value || return nothing
        run.progress_value = value

        message = final ? final_progress_message(run, done, total) : progress_message(run, done, total)
        return (value, total, message)
    end

    payload === nothing && return
    notify_progress(state, token, payload[1], payload[2], payload[3])
    return
end

function final_progress_message(run::TestRunRecord, done::Int, total::Int)
    passed = count(v -> v.status === :passed, values(run.items))
    failed = count(v -> v.status === :failed, values(run.items))
    errored = count(v -> v.status === :errored, values(run.items))
    return "$(run.status): $passed passed, $failed failed, $errored errored of $total"
end

"""
Emit progress every couple of seconds so that a long precompilation or a slow test item
still produces traffic — clients reset their request timeout on progress.
"""
function start_heartbeat!(state::AppState, run::TestRunRecord)
    run.progress_token === nothing && return
    stop = Ref(false)
    run.heartbeat_stop = stop
    @async begin
        try
            while !stop[]
                sleep(PROGRESS_HEARTBEAT_INTERVAL)
                stop[] && break
                report_progress!(state, run; heartbeat=true)
            end
        catch err
            @debug "Progress heartbeat stopped" exception = err
        end
    end
    return
end

function stop_heartbeat!(run::TestRunRecord)
    stop = run.heartbeat_stop
    stop === nothing && return
    stop[] = true
    run.heartbeat_stop = nothing
    return
end
