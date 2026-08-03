# state.jl — Application state

mutable struct AppState
    workspace::Union{Nothing,JuliaWorkspaces.JuliaWorkspace}
    controller::Union{Nothing,TestItemControllers.TestItemController}
    reactor_task::Union{Nothing,Task}
    runs::Dict{String,TestRunRecord}
    processes::Dict{String,ProcessInfo}
    process_outputs::Dict{String,Vector{String}}
    endpoint::JSONRPC.JSONRPCEndpoint
    subscriptions::Set{String}
    log_level::Symbol  # MCP log level: :debug, :info, :notice, :warning, :error, :critical, :alert, :emergency
    cancellation_sources::Dict{String,CancellationTokens.CancellationTokenSource}  # testrun_id → cts
    test_env_by_id::Dict{String,TestItemControllers.TestEnvironment}
    lock::ReentrantLock
    # The Salsa runtime behind `workspace` is not safe for concurrent access, and
    # both the message loop and the file watcher touch it — so every call into
    # JuliaWorkspaces must hold this lock.
    workspace_lock::ReentrantLock
    folders::Vector{String}
    watcher_task::Union{Nothing,Task}
    watcher_stop::Union{Nothing,Ref{Bool}}
    watcher_snapshot::Dict{String,Float64}
end

function AppState(endpoint::JSONRPC.JSONRPCEndpoint)
    return AppState(
        nothing,
        nothing,
        nothing,
        Dict{String,TestRunRecord}(),
        Dict{String,ProcessInfo}(),
        Dict{String,Vector{String}}(),
        endpoint,
        Set{String}(),
        :info,
        Dict{String,CancellationTokens.CancellationTokenSource}(),
        Dict{String,TestItemControllers.TestEnvironment}(),
        ReentrantLock(),
        ReentrantLock(),
        String[],
        nothing,
        nothing,
        Dict{String,Float64}(),
    )
end

"""
Run `f` while holding the workspace lock.
"""
with_workspace_lock(f, state::AppState) = lock(f, state.workspace_lock)
