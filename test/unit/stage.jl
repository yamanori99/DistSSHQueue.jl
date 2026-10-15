using Test
using DistSSHRun
using DistSSHQueue

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
    opts = DistSSHQueue.stage_rsync_push_opts("ssh -o BatchMode=yes")
    @test opts[1] == "-az"
    @test !("--info=progress2" in opts)
    @test ":- .gitignore" in opts
    @test ".distsshqueue/" in opts
    @test ".distsshkit/" in opts
    @test ".git/" in opts
    @test "--info=progress2" in DistSSHQueue.stage_rsync_push_opts("ssh"; progress = true)
    buf = IOBuffer()
    DistSSHQueue.print_rsync_start("qh", "/Users/me/.distsshqueue/stage/abc"; io = buf)
    @test occursin("rsync → qh:", String(take!(buf)))
    buf2 = IOBuffer()
    DistSSHQueue.print_rsync_start("qh", "/tmp/leaf"; pulling = true, io = buf2)
    @test occursin("rsync ← qh:", String(take!(buf2)))
    withenv("DISTSSHKIT_QUIET" => "1") do
        bufq = IOBuffer()
        DistSSHQueue.print_rsync_start("qh", "/x"; io = bufq)
        @test isempty(String(take!(bufq)))
        @test !DistSSHQueue.rsync_progress_on(["--progress"])
    end
    withenv("DISTSSHKIT_QUIET" => nothing, "DISTSSHKIT_PROGRESS" => "1") do
        @test DistSSHQueue.rsync_progress_on()
    end
    withenv("DISTSSHKIT_QUIET" => nothing, "DISTSSHKIT_PROGRESS" => nothing) do
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
    @testset "stage send list matches setup --rsync" begin
        mktempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            @test DistSSHQueue.stage_send_list(tmp) === nothing
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.email test@example.com`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.name Test`; stdout = devnull, stderr = devnull))
            write(joinpath(tmp, ".gitignore"), "*/\n!keep/\n")
            mkpath(joinpath(tmp, "keep"))
            write(joinpath(tmp, "keep", "a.txt"), "x\n")
            mkpath(joinpath(tmp, "build"))
            mkpath(joinpath(tmp, ".distsshqueue"))
            write(joinpath(tmp, ".distsshqueue", "ticket"), "nope\n")
            mkpath(joinpath(tmp, "keep", ".distsshqueue"))
            write(joinpath(tmp, "keep", ".distsshqueue", "nested"), "nope\n")
            env = DistSSHRun.resolve_pkg_env(tmp)
            want = String[
                rel for rel in DistSSHRun.rsync_send_list(env.env_dir, env)
                    if !(".distsshqueue" in split(rel, '/'))
            ]
            listed = DistSSHQueue.stage_send_list(tmp)
            @test listed == want
            @test "keep" in listed
            @test "keep/a.txt" in listed
            @test !("build" in listed)
            @test !any(".distsshqueue" in split(rel, '/') for rel in listed)
        end
    end

    @testset "stage drops a tree that is only .distsshqueue" begin
        mktempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "*\n!.distsshqueue/\n!.distsshqueue/**\n")
            mkpath(joinpath(tmp, ".distsshqueue"))
            write(joinpath(tmp, ".distsshqueue", "ticket"), "nope\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.email test@example.com`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.name Test`; stdout = devnull, stderr = devnull))
            @test_throws ArgumentError DistSSHQueue.stage_send_list(tmp)
        end
    end

    @testset "stage lists a workspace member from the manifest directory" begin
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
            write(joinpath(member, "Project.toml"), "name = \"Run1\"\n[deps]\n")
            write(joinpath(member, "job.jl"), "1\n")
            write(joinpath(lab, "Manifest.toml"), "# lock\n")
            run(pipeline(`git -C $lab init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $lab config user.email test@example.com`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $lab config user.name Test`; stdout = devnull, stderr = devnull))
            listed = DistSSHQueue.stage_send_list(member)
            @test "experiments/run1/job.jl" in listed
            @test "Project.toml" in listed
        end
    end

    files_opts = DistSSHQueue.stage_rsync_files_from_opts("ssh -o BatchMode=yes")
    @test !(":- .gitignore" in files_opts)
    @test !("--delete" in files_opts)
    @test ".distsshqueue/" in files_opts
    @test ".git/" in files_opts
    @test "--info=progress2" in DistSSHQueue.stage_rsync_files_from_opts("ssh"; progress = true)

    fetch_h = sprint(io -> DistSSHQueue.print_queue_command_usage(io, "fetch"))
    @test occursin("--progress", fetch_h)
    @test occursin("progress2", fetch_h)
end
