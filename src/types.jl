# types.jl — Shared data types for test run tracking

const MCP_PROTOCOL_VERSION = "2025-03-26"

mutable struct TestItemResult
    testitem_id::String
    label::String
    uri::String
    status::Symbol  # :pending, :running, :passed, :failed, :errored, :skipped
    duration::Union{Nothing,Float64}
    messages::Vector{Any}  # TestMessage-like dicts
    output::Vector{String}
end

mutable struct TestRunRecord
    const id::String
    status::Symbol  # :running, :completed, :cancelled
    const profile_params::Dict{String,Any}
    const items::Dict{String,TestItemResult}  # testitem_id → result
    coverage::Union{Nothing,Vector{Any}}      # FileCoverage-like dicts
    const started_at::Dates.DateTime
    completed_at::Union{Nothing,Dates.DateTime}
    # --- MCP progress reporting, all guarded by `AppState.lock` ---
    progress_token::Union{Nothing,String,Int}
    progress_value::Float64  # last value actually sent; -1 means nothing sent yet
    progress_frac::Float64   # sub-item heartbeat offset, in [0, 0.95)
    progress_done::Int
    progress_note::String    # startup/status text shown while no item has finished
    heartbeat_stop::Union{Nothing,Ref{Bool}}
end

function TestRunRecord(id, status, profile_params, items, coverage, started_at, completed_at)
    return TestRunRecord(
        id, status, profile_params, items, coverage, started_at, completed_at,
        nothing, -1.0, 0.0, 0, "", nothing,
    )
end

mutable struct ProcessInfo
    id::String
    package_name::String
    status::String
    package_uri::String
    project_uri::String
end

"""
A Julia session managed by JuliaSessionsControllers, plus the output the app has seen for
it. `request_outputs` is keyed by the request id the caller supplied to `JSC.evaluate`.
"""
mutable struct SessionRecord
    const id::String
    const env::JSC.SessionEnvironment
    status::String
    const created_at::Dates.DateTime
    last_used_at::Dates.DateTime
    const output::Vector{String}
    const request_outputs::Dict{String,Vector{String}}
    alive::Bool
    exit_message::Union{Nothing,String}
end

function SessionRecord(id::AbstractString, env::JSC.SessionEnvironment)
    now = Dates.now()
    return SessionRecord(
        String(id), env, "Created", now, now,
        String[], Dict{String,Vector{String}}(), true, nothing,
    )
end

function run_summary(run::TestRunRecord)
    total = length(run.items)
    passed = count(v -> v.status == :passed, values(run.items))
    failed = count(v -> v.status == :failed, values(run.items))
    errored = count(v -> v.status == :errored, values(run.items))
    skipped = count(v -> v.status == :skipped, values(run.items))
    running = count(v -> v.status == :running, values(run.items))
    pending = count(v -> v.status == :pending, values(run.items))
    total_duration = sum((v.duration for v in values(run.items) if v.duration !== nothing), init=0.0)
    return Dict{String,Any}(
        "total" => total,
        "passed" => passed,
        "failed" => failed,
        "errored" => errored,
        "skipped" => skipped,
        "running" => running,
        "pending" => pending,
        "duration" => total_duration,
        "status" => string(run.status),
        "testrun_id" => run.id,
        "started_at" => string(run.started_at),
        "completed_at" => run.completed_at === nothing ? nothing : string(run.completed_at),
    )
end

"""
Compact, bounded view of a test item — no messages, no captured output. Detail lives
behind the `get_testitem_detail` tool so run results stay small.
"""
function testitem_status_dict(item::TestItemResult)
    return Dict{String,Any}(
        "testitem_id" => item.testitem_id,
        "label" => item.label,
        "uri" => item.uri,
        "status" => string(item.status),
        "duration" => item.duration,
    )
end

# Sort order for truncation: the most diagnostic statuses must survive the cap.
const STATUS_RANK = Dict{Symbol,Int}(
    :errored => 0, :failed => 1, :running => 2, :pending => 3, :skipped => 4, :passed => 5,
)

status_rank(item::TestItemResult) = get(STATUS_RANK, item.status, 9)

function testmessage_to_dict(msg)

    d = Dict{String,Any}("message" => msg.message)
    if msg.expected_output !== nothing
        d["expected_output"] = msg.expected_output
    end
    if msg.actual_output !== nothing
        d["actual_output"] = msg.actual_output
    end
    if msg.uri !== nothing
        d["uri"] = msg.uri
    end
    if msg.line !== nothing
        d["line"] = msg.line
    end
    if msg.column !== nothing
        d["column"] = msg.column
    end
    if msg.stack_trace !== nothing
        d["stack_trace"] = [
            Dict{String,Any}(
                "label" => f.label,
                "uri" => f.uri,
                "line" => f.line,
                "column" => f.column,
            ) for f in msg.stack_trace
        ]
    end
    return d
end
