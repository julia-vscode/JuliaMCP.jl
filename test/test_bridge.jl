@testitem "discover produces valid source positions" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        d = JuliaMCP.discover(state)
        items = d.testitems
        setups = d.setups

        @test length(items) == 7
        @test length(setups) == 2

        for item in items
            @test item.line isa Int && item.line >= 1
            @test item.column isa Int && item.column >= 1
            @test item.detail.code_line isa Int && item.detail.code_line >= 1
            @test item.detail.code_column isa Int && item.detail.code_column >= 1
            @test item.package_name == "BasicPkg"
            @test !isempty(item.code)
            # Items are keyed by `(id, package_uri)`, since an id alone does not identify an
            # item when the same package is checked out into two folders of one workspace.
            @test JuliaMCP.TIR.key(item) == (item.id, item.package_uri)
        end

        for setup in setups
            @test setup.line isa Int && setup.line >= 1
            @test setup.column isa Int && setup.column >= 1
        end
    end
end

@testitem "line/column point at the macro call, code_line/code_column at the body" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        items = JuliaMCP.discover(state).testitems
        passing = only(filter(i -> i.name == "passing", items))

        source = read(joinpath(pkg, "test", "test_basics.jl"), String)
        lines = collect(eachline(IOBuffer(source)))

        # The macro call must be on a line that actually starts the test item.
        @test occursin("@testitem \"passing\"", lines[passing.line])
        # The code body starts at or after the macro call, never before it.
        @test passing.detail.code_line >= passing.line
        @test occursin("BasicPkg.add_one(1) == 2", passing.code)
    end
end

@testitem "setups are carried through with their names" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        d = JuliaMCP.discover(state)
        items, setups = d.testitems, d.setups

        byname = Dict(s.name => s for s in setups)
        @test occursin("magic_number", byname["SharedFixture"].code)
        @test occursin("shared_value", byname["SharedSnippet"].code)
        # `kind` distinguishes a `@testmodule` from a `@testsnippet`.
        @test byname["SharedFixture"].kind != byname["SharedSnippet"].kind

        consumer = only(filter(i -> i.name == "uses setup", items))
        @test consumer.setups == ["SharedFixture"]

        plain = only(filter(i -> i.name == "passing", items))
        @test isempty(plain.setups)
    end
end

@testitem "default_imports option is carried through" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JuliaWorkspaces

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        items = JuliaMCP.discover(state).testitems

        @test only(filter(i -> i.name == "passing", items)).detail.option_default_imports
        @test !only(filter(i -> i.name == "no default imports", items)).detail.option_default_imports
    end
end

@testitem "run_profile and run_options translate tool arguments" begin
    args = Dict{String,Any}("julia_cmd" => "julia", "mode" => "Coverage", "max_workers" => 3,
        "julia_num_threads" => "2", "julia_args" => Any["--check-bounds=yes"])
    profile = JuliaMCP.run_profile(args)
    @test profile.coverage
    @test !JuliaMCP.run_profile(Dict{String,Any}()).coverage
    opts = JuliaMCP.run_options(args)
    @test opts.max_workers == 3
    @test opts.julia_cmd == "julia"
    @test opts.julia_num_threads == "2"
    @test opts.julia_args == ["--check-bounds=yes"]
    @test JuliaMCP.run_options(Dict{String,Any}()).julia_num_threads === nothing
    @test JuliaMCP.run_options(Dict{String,Any}()).max_workers == JuliaMCP.TIR.default_max_workers()
end

@testitem "test processes drop the app shim's Julia env vars" begin
    # A `nothing` value makes TestItemControllers remove the variable from the test
    # process environment. Inheriting the shim's JULIA_LOAD_PATH would leave the test
    # process unable to load its own environment. TestItemRuns does this for every profile.
    env = JuliaMCP.TIR._child_env(JuliaMCP.run_profile(Dict{String,Any}()))
    for var in ("JULIA_LOAD_PATH", "JULIA_PROJECT", "JULIA_DEPOT_PATH")
        @test env[var] === nothing
    end
    # Julia sessions get the same overrides explicitly.
    for var in ("JULIA_LOAD_PATH", "JULIA_PROJECT", "JULIA_DEPOT_PATH")
        @test JuliaMCP.shim_env_overrides()[var] === nothing
    end
