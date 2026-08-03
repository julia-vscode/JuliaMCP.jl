# diagnostics.jl — Expose JuliaWorkspaces diagnostics and formatting over MCP

const DIAGNOSTIC_LIMIT_DEFAULT = 200

"""
Resolve a client-supplied file path or URI string to a `URI`.
"""
function resolve_uri(value::AbstractString)
    return occursin(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", value) ?
        JuliaWorkspaces.URIs2.URI(value) :
        JuliaWorkspaces.filepath2uri(abspath(value))
end

"""
Slice `s` between the 1-based byte offsets `from` (inclusive) and `to`
(exclusive), clamping to the string and snapping to character boundaries.
"""
function safe_byte_slice(s::AbstractString, from::Int, to::Int)
    ncu = ncodeunits(s)
    from = clamp(from, 1, ncu + 1)
    to = clamp(to, from, ncu + 1)
    to <= from && return ""
    lo = thisind(s, from)
    hi = prevind(s, thisind(s, to))
    return lo <= hi ? s[lo:hi] : ""
end

"""
Convert a `JuliaWorkspaces.Diagnostic` into a JSON-friendly dictionary.

Diagnostic ranges are 1-based byte offsets and end-exclusive; they are converted
to 1-based line/column positions here.
"""
function diagnostic_to_dict(jw, diag, uri)
    result = Dict{String,Any}(
        "uri" => string(uri),
        "severity" => string(diag.severity),
        "message" => diag.message,
        "source" => diag.source,
    )
    isempty(diag.tags) || (result["tags"] = string.(diag.tags))

    text_file = try
        JuliaWorkspaces.get_text_file(jw, uri)
    catch
        nothing
    end
    text_file === nothing && return result

    content = text_file.content
    source = content.content
    ncu = ncodeunits(source)
    start_offset = clamp(first(diag.range), 1, ncu + 1)
    stop_offset = clamp(last(diag.range), start_offset, ncu + 1)

    start_pos = JuliaWorkspaces.position_at(content, start_offset)
    stop_pos = JuliaWorkspaces.position_at(content, stop_offset)
    result["range"] = Dict{String,Any}(
        "start" => Dict{String,Any}("line" => start_pos.line, "column" => start_pos.column),
        "end" => Dict{String,Any}("line" => stop_pos.line, "column" => stop_pos.column),
    )

    preview = safe_byte_slice(source, start_offset, stop_offset)
    isempty(preview) || (result["preview"] = preview)

    return result
end

"""
Collect diagnostics from the workspace, optionally restricted to a single file
and filtered by severity and source.
"""
function collect_diagnostics(
    state::AppState;
    uri=nothing,
    severity=nothing,
    source=nothing,
    max_results::Int=DIAGNOSTIC_LIMIT_DEFAULT,
    wait_for_ready::Bool=false,
)
    jw = state.workspace
    jw === nothing && error("Workspace not configured. Call set_workspace_folders first.")

    entries = Tuple{Any,Any}[]
    with_workspace_lock(state) do
        if uri !== nothing
            for d in JuliaWorkspaces.get_diagnostic(jw, uri)
                push!(entries, (something(d.uri, uri), d))
            end
        else
            # `get_diagnostics` yields `uri => Vector{Diagnostic}` entries.
            all_diags = wait_for_ready ?
                JuliaWorkspaces.get_diagnostics_blocking(jw) :
                JuliaWorkspaces.get_diagnostics(jw)
            for (file_uri, diags) in all_diags
                for d in diags
                    push!(entries, (something(d.uri, file_uri), d))
                end
            end
        end
    end

    if severity !== nothing
        wanted = Set(Symbol.(severity))
        filter!(e -> e[2].severity in wanted, entries)
    end
    if source !== nothing
        wanted = Set(String.(source))
        filter!(e -> e[2].source in wanted, entries)
    end

    total = length(entries)
    truncated = total > max_results
    truncated && (entries = entries[1:max_results])

    by_file = Dict{String,Vector{Any}}()
    with_workspace_lock(state) do
        for (file_uri, d) in entries
            push!(get!(by_file, string(file_uri), Any[]), diagnostic_to_dict(jw, d, file_uri))
        end
    end

    severities = Dict{String,Int}()
    for (_, d) in entries
        key = string(d.severity)
        severities[key] = get(severities, key, 0) + 1
    end

    return Dict{String,Any}(
        "total" => total,
        "reported" => length(entries),
        "truncated" => truncated,
        "by_severity" => severities,
        "files" => [
            Dict{String,Any}("uri" => file_uri, "diagnostics" => diags)
            for (file_uri, diags) in sort(collect(by_file), by = first)
        ],
    )
end

"""
Convert a `WorkspaceFileEdit` into a JSON-friendly dictionary.
"""
function file_edit_to_dict(edit)
    return Dict{String,Any}(
        "uri" => string(edit.uri),
        "edits" => [
            Dict{String,Any}(
                "start" => Dict{String,Any}("line" => e.start.line, "column" => e.start.column),
                "stop" => Dict{String,Any}("line" => e.stop.line, "column" => e.stop.column),
                "new_text" => e.new_text,
            ) for e in edit.edits
        ],
    )
end

"""
Apply `edits` (in `WorkspaceFileEdit` form) to the text of `content` and return
the new text. Edits are applied back-to-front so earlier offsets stay valid.
"""
function apply_text_edits(content, edits)
    source = content.content
    ordered = sort(collect(edits), by = e -> (e.start.line, e.start.column), rev = true)
    for e in ordered
        from = offset_of(content, e.start)
        to = offset_of(content, e.stop)
        prefix = safe_byte_slice(source, 1, from)
        suffix = safe_byte_slice(source, to, ncodeunits(source) + 1)
        source = string(prefix, e.new_text, suffix)
    end
    return source
end

"""
Convert a 1-based (line, column) `Position` into a 1-based byte offset.
"""
function offset_of(content, pos)
    line_indices = content.line_indices
    line = clamp(pos.line, 1, length(line_indices))
    return line_indices[line] + pos.column - 1
end
