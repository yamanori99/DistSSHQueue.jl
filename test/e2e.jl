#!/usr/bin/env julia
# Queue SSH E2E against testenv/docker-ssh workers. Not part of Pkg.test().
#
# Copies testenv/example-job to its own git root and stages DistSSHRun `demos/`
# there. The Queue repo `.gitignore` does not apply to that root. Then setup!
# to the workers and enqueue Kit go/drive/ride jobs through Queue `serve`
# (same as CLI `submit go` / `submit drive` / `submit ride`). `serve` runs
# DistSSHRun `execute!(…; detached=true)` for kinds in `KIT_EXECUTE_KINDS`.
#
# Also: `julia -m DistSSHKit` on the queue host (omit `qhost:HOST`) and as a
# client (`qhost:HOST` over loopback OpenSSH, including `fetch`). The staged
# tree is the git send list (`setup --rsync`), with `.distsshqueue/` left
# out and `.distsshqueue-backup` kept. Inspect verbs
# (`size` / `plan` / `pool`) are Queue chrome only (header + submit footer).
# Kit slots on docker-ssh (`child:child-1:1`).
# Three roles, one suite: client = loopback, qhost = this host, child = containers.
# Do not treat a container as qhost. `parent:1` only occupies FIFO here.
# Not a client-as-`parent:N` topology. `enable` / `disable` / `teardown` use
# `--write-only` (no user systemd / launchctl).
#
# Table jobs are the four *file*/*echo* demos plus `ride/map_echo.jl`.
# `pipeline_pi.jl` / `pipeline_square.jl` call `go!` / `pipeline!` themselves —
# not Queue rows. One `go` uses `child:HOST:2` (`go_manifest.txt` `slots=2`).
# `size` / `plan` / `pool` list every worker in the hosts file.
#
# Also: FIFO one-at-a-time, cancel queued (skip that row), cancel running
# (`terminate_run!`, then the next queued row).
#
# Also: 0.9.6 CLI rejects a non-finite `--interval`, warns once on the 0.10
# bridges, and `teardown` without `--confirm-path` prints `Would remove`.
# Autoserve (`submit` without `DISTSSHQUEUE_NO_AUTOSERVE`) starts the Julia
# and `--project=` from the `enable` unit, not `default_queue_env`.
#
# Inner `@testset`s print `[i/N]`. `N` is how many `@e2e_announce` / `@e2e_plan`
# labels the file registered, so adding one does not need a hand count.
#
#   testenv/docker-ssh/scripts/up.sh --e2e
#   testenv/apple-container-ssh/scripts/up.sh --e2e   # macOS Apple silicon, not CI
#   DISTSSHQUEUE_SSH_E2E=1 julia --project=test test/e2e.jl

using Test
using Dates
using Sockets
using DistSSHRun
using DistSSHQueue

const QUEUE_ROOT = abspath(joinpath(@__DIR__, ".."))
const DOCKER_SSH = joinpath(QUEUE_ROOT, "testenv", "docker-ssh")
const JOB_SOURCE = joinpath(QUEUE_ROOT, "testenv", "example-job")
const REMOTE_ROOT = "/home/dev/distsshqueue-e2e"
const E2E_JULIA = DistSSHQueue.default_julia_bin()

_e2e_enabled() = get(ENV, "DISTSSHQUEUE_SSH_E2E", "") == "1"

if !_e2e_enabled()
    @info "Skipping Queue SSH E2E (set DISTSSHQUEUE_SSH_E2E=1 to enable)"
    exit(0)
end

# Location variables still name the repo when `-C` is set. A hook can export
# them. Drop them before any git call so `init` and the later `setup!` git
# both use the job tree.
for k in (
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CEILING_DIRECTORIES",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    )
    delete!(ENV, k)
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
# `drive_until_terminal!` poll budget. `drive` (`--n 3`) stays `:running`
# past 2 min on macos-15-intel Colima (E2E weekly after 0.6.0).
const GO_WAIT_TRIES = 600
const DRIVE_WAIT_TRIES = 1800

const SSH_ENV = Dict(
    "DISTSSHKIT_YES" => "1",
    "DISTSSHKIT_QUIET" => get(ENV, "DISTSSHKIT_QUIET", "1"),
    "DISTRIBUTED_SSH_OPTS" => "-F $(SSH_CONFIG)",
    "DISTRIBUTED_REMOTE_PROJECT_ROOT" => REMOTE_ROOT,
    # E2E already runs Kit setup! in its own testset. Per-job setup! would
    # redo rsync/instantiate/:check.
    DistSSHQueue.NO_KIT_SETUP_ENV => "1",
)

function kit_root()::String
    p = pathof(DistSSHRun)
    p isa AbstractString || error("DistSSHKit is loaded without a file path")
    return dirname(dirname(String(p)))
end

function stage_kit_demos!(proj::AbstractString)
    kit = kit_root()
    for (subdir, names) in (
            ("without_kit", ("pi_file.jl", "pi_echo.jl")),
            ("with_kit", ("square_file.jl", "square_echo.jl")),
            ("ride", ("map_echo.jl",)),
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

"""Copy tracked files from `src` to a new git root.

This repo's `.gitignore` is not the send list. Untracked leftovers stay behind.
"""
function isolate_job_git_root(src::AbstractString)::String
    dest = mktempdir()
    listed = read(`git -C $src ls-files -z`, String)
    for rel in split(listed, '\0'; keepempty = false)
        to = joinpath(dest, rel)
        mkpath(dirname(to))
        cp(joinpath(src, rel), to)
    end
    run(`git -C $dest init -q`)
    top = realpath(strip(read(`git -C $dest rev-parse --show-toplevel`, String)))
    top == realpath(dest) || error("job git root is $top, expected $dest")
    return dest
end

const JOB_PROJECT = isolate_job_git_root(JOB_SOURCE)

const _E2E_DEMO_RELS = (
    "demos/without_kit/pi_file.jl",
    "demos/without_kit/pi_echo.jl",
    "demos/with_kit/square_file.jl",
    "demos/with_kit/square_echo.jl",
    "demos/ride/map_echo.jl",
)

"""Fail with the missing path when `setup!` did not deliver a demo."""
function require_remote_demos!()
    for host in HOSTS
        for rel in _E2E_DEMO_RELS
            remote = REMOTE_ROOT * "/" * rel
            cmd = `ssh -F $SSH_CONFIG -o BatchMode=yes -o ConnectTimeout=15 $host test -f $remote`
            proc = run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = devnull))
            proc.exitcode == 0 || error("setup! did not deliver $remote on $host")
        end
    end
    return nothing
