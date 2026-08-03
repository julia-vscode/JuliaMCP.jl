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
            "description" => "Run test items. Blocks until all tests complete and returns full results. If no items or filter specified, runs all detected test items. Test processes are reused across runs with Revise-based hot-reload for fast iteration.",
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
            "description" => "Get results for a completed or in-progress test run.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "testrun_id" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "ID of the test run.",
                    ),
                    "include_output" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Include captured stdout/stderr per test item (default: false).",
                    ),
                    "include_passing" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Include passing test items in results (default: false).",
                    ),
                ),
                "required" => ["testrun_id"],
            ),
        ),
        Dict{String,Any}(
            "name" => "get_testitem_detail",
            "description" => "Get detailed result for a specific test item in a run, including failure messages, stack traces, and captured output.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "testrun_id" => Dict{String,Any}("type" => "string", "description" => "Test run ID."),
                    "testitem_id" => Dict{String,Any}("type" => "string", "description" => "Test item ID."),
                ),
                "required" => ["testrun_id", "testitem_id"],
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
    ]
end
