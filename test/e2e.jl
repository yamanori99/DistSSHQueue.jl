#!/usr/bin/env julia
# Queue SSH E2E against testenv/docker-ssh workers. Not part of Pkg.test().
#
# Stages DistSSHKit `demos/` into testenv/example-job, setup! to the workers,
# then enqueue Kit go/drive jobs through Queue `serve`
# (same as CLI `submit go` / `submit drive`). `serve` runs
# DistSSHKit `execute!(…; detached=true)`.
#
# Also: `julia -m DistSSHQueue` on the queue host (omit `qhost:HOST`) and as a
# client (`qhost:HOST` over loopback OpenSSH, including `fetch`). Inspect verbs
# (`size` / `plan` / `pool`) are Queue chrome only (header + submit footer).
# Kit slots on docker-ssh (`child:distsshqueue-w1:1`).
# Three roles, one suite: client = loopback, qhost = this host, child = containers.
# Do not treat a container as qhost. `parent:1` only occupies FIFO here.
# Not a laptop + `parent:N` topology. `enable` / `disable` / `teardown` use
# `--write-only` (no user systemd / launchctl).
#
# Table jobs are the four *file*/*echo* demos. `pipeline_pi.jl` /
# `pipeline_square.jl` call `go!` / `pipeline!` themselves — not Queue rows.
#
# Also: FIFO one-at-a-time, cancel queued (skip that row), cancel running
# (`terminate_run!`, then the next queued row).
#
# Inner `@testset`s print `[i/N]` (see `_E2E_N`) so CI logs are not a long stall.
#
#   testenv/docker-ssh/scripts/up.sh --e2e
#   testenv/apple-container-ssh/scripts/up.sh --e2e   # macOS Apple silicon, not CI
#   DISTSSHQUEUE_SSH_E2E=1 julia --project=test test/e2e.jl

using Test
using Dates
using Sockets
using DistSSHKit
using DistSSHQueue

const QUEUE_ROOT = abspath(joinpath(@__DIR__, ".."))
const DOCKER_SSH = joinpath(QUEUE_ROOT, "testenv", "docker-ssh")
const JOB_PROJECT = joinpath(QUEUE_ROOT, "testenv", "example-job")
const REMOTE_ROOT = "/home/dev/distsshqueue-e2e"
const E2E_JULIA = DistSSHQueue.default_julia_bin()

_e2e_enabled() = get(ENV, "DISTSSHQUEUE_SSH_E2E", "") == "1"

if !_e2e_enabled()
    @info "Skipping Queue SSH E2E (set DISTSSHQUEUE_SSH_E2E=1 to enable)"
    exit(0)
end

include(joinpath(@__DIR__, "support.jl"))
install_serve_reaper!()

const SSH_CONFIG = joinpath(DOCKER_SSH, ".generated", "ssh_config")
const HOSTS_FILE = joinpath(DOCKER_SSH, ".generated", "hosts")

if !isfile(SSH_CONFIG) || !isfile(HOSTS_FILE)
    error("docker-ssh not ready: missing $(SSH_CONFIG). Run testenv/docker-ssh/scripts/up.sh")
end

function read_hosts(path)
    hosts = String[]
    for line in eachline(path)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        push!(hosts, s)
    end
    return hosts
end

const HOSTS = read_hosts(HOSTS_FILE)
length(HOSTS) >= 1 || error("no hosts in $HOSTS_FILE")

# DistSSHKit demos reject a bare number (`parent:N`). Same flags as Kit E2E.
const GO_N = ["--n", "64"]
const DRIVE_N = ["--n", "3"]

const SSH_ENV = Dict(
    "DISTSSHKIT_YES" => "1",
    "DISTSSHKIT_QUIET" => get(ENV, "DISTSSHKIT_QUIET", "1"),
    "DISTRIBUTED_SSH_OPTS" => "-F $(SSH_CONFIG)",
    "DISTRIBUTED_REMOTE_PROJECT_ROOT" => REMOTE_ROOT,
)

