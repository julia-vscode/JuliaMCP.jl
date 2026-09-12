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
`julia_set_workspace_folders` to tell it which directories to analyse.

## What it exposes

### Tools

Every tool is prefixed `julia_` so a model can tell at a glance that it operates on Julia
code, even in clients that do not namespace tools by server.

**Workspace** — `julia_set_workspace_folders`

**Code analysis** — `julia_get_diagnostics`, `julia_format_file`

**Test items** — `julia_list_testitems`, `julia_get_testitem_detail`, `julia_run_testitems`,
`julia_rerun_failed`, `julia_cancel_testrun`, `julia_get_testrun_results`,
`julia_list_testruns`, `julia_get_coverage_results`, `julia_list_test_processes`,
`julia_terminate_test_process`

`julia_run_testitems` waits at most `max_wait_seconds` (default 600) and otherwise hands the
run back with status `"running"`; `julia_get_testrun_results` polls it and
`julia_cancel_testrun` stops it. The per-item `timeout` is independent and bounds each test
item rather than the call.

**Sessions** — `julia_create_session`, `julia_eval_code`, `julia_profile_code`,
`julia_get_session_variables`, `julia_list_sessions`, `julia_interrupt_session`,
`julia_kill_session`

The workspace tracks the file system itself, so nothing needs to be called after an edit.
`julia_update_file` is routed but not advertised, for embedders that pass `watch: false` to
`julia_set_workspace_folders` and drive refreshes themselves.

### Test item ids

`julia_list_testitems` reports an id for every test item, and `julia_run_testitems`,
`julia_get_testitem_detail` and the `testrun://` resources all take or return those same
ids. They look like this:

```
MyPkg@a1b2c3d4/test/parsing_tests.jl::parse basics
```

That is `<package>/<path>::<label>`.

The package is `<name>@<first eight hex digits of its uuid>`. Both halves matter: the name is
what you recognise, and the uuid fragment separates two different packages that happen to
share a name — a vendored copy sitting beside a dev checkout, say.

The path is the file the `@testitem` is defined in, relative to the root of the package it
belongs to and always written with `/` separators — so an id is identical on Windows and on
Linux, and identical in a dev checkout and on a CI runner. (A file with no filesystem path to
make relative falls back to its full URI, unqualified, since a URI is already unique.)

**An id identifies a test item within its package, not within a workspace.** The *same*
package checked out into two folders — two worktrees, say — produces the same id from both,
deliberately. Two checkouts can only be told apart by their location, and location differs
between a dev checkout and a CI runner, so no single string can be both unique across a
workspace and portable across machines; the id keeps portability. Where uniqueness matters,
this server pairs the id with the package it came from, and results carry the file URI
alongside the id.

**Ids are stable.** They depend only on the file and the test item's name, so inserting or
removing other test items in the same file, or anywhere else in the package, does not change
them. This is what makes `julia_rerun_failed` correct: it re-runs the failed items of an
earlier run by id, and the agent will usually have edited the code in between. The same
holds for ids used in the `items` filter of `julia_run_testitems`, and for ids an agent
writes down and comes back to later. The ids that appear in `juliati`'s results JSON and
JUnit XML output are these same ids.

Two test items in one file are not supposed to share a name. If they do, every occurrence of
that name is suffixed `#1`, `#2`, … so the ids stay unique and each item remains individually
addressable, and a test item definition error is reported for each of them — visible through
`julia_get_diagnostics` and the `workspace://detection-errors` resource. Note that this is
the one case where ids are not stable: resolving the duplicate renumbers its siblings.
Duplicate names are a mistake worth fixing rather than a state to persist ids from.

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
