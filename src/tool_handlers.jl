# tool_handlers.jl — MCP tool call implementations

"""
Check `arguments` against the `required` list in the tool's declared input
schema. Returns an error result for the client, or `nothing` when valid.
"""
function validate_tool_arguments(tool_name::String, arguments::Dict{String,Any})
    idx = findfirst(d -> d["name"] == tool_name, tool_definitions())
    idx === nothing && return nothing

    schema = tool_definitions()[idx]["inputSchema"]
    missing_args = [
        name for name in get(schema, "required", String[])
        if !haskey(arguments, name) || arguments[name] === nothing
    ]
    isempty(missing_args) && return nothing

    return tool_result_error("Missing required argument(s) for $tool_name: $(join(missing_args, ", "))")
end

function handle_tool_call(state::AppState, tool_name::String, arguments::Dict{String,Any})
    invalid = validate_tool_arguments(tool_name, arguments)
    invalid === nothing || return invalid

    if tool_name == "set_workspace_folders"
        return tool_set_workspace_folders(state, arguments)
    elseif tool_name == "update_file"
        return tool_update_file(state, arguments)
    elseif tool_name == "get_diagnostics"
        return tool_get_diagnostics(state, arguments)
    elseif tool_name == "format_file"
        return tool_format_file(state, arguments)
    elseif tool_name == "list_testitems"
        return tool_list_testitems(state, arguments)
    elseif tool_name == "run_testitems"
        return tool_run_testitems(state, arguments)
    elseif tool_name == "rerun_failed"
        return tool_rerun_failed(state, arguments)
    elseif tool_name == "cancel_testrun"
        return tool_cancel_testrun(state, arguments)
    elseif tool_name == "get_testrun_results"
        return tool_get_testrun_results(state, arguments)
    elseif tool_name == "get_testitem_detail"
        return tool_get_testitem_detail(state, arguments)
    elseif tool_name == "list_testruns"
        return tool_list_testruns(state, arguments)
    elseif tool_name == "list_test_processes"
        return tool_list_test_processes(state, arguments)
    elseif tool_name == "terminate_test_process"
        return tool_terminate_test_process(state, arguments)
    elseif tool_name == "get_coverage_results"
        return tool_get_coverage_results(state, arguments)
    else
        error("Unknown tool: $tool_name")
    end
end

# --- set_workspace_folders ---

function tool_set_workspace_folders(state::AppState, args::Dict{String,Any})
    folders = convert(Vector{String}, args["folders"])
    mcp_info(state, "tools", "Setting workspace folders: $folders")

    with_workspace_lock(state) do
        state.workspace = JuliaWorkspaces.workspace_from_folders(folders)
    end
    state.folders = folders

    # Initialize controller on first workspace setup
    init_controller!(state)

    if something(get(args, "watch", nothing), true)
        start_watcher!(
            state;
            interval = something(get(args, "watch_interval", nothing), WATCH_INTERVAL_DEFAULT),
        )
    else
        stop_watcher!(state)
    end

    items = collect_testitems_list(state)
    errors = collect_detection_errors(state)

    notify_resource_list_changed(state)
    notify_resource_updated(state, "workspace://testitems")
    notify_resource_updated(state, "workspace://detection-errors")
    notify_resource_updated(state, "workspace://diagnostics")

    text = "Workspace configured with $(length(folders)) folder(s). " *
           "Detected $(length(items)) test item(s)"
    if !isempty(errors)
        text *= " and $(length(errors)) detection error(s)"
    end
    text *= "."

    return tool_result_text(text)
end

# --- update_file ---

function tool_update_file(state::AppState, args::Dict{String,Any})
    path = args["path"]::String
    jw = state.workspace
    jw === nothing && return tool_result_error("Workspace not configured. Call set_workspace_folders first.")

    with_workspace_lock(state) do
        JuliaWorkspaces.update_file_from_disc!(jw, path)
    end
    # Keep the watcher from re-reporting a change we just applied.
    haskey(state.watcher_snapshot, path) && (state.watcher_snapshot[path] = mtime(path))

    notify_resource_updated(state, "workspace://testitems")
    notify_resource_updated(state, "workspace://detection-errors")
    notify_resource_updated(state, "workspace://diagnostics")

    return tool_result_text("File updated: $path")
end

# --- get_diagnostics ---

