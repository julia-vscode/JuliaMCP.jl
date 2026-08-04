# mcp_resources.jl — MCP resource and resource template definitions

function resource_templates()
    return [
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/summary",
            "name" => "Test Run Summary",
            "description" => "Summary of a test run including pass/fail/error counts and timing.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/failures",
            "name" => "Test Run Failures",
            "description" => "Failed and errored test items with messages and stack traces.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/items/{testitem_id}/output",
            "name" => "Test Item Output",
            "description" => "Captured stdout/stderr for a specific test item.",
            "mimeType" => "text/plain",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/coverage",
            "name" => "Test Run Coverage",
            "description" => "Line-level code coverage from a Coverage-mode test run.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testprocess://{process_id}/output",
            "name" => "Test Process Output",
            "description" => "Raw output of a test worker process. This is where precompilation " *
                             "errors and process crashes surface, which no per-item detail can show.",
            "mimeType" => "text/plain",
        ),
    ]
end

function dynamic_resources(state::AppState)
    res = Dict{String,Any}[]
    lock(state.lock) do
        for (id, run) in state.runs
            push!(res, Dict{String,Any}(
                "uri" => "testrun://$id/summary",
                "name" => "Run $id summary ($(run.status))",
                "mimeType" => "application/json",
            ))
        end
        for (id, p) in state.processes
            push!(res, Dict{String,Any}(
                "uri" => "testprocess://$id/output",
                "name" => "Process $id output ($(p.package_name), $(p.status))",
                "mimeType" => "text/plain",
            ))
        end
    end
    push!(res, Dict{String,Any}(
        "uri" => "workspace://testitems",
        "name" => "Detected Test Items",
        "description" => "All test items detected in the current workspace.",
        "mimeType" => "application/json",
    ))
    push!(res, Dict{String,Any}(
        "uri" => "workspace://detection-errors",
        "name" => "Detection Errors",
        "description" => "Errors encountered during test item detection.",
        "mimeType" => "application/json",
    ))
    push!(res, Dict{String,Any}(
        "uri" => "workspace://diagnostics",
        "name" => "Workspace Diagnostics",
        "description" => "Syntax errors and lint warnings across the current workspace.",
        "mimeType" => "application/json",
    ))
    return res
end

function handle_resources_list(state::AppState, params)
    return Dict{String,Any}("resources" => dynamic_resources(state))
end

function handle_resource_templates_list(state::AppState, params)
    return Dict{String,Any}("resourceTemplates" => resource_templates())
end

function handle_resources_read(state::AppState, params::Dict)
    uri = params["uri"]::String
    contents = read_resource(state, uri)
    return Dict{String,Any}("contents" => contents)
end

function read_resource(state::AppState, uri::String)
    # workspace://testitems
    if uri == "workspace://testitems"
        items = collect_testitems_list(state)
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(items))]
    end

    # workspace://detection-errors
    if uri == "workspace://detection-errors"
        errors = collect_detection_errors(state)
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(errors))]
    end

    # workspace://diagnostics
    if uri == "workspace://diagnostics"
        diagnostics = collect_diagnostics(state)
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(diagnostics))]
    end

    # testrun://{id}/summary
    m = match(r"^testrun://([^/]+)/summary$", uri)
    if m !== nothing
        run_id = m[1]
        run = lock(state.lock) do
            get(state.runs, run_id, nothing)
        end
        run === nothing && error("Test run not found: $run_id")
        summary = lock(state.lock) do
            run_summary(run)
        end
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(summary))]
    end

    # testrun://{id}/failures
    m = match(r"^testrun://([^/]+)/failures$", uri)
    if m !== nothing
        run_id = m[1]
        run = lock(state.lock) do
            get(state.runs, run_id, nothing)
        end
        run === nothing && error("Test run not found: $run_id")
        failures = lock(state.lock) do
            [
                Dict{String,Any}(
                    "testitem_id" => item.testitem_id,
                    "label" => item.label,
                    "uri" => item.uri,
                    "status" => string(item.status),
                    "duration" => item.duration,
                    "messages" => item.messages,
                ) for item in values(run.items) if item.status in (:failed, :errored)
            ]
        end
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(failures))]
    end

    # testrun://{id}/items/{item_id}/output
    m = match(r"^testrun://([^/]+)/items/([^/]+)/output$", uri)
    if m !== nothing
        run_id, item_id = m[1], m[2]
        output = lock(state.lock) do
            run = get(state.runs, run_id, nothing)
            run === nothing && return nothing
            item = get(run.items, item_id, nothing)
            item === nothing && return nothing
            join(item.output, "")
        end
        output === nothing && error("Test item not found: $item_id in run $run_id")
        return [Dict{String,Any}("uri" => uri, "mimeType" => "text/plain", "text" => output)]
    end

    # testrun://{id}/coverage
    m = match(r"^testrun://([^/]+)/coverage$", uri)
    if m !== nothing
        run_id = m[1]
        coverage = lock(state.lock) do
            run = get(state.runs, run_id, nothing)
            run === nothing && return nothing
            run.coverage
        end
        coverage === nothing && error("No coverage data for run: $run_id")
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(coverage))]
    end

    # testprocess://{id}/output
    m = match(r"^testprocess://([^/]+)/output$", uri)
    if m !== nothing
        process_id = m[1]
        output = lock(state.lock) do
            buf = get(state.process_outputs, process_id, nothing)
            buf === nothing ? nothing : join(buf, "")
        end
        output === nothing && error("Test process not found: $process_id")
        return [Dict{String,Any}("uri" => uri, "mimeType" => "text/plain", "text" => output)]
    end

    error("Unknown resource URI: $uri")
end

function handle_resources_subscribe(state::AppState, params::Dict)
    uri = params["uri"]::String
    lock(state.lock) do
        push!(state.subscriptions, uri)
    end
    return Dict{String,Any}()
end

function handle_resources_unsubscribe(state::AppState, params::Dict)
    uri = params["uri"]::String
    lock(state.lock) do
        delete!(state.subscriptions, uri)
    end
    return Dict{String,Any}()
end
