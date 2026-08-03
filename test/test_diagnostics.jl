@testitem "safe_byte_slice" begin
    using TestItemMCPApp: safe_byte_slice

    s = "hello"
    @test safe_byte_slice(s, 1, 6) == "hello"
    @test safe_byte_slice(s, 1, 1) == ""
    @test safe_byte_slice(s, 2, 4) == "el"
    @test safe_byte_slice(s, 1, 100) == "hello"
    @test safe_byte_slice(s, 0, 3) == "he"
    @test safe_byte_slice(s, 10, 20) == ""
    @test safe_byte_slice("", 1, 1) == ""

    # Multi-byte characters must not produce invalid string indices.
    u = "aβc"
    @test safe_byte_slice(u, 1, ncodeunits(u) + 1) == u
    @test safe_byte_slice(u, 2, 4) == "β"
    @test safe_byte_slice(u, 3, 4) == "β"
end

@testitem "resolve_uri accepts paths and URIs" begin
    using TestItemMCPApp: resolve_uri
    using TestItemMCPApp: JuliaWorkspaces

    path = abspath(joinpath(@__DIR__, "runtests.jl"))
    from_path = resolve_uri(path)
    from_uri = resolve_uri(string(JuliaWorkspaces.filepath2uri(path)))

    @test from_path == from_uri
    @test string(from_path) |> x -> startswith(x, "file://")
end

@testitem "syntax errors are reported" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        result = MCPTestHelpers.call_tool(client, "get_diagnostics")
        @test !MCPTestHelpers.is_error(result)
        report = MCPTestHelpers.result_json(result)

        @test report["total"] >= 1
        @test report["truncated"] == false

        all_diags = reduce(vcat, [f["diagnostics"] for f in report["files"]]; init=Any[])
        @test any(d -> occursin("badsyntax.jl", d["uri"]), all_diags)
        @test any(d -> d["source"] == "JuliaSyntax.jl", all_diags)

        for d in all_diags
            @test haskey(d, "severity")
            @test haskey(d, "message")
            @test d["range"]["start"]["line"] >= 1
            @test d["range"]["start"]["column"] >= 1
            @test d["range"]["end"]["line"] >= d["range"]["start"]["line"]
        end
    end
end

@testitem "diagnostics can be scoped to a single file" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        bad = joinpath(pkg, "src", "badsyntax.jl")
        report = MCPTestHelpers.result_json(
            MCPTestHelpers.call_tool(client, "get_diagnostics", Dict{String,Any}("path" => bad)))
        @test report["total"] >= 1
        @test all(f -> occursin("badsyntax.jl", f["uri"]), report["files"])

        clean = joinpath(pkg, "src", "unformatted.jl")
        clean_report = MCPTestHelpers.result_json(
            MCPTestHelpers.call_tool(client, "get_diagnostics", Dict{String,Any}("path" => clean)))
        @test clean_report["total"] == 0
        @test clean_report["files"] == []
    end
end

@testitem "diagnostics filters and truncation" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        by_source = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "get_diagnostics",
            Dict{String,Any}("source" => ["JuliaSyntax.jl"])))
        all_diags = reduce(vcat, [f["diagnostics"] for f in by_source["files"]]; init=Any[])
        @test !isempty(all_diags)
        @test all(d -> d["source"] == "JuliaSyntax.jl", all_diags)

        none = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "get_diagnostics",
            Dict{String,Any}("source" => ["NoSuchSource"])))
        @test none["total"] == 0

        truncated = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "get_diagnostics",
            Dict{String,Any}("max_results" => 1)))
        @test truncated["reported"] == 1
        if truncated["total"] > 1
            @test truncated["truncated"] == true
        end

        by_severity = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "get_diagnostics",
            Dict{String,Any}("severity" => ["error"])))
        errs = reduce(vcat, [f["diagnostics"] for f in by_severity["files"]]; init=Any[])
        @test all(d -> d["severity"] == "error", errs)
    end
end

@testitem "get_diagnostics rejects unknown files and unconfigured workspaces" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        result = MCPTestHelpers.call_tool(client, "get_diagnostics")
        @test MCPTestHelpers.is_error(result)
        @test occursin("set_workspace_folders", MCPTestHelpers.result_text(result))

        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        outside = MCPTestHelpers.call_tool(client, "get_diagnostics",
            Dict{String,Any}("path" => joinpath(pkg, "src", "does_not_exist.jl")))
        @test MCPTestHelpers.is_error(outside)
        @test occursin("not part of the workspace", MCPTestHelpers.result_text(outside))
    end
end

@testitem "workspace://diagnostics resource" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        uris = [r["uri"] for r in MCPTestHelpers.request(client, "resources/list", Dict{String,Any}())["resources"]]
        @test "workspace://diagnostics" in uris

        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")
        MCPTestHelpers.call_tool(client, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        report = MCPTestHelpers.resource_json(MCPTestHelpers.read_resource(client, "workspace://diagnostics"))
        @test report["total"] >= 1
        @test haskey(report, "by_severity")
    end
end

@testitem "diagnostic positions match the source text" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JuliaWorkspaces, collect_diagnostics

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        report = collect_diagnostics(state)
        for file in report["files"]
            path = JuliaWorkspaces.uri2filepath(JuliaWorkspaces.URIs2.URI(file["uri"]))
            lines = collect(eachline(path))
            for d in file["diagnostics"]
                # Every reported line must actually exist in the file.
                @test 1 <= d["range"]["start"]["line"] <= max(length(lines), 1)
            end
        end
    end
end
