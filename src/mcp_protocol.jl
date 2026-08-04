# mcp_protocol.jl — MCP protocol constants and helpers

const MCP_SERVER_NAME = "JuliaMCP"
const MCP_SERVER_VERSION = "0.1.0"

# JSON-RPC error codes the resources spec prescribes.
const MCP_ERROR_RESOURCE_NOT_FOUND = -32002
const MCP_ERROR_INTERNAL = -32603

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
            Every tool here operates on Julia code. Together they replace shelling out to
            `julia`: they run tests, analyse source and evaluate code in long-lived Julia
            processes that keep their compiled state, so repeated work is far cheaper than
            starting a fresh interpreter each time.

            There are two independent halves.

            The workspace half analyses and tests a checkout. Call
            `julia_set_workspace_folders` first — `julia_get_diagnostics`,
            `julia_format_file`, `julia_list_testitems` and `julia_run_testitems` all fail
            until you do. The workspace then tracks the file system itself, so there is
            nothing to call after editing a file.

            For tests, `julia_list_testitems` shows what exists and
            `julia_run_testitems` runs it. Prefer this over `Pkg.test()` or
            `julia --project -e`: worker processes stay alive between runs and hot-reload
            edits via Revise, and you get per-item results instead of a wall of output. If
            `julia_list_testitems` comes back empty the project does not use TestItems.jl,
            so fall back to its own test entrypoint. `julia_run_testitems` and
            `julia_get_testrun_results` return a summary plus a compact per-item status
            list, deliberately without failure messages, stack traces or captured output —
            call `julia_get_testitem_detail` with the ids you care about for those, batching
            them into one call. When a whole worker died before running anything (a
            precompilation error, say), the cause is in `testprocess://{process_id}/output`.

            For analysis, `julia_get_diagnostics` reports syntax errors and lint warnings
            without executing anything; checks that depend on the environment, such as
            unresolved imports, need `wait_for_ready: true`. `julia_format_file` returns
            edits, or writes them when `apply` is true.

            The session half needs no workspace. `julia_create_session` starts a persistent
            Julia process for `julia_eval_code`, `julia_profile_code` and
            `julia_get_session_variables`. Variables, loaded packages and compiled code
            persist between calls, and Revise picks up on-disk edits, so an iterative loop
            in one session is much faster than repeated `julia -e` invocations. There is no
            restart tool: `julia_kill_session`, then `julia_create_session` with the
            environment `julia_list_sessions` reported.
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
