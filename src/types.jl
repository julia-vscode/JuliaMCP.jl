# types.jl — Shared data types for test run tracking

const MCP_PROTOCOL_VERSION = "2025-03-26"

"""
A resource URI the client named that does not exist. Kept distinct from an internal
failure so the server can answer with the spec's -32002 instead of -32603.
"""
struct ResourceNotFound <: Exception
    uri::String
    message::String
end

Base.showerror(io::IO, e::ResourceNotFound) = print(io, e.message)

mutable struct TestItemResult
    testitem_id::String
    label::String
    uri::String
    status::Symbol  # :pending, :running, :passed, :failed, :errored, :skipped
    duration::Union{Nothing,Float64}  # milliseconds, as reported by the test process

    messages::Vector{Any}  # TestMessage-like dicts
    output::Vector{String}
end

mutable struct TestRunRecord
    const id::String
    status::Symbol  # :running, :completed, :cancelled, :errored
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
A Julia session managed by JuliaSessionControllers, plus the output the app has seen for
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

"""
Record a terminal status for `run`, unless one is already recorded.

`execute_testrun` returns for a cancelled run just as it does for a completed one, and
cannot tell the caller which happened — both paths simply put a value on the completion
channel. So the tool call that started the run wakes up wanting to write `:completed` even
when `tool_cancel_testrun` has already written `:cancelled`. First writer wins; the run only
finishes once.

Returns true if this call was the one that set the status.
"""
function finalize_run_status!(run::TestRunRecord, status::Symbol)
    run.status === :running || return false
    run.status = status
    run.completed_at = Dates.now()
    return true
end

"""
Run-level counts plus timings. `duration` is elapsed wall-clock time in milliseconds, to
match the per-item durations and the `started_at`/`completed_at` stamps. It is deliberately
not the sum of per-item durations: items run concurrently on up to `max_workers` processes,
so that sum overshoots elapsed time several-fold, and it silently omits every item without
a duration (pending, running, skipped, timed out, crashed).
"""
function run_summary(run::TestRunRecord)
    total = length(run.items)
    passed = count(v -> v.status == :passed, values(run.items))
    failed = count(v -> v.status == :failed, values(run.items))
    errored = count(v -> v.status == :errored, values(run.items))
    skipped = count(v -> v.status == :skipped, values(run.items))
    running = count(v -> v.status == :running, values(run.items))
    pending = count(v -> v.status == :pending, values(run.items))
    # An in-progress run reports elapsed-so-far rather than nothing.
    end_time = run.completed_at === nothing ? Dates.now() : run.completed_at
    duration = Dates.value(Dates.Millisecond(end_time - run.started_at))
    return Dict{String,Any}(
        "total" => total,
        "passed" => passed,
        "failed" => failed,
        "errored" => errored,
        "skipped" => skipped,
        "running" => running,
        "pending" => pending,
        "duration" => duration,
        "status" => string(run.status),
        "testrun_id" => run.id,
        "started_at" => string(run.started_at),
        "completed_at" => run.completed_at === nothing ? nothing : string(run.completed_at),
    )
end

"""
Compact, bounded view of a test item — no messages, no captured output. Detail lives
behind the `julia_get_testitem_detail` tool so run results stay small.
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
