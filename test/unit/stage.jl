using Test
using DistSSHRun
using DistSSHQueue

@testset "old rsync refuses a remote path with shell characters" begin
    plain = "/home/q/.distsshqueue/stage/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    spaced = "/home/q/my jobs/stage"
    DistSSHQueue._refuse_unprotected_rsync_path!(spaced; version = v"3.2.4")
    DistSSHQueue._refuse_unprotected_rsync_path!(plain; version = v"2.6.9")
    DistSSHQueue._refuse_unprotected_rsync_path!("~/.distsshqueue/stage/job"; version = v"2.6.9")
    for kept in ("results/run#1", "a!b", "x{y}", "file].txt")
        DistSSHQueue._refuse_unprotected_rsync_path!(kept; version = v"2.6.9")
    end
    DistSSHQueue._refuse_unprotected_rsync_path!("x{a,b}"; version = v"3.2.4")
    @test_throws ArgumentError DistSSHQueue._refuse_unprotected_rsync_path!(
        spaced; version = v"2.6.9",
    )
    for bad in ("/tmp/a;rm", "x{a,b}", "x{a..b}", "dir/(a)", "dir/a*b", "dir/a[b")
        @test_throws ArgumentError DistSSHQueue._refuse_unprotected_rsync_path!(
            bad; version = v"2.6.9",
        )
    end
    DistSSHQueue._refuse_unprotected_rsync_path!(spaced; version = nothing)
    ver = DistSSHQueue.local_rsync_version()
    @test ver === nothing || ver isa VersionNumber
end

@testset "unwritten stage is removed only at the stage uuid path" begin
    id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    mktempdir() do home
        stage = joinpath(home, ".distsshqueue", "stage", id)
        mkpath(stage)
        write(joinpath(stage, "keep.txt"), "x\n")
        store = joinpath(home, ".distsshqueue", "jobs.toml")
        withenv("HOME" => home) do
            DistSSHQueue.drop_unwritten_stage!(id, store)
        end
        @test !ispath(stage)
        mkpath(stage)
        write(joinpath(stage, "keep.txt"), "x\n")
        j = DistSSHQueue.Job(;
            id = id, kind = :go, script = "a.jl", hosts = ["parent:1"],
        )
        DistSSHQueue.save_jobs(store, [j])
        withenv("HOME" => home) do
            DistSSHQueue.drop_unwritten_stage!(id, store)
        end
        @test isfile(joinpath(stage, "keep.txt"))
        outside = joinpath(home, "not-stage")
        mkpath(outside)
        withenv("HOME" => home) do
            DistSSHQueue.drop_unwritten_stage!("../not-stage", store)
            DistSSHQueue.drop_unwritten_stage!("", store)
        end
        @test isdir(outside)
        @test DistSSHQueue.orphan_stage_path(id; home = home) == abspath(stage)
        @test DistSSHQueue.orphan_stage_path("../not-stage"; home = home) === nothing
        script = joinpath(home, "S.jl")
        write(script, "1\n")
        mkpath(stage)
        write(joinpath(stage, "keep.txt"), "x\n")
        withenv("HOME" => home, DistSSHQueue.JOB_ID_ENV => id) do
            @test_throws ArgumentError DistSSHQueue.submit_cli(
                store, :go, script, ["parent:1"], Dict{String, Any}(),
            )
        end
        @test isfile(joinpath(stage, "keep.txt"))
        rm(store; force = true)
        withenv("HOME" => home, DistSSHQueue.JOB_ID_ENV => id) do
            @test_throws ArgumentError DistSSHQueue.submit_cli(
                store, :go, script, ["parent:1"], Dict{String, Any}(),
            )
        end
        @test !ispath(stage)
        mkpath(stage)
        write(joinpath(stage, "keep.txt"), "x\n")
        withenv("HOME" => home, DistSSHQueue.JOB_ID_ENV => id) do
            @test_throws ArgumentError DistSSHQueue.submit_main(["pool:1", "go", script])
        end
        @test !ispath(stage)
        mkpath(stage)
        write(joinpath(stage, "keep.txt"), "x\n")
        j = DistSSHQueue.Job(;
            id = id, kind = :go, script = "a.jl", hosts = ["parent:1"],
        )
        DistSSHQueue.save_jobs(store, [j])
        withenv("HOME" => home, DistSSHQueue.JOB_ID_ENV => id) do
            @test_throws ArgumentError DistSSHQueue.submit_main(["go", joinpath(home, "missing.jl")])
        end
        @test isfile(joinpath(stage, "keep.txt"))
        rm(store; force = true)
        write(joinpath(home, ".distsshqueue", "config.toml"), "[\n")
        withenv("HOME" => home, DistSSHQueue.JOB_ID_ENV => id) do
            @test_throws ArgumentError DistSSHQueue.submit_main(["go", script])
        end
        @test !ispath(stage)
    end
