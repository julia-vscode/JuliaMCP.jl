# JuliaMCP.jl

[![Project Status: Active - The project has reached a stable, usable state and is being actively developed.](http://www.repostatus.org/badges/latest/active.svg)](http://www.repostatus.org/#active)
[![Build Status](https://github.com/julia-vscode/JuliaMCP.jl/actions/workflows/juliaci.yml/badge.svg?branch=main)](https://github.com/julia-vscode/JuliaMCP.jl/actions/workflows/juliaci.yml)
[![codecov](https://codecov.io/gh/julia-vscode/JuliaMCP.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/julia-vscode/JuliaMCP.jl)

An [MCP](https://modelcontextprotocol.io) server that gives AI coding agents access to a
live Julia development environment.

JuliaMCP wraps the same engines that power the Julia VS Code extension —
[JuliaWorkspaces.jl](https://github.com/julia-vscode/JuliaWorkspaces.jl) for analysis,
[TestItemControllers.jl](https://github.com/julia-testitems/TestItemControllers.jl) for test
execution, and
[JuliaSessionControllers.jl](https://github.com/julia-vscode/JuliaSessionControllers.jl) for
long-lived REPL sessions — and exposes them over stdio as MCP tools and resources. An agent
can therefore lint a file, run a subset of test items, read the resulting failure output, and
evaluate code in a persistent session, without shelling out to `julia` and scraping stdout.

The server speaks MCP protocol version `2025-03-26`. All logging goes to stderr; stdout
carries MCP messages exclusively.

## Installation

JuliaMCP is a Julia [app](https://pkgdocs.julialang.org/v1/apps/), which requires Julia 1.12
or newer:

```julia
using Pkg
Pkg.Apps.add(url="https://github.com/julia-vscode/JuliaMCP.jl")
```

This installs a `juliamcp` executable into `~/.julia/bin`. Make sure that directory is on
your `PATH`.

## Usage

Point an MCP client at the `juliamcp` command. For clients that use the common
`mcpServers` JSON format:

```json
{
  "mcpServers": {
    "julia": {
      "command": "juliamcp"
    }
  }
}
```

The server starts with no workspace loaded — an agent's first call is normally
`set_workspace_folders` to tell it which directories to analyse.

## What it exposes

### Tools

**Workspace** — `set_workspace_folders`, `update_file`

**Code analysis** — `get_diagnostics`, `format_file`

**Test items** — `list_testitems`, `get_testitem_detail`, `run_testitems`, `rerun_failed`,
`cancel_testrun`, `get_testrun_results`, `list_testruns`, `get_coverage_results`,
`list_test_processes`, `terminate_test_process`

**Sessions** — `create_session`, `eval_code`, `profile_code`, `get_session_variables`,
`list_sessions`, `interrupt_session`, `kill_session`

### Resources

Static resources cover the current workspace state (`workspace://testitems`,
`workspace://diagnostics`, `workspace://detection-errors`). Dynamic resources are listed as
work happens, so an agent can read large output out of band rather than through a tool
result: `testrun://<id>/summary`, `testprocess://<id>/output`, `session://<id>/info` and
`session://<id>/output`.

## Development

```julia
using Pkg
Pkg.develop(url="https://github.com/julia-vscode/JuliaSessionControllers.jl")  # not yet registered
Pkg.test("JuliaMCP")
```

Tests are written as [test items](https://github.com/julia-testitems/TestItems.jl) and run
with TestItemRunner. Note that `testdata/` deliberately contains `@testitem`s that are
fixtures for the test suite rather than tests of this package, so `test/runtests.jl` filters
them out.