function tool_get_diagnostics(state::AppState, args::Dict{String,Any})
    state.workspace === nothing && return tool_result_error("Workspace not configured. Call set_workspace_folders first.")

    uri = haskey(args, "path") && args["path"] !== nothing ? resolve_uri(args["path"]::String) : nothing
    if uri !== nothing && !with_workspace_lock(() -> JuliaWorkspaces.has_file(state.workspace, uri), state)
        return tool_result_error("File is not part of the workspace: $(args["path"])")
    end

    result = try
        collect_diagnostics(
            state;
            uri = uri,
            severity = get(args, "severity", nothing),
            source = get(args, "source", nothing),
            max_results = something(get(args, "max_results", nothing), DIAGNOSTIC_LIMIT_DEFAULT),
            wait_for_ready = something(get(args, "wait_for_ready", nothing), false),
        )
    catch err
        return tool_result_error("Failed to collect diagnostics: $(sprint(showerror, err))")
    end

    return tool_result_json(result)
end

# --- format_file ---

function tool_format_file(state::AppState, args::Dict{String,Any})
    jw = state.workspace
    jw === nothing && return tool_result_error("Workspace not configured. Call set_workspace_folders first.")

    path = args["path"]::String
    uri = resolve_uri(path)
    with_workspace_lock(() -> JuliaWorkspaces.has_file(jw, uri), state) ||
        return tool_result_error("File is not part of the workspace: $path")

    start_line = get(args, "start_line", nothing)
    stop_line = get(args, "stop_line", nothing)
    if (start_line === nothing) != (stop_line === nothing)
        return tool_result_error("start_line and stop_line must be supplied together.")
    end

    edit = try
        with_workspace_lock(state) do
            start_line === nothing ?
                JuliaWorkspaces.get_format_edits(jw, uri) :
                JuliaWorkspaces.get_format_edits(jw, uri, start_line, stop_line)
        end
    catch err
        return tool_result_error("Formatting failed: $(sprint(showerror, err))")
    end

    result = file_edit_to_dict(edit)
    result["already_formatted"] = isempty(edit.edits)

    if something(get(args, "apply", nothing), false) && !isempty(edit.edits)
        file_path = JuliaWorkspaces.uri2filepath(uri)
        with_workspace_lock(state) do
            content = JuliaWorkspaces.get_text_file(jw, uri).content
            write(file_path, apply_text_edits(content, edit.edits))
            JuliaWorkspaces.update_file_from_disc!(jw, file_path)
        end
        # The watcher must not re-report the write we just made.
        haskey(state.watcher_snapshot, file_path) && (state.watcher_snapshot[file_path] = mtime(file_path))

        notify_resource_updated(state, "workspace://testitems")
        notify_resource_updated(state, "workspace://detection-errors")
        notify_resource_updated(state, "workspace://diagnostics")

        result["applied"] = true
    else
        result["applied"] = false
    end

    return tool_result_json(result)
end

# --- list_testitems ---

function tool_list_testitems(state::AppState, args::Dict{String,Any})
    state.workspace === nothing && return tool_result_error("Workspace not configured. Call set_workspace_folders first.")

    filter = build_filter(args)
    items = collect_testitems_list(state; filter=filter)

    return tool_result_json(items)
end

# --- run_testitems ---