end

# Poll until `id` is terminal. Does not start a later queued job once `id` is done.
function drive_until_terminal!(q, id; tries = GO_WAIT_TRIES, sleep_s = 0.2)
    terminal = (:done, :failed, :cancelled)
    for _ in 1:tries
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
        Cmd(
            String[
                E2E_JULIA, "--startup-file=no", "--project=$test_project",
                "-m", "DistSSHQueue", String[string(a) for a in args]...,
            ]
        ),
    )
end

# `read_jobs` turns a torn TOML read into `ArgumentError`. A replace can
# still be observed mid-write on some filesystems, so the waiter retries that
# and a raw `TOML.ParserError`. A bad job row is a different message and
# must not be retried.
function _e2e_transient_store(e)::Bool
    e isa TOML.ParserError && return true
    return e isa ArgumentError && startswith(e.msg, "jobs store is not valid TOML:")
end

# Poll `jobs.toml` (same as test/integration/cli.jl). Waiting on `status`
# chrome used to sit through 600×0.2s when Store `serve  running` looked
# like a job STATE. Default 150×0.2s (~30 s) is enough for local E2E.
# macos-15-intel Colima (nested Docker) leaves a `go` row `:running` past
# that; both CLI testsets pass `tries = GO_WAIT_TRIES`.
function wait_store_job(store::AbstractString, id::AbstractString, states; tries = 150, sleep_s = 0.2)
    want = Set{Symbol}(states)
    sid = String(id)
    last = DistSSHQueue.Job[]
    for _ in 1:tries
        last = try
            DistSSHQueue.with_store_lock(store) do
                isfile(store) ? DistSSHQueue.read_jobs(store) : DistSSHQueue.Job[]
            end
        catch e
            _e2e_transient_store(e) || rethrow()
            last
        end
        i = findfirst(j -> j.id == sid, last)
        if i !== nothing
            st = last[i].state
            st in want && return last[i]
            if st in (:failed, :cancelled, :done) && !(st in want)
                err = last[i].error
                extra = err === nothing || isempty(strip(String(err))) ? "" : ": $err"
                error("job $sid is $st (wanted $want)$extra")
            end
        end
        sleep(sleep_s)
    end
    error("timeout waiting for $sid in $want; last=$last")
end

# `:running` is persisted before Kit writes `kit.pid`. A second `serve`
# `load_jobs` then marks that row lost and can run the next job. Wait until
# the pid names a live process.
function wait_store_kit_pid(store::AbstractString, id::AbstractString; tries = 600, sleep_s = 0.2)
    sid = String(id)
    last = DistSSHQueue.Job[]
    for _ in 1:tries
        last = try
            DistSSHQueue.with_store_lock(store) do
                isfile(store) ? DistSSHQueue.read_jobs(store) : DistSSHQueue.Job[]
            end
        catch e
            _e2e_transient_store(e) || rethrow()
            last
        end
        i = findfirst(j -> j.id == sid, last)
        if i !== nothing
            row = last[i]
            st = row.state
            if st in (:failed, :cancelled, :done)
                err = row.error
                extra = err === nothing || isempty(strip(String(err))) ? "" : ": $err"
                error("job $sid is $st before kit.pid$extra")
            end
            st === :running && DistSSHQueue.kit_child_alive(row) && return row
        end
        sleep(sleep_s)
    end
    error("timeout waiting for kit.pid of $sid; last=$last")
end

# CLI for assertions. Product chrome (`Wrote`, `Started serve`, expected
# `Error:`) stays off the test log; stdout is still returned when captured.
function run_cli(cmd::Cmd)
    return run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = devnull))
end

