# mcp_server.jl — MCP server main loop

function run_server(input::IO, output::IO)
    endpoint = JSONRPC.JSONRPCEndpoint(input, output; framing=JSONRPC.NewlineDelimitedFraming())
    state = AppState(endpoint)

    JSONRPC.start(endpoint)

    mcp_debug(state, "transport", "MCP server started, waiting for initialize request")

    try
        serve_loop(state, endpoint)
    catch e
        if e isa JSONRPC.TransportError || e isa Base.IOError || e isa InvalidStateException
            mcp_debug(state, "transport", "Connection closed")
        else
            @error "Server error" exception = (e, catch_backtrace())
        end
    finally
        stop_watcher!(state)
        shutdown_controller!(state)
        shutdown_sessions!(state)
        try
            close(endpoint)
        catch
        end
    end
end

function serve_loop(state::AppState, endpoint::JSONRPC.JSONRPCEndpoint)
    while true
        msg = JSONRPC.get_next_message(endpoint)
        @async try
            dispatch_mcp_message(state, endpoint, msg)
        catch e
            report_handler_error(state, endpoint, msg, e, catch_backtrace())
        end
    end
end

"""
Report a failed request to the client. A `ResourceNotFound` is the client naming something
that does not exist, so it gets the spec's -32002 and no stack trace; anything else is a
genuine server fault and is logged as one.
"""
function report_handler_error(state::AppState, endpoint::JSONRPC.JSONRPCEndpoint, msg::JSONRPC.Request, e, backtrace)
    resource_missing = e isa ResourceNotFound
    if msg.id !== nothing
        code, message, data = resource_missing ?
            (MCP_ERROR_RESOURCE_NOT_FOUND, e.message, Dict{String,Any}("uri" => e.uri)) :
            (MCP_ERROR_INTERNAL, "Internal error: $(sprint(showerror, e))", nothing)
        try
            JSONRPC.send_error_response(endpoint, msg, code, message, data)
        catch
        end
    end

    if resource_missing
        mcp_debug(state, "resources", e.message)
    else
        @error "Handler error" method = msg.method exception = (e, backtrace)
    end
    return
end

function dispatch_mcp_message(state::AppState, endpoint::JSONRPC.JSONRPCEndpoint, msg::JSONRPC.Request)
    method = msg.method
    params = msg.params === nothing ? Dict{String,Any}() : msg.params

    # --- Lifecycle ---
    if method == "initialize"
        result = handle_initialize(state, params)
        JSONRPC.send_success_response(endpoint, msg, result)
        return
    end

    if method == "notifications/initialized"
        # Client acknowledged initialization — nothing to do
        return
    end

    if method == "ping"
        JSONRPC.send_success_response(endpoint, msg, Dict{String,Any}())
        return
    end

    # --- Tools ---
    if method == "tools/list"
        result = Dict{String,Any}("tools" => tool_definitions())
        JSONRPC.send_success_response(endpoint, msg, result)
        return
    end

    if method == "tools/call"
        tool_name = params["name"]::String
        arguments = get(params, "arguments", Dict{String,Any}())
        if arguments isa Dict
            arguments = convert(Dict{String,Any}, arguments)
        else
            arguments = Dict{String,Any}()
        end
        result = handle_tool_call(state, tool_name, arguments; progress_token=progress_token_of(params))
        JSONRPC.send_success_response(endpoint, msg, result)
        return
    end

    # --- Resources ---
    if method == "resources/list"
        result = handle_resources_list(state, params)
        JSONRPC.send_success_response(endpoint, msg, result)
        return
    end

    if method == "resources/templates/list"
        result = handle_resource_templates_list(state, params)
        JSONRPC.send_success_response(endpoint, msg, result)
        return
    end

    if method == "resources/read"
        result = handle_resources_read(state, params)
        JSONRPC.send_success_response(endpoint, msg, result)
        return
    end

    if method == "resources/subscribe"
        result = handle_resources_subscribe(state, params)
        JSONRPC.send_success_response(endpoint, msg, result)
        return
    end

    if method == "resources/unsubscribe"
        result = handle_resources_unsubscribe(state, params)
        JSONRPC.send_success_response(endpoint, msg, result)
        return
    end

    # --- Unknown method ---
    if msg.id !== nothing
        JSONRPC.send_error_response(endpoint, msg, -32601, "Method not found: $method", nothing)
    end
end

"""
The client opts into progress reporting by putting a `progressToken` in the request's
`_meta`. Per spec it is a string or an integer; anything else is ignored.
"""
function progress_token_of(params)
    meta = get(params, "_meta", nothing)
    meta isa Dict || return nothing
    token = get(meta, "progressToken", nothing)
    return token isa String || token isa Integer ? token : nothing
end