function tool_run_testitems(state::AppState, args::Dict{String,Any})
    state.workspace === nothing && return tool_result_error("Workspace not configured. Call set_workspace_folders first.")

    init_controller!(state)

    filter = build_filter(args)
    items, setups, item_package_info = resolve_testitems(state; filter=filter)

    if isempty(items)
        return tool_result_text("No test items matched the given filter.")
    end

    test_envs, env_id_for_item, max_processes, coverage_root_uris, log_level = build_test_environments(args, item_package_info)
    testrun_id = test_envs[1].id

    # Register test environments for on_process_created callback
    lock(state.lock) do
        for env in test_envs
            state.test_env_by_id[env.id] = env
        end
    end

    # Build work units mapping each item to its matching test environment
    timeout = filter !== nothing ? get(filter, :timeout, nothing) : nothing
    work_units = [
        TestItemControllers.TestRunItem(item.id, env_id_for_item[item.id], timeout, log_level)
        for item in items
    ]

    # Create cancellation source
    cts = CancellationTokens.CancellationTokenSource()
    lock(state.lock) do
        state.cancellation_sources[testrun_id] = cts
    end

    # Register test run record with pending items
    run_record = TestRunRecord(
        testrun_id,
        :running,
        args,
        Dict{String,TestItemResult}(
            item.id => TestItemResult(item.id, item.label, item.uri, :pending, nothing, Any[], String[])
            for item in items
        ),
        nothing,
        Dates.now(),
        nothing,
    )
    lock(state.lock) do
        state.runs[testrun_id] = run_record
    end
    notify_resource_list_changed(state)

    mcp_info(state, "tools", "Starting test run $testrun_id with $(length(items)) item(s)")

    coverage_results = try
        TestItemControllers.execute_testrun(
            state.controller,
            testrun_id,
            test_envs,
            items,
            work_units,
            setups,
            max_processes,
            CancellationTokens.get_token(cts);
            coverage_root_uris=coverage_root_uris,
        )
    catch e
        lock(state.lock) do
            run_record.status = :errored
            run_record.completed_at = Dates.now()
        end
        mcp_error(state, "tools", "Test run $testrun_id failed: $e")
        return tool_result_error("Test run failed: $e")
    finally
        lock(state.lock) do
            delete!(state.cancellation_sources, testrun_id)
        end
    end

    lock(state.lock) do
        run_record.status = :completed
        run_record.completed_at = Dates.now()
        if coverage_results !== nothing
            run_record.coverage = coverage_to_dicts(coverage_results)
        end
    end

    summary = lock(state.lock) do
        run_summary(run_record)
    end

    notify_resource_updated(state, "testrun://$testrun_id/summary")
    notify_resource_updated(state, "testrun://$testrun_id/failures")

    mcp_info(state, "tools", "Test run $testrun_id completed: $(summary["passed"]) passed, $(summary["failed"]) failed, $(summary["errored"]) errored")

    # Return full results inline so the LLM has everything it needs
    failures = lock(state.lock) do
        [
            Dict{String,Any}(
                "testitem_id" => item.testitem_id,
                "label" => item.label,
                "uri" => item.uri,
                "status" => string(item.status),
                "duration" => item.duration,
                "messages" => item.messages,
            ) for item in values(run_record.items) if item.status in (:failed, :errored)
        ]
    end

    result = Dict{String,Any}(
        "summary" => summary,
        "failures" => failures,
    )

    return tool_result_json(result)
end

# --- rerun_failed ---

function tool_rerun_failed(state::AppState, args::Dict{String,Any})
    testrun_id = args["testrun_id"]::String

    prev_run = lock(state.lock) do
        get(state.runs, testrun_id, nothing)
    end
    prev_run === nothing && return tool_result_error("Test run not found: $testrun_id")

    failed_ids = lock(state.lock) do
        [item.testitem_id for item in values(prev_run.items) if item.status in (:failed, :errored)]
    end
    isempty(failed_ids) && return tool_result_text("No failed or errored items in run $testrun_id.")

    # Build new run args with the failed IDs
    new_args = copy(args)
    new_args["items"] = failed_ids
    # Preserve original profile params
    for key in ("julia_cmd", "julia_args", "max_workers", "timeout", "mode")
        if haskey(prev_run.profile_params, key) && !haskey(new_args, key)
            new_args[key] = prev_run.profile_params[key]
        end
    end

    return tool_run_testitems(state, new_args)
end

# --- cancel_testrun ---

function tool_cancel_testrun(state::AppState, args::Dict{String,Any})
    testrun_id = args["testrun_id"]::String

    cts = lock(state.lock) do
        get(state.cancellation_sources, testrun_id, nothing)
    end
    cts === nothing && return tool_result_error("No active test run with ID: $testrun_id")

    CancellationTokens.cancel(cts)

    lock(state.lock) do
        run = get(state.runs, testrun_id, nothing)
        if run !== nothing
            run.status = :cancelled
            run.completed_at = Dates.now()
        end
    end

    mcp_info(state, "tools", "Cancelled test run $testrun_id")
    return tool_result_text("Test run $testrun_id cancelled.")
end

# --- get_testrun_results ---

function tool_get_testrun_results(state::AppState, args::Dict{String,Any})
    testrun_id = args["testrun_id"]::String
    include_output = get(args, "include_output", false)::Bool
    include_passing = get(args, "include_passing", false)::Bool

    run = lock(state.lock) do
        get(state.runs, testrun_id, nothing)
    end
    run === nothing && return tool_result_error("Test run not found: $testrun_id")

    summary = lock(state.lock) do
        run_summary(run)
    end

    items_out = lock(state.lock) do
        result = Dict{String,Any}[]
        for item in values(run.items)
            if !include_passing && item.status == :passed
                continue
            end
            d = Dict{String,Any}(
                "testitem_id" => item.testitem_id,
                "label" => item.label,
                "uri" => item.uri,
                "status" => string(item.status),
                "duration" => item.duration,
                "messages" => item.messages,
            )
            if include_output
                d["output"] = join(item.output, "")
            end
            push!(result, d)
        end
        result
    end

    return tool_result_json(Dict{String,Any}("summary" => summary, "items" => items_out))
