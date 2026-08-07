@testitem "format_file returns edits without touching disk" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    pkg = MCPTestHelpers.copy_testdata("LintPkg")
    target = joinpath(pkg, "src", "unformatted.jl")
    original = read(target, String)

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        result = MCPTestHelpers.call_tool(client, "julia_format_file", Dict{String,Any}("path" => target))
        @test !MCPTestHelpers.is_error(result)

        edit = MCPTestHelpers.result_json(result)
        @test edit["already_formatted"] == false
        @test edit["applied"] == false
        @test !isempty(edit["edits"])
        @test read(target, String) == original

        for e in edit["edits"]
            @test e["start"]["line"] >= 1
            @test e["start"]["column"] >= 1
            @test haskey(e, "new_text")
        end
    end
end

@testitem "format_file with apply rewrites the file and is idempotent" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    pkg = MCPTestHelpers.copy_testdata("LintPkg")
    target = joinpath(pkg, "src", "unformatted.jl")
    original = read(target, String)

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        applied = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_format_file",
            Dict{String,Any}("path" => target, "apply" => true)))
        @test applied["applied"] == true

        formatted = read(target, String)
        @test formatted != original
        # Formatting must preserve the code, not just the whitespace around it.
        @test occursin("messy", formatted)
        @test occursin("struct Point", formatted)

        again = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_format_file",
            Dict{String,Any}("path" => target)))
        @test again["already_formatted"] == true
        @test isempty(again["edits"])
        @test read(target, String) == formatted
    end
end

@testitem "format_file range formatting" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    pkg = MCPTestHelpers.copy_testdata("LintPkg")
    target = joinpath(pkg, "src", "unformatted.jl")

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        result = MCPTestHelpers.call_tool(client, "julia_format_file",
            Dict{String,Any}("path" => target, "start_line" => 1, "stop_line" => 4))
        @test !MCPTestHelpers.is_error(result)
        edit = MCPTestHelpers.result_json(result)
        @test !isempty(edit["edits"])
        # A range format must not reach past the requested lines.
        @test all(e -> e["start"]["line"] >= 1, edit["edits"])

        partial = MCPTestHelpers.call_tool(client, "julia_format_file",
            Dict{String,Any}("path" => target, "start_line" => 1))
        @test MCPTestHelpers.is_error(partial)
        @test occursin("must be supplied together", MCPTestHelpers.result_text(partial))
    end
end

@testitem "format_file reports an excluded file as excluded, not as an error" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    pkg = MCPTestHelpers.copy_testdata("LintPkg")
    write(joinpath(pkg, "JuliaFormat.toml"), "exclude = [\"src/unformatted.jl\"]\n")
    target = joinpath(pkg, "src", "unformatted.jl")
    original = read(target, String)

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        result = MCPTestHelpers.call_tool(client, "julia_format_file", Dict{String,Any}("path" => target))
        @test !MCPTestHelpers.is_error(result)
        edit = MCPTestHelpers.result_json(result)
        @test edit["excluded"] == true
        @test isempty(edit["edits"])
        @test edit["applied"] == false

        # apply=true on an excluded file must leave the file alone.
        applied = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_format_file",
            Dict{String,Any}("path" => target, "apply" => true)))
        @test applied["excluded"] == true
        @test applied["applied"] == false
        @test read(target, String) == original

        # A non-excluded sibling still reports excluded=false and formats.
        other = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_format_file",
            Dict{String,Any}("path" => joinpath(pkg, "src", "LintPkg.jl"))))
        @test other["excluded"] == false
    end
end

@testitem "format_file reports syntax errors" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        result = MCPTestHelpers.call_tool(client, "julia_format_file",
            Dict{String,Any}("path" => joinpath(pkg, "src", "badsyntax.jl")))
        @test MCPTestHelpers.is_error(result)
        @test occursin("Formatting failed", MCPTestHelpers.result_text(result))
    end
end

@testitem "format_file rejects unknown files and unconfigured workspaces" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        result = MCPTestHelpers.call_tool(client, "julia_format_file", Dict{String,Any}("path" => "whatever.jl"))
        @test MCPTestHelpers.is_error(result)
        @test occursin("julia_set_workspace_folders", MCPTestHelpers.result_text(result))

        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

        outside = MCPTestHelpers.call_tool(client, "julia_format_file",
            Dict{String,Any}("path" => joinpath(pkg, "src", "nope.jl")))
        @test MCPTestHelpers.is_error(outside)
        @test occursin("not part of the workspace", MCPTestHelpers.result_text(outside))
    end
end

@testitem "apply_text_edits" begin
    using JuliaMCP: apply_text_edits, offset_of
    using JuliaMCP: JuliaWorkspaces
    using JuliaMCP.JuliaWorkspaces: SourceText, Position

    content = SourceText("one\ntwo\nthree\n", "julia")

    @test offset_of(content, Position(1, 1)) == 1
    @test offset_of(content, Position(2, 1)) == 5
    @test offset_of(content, Position(3, 1)) == 9

    Edit = typeof(JuliaWorkspaces.TextEditResult(Position(1, 1), Position(1, 1), ""))
    replace_second = [JuliaWorkspaces.TextEditResult(Position(2, 1), Position(3, 1), "TWO\n")]
    @test apply_text_edits(content, replace_second) == "one\nTWO\nthree\n"

    # Whole-document replacement, which is what full-file formatting produces.
    whole = [JuliaWorkspaces.TextEditResult(Position(1, 1), Position(4, 1), "new\n")]
    @test apply_text_edits(content, whole) == "new\n"

    @test apply_text_edits(content, Edit[]) == "one\ntwo\nthree\n"

    # Multiple non-overlapping edits are applied back-to-front.
    multi = [
        JuliaWorkspaces.TextEditResult(Position(1, 1), Position(2, 1), "1\n"),
        JuliaWorkspaces.TextEditResult(Position(3, 1), Position(4, 1), "3\n"),
    ]
    @test apply_text_edits(content, multi) == "1\ntwo\n3\n"
end