function kit_root()::String
    p = pathof(DistSSHKit)
    p isa AbstractString || error("DistSSHKit is loaded without a file path")
    return dirname(dirname(String(p)))
end

function stage_kit_demos!(proj::AbstractString)
    kit = kit_root()
    for (subdir, names) in (
        ("without_kit", ("pi_file.jl", "pi_echo.jl")),
        ("with_kit", ("square_file.jl", "square_echo.jl")),
    )
        dest = joinpath(proj, "demos", subdir)
        mkpath(dest)
        for name in names
            src = joinpath(kit, "demos", subdir, name)
            isfile(src) || error("missing DistSSHKit demo: $src")
            cp(src, joinpath(dest, name); force = true)
        end
    end
    return nothing
end

# Poll until `id` is terminal. Does not start a later queued job once `id` is done.
function drive_until_terminal!(q, id; tries = 600, sleep_s = 0.2)
    terminal = (:done, :failed, :cancelled)
    for _ = 1:tries
        st = job(q, id).state
        st in terminal && return st
        step!(q)
        sleep(sleep_s)
    end
    return job(q, id).state
end

function enqueue_kit!(q, kind::Symbol, script::AbstractString, token::AbstractString; out::AbstractString, args::Vector{String})
    return submit!(
        q,
        script,
        String[token];
        kind = kind,
        project = JOB_PROJECT,
        remote = REMOTE_ROOT,
        output_dir = out,
        julia = "auto",
        args = args,
        yes = true,
        quiet = true,
    )
end

function find_named(dir, name::AbstractString)
    isdir(dir) || return nothing
    target = String(name)
    for (root, _, files) in walkdir(dir)
        for f in files
            f == target && return joinpath(root, f)
        end
    end
    return nothing
end

function julia_depot_path_env()::String
    return join((p for p in DEPOT_PATH if !isempty(p)), Sys.iswindows() ? ";" : ":")
end

function e2e_qcmd(test_project::AbstractString, args)
    return DistSSHQueue.with_serve_tag(
        Cmd(String[
            E2E_JULIA, "--startup-file=no", "--project=$test_project",
            "-m", "DistSSHQueue", String[string(a) for a in args]...,
        ]),
    )
end

function wait_status(pred, cmd::Cmd; tries=600, sleep_s=0.2)
    out = ""
    for _ = 1:tries
        out = read(pipeline(cmd; stderr=devnull), String)
        pred(out) && return out
        sleep(sleep_s)
    end
    return out
end

# CLI for assertions. Product chrome (`Wrote`, `Started serve`, expected
# `Error:`) stays off the test log; stdout is still returned when captured.
function run_cli(cmd::Cmd)
    return run(pipeline(ignorestatus(cmd); stdout=devnull, stderr=devnull))
end

function read_cli(cmd::Cmd)::String
    err = IOBuffer()
    try
        return strip(read(pipeline(cmd; stderr=err), String))
    catch
        msg = strip(String(take!(err)))
        isempty(msg) || println(stderr, msg)
        rethrow()
    end
end

function ssh_login_user()
    u = strip(get(ENV, "USER", ""))
    isempty(u) && (u = strip(get(ENV, "LOGNAME", "")))
    isempty(u) && (u = strip(readchomp(`whoami`)))
    return u
end

function find_sshd()
    w = Sys.which("sshd")
    w !== nothing && return w
    for p in ("/usr/sbin/sshd", "/usr/libexec/sshd")
        isfile(p) && return p
    end
    error("sshd not found; qhost: E2E needs OpenSSH server")
end

# OpenSSH needs a root-owned privsep dir. Ubuntu's package creates it via systemd;
# WSL2 CI often has no systemd, so `/run/sshd` is missing even when `sshd` is installed.
function ensure_sshd_privsep_dir()
    Sys.islinux() || return nothing
    dest = isdir("/run") ? "/run/sshd" : "/var/run/sshd"
    isdir(dest) && return nothing
    if Libc.geteuid() == 0
        mkpath(dest)
        chmod(dest, 0o755)
        return nothing
    end
    run(`sudo mkdir -p $dest`)
    run(`sudo chmod 755 $dest`)
    return nothing
