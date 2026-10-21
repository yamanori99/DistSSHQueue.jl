# Child CLI (`julia -m DistSSHKit`) + parent:1. Not SSH.
# Fake `ssh` only checks `qhost:` argv. Real OpenSSH client path is test/e2e.jl.
# `--project` is the Pkg.test env (writable), not `pkgdir` (Registry trees are mode 444).

using Test
using DistSSHQueue

const TEST_PROJECT = let p = Base.active_project()
    p === nothing ? dirname(@__DIR__) : dirname(p)
end
const JULIA = DistSSHQueue.default_julia_bin()

qcli(args) = DistSSHQueue.with_serve_tag(
    `$JULIA --startup-file=no --project=$TEST_PROJECT -m DistSSHQueue $(String[string(a) for a in args])`,
)

function store_jobs(env)
    # `read_jobs`: `load_jobs` would treat a live `:running` row without `kit.pid`
    # yet as a restart and report `:failed` in-memory (and tests would pass/fail on a lie).
    return DistSSHQueue.read_jobs(env["DISTSSHQUEUE_STORE"])
end

function wait_job(env, id, states; tries = wait_tries(:child_reply, 0.2), sleep_s = 0.2)
    want = Set{Symbol}(states)
    sid = String(id)
    last = DistSSHQueue.Job[]
    for _ in 1:tries
        last = store_jobs(env)
        i = findfirst(j -> j.id == sid, last)
        if i !== nothing && last[i].state in want
            return last[i]
        end
        sleep(sleep_s)
    end
    error("timeout waiting for $sid in $want; last=$last")
end

function wait_kit_pid(path::AbstractString; tries = wait_tries(:child_reply, 0.1), sleep_s = 0.1)
    for _ in 1:tries
        isfile(path) && return nothing
        sleep(sleep_s)
    end
    error("timeout waiting for $path")
end

# `read(cmd)` returns only when the child exits. A child that never exits
# sits near 0% CPU until PkgEval's inactivity kill, with no test name. This
# names that wait. `:child_reply` is how long the child may stay under a few
# percent CPU with neither stdout nor stderr growing. A cold compile stays
# above that. A full-CPU spin is left to PkgEval. Unreadable CPU time is a
# wall clock of the same length, and output growth does not extend that wall.
function read_cli(
        args::AbstractVector{<:AbstractString},
        env::AbstractDict;
        label::AbstractString,
        seconds::Real = wait_seconds(:child_reply),
    )::String
    cmd = addenv(qcli(args), env...)
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(cmd; stdout = out, stderr = err); wait = false)
    mark = wait_while_progressing(() -> out.size + err.size, proc; seconds)
    timed_out = mark === :idle || mark === :wall
    if timed_out
        terminate_child!(proc)
    else
        wait(proc)
    end
    text = String(take!(out))
    etext = String(take!(err))
    if timed_out || !success(proc)
        why = timed_out ? "timed out ($(mark))" : "failed"
        error("$label $why (exit=$(proc.exitcode)): stdout=$(repr(text)) stderr=$(repr(etext))")
    end
    return text
end

function cli_env(d::AbstractString)
    cfg = joinpath(d, "config.toml")
    store = joinpath(d, "jobs.toml")
    jobdir = joinpath(d, "job")
    mkpath(jobdir)
    write(joinpath(jobdir, "Project.toml"), "[deps]\n")
    write(joinpath(jobdir, "hello.jl"), "write(joinpath(@__DIR__, \"hello.ran\"), \"cli-local\\n\")\nprintln(\"cli-local\")\n")
    write(joinpath(jobdir, "hold.jl"), "while true; sleep(1); end\n")
    write(cfg, "store = $(repr(store))\nhosts = [\"parent\"]\n\n[env]\nDISTSSHKIT_YES = \"1\"\n")
    env = Dict(
        "DISTSSHQUEUE_CONFIG" => cfg,
        "DISTSSHQUEUE_STORE" => store,
        "DISTSSHKIT_YES" => "1",
        DistSSHQueue.NO_STAGE_ENV => "1",
        DistSSHQueue.LOCAL_QUEUE_ENV => "1",
        DistSSHQueue.NO_KIT_SETUP_ENV => "1",
    )
    withenv(env..., "DISTSSHQUEUE_NO_AUTOSERVE" => "1") do
        DistSSHQueue.main(["setup", "--config", cfg]) == 0 || error("setup failed")
    end
    return env, cfg, store, jobdir
