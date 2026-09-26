# bridge.jl — Test item discovery and selection through TestItemRuns

"""
    discover(state; filter=nothing) -> TestItemRuns.Discovery

Discover the workspace's test items under the workspace lock (the Salsa runtime behind
`state.workspace` is not safe for concurrent access, and the file watcher mutates it) and
apply the tool-argument `filter` built by `build_filter`.
"""
function discover(state::AppState; filter=nothing)
    jw = state.workspace
    jw === nothing && error("Workspace not configured. Call julia_set_workspace_folders first.")
    d = with_workspace_lock(state) do
        TIR.discover_testitems(jw)
    end
    filter === nothing && return d
    return TIR.select(d; predicate = item -> passes_filter(item, filter))
end

function passes_filter(item::TIR.TestItem, filter::Dict)
    if haskey(filter, :tags) && !isempty(filter[:tags])
        item_tags = Set(string.(item.tags))
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
        if !occursin(Regex(filter[:file_pattern], "i"), item.uri)
            return false
        end
    end
    if haskey(filter, :package) && filter[:package] !== nothing
        if item.package_name != filter[:package]
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
    run_profile(params) -> TestItemRuns.RunProfile

The one profile a `julia_run_testitems` call runs under. TestItemRuns clears the
`JULIA_LOAD_PATH`/`JULIA_PROJECT`/`JULIA_DEPOT_PATH` the Pkg app shim launching this
server pins to its own environment, so test processes resolve their own.
"""
function run_profile(params::Dict{String,Any})
    mode = get(params, "mode", "Normal")::String
    return TIR.RunProfile("Default"; coverage = mode == "Coverage")
end

"""
    run_options(params) -> NamedTuple

The `run_async!` keyword arguments a `julia_run_testitems` call selects.
"""
function run_options(params::Dict{String,Any})
    julia_num_threads = let v = get(params, "julia_num_threads", nothing)
        v isa String ? v : nothing
    end
    return (;
        julia_cmd = get(params, "julia_cmd", "julia")::String,
        julia_args = convert(Vector{String}, get(params, "julia_args", String[])),
        julia_num_threads = julia_num_threads,
        max_workers = Int(get(() -> TIR.default_max_workers(), params, "max_workers")::Integer),
        memory_threshold = memory_threshold_of(params),
    )
end

"""
    memory_threshold_of(params) -> Union{Nothing,Float64}

The validated `memory_threshold`, or `nothing` when the caller did not ask for one.

Nothing downstream checks the range and the test process swallows a bad value into "never
recycle", so an unusable fraction has to be rejected here or it passes for a working one.
"""
function memory_threshold_of(params::Dict{String,Any})
    v = get(params, "memory_threshold", nothing)
    isnothing(v) && return nothing
    # `Bool <: Real`, so exclude it: JSON `true` is not a fraction.
    (v isa Real && !(v isa Bool) && 0 < v <= 1) ||
        throw(ArgumentError("memory_threshold must be a fraction greater than 0 and at most 1, got $(repr(v))."))
    return Float64(v)
end

function definition_error_dict(e::TIR.DefinitionError)
    return Dict{String,Any}(
        "uri" => e.uri,
        "id" => e.id,
        "name" => e.name,
        "message" => e.message,
        "line" => e.line,
        "column" => e.column,
        "range" => Dict(
            "start" => Dict("line" => e.line, "column" => e.column),
            "stop" => Dict("line" => e.end_line, "column" => e.end_column),
        ),
    )
end

function collect_detection_errors(state::AppState)
    state.workspace === nothing && return Any[]
    return Any[definition_error_dict(e) for e in discover(state).definition_errors]
end

function testitem_list_dict(item::TIR.TestItem)
    return Dict{String,Any}(
        "id" => item.id,
        "name" => item.name,
        "uri" => item.uri,
        "package_name" => item.package_name,
        "tags" => string.(item.tags),
        "line" => item.line,
        "column" => item.column,
        "setup_names" => copy(item.setups),
    )
end

function collect_testitems_list(state::AppState; filter=nothing)
    state.workspace === nothing && return Any[]
    return Any[testitem_list_dict(item) for item in discover(state; filter=filter)]
end

"""
    shim_env_overrides()

Environment overrides for child processes that undo the Pkg app shim launching this
server. The shim pins `JULIA_LOAD_PATH`/`JULIA_DEPOT_PATH` to this app's own
environment, which a child must not inherit: it replaces the default load path, so
`@` no longer resolves and the child cannot load its own environment. `nothing` means
"drop the variable". (Test processes get this from TestItemRuns automatically; Julia
sessions still need it explicitly.)
"""
shim_env_overrides() = Dict{String,Union{String,Nothing}}(
    "JULIA_LOAD_PATH" => nothing,
    "JULIA_PROJECT" => nothing,
    "JULIA_DEPOT_PATH" => nothing,
)