end

function free_loopback_port()
    server = Sockets.listen(Sockets.IPv4(127, 0, 0, 1), 0)
    _, port = Sockets.getsockname(server)
    close(server)
    return Int(port)
end

function write_loopback_sshd(dir::AbstractString, port::Int, controller_key::AbstractString)
    hostkey = joinpath(dir, "ssh_host_ed25519_key")
    isfile(hostkey) || run(`ssh-keygen -t ed25519 -f $hostkey -N "" -q`)
    auth = joinpath(dir, "authorized_keys")
    cp(string(controller_key, ".pub"), auth; force=true)
    chmod(auth, 0o600)
    cfg = joinpath(dir, "sshd_config")
    lines = String[
        "Port $port",
        "ListenAddress 127.0.0.1",
        "HostKey $hostkey",
        "PidFile $(joinpath(dir, "sshd.pid"))",
        "AuthorizedKeysFile $auth",
        "PasswordAuthentication no",
        "PubkeyAuthentication yes",
        "KbdInteractiveAuthentication no",
        "ChallengeResponseAuthentication no",
        "StrictModes no",
        # Hosted Ubuntu is `runner`; Vampire/setup-wsl is often `root`.
        ssh_login_user() == "root" ? "PermitRootLogin prohibit-password" : "PermitRootLogin no",
        "PrintMotd no",
        "LoginGraceTime 10",
    ]
    Sys.islinux() && push!(lines, "UsePAM no")
    write(cfg, join(lines, '\n') * "\n")
    return cfg
end

function start_loopback_sshd(dir::AbstractString, port::Int, controller_key::AbstractString)
    ensure_sshd_privsep_dir()
    cfg = write_loopback_sshd(dir, port, controller_key)
    log = joinpath(dir, "sshd.log")
    sshd = find_sshd()
    proc = run(`$sshd -D -f $cfg -E $log`; wait=false)::Base.Process
    for _ = 1:50
        process_running(proc) || break
        try
            sock = Sockets.connect(Sockets.IPv4(127, 0, 0, 1), port)
            close(sock)
            return proc
        catch
            sleep(0.1)
        end
    end
    extra = isfile(log) ? read(log, String) : ""
    try
        kill(proc)
        wait(proc)
    catch
    end
    error("loopback sshd failed to listen on 127.0.0.1:$port\n$extra")
end

function stop_loopback_sshd(proc::Base.Process)
    try
        process_running(proc) && kill(proc)
        wait(proc)
    catch
    end
    return nothing
end

function write_ssh_config_with_qhost(
    path::AbstractString,
    port::Int,
    user::AbstractString,
    ssh_config::AbstractString,
    controller_key::AbstractString,
)
    body = read(ssh_config, String)
    write(
        path,
        body * """

Host distsshqueue-qh
  HostName 127.0.0.1
  User $(user)
  Port $(port)
  IdentityFile $(controller_key)
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 10
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $(joinpath(dirname(path), "known_hosts"))
  TCPKeepAlive yes
""",
    )
    return path
end

function write_remote_julia(path::AbstractString, env::Dict{String,String})
    exports = String[]
    for (k, v) in env
        push!(exports, "export $k=$(DistSSHQueue.sh_single_quote(v))")
    end
    write(
        path,
        """
#!/bin/sh
$(join(exports, "\n"))
exec $(DistSSHQueue.sh_single_quote(E2E_JULIA)) "\$@"
""",
    )
    chmod(path, 0o755)
    return path
end

# Same banner idea as `test/runtests.jl`. Inner `@testset`s can take minutes
# of SSH with no Test output until they finish. Update `_E2E_N` when adding one.
const _E2E_N = 11
const _E2E_I = Ref(0)
function _e2e_announce(label::AbstractString)
    _E2E_I[] += 1
    println("[$(_E2E_I[])/$_E2E_N]  $label")
    flush(stdout)
    return nothing