end

# --- get_testitem_detail ---

function tool_get_testitem_detail(state::AppState, args::Dict{String,Any})
    testrun_id = args["testrun_id"]::String
    testitem_id = args["testitem_id"]::String

    item = lock(state.lock) do
        run = get(state.runs, testrun_id, nothing)
        run === nothing && return nothing
        get(run.items, testitem_id, nothing)
    end
    item === nothing && return tool_result_error("Test item $testitem_id not found in run $testrun_id")

    d = lock(state.lock) do
        Dict{String,Any}(
            "testitem_id" => item.testitem_id,
            "label" => item.label,
            "uri" => item.uri,
            "status" => string(item.status),
            "duration" => item.duration,
            "messages" => item.messages,
            "output" => join(item.output, ""),
        )
    end

    return tool_result_json(d)
end

# --- list_testruns ---

function tool_list_testruns(state::AppState, args::Dict{String,Any})
    runs = lock(state.lock) do
        [run_summary(run) for run in values(state.runs)]
    end
    return tool_result_json(runs)
end

# --- list_test_processes ---

function tool_list_test_processes(state::AppState, args::Dict{String,Any})
    procs = lock(state.lock) do
        [
            Dict{String,Any}(
                "id" => p.id,
                "package_name" => p.package_name,
                "status" => p.status,
                "package_uri" => p.package_uri,
                "project_uri" => p.project_uri,
            ) for p in values(state.processes)
        ]
    end
    return tool_result_json(procs)
end

# --- terminate_test_process ---

function tool_terminate_test_process(state::AppState, args::Dict{String,Any})
    process_id = args["process_id"]::String
    state.controller === nothing && return tool_result_error("Controller not initialized.")
    TestItemControllers.terminate_test_process(state.controller, process_id)
    return tool_result_text("Process $process_id termination requested.")
end

# --- get_coverage_results ---

function tool_get_coverage_results(state::AppState, args::Dict{String,Any})
    testrun_id = args["testrun_id"]::String

    coverage = lock(state.lock) do
        run = get(state.runs, testrun_id, nothing)
        run === nothing && return :not_found
        run.coverage === nothing && return :no_coverage
        run.coverage
    end
    coverage === :not_found && return tool_result_error("Test run not found: $testrun_id")
    coverage === :no_coverage && return tool_result_error("No coverage data. Was the run executed with mode=\"Coverage\"?")

    return tool_result_json(coverage)
end

# --- Helpers ---

function build_filter(args::Dict{String,Any})
    filter = Dict{Symbol,Any}()
    if haskey(args, "items") && args["items"] !== nothing
        filter[:ids] = Set(convert(Vector{String}, args["items"]))
    end
    if haskey(args, "tags") && args["tags"] !== nothing
        filter[:tags] = convert(Vector{String}, args["tags"])
    end
    if haskey(args, "name_pattern") && args["name_pattern"] !== nothing
        filter[:name_pattern] = args["name_pattern"]::String
    end
    if haskey(args, "file_pattern") && args["file_pattern"] !== nothing
        filter[:file_pattern] = args["file_pattern"]::String
    end
    if haskey(args, "package") && args["package"] !== nothing
        filter[:package] = args["package"]::String
    end
    if haskey(args, "timeout") && args["timeout"] !== nothing
        filter[:timeout] = args["timeout"]
    end
    return isempty(filter) ? nothing : filter
end

function tool_result_text(text::String)
    return Dict{String,Any}(
        "content" => [Dict{String,Any}("type" => "text", "text" => text)],
    )
end

function tool_result_json(data)
    return Dict{String,Any}(
        "content" => [Dict{String,Any}("type" => "text", "text" => JSON.json(data))],
    )
end

function tool_result_error(message::String)
    return Dict{String,Any}(
        "content" => [Dict{String,Any}("type" => "text", "text" => message)],
        "isError" => true,
    )
end

function coverage_to_dicts(coverage_results)
    dicts = Any[]
    for fc in coverage_results
        # `coverage` has one entry per source line; `nothing` means not instrumentable.
        push!(dicts, Dict{String,Any}(
            "uri" => fc.uri,
            "lines" => [
                Dict{String,Any}("line" => i, "count" => c)
                for (i, c) in enumerate(fc.coverage) if c !== nothing
            ],
            "covered_lines" => count(c -> c !== nothing && c > 0, fc.coverage),
            "coverable_lines" => count(!isnothing, fc.coverage),
        ))
    end
    return dicts
end