end

function stop_store_serve(store::AbstractString)
    DistSSHQueue.stop_serve!(store)
    return nothing
end

# On Julia 1.13, a SIGINT in the first few tenths of a second after `serve`
# starts can land in Distributed's `start_gc_msgs_task` instead of the main
# task. Signal after the loop has run a few intervals.
const SIGINT_SETTLE_S = 1.5

function spawn_to_file(cmd::Cmd, env::AbstractDict, path::AbstractString)::Base.Process
    return run(pipeline(addenv(cmd, env...); stdout = path, stderr = devnull); wait = false)
end

function wait_output(path::AbstractString, proc::Base.Process, needle::AbstractString; seconds::Real = wait_seconds(:child_reply))::Bool
    function bytes()
        isfile(path) || return 0
        return filesize(path)
    end
    watch = IdleWatch(seconds)
    while process_running(proc)
        if isfile(path) && occursin(needle, read(path, String))
            return true
        end
        mark = observe_progress!(
            watch;
            cpu = process_cpu_seconds(proc),
            output = bytes(),
            now = time(),
        )
        mark === :busy || return false
        sleep(CHILD_POLL_S)
    end
    return isfile(path) && occursin(needle, read(path, String))
end

function sigint_stopped(proc::Base.Process; seconds::Real = wait_seconds(:sigint_grace))::Bool
    kill(proc, Base.SIGINT)
    deadline = time() + seconds
    while process_running(proc) && time() < deadline
        sleep(0.05)
    end
    return !process_running(proc)
end

function reap_child(proc::Base.Process)
    process_running(proc) && kill(proc, Base.SIGTERM)
    wait(proc)
    return nothing
end

function write_fake_ssh(path::AbstractString, log::AbstractString)
    mkpath(dirname(path))
    write(
        path,
        """
        #!/bin/sh
        {
          for a in "\$@"; do
            printf '%s\\n' "\$a"
          done
          printf '%s\\n' "---"
        } >> $(DistSSHQueue.sh_single_quote(log))
        for a in "\$@"; do
          if [ "\$a" = "--version" ]; then
            printf '%s\\n' "julia version 1.12.7"
            exit 0
          fi
        done
        exit 0
        """,
    )
    chmod(path, 0o755)
    return path
end

