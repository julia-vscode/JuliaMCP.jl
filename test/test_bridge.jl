@testitem "resolve_testitems produces valid source positions" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        # Regression: this used to throw a MethodError because `position_at`
        # returns a `Position` struct, which was being indexed with `[1]`/`[2]`.
        items, setups, pkg_info = TestItemMCPApp.resolve_testitems(state)

        @test length(items) == 7
        @test length(setups) == 2

        for item in items
            @test item.line isa Int && item.line >= 1
            @test item.column isa Int && item.column >= 1
            @test item.code_line isa Int && item.code_line >= 1
            @test item.code_column isa Int && item.code_column >= 1
            @test item.package_name == "BasicPkg"
            @test !isempty(item.code)
            @test haskey(pkg_info, item.id)
        end

        for setup in setups
            @test setup.line isa Int && setup.line >= 1
            @test setup.column isa Int && setup.column >= 1
        end
    end
end

@testitem "line/column point at the macro call, code_line/code_column at the body" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        items, _, _ = TestItemMCPApp.resolve_testitems(state)
        passing = only(filter(i -> i.label == "passing", items))

        source = read(joinpath(pkg, "test", "test_basics.jl"), String)
        lines = collect(eachline(IOBuffer(source)))

        # The macro call must be on a line that actually starts the test item.
        @test occursin("@testitem \"passing\"", lines[passing.line])
        # The code body starts at or after the macro call, never before it.
        @test passing.code_line >= passing.line
        @test occursin("BasicPkg.add_one(1) == 2", passing.code)
    end
end

@testitem "setups are carried through with their names" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        items, setups, _ = TestItemMCPApp.resolve_testitems(state)

        byname = Dict(s.name => s for s in setups)
        @test occursin("magic_number", byname["SharedFixture"].code)
        @test occursin("shared_value", byname["SharedSnippet"].code)
        # `kind` distinguishes a `@testmodule` from a `@testsnippet`.
        @test byname["SharedFixture"].kind != byname["SharedSnippet"].kind

        consumer = only(filter(i -> i.label == "uses setup", items))
        @test consumer.test_setups == ["SharedFixture"]

        plain = only(filter(i -> i.label == "passing", items))
        @test isempty(plain.test_setups)
    end
end

@testitem "default_imports option is carried through" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        items, _, _ = TestItemMCPApp.resolve_testitems(state)

        @test only(filter(i -> i.label == "passing", items)).option_default_imports
        @test !only(filter(i -> i.label == "no default imports", items)).option_default_imports
    end
end

@testitem "build_test_environments groups items by package" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        _, _, pkg_info = TestItemMCPApp.resolve_testitems(state)
        args = Dict{String,Any}("julia_cmd" => "julia", "mode" => "Coverage", "max_workers" => 3)
        envs, env_for_item, max_processes, coverage_roots, log_level =
            TestItemMCPApp.build_test_environments(args, pkg_info)

        @test length(envs) == 1
        @test only(envs).package_name == "BasicPkg"
        @test only(envs).mode == "Coverage"
        @test max_processes == 3
        @test coverage_roots === nothing
        @test log_level isa Symbol
        # Every item must map to an environment that actually exists.
        env_ids = Set(e.id for e in envs)
        @test !isempty(env_for_item)
        @test all(id -> id in env_ids, values(env_for_item))
        @test keys(env_for_item) == keys(pkg_info)
    end
end

@testitem "test environments drop the app shim's Julia env vars" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        _, _, pkg_info = TestItemMCPApp.resolve_testitems(state)
        envs, _, _, _, _ = TestItemMCPApp.build_test_environments(Dict{String,Any}(), pkg_info)

        # A `nothing` value makes TestItemControllers remove the variable from the
        # test process environment. Inheriting the shim's JULIA_LOAD_PATH would
        # leave the test process unable to load its own environment.
        for var in ("JULIA_LOAD_PATH", "JULIA_PROJECT", "JULIA_DEPOT_PATH")
            @test only(envs).julia_env[var] === nothing
        end
    end
end