function read_cli(cmd::Cmd)::String
    err = IOBuffer()
    try
        return strip(read(pipeline(cmd; stderr = err), String))
    catch
        msg = strip(String(take!(err)))
        isempty(msg) || println(stderr, msg)
        rethrow()
    end
end

"""Exit code plus both streams. A failing CLI is an assertion, not a test error."""
function capture_cli(cmd::Cmd; stdin::Union{Nothing, AbstractString} = nothing)::Tuple{Int, String, String}
    out = IOBuffer()
    err = IOBuffer()
    redir = stdin === nothing ? cmd : pipeline(cmd; stdin = stdin)
    proc = run(pipeline(ignorestatus(redir); stdout = out, stderr = err))
    return proc.exitcode, String(take!(out)), String(take!(err))
end

"""Stop a background `serve`. SIGINT lets it drop its pidfile; SIGKILL is the fallback."""
function stop_e2e_proc!(proc::Base.Process)
    process_running(proc) || return nothing
    try
        run(pipeline(`kill -INT $(getpid(proc))`; stdout = devnull, stderr = devnull))
    catch
    end
    t0 = time()
    while process_running(proc) && (time() - t0) < 10
        sleep(0.05)
    end
    if process_running(proc)
        kill(proc)
    end
    wait(proc)
    return nothing
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
    cp(string(controller_key, ".pub"), auth; force = true)
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
    proc = run(`$sshd -D -f $cfg -E $log`; wait = false)::Base.Process
    for _ in 1:50
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

function write_remote_julia(path::AbstractString, env::Dict{String, String})
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
# of SSH with no Test output until they finish. Macros below run while this
# file expands, before the suite body, so `length(_E2E_PLAN)` is the step count.
const _E2E_PLAN = String[]
const _E2E_I = Ref(0)

function _e2e_push!(label::AbstractString)
    lab = String(label)
    lab in _E2E_PLAN && error("duplicate e2e step: $lab")
    push!(_E2E_PLAN, lab)
    return nothing
end

"""Register one literal step. The printed index is this step's place in `_E2E_PLAN`."""
macro e2e_announce(label)
    label isa String || error("@e2e_announce needs a string literal")
    _e2e_push!(label)
    lab = String(label)
    return quote
        _e2e_print($lab)
    end
end

"""Register loop steps in run order. The loop then calls `_e2e_print` with each label."""
macro e2e_plan(labels...)
    for lab in labels
        lab isa String || error("@e2e_plan needs string literals")
        _e2e_push!(lab)
    end
    return :(nothing)
end

function _e2e_print(label::AbstractString)
    _E2E_I[] += 1
    i = _E2E_I[]
    1 <= i <= length(_E2E_PLAN) || error("e2e step $i is outside 1:$(length(_E2E_PLAN))")
    planned = _E2E_PLAN[i]
    planned == label || error("e2e step $i is $(repr(planned)), ran $(repr(label))")
    println("[$i/$(length(_E2E_PLAN))]  $label")
    flush(stdout)
    return nothing
end

