# bridge.jl — Map between JuliaWorkspaces and TestItemControllers types

function resolve_testitems(state::AppState; filter=nothing)
    jw = state.workspace
    jw === nothing && error("Workspace not configured. Call set_workspace_folders first.")

    items = TestItemControllers.TestItemDetail[]
    setups = TestItemControllers.TestSetupDetail[]
    item_package_info = Dict{String, NamedTuple{(:package_name, :package_uri, :project_uri, :env_content_hash), Tuple{String, Union{Nothing,String}, Union{Nothing,String}, Union{Nothing,String}}}}()

    lock(state.workspace_lock)
    try
    for (uri, file_info) in pairs(JuliaWorkspaces.get_test_items(jw))
        env = JuliaWorkspaces.get_test_env(jw, uri)
        textfile = JuliaWorkspaces.get_text_file(jw, uri)

        for item in file_info.testitems
            # Apply filter if provided
            if filter !== nothing && !passes_filter(item, env, uri, filter)
                continue
            end

            item_pos = JuliaWorkspaces.position_at(textfile.content, first(item.range))
            code_pos = JuliaWorkspaces.position_at(textfile.content, first(item.code_range))

            push!(items, TestItemControllers.TestItemDetail(
                item.id,
                string(item.uri),
                item.name,
                env.package_name === nothing ? "" : env.package_name,
                env.package_uri === nothing ? "" : string(env.package_uri),
                item.option_default_imports,
                string.(item.option_setup),
                item_pos.line,
                item_pos.column,
                textfile.content.content[item.code_range],
                code_pos.line,
                code_pos.column,
            ))
            item_package_info[item.id] = (
                package_name = env.package_name,
                package_uri = env.package_uri === nothing ? nothing : string(env.package_uri),
                project_uri = env.project_uri === nothing ? nothing : string(env.project_uri),
                env_content_hash = env.env_content_hash === nothing ? nothing : string(env.env_content_hash),
            )
        end

        for setup in file_info.testsetups
            env.package_uri === nothing && continue
            setup_pos = JuliaWorkspaces.position_at(textfile.content, first(setup.code_range))
            push!(setups, TestItemControllers.TestSetupDetail(
                string(env.package_uri),
                string(setup.name),
                string(setup.kind),
                string(uri),
                setup_pos.line,
                setup_pos.column,
                textfile.content.content[setup.code_range],
            ))
        end
    end
    finally
        unlock(state.workspace_lock)
    end

    return items, setups, item_package_info
end

function passes_filter(item, env, uri, filter::Dict)
    if haskey(filter, :tags) && !isempty(filter[:tags])
        item_tags = Set(string.(item.option_tags))
        if !any(t -> t in item_tags, filter[:tags])
            return false
        end
    end
    if haskey(filter, :name_pattern) && filter[:name_pattern] !== nothing
        if !occursin(Regex(filter[:name_pattern], "i"), item.name)
            return false
        end
    end
    if haskey(filter, :file_pattern) && filter[:file_pattern] !== nothing
        if !occursin(Regex(filter[:file_pattern], "i"), string(uri))
            return false
        end
    end
    if haskey(filter, :package) && filter[:package] !== nothing
        if env.package_name != filter[:package]
            return false
        end
    end
    if haskey(filter, :ids) && !isempty(filter[:ids])
        if !(item.id in filter[:ids])
            return false
        end
    end
    return true
end

"""
    shim_env_overrides()

Environment overrides for test processes that undo the Pkg app shim launching this
server. The shim pins `JULIA_LOAD_PATH`/`JULIA_DEPOT_PATH` to this app's own
environment, which a test process must not inherit: it replaces the default load
path, so `@` no longer resolves and the test process cannot load its own
environment. `nothing` tells TestItemControllers to drop the variable.
"""
shim_env_overrides() = Dict{String,Union{String,Nothing}}(
    "JULIA_LOAD_PATH" => nothing,
    "JULIA_PROJECT" => nothing,
    "JULIA_DEPOT_PATH" => nothing,
)