end

@testset "qhost stage path rewrite" begin
    mktempdir() do d
        proj = joinpath(d, "job")
        mkpath(proj)
        script = joinpath(proj, "S.jl")
        write(script, "1\n")
        outdir = joinpath(proj, "out", "x")
        remote = "~/.distsshqueue/stage/abc"
        payload = [
            "go",
            "child:w:1",
            "--output-dir",
            outdir,
            "S.jl",
        ]
        got = DistSSHQueue.rewrite_payload_paths(payload, proj, remote)
        @test got[1] == "go"
        @test got[2] == "child:w:1"
        @test got[3] == "--output-dir"
        @test got[4] == remote * "/out/x"
        @test got[5] == remote * "/S.jl"
        @test DistSSHQueue.rewrite_one_path("parent:1", proj, remote) == "parent:1"
        @test DistSSHQueue.remote_stage_root("abc") == remote
        k = DistSSHQueue.new_job_id()
        @test DistSSHQueue.new_job_id() != k
        @test occursin(r"^[0-9a-fA-F-]{36}$", k)
        @test DistSSHQueue.remote_stage_root(k; home = "/qh") == "/qh/.distsshqueue/stage/" * k
    end
    @test !DistSSHQueue.should_stage("status", ["--interval", "1"])
    @test DistSSHQueue.should_submit_ticket("submit", ["go", "S.jl"])
    @test !DistSSHQueue.should_submit_ticket("go", ["S.jl"])
    @test !DistSSHQueue.should_submit_ticket("status", ["--interval", "1"])
    withenv(DistSSHQueue.NO_STAGE_ENV => "1") do
        @test !DistSSHQueue.staging_enabled()
        @test !DistSSHQueue.should_stage("submit", ["go", "S.jl"])
        @test DistSSHQueue.should_submit_ticket("submit", ["go", "S.jl"])
    end
    withenv("DISTRIBUTED_SSH_OPTS" => "-F \"/tmp/cfg dir/config\" -o BatchMode=yes") do
        t = DistSSHQueue._ssh_transport()
        @test startswith(t, "ssh ")
        @test occursin(Base.shell_escape("/tmp/cfg dir/config"), t)
    end
    buf = IOBuffer()
    DistSSHQueue.print_ship_tree_start("qh", "/Users/me/.distsshqueue/stage/abc"; io = buf)
    @test occursin("ship-tree → qh:", String(take!(buf)))
    buf2 = IOBuffer()
    DistSSHQueue.print_rsync_start("qh", "/tmp/leaf"; pulling = true, io = buf2)
    @test occursin("rsync ← qh:", String(take!(buf2)))
    withenv("DISTSSH_QUIET" => "1") do
        bufq = IOBuffer()
        DistSSHQueue.print_ship_tree_start("qh", "/x"; io = bufq)
        @test isempty(String(take!(bufq)))
        @test !DistSSHQueue.rsync_progress_on(["--progress"])
    end
    withenv("DISTSSH_QUIET" => nothing, "DISTSSH_PROGRESS" => "1") do
        @test DistSSHQueue.rsync_progress_on()
    end
    withenv("DISTSSH_QUIET" => nothing, "DISTSSH_PROGRESS" => nothing) do
        @test !DistSSHQueue.rsync_progress_on()
        @test DistSSHQueue.rsync_progress_on(["go", "--progress", "S.jl"])
    end

    @testset "stage follows the manifest directory" begin
        mktempdir() do root
            lab = joinpath(root, "lab")
            member = joinpath(lab, "experiments", "run1")
            mkpath(member)
            write(
                joinpath(lab, "Project.toml"),
                """
                name = "Lab"
                [workspace]
                projects = ["experiments/run1"]
                """,
            )
            write(joinpath(lab, "Manifest.toml"), "# lock\n")
            write(joinpath(member, "Project.toml"), "name = \"Run1\"\n[deps]\n")
            script = joinpath(member, "S.jl")
            write(script, "1\n")
            remote = "~/.distsshqueue/stage/abc"
            layout = DistSSHQueue.stage_env_and_project(member, remote)
            @test layout.env_dir == DistSSHQueue.canonical_local_path(lab)
            @test layout.remote_proj == remote * "/experiments/run1"
            got = DistSSHQueue.rewrite_payload_paths(
                ["go", "--project", member, script],
                layout.env_dir,
                remote,
            )
            @test got[3] == remote * "/experiments/run1"
            @test got[4] == remote * "/experiments/run1/S.jl"
            solo = joinpath(root, "solo")
            mkpath(solo)
            write(joinpath(solo, "Project.toml"), "name = \"Solo\"\n[deps]\n")
            same = DistSSHQueue.stage_env_and_project(solo, remote)
            @test same.env_dir == DistSSHQueue.canonical_local_path(solo)
            @test same.remote_proj == remote
        end
    end
    @testset "stage ship send list matches pack" begin
        mktempdir() do tmp::String
            write_min_stage_project!(tmp)
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.email test@example.com`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.name Test`; stdout = devnull, stderr = devnull))
            write(joinpath(tmp, ".gitignore"), "*/\n!keep/\n")
            mkpath(joinpath(tmp, "keep"))
            write(joinpath(tmp, "keep", "a.txt"), "x\n")
            mkpath(joinpath(tmp, "build"))
            mkpath(joinpath(tmp, ".distsshqueue"))
            write(joinpath(tmp, ".distsshqueue", "ticket"), "nope\n")
            write(joinpath(tmp, ".distsshqueue-backup"), "keep\n")
            listed = DistSSHRun.ship_send_list(tmp)
            @test "keep" in listed
            @test "keep/a.txt" in listed
            @test !("build" in listed)
            @test ".distsshqueue-backup" in listed
            @test !any(".distsshqueue" in split(rel, '/') for rel in listed)
        end
    end

    @testset "pack errors on gitignored Manifest-v1.13.0.toml" begin
        mktempdir() do tmp::String
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
            write(joinpath(tmp, "Manifest-v1.13.0.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
            write(joinpath(tmp, ".gitignore"), "Manifest-v1.13.0.toml\n")
            write(joinpath(tmp, "keep.jl"), "1\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.email test@example.com`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.name Test`; stdout = devnull, stderr = devnull))
            err = nothing
            try
                DistSSHQueue._pack_ship_tree_with_warnings(tmp)
            catch e
                err = e
            end
            @test err isa ArgumentError
            msg = sprint(showerror, err)
            @test occursin("Manifest-v1.13.0.toml", msg)
            @test occursin("will not be shipped", msg)
        end
    end

    @testset "ship pack uses fake ssh (stdin tar)" begin
        mktempdir() do state::String
            mktempdir() do tmp::String
                bin = joinpath(tmp, "bin")
                mkpath(bin)
                shelllog = joinpath(tmp, "shell-ssh.log")
                write(shelllog, "")
                write(
                    joinpath(bin, "ssh"),
                    """
                    #!/bin/sh
                    printf '%s\\n' "\$@" >> "\$FAKE_SHELL_SSH_LOG"
                    exit 0
                    """,
                )
                chmod(joinpath(bin, "ssh"), 0o755)
                sshlog = joinpath(tmp, "ssh-scripts.log")
                write(sshlog, "")
                proj = joinpath(tmp, "gitproj")
                mkpath(proj)
                write_min_stage_project!(proj)
                write(joinpath(proj, "a.txt"), "x\n")
                run(pipeline(`git -C $proj init -q`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $proj config user.email test@example.com`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $proj config user.name Test`; stdout = devnull, stderr = devnull))
                env = merge(
                    fake_ship_remote_env(state),
                    Dict(
                        "DISTSSH_TEST_SSH_LOG" => sshlog,
                        "FAKE_SHELL_SSH_LOG" => shelllog,
                        "PATH" => bin * ":" * get(ENV, "PATH", ""),
                    ),
                )
                pack = DistSSHRun.pack_ship_tree(proj)
                hash = pack.content_tree_hash
                rm(pack.directory; force = true, recursive = true)
                withenv(merge(env, Dict("DISTSSH_TEST_EXPECT_TREE_HASH" => hash))...) do
                    got_hash, _ = DistSSHQueue.ship_tree_to_qhost!(
                        "qh", proj, "/stage/git", String[], "auto", "job-1"; write_record = false,
                    )
                    @test got_hash == hash
                end
                log = read(sshlog, String)
                @test occursin("Tar.extract", log)
                shell = read(shelllog, String)
                @test occursin("mkdir -p", shell)
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
            end
        end
        mktempdir() do state::String
            mktempdir() do tmp::String
                bin = joinpath(tmp, "bin")
                mkpath(bin)
                write(joinpath(bin, "ssh"), "#!/bin/sh\nexit 0\n")
                chmod(joinpath(bin, "ssh"), 0o755)
                proj = joinpath(tmp, "plain")
                mkpath(proj)
                write_min_stage_project!(proj)
                env = merge(
                    fake_ship_remote_env(state),
                    Dict(
                        "DISTSSH_TEST_TAR_EXTRACT_FAIL" => "1",
                        "PATH" => bin * ":" * get(ENV, "PATH", ""),
                    ),
                )
                withenv(env...) do
                    @test_throws ArgumentError DistSSHQueue.ship_tree_to_qhost!(
                        "qh", proj, "/stage/fail", String[], "auto", "job-2"; write_record = false,
                    )
                end
            end
        end
        mktempdir() do state::String
            mktempdir() do tmp::String
                mkpath(tmp)
                write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
                withenv(fake_ship_remote_env(state)...) do
                    @test_throws ArgumentError DistSSHQueue.ship_tree_to_qhost!(
                        "qh", tmp, "/stage/noman", String[], "auto", "job-3"; write_record = false,
                    )
                end
            end
        end
    end

    fetch_h = sprint(io -> DistSSHQueue.print_queue_command_usage(io, "fetch"))
    @test occursin("--progress", fetch_h)
    @test occursin("progress2", fetch_h)
end

@testset "kit_verb_and_args splits submit" begin
    kit, args = DistSSHQueue.kit_verb_and_args("submit", ["go", "a.jl", "parent:1"])
    @test kit == "go"
    @test args == ["a.jl", "parent:1"]
    kit2, args2 = DistSSHQueue.kit_verb_and_args("drive", ["job.jl"])
    @test kit2 == "drive"
    @test args2 == ["job.jl"]
    @test_throws ArgumentError DistSSHQueue.kit_verb_and_args("submit", String[])
    @test_throws ArgumentError DistSSHQueue.kit_verb_and_args("submit", ["nope"])
end

@testset "rsync pull records argv and caches 3.2.7" begin
    mktempdir() do tmp::String
        bin = joinpath(tmp, "bin")
        mkpath(bin)
        rsynclog = joinpath(tmp, "rsync.log")
        write(
            joinpath(bin, "rsync"),
            """
            #!/bin/sh
            if [ "\$1" = "--version" ]; then
              echo "rsync  version 3.2.7  protocol version 31"
              exit 0
            fi
            printf '%s\\n' "\$@" >> "\$FAKE_RSYNC_LOG"
            exit 0
            """,
        )
        chmod(joinpath(bin, "rsync"), 0o755)
        try
            DistSSHQueue._RSYNC_VER_READY[] = false
            withenv(
                "PATH" => bin * ":" * get(ENV, "PATH", ""),
                "FAKE_RSYNC_LOG" => rsynclog,
            ) do
                DistSSHQueue.rsync_from_qhost!("qh", "/remote/out", joinpath(tmp, "dest"))
                DistSSHQueue.rsync_from_qhost_file!(
                    "qh", "/remote/file.txt", joinpath(tmp, "file.txt"); progress = true,
                )
                DistSSHQueue.rsync_from_qhost!("qh", "/remote/a b", joinpath(tmp, "space"))
                return nothing
            end
            @test DistSSHQueue.local_rsync_version() == v"3.2.7"
        finally
            DistSSHQueue._RSYNC_VER_READY[] = false
        end
        log = read(rsynclog, String)
        @test occursin("qh:/remote/out/", log)
        @test occursin("qh:/remote/file.txt\n", log)
        @test occursin("--info=progress2", log)
        @test occursin("qh:/remote/a b", log)
    end
end

@testset "hop_print uses shell ssh on PATH" begin
    mktempdir() do tmp::String
        bin = joinpath(tmp, "bin")
        mkpath(bin)
        write(
            joinpath(bin, "ssh"),
            """
            #!/bin/sh
            echo /tmp/fakehome
            exit 0
            """,
        )
        chmod(joinpath(bin, "ssh"), 0o755)
        env = Dict("PATH" => bin * ":" * get(ENV, "PATH", ""))
        home = withenv(env...) do
            return DistSSHQueue.hop_print("qh", "/opt/julia", "print(homedir())")
        end
        @test home == "/tmp/fakehome"
    end
end

@testset "ship failure before submit does not enqueue" begin
    mktempdir() do state::String
        mktempdir() do home
            store = joinpath(home, ".distsshqueue", "jobs.toml")
            proj = joinpath(home, "job")
            mkpath(proj)
            write_min_stage_project!(proj)
            write(joinpath(proj, "job.jl"), "1\n")
            bin = joinpath(home, "bin")
            mkpath(bin)
            write(
                joinpath(bin, "ssh"),
                "#!/bin/sh\nexit 0\n",
            )
            chmod(joinpath(bin, "ssh"), 0o755)
            env = merge(
                fake_ship_remote_env(state; remote_home = home),
                Dict(
                    "DISTSSH_TEST_TAR_EXTRACT_FAIL" => "1",
                    "HOME" => home,
                    "DISTRIBUTED_PROJECT_ROOT" => proj,
                    "PATH" => bin * ":" * get(ENV, "PATH", ""),
                ),
            )
            withenv(env...) do
                @test_throws ArgumentError DistSSHQueue.stage_job_tree!(
                    "qh", "auto", "submit", ["go", "job.jl", "parent:1"],
                )
            end
            @test !isfile(store)
        end
    end
end

function _source_git!(dir::String)
    run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir config user.name "Test"`; stdout = devnull, stderr = devnull))
    write(joinpath(dir, "f.txt"), "hi\n")
    run(pipeline(`git -C $dir add -A`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir -c commit.gpgsign=false commit -q -m init`; stdout = devnull, stderr = devnull))
    return nothing
end

@testset "qhost submit source env" begin
    mktempdir() do tmp
        @test isempty(DistSSHQueue.queue_source_env(tmp))
    end
    Sys.which("git") === nothing && return
    mktempdir() do repo
        write(joinpath(repo, "Project.toml"), "name = \"App\"\n")
        _source_git!(repo)
        clean = DistSSHQueue.queue_source_env(repo)
        head = readchomp(`git -C $repo rev-parse HEAD`)
        snap = DistSSHRun.git_source_snapshot(repo)
        @test snap isa Dict
        @test clean[DistSSHQueue.SOURCE_COMMIT_ENV] == head
        @test clean[DistSSHQueue.SOURCE_DIRTY_ENV] == "false"
        if snap isa Dict
            @test clean[DistSSHQueue.SOURCE_DIFF_SHA256_ENV] == snap["diff_sha256"]
        end
        @test startswith(clean[DistSSHQueue.SOURCE_CAPTURED_ENV], "submit:")
        @test clean[DistSSHQueue.SOURCE_CAPTURED_ENV] == "submit:" * gethostname()
        @test clean[DistSSHQueue.SOURCE_UNTRACKED_ENV] == "0"
        write(joinpath(repo, "f.txt"), "changed\n")
        dirty = DistSSHQueue.queue_source_env(repo)
        dirty_snap = DistSSHRun.git_source_snapshot(repo)
        @test dirty_snap isa Dict
        @test dirty[DistSSHQueue.SOURCE_DIRTY_ENV] == "true"
        @test dirty[DistSSHQueue.SOURCE_UNTRACKED_ENV] == "0"
        if dirty_snap isa Dict
            @test dirty[DistSSHQueue.SOURCE_DIFF_SHA256_ENV] == dirty_snap["diff_sha256"]
        end
        @test dirty[DistSSHQueue.SOURCE_DIFF_SHA256_ENV] != clean[DistSSHQueue.SOURCE_DIFF_SHA256_ENV]
        write(joinpath(repo, "f.txt"), "hi\n")
        write(joinpath(repo, "extra.txt"), "x\n")
        only_new = DistSSHQueue.queue_source_env(repo)
        @test only_new[DistSSHQueue.SOURCE_DIRTY_ENV] == "true"
        @test parse(Int, only_new[DistSSHQueue.SOURCE_UNTRACKED_ENV]) >= 1
        @test only_new[DistSSHQueue.SOURCE_DIFF_SHA256_ENV] == clean[DistSSHQueue.SOURCE_DIFF_SHA256_ENV]
        rm(joinpath(repo, "extra.txt"))
        mkpath(joinpath(repo, ".distsshqueue", "tickets"))
        write(joinpath(repo, ".distsshqueue", "tickets", "j"), "t\n")
        mkpath(joinpath(repo, ".distsshkit"))
        write(joinpath(repo, ".distsshkit", "provenance.toml"), "x\n")
        kit_only = DistSSHQueue.queue_source_env(repo)
        @test kit_only[DistSSHQueue.SOURCE_DIRTY_ENV] == "false"
        @test kit_only[DistSSHQueue.SOURCE_UNTRACKED_ENV] == "0"
        run(pipeline(`git -C $repo mv f.txt g.txt`; stdout = devnull, stderr = devnull))
        moved = DistSSHQueue.queue_source_env(repo)
        @test moved[DistSSHQueue.SOURCE_DIRTY_ENV] == "true"
        @test moved[DistSSHQueue.SOURCE_UNTRACKED_ENV] == "0"
        withenv("PATH" => "/nonexistent-distsshqueue-path") do
            @test isempty(DistSSHQueue.queue_source_env(repo))
        end
    end
end
