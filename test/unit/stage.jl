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
        mktempdir() do tmp::String
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
            write(joinpath(tmp, ".distsshqueue-backup"), "keep\n")
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
            @test ".distsshqueue-backup" in listed
            @test !any(".distsshqueue" in split(rel, '/') for rel in listed)
        end
    end

    @testset "stage drops a tree that is only .distsshqueue" begin
        mktempdir() do tmp::String
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "*\n!.distsshqueue/\n!.distsshqueue/**\n")
            mkpath(joinpath(tmp, ".distsshqueue"))
            write(joinpath(tmp, ".distsshqueue", "ticket"), "nope\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.email test@example.com`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.name Test`; stdout = devnull, stderr = devnull))
            err = try
                DistSSHQueue.stage_send_list(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("after dropping .distsshqueue", sprint(showerror, err))
        end
    end

    @testset "an empty git send list stays Run's error" begin
        mktempdir() do tmp::String
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "*\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.email test@example.com`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.name Test`; stdout = devnull, stderr = devnull))
            err = try
                DistSSHQueue.stage_send_list(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            msg = sprint(showerror, err)
            @test occursin("nothing to send", msg)
            @test !occursin("after dropping", msg)
        end
    end

    @testset "ancestor gitignore warns once on stdout" begin
        mktempdir() do tmp::String
            write(joinpath(tmp, ".gitignore"), "dropped.txt\n")
            sub = joinpath(tmp, "sub")
            mkpath(sub)
            write(joinpath(sub, "Project.toml"), "name = \"App\"\n")
            write(joinpath(sub, "dropped.txt"), "nope\n")
            write(joinpath(sub, "keep.txt"), "yes\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.email test@example.com`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.name Test`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp add -A`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp commit -q -m init`; stdout = devnull, stderr = devnull))
            text = mktemp() do _, io
                listed = redirect_stdout(io) do
                    redirect_stderr(devnull) do
                        DistSSHQueue.stage_send_list(sub)
                    end
                end
                @test "keep.txt" in listed
                @test !("dropped.txt" in listed)
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test count("Warning:", text) == 1
            @test occursin("dropped.txt", text)
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

    @testset "stage rsync argv and a local error skips ssh" begin
        mktempdir() do tmp::String
            bin = joinpath(tmp, "bin")
            mkpath(bin)
            sshlog = joinpath(tmp, "ssh.log")
            rsynclog = joinpath(tmp, "rsync.log")
            filesfrom = joinpath(tmp, "files-from")
            write(sshlog, "")
            write(
                joinpath(bin, "ssh"),
                """
                #!/bin/sh
                printf '%s\\n' "\$@" >> "\$FAKE_SSH_LOG"
                exit 0
                """,
            )
            write(
                joinpath(bin, "rsync"),
                """
                #!/bin/sh
                printf '%s\\n' "\$@" >> "\$FAKE_RSYNC_LOG"
                for arg in "\$@"; do
                  case "\$arg" in
                    --files-from=*)
                      cp "\${arg#--files-from=}" "\$FAKE_FILES_FROM"
                      ;;
                  esac
                done
                exit 0
                """,
            )
            chmod(joinpath(bin, "ssh"), 0o755)
            chmod(joinpath(bin, "rsync"), 0o755)
            fakeenv = [
                "PATH" => bin * ":" * get(ENV, "PATH", ""),
                "FAKE_SSH_LOG" => sshlog,
                "FAKE_RSYNC_LOG" => rsynclog,
                "FAKE_FILES_FROM" => filesfrom,
            ]

            emptygit = joinpath(tmp, "emptygit")
            mkpath(emptygit)
            write(joinpath(emptygit, "Project.toml"), "name = \"App\"\n")
            write(joinpath(emptygit, ".gitignore"), "*\n!.distsshqueue/\n!.distsshqueue/**\n")
            mkpath(joinpath(emptygit, ".distsshqueue"))
            write(joinpath(emptygit, ".distsshqueue", "ticket"), "nope\n")
            run(pipeline(`git -C $emptygit init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $emptygit config user.email test@example.com`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $emptygit config user.name Test`; stdout = devnull, stderr = devnull))
            withenv(fakeenv...) do
                @test_throws ArgumentError DistSSHQueue.rsync_to_qhost!(
                    "qh", emptygit, "/stage/empty", String[]
                )
            end
            @test isempty(read(sshlog, String))

            plain = joinpath(tmp, "plain")
            mkpath(plain)
            write(joinpath(plain, "Project.toml"), "name = \"App\"\n")
            withenv(fakeenv...) do
                @test_throws ArgumentError DistSSHQueue.rsync_to_qhost!(
                    "qh", plain, "/stage/plain", [joinpath(tmp, "missing.jl")]
                )
            end
            @test isempty(read(sshlog, String))

            gitproj = joinpath(tmp, "gitproj")
            mkpath(gitproj)
            write(joinpath(gitproj, "Project.toml"), "name = \"App\"\n")
            write(joinpath(gitproj, "a.txt"), "x\n")
            write(joinpath(gitproj, "#hash.txt"), "hash\n")
            write(joinpath(gitproj, ";semi.txt"), "semi\n")
            run(pipeline(`git -C $gitproj init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $gitproj config user.email test@example.com`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $gitproj config user.name Test`; stdout = devnull, stderr = devnull))
            withenv(fakeenv...) do
                DistSSHQueue.rsync_to_qhost!("qh", gitproj, "/stage/git", String[])
            end
            gitargv = read(rsynclog, String)
            @test occursin("--from0", gitargv)
            @test occursin("--files-from=", gitargv)
            @test !occursin(":- .gitignore", gitargv)
            listed = Set(split(read(filesfrom, String), '\0'; keepempty = false))
            @test "a.txt" in listed
            @test "Project.toml" in listed
            @test "./#hash.txt" in listed
            @test "./;semi.txt" in listed
            @test !isempty(read(sshlog, String))

            write(sshlog, "")
            write(rsynclog, "")
            nogit = joinpath(tmp, "nogit")
            mkpath(nogit)
            write(joinpath(nogit, "Project.toml"), "name = \"App\"\n")
            withenv(fakeenv...) do
                DistSSHQueue.rsync_to_qhost!("qh", nogit, "/stage/nogit", String[])
            end
            plainargv = read(rsynclog, String)
            @test occursin(":- .gitignore", plainargv)
            @test !occursin("--from0", plainargv)
            @test !occursin("--files-from=", plainargv)
            @test !isempty(read(sshlog, String))
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

@testset "hop_print and stage_job_tree use ssh on PATH" begin
    mktempdir() do tmp::String
        bin = joinpath(tmp, "bin")
        mkpath(bin)
        rsynclog = joinpath(tmp, "rsync.log")
        write(
            joinpath(bin, "ssh"),
            """
            #!/bin/sh
            echo /tmp/fakehome
            exit 0
            """,
        )
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
        chmod(joinpath(bin, "ssh"), 0o755)
        chmod(joinpath(bin, "rsync"), 0o755)
        proj = joinpath(tmp, "job")
        mkpath(proj)
        write(joinpath(proj, "Project.toml"), "name = \"App\"\n")
        write(joinpath(proj, "job.jl"), "1\n")
        env = [
            "PATH" => bin * ":" * get(ENV, "PATH", ""),
            "FAKE_RSYNC_LOG" => rsynclog,
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
        ]
        home = try
            DistSSHQueue._RSYNC_VER_READY[] = false
            withenv(env...) do
                return DistSSHQueue.hop_print("qh", "/opt/julia", "print(homedir())")
            end
        finally
            DistSSHQueue._RSYNC_VER_READY[] = false
        end
        @test home == "/tmp/fakehome"
        staged = String[]
        extra = Dict{String, String}()
        try
            DistSSHQueue._RSYNC_VER_READY[] = false
            withenv(env...) do
                cd(proj) do
                    got, more = DistSSHQueue.stage_job_tree!(
                        "qh", "/opt/julia", "submit", ["go", "job.jl"],
                    )
                    append!(staged, got)
                    merge!(extra, more)
                    return nothing
                end
            end
        finally
            DistSSHQueue._RSYNC_VER_READY[] = false
        end
        @test any(s -> startswith(s, "/tmp/fakehome/.distsshqueue/stage/"), staged)
        @test startswith(extra["DISTRIBUTED_PROJECT_ROOT"], "/tmp/fakehome/.distsshqueue/stage/")
        @test haskey(extra, DistSSHQueue.JOB_ID_ENV)
        @test occursin("/tmp/fakehome/.distsshqueue/stage/", read(rsynclog, String))
    end
end
