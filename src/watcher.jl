# watcher.jl — Keep the workspace in sync with on-disc changes

const WATCH_INTERVAL_DEFAULT = 1.0
const WATCH_DEBOUNCE_DEFAULT = 0.25

const WATCH_SKIP_DIRS = Set(["node_modules", "build", "deps"])

"""
Whether changes to `path` can affect analysis results.
"""
function is_watched_path(path::AbstractString)
    return JuliaWorkspaces.is_path_julia_file(path) ||
        JuliaWorkspaces.is_path_project_file(path) ||
        JuliaWorkspaces.is_path_manifest_file(path) ||
        JuliaWorkspaces.is_path_toolconfig_file(path)
end

function scan_folder!(snapshot::Dict{String,Float64}, dir::AbstractString)
    entries = try
        readdir(dir)
    catch
        return snapshot
    end

    for name in entries
        startswith(name, ".") && continue
        name in WATCH_SKIP_DIRS && continue
        path = joinpath(dir, name)
        if isdir(path)
            scan_folder!(snapshot, path)
        elseif is_watched_path(path)
            try
                snapshot[path] = mtime(path)
            catch
                # File vanished between readdir and stat.
            end
        end
    end
    return snapshot
end

"""
Build a `path => mtime` snapshot of every analysis-relevant file under `folders`.
"""
function scan_folders(folders)
    snapshot = Dict{String,Float64}()
    for folder in folders
        isdir(folder) && scan_folder!(snapshot, folder)
    end
    return snapshot
end

"""
Compare two snapshots. Returns `(created, modified, deleted)` path vectors.
"""
function diff_snapshots(old::Dict{String,Float64}, new::Dict{String,Float64})
    created = String[]
    modified = String[]
    for (path, stamp) in new
        if !haskey(old, path)
            push!(created, path)
        elseif old[path] != stamp
            push!(modified, path)
        end
    end
    deleted = String[path for path in keys(old) if !haskey(new, path)]
    return sort!(created), sort!(modified), sort!(deleted)
end

"""
Apply on-disc changes to the workspace. Returns the number of files applied.
"""
function apply_file_changes!(state::AppState, created, modified, deleted)
    applied = 0
    with_workspace_lock(state) do
        jw = state.workspace
        jw === nothing && return
        for path in Iterators.flatten((created, modified))
            uri = JuliaWorkspaces.filepath2uri(path)
            try
                if JuliaWorkspaces.has_file(jw, uri)
                    JuliaWorkspaces.update_file_from_disc!(jw, path)
                else
                    JuliaWorkspaces.add_file_from_disc!(jw, path)
                end
                applied += 1
            catch err
                mcp_debug(state, "watcher", "Failed to refresh $path: $(sprint(showerror, err))")
            end
        end
        for path in deleted
            uri = JuliaWorkspaces.filepath2uri(path)
            try
                if JuliaWorkspaces.has_file(jw, uri)
                    JuliaWorkspaces.remove_file!(jw, uri)
                    applied += 1
                end
            catch err
                mcp_debug(state, "watcher", "Failed to remove $path: $(sprint(showerror, err))")
            end
        end
    end
    return applied
end

function notify_workspace_changed(state::AppState)
    notify_resource_list_changed(state)
    notify_resource_updated(state, "workspace://testitems")
    notify_resource_updated(state, "workspace://detection-errors")
    notify_resource_updated(state, "workspace://diagnostics")
end

"""
Apply a batch of changes and tell subscribers about it.
"""
function handle_file_changes!(state::AppState, created, modified, deleted)
    applied = apply_file_changes!(state, created, modified, deleted)
    applied == 0 && return 0

    mcp_debug(state, "watcher",
        "Workspace refreshed: $(length(created)) added, $(length(modified)) changed, $(length(deleted)) removed")
    notify_workspace_changed(state)
    return applied
end

function watch_loop(state::AppState, stop::Ref{Bool}, interval::Float64, debounce::Float64)
    while !stop[]
        sleep(interval)
        stop[] && break
        try
            current = scan_folders(state.folders)
            created, modified, deleted = diff_snapshots(state.watcher_snapshot, current)
            (isempty(created) && isempty(modified) && isempty(deleted)) && continue

            # Let a burst of writes settle, then re-scan so the batch is coherent.
            sleep(debounce)
            stop[] && break
            current = scan_folders(state.folders)
            created, modified, deleted = diff_snapshots(state.watcher_snapshot, current)
            state.watcher_snapshot = current

            handle_file_changes!(state, created, modified, deleted)
        catch err
            mcp_debug(state, "watcher", "Watch cycle failed: $(sprint(showerror, err))")
        end
    end
end

"""
Start watching `state.folders`. Any previously running watcher is stopped first.
"""
function start_watcher!(state::AppState; interval=WATCH_INTERVAL_DEFAULT, debounce=WATCH_DEBOUNCE_DEFAULT)
    stop_watcher!(state)
    isempty(state.folders) && return nothing

    state.watcher_snapshot = scan_folders(state.folders)
    stop = Ref(false)
    state.watcher_stop = stop
    state.watcher_task = @async watch_loop(state, stop, Float64(interval), Float64(debounce))
    mcp_debug(state, "watcher", "Watching $(length(state.folders)) folder(s) every $(interval)s")
    return state.watcher_task
end

function stop_watcher!(state::AppState)
    state.watcher_stop === nothing && return
    state.watcher_stop[] = true
    state.watcher_stop = nothing
    state.watcher_task = nothing
    return
end