@testset "CLI (parent:1)" begin
    @testset "setup submit status parent:1 (explicit serve)" begin
        mktempdir() do d
            base, _, store, jobdir = cli_env(d)
            env = merge(base, Dict("DISTSSHQUEUE_NO_AUTOSERVE" => "1"))
            serve_cmd = addenv(qcli(["serve", "--interval", "0.1"]), env...)
            proc = run(serve_cmd; wait = false)
            try
                cd(jobdir) do
                    id = strip(read_cli(["submit", "go", "parent:1", "hello.jl"], env; label = "submit hello"))
                    @test !isempty(id)
                    row = wait_job(env, id, (:done, :failed))
                    @test row.state === :done
                    @test isfile(joinpath(jobdir, "hello.ran"))
                    out = read_cli(["status"], env; label = "status")
                    @test status_shows_id(out, id)
                    watch_env = Dict{String, String}(env)
                    watch_env["DISTSSHQUEUE_WATCH_TICKS"] = "1"
                    wout = read_cli(["watch", "--interval", "0.05"], watch_env; label = "watch")
                    @test occursin("serve", wout)
                    @test occursin("running", wout)
                    @test occursin("queued", wout)
                    @test !occursin("DistSSHQueue watch", wout)
                end
            finally
                DistSSHQueue.stop_serve!(store)
                try
                    kill(proc)
                    wait(proc)
                catch
                end
            end
        end
    end

    @testset "auto-serve submit and cancel queued" begin
        mktempdir() do d
            env, _, store, jobdir = cli_env(d)
            try
                cd(jobdir) do
                    hold_out = joinpath(d, "hold-queued-out")
                    id1 = strip(
                        read_cli(
                            ["submit", "go", "parent:1", "--output-dir", hold_out, "hold.jl"],
                            env;
                            label = "submit hold",
                        )
                    )
                    @test !isempty(id1)
                    row = wait_job(env, id1, (:running,))
                    wait_kit_pid(joinpath(hold_out, "kit.pid"))
                    @test row.state === :running
                    id2 = strip(
                        read_cli(
                            ["submit", "go", "parent:1", "hello.jl"],
                            env;
                            label = "submit hello while hold runs",
                        )
                    )
                    queued = wait_job(env, id2, (:queued,))
                    @test queued.state === :queued
                    c = strip(read_cli(["cancel", id2], env; label = "cancel queued"))
                    @test c == id2
                    listed = read_cli(["status"], env; label = "status after cancel queued")
                    @test status_shows_id(listed, id1)
                    @test status_shows_id(listed, id2)
                    @test occursin("cancelled", listed)
                end
            finally
                DistSSHQueue.stop_serve!(store)
            end
        end
    end

    @testset "cancel running parent:1" begin
        mktempdir() do d
            env, _, store, jobdir = cli_env(d)
            try
                cd(jobdir) do
                    id = strip(
                        read_cli(
                            ["submit", "go", "parent:1", "hold.jl"],
                            env;
                            label = "submit running hold",
                        )
                    )
                    @test !isempty(id)
                    row = wait_job(env, id, (:running,))
                    sidecar = nothing
                    for _ in 1:300
                        rd = get(row.kwargs, "run_dir", nothing)
                        if rd isa AbstractString && isfile(joinpath(rd, "kit.pid"))
                            sidecar = rd
                            break
                        end
                        rp = row.result_path
                        if rp isa AbstractString && isfile(joinpath(rp, "kit.pid"))
                            sidecar = rp
                            break
                        end
                        sleep(0.1)
                        row = wait_job(env, id, (:running,))
                    end
                    sidecar === nothing && error("timeout waiting for kit.pid")
                    wait_kit_pid(joinpath(sidecar, "kit.pid"))
                    @test row.state === :running
                    c = strip(read_cli(["cancel", id], env; label = "cancel running"))
                    @test c == id
                    done = wait_job(env, id, (:cancelled,); tries = 200)
                    @test done.state === :cancelled
                end
            finally
                DistSSHQueue.stop_serve!(store)
            end
        end
    end

    @testset "qhost:HOST ssh argv (no remote exec)" begin
        mktempdir() do d
            env, _, _, _ = cli_env(d)
            log = joinpath(d, "ssh.log")
            fake = joinpath(d, "fakebin")
            write_fake_ssh(joinpath(fake, "ssh"), log)
            path = fake * ":" * get(ENV, "PATH", "")
            withenv(env..., "PATH" => path) do
                @test DistSSHQueue.main(
                    [
                        "qhost:qbox",
                        "--remote-julia", JULIA,
                        "status",
                    ]
                ) == 0
                @test DistSSHQueue.main(
                    [
                        "qhost:qbox",
                        "--remote-julia", JULIA,
                        "watch",
                    ]
                ) == 0
                @test DistSSHQueue.main(
                    [
                        "qhost:qbox",
                        "--remote-julia", JULIA,
                        "list-host",
                    ]
                ) == 0
                code_go = DistSSHQueue.main(
                    [
                        "qhost:qbox",
                        "--remote-julia", JULIA,
                        "go",
                        "--hosts",
                        "child:w:2",
                        "hello.jl",
                    ]
                )
                @test code_go == 1
            end
            withenv(
                env...,
                "PATH" => path,
                DistSSHQueue.QHOST_DEFAULT_ENV => "qbox",
            ) do
                @test DistSSHQueue.main(["--remote-julia", JULIA, "status"]) == 0
            end
            dumped = read(log, String)
            @test occursin("qbox", dumped)
            @test occursin("DistSSHQueue", dumped)
            @test occursin("status", dumped)
            @test occursin("watch", dumped)
            @test occursin("list-host", dumped)
            @test !occursin("hello.jl", dumped)
            @test occursin("--startup-file=no", dumped)
            @test occursin("--project=~/.distsshqueue/env", dumped)
            @test !occursin("add-host", dumped)
            @test occursin("DISTSSHQUEUE_QHOST", dumped)
            @test !occursin("--via", dumped)
        end
    end

    @testset "instantiate subprocess skips queue-env depot" begin
        mktempdir() do d
            qenv = joinpath(d, "env")
            job = joinpath(d, "job")
            mkpath(qenv)
            mkpath(job)
            write(joinpath(qenv, "Project.toml"), "[deps]\n")
            env_manifest = joinpath(qenv, "Manifest.toml")
            write(env_manifest, "manifest_format = \"2.0\"\n")
            env_before = read(env_manifest, String)
            write(joinpath(job, "Project.toml"), "[deps]\n")
            script = """
            using DistSSHQueue
            empty!(DEPOT_PATH)
            push!(DEPOT_PATH, $(repr(qenv)))
            DistSSHQueue._queue_local_instantiate!($(repr(job)))
            """
            cmd = DistSSHQueue.with_serve_tag(
                Cmd(String[JULIA, "--startup-file=no", "--project=$TEST_PROJECT", "-e", script]),
            )
            run(cmd)
            @test isfile(joinpath(job, "Manifest.toml"))
            @test read(env_manifest, String) == env_before
            @test !isdir(joinpath(qenv, "packages"))
        end
    end

    @testset "teardown -y after setup" begin
        mktempdir() do home::String
            data = joinpath(home, ".distsshqueue")
            bindir = joinpath(home, ".local", "bin")
            mkpath(bindir)
            leftover = joinpath(bindir, "dskq")
            write(leftover, "#!/bin/sh\n")
            withenv("DISTSSHQUEUE_CONFIG" => nothing, "DISTSSHQUEUE_STORE" => nothing) do
                @test DistSSHQueue.main(
                    [
                        "setup",
                        "--config", joinpath(data, "config.toml"),
                    ]
                ) == 0
                confirm = String[]
                for p in DistSSHQueue.teardown_targets(; home = home)
                    ispath(p) || continue
                    push!(confirm, "--confirm-path", p)
                end
                @test DistSSHQueue.main(
                    [
                        "teardown",
                        "--home", home,
                        "--write-only",
                        confirm...,
                    ]
                ) == 0
            end
            @test !isfile(leftover)
            @test !isdir(data)
        end
    end

    @testset "SIGINT stops serve" begin
        mktempdir() do d
            base, _, store, _ = cli_env(d)
            env = merge(base, Dict("DISTSSHQUEUE_NO_AUTOSERVE" => "1"))
            logf = joinpath(d, "serve.out")
            pidpath = DistSSHQueue.store_pid_path(store)
            proc = spawn_to_file(qcli(["serve", "--interval", "0.2"]), env, logf)
            try
                @test wait_output(logf, proc, "Ctrl-C stops serve")
                @test isfile(pidpath)
                sleep(SIGINT_SETTLE_S)
                @test sigint_stopped(proc)
                @test proc.exitcode == 0
                @test !isfile(pidpath)
            finally
                reap_child(proc)
            end
        end
    end

    @testset "SIGINT stops watch" begin
        mktempdir() do d
            store = joinpath(d, "jobs.toml")
            logf = joinpath(d, "watch.out")
            env = Dict("DISTSSHQUEUE_STORE" => store, "DISTSSHQUEUE_CONFIG" => joinpath(d, "no.toml"))
            proc = spawn_to_file(qcli(["watch", "--interval", "0.2"]), env, logf)
            try
                @test wait_output(logf, proc, "serve")
                sleep(SIGINT_SETTLE_S)
                @test sigint_stopped(proc)
                @test proc.exitcode == 0
            finally
                reap_child(proc)
            end
        end
    end
end