function build_test_environments(params::Dict{String,Any}, item_package_info::Dict)
    julia_cmd = get(params, "julia_cmd", "julia")::String
    julia_args = convert(Vector{String}, get(params, "julia_args", String[]))
    julia_num_threads = let v = get(params, "julia_num_threads", nothing)
        v isa String ? v : nothing
    end
    mode = get(params, "mode", "Normal")::String
    max_processes = get(params, "max_workers", min(Sys.CPU_THREADS, 8))::Int
    coverage_root_uris = let v = get(params, "coverage_root_uris", nothing)
        v === nothing ? nothing : convert(Vector{String}, v)
    end
    log_level = :Info

    # Collect unique packages
    unique_packages = Dict{String, NamedTuple}()
    for (_, pkg) in item_package_info
        key = something(pkg.package_uri, "")
        if !haskey(unique_packages, key)
            unique_packages[key] = pkg
        end
    end

    test_envs = TestItemControllers.TestEnvironment[]
    env_id_for_item = Dict{String, String}()
    for (pkg_key, pkg) in unique_packages
        env = TestItemControllers.TestEnvironment(
            string(UUIDs.uuid4()),
            julia_cmd,
            julia_args,
            julia_num_threads,
            shim_env_overrides(),
            mode,
            pkg.package_name,
            something(pkg.package_uri, ""),
            pkg.project_uri,
            pkg.env_content_hash,
        )
        push!(test_envs, env)
        for (item_id, item_pkg) in item_package_info
            if something(item_pkg.package_uri, "") == pkg_key
                env_id_for_item[item_id] = env.id
            end
        end
    end

    return test_envs, env_id_for_item, max_processes, coverage_root_uris, log_level
end

function collect_detection_errors(state::AppState)
    jw = state.workspace
    jw === nothing && return Any[]
    errors = Any[]
    with_workspace_lock(state) do
        for (uri, file_info) in pairs(JuliaWorkspaces.get_test_items(jw))
            textfile = JuliaWorkspaces.get_text_file(jw, uri)
            for e in file_info.testerrors
                start_pos = JuliaWorkspaces.position_at(textfile.content, first(e.range))
                stop_pos = JuliaWorkspaces.position_at(textfile.content, last(e.range))
                push!(errors, Dict{String,Any}(
                    "uri" => string(e.uri),
                    "id" => e.id,
                    "name" => e.name,
                    "message" => e.message,
                    "line" => start_pos.line,
                    "column" => start_pos.column,
                    "range" => Dict(
                        "start" => Dict("line" => start_pos.line, "column" => start_pos.column),
                        "stop" => Dict("line" => stop_pos.line, "column" => stop_pos.column),
                    ),
                ))
            end
        end
    end
    return errors
end

function collect_testitems_list(state::AppState; filter=nothing)
    jw = state.workspace
    jw === nothing && return Any[]
    result = Any[]
    with_workspace_lock(state) do
        for (uri, file_info) in pairs(JuliaWorkspaces.get_test_items(jw))
            env = JuliaWorkspaces.get_test_env(jw, uri)
            textfile = JuliaWorkspaces.get_text_file(jw, uri)
            for item in file_info.testitems
                if filter !== nothing && !passes_filter(item, env, uri, filter)
                    continue
                end
                item_pos = JuliaWorkspaces.position_at(textfile.content, first(item.range))
                push!(result, Dict{String,Any}(
                    "id" => item.id,
                    "name" => item.name,
                    "uri" => string(item.uri),
                    "package_name" => env.package_name,
                    "tags" => string.(item.option_tags),
                    "line" => item_pos.line,
                    "column" => item_pos.column,
                    "setup_names" => string.(item.option_setup),
                ))
            end
        end
    end
    return result
end
