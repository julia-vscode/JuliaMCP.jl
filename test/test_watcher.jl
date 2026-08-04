@testitem "is_watched_path" begin
    using JuliaMCP: is_watched_path

    @test is_watched_path("/a/b/foo.jl")
    @test is_watched_path("/a/b/Project.toml")
    @test is_watched_path("/a/b/Manifest.toml")
    @test is_watched_path("/a/b/JuliaLint.toml")
    @test is_watched_path("/a/b/JuliaFormat.toml")

    @test !is_watched_path("/a/b/README.md")
    @test !is_watched_path("/a/b/data.csv")
    @test !is_watched_path("/a/b/notes.txt")
end

@testitem "scan_folders finds relevant files and skips noise" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: scan_folders

    dir = mktempdir()
    write(joinpath(dir, "a.jl"), "x = 1")
    write(joinpath(dir, "Project.toml"), "name = \"X\"")
    write(joinpath(dir, "notes.md"), "hi")
    mkpath(joinpath(dir, "sub"))
    write(joinpath(dir, "sub", "b.jl"), "y = 2")
    mkpath(joinpath(dir, ".git"))
    write(joinpath(dir, ".git", "hidden.jl"), "nope")
    mkpath(joinpath(dir, "node_modules"))
    write(joinpath(dir, "node_modules", "vendor.jl"), "nope")

    snapshot = scan_folders([dir])
    names = sort(basename.(collect(keys(snapshot))))

    @test names == ["Project.toml", "a.jl", "b.jl"]
    @test all(v -> v isa Float64, values(snapshot))

    # Non-existent folders are ignored rather than throwing.
    @test isempty(scan_folders([joinpath(dir, "does-not-exist")]))
end

@testitem "diff_snapshots" begin
    using JuliaMCP: diff_snapshots

    old = Dict("a" => 1.0, "b" => 2.0, "c" => 3.0)
    new = Dict("a" => 1.0, "b" => 9.0, "d" => 4.0)

    created, modified, deleted = diff_snapshots(old, new)
    @test created == ["d"]
    @test modified == ["b"]
    @test deleted == ["c"]

    same = diff_snapshots(old, old)
    @test all(isempty, same)
end

@testitem "watcher picks up new, changed and deleted files" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    pkg = MCPTestHelpers.copy_testdata("BasicPkg")
    extra = joinpath(pkg, "test", "test_extra.jl")

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch_interval" => 0.05))
        @test length(MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testitems"))) == 7

        write(extra, "@testitem \"from watcher\" begin\n    @test true\nend\n")
        @test MCPTestHelpers.timed_wait(20.0) do
            names = [i["name"] for i in MCPTestHelpers.result_json(
                MCPTestHelpers.call_tool(client, "julia_list_testitems"))]
            "from watcher" in names
        end

        write(extra, "@testitem \"renamed by watcher\" begin\n    @test true\nend\n")
        @test MCPTestHelpers.timed_wait(20.0) do
            names = [i["name"] for i in MCPTestHelpers.result_json(
                MCPTestHelpers.call_tool(client, "julia_list_testitems"))]
            "renamed by watcher" in names && !("from watcher" in names)
        end

        rm(extra)
        @test MCPTestHelpers.timed_wait(20.0) do
            length(MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testitems"))) == 7
        end
    end
end

@testitem "watcher notifies subscribers" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    pkg = MCPTestHelpers.copy_testdata("BasicPkg")

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch_interval" => 0.05))
        MCPTestHelpers.subscribe(client, "workspace://testitems")
        MCPTestHelpers.drain_notifications(client)

        write(joinpath(pkg, "test", "test_notify.jl"), "@testitem \"notify\" begin\n    @test true\nend\n")

        msg = MCPTestHelpers.wait_for_notification(client, "notifications/resources/updated"; timeout=20.0)
        @test msg !== nothing
        @test msg.params["uri"] == "workspace://testitems"
    end
end

@testitem "rapid writes are coalesced into one refresh" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    pkg = MCPTestHelpers.copy_testdata("BasicPkg")

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch_interval" => 0.05))
        MCPTestHelpers.subscribe(client, "workspace://testitems")
        MCPTestHelpers.drain_notifications(client)

        for i in 1:5
            write(joinpath(pkg, "test", "burst_$i.jl"), "@testitem \"burst $i\" begin\n    @test true\nend\n")
        end

        @test MCPTestHelpers.timed_wait(20.0) do
            length(MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testitems"))) == 12
        end

        # The debounce window should fold the burst into a small number of batches,
        # not one notification per file.
        updates = filter(m -> m.method == "notifications/resources/updated",
            MCPTestHelpers.drain_notifications(client))
        @test length(updates) < 5
    end
end

@testitem "watching can be disabled" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    # `watch` and `julia_update_file` are both unadvertised; this covers the internal path
    # embedders use when they drive refreshes themselves.
    pkg = MCPTestHelpers.copy_testdata("BasicPkg")

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false, "watch_interval" => 0.05))

        write(joinpath(pkg, "test", "test_ignored.jl"), "@testitem \"ignored\" begin\n    @test true\nend\n")
        sleep(1.0)

        items = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testitems"))
        @test length(items) == 7

        # The manual escape hatch still works.
        MCPTestHelpers.call_tool(client, "julia_update_file",
            Dict{String,Any}("path" => joinpath(pkg, "test", "test_basics.jl")))
        @test length(MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testitems"))) == 7
    end
end

@testitem "watcher stops when the workspace is reconfigured" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    first_pkg = MCPTestHelpers.copy_testdata("BasicPkg")
    second_pkg = MCPTestHelpers.copy_testdata("BasicPkg")

    MCPTestHelpers.with_app_state() do state
        state.folders = [first_pkg]
        JuliaMCP.start_watcher!(state; interval=0.05)
        first_task = state.watcher_task
        @test first_task !== nothing

        state.folders = [second_pkg]
        JuliaMCP.start_watcher!(state; interval=0.05)
        @test state.watcher_task !== first_task
        @test MCPTestHelpers.timed_wait(() -> istaskdone(first_task), 10.0)

        second_task = state.watcher_task
        JuliaMCP.stop_watcher!(state)
        @test state.watcher_task === nothing
        @test MCPTestHelpers.timed_wait(() -> istaskdone(second_task), 10.0)
    end
end

@testitem "apply_file_changes! tolerates unreadable paths" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JuliaWorkspaces, apply_file_changes!

    pkg = MCPTestHelpers.copy_testdata("BasicPkg")

    MCPTestHelpers.with_app_state() do state
        state.workspace = JuliaWorkspaces.workspace_from_folders([pkg])
        state.folders = [pkg]

        # A file that never existed must not take the watcher down.
        @test apply_file_changes!(state, [joinpath(pkg, "ghost.jl")], String[], String[]) == 0
        # Removing a file the workspace never knew about is a no-op.
        @test apply_file_changes!(state, String[], String[], [joinpath(pkg, "ghost.jl")]) == 0
    end
end
