# mcp_tools.jl — MCP tool definitions with JSON Schema

function tool_definitions()
    return [
        Dict{String,Any}(
            "name" => "set_workspace_folders",
            "description" => "Set the workspace folders for test item detection. Call this first to configure which Julia packages/projects to scan for @testitem and @testsetup macros. Replaces any previous workspace configuration.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "folders" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Absolute paths to workspace folders to scan for test items.",
                    ),
                    "watch" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Automatically refresh the workspace when files change on disk. Defaults to true; when disabled, call update_file after each edit.",
                    ),
                    "watch_interval" => Dict{String,Any}(
                        "type" => "number",
                        "description" => "Seconds between file system scans (default $(WATCH_INTERVAL_DEFAULT)).",
                    ),
                ),
                "required" => ["folders"],
            ),
        ),
        Dict{String,Any}(
            "name" => "update_file",
            "description" => "Notify the server that a file has changed on disk. Only needed when watching is disabled — by default the workspace refreshes automatically.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "path" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Absolute file path that was changed.",
                    ),
                ),
                "required" => ["path"],
            ),
        ),
        Dict{String,Any}(
            "name" => "get_diagnostics",
            "description" => "Get syntax errors, lint warnings, and test item detection errors for the workspace, or for a single file. Results are grouped by file with 1-based line/column positions.",
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
                        "description" => "Wait for environment-dependent analysis to finish before reporting. Slower, but required for checks such as unresolved imports and missing references.",
                    ),
                ),
            ),
        ),
        Dict{String,Any}(
            "name" => "format_file",
            "description" => "Format a Julia file using the style from the nearest juliaformat.toml (JuliaFormatter by default, or Runic when style=\"runic\"). Returns the edits by default; set apply=true to write them to disk.",
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
            "name" => "list_testitems",
            "description" => "List all detected test items, optionally filtered by tags, name pattern, file pattern, or package name.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "tags" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Filter to items containing at least one of these tags.",
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
            "name" => "run_testitems",
            "description" => "Run test items. Blocks until all tests complete. Returns a summary plus a " *
                             "compact status line per test item — failure messages, stack traces and captured " *
                             "output are NOT included; call get_testitem_detail for those. If no items or " *
                             "filter are specified, runs all detected test items. Test processes are reused " *
                             "across runs with Revise-based hot-reload for fast iteration.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "items" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Specific test item IDs to run. If omitted, runs all (or filtered) items.",
                    ),
                    "tags" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Filter to items containing at least one of these tags.",
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
                        "description" => "Execution mode (default: \"Run\").",
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
            "name" => "rerun_failed",
            "description" => "Re-run only the failed and errored test items from a previous test run.",
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
            "name" => "cancel_testrun",
            "description" => "Cancel an active test run.",
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
            "name" => "get_testrun_results",
            "description" => "Get results for a completed or in-progress test run: a summary plus a compact " *
                             "status line per test item. Use get_testitem_detail for failure messages, stack " *
                             "traces and captured output.",
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
            "name" => "get_testitem_detail",
            "description" => "Get detailed results for one or more test items in a run: failure messages, " *
                             "stack traces, and captured output (stdout and stderr interleaved). This is the " *
                             "follow-up to run_testitems — pass every id you want to inspect in one call.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "testrun_id" => Dict{String,Any}("type" => "string", "description" => "Test run ID."),
                    "testitem_ids" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string"),
                        "description" => "Test item IDs to inspect. Unknown ids are reported per item rather than failing the call.",
                    ),
                    "testitem_id" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Single test item ID. Prefer testitem_ids for more than one.",
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
            "name" => "list_testruns",
            "description" => "List all test runs with their status summaries.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(),
            ),
        ),
        Dict{String,Any}(
            "name" => "list_test_processes",
            "description" => "List active test worker processes managed by the controller.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(),
            ),
        ),
        Dict{String,Any}(
            "name" => "terminate_test_process",
            "description" => "Terminate a specific test worker process.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "process_id" => Dict{String,Any}("type" => "string", "description" => "Process ID to terminate."),
                ),
                "required" => ["process_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "get_coverage_results",
            "description" => "Get line-level coverage results from a Coverage-mode test run.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "testrun_id" => Dict{String,Any}("type" => "string", "description" => "Test run ID (must have been run with mode=\"Coverage\")."),
                ),
                "required" => ["testrun_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "create_session",
            "description" => "Start a persistent Julia session and return its session_id. State (variables, " *
                             "functions, loaded packages) survives between eval_code calls, so iterating in a " *
                             "session avoids Julia's startup and compilation costs. Sessions are independent of " *
                             "the test workspace — set_workspace_folders is not required. The response echoes the " *
                             "resolved environment; pass it back here to replace a session that died.",
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
            "name" => "eval_code",
            "description" => "Evaluate Julia code in a session and return the value, captured output, and any " *
                             "error. An error is a normal result with status \"error\", not a tool failure. " *
                             "Definitions and variables persist for later calls.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "session_id" => Dict{String,Any}("type" => "string", "description" => "Session to evaluate in, from create_session."),
                    "code" => Dict{String,Any}("type" => "string", "description" => "Julia code to evaluate. Multiple top-level statements are allowed; the last value is returned."),
                    "module" => Dict{String,Any}("type" => "string", "description" => "Module to evaluate in (default \"Main\")."),
                    "revise" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Run Revise first so edits made on disk take effect (default true).",
                    ),
                    "timeout" => Dict{String,Any}(
                        "type" => "number",
                        "description" => "Seconds before the evaluation is interrupted. Omit for no timeout; long precompilation can take minutes.",
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
            "name" => "interrupt_session",
            "description" => "Interrupt whatever a session is currently evaluating. Queued requests are " *
                             "discarded. The session stays alive and usable. Note that code which never yields " *
                             "(for example `while true; end`) may not be interruptible on Windows — kill_session " *
                             "is the only recourse there.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "session_id" => Dict{String,Any}("type" => "string", "description" => "Session to interrupt."),
                ),
                "required" => ["session_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "kill_session",
            "description" => "Terminate a session and discard its state. To start over with the same setup, " *
                             "call create_session with the environment reported by list_sessions.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "session_id" => Dict{String,Any}("type" => "string", "description" => "Session to terminate."),
                ),
                "required" => ["session_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "list_sessions",
            "description" => "List Julia sessions with their status and the environment each was created with.",
            "inputSchema" => Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
        ),
        Dict{String,Any}(
            "name" => "profile_code",
            "description" => "Profile Julia code in a session and return the hottest functions by self and total " *
                             "sample count. Use kind=\"alloc\" for an allocation profile (Julia 1.8+).",
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
            "name" => "get_session_variables",
            "description" => "List the bindings of a module in a session, with rendered values. Values too " *
                             "expensive to render come back with lazy=true and an id — pass that id back as " *
                             "variable_id to expand them.",
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