end

@testitem "passes_filter" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JuliaWorkspaces, passes_filter

    MCPTestHelpers.with_app_state() do state
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        jw = JuliaWorkspaces.workspace_from_folders([pkg])
        state.workspace = jw

        byname = Dict(i.name => i for i in JuliaMCP.discover(state).testitems)

        @test passes_filter(byname["also passing"], Dict(:tags => ["fast"]))
        @test !passes_filter(byname["passing"], Dict(:tags => ["fast"]))
        @test passes_filter(byname["failing"], Dict(:tags => ["flaky"]))

        @test passes_filter(byname["passing"], Dict(:name_pattern => "^passing\$"))
        @test !passes_filter(byname["failing"], Dict(:name_pattern => "^passing\$"))
        # Name matching is case-insensitive.
        @test passes_filter(byname["passing"], Dict(:name_pattern => "PASSING"))

        @test passes_filter(byname["passing"], Dict(:file_pattern => "test_basics"))
        @test !passes_filter(byname["passing"], Dict(:file_pattern => "nonexistent"))

        @test passes_filter(byname["passing"], Dict(:package => "BasicPkg"))
        @test !passes_filter(byname["passing"], Dict(:package => "OtherPkg"))

        @test passes_filter(byname["passing"], Dict(:ids => Set([byname["passing"].id])))
        @test !passes_filter(byname["failing"], Dict(:ids => Set([byname["passing"].id])))

        # Multiple criteria must all hold.
        @test !passes_filter(byname["passing"], Dict(:tags => ["fast"], :package => "BasicPkg"))
    end
end

@testitem "build_filter" begin
    using JuliaMCP: build_filter

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
    using JuliaMCP: coverage_to_dicts
    using TestItemRuns: TestrunResultFileCoverage as FileCoverage

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
    using JuliaMCP: JuliaWorkspaces, collect_testitems_list

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
        # 1-based line/column, not the raw byte offset into the file.
        @test byname["passing"]["line"] == 9
        @test byname["passing"]["column"] == 1
        @test byname["no default imports"]["line"] == 36
    end
end

@testitem "collect_detection_errors surfaces malformed test items" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JuliaWorkspaces, collect_detection_errors

    MCPTestHelpers.with_app_state() do state
        # No workspace configured yet.
        @test collect_detection_errors(state) == Any[]

        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])
        @test collect_detection_errors(state) == Any[]
    end
end

@testitem "collect_detection_errors reports line positions" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JuliaWorkspaces, collect_detection_errors

    MCPTestHelpers.with_app_state() do state
        pkg = MCPTestHelpers.copy_testdata("BasicPkg")
        write(joinpath(pkg, "test", "test_bad.jl"), """
        # a comment
        @testitem "bad kwarg" nonsense=1 begin
            @test true
        end
        """)
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])

        errors = collect_detection_errors(state)
        err = only(errors)
        # 1-based line number, not the raw byte offset into the file.
        @test err["line"] == 2
        @test err["column"] == 1
        @test err["range"]["start"]["line"] == 2
        @test err["range"]["stop"]["line"] == 4
    end
end

@testitem "discover requires a workspace" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_app_state() do state
        @test_throws ErrorException JuliaMCP.discover(state)
    end
end

@testitem "memory_threshold is validated and passed through" begin
    using JuliaMCP: memory_threshold_of, run_options

    @test isnothing(memory_threshold_of(Dict{String,Any}()))
    @test memory_threshold_of(Dict{String,Any}("memory_threshold" => 0.25)) === 0.25
    # An integer fraction is fine at the boundary, and comes back as a Float64.
    @test memory_threshold_of(Dict{String,Any}("memory_threshold" => 1)) === 1.0
    @test run_options(Dict{String,Any}("memory_threshold" => 0.5)).memory_threshold === 0.5
    @test isnothing(run_options(Dict{String,Any}()).memory_threshold)

    # Out of range, and `true` is not a fraction: rejected rather than silently ignored,
    # which is what the test process would do with it.
    for bad in (0, -0.1, 1.5, true)
        @test_throws "memory_threshold must be a fraction greater than 0 and at most 1" memory_threshold_of(Dict{String,Any}("memory_threshold" => bad))
    end
end