end

@testset "Queue SSH E2E (docker-ssh)" verbose = true begin
    withenv(SSH_ENV...) do
        kit = kit_root()
        @testset "pipeline_* demos are Kit API scripts, not Queue jobs" begin
            _e2e_announce("pipeline_* demos are Kit API scripts, not Queue jobs")
            @test isfile(joinpath(kit, "demos", "without_kit", "pipeline_pi.jl"))
            @test isfile(joinpath(kit, "demos", "with_kit", "pipeline_square.jl"))
            pi_src = read(joinpath(kit, "demos", "without_kit", "pipeline_pi.jl"), String)
            sq_src = read(joinpath(kit, "demos", "with_kit", "pipeline_square.jl"), String)
            @test occursin("go!", pi_src)
            @test occursin("pipeline!", sq_src)
        end

        stage_kit_demos!(JOB_PROJECT)

        @testset "setup! deploys example job (Kit demos + DistSSHKit)" begin
            _e2e_announce("setup! deploys example job (Kit demos + DistSSHKit)")
            session = KitSession(
                project = JOB_PROJECT,
                workers = ["child:$(h)" for h in HOSTS],
                remote = REMOTE_ROOT,
                yes = true,
                quiet = true,
            )
            prep = setup!(session, :delete, :rsync, :instantiate)
            @test prep.ok
            @test length(prep.hosts) == length(HOSTS)
            @test all(h -> h.ok, prep.hosts)
        end

        mktempdir() do d
            host = HOSTS[1]
            token = "child:$(host):1"

            @testset "Kit go/drive demos through serve" begin
                cases = (
                    (
                        :go,
                        joinpath(JOB_PROJECT, "demos", "without_kit", "pi_file.jl"),
                        "pi_file",
                        GO_N,
                        "pi_results.txt",
                        "pi=",
                    ),
                    (
                        :go,
                        joinpath(JOB_PROJECT, "demos", "without_kit", "pi_echo.jl"),
                        "pi_echo",
                        GO_N,
                        nothing,
                        nothing,
                    ),
                    (
                        :drive,
                        joinpath(JOB_PROJECT, "demos", "with_kit", "square_file.jl"),
                        "square_file",
                        DRIVE_N,
                        "square_results.csv",
                        "param,result",
                    ),
                    (
                        :drive,
                        joinpath(JOB_PROJECT, "demos", "with_kit", "square_echo.jl"),
                        "square_echo",
                        DRIVE_N,
                        nothing,
                        nothing,
                    ),
                )
                for (kind, script, label, args, artifact, needle) in cases
                    @testset "$label" begin
                        _e2e_announce(label)
                        case_store = joinpath(d, "store_$label.toml")
                        out = joinpath(JOB_PROJECT, "e2e_kit_out", label)
                        isdir(out) && rm(out; recursive = true)
                        q = Queue(; store = case_store)
                        id = enqueue_kit!(q, kind, script, token; out = out, args = args)
                        @test job(q, id).kind === kind
                        q = Queue(; store = case_store)
                        load!(q)
                        st = drive_until_terminal!(q, id)
                        row = job(q, id)
                        st === :done || @warn "job not done" label state = st error = row.error
                        @test st === :done
                        @test row.kind === kind
                        if artifact !== nothing
                            found = find_named(out, artifact)
                            @test found !== nothing
                            if found !== nothing
                                @test occursin(needle, read(found, String))
                            end
                        end
                    end
                end
            end

            @testset "FIFO one Kit job at a time" begin
                _e2e_announce("FIFO one Kit job at a time")
                store_fifo = joinpath(d, "fifo.toml")
                echo = joinpath(JOB_PROJECT, "demos", "without_kit", "pi_echo.jl")
                q = Queue(; store = store_fifo)
                out_a = joinpath(JOB_PROJECT, "e2e_kit_out", "fifo_a")
                out_b = joinpath(JOB_PROJECT, "e2e_kit_out", "fifo_b")
                isdir(out_a) && rm(out_a; recursive = true)
                isdir(out_b) && rm(out_b; recursive = true)
                a = enqueue_kit!(q, :go, echo, token; out = out_a, args = GO_N)
                b = enqueue_kit!(q, :go, echo, token; out = out_b, args = GO_N)
                @test step!(q) == 1
                @test job(q, a).state === :running
                @test job(q, b).state === :queued
                @test step!(q) == 0
                @test drive_until_terminal!(q, a) === :done
                @test step!(q) == 1
                @test drive_until_terminal!(q, b) === :done
                fa = job(q, a).finished_at
                sb = job(q, b).started_at
                @test fa isa DateTime && sb isa DateTime && fa <= sb
            end

            @testset "cancel queued skips that row" begin
                _e2e_announce("cancel queued skips that row")
                store_c = joinpath(d, "cancel.toml")
                echo = joinpath(JOB_PROJECT, "demos", "without_kit", "pi_echo.jl")
                h = Queue(; store = store_c)
                outs = [joinpath(JOB_PROJECT, "e2e_kit_out", "skip_$i") for i = 1:3]
                for o in outs
                    isdir(o) && rm(o; recursive = true)
                end
                a = enqueue_kit!(h, :go, echo, token; out = outs[1], args = GO_N)
                b = enqueue_kit!(h, :go, echo, token; out = outs[2], args = GO_N)
                c = enqueue_kit!(h, :go, echo, token; out = outs[3], args = GO_N)
                @test cancel!(h, b)
                @test job(h, b).state === :cancelled
                @test step!(h) == 1
                @test job(h, a).state === :running
                @test drive_until_terminal!(h, a) === :done
                @test step!(h) == 1
                @test job(h, c).state === :running
                @test drive_until_terminal!(h, c) === :done
                @test job(h, b).state === :cancelled
                @test step!(h) == 0
            end

            @testset "cancel running then the next queued row" begin
                _e2e_announce("cancel running then the next queued row")
                store_r = joinpath(d, "cancel-running.toml")
                echo = joinpath(JOB_PROJECT, "demos", "without_kit", "pi_echo.jl")
                hold = joinpath(d, "hold_cancel.jl")
                write(hold, "while true; sleep(1); end\n")
                h = Queue(; store = store_r)
                out_a = joinpath(JOB_PROJECT, "e2e_kit_out", "cancel_run_a")
                out_b = joinpath(JOB_PROJECT, "e2e_kit_out", "cancel_run_b")
                for o in (out_a, out_b)
                    isdir(o) && rm(o; recursive = true)
                end
                a = submit!(
                    h,
                    hold,
                    String["parent:1"];
                    kind = :go,
                    project = JOB_PROJECT,
                    output_dir = out_a,
                    julia = "auto",
                    args = String[],
                    yes = true,
                    quiet = true,
                )
                b = enqueue_kit!(h, :go, echo, token; out = out_b, args = GO_N)
                @test step!(h) == 1
                @test job(h, a).state === :running
                t0 = time()
                while !DistSSHQueue.kit_child_alive(job(h, a)) && (time() - t0) < 60
                    sleep(0.05)
                end
                @test DistSSHQueue.kit_child_alive(job(h, a))
                @test cancel!(h, a)
                @test job(h, a).state === :cancelled
                @test step!(h) == 1
                @test job(h, b).state === :running
                @test drive_until_terminal!(h, b) === :done
                @test job(h, a).state === :cancelled
                @test step!(h) == 0
            end
        end

        test_project = joinpath(QUEUE_ROOT, "test")
        controller_key = joinpath(DOCKER_SSH, ".generated", "controller")
        qcmd(args) = e2e_qcmd(test_project, args)

        @testset "CLI (queue host + qhost:)" verbose = true begin
            mktempdir() do d
                e2e_home = joinpath(d, "home")
                mkpath(e2e_home)
                cfg = joinpath(e2e_home, ".distsshqueue", "config.toml")
                store = joinpath(e2e_home, ".distsshqueue", "jobs.toml")
                token = "child:$(HOSTS[1]):1"
                script = joinpath(JOB_PROJECT, "demos", "without_kit", "pi_echo.jl")
                @test isfile(script)

                host_env = Dict{String,String}(
                    "HOME" => e2e_home,
                    "JULIA_DEPOT_PATH" => julia_depot_path_env(),
                    "DISTSSHQUEUE_CONFIG" => cfg,
                    "DISTSSHQUEUE_STORE" => store,
                    "DISTSSHKIT_YES" => "1",
                    "DISTSSHKIT_QUIET" => get(ENV, "DISTSSHKIT_QUIET", "1"),
                    "DISTSSHQUEUE_WATCH_TICKS" => "1",
                    "DISTRIBUTED_SSH_OPTS" => "-F $(SSH_CONFIG)",
                    # Kit project is the example job, not the CLI's cwd. Over `qhost:`
                    # the ssh command lands in the login HOME, so `job_project()`
                    # cannot infer it; pin it like the API tests pass `project=`.
                    "DISTRIBUTED_PROJECT_ROOT" => JOB_PROJECT,
                    "DISTRIBUTED_REMOTE_PROJECT_ROOT" => REMOTE_ROOT,
                )

                @testset "queue-host verbs (logged in; omit qhost:)" begin
                    _e2e_announce("queue-host verbs (logged in; omit qhost:)")
                    env = merge(host_env, Dict("DISTSSHQUEUE_NO_AUTOSERVE" => "1"))
                    @test run_cli(addenv(qcmd(["setup"]), env...)).exitcode == 0
                    @test isfile(cfg)
                    @test run_cli(addenv(qcmd(["enable", "--write-only", "--queue-env", test_project, "--julia", E2E_JULIA]), env...)).exitcode == 0
                    rel = if Sys.isapple()
                        joinpath("Library", "LaunchAgents", "org.distsshqueue.serve.plist")
                    else
                        joinpath(".config", "systemd", "user", "distsshqueue.serve.service")
                    end
                    unit = joinpath(e2e_home, rel)
                    @test unit == (Sys.isapple() ? DistSSHQueue.launch_agent_path(; home=e2e_home) :
                        DistSSHQueue.systemd_user_path(; home=e2e_home))
                    @test isfile(unit)
                    @test !isfile(joinpath(e2e_home, Sys.isapple() ?
                        joinpath(".config", "systemd", "user", "distsshqueue.serve.service") :
                        joinpath("Library", "LaunchAgents", "org.distsshqueue.serve.plist")))
                    body = read(unit, String)
                    @test occursin("DistSSHQueue", body)
                    @test occursin("serve", body)
                    @test occursin("--project=", body)
                    @test occursin("--startup-file=no", body)
                    @test run_cli(addenv(qcmd(["disable", "--write-only"]), env...)).exitcode == 0
                    @test !isfile(unit)

                    # Glue only: header + Queue submit footer. Table layout is Kit E2E.
                    size_env = merge(env, Dict("DISTSSHKIT_QUIET" => "0"))
                    inspect_hosts = ["parent", "child:$(HOSTS[1])"]
                    size_out = read_cli(addenv(
                        qcmd(["size", "--gb-per-worker", "1.5", inspect_hosts...]),
                        size_env...,
                    ))
                    @test occursin("DistSSHQueue size", size_out)
                    @test occursin("Queue submit:", size_out)
                    @test occursin("child:$(HOSTS[1]):", size_out)

                    plan_out = read_cli(addenv(qcmd(["plan", inspect_hosts..., script]), size_env...))
                    @test occursin("DistSSHQueue plan", plan_out)
                    @test occursin("Queue submit:", plan_out)
                    @test occursin("submit go", plan_out) || occursin("submit ride", plan_out) ||
                        occursin("submit drive", plan_out)
                    @test occursin("child:$(HOSTS[1]):", plan_out)

                    pool_out = read_cli(addenv(
                        qcmd(["pool", "--gb-per-worker", "1.5", inspect_hosts...]),
                        size_env...,
                    ))
                    @test occursin("DistSSHQueue pool", pool_out)
                    @test occursin("Queue submit:", pool_out)
                    @test occursin("child:$(HOSTS[1]):", pool_out)
                    @test !isfile(store)

                    serve_proc = run(pipeline(addenv(qcmd(["serve", "--interval", "0.2"]), env...); stdout=devnull, stderr=devnull); wait=false)
                    try
                        outdir = joinpath(JOB_PROJECT, "e2e_kit_out", "cli_on_host")
                        isdir(outdir) && rm(outdir; recursive=true)
                        id = read_cli(addenv(qcmd(["submit", "go", token, "--output-dir", outdir, script, GO_N...]), env...))
                        @test !isempty(id)
                        listed = wait_status(addenv(qcmd(["status"]), env...)) do out
                            status_shows_id(out, id) && occursin("  done  ", out) && !occursin("  running  ", out)
                        end
                        @test status_shows_id(listed, id)
                        @test occursin("  done  ", listed)
                        wout = read_cli(addenv(qcmd(["watch", "--interval", "0.05"]), merge(env, Dict("DISTSSHKIT_QUIET" => "0"))...))
                        @test occursin("serve", wout)
                        @test occursin("running", wout)
                    finally
                        DistSSHQueue.stop_serve!(store)
                        try
                            kill(serve_proc)
                            wait(serve_proc)
                        catch
                        end
                    end
                    @test run_cli(addenv(qcmd(["stop"]), env...)).exitcode == 0
                end

                @testset "client qhost: (real ssh to loopback queue host)" begin
                    _e2e_announce("client qhost: (real ssh to loopback queue host)")
                    sshd_dir = joinpath(d, "sshd")
                    mkpath(sshd_dir)
                    port = free_loopback_port()
                    qh_store = joinpath(e2e_home, ".distsshqueue", "qhost-jobs.toml")
                    sshd_proc = start_loopback_sshd(sshd_dir, port, controller_key)
                    try
                        ssh_cfg = write_ssh_config_with_qhost(
                            joinpath(d, "ssh_config"), port, ssh_login_user(),
                            SSH_CONFIG, controller_key,
                        )
                        probe_err = IOBuffer()
                        probe = run(pipeline(ignorestatus(`ssh -F $ssh_cfg -o ConnectTimeout=5 -o LogLevel=ERROR distsshqueue-qh true`); stdout=devnull, stderr=probe_err))
                        if probe.exitcode != 0
                            client = String(take!(probe_err))
                            server = read(joinpath(sshd_dir, "sshd.log"), String)
                            error("loopback ssh to distsshqueue-qh failed: $client$server")
                        end
                        remote_env = Dict{String,String}(
                            "HOME" => e2e_home,
                            "JULIA_DEPOT_PATH" => julia_depot_path_env(),
                            "JULIA_PROJECT" => test_project,
                            "DISTSSHQUEUE_CONFIG" => cfg,
                            "DISTSSHQUEUE_STORE" => qh_store,
                            "DISTSSHKIT_YES" => "1",
                            "DISTSSHKIT_QUIET" => get(ENV, "DISTSSHKIT_QUIET", "1"),
                            "DISTRIBUTED_SSH_OPTS" => "-F $(SSH_CONFIG)",
                            "DISTRIBUTED_REMOTE_PROJECT_ROOT" => REMOTE_ROOT,
                        )
                        wrapper = write_remote_julia(joinpath(d, "remote-julia"), remote_env)
                        client_env = Dict{String,String}(
                            "DISTSSHKIT_YES" => "1",
                            "DISTSSHQUEUE_WATCH_TICKS" => "1",
                            "DISTRIBUTED_SSH_OPTS" => "-F $ssh_cfg",
                            "DISTRIBUTED_PROJECT_ROOT" => JOB_PROJECT,
                        )
                        qh(rest) = qcmd(["qhost:distsshqueue-qh", "--remote-julia", wrapper, "--queue-env", test_project, rest...])

                        reject_err = IOBuffer()
                        rejected = run(pipeline(ignorestatus(addenv(qh(["setup"]), client_env...)); stdout=devnull, stderr=reject_err))
                        @test rejected.exitcode != 0
                        @test occursin("client token", String(take!(reject_err)))

                        outdir = joinpath(JOB_PROJECT, "e2e_kit_out", "qhost")
                        isdir(outdir) && rm(outdir; recursive=true)
                        id1 = read_cli(addenv(qh(["submit", "go", token, "--output-dir", outdir, script, GO_N...]), client_env...))
                        @test !isempty(id1)
                        listed = wait_status(addenv(qh(["status"]), client_env...)) do out
                            status_shows_id(out, id1) && occursin("  done  ", out) && !occursin("  running  ", out)
                        end
                        @test status_shows_id(listed, id1)
                        @test occursin("  done  ", listed)
                        wout = read_cli(addenv(qh(["watch", "--interval", "0.05"]), client_env..., "DISTSSHKIT_QUIET" => "0"))
                        @test occursin("serve", wout)
                        @test occursin("running", wout)

                        id_f = read_cli(addenv(qh(["submit", "go", token, script, GO_N...]), client_env...))
                        @test !isempty(id_f)
                        wait_status(addenv(qh(["status"]), client_env...)) do out
                            status_shows_id(out, id_f) && occursin("  done  ", out) && !occursin("  running  ", out)
                        end
                        fetched = read_cli(addenv(qh(["fetch", id_f]), client_env...))
                        @test occursin(id_f, fetched)
                        @test isfile(joinpath(fetched, "kit.result"))
                        rm(fetched; recursive=true, force=true)

                        # Occupy serve on this box (`parent:1`); a worker
                        # `pi_echo` finishes before cancel. Submit the queued row
                        # immediately (same pattern as test/integration/cli.jl).
                        hold = joinpath(d, "hold.jl")
                        write(hold, "while true; sleep(1); end\n")
                        cancel_out = joinpath(JOB_PROJECT, "e2e_kit_out", "qhost_cancel")
                        isdir(cancel_out) && rm(cancel_out; recursive=true)
                        id2 = read_cli(addenv(qh(["submit", "go", "parent:1", "--output-dir", cancel_out, hold]), client_env...))
                        wait_status(addenv(qh(["status"]), client_env...)) do out
                            status_shows_id(out, id2) && occursin("  running  ", out)
                        end
                        isfile(joinpath(cancel_out, "kit.pid")) || sleep(0.5)
                        id3 = read_cli(addenv(qh(["submit", "go", token, script, GO_N...]), client_env...))
                        wait_status(addenv(qh(["status"]), client_env...)) do out
                            status_shows_id(out, id3) && occursin("queued", out)
                        end
                        cancelled = read_cli(addenv(qh(["cancel", id3]), client_env...))
                        @test cancelled == id3
                        after = wait_status(addenv(qh(["status"]), client_env...)) do out
                            status_shows_id(out, id3) && occursin("cancelled", out)
                        end
                        @test status_shows_id(after, id2)
                        @test occursin("cancelled", after)

                        @test run_cli(addenv(qh(["stop"]), client_env...)).exitcode == 0
                        @test run_cli(addenv(qh(["teardown", "-y", "--write-only"]), client_env...)).exitcode == 0
                    finally
                        DistSSHQueue.stop_serve!(qh_store)
                        DistSSHQueue.stop_serve!(store)
                        stop_loopback_sshd(sshd_proc)
                    end
                end
            end
        end
    end
end