@testset "Queue SSH E2E (docker-ssh)" verbose = true begin
    withenv(SSH_ENV...) do
        kit = kit_root()
        @testset "pipeline_* demos are Kit API scripts, not Queue jobs" begin
            @e2e_announce "pipeline_* demos are Kit API scripts, not Queue jobs"
            @test isfile(joinpath(kit, "demos", "without_kit", "pipeline_pi.jl"))
            @test isfile(joinpath(kit, "demos", "with_kit", "pipeline_square.jl"))
            pi_src = read(joinpath(kit, "demos", "without_kit", "pipeline_pi.jl"), String)
            sq_src = read(joinpath(kit, "demos", "with_kit", "pipeline_square.jl"), String)
            @test occursin("go!", pi_src)
            @test occursin("pipeline!", sq_src)
        end

        stage_kit_demos!(JOB_PROJECT)

        @testset "setup! deploys example job (Kit demos + DistSSHKit)" begin
            @e2e_announce "setup! deploys example job (Kit demos + DistSSHKit)"
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
            require_remote_demos!()
            # This tree lists DistSSHKit in [deps], so Kit 0.7.2 still uses
            # `--project=` here (not pkgdir).
            DistSSHQueue._queue_local_instantiate!(JOB_PROJECT)
            @test isfile(joinpath(JOB_PROJECT, "Manifest.toml"))
        end

        mktempdir() do d
            host = HOSTS[1]
            token = "child:$(host):1"

            @testset "Kit go/drive/ride demos through serve" begin
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
                    (
                        :ride,
                        joinpath(JOB_PROJECT, "demos", "ride", "map_echo.jl"),
                        "map_echo",
                        String[],
                        nothing,
                        "1,4,9,16,25,36,49,64",
                    ),
                )
                @e2e_plan "pi_file" "pi_echo" "square_file" "square_echo" "map_echo"
                for (kind, script, label, args, artifact, needle) in cases
                    @testset "$label" begin
                        _e2e_print(label)
                        case_store = joinpath(d, "store_$label.toml")
                        out = joinpath(JOB_PROJECT, "e2e_kit_out", label)
                        isdir(out) && rm(out; recursive = true)
                        q = Queue(; store = case_store)
                        id = enqueue_kit!(q, kind, script, token; out = out, args = args)
                        @test job(q, id).kind === kind
                        q = Queue(; store = case_store)
                        load!(q)
                        wait_tries = kind === :drive ? DRIVE_WAIT_TRIES : GO_WAIT_TRIES
                        st = drive_until_terminal!(q, id; tries = wait_tries)
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
                        elseif needle !== nothing
                            # Detached `execute!` sends the child stdout to `run_dir/kit.out`.
                            # Quiet drops Kit chrome, not this script `println`.
                            rundir = get(row.kwargs, "run_dir", nothing)
                            @test rundir isa AbstractString
                            if rundir isa AbstractString
                                kit_out = joinpath(rundir, "kit.out")
                                @test isfile(kit_out)
                                @test occursin(needle, read(kit_out, String))
                            end
                        end
                    end
                end
            end

            @testset "go on child:HOST:2" begin
                @e2e_announce "go on child:HOST:2"
                # One job, two Kit slots on the same worker. `step!` still runs
                # a single row; this checks the `:2` token is accepted and finishes.
                wide = "child:$(host):2"
                store_w = joinpath(d, "wide.toml")
                echo = joinpath(JOB_PROJECT, "demos", "without_kit", "pi_echo.jl")
                out_w = joinpath(JOB_PROJECT, "e2e_kit_out", "wide")
                isdir(out_w) && rm(out_w; recursive = true)
                q = Queue(; store = store_w)
                id = enqueue_kit!(q, :go, echo, wide; out = out_w, args = GO_N)
                @test job(q, id).hosts == [wide]
                q = Queue(; store = store_w)
                load!(q)
                st = drive_until_terminal!(q, id)
                st === :done || @warn "job not done" state = st error = job(q, id).error
                @test st === :done
                manifest = find_named(out_w, "go_manifest.txt")
                @test manifest !== nothing
                if manifest !== nothing
                    text = read(manifest, String)
                    @test occursin("slots=2", text)
                    @test count("kind=child", text) == 2
                end
            end

            @testset "FIFO one Kit job at a time" begin
                @e2e_announce "FIFO one Kit job at a time"
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
                @e2e_announce "cancel queued skips that row"
                store_c = joinpath(d, "cancel.toml")
                echo = joinpath(JOB_PROJECT, "demos", "without_kit", "pi_echo.jl")
                h = Queue(; store = store_c)
                outs = [joinpath(JOB_PROJECT, "e2e_kit_out", "skip_$i") for i in 1:3]
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
                @e2e_announce "cancel running then the next queued row"
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
            @testset "0.9.6 CLI warnings and rejects" begin
                @e2e_announce "0.9.6 CLI warnings and rejects"
                # No worker SSH. `status` / `watch` need a config file or they
                # reject the hop before parsing `--interval`. Do not set HOME:
                # the juliaup shim would install into that home.
                mktempdir() do d
                    cfg = joinpath(d, "config.toml")
                    store = joinpath(d, "jobs.toml")
                    env = Dict{String, String}(
                        "JULIA_DEPOT_PATH" => julia_depot_path_env(),
                        "DISTSSHQUEUE_CONFIG" => cfg,
                        "DISTSSHQUEUE_STORE" => store,
                        "DISTSSHKIT_YES" => "",
                        "DISTSSHKIT_QUIET" => "1",
                        "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
                    )
                    @test capture_cli(addenv(qcmd(["setup"]), env...))[1] == 0
                    @test isfile(cfg)

                    for verb in ("serve", "status", "watch"), raw in ("nan", "inf")
                        code, _, err = capture_cli(addenv(qcmd([verb, "--interval", raw]), env...))
                        @test code == 1
                        @test occursin("Error:", err)
                        @test occursin("must be finite", err)
                    end

                    neg_store = joinpath(d, "neg.toml")
                    code, out, err = capture_cli(
                        addenv(
                            qcmd(["serve", "--interval", "-0.1"]),
                            merge(env, Dict("DISTSSHQUEUE_STORE" => neg_store))...,
                        ),
                    )
                    @test code == 1
                    @test count("will require --interval > 0", out) == 1
                    @test occursin("cannot sleep", err)

                    zstore = joinpath(d, "zero.toml")
                    zout = joinpath(d, "zero.out")
                    zerr = joinpath(d, "zero.err")
                    proc = run(
                        pipeline(
                            addenv(
                                qcmd(["serve", "--interval", "0"]),
                                merge(env, Dict("DISTSSHQUEUE_STORE" => zstore))...,
                            );
                            stdout = zout,
                            stderr = zerr,
                        );
                        wait = false,
                    )
                    ready = false
                    try
                        for _ in 1:120
                            DistSSHQueue.serve_alive(zstore) && (ready = true; break)
                            process_running(proc) || break
                            sleep(0.5)
                        end
                        @test ready
                    finally
                        stop_e2e_proc!(proc)
                        DistSSHQueue.stop_serve!(zstore)
                    end
                    ztext = isfile(zout) ? read(zout, String) : ""
                    @test count("will require --interval > 0", ztext) == 1

                    @test capture_cli(addenv(qcmd(["add-host", "parent"]), env...))[1] == 0
                    decline = joinpath(d, "decline.txt")
                    write(decline, "no\n")
                    code, out, _ = capture_cli(
                        addenv(qcmd(["up", "default", "1.13"]), env...);
                        stdin = decline,
                    )
                    @test code == 0
                    @test count("will exit 1", out) == 1
                    @test !occursin("✓ juliaup", out)

                    code, out, err = capture_cli(
                        addenv(
                            qcmd(["status"]),
                            merge(env, Dict("DISTSSHQUEUE_STORE" => "~/distsshqueue-e2e-tilde/jobs.toml"))...,
                        ),
                    )
                    @test code == 0
                    @test count("starts with ~", out) == 1
                    @test occursin("0.10 will reject", out)
                    @test !occursin("Error:", err)

                    dead = joinpath(d, "dead.toml")
                    script = joinpath(d, "a.jl")
                    write(script, "1\n")
                    rundir = joinpath(d, "run")
                    mkpath(rundir)
                    write(joinpath(rundir, "kit.pid"), "99999999\n")
                    DistSSHQueue.save_jobs(
                        dead,
                        [
                            DistSSHQueue.Job(;
                                kind = :go,
                                script = script,
                                hosts = ["parent"],
                                state = :running,
                                kwargs = Dict{String, Any}("run_dir" => rundir),
                            ),
                        ],
                    )
                    before = read(dead, String)
                    code, out, _ = capture_cli(
                        addenv(qcmd(["status"]), merge(env, Dict("DISTSSHQUEUE_STORE" => dead))...),
                    )
                    @test code == 0
                    @test count("kit.pid is dead", out) == 1
                    @test read(dead, String) == before

                    home = joinpath(d, "tdhome")
                    mkpath(home)
                    code, out, err = capture_cli(
                        addenv(qcmd(["teardown", "--home", home, "--config", cfg, "--write-only"]), env...),
                    )
                    @test code == 0
                    @test occursin("Would remove", out)
                    @test !occursin("Removed", out)
                    @test isempty(err) || !occursin("still deletes", err)
                    @test isfile(cfg)

                    shome = joinpath(d, "slink")
                    mkpath(joinpath(shome, ".distsshqueue"))
                    real = joinpath(d, "real.toml")
                    write(real, "store = $(repr(joinpath(d, "unused.toml")))\n")
                    link = joinpath(shome, ".distsshqueue", "config.toml")
                    symlink(real, link)
                    code, out, _ = capture_cli(
                        addenv(
                            qcmd(["teardown", "--home", shome, "--config", link, "--write-only"]),
                            merge(
                                env,
                                Dict(
                                    "DISTSSHQUEUE_CONFIG" => link,
                                    "DISTSSHQUEUE_STORE" => joinpath(d, "unused.toml"),
                                ),
                            )...,
                        ),
                    )
                    @test code == 0
                    @test occursin("Would remove", out)
                    @test count("will refuse", out) == 1
                    @test !occursin("Removed", out)
                    @test islink(link)
                    @test isfile(real)
                end
            end

            @testset "autoserve reads the enable unit" begin
                @e2e_announce "autoserve reads the enable unit"
                # `--queue-env` is a symlink to the instantiated test project.
                # `canonical_local_path` keeps that path, so a serve that ignored
                # the unit and used `default_queue_env` would show a different
                # `--project=`. HOME is the temp home: `homedir()` follows it,
                # and `JULIA_DEPOT_PATH` stays the real depot.
                mktempdir() do d
                    e2e_home = joinpath(d, "home")
                    mkpath(e2e_home)
                    cfg = joinpath(d, "config.toml")
                    store = joinpath(d, "jobs.toml")
                    qenv = joinpath(d, "qenv")
                    symlink(test_project, qenv)
                    script = joinpath(d, "once.jl")
                    write(script, "println(1)\n")
                    outdir = joinpath(d, "out")
                    env = Dict{String, String}(
                        "HOME" => e2e_home,
                        "JULIA_DEPOT_PATH" => julia_depot_path_env(),
                        "DISTSSHQUEUE_CONFIG" => cfg,
                        "DISTSSHQUEUE_STORE" => store,
                        "DISTSSHKIT_YES" => "1",
                        "DISTSSHKIT_QUIET" => "1",
                        "DISTSSHQUEUE_NO_AUTOSERVE" => "",
                        DistSSHQueue.NO_KIT_SETUP_ENV => "1",
                    )
                    enabled = false
                    try
                        @test capture_cli(addenv(qcmd(["setup"]), env...))[1] == 0
                        @test capture_cli(addenv(qcmd(["add-host", "parent"]), env...))[1] == 0
                        @test capture_cli(
                            addenv(
                                qcmd(["enable", "--write-only", "--queue-env", qenv, "--julia", E2E_JULIA]),
                                env...,
                            ),
                        )[1] == 0
                        enabled = true
                        spec = DistSSHQueue.enabled_serve_command(; home = e2e_home)
                        @test spec !== nothing
                        @test spec.project == DistSSHQueue.canonical_local_path(qenv)
                        @test spec.project != DistSSHQueue.canonical_local_path(test_project)
                        @test spec.julia == DistSSHQueue.canonical_local_path(E2E_JULIA)
                        tag = get(ENV, "DISTSSHQUEUE_SERVE_TAG", "")
                        @test !isempty(tag)
                        code, _, err = capture_cli(
                            addenv(
                                qcmd(["submit", "go", "parent:1", "--output-dir", outdir, script]),
                                env...,
                            ),
                        )
                        @test code == 0
                        @test !occursin("Error:", err)
                        proj_arg = "--project=$(spec.project)"
                        needle = "DISTSSHQUEUE_SERVE_TAG=$tag"
                        seen = false
                        for _ in 1:40
                            text = try
                                read(`ps axeww`, String)
                            catch
                                ""
                            end
                            for line in eachsplit(text, '\n')
                                occursin(needle, line) || continue
                                occursin(proj_arg, line) || continue
                                occursin("-m DistSSHQueue serve", line) || continue
                                occursin(spec.julia, line) || continue
                                seen = true
                                break
                            end
                            seen && break
                            sleep(0.25)
                        end
                        @test seen
                    finally
                        DistSSHQueue.stop_serve!(store)
                        DistSSHQueue.reap_serve_tag!(get(ENV, "DISTSSHQUEUE_SERVE_TAG", ""))
                        if enabled
                            capture_cli(addenv(qcmd(["disable", "--write-only"]), env...))
                        end
                    end
                end
            end

            mktempdir() do d
                e2e_home = joinpath(d, "home")
                mkpath(e2e_home)
                cfg = joinpath(e2e_home, ".distsshqueue", "config.toml")
                store = joinpath(e2e_home, ".distsshqueue", "jobs.toml")
                token = "child:$(HOSTS[1]):1"
                script = joinpath(JOB_PROJECT, "demos", "without_kit", "pi_echo.jl")
                @test isfile(script)

                host_env = Dict{String, String}(
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
                    DistSSHQueue.NO_KIT_SETUP_ENV => "1",
                )

                @testset "queue-host verbs (logged in; omit qhost:)" begin
                    @e2e_announce "queue-host verbs (logged in; omit qhost:)"
                    env = merge(host_env, Dict("DISTSSHQUEUE_NO_AUTOSERVE" => "1"))
                    @test run_cli(addenv(qcmd(["setup"]), env...)).exitcode == 0
                    @test isfile(cfg)
                    @test run_cli(addenv(qcmd(["add-host", "parent", "child:$(HOSTS[1])"]), env...)).exitcode == 0
                    @test run_cli(addenv(qcmd(["enable", "--write-only", "--queue-env", test_project, "--julia", E2E_JULIA]), env...)).exitcode == 0
                    rel = if Sys.isapple()
                        joinpath("Library", "LaunchAgents", "org.distsshqueue.serve.plist")
                    else
                        joinpath(".config", "systemd", "user", "distsshqueue.serve.service")
                    end
                    unit = joinpath(e2e_home, rel)
                    @test unit == (
                        Sys.isapple() ? DistSSHQueue.launch_agent_path(; home = e2e_home) :
                            DistSSHQueue.systemd_user_path(; home = e2e_home)
                    )
                    @test isfile(unit)
                    @test !isfile(
                        joinpath(
                            e2e_home, Sys.isapple() ?
                                joinpath(".config", "systemd", "user", "distsshqueue.serve.service") :
                                joinpath("Library", "LaunchAgents", "org.distsshqueue.serve.plist")
                        )
                    )
                    body = read(unit, String)
                    @test occursin("DistSSHQueue", body)
                    @test occursin("serve", body)
                    @test occursin("--project=", body)
                    @test occursin("--startup-file=no", body)
                    @test run_cli(addenv(qcmd(["disable", "--write-only"]), env...)).exitcode == 0
                    @test !isfile(unit)

                    # Glue only: header + submit template footer. Table layout is Kit E2E.
                    size_env = merge(env, Dict("DISTSSHKIT_QUIET" => "0"))
                    inspect_hosts = ["parent"; ["child:$(h)" for h in HOSTS]]
                    size_out = read_cli(
                        addenv(
                            qcmd(["size", "--gb-per-worker", "1.5", inspect_hosts...]),
                            size_env...,
                        )
                    )
                    @test occursin("DistSSHQueue size", size_out)
                    @test occursin("Suggested submit (template):", size_out)
                    for h in HOSTS
                        @test occursin("child:$(h):", size_out)
                    end

                    plan_out = read_cli(addenv(qcmd(["plan", inspect_hosts..., script]), size_env...))
                    @test occursin("DistSSHQueue plan", plan_out)
                    @test occursin("Suggested submit (template):", plan_out)
                    @test occursin("submit go", plan_out) || occursin("submit ride", plan_out) ||
                        occursin("submit drive", plan_out)
                    for h in HOSTS
                        @test occursin("child:$(h):", plan_out)
                    end

                    pool_out = read_cli(
                        addenv(
                            qcmd(["pool", "--gb-per-worker", "1.5", inspect_hosts...]),
                            size_env...,
                        )
                    )
                    @test occursin("DistSSHQueue pool", pool_out)
                    @test occursin("Suggested submit (template):", pool_out)
                    @test occursin("no RSS; use size to measure", pool_out)
                    for h in HOSTS
                        @test occursin("child:$(h):", pool_out)
                    end
                    @test !isfile(store)

                    serve_proc = run(pipeline(addenv(qcmd(["serve", "--interval", "0.2"]), env...); stdout = devnull, stderr = devnull); wait = false)
                    try
                        outdir = joinpath(JOB_PROJECT, "e2e_kit_out", "cli_on_host")
                        isdir(outdir) && rm(outdir; recursive = true)
                        id = read_cli(addenv(qcmd(["submit", "go", token, "--output-dir", outdir, script, GO_N...]), env...))
                        @test !isempty(id)
                        wait_store_job(store, id, (:done,); tries = GO_WAIT_TRIES)
                        listed = read_cli(addenv(qcmd(["status"]), env...))
                        @test status_shows_id(listed, id)
                        @test occursin("done", listed)
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
                    @e2e_announce "client qhost: (real ssh to loopback queue host)"
                    sshd_dir = joinpath(d, "sshd")
                    mkpath(sshd_dir)
                    port = free_loopback_port()
                    qh_store = joinpath(e2e_home, ".distsshqueue", "qhost-jobs.toml")
                    gi = joinpath(JOB_PROJECT, ".gitignore")
                    gi_body = read(gi, String)
                    sshd_proc = start_loopback_sshd(sshd_dir, port, controller_key)
                    try
                        ssh_cfg = write_ssh_config_with_qhost(
                            joinpath(d, "ssh_config"), port, ssh_login_user(),
                            SSH_CONFIG, controller_key,
                        )
                        probe_err = IOBuffer()
                        probe = run(pipeline(ignorestatus(`ssh -F $ssh_cfg -o ConnectTimeout=5 -o LogLevel=ERROR distsshqueue-qh true`); stdout = devnull, stderr = probe_err))
                        if probe.exitcode != 0
                            client = String(take!(probe_err))
                            server = read(joinpath(sshd_dir, "sshd.log"), String)
                            error("loopback ssh to distsshqueue-qh failed: $client$server")
                        end
                        # Stage rsync honors `.gitignore` (`Manifest.toml` is listed).
                        # This job lists DistSSHKit in [deps], so Kit 0.7.2 still
                        # uses `--project=` of the stage; the Manifest [2/11] wrote
                        # must reach it. Do not instantiate that Manifest on
                        # workers (path-dev Kit).
                        write(gi, replace(gi_body, r"^Manifest\.toml\r?\n?"m => ""))
                        write(joinpath(JOB_PROJECT, ".distsshqueue-backup"), "keep\n")
                        mkpath(joinpath(JOB_PROJECT, ".distsshqueue"))
                        write(joinpath(JOB_PROJECT, ".distsshqueue", "ticket"), "nope\n")
                        remote_env = Dict{String, String}(
                            "HOME" => e2e_home,
                            "JULIA_DEPOT_PATH" => julia_depot_path_env(),
                            "JULIA_PROJECT" => test_project,
                            "DISTSSHQUEUE_CONFIG" => cfg,
                            "DISTSSHQUEUE_STORE" => qh_store,
                            "DISTSSHKIT_YES" => "1",
                            "DISTSSHKIT_QUIET" => get(ENV, "DISTSSHKIT_QUIET", "1"),
                            "DISTRIBUTED_SSH_OPTS" => "-F $(SSH_CONFIG)",
                            "DISTRIBUTED_REMOTE_PROJECT_ROOT" => REMOTE_ROOT,
                            DistSSHQueue.NO_KIT_SETUP_ENV => "1",
                        )
                        wrapper = write_remote_julia(joinpath(d, "remote-julia"), remote_env)
                        client_env = Dict{String, String}(
                            "DISTSSHKIT_YES" => "1",
                            "DISTSSHQUEUE_WATCH_TICKS" => "1",
                            "DISTRIBUTED_SSH_OPTS" => "-F $ssh_cfg",
                            "DISTRIBUTED_PROJECT_ROOT" => JOB_PROJECT,
                        )
                        qh(rest) = qcmd(["qhost:distsshqueue-qh", "--remote-julia", wrapper, "--queue-env", test_project, rest...])

                        reject_err = IOBuffer()
                        rejected = run(pipeline(ignorestatus(addenv(qh(["setup"]), client_env...)); stdout = devnull, stderr = reject_err))
                        @test rejected.exitcode != 0
                        @test occursin("client token", String(take!(reject_err)))

                        outdir = joinpath(JOB_PROJECT, "e2e_kit_out", "qhost")
                        isdir(outdir) && rm(outdir; recursive = true)
                        id1 = read_cli(addenv(qh(["submit", "go", token, "--output-dir", outdir, script, GO_N...]), client_env...))
                        @test !isempty(id1)
                        @test isfile(DistSSHQueue.submit_ticket_path(JOB_PROJECT, id1))
                        stage = joinpath(e2e_home, ".distsshqueue", "stage", id1)
                        @test isdir(stage)
                        listed = DistSSHQueue.stage_send_list(JOB_PROJECT)
                        @test listed isa Vector{String}
                        if listed isa Vector{String}
                            env = DistSSHRun.resolve_pkg_env(JOB_PROJECT)
                            raw = DistSSHRun.rsync_send_list(env.env_dir, env)
                            @test raw isa Vector
                            if raw isa Vector
                                want = String[
                                    String(rel) for rel in raw if !(".distsshqueue" in split(String(rel), '/'))
                                ]
                                @test listed == want
                            end
                            @test ".distsshqueue-backup" in listed
                            @test !any(rel -> ".distsshqueue" in split(rel, '/'), listed)
                            for rel in listed
                                @test ispath(joinpath(stage, rel))
                            end
                            want_set = Set(listed)
                            for (root, _, files) in walkdir(stage)
                                relroot = relpath(root, stage)
                                for f in files
                                    rel = relroot == "." ? f : joinpath(relroot, f)
                                    @test replace(rel, '\\' => '/') in want_set
                                end
                            end
                        end
                        @test isfile(joinpath(stage, ".distsshqueue-backup"))
                        @test read(joinpath(stage, ".distsshqueue-backup"), String) == "keep\n"
                        @test !ispath(joinpath(stage, ".distsshqueue"))
                        wait_store_job(qh_store, id1, (:done,); tries = 600)
                        listed = read_cli(addenv(qh(["status"]), client_env...))
                        @test status_shows_id(listed, id1)
                        @test occursin("done", listed)
                        wout = read_cli(addenv(qh(["watch", "--interval", "0.05"]), client_env..., "DISTSSHKIT_QUIET" => "0"))
                        @test occursin("serve", wout)
                        @test occursin("running", wout)

                        id_f = read_cli(addenv(qh(["submit", "go", token, script, GO_N...]), client_env...))
                        @test !isempty(id_f)
                        row_f = wait_store_job(qh_store, id_f, (:done,); tries = 600)
                        @test row_f.state === :done
                        fetched = read_cli(addenv(qh(["fetch", id_f]), client_env...))
                        @test occursin(first(id_f, 8), fetched)
                        @test isfile(joinpath(fetched, "kit.result"))
                        into_f = joinpath(JOB_PROJECT, "e2e_fetch_into")
                        isdir(into_f) && rm(into_f; recursive = true)
                        mkpath(into_f)
                        write(joinpath(into_f, "old_result.csv"), "keep\n")
                        fetched_into = read_cli(
                            addenv(
                                qh(["fetch", id_f, "--into", into_f, "--force"]),
                                client_env...,
                            )
                        )
                        @test fetched_into == DistSSHQueue.canonical_local_path(into_f) ||
                            occursin("e2e_fetch_into", fetched_into)
                        @test isfile(joinpath(into_f, "old_result.csv"))
                        @test isfile(joinpath(into_f, "kit.result"))
                        @test read(joinpath(into_f, "old_result.csv"), String) == "keep\n"
                        rm(fetched; recursive = true, force = true)
                        rm(into_f; recursive = true, force = true)

                        # Occupy serve on this box (`parent:1`). Wait until `kit.pid`
                        # is live so a second serve does not drop the hold and
                        # finish the worker `pi_echo` before cancel.
                        hold = joinpath(d, "hold.jl")
                        write(hold, "while true; sleep(1); end\n")
                        cancel_out = joinpath(JOB_PROJECT, "e2e_kit_out", "qhost_cancel")
                        isdir(cancel_out) && rm(cancel_out; recursive = true)
                        id2 = read_cli(addenv(qh(["submit", "go", "parent:1", "--output-dir", cancel_out, hold]), client_env...))
                        wait_store_job(qh_store, id2, (:running,); tries = 600)
                        wait_store_kit_pid(qh_store, id2)
                        id3 = read_cli(addenv(qh(["submit", "go", token, script, GO_N...]), client_env...))
                        wait_store_job(qh_store, id3, (:queued,); tries = 600)
                        cancelled = read_cli(addenv(qh(["cancel", id3]), client_env...))
                        @test cancelled == id3
                        wait_store_job(qh_store, id3, (:cancelled,); tries = 600)
                        after = read_cli(addenv(qh(["status"]), client_env...))
                        @test status_shows_id(after, id2)
                        @test occursin("cancelled", after)

                        @test run_cli(addenv(qh(["stop"]), client_env...)).exitcode == 0
                        confirm = String[]
                        withenv(
                            "DISTSSHQUEUE_CONFIG" => cfg,
                            "DISTSSHQUEUE_STORE" => qh_store,
                        ) do
                            for p in DistSSHQueue.teardown_targets(; home = e2e_home, config = cfg)
                                ispath(p) || continue
                                push!(confirm, "--confirm-path", p)
                            end
                        end
                        @test run_cli(addenv(qh(["teardown", "--home", e2e_home, "--config", cfg, "--write-only", confirm...]), client_env...)).exitcode == 0
                    finally
                        write(gi, gi_body)
                        DistSSHQueue.stop_serve!(qh_store)
                        DistSSHQueue.stop_serve!(store)
                        stop_loopback_sshd(sshd_proc)
                    end
                end
            end
        end
        @test _E2E_I[] == length(_E2E_PLAN)
    end
end
