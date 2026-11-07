using Test
using Dates
using DistSSHQueue

# Pseudo-TTY (`script`) versus pipe coverage for Queue CLI display contracts.
# size/pool use Run verbosity (`:progress` on TTY, `:verbose` on pipes).
# status/watch/serve keep Queue-owned flags and spinner behavior.
# This file must not change product display policy.

@testset "Queue pseudo-TTY CLI regression" begin
    mktempdir() do dir
        # Keep the real HOME / depot. Isolate via DISTSSHQUEUE_CONFIG/STORE only
        # (changing HOME would make Julia look under an empty ~/.julia).
        store = joinpath(dir, "jobs.toml")
        cfg = joinpath(dir, "config.toml")
        jobdir = joinpath(dir, "job")
        mkpath(jobdir)
        write(joinpath(jobdir, "Project.toml"), "[deps]\n")
        write(joinpath(jobdir, "Manifest.toml"), "# lock\n")
        write(joinpath(jobdir, "a.jl"), "1\n")
        write(
            cfg,
            """
            store = $(repr(store))
            hosts = ["parent", "child:host1", "child:host2"]
            """,
        )

        fail_ssh = joinpath(dir, "fail_ssh.jl")
        write(
            fail_ssh,
            """
            println(stderr, "Permission denied (publickey).")
            exit(255)
            """,
        )

        # Queued job with enough hosts to trigger compact truncation (`_HOSTS_KEEP = 2`).
        many_hosts = String[
            "parent:1",
            "child:host1:1",
            "child:host2:1",
            "child:host3:1",
            "child:host4:1",
        ]
        seed = DistSSHQueue.Job(;
            kind = :go,
            script = joinpath(jobdir, "a.jl"),
            hosts = many_hosts,
            state = :queued,
            kwargs = Dict{String, Any}("project" => jobdir),
        )
        DistSSHQueue.save_jobs(store, DistSSHQueue.Job[seed])
        short_id = first(seed.id, 8)

        size_cmd = _queue_cli_cmd(["size", "parent", "--gb-per-worker", "0.5"])
        size_quiet_cmd = _queue_cli_cmd(["size", "-q", "parent", "--gb-per-worker", "0.5"])
        pool_cmd = _queue_cli_cmd(
            ["pool", "parent", "child:host1", "child:host2", "--gb-per-worker", "0.5"],
        )
        pool_quiet_cmd = _queue_cli_cmd(
            ["pool", "-q", "parent", "child:host1", "child:host2", "--gb-per-worker", "0.5"],
        )
        status_cmd = _queue_cli_cmd(["status"])
        status_verbose_cmd = _queue_cli_cmd(["status", "--verbose"])
        status_progress_cmd = _queue_cli_cmd(["status", "--progress"])
        status_quiet_cmd = _queue_cli_cmd(["status", "-q"])
        watch_cmd = _queue_cli_cmd(["watch", "--interval", "0.05"])
        watch_quiet_cmd = _queue_cli_cmd(["watch", "-q", "--interval", "0.05"])

        base_env = Dict{String, String}(
            "DISTSSHQUEUE_CONFIG" => cfg,
            "DISTSSHQUEUE_STORE" => store,
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
            "DISTRIBUTED_PROJECT_ROOT" => jobdir,
            "DISTSSHKIT_TEST" => "1",
            "DISTSSHKIT_TEST_SSH" => fail_ssh,
            DistSSHQueue.LOCAL_QUEUE_ENV => "1",
            DistSSHQueue.NO_KIT_SETUP_ENV => "1",
            DistSSHQueue.NO_STAGE_ENV => "1",
        )

        function write_runner(path::AbstractString, body::AbstractString)
            write(
                path,
                """
                #!/bin/sh
                # Do not `set -e`: pool exits 1 when child hosts fail SSH (expected).
                # Record each command's status; the wrapper's last status is watch.
                $(_queue_stty_prefix())
                unset NO_COLOR
                unset DISTSSHKIT_QUIET
                unset DISTSSHKIT_PROGRESS
                unset DISTSSHKIT_VERBOSE
                export DISTSSHQUEUE_CONFIG=$(_queue_sh_quote(cfg))
                export DISTSSHQUEUE_STORE=$(_queue_sh_quote(store))
                export DISTSSHQUEUE_NO_AUTOSERVE=1
                export DISTRIBUTED_PROJECT_ROOT=$(_queue_sh_quote(jobdir))
                export DISTSSHKIT_TEST=1
                export DISTSSHKIT_TEST_SSH=$(_queue_sh_quote(fail_ssh))
                export $(DistSSHQueue.LOCAL_QUEUE_ENV)=1
                export $(DistSSHQueue.NO_KIT_SETUP_ENV)=1
                export $(DistSSHQueue.NO_STAGE_ENV)=1
                export TERM=xterm-256color
                cd $(_queue_sh_quote(jobdir))
                $body
                """,
            )
            chmod(path, 0o755)
            return nothing
        end

        function run_marked(cmd::Cmd)
            return """
            $(_queue_argv_line(cmd))
            echo "___EC:\$?___"
            echo '___SPLIT___'
            """
        end

        runner = joinpath(dir, "runner.sh")
        write_runner(
            runner,
            """
            $(run_marked(size_cmd))
            $(run_marked(size_quiet_cmd))
            $(run_marked(pool_cmd))
            $(run_marked(pool_quiet_cmd))
            $(run_marked(status_cmd))
            $(run_marked(status_verbose_cmd))
            $(run_marked(status_progress_cmd))
            $(run_marked(status_quiet_cmd))
            export DISTSSHQUEUE_WATCH_TICKS=2
            $(run_marked(watch_cmd))
            $(run_marked(watch_quiet_cmd))
            """,
        )

        dest = joinpath(dir, "typescript.txt")
        env = _queue_child_env(base_env)
        captured = _queue_pty_capture(runner, dest; env = env)
        @info "Queue progress_tty shared script wall" elapsed = captured.elapsed exitcode =
            captured.exitcode
        @test isfinite(captured.elapsed)
        # Last command is watch -q (exit 0). Linux `script -e` returns that.
        @test captured.exitcode == 0

        parts = split(captured.raw, "___SPLIT___")
        @test length(parts) >= 10
        function take_n(i::Int)
            i <= length(parts) || return "", nothing
            return _queue_section_exit(parts[i])
        end
        size_tty, size_ec = take_n(1)
        size_quiet_tty, size_quiet_ec = take_n(2)
        pool_tty, pool_ec = take_n(3)
        pool_quiet_tty, pool_quiet_ec = take_n(4)
        status_tty, status_ec = take_n(5)
        status_verbose_tty, status_verbose_ec = take_n(6)
        status_progress_tty, status_progress_ec = take_n(7)
        status_quiet_tty, status_quiet_ec = take_n(8)
        watch_tty, watch_ec = take_n(9)
        watch_quiet_tty, watch_quiet_ec = take_n(10)

        @testset "per-command exit codes on TTY" begin
            @test size_ec == 0
            @test size_quiet_ec == 0
            @test pool_ec == 1
            @test pool_quiet_ec == 1
            @test status_ec == 0
            @test status_verbose_ec == 0
            @test status_progress_ec == 0
            @test status_quiet_ec == 0
            @test watch_ec == 0
            @test watch_quiet_ec == 0
        end

        @testset "size parent on TTY keeps table; hides :progress headings" begin
            size_plain = _queue_tty_strip_ansi(size_tty)
            size_lines = _queue_tty_lines(size_tty)
            @test occursin("parent", size_plain)
            @test occursin("Host", size_plain) || occursin("Workers", size_plain) ||
                occursin("worker", lowercase(size_plain))
            # Product contract: verbose-only title / Project are absent at TTY :progress.
            @test !occursin("DistSSHQueue size", size_plain)
            @test !occursin(r"(?m)^Project:", size_plain)
            @test !any(l -> startswith(strip(l), "Project:"), size_lines)
            @test occursin(r"Total:\s*\d+\s*workers", size_plain) ||
                occursin("workers", lowercase(size_plain))
            quiet_plain = _queue_tty_strip_ansi(size_quiet_tty)
            @test occursin("parent", quiet_plain)
            @test !occursin("DistSSHQueue size", quiet_plain)
            @test !occursin(r"(?m)^Project:", quiet_plain)
        end

        @testset "pool parent local + two-host SSH failures on TTY" begin
            pool_plain = _queue_tty_strip_ansi(pool_tty)
            pool_lines = _queue_tty_lines(pool_tty)
            @test occursin("parent", pool_plain)
            @test occursin("host1", pool_plain)
            @test occursin("host2", pool_plain)
            @test any(l -> _queue_host_fail_line(l, "host1"), pool_lines)
            @test any(l -> _queue_host_fail_line(l, "host2"), pool_lines)
            @test _queue_tty_message_visible(pool_tty, "host1")
            @test _queue_tty_message_visible(pool_tty, "host2")
            host1_at = findlast("host1", pool_tty)
            host2_at = findlast("host2", pool_tty)
            @test host1_at !== nothing && !_queue_tty_cursor_up_after(pool_tty, "host1")
            @test host2_at !== nothing && !_queue_tty_cursor_up_after(pool_tty, "host2")
            @test !occursin("DistSSHQueue pool", pool_plain)
            @test !occursin(r"(?m)^Project:", pool_plain)
            quiet_plain = _queue_tty_strip_ansi(pool_quiet_tty)
            quiet_lines = _queue_tty_lines(pool_quiet_tty)
            @test occursin("host1", quiet_plain)
            @test occursin("host2", quiet_plain)
            @test any(l -> _queue_host_fail_line(l, "host1"), quiet_lines)
            @test any(l -> _queue_host_fail_line(l, "host2"), quiet_lines)
            @test !occursin("DistSSHQueue pool", quiet_plain)
        end

        @testset "status compact / verbose / progress / quiet on TTY" begin
            status_plain = _queue_tty_strip_ansi(status_tty)
            @test occursin(short_id, status_plain)
            @test occursin("hosts", status_plain)
            @test occursin("+3", status_plain) || occursin("+ 3", status_plain)
            @test !occursin("child:host4:1", status_plain)

            verbose_plain = _queue_tty_strip_ansi(status_verbose_tty)
            @test occursin("child:host1:1", verbose_plain)
            @test occursin("child:host4:1", verbose_plain)
            @test !occursin("+3", verbose_plain)

            progress_plain = _queue_tty_strip_ansi(status_progress_tty)
            @test occursin("child:host4:1", progress_plain)

            quiet_plain = _queue_tty_strip_ansi(status_quiet_tty)
            @test occursin(short_id, quiet_plain)
            @test !occursin("Store", quiet_plain)
            @test !occursin("hosts", quiet_plain)
        end

        @testset "watch TTY refresh and final frame" begin
            @test _queue_tty_has_screen_clear(watch_tty) ||
                occursin("\e[H", watch_tty) || occursin("\e[J", watch_tty)
            final = _queue_tty_strip_ansi(_queue_tty_visible_screen(watch_tty))
            @test occursin("Store", final) || occursin("serve", final)
            @test occursin(short_id, final) || occursin("queued", lowercase(final))
            @test !occursin(r"\e\[[0-9;]*m", watch_tty)
            quiet_watch = _queue_tty_strip_ansi(_queue_tty_visible_screen(watch_quiet_tty))
            @test occursin(short_id, quiet_watch)
            @test !occursin("Store", quiet_watch)
        end

        @testset "pipe contracts (no TTY control sequences)" begin
            pipe_env = _queue_child_env(base_env)
            size_pipe = _queue_pipe_capture(size_cmd; env = pipe_env)
            size_quiet_pipe = _queue_pipe_capture(size_quiet_cmd; env = pipe_env)
            pool_pipe = _queue_pipe_capture(pool_cmd; env = pipe_env)
            pool_quiet_pipe = _queue_pipe_capture(pool_quiet_cmd; env = pipe_env)
            status_pipe = _queue_pipe_capture(status_cmd; env = pipe_env)
            watch_pipe_env = copy(pipe_env)
            watch_pipe_env["DISTSSHQUEUE_WATCH_TICKS"] = "1"
            watch_pipe = _queue_pipe_capture(watch_cmd; env = watch_pipe_env)

            @info "Queue progress_tty pipe walls" size = size_pipe.elapsed pool = pool_pipe.elapsed status =
                status_pipe.elapsed watch = watch_pipe.elapsed

            @test size_pipe.exitcode == 0
            @test size_quiet_pipe.exitcode == 0
            @test pool_pipe.exitcode == 1
            @test pool_quiet_pipe.exitcode == 1
            @test status_pipe.exitcode == 0
            @test watch_pipe.exitcode == 0

            @test occursin("DistSSHQueue size", size_pipe.stdout) ||
                occursin("Project:", size_pipe.stdout)
            @test occursin("parent", size_pipe.stdout)
            @test !_queue_tty_has_screen_clear(size_pipe.stdout)
            @test !occursin(r"\e\[[0-9]*[AJKH]", size_pipe.stdout)
            @test occursin("parent", size_quiet_pipe.stdout)
            @test !occursin("DistSSHQueue size", size_quiet_pipe.stdout)
            @test !occursin(r"(?m)^Project:", size_quiet_pipe.stdout)

            pool_pipe_lines = split(pool_pipe.stdout, '\n')
            @test occursin("host1", pool_pipe.stdout)
            @test occursin("host2", pool_pipe.stdout)
            @test any(l -> _queue_host_fail_line(l, "host1"), pool_pipe_lines)
            @test any(l -> _queue_host_fail_line(l, "host2"), pool_pipe_lines)
            @test occursin("parent", pool_pipe.stdout)
            @test !_queue_tty_has_screen_clear(pool_pipe.stdout)
            @test !occursin(r"\e\[[0-9]*[AJKH]", pool_pipe.stdout)
            @test occursin("host1", pool_quiet_pipe.stdout)
            @test occursin("host2", pool_quiet_pipe.stdout)

            @test occursin(short_id, status_pipe.stdout)
            @test occursin("+3", status_pipe.stdout) || occursin("+ 3", status_pipe.stdout)
            @test !_queue_tty_has_csi(status_pipe.stdout)

            @test occursin("serve", watch_pipe.stdout)
            @test occursin("running", watch_pipe.stdout)
            @test occursin("queued", watch_pipe.stdout)
            @test !_queue_tty_has_screen_clear(watch_pipe.stdout)
            @test !_queue_tty_has_csi(watch_pipe.stdout)
        end

        @testset "serve idle spinner and graceful shutdown" begin
            DistSSHQueue.save_jobs(store, DistSSHQueue.Job[])
            serve_runner = joinpath(dir, "serve_runner.sh")
            serve_cmd = _queue_cli_cmd(["serve", "--interval", "0.05"])
            write(
                serve_runner,
                """
                #!/bin/sh
                $(_queue_stty_prefix())
                unset NO_COLOR
                unset DISTSSHKIT_QUIET
                unset DISTSSHKIT_PROGRESS
                unset DISTSSHKIT_VERBOSE
                export DISTSSHQUEUE_CONFIG=$(_queue_sh_quote(cfg))
                export DISTSSHQUEUE_STORE=$(_queue_sh_quote(store))
                export DISTSSHQUEUE_NO_AUTOSERVE=1
                export DISTRIBUTED_PROJECT_ROOT=$(_queue_sh_quote(jobdir))
                export DISTSSHKIT_TEST=1
                export $(DistSSHQueue.LOCAL_QUEUE_ENV)=1
                export $(DistSSHQueue.NO_KIT_SETUP_ENV)=1
                export $(DistSSHQueue.NO_STAGE_ENV)=1
                export TERM=xterm-256color
                cd $(_queue_sh_quote(jobdir))
                exec $(_queue_argv_line(serve_cmd))
                """,
            )
            chmod(serve_runner, 0o755)
            serve_dest = joinpath(dir, "serve_typescript.txt")
            t0 = time()
            serve_proc = _queue_start_script(serve_runner, serve_dest; env = env)
            saw_idle = false
            try
                deadline = time() + 60.0
                while time() < deadline && process_running(serve_proc)
                    if isfile(serve_dest)
                        text = read(serve_dest, String)
                        if occursin("idle", text) || any(c -> occursin(c, text), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
                            saw_idle = true
                            sleep(0.35)
                            break
                        end
                    end
                    sleep(0.05)
                end
                @test saw_idle
                if process_running(serve_proc)
                    _queue_kill_capture_tree!(serve_proc; sig = Base.SIGINT)
                end
                done = timedwait(() -> !process_running(serve_proc), 30.0; pollint = 0.2)
                if done !== :ok
                    _queue_kill_capture_tree!(serve_proc; sig = Base.SIGTERM)
                    error("serve graceful SIGINT did not exit; hang cleanup used")
                end
                wait(serve_proc)
            finally
                if process_running(serve_proc)
                    _queue_kill_capture_tree!(serve_proc; sig = Base.SIGKILL)
                end
            end
            serve_elapsed = time() - t0
            serve_raw = isfile(serve_dest) ? read(serve_dest, String) : ""
            serve_ec = Int(serve_proc.exitcode)
            @info "Queue progress_tty serve script wall" elapsed = serve_elapsed exitcode = serve_ec

            @test serve_ec in (0, 130)
            @test !occursin("pseudo-TTY script exceeded", serve_raw)

            serve_plain = _queue_tty_strip_ansi(serve_raw)
            @test occursin("idle", serve_plain) || _queue_tty_spinner_char(serve_plain)
            @test occursin("\r\e[K", serve_raw) || occursin("\e[K", serve_raw)
            @test DistSSHQueue.serve_pid(store) === nothing
            @test DistSSHQueue.serve_alive(store) == false
        end

        @testset "synthetic two-writer TTY (not production setup!)" begin
            # Queue spinner and a fake setup-like bar on one TTY. Does not run
            # DistSSHRun.setup! or claim serve↔setup coordination is fixed.
            DistSSHQueue.save_jobs(store, DistSSHQueue.Job[])
            probe = joinpath(dir, "collision_probe.jl")
            write(
                probe,
                """
                using DistSSHQueue
                store = $(repr(store))
                jobdir = $(repr(jobdir))
                j = DistSSHQueue.Job(;
                    kind = :go,
                    script = joinpath(jobdir, "a.jl"),
                    hosts = ["parent:1"],
                    state = :queued,
                    kwargs = Dict{String, Any}("project" => jobdir),
                )
                DistSSHQueue.save_jobs(store, DistSSHQueue.Job[j])
                function fake_setup_bar(::DistSSHQueue.Job)
                    for _ in 1:25
                        print(stdout, "\\r  ⠋ setup ━━━━━━━━╺━━━  probing\\e[K")
                        flush(stdout)
                        sleep(0.04)
                    end
                    return nothing
                end
                q = DistSSHQueue.Queue(; store = store, runner = fake_setup_bar)
                t = @async DistSSHQueue.serve!(q; interval = 0.05)
                for _ in 1:100
                    DistSSHQueue.serve_pid(store) == getpid() && break
                    sleep(0.05)
                end
                sleep(1.2)
                schedule(t, InterruptException(); error = true)
                try
                    wait(t)
                catch
                end
                """,
            )
            probe_runner = joinpath(dir, "collision_runner.sh")
            write(
                probe_runner,
                """
                #!/bin/sh
                $(_queue_stty_prefix())
                unset NO_COLOR
                export DISTSSHQUEUE_CONFIG=$(_queue_sh_quote(cfg))
                export DISTSSHQUEUE_STORE=$(_queue_sh_quote(store))
                export DISTSSHQUEUE_NO_AUTOSERVE=1
                export DISTSSHKIT_TEST=1
                export $(DistSSHQueue.LOCAL_QUEUE_ENV)=1
                export $(DistSSHQueue.NO_KIT_SETUP_ENV)=1
                export $(DistSSHQueue.NO_STAGE_ENV)=1
                export TERM=xterm-256color
                $(_queue_sh_quote(_queue_julia_exe())) --startup-file=no --project=$(_queue_sh_quote(_queue_cli_project())) $(_queue_sh_quote(probe))
                """,
            )
            chmod(probe_runner, 0o755)
            probe_dest = joinpath(dir, "collision_typescript.txt")
            probe_cap = _queue_pty_capture(probe_runner, probe_dest; env = env)
            @info "Queue synthetic two-writer TTY wall" elapsed = probe_cap.elapsed
            @test probe_cap.exitcode == 0
            raw = probe_cap.raw
            plain = _queue_tty_strip_ansi(raw)
            @test occursin("setup", plain)
            @test occursin("━", raw) || occursin("╺", raw)
            @test occursin("idle", plain) || occursin("running", plain) ||
                _queue_tty_spinner_char(plain)
            visible_lines = split(_queue_tty_strip_ansi(_queue_tty_visible_screen(raw)), '\n')
            @test !any(l -> occursin("idle", l) && occursin("setup", l), visible_lines)
            @test !any(l -> occursin("running", l) && occursin("setup", l), visible_lines)
        end
    end
end
