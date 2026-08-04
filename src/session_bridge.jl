# session_bridge.jl — Map JuliaSessionControllers sessions into AppState

# Session-level output (anything printed outside a request) is only ever context, so a
# bounded tail is enough.
const SESSION_OUTPUT_CHUNK_LIMIT = 200

function create_session_callbacks(state::AppState)
    return JSC.ControllerCallbacks(
        on_session_created = (session_id, env) -> begin
            mcp_notice(state, "session", "Session created: $session_id")
            notify_resource_list_changed(state)
        end,

        on_session_status_changed = (session_id, status) -> begin
            lock(state.lock) do
                rec = get(state.sessions, session_id, nothing)
                rec === nothing && return
                rec.status = status
            end
            mcp_debug(state, "session", "Session $session_id: $status")
        end,

        on_session_output = (session_id, output) -> begin
            lock(state.lock) do
                rec = get(state.sessions, session_id, nothing)
                rec === nothing && return
                push!(rec.output, output)
                length(rec.output) > SESSION_OUTPUT_CHUNK_LIMIT && popfirst!(rec.output)
            end
            notify_resource_updated(state, "session://$session_id/output")
        end,

        on_request_output = (session_id, request_id, output) -> begin
            lock(state.lock) do
                rec = get(state.sessions, session_id, nothing)
                rec === nothing && return
                # Only requests a tool registered are buffered; anything else would grow
                # without bound, so it joins the session tail instead.
                buf = get(rec.request_outputs, request_id, nothing)
                if buf === nothing
                    push!(rec.output, output)
                    length(rec.output) > SESSION_OUTPUT_CHUNK_LIMIT && popfirst!(rec.output)
                else
                    push!(buf, output)
                end
            end
            notify_resource_updated(state, "session://$session_id/output")
        end,

        on_session_terminated = (session_id,) -> begin
            lock(state.lock) do
                rec = get(state.sessions, session_id, nothing)
                rec === nothing && return
                rec.alive = false
                rec.status = "Terminated"
            end
            mcp_notice(state, "session", "Session terminated: $session_id")
            notify_resource_list_changed(state)
        end,

        on_session_died = (session_id, exception) -> begin
            message = sprint(showerror, exception)
            lock(state.lock) do
                rec = get(state.sessions, session_id, nothing)
                rec === nothing && return
                rec.alive = false
                rec.status = "Died"
                rec.exit_message = message
            end
            mcp_error(state, "session", "Session died: $session_id — $message")
            notify_resource_list_changed(state)
        end,
    )
end

function init_session_controller!(state::AppState)
    state.session_controller === nothing || return
    state.session_controller = JSC.JuliaSessionController(create_session_callbacks(state); log_level=:Info)
    state.session_reactor_task = @async Base.run(state.session_controller)
    mcp_notice(state, "transport", "JuliaSessionController initialized")
    return
end

function shutdown_sessions!(state::AppState)
    controller = state.session_controller
    controller === nothing && return
    JSC.shutdown(controller)
    if state.session_reactor_task !== nothing
        JSC.wait_for_shutdown(controller, state.session_reactor_task)
    end
    state.session_controller = nothing
    state.session_reactor_task = nothing
    return
end

"""
Build a `SessionEnvironment` from tool arguments. `project` and `package` are client-supplied
paths or URIs.
"""
function build_session_environment(args::Dict{String,Any})
    project = get(args, "project", nothing)
    package = get(args, "package", nothing)

    julia_env = copy(shim_env_overrides())
    for (k, v) in pairs(get(args, "env", Dict{String,Any}()))
        julia_env[String(k)] = v === nothing ? nothing : String(v)
    end

    return JSC.SessionEnvironment(
        julia_cmd = something(get(args, "julia_cmd", nothing), joinpath(Sys.BINDIR, "julia")),
        julia_args = convert(Vector{String}, get(args, "julia_args", String[])),
        julia_num_threads = let v = get(args, "julia_num_threads", nothing)
            v isa String ? v : nothing
        end,
        julia_env = julia_env,
        project_uri = project === nothing ? nothing : string(resolve_uri(String(project))),
        package_uri = package === nothing ? nothing : string(resolve_uri(String(package))),
        package_name = get(args, "package_name", nothing),
        use_test_env = something(get(args, "use_test_env", nothing), false),
    )
end

"""
The environment as a dict the client can feed straight back into `create_session`. There is
no restart tool, so this is how a crashed session is reproduced.
"""
function session_environment_dict(env::JSC.SessionEnvironment)
    return Dict{String,Any}(
        "julia_cmd" => env.julia_cmd,
        "julia_args" => env.julia_args,
        "julia_num_threads" => env.julia_num_threads,
        "project" => env.project_uri,
        "package" => env.package_uri,
        "package_name" => env.package_name,
        "use_test_env" => env.use_test_env,
    )
end

function session_dict(rec::SessionRecord, info::Union{Nothing,JSC.SessionInfo}=nothing)
    d = Dict{String,Any}(
        "session_id" => rec.id,
        "status" => rec.status,
        "alive" => rec.alive,
        "created_at" => string(rec.created_at),
        "last_used_at" => string(rec.last_used_at),
        "environment" => session_environment_dict(rec.env),
    )
    rec.exit_message === nothing || (d["exit_message"] = rec.exit_message)
    if info !== nothing
        d["active_project"] = info.active_project
        d["queued_requests"] = info.queued_requests
        d["exit_code"] = info.exit_code
    end
    return d
end

"""
Look up a live session, returning an error result the tool can hand straight back when the
id is unknown.
"""
function session_record(state::AppState, args::Dict{String,Any})
    id = args["session_id"]::String
    rec = lock(state.lock) do
        get(state.sessions, id, nothing)
    end
    rec === nothing && return nothing, tool_result_error("Unknown session: $id. Call list_sessions to see active sessions.")
    return rec, nothing
end