@testitem "passes_filter" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JuliaWorkspaces, passes_filter

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        jw = JuliaWorkspaces.workspace_from_folders([pkg])
        state.workspace = jw

        uri, details = only(filter(p -> !isempty(p[2].testitems), collect(pairs(JuliaWorkspaces.get_test_items(jw)))))
        env = JuliaWorkspaces.get_test_env(jw, uri)
        byname = Dict(i.name => i for i in details.testitems)

        @test passes_filter(byname["also passing"], env, uri, Dict(:tags => ["fast"]))
        @test !passes_filter(byname["passing"], env, uri, Dict(:tags => ["fast"]))
        @test passes_filter(byname["failing"], env, uri, Dict(:tags => ["flaky"]))

        @test passes_filter(byname["passing"], env, uri, Dict(:name_pattern => "^passing\$"))
        @test !passes_filter(byname["failing"], env, uri, Dict(:name_pattern => "^passing\$"))
        # Name matching is case-insensitive.
        @test passes_filter(byname["passing"], env, uri, Dict(:name_pattern => "PASSING"))

        @test passes_filter(byname["passing"], env, uri, Dict(:file_pattern => "test_basics"))
        @test !passes_filter(byname["passing"], env, uri, Dict(:file_pattern => "nonexistent"))

        @test passes_filter(byname["passing"], env, uri, Dict(:package => "BasicPkg"))
        @test !passes_filter(byname["passing"], env, uri, Dict(:package => "OtherPkg"))

        @test passes_filter(byname["passing"], env, uri, Dict(:ids => Set([byname["passing"].id])))
        @test !passes_filter(byname["failing"], env, uri, Dict(:ids => Set([byname["passing"].id])))

        # Multiple criteria must all hold.
        @test !passes_filter(byname["passing"], env, uri, Dict(:tags => ["fast"], :package => "BasicPkg"))
    end
end

@testitem "build_filter" begin
    using TestItemMCPApp: build_filter

    @test build_filter(Dict{String,Any}()) === nothing
    @test build_filter(Dict{String,Any}("items" => nothing, "tags" => nothing)) === nothing

    f = build_filter(Dict{String,Any}(
        "items" => ["a", "b"],
        "tags" => ["fast"],
        "name_pattern" => "foo",
        "file_pattern" => "bar",
        "package" => "Pkg",
        "timeout" => 30,
    ))
    @test f[:ids] == Set(["a", "b"])
    @test f[:tags] == ["fast"]
    @test f[:name_pattern] == "foo"
    @test f[:file_pattern] == "bar"
    @test f[:package] == "Pkg"
    @test f[:timeout] == 30
end

@testitem "coverage_to_dicts matches the FileCoverage layout" begin
    using TestItemMCPApp: coverage_to_dicts
    using TestItemControllers: FileCoverage

    # Regression: this used to read `fc.lines`, which does not exist —
    # `FileCoverage` stores one entry per source line in `coverage`.
    coverage = [FileCoverage("file:///a.jl", Union{Int,Nothing}[nothing, 3, 0, nothing, 7])]
    dicts = coverage_to_dicts(coverage)

    result = only(dicts)
    @test result["uri"] == "file:///a.jl"
    @test result["lines"] == [
        Dict("line" => 2, "count" => 3),
        Dict("line" => 3, "count" => 0),
        Dict("line" => 5, "count" => 7),
    ]
    @test result["coverable_lines"] == 3
    @test result["covered_lines"] == 2

    @test coverage_to_dicts(FileCoverage[]) == Any[]
end

@testitem "collect_testitems_list reports metadata" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JuliaWorkspaces, collect_testitems_list

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        items = collect_testitems_list(state)
        @test length(items) == 7

        byname = Dict(i["name"] => i for i in items)
        @test byname["also passing"]["tags"] == ["fast"]
        @test sort(byname["failing"]["tags"]) == ["flaky", "slow"]
        @test byname["uses setup"]["setup_names"] == ["SharedFixture"]
        @test byname["passing"]["package_name"] == "BasicPkg"
        @test endswith(byname["passing"]["uri"], "test_basics.jl")
        @test byname["passing"]["line"] isa Int
    end
end

@testitem "collect_detection_errors surfaces malformed test items" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using TestItemMCPApp: JuliaWorkspaces, collect_detection_errors

    MCPTestHelpers.with_app_state() do state
        # No workspace configured yet.
        @test collect_detection_errors(state) == Any[]

        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])
        @test collect_detection_errors(state) == Any[]
    end
end

@testitem "resolve_testitems requires a workspace" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_app_state() do state
        @test_throws ErrorException TestItemMCPApp.resolve_testitems(state)
    end
end
