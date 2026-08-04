@testmodule MCPTestHelpers begin

using Test
using Sockets
using TestItemMCPApp
using TestItemMCPApp: JSONRPC, JSON

const TESTDATA_DIR = joinpath(dirname(@__DIR__), "testdata")

"""
Copy a `testdata/` fixture into a fresh temp directory so tests can mutate it
freely. Returns the path to the copy.
"""
function copy_testdata(name::String)
    dest = mktempdir()
    target = joinpath(dest, name)
    cp(joinpath(TESTDATA_DIR, name), target)
    return target
end

"""
Create a connected pair of named pipes. Returns `(server_io, client_io, listener)`.
"""
function named_pipe_pair()
    pipe_name = JSONRPC.generate_pipe_name()
    listener = Sockets.listen(pipe_name)
    accepted = Channel{Any}(1)
    @async put!(accepted, Sockets.accept(listener))
    client = Sockets.connect(pipe_name)
    server = take!(accepted)
    return server, client, listener
end

# --- Bare AppState, no server loop -------------------------------------------

"""
Run `f(state)` with a fresh `AppState` backed by a live endpoint whose output is
discarded. Use for testing handlers directly without the MCP message loop.
"""
function with_app_state(f)
    server_io, client_io, listener = named_pipe_pair()
    endpoint = JSONRPC.JSONRPCEndpoint(server_io, server_io; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(endpoint)
    # Discard anything the state writes so the pipe buffer never fills up.
    drain = @async try
        while !eof(client_io)
            readavailable(client_io)
        end
    catch
    end
    state = TestItemMCPApp.AppState(endpoint)
    try
        f(state)
    finally
        try
            TestItemMCPApp.stop_watcher!(state)
            TestItemMCPApp.shutdown_controller!(state)
            TestItemMCPApp.shutdown_sessions!(state)
        catch
        end
        close(endpoint)
        close(client_io)
        close(server_io)
        close(listener)
        wait(drain)
    end
end

# --- Full server over a transport --------------------------------------------

mutable struct MCPClient
    endpoint::JSONRPC.JSONRPCEndpoint
    client_io::Any
    server_io::Any
    listener::Any
    server_task::Task
end

request(c::MCPClient, method::AbstractString, params=nothing) =
    JSONRPC.send_request(c.endpoint, method, params)

notify(c::MCPClient, method::AbstractString, params=nothing) =
    JSONRPC.send_notification(c.endpoint, method, params)

"""
Perform the MCP `initialize` handshake and return the server's result.
"""
function initialize!(c::MCPClient)
    result = request(c, "initialize", Dict{String,Any}(
        "protocolVersion" => TestItemMCPApp.MCP_PROTOCOL_VERSION,
        "capabilities" => Dict{String,Any}(),
        "clientInfo" => Dict{String,Any}("name" => "MCPTestHelpers", "version" => "0.0.1"),
    ))
    notify(c, "notifications/initialized", nothing)
    return result
end

function call_tool(c::MCPClient, name::AbstractString, args::Dict=Dict{String,Any}(); progress_token=nothing)
    params = Dict{String,Any}("name" => name, "arguments" => args)
    if progress_token !== nothing
        params["_meta"] = Dict{String,Any}("progressToken" => progress_token)
    end
    return request(c, "tools/call", params)
end

read_resource(c::MCPClient, uri::AbstractString) =
    request(c, "resources/read", Dict{String,Any}("uri" => uri))

subscribe(c::MCPClient, uri::AbstractString) =
    request(c, "resources/subscribe", Dict{String,Any}("uri" => uri))

unsubscribe(c::MCPClient, uri::AbstractString) =
    request(c, "resources/unsubscribe", Dict{String,Any}("uri" => uri))

"""
Wait until a server-to-client notification with `method` arrives, or `timeout`
seconds elapse. Returns the message, or `nothing` on timeout. Notifications seen
while waiting are discarded.
"""
function wait_for_notification(c::MCPClient, method::AbstractString; timeout=10.0)
    deadline = time() + timeout
    while time() < deadline
        if isready(c.endpoint.in_msg_queue)
            msg = take!(c.endpoint.in_msg_queue)
            msg.method == method && return msg
        else
            sleep(0.02)
        end
    end
    return nothing
end

"""
Collect every notification currently queued on the client.
"""
function drain_notifications(c::MCPClient)
    msgs = JSONRPC.Request[]
    while isready(c.endpoint.in_msg_queue)
        push!(msgs, take!(c.endpoint.in_msg_queue))
    end
    return msgs
end

"""
Run `f(client)` against a live `run_server` instance. The handshake is performed
unless `initialize=false`.
"""
function with_mcp_server(f; initialize=true)
    server_io, client_io, listener = named_pipe_pair()
    server_task = @async try
        TestItemMCPApp.run_server(server_io, server_io)
    catch err
        @error "MCP server task failed" exception = (err, catch_backtrace())
    end

    endpoint = JSONRPC.JSONRPCEndpoint(client_io, client_io; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(endpoint)
    client = MCPClient(endpoint, client_io, server_io, listener, server_task)

    initialize && initialize!(client)
    try
        f(client)
    finally
        close(endpoint)
        close(client_io)
        # Give the server a moment to notice the closed transport and shut down.
        timed_wait(() -> istaskdone(server_task), 30.0)
        close(server_io)
        close(listener)
    end
end

# --- Result helpers -----------------------------------------------------------

is_error(result) = get(result, "isError", false) === true

function result_text(result)
    content = result["content"]
    return join([c["text"] for c in content if c["type"] == "text"], "\n")
end

result_json(result) = JSON.parse(result_text(result))

resource_json(result) = JSON.parse(result["contents"][1]["text"])

"""
Poll `f` until it returns `true` or `timeout` seconds elapse. Returns whether it
succeeded.
"""
function timed_wait(f, timeout; interval=0.05)
    deadline = time() + timeout
    while time() < deadline
        f() && return true
        sleep(interval)
    end
    return f()
end

end
