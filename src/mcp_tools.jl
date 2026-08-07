# mcp_tools.jl — MCP tool definitions with JSON Schema

# `title` belongs inside `annotations` in protocol 2025-03-26. Nothing here reaches the
# network, so `openWorldHint` is always false.
function tool_annotations(title::String; read_only::Bool=false, destructive::Bool=false, idempotent::Bool=false)
    return Dict{String,Any}(
        "title" => title,
        "readOnlyHint" => read_only,
        "destructiveHint" => destructive,
        "idempotentHint" => idempotent,
        "openWorldHint" => false,
    )
end

# `update_file` is deliberately not advertised: the workspace tracks the file system
# itself, so offering a manual refresh only invites needless calls. It stays routed in
# `handle_tool_call` for the `watch=false` path.
function tool_definitions()
    return [
        Dict{String,Any}(
            "name" => "julia_set_workspace_folders",
            "description" => "Load Julia packages or projects into this server's workspace. This is a " *
                             "prerequisite for every other Julia workspace tool — julia_get_diagnostics, " *
                             "julia_format_file, julia_list_testitems and julia_run_testitems all fail until " *
                             "it has been called. Parses the Julia source under each folder, resolves the " *
                             "Project.toml/Manifest.toml environments, and detects @testitem and @testsetup " *
                             "blocks. The workspace then keeps itself up to date as files change on disk, so " *
                             "nothing needs to be called after editing a file. Calling this again replaces the " *
                             "previous configuration. Julia sessions (julia_create_session) are separate and " *
                             "need no workspace.",
            "annotations" => tool_annotations("Set Julia workspace folders"; destructive=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "folders" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Absolute paths of the Julia package or project folders to load, normally the repository roots being worked on.",
                    ),
                    "watch_interval" => Dict{String,Any}(
                        "type" => "number",
                        "description" => "Seconds between file system scans (default $(WATCH_INTERVAL_DEFAULT)). The workspace always tracks the file system; this only tunes how quickly edits are noticed.",
                    ),
                ),
                "required" => ["folders"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_get_diagnostics",
            "description" => "Report Julia syntax errors, lint warnings and test item detection errors, for " *
                             "the whole workspace or a single file. This is static analysis: no Julia code is " *
                             "run and nothing is compiled, so it is cheap enough to call after every edit. " *
                             "Prefer it over shelling out to julia to check whether a file parses. Results are " *
                             "grouped by file with 1-based line/column positions. Requires " *
                             "julia_set_workspace_folders.",
            "annotations" => tool_annotations("Get Julia diagnostics"; read_only=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "path" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Optional absolute file path or file:// URI. When omitted, diagnostics for the whole workspace are returned.",
                    ),
                    "severity" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Only report these severities, e.g. [\"error\"] or [\"error\", \"warning\"].",
                    ),
                    "source" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Only report diagnostics from these sources, e.g. [\"JuliaSyntax.jl\"] or [\"StaticLint.jl\"].",
                    ),
                    "max_results" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Maximum number of diagnostics to return (default $(DIAGNOSTIC_LIMIT_DEFAULT)). The response reports whether it was truncated.",
                    ),
                    "wait_for_ready" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Wait for environment-dependent analysis (package resolution) to finish first. Slower, but required for checks that need the surrounding environment, such as unresolved imports and missing references — without it those checks are silently absent.",
                    ),
                ),
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_format_file",
            "description" => "Format Julia source code with the style configured by the nearest " *
                             "JuliaFormat.toml (JuliaFormatter by default, or Runic when style=\"runic\"). " *
                             "Returns the text edits without touching disk; set apply=true to write them and " *
                             "refresh the workspace. A file the configuration excludes returns " *
                             "excluded=true with no edits rather than an error. Requires " *
                             "julia_set_workspace_folders, and only works on files inside the workspace.",
            "annotations" => tool_annotations("Format a Julia file"; idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "path" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Absolute file path or file:// URI of the file to format.",
                    ),
                    "start_line" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "First line to format (1-based, inclusive). Requires stop_line. Formats the whole file when omitted.",
                    ),
                    "stop_line" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Last line to format (1-based, inclusive). Requires start_line.",
                    ),
                    "apply" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Write the formatted result to disk and refresh the workspace. Defaults to false, which only returns the edits.",
                    ),
                ),
                "required" => ["path"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_list_testitems",
            "description" => "List the Julia test items (@testitem blocks from TestItems.jl) detected in the " *
                             "workspace, with their ids, names, tags, packages and source locations. Call this " *
                             "before julia_run_testitems to see what can be run and to get ids for filtering. " *
                             "An empty result means the workspace does not use test items, in which case fall " *
                             "back to the package's own test entrypoint. Requires julia_set_workspace_folders.",
            "annotations" => tool_annotations("List Julia test items"; read_only=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "items" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Filter to these specific test item ids.",
                    ),
                    "tags" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Filter to items carrying at least one of these tags.",
                    ),
                    "name_pattern" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Regex pattern to match against test item names (case-insensitive).",
                    ),
                    "file_pattern" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Regex pattern to match against file URIs (case-insensitive).",
                    ),
                    "package" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Filter to items in this package only.",
                    ),
                ),
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_run_testitems",
            "description" => "Run Julia test items and block until they finish. This is the right way to run " *
                             "tests for a workspace that uses TestItems.jl — use it instead of shelling out to " *
                             "Pkg.test() or `julia --project -e`, which recompile everything and cannot report " *
                             "per-test results. Test items run in Julia worker processes that stay alive " *
                             "between calls and hot-reload edits via Revise, so repeat runs skip startup and " *
                             "most compilation. Runs every detected item when no filter is given; narrow with " *
                             "items, tags, name_pattern, file_pattern or package. Returns a summary plus one " *
                             "compact status line per item — failure messages, stack traces and captured " *
                             "output are deliberately omitted; call julia_get_testitem_detail with the ids you " *
                             "care about for those. All durations are milliseconds: per item, the time that " *
                             "item took; in the summary, elapsed wall-clock time for the whole run (not the sum " *
                             "of the per-item times, which overshoots because items run in parallel). If this " *
                             "call is interrupted or its result is lost, the run keeps going and its results " *
                             "stay retrievable — find the run with julia_list_testruns and fetch it with " *
                             "julia_get_testrun_results. Requires julia_set_workspace_folders.",
            "annotations" => tool_annotations("Run Julia test items"),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "items" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Specific test item ids to run, as reported by julia_list_testitems. If omitted, runs all (or filtered) items.",
                    ),
                    "tags" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Filter to items carrying at least one of these tags.",
                    ),
                    "name_pattern" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Regex pattern to match against test item names.",
                    ),
                    "file_pattern" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Regex pattern to match against file URIs.",
                    ),
                    "package" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Filter to items in this package only.",
                    ),
                    "julia_cmd" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Julia command to use (default: \"julia\").",
                    ),
                    "julia_args" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Extra command-line arguments for Julia.",
                    ),
                    "julia_num_threads" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Thread count (e.g. \"auto\", \"4\").",
                    ),
                    "max_workers" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Maximum number of parallel test processes (default: min(CPU_THREADS, 8)).",
                    ),
                    "mode" => Dict{String,Any}(
                        "type" => "string",
                        "enum" => ["Normal", "Coverage"],
                        "description" => "Execution mode (default \"Normal\"). Use \"Coverage\" to collect line coverage, then read it with julia_get_coverage_results.",
                    ),
                    "timeout" => Dict{String,Any}(
                        "type" => "number",
                        "description" => "Per-test-item timeout in seconds.",
                    ),
                    "coverage_root_uris" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Root URIs for coverage collection (Coverage mode only).",
                    ),
                    "include_passing" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "List passing items too. Defaults to false — passing items are counted in the summary.",
                    ),
                    "max_items" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Maximum number of items to list (default $(MAX_ITEMS_DEFAULT)). Errored and failed items are listed first.",
                    ),
                ),
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_rerun_failed",
            "description" => "Re-run only the failed and errored Julia test items from an earlier run, reusing " *
                             "that run's settings. Returns a new test run id; the original run is left intact. " *
                             "The usual loop is julia_run_testitems, fix the code, then this — the worker " *
                             "processes pick up the fix via Revise.",
            "annotations" => tool_annotations("Re-run failed Julia test items"),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "testrun_id" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "ID of the previous test run whose failures to re-run.",
                    ),
                    "julia_cmd" => Dict{String,Any}("type" => "string", "description" => "Julia command override."),
                    "julia_args" => Dict{String,Any}("type" => "array", "items" => Dict{String,Any}("type" => "string"), "description" => "Julia args override."),
                    "max_workers" => Dict{String,Any}("type" => "integer", "description" => "Max workers override."),
                    "timeout" => Dict{String,Any}("type" => "number", "description" => "Per-item timeout override."),
                ),
                "required" => ["testrun_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_cancel_testrun",
            "description" => "Cancel an in-progress Julia test run. Items that have not finished are abandoned; " *
                             "results already collected stay readable via julia_get_testrun_results. Only " *
                             "meaningful while a run is still going, so it has to come from somewhere other " *
                             "than the blocking julia_run_testitems call.",
            "annotations" => tool_annotations("Cancel a Julia test run"; destructive=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "testrun_id" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "ID of the test run to cancel.",
                    ),
                ),
                "required" => ["testrun_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_get_testrun_results",
            "description" => "Get the summary and per-item status lines for a Julia test run, whether it has " *
                             "completed or is still going. Same compact shape julia_run_testitems returns — use " *
                             "julia_get_testitem_detail for failure messages, stack traces and captured output. " *
                             "Durations are milliseconds; the summary duration is elapsed wall-clock time, and " *
                             "for a run still in progress it is the time elapsed so far.",
            "annotations" => tool_annotations("Get Julia test run results"; read_only=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "testrun_id" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "ID of the test run.",
                    ),
                    "include_passing" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Include passing test items in results (default: false).",
                    ),
                    "max_items" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Maximum number of items to list (default $(MAX_ITEMS_DEFAULT)). Errored and failed items are listed first.",
                    ),
                ),
                "required" => ["testrun_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_get_testitem_detail",
            "description" => "Get the full result of one or more Julia test items: failure messages, stack " *
                             "traces, and captured output (stdout and stderr interleaved). This is the " *
                             "follow-up to julia_run_testitems — pass every id you want to inspect in a single " *
                             "call rather than one call per item. Supply testitem_ids or testitem_id; at least " *
                             "one is required. If a whole worker process died before running anything (a " *
                             "precompilation error, say), the cause is in the testprocess://{process_id}/output " *
                             "resource instead.",
            "annotations" => tool_annotations("Get Julia test item detail"; read_only=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "testrun_id" => Dict{String,Any}("type" => "string", "description" => "Test run ID."),
                    "testitem_ids" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Test item ids to inspect. Unknown ids are reported per item rather than failing the call.",
                    ),
                    "testitem_id" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Single test item id. Prefer testitem_ids for more than one.",
                    ),
                    "max_output_bytes" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Cap on captured output per item (default $(MAX_OUTPUT_BYTES_DEFAULT)). The tail is kept; " *
                                         "read the testrun://{id}/items/{id}/output resource for the full stream.",
                    ),
                    "max_messages" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Cap on failure messages per item (default $(MAX_MESSAGES_DEFAULT)).",
                    ),
                    "max_stack_frames" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Cap on stack frames per message (default $(MAX_STACK_FRAMES_DEFAULT)).",
                    ),
                ),
                "required" => ["testrun_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_list_testruns",
            "description" => "List every Julia test run this server has started, with status and pass/fail " *
                             "counts. Use it to recover a testrun_id for julia_get_testrun_results, " *
                             "julia_get_testitem_detail or julia_rerun_failed — including when a " *
                             "julia_run_testitems call was interrupted or its result went missing.",
            "annotations" => tool_annotations("List Julia test runs"; read_only=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(),
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_list_test_processes",
            "description" => "List the Julia worker processes currently held for running test items. They " *
                             "persist between runs by design — that is what makes repeat runs fast. Read the " *
                             "testprocess://{process_id}/output resource for a process's raw output, which is " *
                             "where precompilation and startup failures show up.",
            "annotations" => tool_annotations("List Julia test workers"; read_only=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(),
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_terminate_test_process",
            "description" => "Kill a Julia test worker process. Its loaded packages and compiled code are " *
                             "lost, so the next run needing it pays full Julia startup and precompilation " *
                             "again. Only worth doing when a worker is wedged or Revise cannot apply a change — " *
                             "editing a struct definition, for instance.",
            "annotations" => tool_annotations("Terminate a Julia test worker"; destructive=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "process_id" => Dict{String,Any}("type" => "string", "description" => "Process ID to terminate."),
                ),
                "required" => ["process_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_get_coverage_results",
            "description" => "Get line-level Julia code coverage for a test run. Only available for runs " *
                             "started with mode=\"Coverage\"; anything else returns an error.",
            "annotations" => tool_annotations("Get Julia coverage results"; read_only=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "testrun_id" => Dict{String,Any}("type" => "string", "description" => "Test run ID (must have been run with mode=\"Coverage\")."),
                ),
                "required" => ["testrun_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_create_session",
            "description" => "Start a persistent Julia process and return its session_id. State — variables, " *
                             "functions, loaded packages, compiled code — survives across julia_eval_code " *
                             "calls, so iterating inside one session avoids paying Julia's startup and " *
                             "compilation cost over and over. Prefer this over shelling out to `julia -e` for " *
                             "anything beyond a single throwaway command. Revise is loaded, so edits made to " *
                             "package source on disk take effect on the next evaluation without a restart. " *
                             "Sessions are independent of the analysis workspace: julia_set_workspace_folders " *
                             "is not required. The response echoes the resolved environment; pass it back here " *
                             "to replace a session that died.",
            "annotations" => tool_annotations("Start a Julia session"),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "project" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Absolute path or file:// URI of the project to activate. Omitted means Julia's default environment.",
                    ),
                    "package" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Absolute path or file:// URI of the package being developed, when there is one.",
                    ),
                    "package_name" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Name of the package being developed.",
                    ),
                    "use_test_env" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Activate the package's test environment via TestEnv (default false).",
                    ),
                    "julia_cmd" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Path to the Julia executable (default: the one running this server).",
                    ),
                    "julia_args" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Extra command-line arguments for Julia.",
                    ),
                    "julia_num_threads" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Thread count (e.g. \"auto\", \"4\").",
                    ),
                    "env" => Dict{String,Any}(
                        "type" => "object",
                        "description" => "Environment variable overrides. A null value removes the variable.",
                    ),
                ),
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_eval_code",
            "description" => "Evaluate Julia code in a persistent session and return the value, captured " *
                             "output, and any error. A Julia exception comes back as a normal result with " *
                             "status \"error\" rather than a tool failure, so the message and backtrace are " *
                             "there to read. Definitions and variables persist for later calls in the same " *
                             "session. Revise runs first by default, so edits made to package source on disk " *
                             "are picked up before the code runs.",
            "annotations" => tool_annotations("Evaluate Julia code"),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "session_id" => Dict{String,Any}("type" => "string", "description" => "Session to evaluate in, from julia_create_session."),
                    "code" => Dict{String,Any}("type" => "string", "description" => "Julia code to evaluate. Multiple top-level statements are allowed; the value of the last one is returned."),
                    "module" => Dict{String,Any}("type" => "string", "description" => "Module to evaluate in (default \"Main\")."),
                    "revise" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Run Revise first so edits made on disk take effect (default true).",
                    ),
                    "timeout" => Dict{String,Any}(
                        "type" => "number",
                        "description" => "Seconds before the evaluation is interrupted. Omit for no timeout; Julia precompilation can take minutes.",
                    ),
                    "max_output_bytes" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Cap on returned output, keeping the tail (default $(MAX_OUTPUT_BYTES_DEFAULT)).",
                    ),
                ),
                "required" => ["session_id", "code"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_interrupt_session",
            "description" => "Interrupt whatever a Julia session is currently evaluating, as Ctrl-C would. " *
                             "Queued requests are discarded and the session stays alive and usable. Julia code " *
                             "that never yields (`while true; end`, or a long call into a C library) may not be " *
                             "interruptible, especially on Windows — julia_kill_session is the only recourse " *
                             "there.",
            "annotations" => tool_annotations("Interrupt a Julia session"; idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "session_id" => Dict{String,Any}("type" => "string", "description" => "Session to interrupt."),
                ),
                "required" => ["session_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_kill_session",
            "description" => "Terminate a Julia session and discard all of its state. There is no restart " *
                             "tool: to start over with the same setup, call julia_create_session with the " *
                             "environment julia_list_sessions reports for it.",
            "annotations" => tool_annotations("Kill a Julia session"; destructive=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "session_id" => Dict{String,Any}("type" => "string", "description" => "Session to terminate."),
                ),
                "required" => ["session_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_list_sessions",
            "description" => "List the Julia sessions this server manages, with each one's status and the " *
                             "environment it was created with. That environment is what julia_create_session " *
                             "needs to recreate a session after julia_kill_session.",
            "annotations" => tool_annotations("List Julia sessions"; read_only=true, idempotent=true),
            "inputSchema" => Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
        ),
        Dict{String,Any}(
            "name" => "julia_profile_code",
            "description" => "Profile Julia code in a session and return the hottest functions by self and " *
                             "total sample count. Use kind=\"alloc\" for an allocation profile instead of CPU " *
                             "sampling. Run the code once with julia_eval_code first — otherwise compilation " *
                             "dominates the samples and the profile says nothing useful.",
            "annotations" => tool_annotations("Profile Julia code"),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "session_id" => Dict{String,Any}("type" => "string", "description" => "Session to profile in."),
                    "code" => Dict{String,Any}("type" => "string", "description" => "Julia code to profile. Run it once first so compilation does not dominate the profile."),
                    "kind" => Dict{String,Any}(
                        "type" => "string",
                        "enum" => ["cpu", "alloc"],
                        "description" => "Profile kind (default \"cpu\").",
                    ),
                    "module" => Dict{String,Any}("type" => "string", "description" => "Module to profile in (default \"Main\")."),
                    "max_entries" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Number of hot functions to report (default $(PROFILE_ENTRIES_DEFAULT)).",
                    ),
                    "timeout" => Dict{String,Any}("type" => "number", "description" => "Seconds before the profile run is interrupted."),
                ),
                "required" => ["session_id", "code"],
            ),
        ),
        Dict{String,Any}(
            "name" => "julia_get_session_variables",
            "description" => "List the bindings of a module in a Julia session with rendered values — the " *
                             "equivalent of a debugger's variable pane. Values too expensive to render eagerly " *
                             "come back with lazy=true and an id; pass that id back as variable_id to expand " *
                             "that value's children.",
            "annotations" => tool_annotations("Inspect Julia session variables"; read_only=true, idempotent=true),
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "session_id" => Dict{String,Any}("type" => "string", "description" => "Session to inspect."),
                    "module" => Dict{String,Any}("type" => "string", "description" => "Module whose bindings to list (default \"Main\")."),
                    "variable_id" => Dict{String,Any}(
                        "type" => "integer",
                        "description" => "Expand the children of this lazily reported variable instead of listing a module.",
                    ),
                    "include_modules" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Include module bindings in the listing (default false).",
                    ),
                ),
                "required" => ["session_id"],
            ),
        ),
    ]
end
