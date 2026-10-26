using Test
using Dates
using DistSSHRun
using DistSSHQueue

struct _KitOdd end
Base.hasproperty(::_KitOdd, s::Symbol) = s === :ok
Base.getproperty(::_KitOdd, ::Symbol) = throw(KeyError(:ok))

struct _KitSetupOk
    modes::Vector{Symbol}
end

function (p::_KitSetupOk)(_, mode::Symbol; gitignore::Bool = true)
    push!(p.modes, mode)
    return (; ok = true, gitignore)
end

struct _KitSetupFail
    bad::Symbol
    throw_on_bad::Bool
end

function (p::_KitSetupFail)(_, mode::Symbol; gitignore::Bool = true)
    mode === p.bad || return (; ok = true, gitignore)
    p.throw_on_bad && error(mode === :rsync ? "rsync failed" : "failed")
    return (; ok = false, gitignore)
end

const _SetupNote = @NamedTuple{host::String, kind::Symbol, message::String}

struct _KitSetupWarn
    ok::Bool
    warnings::Vector{_SetupNote}
end

function (p::_KitSetupWarn)(_, mode::Symbol; gitignore::Bool = true)
    mode === :check || return (; ok = true, gitignore)
    return (; ok = p.ok, gitignore, warnings = p.warnings)
end

struct _StageRsyncProbe
    modes::Vector{Symbol}
    gitignore::Vector{Bool}
    manifest_at::Dict{Symbol, Bool}
    manifest::String
end

function (p::_StageRsyncProbe)(_, mode::Symbol; gitignore::Bool = true)
    push!(p.modes, mode)
    if mode === :rsync
        empty!(p.gitignore)
        push!(p.gitignore, gitignore)
    end
    p.manifest_at[mode] = isfile(p.manifest)
    return (; ok = true)
end

function _stage_rsync_setup!(proj::String)
    script = joinpath(proj, "s.jl")
    write(script, "1\n")
    j = DistSSHQueue.Job(;
        kind = :go,
        script = script,
        hosts = ["child:w1:1"],
        kwargs = Dict{String, Any}("project" => proj),
    )
    manifest = joinpath(proj, "Manifest.toml")
    modes = Symbol[]
    gitignore = Bool[]
    manifest_at = Dict{Symbol, Bool}()
    phases = String[]
    withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
        DistSSHQueue._queue_kit_setup!(
            j,
            ph -> ph isa AbstractString && push!(phases, String(ph));
            kit_setup! = _StageRsyncProbe(modes, gitignore, manifest_at, manifest),
        )
    end
    return (; modes, phases, gitignore = only(gitignore), manifest_at)
end

function _cov_spawn_note!(j, p)
    od = p.output_dir
    od === nothing && return nothing
    j.result_path = String(od)
    return nothing
end

function _cov_hold_kit(; run_dir, output_dir)
    proc = Base.run(`sleep 30`; wait = false)
    kp = DistSSHRun.KitProcess(proc; kind = :go, run_dir = run_dir, output_dir = output_dir)
    return proc::Base.Process, kp
end

function _cov_stop(proc::Base.Process)
    process_running(proc) && kill(proc)
    try
        wait(proc)
    catch
    end
    return nothing
end

function _cov_exec(armed, kp, kind, script, hosts; detached, job_id, kwargs...)
    _ = (kind, script, hosts, detached, job_id, kwargs)
    armed[] = true
    return kp
end

function _cov_exec_done(kp, kind, script, hosts; detached, job_id, kwargs...)
    _ = (kind, script, hosts, detached, job_id, kwargs)
    return kp
end

function _cov_term(seen, side; kind)
    _ = kind
    seen[] = String(side)
    return nothing
end

function _cov_term_unused(side; kind)
    _ = (side, kind)
    error("terminate must not run")
end

function _wait_state(q, id, st; tries = 200)
    for _ in 1:tries
        job(q, id).state === st && return nothing
        sleep(0.01)
    end
    error("job $id stayed $(job(q, id).state), expected $st")
end

@testset "submit! rejects pre-0.4 host tokens" begin
    q = Queue(; runner = _ -> nothing)
    @test_throws ArgumentError submit!(q, "a.jl", "parenthost:2")
    @test_throws ArgumentError submit!(q, "a.jl", "worker:2")
    @test_throws ArgumentError submit!(q, "a.jl", "h1")
    @test_throws ArgumentError submit!(q, "a.jl", "64")
    id = submit!(q, "a.jl", "parent:1", "child:w1:2")
    @test job(q, id).hosts == ["parent:1", "child:w1:2"]
end

@testset "submit! rejects Kit names not on allowed" begin
    q = Queue(; runner = _ -> nothing, allowed = ["parent", "child:host1"])
    id = submit!(q, "a.jl", "parent:2", "child:host1:4")
    @test job(q, id).hosts == ["parent:2", "child:host1:4"]
    @test_throws ArgumentError submit!(q, "b.jl", "child:other:1")
    tokened = Queue(; runner = _ -> nothing, allowed = ["child:host1"])
    gid = submit!(tokened, "g.jl", "child:host1:4")
    @test job(tokened, gid).hosts == ["child:host1:4"]
    mixed = Queue(; runner = _ -> nothing, allowed = ["parent"])
    @test_throws ArgumentError submit!(mixed, "m.jl", "parent:1", "child:other:1")
    @test isempty(jobs(mixed))
    closed = Queue(; runner = _ -> nothing, allowed = String[])
    @test_throws ArgumentError submit!(closed, "c.jl", "parent:1")
    open = Queue(; runner = _ -> nothing)
    @test submit!(open, "d.jl", "child:any:1") isa String
    @test_throws ArgumentError Queue(; allowed = ["host1"])
    @test_throws ArgumentError Queue(; allowed = ["parent"], follow_config = true)
end

@testset "submit! rejects two projects that share a worker path" begin
    mktempdir() do d
        a = joinpath(d, "a")
        b = joinpath(d, "b")
        mkpath(a)
        mkpath(b)
        write(joinpath(a, "Project.toml"), "[deps]\n")
        write(joinpath(b, "Project.toml"), "[deps]\n")
        write(joinpath(a, "x.jl"), "1\n")
        write(joinpath(b, "x.jl"), "1\n")
        q = Queue(; runner = _ -> nothing)
        shared = "/tmp/distsshqueue-shared-remote"
        withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => shared) do
            id = submit!(q, joinpath(a, "x.jl"), "parent:1"; project = a)
            @test DistSSHQueue.canonical_local_path(String(job(q, id).kwargs["project"])) ==
                DistSSHQueue.canonical_local_path(a)
            @test_throws ArgumentError submit!(q, joinpath(b, "x.jl"), "parent:1"; project = b)
            id2 = submit!(q, joinpath(a, "x.jl"), "parent:1"; project = a)
            @test job(q, id2).state === :queued
        end
        q2 = Queue(; runner = _ -> nothing)
        submit!(q2, joinpath(a, "x.jl"), "parent:1"; project = a, remote = "/r/one")
        @test_throws ArgumentError submit!(q2, joinpath(b, "x.jl"), "parent:1"; project = b, remote = "/r/one")
        submit!(q2, joinpath(b, "x.jl"), "parent:1"; project = b, remote = "/r/two")
        @test DistSSHQueue.kit_worker_root(a, Dict{String, Any}("remote" => "~/jobs/x")) == "~/jobs/x"
        @test DistSSHQueue.kit_worker_root(a, Dict{String, Any}("remote" => "~/jobs/x")) !=
            DistSSHQueue.canonical_local_path("~/jobs/x")
        @test DistSSHQueue.kit_worker_root(a, Dict{String, Any}("remote" => "/r/one")) ==
            DistSSHQueue.remote_env_project_root("/r/one")
        q3 = Queue(; runner = _ -> nothing)
        submit!(q3, joinpath(a, "x.jl"), "parent:1"; project = a, remote = "~/jobs/x")
        submit!(q3, joinpath(b, "x.jl"), "parent:1"; project = b, remote = DistSSHQueue.canonical_local_path("~/jobs/x"))
    end
end

@testset "submit! keeps a client-assigned job id" begin
    want = DistSSHQueue.new_job_id()
    q = Queue(; runner = _ -> nothing)
    id = submit!(q, "a.jl", "parent:1"; id = want)
    @test id == want
    @test job(q, id).id == want
    @test_throws ArgumentError submit!(q, "b.jl", "parent:1"; id = want)
    @test length(jobs(q)) == 1
end

@testset "two stage trees from one client path do not share a worker root" begin
    mktempdir() do d
        s1 = joinpath(d, ".distsshqueue", "stage", DistSSHQueue.new_job_id())
        s2 = joinpath(d, ".distsshqueue", "stage", DistSSHQueue.new_job_id())
        mkpath(s1)
        mkpath(s2)
        write(joinpath(s1, "x.jl"), "1\n")
        write(joinpath(s2, "x.jl"), "1\n")
        withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => nothing) do
            q = Queue(; runner = _ -> nothing)
            id1 = submit!(q, joinpath(s1, "x.jl"), "parent:1"; project = s1)
            id2 = submit!(q, joinpath(s2, "x.jl"), "parent:1"; project = s2)
            @test id1 != id2
            r1 = DistSSHQueue.kit_worker_root(s1, job(q, id1).kwargs)
            r2 = DistSSHQueue.kit_worker_root(s2, job(q, id2).kwargs)
            @test r1 != r2
        end
        shared = "/tmp/distsshqueue-shared-remote"
        withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => shared) do
            q = Queue(; runner = _ -> nothing)
            id1 = submit!(q, joinpath(s1, "x.jl"), "parent:1"; project = s1)
            id2 = submit!(q, joinpath(s2, "x.jl"), "parent:1"; project = s2)
            @test id1 != id2
            @test DistSSHQueue.kit_worker_root(s1, job(q, id1).kwargs) ==
                DistSSHQueue.kit_worker_root(s2, job(q, id2).kwargs)
        end
    end
end

@testset "submit! rejects :N above the allowed max" begin
    q = Queue(; runner = _ -> nothing, allowed = ["parent:2", "child:host1:4"])
    @test submit!(q, "ok.jl", "parent:2", "child:host1:4") isa String
    @test_throws ArgumentError submit!(q, "big.jl", "child:host1:5")
    @test_throws ArgumentError submit!(q, "non.jl", "child:host1")
    @test_throws ArgumentError submit!(q, "p.jl", "parent:3")
end

@testset "follow_config re-reads hosts without a new Queue" begin
    mktempdir() do d
        cfg = joinpath(d, "config.toml")
        store = joinpath(d, "jobs.toml")
        write(cfg, "store = $(repr(store))\nhosts = [\"parent\"]\n")
        withenv("DISTSSHQUEUE_CONFIG" => cfg) do
            q = Queue(; store = store, runner = _ -> nothing, follow_config = true)
            a = submit!(q, "a.jl", "parent:1")
            @test job(q, a).state === :queued
            @test_throws ArgumentError submit!(q, "b.jl", "child:host1:1")
            DistSSHQueue.add_host_names!(cfg, ["child:host1"])
            b = submit!(q, "b.jl", "child:host1:1")
            @test job(q, b).hosts == ["child:host1:1"]
        end
    end
end

@testset "hosts change does not stop running or drop queued" begin
    ev = Base.Event()
    q = Queue(; runner = _ -> wait(ev), allowed = ["parent", "child:host1"])
    run_id = submit!(q, "run.jl", "parent:1")
    queued_id = submit!(q, "q.jl", "child:host1:1")
    @test step!(q) == 1
    @test job(q, run_id).state === :running
    q.allowed = DistSSHQueue.HostAllow("parent" => nothing)
    @test job(q, queued_id).state === :queued
    @test step!(q) == 0
    notify(ev)
    _wait_state(q, run_id, :done)
    @test step!(q) == 1
    _wait_state(q, queued_id, :done)
    @test job(q, queued_id).hosts == ["child:host1:1"]
end

@testset "true FIFO one at a time" begin
    started = String[]
    q = Queue(; runner = j -> (push!(started, j.id); sleep(0.05)))
    a = submit!(q, "a.jl", "child:host1:4")
    b = submit!(q, "b.jl", "child:host1:1")
    @test step!(q) == 1
    @test job(q, a).state === :running
    @test job(q, b).state === :queued
    @test step!(q) == 0
    _wait_state(q, a, :done)
    @test step!(q) == 1
    _wait_state(q, b, :done)
    @test started == [a, b]
end

@testset "drive_until_terminal! leaves the next row queued" begin
    n = Ref(0)
    hold = Base.Event()
    q = Queue(;
        runner = _ -> (n[] += 1; n[] == 1 ? nothing : wait(hold)),
        allowed = ["child:host1"],
    )
    a = submit!(q, "a.jl", "child:host1:1")
    b = submit!(q, "b.jl", "child:host1:1")
    @test drive_until_terminal!(q, a; tries = 50, sleep_s = 0.01) === :done
    @test job(q, b).state === :queued
    @test step!(q) == 1
    @test job(q, b).state === :running
    notify(hold)
    _wait_state(q, b, :done)
end

@testset "cancel queued; stub running without a script has no output_dir" begin
    q = Queue(; runner = _ -> sleep(0.05))
    a = submit!(q, "a.jl", "parent:2")
    b = submit!(q, "b.jl", "parent:2")
    @test cancel!(q, b)
    @test job(q, b).state === :cancelled
    @test step!(q) == 1
    @test cancel!(q, a)
    @test job(q, a).state === :running
    @test job(q, a).kwargs["cancel"] === true
    @test step!(q) == 0
    _wait_state(q, a, :done)
end

@testset "cancel running without submit output_dir" begin
    mktempdir() do d
        script = joinpath(d, "hold.jl")
        write(script, "1\n")
        ev = Base.Event()
        q = Queue(; runner = _ -> wait(ev))
        id = submit!(q, script, "parent:1"; project = d)
        @test step!(q) == 1
        j = job(q, id)
        @test j.state === :running
        @test j.result_path === nothing
        @test get(j.kwargs, "output_dir", nothing) === nothing
        @test cancel!(q, id)
        @test job(q, id).state === :running
        @test job(q, id).kwargs["cancel"] === true
        @test DistSSHQueue._job_state_disp(job(q, id)) == "stopping"
        run = joinpath(d, ".distsshkit", "runs", "go", "hold_x")
        mkpath(run)
        DistSSHQueue._set_running_kit_meta!(q, id; run_dir = run)
        @test DistSSHQueue.kit_run_dir(job(q, id)) == run
        child = Base.run(`sleep 60`; wait = false)
        write(joinpath(run, "kit.pid"), string(getpid(child)))
        try
            @test cancel!(q, id)
            @test job(q, id).state === :cancelled
            @test !process_running(child)
        finally
            process_running(child) && kill(child)
            wait(child)
        end
        @test job(q, id).result_path === nothing
        notify(ev)
        sleep(0.05)
        @test job(q, id).state === :cancelled
    end
end

@testset "cancel during setup keeps the slot until load!" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        ev = Base.Event()
        q = Queue(; store, runner = _ -> wait(ev))
        a = submit!(q, "a.jl", "parent:1")
        b = submit!(q, "b.jl", "parent:1")
        @test step!(q) == 1
        code = withenv(
            "DISTSSHQUEUE_STORE" => store,
            "DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml"),
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
        ) do
            DistSSHQueue.cancel_cli([first(a, 8)])
        end
        @test code == 0
        DistSSHQueue.reload_keep_live!(q)
        @test job(q, a).state === :running
        @test DistSSHQueue._job_cancel_flag(job(q, a))
        @test step!(q) == 0
        @test job(q, b).state === :queued
        q2 = Queue(; store, runner = _ -> error("must not re-run"))
        load!(q2)
        @test job(q2, a).state === :cancelled
        notify(ev)
        _wait_state(q, a, :cancelled)
    end
    lost = DistSSHQueue.Job(;
        kind = :go,
        script = "a.jl",
        hosts = ["parent:1"],
        state = :running,
        kwargs = Dict{String, Any}("cancel" => true),
    )
    DistSSHQueue.fail_stale_running!([lost])
    @test lost.state === :cancelled
    plain = DistSSHQueue.Job(;
        kind = :go, script = "a.jl", hosts = ["parent:1"], state = :running,
    )
    DistSSHQueue.fail_stale_running!([plain])
    @test plain.state === :failed
    @test occursin("running job marked failed", something(plain.error, ""))
end

@testset "kit setup stops after the current step when cancel is set" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = script,
            hosts = ["child:w1:1"],
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        modes = Symbol[]
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            @test_throws DistSSHQueue._JobCancelled DistSSHQueue._queue_kit_setup!(
                j,
                Returns(nothing);
                kit_setup! = _KitSetupOk(modes),
                cancel_requested = Returns(true),
            )
        end
        @test modes == [:rsync]
        bare = DistSSHQueue.Job(;
            kind = :go,
            script = "a.jl",
            hosts = ["parent:1"],
            kwargs = Dict{String, Any}("project" => joinpath(d, "missing")),
        )
        @test_throws DistSSHQueue._JobCancelled DistSSHQueue.run_kit(
            bare, Returns(nothing); cancel_requested = Returns(true),
        )
        _, help_out, _ = capture_stdio() do
            DistSSHQueue.show_usage(; command = "cancel")
        end
        @test occursin("setup step runs to the end", help_out)
    end
end

@testset "run_kit stops on the cancel flag right after execute!" begin
    @test DistSSHRun.DistSSHBase.is_sigint(InterruptException())
    mktempdir() do d
        rundir = joinpath(d, "run")
        outdir = joinpath(d, "out")
        mkpath(rundir)
        mkpath(outdir)
        proc, kp = _cov_hold_kit(; run_dir = rundir, output_dir = outdir)
        armed = Ref(false)
        seen = Ref{Union{Nothing, String}}(nothing)
        j = DistSSHQueue.Job(;
            kind = :go, script = "a.jl", hosts = ["parent:1"],
        )
        try
            @test_throws DistSSHQueue._JobCancelled DistSSHQueue.run_kit(
                j,
                p -> _cov_spawn_note!(j, p);
                cancel_requested = () -> armed[],
                execute = (args...; kwargs...) -> _cov_exec(armed, kp, args...; kwargs...),
                terminate = (side; kind) -> _cov_term(seen, side; kind),
            )
        finally
            _cov_stop(proc)
        end
        @test seen[] == rundir
        @test !process_running(proc)
    end
    mktempdir() do d
        outdir = joinpath(d, "out")
        mkpath(outdir)
        proc, kp = _cov_hold_kit(; run_dir = nothing, output_dir = outdir)
        armed = Ref(false)
        seen = Ref{Union{Nothing, String}}(nothing)
        j = DistSSHQueue.Job(;
            kind = :go, script = "a.jl", hosts = ["parent:1"],
        )
        try
            @test_throws DistSSHQueue._JobCancelled DistSSHQueue.run_kit(
                j,
                p -> _cov_spawn_note!(j, p);
                cancel_requested = () -> armed[],
                execute = (args...; kwargs...) -> _cov_exec(armed, kp, args...; kwargs...),
                terminate = (side; kind) -> _cov_term(seen, side; kind),
            )
        finally
            _cov_stop(proc)
        end
        @test seen[] == outdir
    end
    mktempdir() do d
        outdir = joinpath(d, "out")
        mkpath(outdir)
        proc = Base.run(`/usr/bin/true`; wait = false)::Base.Process
        kp = DistSSHRun.KitProcess(proc; kind = :go, output_dir = outdir)
        j = DistSSHQueue.Job(;
            kind = :go, script = "a.jl", hosts = ["parent:1"],
        )
        out = DistSSHQueue.run_kit(
            j,
            p -> _cov_spawn_note!(j, p);
            execute = (args...; kwargs...) -> _cov_exec_done(kp, args...; kwargs...),
            terminate = _cov_term_unused,
        )
        @test out == outdir
        @test !process_running(proc)
    end
end

@testset "as_host_allow reads a dict of caps" begin
    allow = DistSSHQueue.as_host_allow(
        Dict("parent:2" => nothing, "child:box" => 3, "" => 9, "lab" => nothing),
    )
    @test allow["parent"] === nothing
    @test allow["box"] == 3
    @test allow["lab"] === nothing
    @test !haskey(allow, "")
    listed = DistSSHQueue.as_host_allow(["child:h:2"])
    @test listed["h"] == 2
    @test DistSSHQueue.as_host_allow(nothing) === nothing
    @test_throws ArgumentError DistSSHQueue.as_host_allow(Dict("child:h" => 0))
end

@testset "kit_run_error_text and a failed kit.result" begin
    ok = DistSSHRun.KitRunResult(true, :go, nothing, nothing, nothing, 0)
    @test DistSSHQueue.kit_run_error_text(ok) == ""
    bad = DistSSHRun.KitRunResult(false, :go, nothing, nothing, "go", 2)
    @test occursin("exit 2", DistSSHQueue.kit_run_error_text(bad))
    @test_throws KeyError DistSSHQueue.kit_run_error_text(_KitOdd())
    mktempdir() do d
        DistSSHRun._write_kit_result_file(
            DistSSHRun.KitRunResult(false, :go, d, nothing, "go", 1),
        )
        j = DistSSHQueue.Job(;
            kind = :go,
            script = "a.jl",
            hosts = ["parent:1"],
            state = :running,
            kwargs = Dict{String, Any}("run_dir" => d),
        )
        DistSSHQueue.settle_lost_kit_child!(j)
        @test j.state === :failed
        @test occursin("exit 1", something(j.error, ""))
    end
end

@testset "serve! on a memory queue steps one job" begin
    ran = Ref(0)
    q = Queue(;
        runner = function (_)
            ran[] += 1
            return nothing
        end
    )
    id = submit!(q, "a.jl", "parent:1")
    t = @async capture_stdio() do
        DistSSHQueue.serve!(q; interval = 0.02)
    end
    for _ in 1:200
        ran[] >= 1 && job(q, id).state === :done && break
        sleep(0.02)
    end
    @test ran[] == 1
    @test job(q, id).state === :done
    schedule(t, InterruptException(); error = true)
    try
        wait(t)
    catch
    end
    @test istaskdone(t)
end

@testset "cancel running records run.toml output_dir not runs/" begin
    mktempdir() do d
        script = joinpath(d, "hold.jl")
        write(script, "1\n")
        ev = Base.Event()
        q = Queue(; runner = _ -> wait(ev))
        id = submit!(q, script, "parent:1"; project = d)
        @test step!(q) == 1
        run = joinpath(d, ".distsshkit", "runs", "go", "hold_x")
        art = joinpath(d, ".distsshkit", "go", "hold_leaf")
        mkpath(run)
        mkpath(art)
        write(joinpath(run, "run.toml"), "output_dir = $(repr(art))\n")
        DistSSHQueue._set_running_kit_meta!(q, id; run_dir = run)
        @test DistSSHQueue.kit_artifact_from_sidecar(run) == art
        child = Base.run(`sleep 60`; wait = false)
        write(joinpath(run, "kit.pid"), string(getpid(child)))
        try
            @test cancel!(q, id)
            @test job(q, id).result_path == art
            @test !process_running(child)
        finally
            process_running(child) && kill(child)
            wait(child)
        end
        notify(ev)
        sleep(0.05)
    end
end

@testset "drive without output_dir does not pin a Queue leaf" begin
    mktempdir() do d
        script = joinpath(d, "hold.jl")
        write(script, "1\n")
        ev = Base.Event()
        q = Queue(; runner = _ -> wait(ev))
        id = submit!(q, script, "parent:1"; kind = :drive, project = d)
        @test step!(q) == 1
        j = job(q, id)
        @test get(j.kwargs, "output_dir", nothing) === nothing
        @test j.result_path === nothing
        @test DistSSHQueue.kit_sidecar_dir(j) === nothing
        notify(ev)
        _wait_state(q, id, :done)
    end
end

@testset "go without output_dir does not pin a Queue leaf" begin
    mktempdir() do d
        script = joinpath(d, "hold.jl")
        write(script, "1\n")
        ev = Base.Event()
        q = Queue(; runner = _ -> wait(ev))
        id = submit!(q, script, "parent:1"; project = d)
        @test step!(q) == 1
        j = job(q, id)
        @test get(j.kwargs, "output_dir", nothing) === nothing
        @test j.result_path === nothing
        @test DistSSHQueue.kit_sidecar_dir(j) === nothing
        notify(ev)
        _wait_state(q, id, :done)
    end
end

@testset "kit_sidecar_dir prefers run_dir over the artifact leaf" begin
    mktempdir() do d
        out = joinpath(d, "out")
        run = joinpath(d, "run")
        mkpath(out)
        mkpath(run)
        j = DistSSHQueue.Job(;
            kind = :go,
            script = "a.jl",
            hosts = ["parent:1"],
            result_path = out,
            kwargs = Dict{String, Any}("output_dir" => out, "run_dir" => run),
        )
        @test DistSSHQueue.kit_output_dir(j) == out
        @test DistSSHQueue.kit_run_dir(j) == run
        @test DistSSHQueue.kit_sidecar_dir(j) == run
    end
end

@testset "serve snapshots run.toml onto the job row" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        script = joinpath(d, "hold.jl")
        write(script, "1\n")
        ev = Base.Event()
        q = Queue(; store, runner = _ -> wait(ev))
        id = submit!(q, script, "parent:1"; project = d)
        @test step!(q) == 1
        run = joinpath(d, ".distsshkit", "runs", "go", "hold_x")
        art = joinpath(d, ".distsshkit", "go", "hold_leaf")
        mkpath(run)
        mkpath(art)
        write(
            joinpath(run, "run.toml"),
            """
            schema = 1
            kind = "go"
            run_dir = $(repr(run))
            output_dir = $(repr(art))
            """,
        )
        DistSSHQueue._set_running_kit_meta!(q, id; run_dir = run)
        snap = DistSSHQueue.kit_run_toml(job(q, id))
        @test snap isa AbstractDict
        @test snap["output_dir"] == art
        rm(joinpath(run, "run.toml"))
        @test DistSSHQueue.output_dir_from_run_toml(DistSSHQueue.kit_run_toml(job(q, id))) == art
        loaded = DistSSHQueue.read_jobs(store)
        i = findfirst(j -> j.id == id, loaded)
        @test i !== nothing
        @test DistSSHQueue.output_dir_from_run_toml(DistSSHQueue.kit_run_toml(loaded[i])) == art
        @test !haskey(DistSSHQueue.execute_kwargs(job(q, id)), :run_toml)
        notify(ev)
        _wait_state(q, id, :done)
    end
end

@testset "load! keeps running without submit output_dir when kit.pid is live" begin
    mktempdir() do d
        script = joinpath(d, "hold.jl")
        write(script, "1\n")
        store = joinpath(d, "jobs.toml")
        ev = Base.Event()
        q = Queue(; store, runner = _ -> wait(ev))
        id = submit!(q, script, "parent:1"; project = d)
        @test step!(q) == 1
        @test job(q, id).result_path === nothing
        run = joinpath(d, ".distsshkit", "runs", "go", "hold_x")
        mkpath(run)
        write(joinpath(run, "kit.pid"), string(getpid()))
        DistSSHQueue._set_running_kit_meta!(q, id; run_dir = run)
        q2 = Queue(; store, runner = _ -> error("must not re-run"))
        load!(q2)
        loaded = job(q2, id)
        @test loaded.state === :running
        @test DistSSHQueue.kit_child_alive(loaded)
        @test DistSSHQueue.kit_run_dir(loaded) == run
        notify(ev)
        _wait_state(q, id, :done)
    end
end

@testset "cancel during setup with output_dir keeps the slot" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        ev = Base.Event()
        q = Queue(; runner = _ -> wait(ev))
        id = submit!(q, "a.jl", "parent:1"; output_dir = out)
        nxt = submit!(q, "b.jl", "parent:1")
        @test step!(q) == 1
        @test job(q, id).state === :running
        @test DistSSHQueue.kit_run_dir(job(q, id)) === nothing
        @test !DistSSHQueue.kit_child_alive(job(q, id))
        @test cancel!(q, id)
        @test job(q, id).state === :running
        @test job(q, id).kwargs["cancel"] === true
        @test step!(q) == 0
        @test job(q, nxt).state === :queued
        notify(ev)
        _wait_state(q, id, :done)
    end
end

@testset "cancel stops a live kit.pid under output_dir" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        child = Base.run(`sleep 60`; wait = false)
        write(joinpath(out, "kit.pid"), string(getpid(child)))
        ev = Base.Event()
        q = Queue(; runner = _ -> wait(ev))
        try
            id = submit!(q, "a.jl", "parent:1"; output_dir = out)
            @test step!(q) == 1
            @test DistSSHQueue.kit_run_dir(job(q, id)) === nothing
            @test DistSSHQueue.kit_child_alive(job(q, id))
            @test cancel!(q, id)
            @test job(q, id).state === :cancelled
            @test !process_running(child)
        finally
            process_running(child) && kill(child)
            wait(child)
            notify(ev)
        end
    end
end

@testset "cancel running overwrites a concurrent :failed finish" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        q = Queue(; runner = _ -> wait(Base.Event()))
        id = submit!(q, "a.jl", "parent:1"; output_dir = out)
        @test step!(q) == 1
        DistSSHQueue._finish!(q, id, :failed, "terminated"; result_path = out)
        DistSSHQueue._finish!(q, id, :cancelled, nothing; result_path = out)
        @test job(q, id).state === :cancelled
    end
end

@testset "cancel running overwrites a concurrent :done finish" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        q = Queue(; runner = _ -> wait(Base.Event()))
        id = submit!(q, "a.jl", "parent:1"; output_dir = out)
        @test step!(q) == 1
        DistSSHQueue._finish!(q, id, :done, nothing; result_path = out)
        DistSSHQueue._finish!(q, id, :cancelled, nothing; result_path = out)
        @test job(q, id).state === :cancelled
    end
end

@testset "reload keeps serve :running over a stale disk snapshot" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        out = joinpath(d, "kit-out")
        mkpath(out)
        q = Queue(; store, runner = _ -> wait(Base.Event()))
        id = submit!(q, "a.jl", "parent:1"; output_dir = out)
        @test step!(q) == 1
        DistSSHQueue._set_running_result_path!(q, id, out)
        stale = DistSSHQueue.read_jobs(store)
        stale[1].result_path = nothing
        DistSSHQueue.save_jobs(store, stale)
        DistSSHQueue.reload_keep_live!(q)
        @test job(q, id).state === :running
        @test job(q, id).result_path == out
        @test q.live_id == id
    end
end

@testset "client cancel on disk wins over serve :done" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        out = joinpath(d, "kit-out")
        mkpath(out)
        ev = Base.Event()
        q = Queue(; store, runner = _ -> wait(ev))
        id = submit!(q, "a.jl", "parent:1"; output_dir = out)
        @test step!(q) == 1
        @test q.live_id == id
        child = Base.run(`sleep 60`; wait = false)
        write(joinpath(out, "kit.pid"), string(getpid(child)))
        client = Queue(; store, runner = _ -> error("client must not run"))
        try
            @test cancel!(client, id)
        finally
            process_running(child) && kill(child)
            wait(child)
        end
        @test job(client, id).state === :cancelled
        DistSSHQueue._finish!(q, id, :done, nothing; result_path = out)
        @test job(q, id).state === :cancelled
        @test q.live_id === nothing
        @test DistSSHQueue.read_jobs(store)[1].state === :cancelled
        notify(ev)
        sleep(0.05)
        @test job(q, id).state === :cancelled
    end
end

@testset "setup failure after cancel is cancelled" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        gate = Base.Event()
        q = Queue(; store, runner = _ -> (wait(gate); error("rsync failed")))
        id = submit!(q, "a.jl", "parent:1")
        @test step!(q) == 1
        @test cancel!(q, id)
        @test DistSSHQueue._job_cancel_flag(job(q, id))
        notify(gate)
        _wait_state(q, id, :cancelled)
        @test job(q, id).error === nothing
    end
end

@testset "setup failure without cancel is failed" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        q = Queue(; store, runner = _ -> error("rsync failed"))
        id = submit!(q, "a.jl", "parent:1")
        @test step!(q) == 1
        _wait_state(q, id, :failed)
        @test occursin("rsync failed", something(job(q, id).error, ""))
    end
end

@testset "unreadable cancel flag finishes failed" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        started = Base.Event()
        gate = Base.Event()
        q = Queue(; store, runner = _ -> (notify(started); wait(gate); error("rsync failed")))
        id = submit!(q, "a.jl", "parent:1")
        @test step!(q) == 1
        wait(started)
        @test cancel!(q, id)
        write(store, "[\n")
        notify(gate)
        _wait_state(q, id, :failed)
        @test job(q, id).state === :failed
    end
end

@testset "kit throw does not stall" begin
    q = Queue(; runner = j -> basename(j.script) == "bad.jl" ? error("boom") : nothing)
    a = submit!(q, "bad.jl", "parent:1")
    b = submit!(q, "ok.jl", "parent:1")
    @test step!(q) == 1
    _wait_state(q, a, :failed)
    @test occursin("boom", something(job(q, a).error, ""))
    @test step!(q) == 1
    _wait_state(q, b, :done)
end

@testset "kind=:drive" begin
    q = Queue(; runner = _ -> nothing)
    id = submit!(q, "d.jl", "parent:1"; kind = :drive)
    j = job(q, id)
    @test j.kind === :drive
    @test haskey(j.kwargs, "project")
    @test !haskey(j.kwargs, "path_anchor")
    gid = submit!(q, "g.jl", "parent:1")
    g = job(q, gid)
    @test g.kind === :go
    @test !haskey(g.kwargs, "path_anchor")
    rid = submit!(q, "m.jl", "parent:1"; kind = :ride)
    @test job(q, rid).kind === :ride
end

@testset "kit setup session uses job remote" begin
    mktempdir() do d
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = script,
            hosts = ["parent:1"],
            kwargs = Dict{String, Any}("project" => String(d), "remote" => "/custom/root"),
        )
        s = DistSSHQueue._kit_setup_session(j, String(d))
        @test s.remote == "/custom/root"
        @test DistSSHQueue._kit_setup_child_tokens(["parent:1", "child:w1:2"]) ==
            ["child:w1:2"]
        @test isempty(DistSSHQueue._kit_setup_child_tokens(["parent:2"]))
        j2 = DistSSHQueue.Job(;
            kind = :go,
            script = script,
            hosts = ["parent:1"],
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        s2 = DistSSHQueue._kit_setup_session(j2, String(d))
        @test s2.remote === nothing
    end
end

@testset "kit setup instantiates the queue-host project without SSH" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = script,
            hosts = ["parent:1"],
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            DistSSHQueue._queue_kit_setup!(j, Returns(nothing))
        end
        @test isfile(joinpath(d, "Project.toml"))
        @test isfile(joinpath(d, "Manifest.toml"))
    end
    DistSSHQueue._require_kit_setup_ok!((; ok = true), "instantiate")
    @test_throws ErrorException DistSSHQueue._require_kit_setup_ok!((; ok = false), "check")
end

@testset "kit setup always runs :check after instantiate" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = script,
            hosts = ["child:w1:1"],
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        modes = Symbol[]
        phases = String[]
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            DistSSHQueue._queue_kit_setup!(
                j,
                ph -> ph isa AbstractString && push!(phases, String(ph));
                kit_setup! = _KitSetupOk(modes),
            )
        end
        @test modes == [:rsync, :instantiate, :check]
        @test phases == ["rsync", "instantiate", "check"]
    end
end

@testset "stage rsync skips gitignore and stays before instantiate" begin
    mktempdir() do d
        stage = joinpath(d, ".distsshqueue", "stage", "11111111-1111-4111-8111-111111111111")
        mkpath(stage)
        write(joinpath(stage, "Project.toml"), "[deps]\n")
        got = _stage_rsync_setup!(stage)
        @test got.gitignore === false
        @test got.modes == [:rsync, :instantiate, :check]
        @test got.phases == ["rsync", "instantiate", "check"]
        @test got.manifest_at[:rsync] === false
        @test got.manifest_at[:instantiate] === true
    end
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        got = _stage_rsync_setup!(d)
        @test got.gitignore === true
        @test got.modes == [:rsync, :instantiate, :check]
        @test got.phases == ["rsync", "instantiate", "check"]
    end
end

@testset "kit setup failure records setup log paths" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        logdir = joinpath(d, ".distsshkit", "setup")
        mkpath(logdir)
        write(joinpath(logdir, "setup_new.log"), "instantiate failed\n")
        j = DistSSHQueue.Job(;
            kind = :drive,
            script = script,
            hosts = ["child:w1:1"],
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        DistSSHQueue._allocate_queue_leaf!(j)
        leaf = DistSSHQueue.kit_output_dir(j)::String
        @test leaf isa String
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            @test_throws ErrorException DistSSHQueue._queue_kit_setup!(
                j, Returns(nothing); kit_setup! = _KitSetupFail(:instantiate, false),
            )
        end
        @test !isfile(joinpath(leaf, "setup_failure.log"))
        logs = j.kwargs["setup_logs"]
        @test logs isa AbstractVector
        @test any(p -> occursin("setup_new.log", String(p)), logs)
        mkpath(joinpath(logdir, "setup_dir.log"))
        DistSSHQueue._record_kit_setup_logs!(j, String(d))
        @test all(p -> isfile(String(p)), j.kwargs["setup_logs"])
    end
end

@testset "kit setup rsync failure records setup log paths" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        logdir = joinpath(d, ".distsshkit", "setup")
        mkpath(logdir)
        write(joinpath(logdir, "setup_rsync.log"), "rsync failed\n")
        j = DistSSHQueue.Job(;
            kind = :drive,
            script = script,
            hosts = ["child:w1:1"],
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        DistSSHQueue._allocate_queue_leaf!(j)
        leaf = DistSSHQueue.kit_output_dir(j)::String
        @test leaf isa String
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            @test_throws ErrorException DistSSHQueue._queue_kit_setup!(
                j, Returns(nothing); kit_setup! = _KitSetupFail(:rsync, true),
            )
        end
        @test !isfile(joinpath(leaf, "setup_failure.log"))
        @test any(p -> occursin("setup_rsync.log", String(p)), j.kwargs["setup_logs"])
    end
end

function _running_setup_job(dir::AbstractString)
    proj = joinpath(dir, "proj")
    mkpath(proj)
    store = joinpath(dir, "jobs.toml")
    script = joinpath(dir, "s.jl")
    write(script, "1\n")
    q = Queue(; store = store, runner = _ -> nothing)
    id = submit!(q, script, "child:box:1"; project = String(proj))
    lock(q.lock) do
        i = DistSSHQueue._index_id(q.jobs, id)
        row = q.jobs[i]
        row.state = :running
        row.kwargs["warnings"] = Any[
            Dict{String, Any}(
                "kind" => "manifest_absent",
                "message" => "no Manifest.toml",
            ),
        ]
        return nothing
    end
    DistSSHQueue._persist!(q)
    return q, id, job(q, id), store
end

@testset "setup warnings are stored before the job finishes" begin
    mktempdir() do d
        q, id, snap, store = _running_setup_job(d)
        note = (host = "box", kind = :julia_patch, message = "Julia patch version differs")
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            DistSSHQueue._queue_kit_setup!(
                snap, Returns(nothing);
                kit_setup! = _KitSetupWarn(true, [note]),
                on_warnings = entries -> DistSSHQueue._persist_job_warnings!(q, id, entries),
            )
        end
        row = only(DistSSHQueue.read_jobs(store))
        @test row.state === :running
        kinds = [w["kind"] for w in row.kwargs["warnings"]]
        @test kinds == ["manifest_absent", "julia_patch"]
        @test row.kwargs["warnings"][2]["host"] == "box"
        listed = sprint(io -> DistSSHQueue.print_jobs_table([row]; io = io))
        @test occursin(" !", listed)
        @test occursin("setup warnings", listed)
        quiet = sprint(io -> DistSSHQueue.print_jobs_table([row]; io = io, quiet = true))
        @test occursin(" !", quiet)
        @test !occursin("setup warnings", quiet)
    end
    mktempdir() do d
        q, id, snap, store = _running_setup_job(d)
        note = (host = "box", kind = :git_dirty, message = "Git has uncommitted changes")
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            @test_throws ErrorException DistSSHQueue._queue_kit_setup!(
                snap, Returns(nothing);
                kit_setup! = _KitSetupWarn(false, [note]),
                on_warnings = entries -> DistSSHQueue._persist_job_warnings!(q, id, entries),
            )
        end
        row = only(DistSSHQueue.read_jobs(store))
        @test row.state === :running
        @test row.kwargs["warnings"][2]["kind"] == "git_dirty"
    end
    mktempdir() do d
        _, _, snap, _ = _running_setup_job(d)
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            DistSSHQueue._queue_kit_setup!(
                snap, Returns(nothing); kit_setup! = _KitSetupOk(Symbol[]),
            )
        end
        @test length(snap.kwargs["warnings"]) == 1
        @test snap.kwargs["warnings"][1]["kind"] == "manifest_absent"
    end
end

@testset "kit setup failure is kept if log record throws" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        logdir = joinpath(d, ".distsshkit", "setup")
        mkpath(logdir)
        write(joinpath(logdir, "setup_new.log"), "instantiate failed\n")
        j = DistSSHQueue.Job(;
            kind = :drive,
            script = script,
            hosts = ["child:w1:1"],
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        DistSSHQueue._allocate_queue_leaf!(j)
        leaf = DistSSHQueue.kit_output_dir(j)
        @test leaf !== nothing
        chmod(logdir, 0o000)
        thrown = try
            withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
                @test_throws ErrorException DistSSHQueue._queue_kit_setup!(
                    j, Returns(nothing); kit_setup! = _KitSetupFail(:instantiate, false),
                )
            end
        finally
            chmod(logdir, 0o755)
        end
        @test occursin("setup! instantiate failed", thrown.value.msg)
        @test !haskey(j.kwargs, "setup_logs")
    end
end

@testset "setup logs recorded when leaf allocation throws" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        logdir = joinpath(d, ".distsshkit", "setup")
        mkpath(logdir)
        write(joinpath(logdir, "setup_new.log"), "instantiate failed\n")
        write(joinpath(d, ".distsshqueue"), "not a directory\n")
        j = DistSSHQueue.Job(;
            kind = :drive,
            script = script,
            hosts = ["child:w1:1"],
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        thrown = withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            @test_throws ErrorException DistSSHQueue._queue_kit_setup!(
                j, Returns(nothing); kit_setup! = _KitSetupFail(:instantiate, false),
            )
        end
        @test occursin("setup! instantiate failed", thrown.value.msg)
        @test DistSSHQueue.kit_output_dir(j) === nothing
        @test any(p -> occursin("setup_new.log", String(p)), j.kwargs["setup_logs"])
    end
end

@testset "setup failure with explicit output_dir is fetchable" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        id = "aaaaaaaa-1111-4000-8000-000000000001"
        leaf = joinpath(d, ".distsshqueue", "drive", "s_aaaaaaaa")
        mkpath(leaf)
        q = Queue(; store = store, runner = _ -> error("DistSSHKit setup! instantiate failed"))
        submit!(
            q,
            script,
            "parent:1";
            id = id,
            kind = :drive,
            project = d,
            output_dir = leaf,
        )
        @test step!(q) == 1
        _wait_state(q, id, :failed)
        @test job(q, id).result_path == leaf
        src = DistSSHQueue.fetch_source(id; store = store)
        @test startswith(src, "failed\t")
        @test occursin(leaf, src)
    end
end

@testset "setup failure persists setup_logs from runner snapshot" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        logp = joinpath(d, ".distsshkit", "setup", "setup_new.log")
        mkpath(dirname(logp))
        write(logp, "instantiate failed\n")
        id = "aaaaaaaa-2222-4000-8000-000000000002"
        q = Queue(;
            store = store, runner = function (j)
                j.kwargs["setup_logs"] = [logp]
                error("DistSSHKit setup! instantiate failed")
            end
        )
        submit!(q, script, "parent:1"; id = id, kind = :drive, project = d)
        @test step!(q) == 1
        _wait_state(q, id, :failed)
        logs = job(q, id).kwargs["setup_logs"]
        @test logs isa AbstractVector
        @test any(p -> occursin("setup_new.log", String(p)), logs)
        saved = DistSSHQueue.load_jobs(store)
        @test any(p -> occursin("setup_new.log", String(p)), saved[1].kwargs["setup_logs"])
    end
end

@testset "instantiate skips queue-env and empty JULIA_DEPOT_PATH" begin
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
        @test DistSSHQueue.pkg_depots_for_instantiate() isa Vector{String}
        old = copy(DEPOT_PATH)
        try
            empty!(DEPOT_PATH)
            push!(DEPOT_PATH, qenv)
            @test DistSSHQueue.pkg_depots_for_instantiate() ==
                [joinpath(homedir(), ".julia")]
            real = joinpath(d, "depot")
            mkpath(real)
            empty!(DEPOT_PATH)
            push!(DEPOT_PATH, qenv)
            push!(DEPOT_PATH, real)
            @test DistSSHQueue.pkg_depots_for_instantiate() == [real]
            seen = String[]
            DistSSHQueue._with_pkg_depots() do
                append!(seen, DEPOT_PATH)
                return nothing
            end
            @test seen == [real]
            empty!(DEPOT_PATH)
            DistSSHQueue._queue_local_instantiate!(job)
            @test isfile(joinpath(job, "Manifest.toml"))
            @test read(env_manifest, String) == env_before
            @test !isdir(joinpath(qenv, "packages"))
            @test !isdir(joinpath(qenv, "compiled"))
        finally
            empty!(DEPOT_PATH)
            append!(DEPOT_PATH, old)
        end
    end
end

@testset "run_kit skips execute when no longer running" begin
    mktempdir() do d
        script = joinpath(d, "nope.jl")
        write(script, "error(\"must not execute\")\n")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = script,
            hosts = ["parent:1"],
            state = :running,
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => "1") do
            out = DistSSHQueue.run_kit(j, Returns(nothing); still_running = Returns(false))
            @test out == ""
        end
    end
end

@testset "drive without Queue output_dir leaves init_output_dir! to the script" begin
    mktempdir() do d
        sdir = joinpath(d, "with_kit")
        mkpath(sdir)
        script = joinpath(sdir, "square_file.jl")
        write(
            script, """
            using DistSSHRun
            function init_output_dir!(_)
                DistSSHRun.resolve_distributed_output_dir!(ARGS, joinpath(@__DIR__, "output"))
            end
            """
        )
        q = Queue(; runner = _ -> nothing, store = joinpath(d, "jobs.toml"))
        id = submit!(q, script, "parent:1"; kind = :drive, project = d)
        @test step!(q) == 1
        _wait_state(q, id, :done)
        j = job(q, id)
        @test j.result_path === nothing
        @test get(j.kwargs, "output_dir", nothing) === nothing
        mod = Module()
        Base.include(mod, script)
        got = withenv("DISTRIBUTED_OUTPUT_DIR" => nothing) do
            @eval mod init_output_dir!(String[])
        end
        @test DistSSHQueue.canonical_local_path(got) ==
            DistSSHQueue.canonical_local_path(joinpath(sdir, "output"))
    end
end

@testset "kit.pid keeps a live detached child across load" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        write(joinpath(out, "kit.pid"), string(getpid()))
        p = joinpath(d, "jobs.toml")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = "/tmp/job.jl",
            hosts = ["parent:1"],
            state = :running,
            result_path = out,
        )
        DistSSHQueue.save_jobs(p, [j])
        q = Queue(; store = p, runner = _ -> error("must not re-run"))
        load!(q)
        loaded = job(q, j.id)
        @test loaded.state === :running
        @test DistSSHQueue.kit_child_alive(loaded)
        DistSSHQueue.adopt_running!(q)
        @test q.live_id == j.id
        sleep(0.05)
        @test job(q, j.id).state === :running
    end
end

@testset "two-line kit.pid is live" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        st = DistSSHRun.kit_process_start_key(getpid())
        body = st === nothing ? string(getpid(), '\n') : string(getpid(), '\n', st, '\n')
        write(joinpath(out, "kit.pid"), body)
        j = DistSSHQueue.Job(;
            kind = :go,
            script = "/tmp/job.jl",
            hosts = ["parent:1"],
            state = :running,
            result_path = out,
        )
        @test DistSSHQueue.kit_child_alive(j)
        @test DistSSHRun.kit_pid_file_running(out)
    end
end

@testset "kit.result settles a finished running row on load" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        DistSSHRun._write_kit_result_file(
            DistSSHRun.KitRunResult(
                true, :go, out, nothing, nothing, 0,
            )
        )
        p = joinpath(d, "jobs.toml")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = "/tmp/job.jl",
            hosts = ["parent:1"],
            state = :running,
            result_path = out,
        )
        DistSSHQueue.save_jobs(p, [j])
        q = Queue(; store = p, runner = _ -> error("must not re-run"))
        load!(q)
        loaded = job(q, j.id)
        @test loaded.state === :done
        @test loaded.error === nothing
    end
end

@testset "kit.result drive ok=true is done" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        DistSSHRun._write_kit_result_file(
            DistSSHRun.KitRunResult(
                true, :drive, out, nothing, nothing, 0,
            )
        )
        p = joinpath(d, "jobs.toml")
        j = DistSSHQueue.Job(;
            kind = :drive,
            script = "/tmp/job.jl",
            hosts = ["parent:2", "child:mini-alpha:2"],
            state = :running,
            result_path = out,
        )
        DistSSHQueue.save_jobs(p, [j])
        q = Queue(; store = p, runner = _ -> error("must not re-run"))
        load!(q)
        loaded = job(q, j.id)
        @test loaded.state === :done
        @test loaded.error === nothing
        @test loaded.result_path == out
    end
end

@testset "TOML store restart" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        ev = Base.Event()
        q = Queue(; store = p, runner = _ -> wait(ev))
        id = submit!(q, "a.jl", "parent:1")
        @test step!(q) == 1
        @test job(q, id).state === :running
        q2 = Queue(; store = p, runner = _ -> nothing)
        load!(q2)
        notify(ev)
        _wait_state(q, id, :done)
        @test job(q2, id).state === :failed
        @test occursin("serve restarted", something(job(q2, id).error, ""))
    end
end

@testset "kit ok=false is failed" begin
    @test_throws ErrorException DistSSHQueue.require_kit_ok((ok = false, kind = :go))
    detailed = try
        DistSSHQueue.require_kit_ok((ok = false, kind = :drive, failed_step = "drive", exit_code = 42))
    catch e
        e
    end
    @test detailed isa ErrorException
    @test occursin("drive", detailed.msg)
    @test occursin("exit 42", detailed.msg)
    @test DistSSHQueue.require_kit_ok((ok = true, kind = :go, output_dir = "/tmp/out")) === nothing
    @test DistSSHQueue.kit_result_path((ok = true, output_dir = "/tmp/out")) == "/tmp/out"
    q = Queue(; runner = _ -> error("DistSSHKit go failed (ok=false)"))
    id = submit!(q, "a.jl", "parent:1")
    @test step!(q) == 1
    _wait_state(q, id, :failed)
end

@testset "execute_kwargs drops names execute! detached rejects" begin
    q = Queue(; runner = _ -> nothing)
    gid = submit!(q, "g.jl", "parent:1"; path_anchor = "/x", yes = false, log_dir = "/logs", quiet = true)
    gkw = DistSSHQueue.execute_kwargs(job(q, gid))
    @test gkw.yes === true
    @test gkw.quiet === true
    @test !haskey(gkw, :path_anchor)
    @test !haskey(gkw, :job_id)
    @test !haskey(gkw, :log_dir)
    did = submit!(q, "d.jl", "parent:1"; kind = :drive, log_dir = "/logs", skip_hash_check = false)
    dkw = DistSSHQueue.execute_kwargs(job(q, did))
    @test dkw.log_dir == "/logs"
    @test dkw.skip_hash_check === false
    @test dkw.yes === true
    wid = submit!(q, "w.jl", "child:h1:1"; kind = :drive, workers = 4, mem_headroom = 0.5)
    wkw = DistSSHQueue.execute_kwargs(job(q, wid))
    @test wkw.workers == 4
    @test wkw.mem_headroom == 0.5
    @test !haskey(DistSSHQueue.execute_kwargs(job(q, gid)), :workers)
    rid = submit!(q, "r.jl", "parent:1"; kind = :go, repeat = 8)
    @test DistSSHQueue.execute_kwargs(job(q, rid)).repeat == 8
    didr = submit!(q, "rd.jl", "parent:1"; kind = :drive, repeat = 8)
    @test !haskey(DistSSHQueue.execute_kwargs(job(q, didr)), :repeat)
    ride = submit!(q, "m.jl", "parent:2"; kind = :ride, spi_check = false, repeat = 8)
    rkw = DistSSHQueue.execute_kwargs(job(q, ride))
    @test rkw.spi_check === false
    @test !haskey(rkw, :repeat)
    @test_throws ArgumentError submit!(q, "x.jl", "parent:1"; kind = :pipeline)
end

@testset "result_path from runner and kwargs" begin
    q = Queue(; runner = _ -> "/tmp/kit-out")
    id = submit!(q, "a.jl", "parent:1"; output_dir = "/tmp/unused")
    @test step!(q) == 1
    _wait_state(q, id, :done)
    @test job(q, id).result_path == "/tmp/kit-out"

    q2 = Queue(; runner = _ -> nothing)
    id2 = submit!(q2, "b.jl", "parent:1"; output_dir = "/tmp/bag")
    @test step!(q2) == 1
    _wait_state(q2, id2, :done)
    @test job(q2, id2).result_path == "/tmp/bag"
end

@testset "client cancel reloads store" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        q = Queue(; store = p, runner = _ -> sleep(0.05))
        a = submit!(q, "a.jl", "parent:1")
        b = submit!(q, "b.jl", "parent:1")
        @test step!(q) == 1
        other = Queue(; store = p)
        @test cancel!(other, b)
        @test cancel!(other, a)
        @test job(other, a).state === :running
        @test DistSSHQueue._job_cancel_flag(job(other, a))
        @test job(other, b).state === :cancelled
        _wait_state(q, a, :done)
        @test step!(q) == 0
    end
end

@testset "client enqueue keeps running row" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        ev = Base.Event()
        q = Queue(; store = p, runner = _ -> wait(ev))
        a = submit!(q, "a.jl", "parent:1")
        @test step!(q) == 1
        q2 = Queue(; store = p, runner = _ -> nothing)
        b = submit!(q2, "b.jl", "child:host1:2")
        rows = DistSSHQueue.read_jobs(p)
        @test job(q, a).state === :running
        @test any(j -> j.id == b && j.state === :queued, rows)
        @test any(j -> j.id == a && j.state === :running, rows)
        notify(ev)
        _wait_state(q, a, :done)
    end
end

@testset "CLI help and Kit go enqueue" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        jobdir = mktempdir()
        write(joinpath(jobdir, "Project.toml"), "[deps]\n")
        write(joinpath(jobdir, "job.jl"), "1\n")
        write(joinpath(jobdir, "alias.jl"), "1\n")
        write(joinpath(jobdir, "drv.jl"), "1\n")
        write(joinpath(jobdir, "map.jl"), "1\n")
        withenv(
            "DISTSSHQUEUE_STORE" => p,
            "DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml"),
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
            "DISTRIBUTED_PROJECT_ROOT" => nothing,
        ) do
            cd(jobdir) do
                proj = DistSSHQueue.canonical_local_path(pwd())
                help = sprint(DistSSHQueue.print_queue_usage)
                client_h = sprint(io -> DistSSHQueue.print_queue_usage(io; topic = "client"))
                queue_h = sprint(io -> DistSSHQueue.print_queue_usage(io; topic = "qhost"))
                qv = string(pkgversion(DistSSHQueue))
                kv = string(DistSSHRun.dist_ssh_kit_version())
                @test occursin("DistSSHQueue $(qv)\nDistSSHRun $(kv)", help)
                @test !occursin("DistSSHQueue $(qv)", client_h)
                @test occursin("Usage", help)
                @test occursin("  help client", help)
                @test occursin("  help qhost", help)
                @test !occursin("--help client", help)
                @test !occursin("--help qhost", help)
                @test length(DistSSHQueue.CLIENT_COMMAND_LINES) == 9
                @test length(DistSSHQueue.QUEUE_HOST_COMMAND_LINES) == 12
                @test Base.ispublic(DistSSHQueue, :CLIENT_COMMAND_LINES)
                @test Base.ispublic(DistSSHQueue, :QUEUE_HOST_COMMAND_LINES)
                @test Base.ispublic(DistSSHQueue, :KIT_EXECUTE_KINDS)
                @test !Base.isexported(DistSSHQueue, :CLIENT_COMMAND_LINES)
                @test !Base.isexported(DistSSHQueue, :QUEUE_HOST_COMMAND_LINES)
                @test !Base.isexported(DistSSHQueue, :KIT_EXECUTE_KINDS)
                for line in DistSSHQueue.CLIENT_COMMAND_LINES
                    @test occursin(line, help)
                end
                for line in DistSSHQueue.QUEUE_HOST_COMMAND_LINES
                    @test occursin(line, help)
                end
                @test occursin("Client / qhost", help)
                @test occursin("job --project=.", help)
                @test occursin("qhost:HOST is SSH to the queue", help)
                @test !occursin("Examples", help)
                @test occursin("qhost:HOST", help)
                @test !occursin("Danger", help)
                @test !occursin("teardown -y", help)
                @test !occursin("status [-q]", help)
                @test !occursin("setup [--force]", help)
                @test occursin("--queue-env", help)
                @test occursin("~/.distsshqueue/env", help)
                @test occursin("julia --project=. -m DistSSHKit [qhost:HOST]", help)
                @test occursin(DistSSHQueue.help_verb_line("Queue host", "julia -m DistSSHKit qhost …"), help)
                @test occursin("help <command> for flags.", help)
                @test !occursin("Run <command> --help", help)
                @test !occursin("the hop", help)
                @test !occursin("laptop", help)
                @test occursin("DistSSHKit help client", client_h)
                @test occursin("help <command> for flags.", client_h)
                @test !occursin("--help client", client_h)
                @test occursin("Jobs", client_h)
                @test occursin("Hosts", client_h)
                @test occursin("list-host", client_h)
                @test occursin("juliaup default", client_h)
                @test occursin("  size ", client_h)
                @test occursin("watch", client_h)
                @test occursin(DistSSHQueue.help_verb_line("status", "Snapshot of the store"), client_h)
                @test occursin(DistSSHQueue.help_verb_line("watch", "Live status"), client_h)
                @test occursin("fetch", client_h)
                @test occursin("Copy a finished Kit leaf", client_h)
                @test occursin("size", client_h)
                @test occursin("plan", client_h)
                @test occursin("pool", client_h)
                @test occursin("ride", client_h)
                @test occursin("See DistSSHKit", client_h)
                @test occursin("-m DistSSHKit --help", client_h)
                @test occursin("parent:4", client_h)
                @test occursin("submit drive parent:4", client_h)
                @test occursin("child:NAME:N", client_h)
                @test !occursin("submit \\", client_h)
                @test !occursin("Replay:", client_h)
                @test !occursin("qhost:HOST go parent SCRIPT", client_h)
                @test !occursin("qhost:HOST drive parent", client_h)
                @test occursin("DistSSHKit help qhost", queue_h)
                @test occursin("help <command> for flags.", queue_h)
                @test !occursin("--help qhost", queue_h)
                @test occursin("Setup", queue_h)
                @test occursin("Serve", queue_h)
                @test occursin("add-host", queue_h)
                @test occursin("remove-host", queue_h)
                @test occursin("enable", queue_h)
                @test occursin("disable", queue_h)
                @test occursin("julia -m DistSSHKit qhost setup", queue_h)
                @test occursin("julia -m DistSSHKit qhost up", queue_h)
                @test !occursin("julia --project=. -m DistSSHKit qhost setup", queue_h)
                @test occursin("Danger", queue_h)
                @test occursin(DistSSHQueue.help_verb_line("teardown", "Stop serve and remove ~/.distsshqueue"), queue_h)
                @test occursin(DistSSHQueue.help_verb_line("", "Would remove, then --confirm-path. ~/.distsshqueue goes, including stage."), queue_h)
                @test occursin("size", queue_h)
                @test occursin("plan", queue_h)
                @test occursin("pool", queue_h)
                @test !occursin("teardown -y", queue_h)
                @test_throws ArgumentError DistSSHQueue.print_queue_usage(IOBuffer(); topic = "nope")
                topic_err = try
                    DistSSHQueue.print_queue_usage(IOBuffer(); topic = "nope")
                    nothing
                catch e
                    e
                end
                @test topic_err isa ArgumentError
                @test occursin("client / qhost / queue / queue-host", topic_err.msg)
                code_topic, out_topic, _ = capture_stdio() do
                    DistSSHQueue.main(["-h", "client"])
                end
                @test code_topic == 0
                @test occursin("submit drive parent:4", out_topic)
                @test occursin("DistSSHQueue help client", out_topic)
                code_help_client, out_help_client, _ = capture_stdio() do
                    DistSSHQueue.main(["help", "client"])
                end
                @test code_help_client == 0
                @test out_help_client == out_topic
                code_topic2, out_topic2, _ = capture_stdio() do
                    DistSSHQueue.main(["--help", "qhost"])
                end
                @test code_topic2 == 0
                @test occursin("add-host", out_topic2)
                @test occursin("DistSSHQueue help qhost", out_topic2)
                @test occursin("julia -m DistSSHQueue up", out_topic2)
                @test !occursin("qhost up", out_topic2)
                code_help_qhost, out_help_qhost, _ = capture_stdio() do
                    DistSSHQueue.main(["help", "qhost"])
                end
                @test code_help_qhost == 0
                @test out_help_qhost == out_topic2
                for topic in ("queue", "queue-host")
                    code_alias_topic, out_alias_topic, _ = capture_stdio() do
                        DistSSHQueue.main(["help", topic])
                    end
                    @test code_alias_topic == 0
                    @test out_alias_topic == out_topic2
                end
                code_bad_topic, _, err_bad_topic = capture_stdio() do
                    DistSSHQueue.main(["help", "nope"])
                end
                @test code_bad_topic == 1
                @test occursin(
                    "unknown help topic: nope (client / qhost / queue / queue-host)",
                    err_bad_topic,
                )
                setup_h = sprint(DistSSHQueue.print_setup_usage)
                @test occursin("--force", setup_h)
                @test !occursin("--juliaup", setup_h)
                up_h = sprint(DistSSHQueue.print_up_usage)
                @test occursin("qhost up update", up_h)
                @test occursin("qhost up", up_h)
                @test !occursin("[child:NAME", setup_h)
                @test occursin("--help / -h", setup_h)
                @test !occursin("Enqueue DistSSHKit", setup_h)
                code_st_h, out_st_h, _ = capture_stdio() do
                    DistSSHQueue.main(["status", "-h"])
                end
                @test code_st_h == 0
                @test occursin("DistSSHQueue status", out_st_h)
                @test occursin("--tail N|full", out_st_h)
                @test occursin("  status", out_st_h)
                @test !occursin("--project=.", out_st_h)
                @test !occursin("qhost:HOST", out_st_h)
                @test !occursin("add-host", out_st_h)
                @test !occursin("teardown -y", out_st_h)
                code_sv_h, out_sv_h, _ = capture_stdio() do
                    DistSSHQueue.main(["serve", "--help"])
                end
                @test code_sv_h == 0
                @test occursin("DistSSHQueue serve", out_sv_h)
                @test occursin("--interval SEC", out_sv_h)
                @test !occursin("julia -m DistSSHKit qhost serve", out_sv_h)
                @test !occursin("submit drive", out_sv_h)
                code_svc, out_svc, err_svc = capture_stdio() do
                    DistSSHQueue.main(["service", "-h"])
                end
                @test code_svc == 0
                @test occursin("service is gone", out_svc * err_svc)
                code_svc_bad, _, err_svc_bad = capture_stdio() do
                    DistSSHQueue.main(["service"])
                end
                @test code_svc_bad == 1
                @test occursin("service is gone", err_svc_bad)
                code_sub_h, out_sub_h, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "-h"])
                end
                @test code_sub_h == 0
                @test occursin("submit go|ride|drive", out_sub_h)
                @test occursin("help submit go", out_sub_h)
                @test !occursin("submit go --help", out_sub_h)
                @test occursin(DistSSHQueue.help_verb_line("go", "Run an as-is complete job"), out_sub_h)
                @test occursin(DistSSHQueue.help_verb_line("ride", "Experimental auto-split of map / filter"), out_sub_h)
                @test occursin(DistSSHQueue.help_verb_line("drive", "Distributed workers + collect"), out_sub_h)
                @test occursin("--help / -h", out_sub_h)
                @test !occursin("add-host", out_sub_h)
                code_help_sub, out_help_sub, err_help_sub = capture_stdio() do
                    DistSSHQueue.main(["help", "submit"])
                end
                @test code_help_sub == 0
                @test out_help_sub == out_sub_h
                @test isempty(err_help_sub)
                code_flag_sub, out_flag_sub, _ = capture_stdio() do
                    DistSSHQueue.main(["--help", "submit"])
                end
                @test code_flag_sub == 0
                @test out_flag_sub == out_sub_h
                code_need, _, err_need = capture_stdio() do
                    DistSSHQueue.main(["submit"])
                end
                @test code_need == 1
                @test occursin("need `go`, `ride`, or `drive`", err_need)
                code_word_help, _, err_word_help = capture_stdio() do
                    DistSSHQueue.main(["status", "help"])
                end
                @test code_word_help == 1
                @test occursin("unknown status option: help", err_word_help)
                td_h = sprint(DistSSHQueue.print_teardown_usage)
                @test occursin("--confirm-path PATH", td_h)
                @test occursin("Still deletes. Removed in 0.10", td_h)
                @test occursin("$(DistSSHQueue.cli_m()) $(DistSSHQueue.cli_qhost())teardown", td_h)
                @test !occursin("teardown -y", td_h)
                code_sh, out_sh, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "-h"])
                end
                @test code_sh == 0
                @test occursin("parent:N", out_sh)
                @test occursin("DistSSHKit", out_sh)
                @test occursin("not a Kit slot", out_sh)
                code_help_go, out_help_go, err_help_go = capture_stdio() do
                    DistSSHQueue.main(["help", "submit", "go"])
                end
                @test code_help_go == 0
                @test out_help_go == out_sh
                @test isempty(err_help_go)
                code_ride_h, out_ride_h, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "ride", "--help"])
                end
                code_help_ride, out_help_ride, _ = capture_stdio() do
                    DistSSHQueue.main(["help", "submit", "ride"])
                end
                @test code_ride_h == 0
                @test code_help_ride == 0
                @test out_help_ride == out_ride_h
                code_hop_help, out_hop_help, err_hop_help = capture_stdio() do
                    DistSSHQueue.main(["qhost:no-such-host", "help", "submit"])
                end
                @test code_hop_help == 0
                @test out_hop_help == out_sub_h
                @test isempty(err_hop_help)
                @test !occursin("Notes", help)
                @test !occursin("[--size]", help)
                @test !occursin("qhost:HOST add-host", help)
                @test !occursin("IdentityFile", help)
                @test !occursin("laptop", help)
                @test !occursin("service install", help)
                code_h, out_h, _ = capture_stdio() do
                    DistSSHQueue.main(["-h"])
                end
                @test code_h == 0
                @test occursin("Usage", out_h)
                qv = string(pkgversion(DistSSHQueue))
                kv = string(DistSSHRun.dist_ssh_kit_version())
                for flag in ("--version", "-v", "-V")
                    code_v, out_v, _ = capture_stdio() do
                        DistSSHQueue.main([flag])
                    end
                    @test code_v == 0
                    lines = split(strip(out_v), '\n')
                    @test length(lines) == 2
                    @test lines[1] == "DistSSHQueue $(qv)"
                    @test lines[2] == "DistSSHRun $(kv)"
                end
                code_qv, out_qv, _ = capture_stdio() do
                    DistSSHQueue.main(["qhost:no-such-host", "--version"])
                end
                @test code_qv == 0
                @test startswith(strip(out_qv), "DistSSHQueue $(qv)")
                code_st, out_st, _ = capture_stdio() do
                    DistSSHQueue.main(["status"])
                end
                @test code_st == 0
                @test occursin("Store", out_st)
                @test occursin("serve", out_st)
                @test occursin("  enable ", out_st)
                @test occursin("qhost", out_st)
                @test shows_flat(out_st, "local ($(gethostname()))")
                @test occursin("  path   none", out_st)
                @test occursin("(none)", out_st)
                @test !occursin("(empty)", out_st)
                empty = sprint(io -> DistSSHQueue.show_status(p; io = io))
                @test occursin("Store", empty)
                @test occursin("(none)", empty)
                @test !occursin("(empty)", empty)
                via_out = sprint(io -> DistSSHQueue.show_status(p; io = io, qhost = "qbox"))
                @test shows_flat(via_out, "qbox ($(gethostname()))")
                @test DistSSHQueue._qhost_disp(gethostname()) == gethostname()
                env_out = withenv(DistSSHQueue.QHOST_DISPLAY_ENV => "from-env") do
                    sprint(io -> DistSSHQueue.show_status(p; io = io))
                end
                @test shows_flat(env_out, "from-env ($(gethostname()))")
                code_via, _, err_via = capture_stdio() do
                    DistSSHQueue.main(["status", "--via", "qbox"])
                end
                @test code_via == 1
                @test occursin("unknown status option", err_via)
                code_q, out_q, _ = capture_stdio() do
                    DistSSHQueue.main(["status", "-q"])
                end
                @test code_q == 0
                @test occursin("(none)", out_q)
                @test !occursin("(empty)", out_q)
                @test !occursin("Store", out_q)
                @test !occursin("qhost", out_q)
                withenv("DISTSSHKIT_QUIET" => "1") do
                    code_qe, out_qe, _ = capture_stdio() do
                        DistSSHQueue.main(["status"])
                    end
                    @test code_qe == 0
                    @test !occursin("Store", out_qe)
                end
                code_qv, _, err_qv = capture_stdio() do
                    DistSSHQueue.main(["status", "-q", "--verbose"])
                end
                @test code_qv == 1
                @test occursin("cannot combine", err_qv)
                code_go, _, err_go = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "child:host1:4", "job.jl"])
                end
                @test code_go == 1
                @test occursin("no add-host list", err_go)
                @test occursin("add-host first", err_go)
                @test isempty(DistSSHQueue.read_jobs(p))
                code_add, _, _ = capture_stdio() do
                    DistSSHQueue.main(["add-host", "parent", "child:host1", "child:w"])
                end
                @test code_add == 0
                code_go, out_go, err_go = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "child:host1:4", "job.jl"])
                end
                @test code_go == 0
                @test !occursin("no add-host list", err_go)
                rows = DistSSHQueue.read_jobs(p)
                @test length(rows) == 1
                @test strip(out_go) == rows[1].id
                @test rows[1].kind === :go
                @test rows[1].script == DistSSHQueue.canonical_local_path(joinpath(pwd(), "job.jl"))
                @test rows[1].hosts == ["child:host1:4"]
                @test rows[1].state === :queued
                @test rows[1].kwargs["project"] == proj
                listed = sprint(io -> DistSSHQueue.show_status(p; io = io))
                @test occursin(first(rows[1].id, 8), listed)
                @test !occursin(rows[1].id, listed)
                @test occursin("queued", listed)
                @test occursin("STATE", listed)
                code_alias, _, err_alias = capture_stdio() do
                    DistSSHQueue.main(["go", "parent:1", "alias.jl"])
                end
                @test code_alias == 1
                @test occursin("Enqueue with submit", err_alias)
                @test occursin("submit go", err_alias)
                @test length(DistSSHQueue.read_jobs(p)) == 1
                code_drv, _, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "drive", "parent:2", "drv.jl"])
                end
                @test code_drv == 0
                rows = DistSSHQueue.read_jobs(p)
                @test length(rows) == 2
                @test rows[2].kind === :drive
                @test rows[2].script == DistSSHQueue.canonical_local_path(joinpath(pwd(), "drv.jl"))
                @test rows[2].hosts == ["parent:2"]
                @test rows[2].kwargs["project"] == proj
                code_ride, _, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "ride", "--no-spi-check", "parent:1", "map.jl"])
                end
                @test code_ride == 0
                rows = DistSSHQueue.read_jobs(p)
                @test rows[end].kind === :ride
                @test DistSSHQueue.execute_kwargs(rows[end]).spi_check === false
                code_w, _, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "drive", "--workers", "4", "child:host1:1", "drv.jl"])
                end
                @test code_w == 0
                rows = DistSSHQueue.read_jobs(p)
                want = DistSSHQueue.host_tokens(
                    DistSSHRun.parse_drive_args(["--workers", "4", "child:host1:1", "drv.jl"]);
                    kind = :drive,
                )
                @test rows[end].hosts == want
                @test rows[end].kwargs["workers"] == 4
                n_hosts = length(rows)
                code_bare, _, err_bare = capture_stdio() do
                    DistSSHQueue.main(["submit", "drive", "--workers", "4", "child:host1", "drv.jl"])
                end
                @test code_bare == 1
                @test occursin("needs :N", err_bare)
                @test length(DistSSHQueue.read_jobs(p)) == n_hosts
                code_kitgo, _, err_kitgo = capture_stdio() do
                    DistSSHQueue.main(["go", "--hosts", "child:w:2", "job.jl"])
                end
                @test code_kitgo == 1
                @test occursin("Enqueue with submit", err_kitgo)
                n_before_hf = length(DistSSHQueue.read_jobs(p))
                code_hf, _, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "--hosts", "child:w:2", "job.jl"])
                end
                @test code_hf == 0
                rows = DistSSHQueue.read_jobs(p)
                @test length(rows) == n_before_hf + 1
                @test rows[end].hosts == ["child:w:2"]
                code_sh, _, err_sh = capture_stdio() do
                    DistSSHQueue.main(["--hosts", "child:w:2", "job.jl"])
                end
                @test code_sh == 1
                @test occursin("unknown subcommand", err_sh)
                @test length(DistSSHQueue.read_jobs(p)) == length(rows)
                code_jl, _, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "--julia", "/opt/queue-kit-julia", "parent:1", "job.jl"])
                end
                @test code_jl == 0
                rows = DistSSHQueue.read_jobs(p)
                @test rows[end].kwargs["julia"] == "/opt/queue-kit-julia"
                n_jl = length(rows)
                code_parent, _, err_parent = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "parent", "job.jl"])
                end
                @test code_parent == 1
                @test occursin("needs :N", err_parent)
                @test length(DistSSHQueue.read_jobs(p)) == n_jl
                cid = DistSSHQueue.read_jobs(p)[2].id
                code_c, out_c, _ = capture_stdio() do
                    DistSSHQueue.main(["cancel", cid])
                end
                @test code_c == 0
                @test strip(out_c) == cid
                cancelled = DistSSHQueue.read_jobs(p)
                @test any(j -> j.id == cid && j.state === :cancelled, cancelled)
            end
        end
    end
end

# Same stream and entry as `_main`: stdout, and no color while stdout is not a TTY.
function _help_root_page()
    buf = IOBuffer()
    redirect_stdout(devnull) do
        DistSSHQueue.with_cli_entry(:DistSSHQueue) do
            DistSSHQueue.print_queue_usage(buf)
        end
    end
    return String(take!(buf))
end

function _help_topic_page(topic::AbstractString)
    buf = IOBuffer()
    redirect_stdout(devnull) do
        DistSSHQueue.with_cli_entry(:DistSSHQueue) do
            DistSSHQueue.print_queue_usage(buf; topic = topic)
        end
    end
    return String(take!(buf))
end

function _help_command_page(verb::AbstractString)
    buf = IOBuffer()
    redirect_stdout(devnull) do
        DistSSHQueue.with_cli_entry(:DistSSHQueue) do
            DistSSHQueue.print_queue_command_usage(buf, verb)
        end
    end
    return String(take!(buf))
end

function _help_topic_error(topic::AbstractString)
    msg = try
        DistSSHQueue.print_queue_usage(IOBuffer(); topic = topic)
        error("topic printed")
    catch e
        e isa ArgumentError || rethrow()
        e.msg
    end
    _, _, err = capture_stdio() do
        DistSSHRun.print_cli_error(msg)
        return 1
    end
    return err
end

@testset "help-only argv is the root page" begin
    mktempdir() do d
        withenv(
            "DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml"),
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
        ) do
            page = _help_root_page()
            for line in DistSSHQueue.CLIENT_COMMAND_LINES
                @test occursin(line, page)
            end
            for line in DistSSHQueue.QUEUE_HOST_COMMAND_LINES
                @test occursin(line, page)
            end
            for args in (
                    ["help"],
                    ["-h"],
                    ["--help"],
                    ["help", "--help"],
                    ["help", "-h"],
                    ["help", "help"],
                    ["--help", "help"],
                    ["-h", "--help"],
                    ["--help", "-h", "help"],
                )
                code, out, err = capture_stdio() do
                    DistSSHQueue.main(args)
                end
                @test code == 0
                @test out == page
                @test err == ""
            end
            code_bogus, out_bogus, err_bogus = capture_stdio() do
                DistSSHQueue.main(["help", "bogus"])
            end
            @test code_bogus == 1
            @test out_bogus == ""
            @test err_bogus == _help_topic_error("bogus")
            code_sub, out_sub, err_sub = capture_stdio() do
                DistSSHQueue.main(["help", "submit", "--help"])
            end
            code_direct, out_direct, err_direct = capture_stdio() do
                DistSSHQueue.main(["submit", "--help"])
            end
            @test (code_sub, out_sub, err_sub) == (code_direct, out_direct, err_direct)
            @test code_sub == 0
            @test out_sub == _help_command_page("submit")
            @test err_sub == ""
            code_qh, out_qh, err_qh = capture_stdio() do
                DistSSHQueue.main(["help", "qhost", "--help"])
            end
            code_topic, out_topic, err_topic = capture_stdio() do
                DistSSHQueue.main(["help", "qhost"])
            end
            @test (code_qh, out_qh, err_qh) == (code_topic, out_topic, err_topic)
            @test code_qh == 0
            @test out_qh == _help_topic_page("qhost")
            @test err_qh == ""
        end
    end
end

@testset "submit kind help does not need a queue target" begin
    mktempdir() do d
        home = joinpath(d, "home")
        mkpath(home)
        withenv(
            "HOME" => home,
            DistSSHQueue.LOCAL_QUEUE_ENV => nothing,
            "DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml"),
            "DISTSSHQUEUE_HOST" => nothing,
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
        ) do
            @test !DistSSHQueue.queue_host_machine()
            @test !DistSSHQueue.local_queue_exempt()
            code_go, out_go, err_go = capture_stdio() do
                DistSSHQueue.main(["submit", "go", "--help"])
            end
            @test code_go == 0
            @test err_go == ""
            @test occursin("not a Kit slot", out_go)
            for args in (
                    ["submit", "go", "-h"],
                    ["help", "submit", "go"],
                    ["submit", "pool:2", "go", "--help"],
                    ["qhost:no-such-host", "submit", "go", "--help"],
                    ["qhost:no-such-host", "help", "submit", "go"],
                )
                code, out, err = capture_stdio() do
                    DistSSHQueue.main(args)
                end
                @test code == 0
                @test out == out_go
                @test err == ""
            end
            for kind in ("ride", "drive")
                code, out, err = capture_stdio() do
                    DistSSHQueue.main(["submit", kind, "--help"])
                end
                @test code == 0
                @test err == ""
                @test occursin(kind, out)
                @test out != out_go
            end
            code_page, out_page, err_page = capture_stdio() do
                DistSSHQueue.main(["submit", "pool:2", "--help"])
            end
            @test code_page == 0
            @test err_page == ""
            @test out_page == _help_command_page("submit")
            code_need, _, err_need = capture_stdio() do
                DistSSHQueue.main(["submit", "go"])
            end
            @test code_need == 1
            @test occursin("no config / store", err_need)
            code_ver, _, err_ver = capture_stdio() do
                DistSSHQueue.main(["submit", "go", "--version"])
            end
            @test code_ver == 1
            @test occursin("no config / store", err_ver)
            code_bad, _, err_bad = capture_stdio() do
                DistSSHQueue.main(["submit", "go", "--not-a-flag"])
            end
            @test code_bad == 1
            @test occursin("no config / store", err_bad)
            @test !occursin("unknown", err_bad)
        end
    end
end

@testset "CLI submit respects config allowed" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        cfg = joinpath(d, "config.toml")
        write(cfg, "store = $(repr(p))\nhosts = [\"parent\"]\n")
        jobdir = mktempdir()
        write(joinpath(jobdir, "Project.toml"), "[deps]\n")
        write(joinpath(jobdir, "job.jl"), "1\n")
        withenv(
            "DISTSSHQUEUE_STORE" => p,
            "DISTSSHQUEUE_CONFIG" => cfg,
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
        ) do
            cd(jobdir) do
                code_ok, out_ok, err_ok = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "parent:1", "job.jl"])
                end
                @test code_ok == 0
                @test occursin(r"Queued\s+1\b", err_ok)
                @test occursin("(no running)", err_ok)
                @test occursin("queue: local", err_ok)
                @test !occursin("qhost: local", err_ok)
                @test !occursin("no add-host list", err_ok)
                @test !occursin("Queued", out_ok)
                id1 = strip(out_ok)
                @test !isempty(id1)
                withenv(DistSSHQueue.QHOST_DISPLAY_ENV => "mini-tak-ts") do
                    code_h, _, err_h = capture_stdio() do
                        DistSSHQueue.main(["submit", "go", "parent:1", "job.jl"])
                    end
                    @test code_h == 0
                    @test occursin("qhost: local", err_h)
                    @test !occursin("queue: local", err_h)
                    @test !occursin("queue: qhost:", err_h)
                end
                code2, out2, err2 = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "parent:1", "job.jl"])
                end
                @test code2 == 0
                @test occursin(r"Queued\s+3\b", err2)
                @test strip(out2) != id1
                withenv("DISTSSHKIT_QUIET" => "1") do
                    code_q, out_q, err_q = capture_stdio() do
                        DistSSHQueue.main(["submit", "go", "parent:1", "job.jl"])
                    end
                    @test code_q == 0
                    @test !occursin("Queued", err_q)
                    @test !occursin("queue: local", err_q)
                    @test !occursin("no add-host list", err_q)
                    @test !isempty(strip(out_q))
                end
                code_bad, _, err = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "child:host1:1", "job.jl"])
                end
                @test code_bad == 1
                @test occursin("not allowed", err)
            end
        end
    end
end

@testset "status error shows the full Kit line with a Queue prefix" begin
    kit = """setup: "parent" is only for up (kit parent machine). extra words"""
    j = DistSSHQueue.Job(; kind = :go, script = "x.jl", hosts = ["parent:1"], state = :failed, error = kit)
    shown = DistSSHQueue._job_error_disp(j)
    @test occursin("parent:N", shown)
    @test occursin("only for up", shown)
    @test occursin("extra words", shown)
    @test !endswith(shown, "…")
    @test DistSSHQueue.queue_explain_error("unrelated only for up noise") ==
        "unrelated only for up noise"
    prefixed = DistSSHQueue.queue_explain_error("this job includes parent:N; keep")
    @test prefixed == "this job includes parent:N; keep"
end

@testset "CLI submit pool:N" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        cfg = joinpath(d, "config.toml")
        write(cfg, "store = $(repr(p))\nhosts = [\"parent\", \"child:host1:4\"]\n")
        jobdir = mktempdir()
        write(joinpath(jobdir, "Project.toml"), "[deps]\n")
        write(joinpath(jobdir, "job.jl"), "1\n")
        withenv(
            "DISTSSHQUEUE_STORE" => p,
            "DISTSSHQUEUE_CONFIG" => cfg,
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
        ) do
            cd(jobdir) do
                code, _, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "pool:8", "go", "job.jl"])
                end
                @test code == 0
                @test DistSSHQueue.read_jobs(p)[end].hosts == ["parent:8", "child:host1:4"]
                code_m, _, err_m = capture_stdio() do
                    DistSSHQueue.main(["submit", "pool:2", "go", "parent:1", "job.jl"])
                end
                @test code_m == 1
                @test occursin("cannot mix", err_m)
                rest, n = DistSSHQueue.peel_submit_pool(
                    ["go", "--julia", "pool:8", "parent:1", "job.jl"],
                )
                @test n === nothing
                @test rest == ["go", "--julia", "pool:8", "parent:1", "job.jl"]
                rest2, n2 = DistSSHQueue.peel_submit_pool(["pool:8", "go", "job.jl"])
                @test n2 == 8
                @test rest2 == ["go", "job.jl"]
            end
        end
    end
end

@testset "CLI add-host applies while serve is running" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        cfg = joinpath(d, "config.toml")
        write(cfg, "store = $(repr(p))\nhosts = [\"parent\"]\n")
        jobdir = mktempdir()
        write(joinpath(jobdir, "Project.toml"), "[deps]\n")
        write(joinpath(jobdir, "job.jl"), "1\n")
        q = Queue(; store = p, runner = _ -> nothing)
        withenv(
            "DISTSSHQUEUE_STORE" => p,
            "DISTSSHQUEUE_CONFIG" => cfg,
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
        ) do
            cd(jobdir) do
                capture_stdio() do
                    t = @async DistSSHQueue.serve!(q; interval = 0.02)
                    for _ in 1:200
                        DistSSHQueue.serve_pid(p) == getpid() && break
                        sleep(0.02)
                    end
                    @test DistSSHQueue.serve_pid(p) == getpid()
                    code_bad, _, err = capture_stdio() do
                        DistSSHQueue.main(["submit", "go", "child:host1:1", "job.jl"])
                    end
                    @test code_bad == 1
                    @test occursin("not allowed", err)
                    code_add, _, _ = capture_stdio() do
                        DistSSHQueue.main(["add-host", "child:host1"])
                    end
                    @test code_add == 0
                    code_ok, _, _ = capture_stdio() do
                        DistSSHQueue.main(["submit", "go", "child:host1:1", "job.jl"])
                    end
                    @test code_ok == 0
                    schedule(t, InterruptException(); error = true)
                    try
                        wait(t)
                    catch
                    end
                end
            end
        end
    end
end

@testset "CLI list-host lists names and ssh -G fields" begin
    buf = IOBuffer()
    DistSSHQueue._print_cli_note(
        buf,
        "child:host1",
        "DistSSHKit can reach this name from this queue host. Anyone who can submit as this user (including qhost:) can use them.";
        cols = 40,
    )
    wrapped = split(String(take!(buf)), '\n'; keepempty = false)
    @test !isempty(wrapped)
    @test all(l -> textwidth(l) <= 40, wrapped)
    @test startswith(wrapped[1], "  ! ")
    @test any(l -> startswith(l, "    "), wrapped)
    let (nw, tw, mw, jw, sw) = DistSSHQueue._list_host_fit(40, 40, 3, 5, 48)
        @test nw + tw + mw + jw + sw + 10 <= 48
        @test nw >= 4
        @test tw >= 5
        @test sw >= 8
    end
    let (nw, tw, mw, jw, sw) = DistSSHQueue._list_host_fit(80, 11, 3, 6, 72)
        @test tw == 11
        @test nw < 80
        @test nw >= 4
        @test nw + tw + mw + jw + sw + 10 <= 72
    end
    hn = "sat12-bq153-f5a29c4d-2cfd-48dd-a60c-d49a6140ecf7-3AD76F09ECCB.local"
    let (nw, tw, mw, jw, _) = DistSSHQueue._list_host_fit(
            textwidth(hn), textwidth("child:host1"), 3, 6, 72,
        )
        buf = IOBuffer()
        DistSSHQueue.print_wrapped_row(
            buf, [hn, "child:host1", "-", "1.13.2"], Int[nw, tw, mw, jw],
            "lab@10.0.0.8:2222"; cols = 72,
        )
        row = String(take!(buf))
        @test occursin("child:host1", row)
        @test !occursin(hn, row)
        @test occursin(first(hn, 12), row)
    end
    @test shows_flat("local\n         (host.local)", "local (host.local)")
    overflow = IOBuffer()
    DistSSHQueue.print_wrapped_tail(overflow, repeat("P", 25), "SSH"; cols = 27)
    olines = split(String(take!(overflow)), '\n'; keepempty = false)
    @test all(l -> textwidth(l) <= 27, olines)
    @test any(l -> occursin("SSH", l), olines)
    mktempdir() do d
        cfg = joinpath(d, "config.toml")
        fake = joinpath(d, "fakebin")
        mkpath(fake)
        write(
            joinpath(fake, "ssh"),
            """
            #!/bin/sh
            for a in "\$@"; do
              if [ "\$a" = "-G" ]; then
                printf '%s\\n' "host host1"
                printf '%s\\n' "hostname 10.0.0.8"
                printf '%s\\n' "user lab"
                printf '%s\\n' "port 2222"
                printf '%s\\n' "identityfile /secret/id_rsa"
                exit 0
              fi
            done
            printf '%s\\n' "* 1.13   1.13.2+0.x86_64-linux-gnu"
            exit 0
            """,
        )
        chmod(joinpath(fake, "ssh"), 0o755)
        ju = joinpath(fake, "juliaup")
        write(
            ju,
            """
            #!/bin/sh
            [ "\$1" = "status" ] || exit 1
            printf '%s\\n' "* 1.12   1.12.7+0.x86_64-linux-gnu"
            exit 0
            """,
        )
        chmod(ju, 0o755)
        path = fake * ":" * get(ENV, "PATH", "")
        write(cfg, "hosts = [\"parent\", \"child:host1\"]\n")
        withenv(
            "DISTSSHQUEUE_CONFIG" => cfg,
            "PATH" => path,
            "DISTSSHKIT_TEST" => "1",
            "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju,
        ) do
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["list-host"])
            end
            @test code == 0
            @test occursin("parent", out)
            @test occursin("child:host1", out)
            @test occursin("TOKEN", out)
            @test !occursin("HOST TOKEN", out)
            @test shows_hostname_prefix(out)
            @test occursin("this machine", out)
            @test !occursin("queue host", out)
            # SSH wraps when NAME is wide: PkgEval's long hostname in a
            # 72-column pipe leaves no room for the 17-char field. Order is
            # kept, so match without the wrap whitespace. lab / 10.0.0.8 /
            # 2222 are also checked below.
            @test occursin("lab@10.0.0.8:2222", replace(out, r"\s+" => ""))
            @test !occursin("    host      host1", out)
            @test occursin("10.0.0.8", out)
            @test occursin("lab", out)
            @test occursin("2222", out)
            @test !occursin("HostName", out)
            @test !occursin("identityfile", lowercase(out))
            @test !occursin("id_rsa", out)
            @test occursin("MAX", out)
            @test occursin("JULIA", out)
            @test !occursin("JULIAUP", out)
            @test occursin("1.12.7", out)
            @test occursin("1.13.2", out)
            @test !occursin("1.12.7+", out)
            narrow = IOBuffer()
            DistSSHQueue.print_list_host(
                DistSSHQueue.config_host_names(DistSSHQueue.load_config());
                io = narrow,
                cols = 40,
            )
            for line in split(String(take!(narrow)), '\n'; keepempty = false)
                startswith(line, "  ") || continue
                @test textwidth(line) <= 40
            end
        end
        write(cfg, "hosts = [\"parent\", \"child:host1\"]\n")
        withenv(
            "DISTSSHQUEUE_CONFIG" => cfg,
            "PATH" => path,
            DistSSHQueue.QHOST_DISPLAY_ENV => "mini",
        ) do
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["list-host"])
            end
            @test code == 0
            @test occursin("queue host", out)
            @test !occursin("this machine", out)
            @test shows_hostname_prefix(out)
            @test occursin("parent", out)
        end
        write(cfg, "store = \"x\"\n")
        withenv("DISTSSHQUEUE_CONFIG" => cfg, "PATH" => path) do
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["list-host"])
            end
            @test code == 0
            @test occursin("add-host first", out)
        end
        write(cfg, "hosts = []\n")
        withenv("DISTSSHQUEUE_CONFIG" => cfg, "PATH" => path) do
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["list-host"])
            end
            @test code == 0
            @test occursin("accepts none", out)
        end
        withenv("DISTSSHQUEUE_CONFIG" => cfg) do
            bad, _, err = capture_stdio() do
                DistSSHQueue.main(["list-host", "--hosts"])
            end
            @test bad == 1
            @test occursin("unknown list-host option", err)
        end
        write(cfg, DistSSHQueue.default_config_body(; store = joinpath(d, "jobs.toml")))
        withenv("DISTSSHQUEUE_CONFIG" => cfg, "PATH" => path) do
            code_p, out_p, _ = capture_stdio() do
                DistSSHQueue.main(["add-host", "parent"])
            end
            @test code_p == 0
            @test !occursin("reachable via DistSSHKit", out_p)
            @test !occursin("  ! ", out_p)
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["add-host", "parent", "child:host1"])
            end
            @test code == 0
            @test occursin("child:host1", out)
            @test occursin("  ! ", out)
            @test occursin("DistSSHKit can reach", out)
            @test occursin("including qhost:", out)
            @test occursin("outbound internet", out)
            @test occursin("unless the depot", out)
            @test occursin("instantiate", out)
            @test DistSSHQueue.config_host_names(DistSSHQueue.load_config()) ==
                DistSSHQueue.HostAllow("parent" => nothing, "host1" => nothing)
            withenv("DISTSSHKIT_QUIET" => "1") do
                code_q, out_q, _ = capture_stdio() do
                    DistSSHQueue.main(["add-host", "child:host2"])
                end
                @test code_q == 0
                @test occursin("child:host2", out_q)
                @test !occursin("  ! ", out_q)
                @test !occursin("DistSSHKit can reach", out_q)
            end
            code2, out2, _ = capture_stdio() do
                DistSSHQueue.main(["remove-host", "parent"])
            end
            @test code2 == 0
            @test occursin("host1", out2)
            @test DistSSHQueue.config_host_names(DistSSHQueue.load_config()) ==
                DistSSHQueue.HostAllow("host1" => nothing, "host2" => nothing)
            bad2, _, err2 = capture_stdio() do
                DistSSHQueue.main(["add-host", "--hosts"])
            end
            @test bad2 == 1
            @test occursin("unknown add-host option", err2)
        end
    end
end

@testset "size uses Kit argv or config hosts" begin
    allow = DistSSHQueue.HostAllow("parent" => nothing, "host1" => 4)
    inc, hosts = DistSSHQueue.size_hosts_from_allow(false, String[], allow)
    @test inc
    @test hosts == ["host1"]
    inc2, hosts2 = DistSSHQueue.size_hosts_from_allow(true, String["w"], allow)
    @test inc2
    @test hosts2 == ["w"]
    @test_throws ArgumentError DistSSHQueue.size_hosts_from_allow(false, String[], nothing)
    @test_throws ArgumentError DistSSHQueue.size_hosts_from_allow(
        false,
        String[],
        DistSSHQueue.HostAllow(),
    )
    code, out, _ = capture_stdio() do
        DistSSHQueue.main(["size", "-h"])
    end
    @test code == 0
    @test occursin("DistSSHQueue size", out)
    @test occursin("Queue", out)
    @test occursin("qhost:HOST", out)
    @test occursin("Does not enqueue", out)
end

@testset "plan inspects a script and does not enqueue" begin
    code, out, _ = capture_stdio() do
        DistSSHQueue.main(["plan", "-h"])
    end
    @test code == 0
    @test occursin("DistSSHQueue plan", out)
    @test occursin("Queue", out)
    @test occursin("Does not enqueue", out)
    mktempdir() do d
        jobdir = joinpath(d, "job")
        mkpath(jobdir)
        write(joinpath(jobdir, "Project.toml"), "[deps]\n")
        write(joinpath(jobdir, "echo.jl"), "println(1)\n")
        p = joinpath(d, "jobs.toml")
        withenv(
            "DISTSSHQUEUE_STORE" => p,
            "DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml"),
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
            "DISTRIBUTED_PROJECT_ROOT" => nothing,
        ) do
            cd(jobdir) do
                code_p, out_p, _ = capture_stdio() do
                    DistSSHQueue.main(["plan", "echo.jl"])
                end
                @test code_p == 0
                @test occursin("suggest:", out_p)
                @test occursin("Suggested submit (template):", out_p)
                @test occursin("julia --project=. -m DistSSHQueue submit", out_p)
                @test !occursin("-m DistSSHKit submit", out_p)
                @test occursin("submit go", out_p) || occursin("submit ride", out_p) ||
                    occursin("submit drive", out_p)
                @test !isfile(p)
            end
        end
    end
end

@testset "pool help does not enqueue" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        withenv(
            "DISTSSHQUEUE_STORE" => p,
            "DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml"),
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
            "DISTRIBUTED_PROJECT_ROOT" => nothing,
        ) do
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["pool", "-h"])
            end
            @test code == 0
            @test occursin("DistSSHQueue pool", out)
            @test occursin("Queue", out)
            @test occursin("Does not enqueue", out)
            @test !isfile(p)
        end
    end
end

@testset "inspect CLI chrome" begin
    _, out, _ = capture_stdio() do
        DistSSHQueue.with_cli_entry(:DistSSHQueue) do
            DistSSHQueue.print_inspect_submit_template("drive", String["parent:2", "child:host1:4"])
        end
    end
    @test occursin("Suggested submit (template):", out)
    @test occursin(
        "julia --project=. -m DistSSHQueue submit drive parent:2 child:host1:4 SCRIPT.jl",
        out,
    )
    @test !occursin("-m DistSSHKit submit", out)
    _, empty_out, _ = capture_stdio() do
        DistSSHQueue.with_cli_entry(:DistSSHQueue) do
            DistSSHQueue.print_inspect_submit_template("go", String[])
        end
    end
    @test occursin("julia --project=. -m DistSSHQueue submit go SCRIPT.jl", empty_out)
    @test !occursin("-m DistSSHKit submit", empty_out)

    line = DistSSHQueue.pool_sizing_assumption_line(;
        gb_per_worker = nothing,
        mem_headroom = DistSSHRun.DEFAULT_MEM_HEADROOM,
        parent_gb = DistSSHRun.DEFAULT_PARENT_GB,
    )
    @test occursin("1.5 GB/worker", line)
    @test occursin("no RSS; use size to measure", line)

    _, notes, _ = capture_stdio() do
        DistSSHQueue.print_pool_inventory_notes!(;
            gb_per_worker = 2.0,
            mem_headroom = 0.75,
            parent_gb = 0.4,
        )
    end
    @test occursin("2.0 GB/worker", notes)
    @test occursin("parent is this queue host", notes)
    @test occursin("not free queue capacity", notes)
end

@testset "pool submit template respects Queue host caps" begin
    pool = DistSSHRun.ResourcePool(
        true,
        [
            DistSSHRun.HostInventory(DistSSHQueue.PARENT_HOST_NAME, true, 8, 64.0, 8, ""),
            DistSSHRun.HostInventory("host1", true, 8, 64.0, 8, ""),
        ],
        16,
        128.0,
        16,
    )
    allow = DistSSHQueue.HostAllow("parent" => 2, "host1" => 4)
    _, out, _ = capture_stdio() do
        DistSSHQueue.with_cli_entry(:DistSSHQueue) do
            DistSSHQueue.print_queue_pool_submit(pool, allow)
        end
    end
    @test occursin("Suggested submit (template):", out)
    @test occursin("julia --project=. -m DistSSHQueue submit drive", out)
    @test !occursin("-m DistSSHKit submit", out)
    @test occursin("parent:2", out)
    @test occursin("child:host1:4", out)
    @test !occursin("parent:8", out)
    @test !occursin("child:host1:8", out)
end

@testset "watch reprints status then exits on DISTSSHQUEUE_WATCH_TICKS" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        jobdir = joinpath(d, "jobtree")
        mkpath(jobdir)
        write(joinpath(jobdir, "a.jl"), "1\n")
        write(joinpath(d, "config.toml"), "store = $(repr(p))\nhosts = [\"parent\"]\n")
        withenv(
            "DISTSSHQUEUE_STORE" => p,
            "DISTSSHQUEUE_CONFIG" => joinpath(d, "config.toml"),
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
            "DISTRIBUTED_PROJECT_ROOT" => nothing,
            "DISTSSHQUEUE_WATCH_TICKS" => "1",
        ) do
            cd(jobdir) do
                code, out, _ = capture_stdio() do
                    DistSSHQueue.main(["watch", "--interval", "0.01"])
                end
                @test code == 0
                @test occursin("serve", out)
                @test occursin("running", out)
                @test occursin("queued", out)
                @test !occursin("DistSSHQueue watch", out)
                @test !occursin("Ctrl-C stops watch", out)
                code_si, out_si, _ = capture_stdio() do
                    DistSSHQueue.main(["status", "--interval", "0.01"])
                end
                @test code_si == 0
                @test occursin("serve", out_si)
                @test occursin("running", out_si)
                @test occursin("queued", out_si)
                @test !occursin("Ctrl-C stops watch", out_si)
                code_qw, out_qw, _ = capture_stdio() do
                    DistSSHQueue.main(["watch", "-q", "--interval", "0.01"])
                end
                @test code_qw == 0
                @test occursin("(none)", out_qw)
                @test !occursin("(empty)", out_qw)
                @test !occursin("Store", out_qw)
                @test !occursin("DistSSHQueue watch", out_qw)
                @test !occursin("Ctrl-C stops watch", out_qw)
                code_go, _, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "parent:1", "a.jl"])
                end
                @test code_go == 0
                withenv("DISTSSHQUEUE_WATCH_TICKS" => "2") do
                    code2, out2, _ = capture_stdio() do
                        DistSSHQueue.main(["watch", "--interval", "0.01"])
                    end
                    @test code2 == 0
                    @test occursin("queued", out2)
                end
                errc, _, err = capture_stdio() do
                    DistSSHQueue.main(["watch", "--bogus"])
                end
                @test errc == 1
                @test occursin("unknown watch option", err)
                errt, _, err_ticks = capture_stdio() do
                    DistSSHQueue.main(["watch", "--ticks", "1"])
                end
                @test errt == 1
                @test occursin("unknown watch option", err_ticks)
                frame = sprint(io -> DistSSHQueue.print_watch_frame(p, DistSSHQueue.Job[]; io = io))
                @test occursin("Store", frame)
                @test occursin("serve", frame)
                @test occursin("Ctrl-C stops watch", frame)
                @test !occursin("Process", frame)
                live_n = IOBuffer()
                DistSSHQueue.print_status_table(
                    p, DistSSHQueue.Job[]; io = live_n, live = true, cols = 24,
                )
                for line in split(String(take!(live_n)), '\n'; keepempty = false)
                    @test textwidth(line) <= 24
                end
            end
        end
    end
end

@testset "watch TTY paint clears before the frame" begin
    prev = Ref("")
    buf = IOBuffer()
    DistSSHQueue._watch_paint!(buf, "ab", prev; clear = true)
    DistSSHQueue._watch_paint!(buf, "c", prev; clear = true)
    @test String(take!(buf)) == "\e[H\e[Jab\e[H\e[Jc"
    prev_pipe = Ref("")
    pipe = IOBuffer()
    DistSSHQueue._watch_paint!(pipe, "ab", prev_pipe)
    DistSSHQueue._watch_paint!(pipe, "c", prev_pipe)
    @test String(take!(pipe)) == "abc"
end

@testset "qhost status hop tty does not require --interval" begin
    @test DistSSHQueue.status_watch_hop_tty(String[]; client_tty = true)
    @test DistSSHQueue.status_watch_hop_tty(["--interval", "0.5"]; client_tty = true)
    @test DistSSHQueue.status_watch_hop_tty(String[]; client_tty = false) === false
end

@testset "qhost hop forwards NO_COLOR" begin
    withenv("NO_COLOR" => "1", "DISTSSHKIT_QUIET" => nothing) do
        assigns = String[]
        DistSSHQueue.append_hop_forwarded_env!(assigns)
        @test any(a -> occursin("NO_COLOR", a), assigns)
    end
    withenv("NO_COLOR" => nothing, "DISTSSHKIT_QUIET" => nothing) do
        assigns = String[]
        DistSSHQueue.append_hop_forwarded_env!(assigns)
        @test !any(a -> occursin("NO_COLOR", a), assigns)
    end
end

@testset "cli surfaces friendly errors instead of stacktraces" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        jobdir = joinpath(d, "jobtree")
        mkpath(jobdir)
        withenv(
            "DISTSSHQUEUE_STORE" => p,
            "DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml"),
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
            "DISTRIBUTED_PROJECT_ROOT" => nothing,
        ) do
            cd(jobdir) do
                code, _, err = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "parent:1", "no_such.jl"])
                end
                @test code == 1
                @test occursin("not found", err)
                @test isempty(DistSSHQueue.read_jobs(p))

                code2, _, err2 = capture_stdio() do
                    DistSSHQueue.main(["cancel"])
                end
                @test code2 == 1
                @test occursin("Error:", err2)
                @test occursin("need a job id", err2)
                @test !occursin("Stacktrace", err2)

                code3, _, err3 = capture_stdio() do
                    DistSSHQueue.main(["cancel", "no-such-id"])
                end
                @test code3 == 1
                @test occursin("cannot be cancelled", err3)

                code4, _, err4 = capture_stdio() do
                    DistSSHQueue.main(["qhost:h", "serve"])
                end
                @test code4 == 1
                @test occursin("Error:", err4)
            end
        end
    end
end

@testset "status missing store is none, empty file is empty" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        miss = sprint(io -> DistSSHQueue.show_status(p; io = io))
        @test occursin("  path   none", miss)
        @test occursin("(none)", miss)
        @test !occursin("(empty)", miss)
        DistSSHQueue.save_jobs(p, DistSSHQueue.Job[])
        z = sprint(io -> DistSSHQueue.show_status(p; io = io))
        @test occursin("(empty)", z)
        @test !occursin("  path   none", z)
        @test occursin("path", z)
        hop = sprint(io -> DistSSHQueue.show_status(p; io = io, qhost = "qbox"))
        @test occursin("qbox:", hop)
        @test shows_flat(hop, "qbox ($(gethostname()))")
        hopnone = sprint(io -> DistSSHQueue.show_status(joinpath(d, "gone.toml"); io = io, qhost = "qbox"))
        @test occursin("  path   none", hopnone)
        @test !occursin("qbox:none", hopnone)
        q = sprint(io -> DistSSHQueue.show_status(p; io = io, quiet = true))
        @test occursin("(empty)", q)
        @test !occursin("Store", q)
        mq = sprint(io -> DistSSHQueue.show_status(joinpath(d, "gone.toml"); io = io, quiet = true))
        @test occursin("(none)", mq)
        @test !occursin("(empty)", mq)
        @test !occursin("Store", mq)
    end
end

@testset "status table shows the error line for failed jobs" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        q = Queue(; store = p, runner = _ -> error("boom: kaboom"))
        id = submit!(q, "a.jl", "parent:1")
        @test step!(q) == 1
        _wait_state(q, id, :failed)
        listed = sprint(io -> DistSSHQueue.show_status(p; io = io))
        @test occursin("error", listed)
        @test occursin("boom: kaboom", listed)
    end
end

@testset "serve live line" begin
    @test DistSSHQueue._serve_live_text('⠋', nothing) == "  ⠋  idle"
    mktempdir() do d::String
        script = joinpath(d, "demos", "pi_echo.jl")
        mkpath(dirname(script))
        write(script, "1\n")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = script,
            hosts = ["parent:1"],
            state = :running,
            kwargs = Dict{String, Any}("project" => d),
        )
        ids = [j.id]
        t = DistSSHQueue._serve_live_text('⠙', j, ids)
        @test startswith(t, "  ⠙  running  $(first(j.id, 8))  go")
        stopping = DistSSHQueue.Job(;
            id = j.id,
            kind = :go,
            script = script,
            hosts = ["parent:1"],
            state = :running,
            kwargs = Dict{String, Any}("project" => d, "cancel" => true),
        )
        @test startswith(DistSSHQueue._serve_live_text('⠙', stopping, ids), "  ⠙  stopping  $(first(j.id, 8))  go")
        @test !occursin(j.id, t)
        @test occursin("demos/pi_echo.jl", t) || occursin(joinpath("demos", "pi_echo.jl"), t)
        @test !occursin(d, t)
        narrow = DistSSHQueue._serve_live_text('⠙', j, ids; cols = 20)
        @test textwidth(narrow) <= 20
        @test endswith(narrow, "…")
    end
    buf = IOBuffer()
    DistSSHQueue.print_serve_banner(1, "/tmp/jobs.toml"; io = buf)
    s = String(take!(buf))
    @test occursin("pid 1", s)
    @test occursin("store", s)
    @test !occursin("Process", s)
    buf2 = IOBuffer()
    DistSSHQueue.print_serve_idle_note(; io = buf2)
    note = String(take!(buf2))
    @test occursin("Ctrl-C stops serve", note)
    @test occursin("A job still in setup fails", note)
    @test occursin("A detached DistSSHKit job is not killed", note)
end

@testset "job id prefix and status paths relative to project" begin
    mktempdir() do d
        stage = joinpath(d, ".distsshqueue", "stage", "1f7276b9bbc65609")
        mkpath(joinpath(stage, "demos"))
        script = joinpath(stage, "demos", "pi_echo.jl")
        write(script, "1\n")
        leaf = joinpath(stage, "demos", ".distsshkit", "go", "pi_echo_x_aaaaaaaa-1111-4000-8000-000000000001")
        a = DistSSHQueue.Job(;
            id = "aaaaaaaa-1111-4000-8000-000000000001",
            kind = :go,
            script = script,
            hosts = ["parent:1"],
            state = :done,
            result_path = leaf,
            kwargs = Dict{String, Any}("project" => stage),
        )
        b = DistSSHQueue.Job(;
            id = "aaaaaaaa-2222-4000-8000-000000000002",
            kind = :go,
            script = script,
            hosts = ["parent:1"],
            state = :queued,
            kwargs = Dict{String, Any}("project" => stage),
        )
        q = DistSSHQueue.Queue()
        push!(q.jobs, a, b)
        @test job(q, a.id).id == a.id
        @test job(q, "aaaaaaaa-1111").id == a.id
        @test_throws ArgumentError job(q, "aaaaaaaa")
        @test_throws ArgumentError job(q, "nope")
        p = joinpath(d, "jobs.toml")
        DistSSHQueue.save_jobs(p, [a, b])
        listed = sprint(io -> DistSSHQueue.show_status(p; io = io))
        @test occursin("aaaaaaaa-1", listed)
        @test occursin("aaaaaaaa-2", listed)
        @test occursin("pi_echo_x_aaaaaaaa-1111-4000-8000-000000000001", listed)
        @test occursin(joinpath("demos", "pi_echo.jl"), listed) || occursin("demos/pi_echo.jl", listed)
        @test !occursin(stage * "/", listed)
        @test occursin(
            replace(DistSSHQueue.short_path(stage), r"\s+" => ""),
            replace(listed, r"\s+" => ""),
        )
    end
end

@testset "status cards show queued time, wall, and folded hosts" begin
    qat = DateTime(2026, 9, 10, 4, 20)
    done = DistSSHQueue.Job(;
        id = "bbbbbbbb-1111-4000-8000-000000000001",
        kind = :drive,
        script = "d.jl",
        hosts = ["parent:5", "child:mini-alpha:8", "child:mini-beta:8", "child:mini-gamma:8"],
        state = :done,
        queued_at = qat,
        started_at = qat,
        finished_at = qat + Hour(1) + Minute(4),
    )
    run = DistSSHQueue.Job(;
        id = "bbbbbbbb-2222-4000-8000-000000000002",
        kind = :go,
        script = "g.jl",
        hosts = ["parent:1"],
        state = :running,
        queued_at = qat,
        started_at = now(UTC) - Minute(12) - Second(30),
    )
    listed = sprint(io -> DistSSHQueue.print_jobs_table([done, run]; io = io))
    @test occursin("queued", listed)
    local_q = DistSSHQueue._job_queued_disp(done)
    @test occursin(local_q, listed)
    @test occursin("wall", listed)
    @test occursin("1h04m", listed)
    @test occursin("elapsed", listed)
    @test DistSSHQueue._human_span(qat, qat + Minute(12)) == "12m"
    @test occursin("parent:5  child:mini-alpha:8  +2", listed)
    @test !occursin("child:mini-gamma:8", listed)
    full = sprint(io -> DistSSHQueue.print_jobs_table([done]; io = io, verbose = true))
    @test occursin("child:mini-gamma:8", full)
    quiet = sprint(io -> DistSSHQueue.print_jobs_table([done]; io = io, quiet = true))
    @test !occursin("queued", quiet)
    @test !occursin("hosts", quiet)
    failed = DistSSHQueue.Job(;
        id = "cccccccc-1111-4000-8000-000000000001",
        kind = :go,
        script = "s.jl",
        hosts = ["parent:1"],
        state = :failed,
        error = "setup failed because " * repeat("x", 60),
        result_path = joinpath("/tmp", "artifact" * repeat("y", 40)),
    )
    narrow = IOBuffer()
    DistSSHQueue.print_jobs_table([failed]; io = narrow, cols = 40)
    nlines = split(String(take!(narrow)), '\n'; keepempty = false)
    @test !isempty(nlines)
    @test all(l -> textwidth(l) <= 40, nlines)
    @test any(l -> startswith(l, "    "), nlines)
    @test any(l -> occursin("error", l), nlines)
    # _utc_to_local is libc localtime. Needs the America/New_York zone file;
    # PkgEval's Debian sandbox has no tzdata, so TZ stays UTC there. Skip
    # rather than accept the UTC passthrough, which would hide a conversion bug.
    if !Sys.iswindows() && isfile("/usr/share/zoneinfo/America/New_York")
        winter = DateTime(2026, 1, 15, 12, 0)
        summer = DateTime(2026, 7, 15, 12, 0)
        old_tz = get(ENV, "TZ", nothing)
        try
            ENV["TZ"] = "America/New_York"
            ccall(:tzset, Cvoid, ())
            @test DistSSHQueue._utc_to_local(winter) == DateTime(2026, 1, 15, 7, 0)
            @test DistSSHQueue._utc_to_local(summer) == DateTime(2026, 7, 15, 8, 0)
        finally
            if old_tz === nothing
                delete!(ENV, "TZ")
            else
                ENV["TZ"] = old_tz
            end
            ccall(:tzset, Cvoid, ())
        end
    end
end

@testset "go with job_id still runs the user script" begin
    mktempdir() do d
        mark = joinpath(d, "RAN")
        write(joinpath(d, "Project.toml"), "[deps]\n")
        write(joinpath(d, "mark.jl"), "write($(repr(mark)), \"yes\")\n")
        kp = DistSSHRun.execute!(
            :go,
            joinpath(d, "mark.jl"),
            ["parent:1"];
            detached = true,
            yes = true,
            job_id = "queue-slot-include",
            project = d,
            output_dir = joinpath(d, "out"),
        )
        r = wait(kp)
        @test r.ok
        @test isfile(mark)
    end
end

@testset "service unit text is serve" begin
    plist = DistSSHQueue.launch_agent_plist("/opt/bin/julia", "/opt/Queue.jl")
    @test occursin("org.distsshqueue.serve", plist)
    @test occursin("/opt/bin/julia", plist)
    @test occursin("--project=/opt/Queue.jl", plist)
    @test occursin("--startup-file=no", plist)
    @test occursin("<string>-m</string>", plist)
    @test occursin("DistSSHQueue", plist)
    @test occursin("serve", plist)
    @test occursin("<key>RunAtLoad</key>", plist)
    @test occursin("<key>KeepAlive</key>\n    <dict>\n        <key>SuccessfulExit</key>\n        <false/>\n    </dict>", plist)
    @test !occursin("<key>KeepAlive</key>\n    <true/>", plist)
    unit = DistSSHQueue.systemd_user_unit("/usr/bin/julia", "/opt/Queue.jl")
    @test occursin("ExecStart=/usr/bin/julia --startup-file=no --project=/opt/Queue.jl -m DistSSHQueue serve", unit)
    @test DistSSHQueue.m_package("/opt/Queue.jl") == "DistSSHQueue"
    mktempdir() do env::String
        write(
            joinpath(env, "Project.toml"),
            """
            name = "QueueEnv"
            [deps]
            DistSSHKit = "ceec0504-c968-4be5-b215-667cae0e8f81"
            """,
        )
        kit_unit = DistSSHQueue.systemd_user_unit("/usr/bin/julia", env)
        @test occursin("-m DistSSHKit serve", kit_unit)
        expr = DistSSHQueue.fetch_source_expr("abcdabcd")
        @test occursin("Base.active_project()", expr)
        @test occursin("DistSSHKit.DistSSHQueue.fetch_source", expr)
        @test occursin("DistSSHQueue.fetch_source", expr)
        @test !occursin(env, expr)
        hop = DistSSHQueue.remote_main_expr(["status"])
        @test occursin("Base.active_project()", hop)
        @test !occursin(env, hop)
    end
    @test occursin("Restart=on-failure", unit)
    @test occursin("Type=simple", unit)
    @test occursin("WantedBy=default.target", unit)
end

# README / docs paths. Literal strings so Linux Pkg.test still catches a macOS
# path drift (and the reverse). `enable --write-only` then pins the live OS.
@testset "enable unit paths match docs (macOS and Linux)" begin
    @test DistSSHQueue.launch_agent_path(; home = "/Users/lab") ==
        "/Users/lab/Library/LaunchAgents/org.distsshqueue.serve.plist"
    @test DistSSHQueue.systemd_user_path(; home = "/home/lab") ==
        "/home/lab/.config/systemd/user/distsshqueue.serve.service"
    mktempdir() do home
        plist = DistSSHQueue.launch_agent_path(; home)
        unit = DistSSHQueue.systemd_user_path(; home)
        DistSSHQueue.write_serve_unit(plist, DistSSHQueue.launch_agent_plist("/opt/julia", "/opt/env"))
        DistSSHQueue.write_serve_unit(unit, DistSSHQueue.systemd_user_unit("/opt/julia", "/opt/env"))
        @test isfile(joinpath(home, "Library", "LaunchAgents", "org.distsshqueue.serve.plist"))
        @test isfile(joinpath(home, ".config", "systemd", "user", "distsshqueue.serve.service"))
    end
end

@testset "enable --write-only writes the host OS unit under HOME" begin
    Sys.iswindows() && return nothing
    mktempdir() do d
        home = joinpath(d, "home")
        envdir = joinpath(d, "qenv")
        mkpath(home)
        mkpath(envdir)
        write(joinpath(envdir, "Project.toml"), "[deps]\n")
        julia = DistSSHQueue.default_julia_bin()
        mac_unit = joinpath(home, "Library", "LaunchAgents", "org.distsshqueue.serve.plist")
        linux_unit = joinpath(home, ".config", "systemd", "user", "distsshqueue.serve.service")
        withenv("HOME" => home) do
            @test homedir() == home
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["enable", "--write-only", "--queue-env", envdir, "--julia", julia])
            end
            @test code == 0
            want = Sys.isapple() ? mac_unit : linux_unit
            other = Sys.isapple() ? linux_unit : mac_unit
            @test isfile(want)
            @test !isfile(other)
            body = read(want, String)
            jl = DistSSHQueue.canonical_local_path(julia)
            proj = DistSSHQueue.canonical_local_path(envdir)
            @test occursin(jl, body)
            @test occursin("--project=$proj", body)
            @test occursin("DistSSHQueue", body)
            @test occursin("serve", body)
            @test occursin(Sys.isapple() ? "org.distsshqueue.serve.plist" : "distsshqueue.serve.service", out)
            code_en, out_en, _ = capture_stdio() do
                DistSSHQueue.main(["status"])
            end
            @test code_en == 0
            @test occursin("  enable ", out_en)
            @test occursin(basename(want), out_en)
            @test occursin("  serve  ", out_en)
            code2, out2, _ = capture_stdio() do
                DistSSHQueue.main(["disable", "--write-only"])
            end
            @test code2 == 0
            @test !isfile(want)
            @test occursin("Removed", out2)
            @test occursin(basename(want), out2)
            code3, out3, _ = capture_stdio() do
                DistSSHQueue.main(["disable", "--write-only"])
            end
            @test code3 == 0
            @test occursin("Present", out3)
            @test occursin("(unchanged)", out3)
            @test !occursin("--force", out3)
            code_off, out_off, _ = capture_stdio() do
                DistSSHQueue.main(["status"])
            end
            @test code_off == 0
            @test occursin("  enable none", out_off)
        end
    end
end

@testset "queue version skew is a warning, not a refusal" begin
    same = "DistSSHQueue $(pkgversion(DistSSHQueue)) (DistSSHKit 0.8.0)"
    @test DistSSHQueue.queue_version_skew_warning(same) === nothing
    @test DistSSHQueue.queue_version_from_line("noise") === nothing
    msg = DistSSHQueue.queue_version_skew_warning(
        "DistSSHQueue 0.0.1 (DistSSHKit 0.8.1)";
        local_ver = v"0.6.0",
    )
    @test msg !== nothing
    @test occursin("0.0.1", msg.head)
    @test occursin("0.6.0", msg.head)
    @test msg.kit == "0.8.1"
    @test DistSSHQueue.queue_version_skew_warning(
        "DistSSHQueue 0.6.0";
        local_ver = v"0.6.0",
    ) === nothing
    two = DistSSHQueue.queue_version_skew_warning(
        "DistSSHQueue 0.0.1\nDistSSHRun 0.1.5";
        local_ver = v"0.6.0",
    )
    @test two !== nothing
    @test two.kit == "0.1.5"
    @test two.kit_name == "DistSSHRun"
    @test DistSSHQueue.queue_version_skew_warning(
        "DistSSHQueue $(pkgversion(DistSSHQueue))\nDistSSHRun 0.1.5",
    ) === nothing
end

@testset "autoserve reads the enable unit" begin
    plist = DistSSHQueue.serve_command_from_unit(
        DistSSHQueue.launch_agent_plist("/opt/a&b", "/opt/my env"),
    )
    @test plist !== nothing
    @test plist.julia == "/opt/a&b"
    @test plist.project == "/opt/my env"
    unit = DistSSHQueue.serve_command_from_unit(
        DistSSHQueue.systemd_user_unit("/opt/it's julia", "/opt/env"),
    )
    @test unit !== nothing
    @test unit.julia == "/opt/it's julia"
    @test unit.project == "/opt/env"
    @test DistSSHQueue.serve_command_from_unit("ExecStart=/usr/bin/julia serve\n") === nothing
    mktempdir() do home::String
        @test DistSSHQueue.enabled_serve_command(; home = home) === nothing
        if Sys.isapple()
            path = DistSSHQueue.launch_agent_path(; home = home)
            body = DistSSHQueue.launch_agent_plist("/opt/julia", "/opt/env")
        elseif Sys.islinux()
            path = DistSSHQueue.systemd_user_path(; home = home)
            body = DistSSHQueue.systemd_user_unit("/opt/julia", "/opt/env")
        else
            return nothing
        end
        DistSSHQueue.write_serve_unit(path, body)
        spec = DistSSHQueue.enabled_serve_command(; home = home)
        @test spec !== nothing
        @test spec.julia == "/opt/julia"
        @test spec.project == "/opt/env"
    end
    qh = sprint(io -> DistSSHQueue.print_queue_usage(io; topic = "qhost"))
    @test occursin("Would remove, then --confirm-path", qh)
    @test !occursin("Needs -y", qh)
    up = sprint(DistSSHQueue.print_up_usage)
    @test occursin("Decline exits 0", up)
    _, serve_h, _ = capture_stdio() do
        DistSSHQueue.main(["serve", "--help"])
    end
    @test occursin("Must be finite", serve_h)
end

@testset "enable refuses --project; --queue-env is the Queue env" begin
    code, _, err = capture_stdio() do
        DistSSHQueue.main(["enable", "--write-only", "--project", "/opt/Queue.jl"])
    end
    @test code == 1
    @test occursin("--queue-env", err)
    @test occursin("not --project", err)
end

@testset "peel_submit_pool keeps flags and rejects bare pool" begin
    rest, n = DistSSHQueue.peel_submit_pool(["go", "--", "pool:8", "job.jl"])
    @test n === nothing
    @test rest == ["go", "--", "pool:8", "job.jl"]
    rest2, n2 = DistSSHQueue.peel_submit_pool(["go", "--julia", "pool:8", "job.jl"])
    @test n2 === nothing
    @test rest2 == ["go", "--julia", "pool:8", "job.jl"]
    @test_throws ArgumentError DistSSHQueue.peel_submit_pool(["pool", "go", "job.jl"])
end

@testset "peel_status_watch_interval reads interval and tail" begin
    mode, interval, tail = DistSSHQueue.peel_status_watch_interval(
        ["--interval", "1.5", "--tail", "full"]; verb = "watch", default_interval = 0.2,
    )
    @test mode === :run
    @test interval == 1.5
    @test tail === nothing
    _, _, ntail = DistSSHQueue.peel_status_watch_interval(
        ["--tail", "4"]; verb = "status", default_interval = nothing,
    )
    @test ntail == 4
    help, _, _ = DistSSHQueue.peel_status_watch_interval(
        ["-h"]; verb = "watch", default_interval = 0.2,
    )
    @test help === :help
    @test_throws ArgumentError DistSSHQueue.peel_status_watch_interval(
        ["--tail", "0"]; verb = "watch", default_interval = 0.2,
    )
    @test_throws ArgumentError DistSSHQueue.peel_status_watch_interval(
        ["--tail", "nope"]; verb = "status", default_interval = nothing,
    )
    @test_throws ArgumentError DistSSHQueue.peel_status_watch_interval(
        ["--interval"]; verb = "watch", default_interval = 0.2,
    )
    @test_throws ArgumentError DistSSHQueue.parse_cli_interval("watch", "nope")
end

function _submit_source_dict(raw)::AbstractDict
    raw isa AbstractDict || error("source env missing")
    return raw
end

@testset "submit source" begin
    q = DistSSHQueue.Queue(; runner = _ -> nothing)
    id = DistSSHQueue.submit!(
        q, "g.jl", "parent:1";
        source = Dict{String, Any}(
            "commit" => "abc",
            "dirty" => false,
            "diff_sha256" => "e3b0",
            "captured" => "submit:client",
            "untracked" => 0,
        ),
    )
    kw = DistSSHQueue.execute_kwargs(DistSSHQueue.job(q, id))
    if DistSSHRun.execute_detached_accepts(:source; kind = :go)
        @test kw.source["commit"] == "abc"
        @test kw.source["dirty"] == false
    else
        @test !haskey(kw, :source)
    end
    plain = DistSSHQueue.submit!(q, "local.jl", "parent:1")
    @test !haskey(DistSSHQueue.job(q, plain).kwargs, "source")
    withenv(
        "DISTSSHQUEUE_SOURCE_COMMIT" => "abc",
        "DISTSSHQUEUE_SOURCE_DIRTY" => "true",
        "DISTSSHQUEUE_SOURCE_DIFF_SHA256" => "e3b0",
        "DISTSSHQUEUE_SOURCE_CAPTURED" => "submit:client",
        "DISTSSHQUEUE_SOURCE_UNTRACKED" => "2",
    ) do
        built = _submit_source_dict(DistSSHQueue._source_from_queue_env())
        @test built["commit"] == "abc"
        @test built["dirty"] == true
        @test built["diff_sha256"] == "e3b0"
        @test built["captured"] == "submit:client"
        @test built["untracked"] == 2
    end
    withenv("DISTSSHQUEUE_SOURCE_COMMIT" => nothing) do
        @test DistSSHQueue._source_from_queue_env() === nothing
    end
    mktempdir() do tmp
        store = joinpath(tmp, "jobs.toml")
        cfg = joinpath(tmp, "config.toml")
        script = joinpath(tmp, "job.jl")
        write(script, "1\n")
        write(cfg, "store = $(repr(store))\nhosts = [\"parent\"]\n")
        withenv(
            "DISTSSHQUEUE_CONFIG" => cfg,
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
            "DISTSSHQUEUE_SOURCE_COMMIT" => "abc",
            "DISTSSHQUEUE_SOURCE_DIRTY" => "false",
            "DISTSSHQUEUE_SOURCE_DIFF_SHA256" => "e3b0",
            "DISTSSHQUEUE_SOURCE_CAPTURED" => "submit:client",
            "DISTSSHQUEUE_SOURCE_UNTRACKED" => "0",
        ) do
            redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    @test DistSSHQueue.submit_cli(
                        store, :go, script, ["parent:1"], Dict{String, Any}(),
                    ) == 0
                end
            end
            loaded = DistSSHQueue.Queue(; store = store)
            DistSSHQueue.load!(loaded)
            src = _submit_source_dict(only(loaded.jobs).kwargs["source"])
            @test src["commit"] == "abc"
            @test src["dirty"] == false
            @test src["untracked"] == 0
        end
    end
end

function _submit_manifest_tree(dir::AbstractString, kind::Symbol)
    proj = joinpath(dir, "job")
    mkpath(proj)
    if kind === :deps
        write(
            joinpath(proj, "Project.toml"),
            "name = \"Job\"\n[deps]\nExample = \"7876af07-990d-54b4-ab0e-df70d8e5d1c6\"\n",
        )
    elseif kind === :empty_deps
        write(joinpath(proj, "Project.toml"), "name = \"Job\"\n[deps]\n")
    elseif kind === :manifest
        write(
            joinpath(proj, "Project.toml"),
            "name = \"Job\"\n[deps]\nExample = \"7876af07-990d-54b4-ab0e-df70d8e5d1c6\"\n",
        )
        write(joinpath(proj, "Manifest.toml"), "# lock\n")
    end
    store = joinpath(dir, "jobs.toml")
    cfg = joinpath(dir, "config.toml")
    script = joinpath(dir, "job.jl")
    write(script, "1\n")
    write(cfg, "store = $(repr(store))\nhosts = [\"parent\"]\n")
    stdout, stderr, code = mktemp() do _, out_io
        mktemp() do _, err_io
            status = withenv("DISTSSHQUEUE_CONFIG" => cfg, "DISTSSHQUEUE_NO_AUTOSERVE" => "1") do
                redirect_stdout(out_io) do
                    redirect_stderr(err_io) do
                        DistSSHQueue.submit_cli(
                            store, :go, script, ["parent:1"],
                            Dict{String, Any}("project" => proj),
                        )
                    end
                end
            end
            flush(out_io)
            flush(err_io)
            seekstart(out_io)
            seekstart(err_io)
            return read(out_io, String), read(err_io, String), status
        end
    end
    loaded = DistSSHQueue.Queue(; store = store)
    DistSSHQueue.load!(loaded)
    return (; code, stdout, stderr, job = only(loaded.jobs))
end

@testset "submit warns when dependencies have no Manifest" begin
    mktempdir() do dir
        got = _submit_manifest_tree(dir, :deps)
        @test got.code == 0
        lines = split(chomp(got.stdout), '\n'; keepempty = false)
        @test length(lines) == 1
        @test lines[1] == got.job.id
        @test occursin("no Manifest.toml", got.stderr)
        @test occursin("A later minor will refuse", got.stderr)
        @test occursin("Queued", got.stderr)
        warnings = got.job.kwargs["warnings"]
        @test length(warnings) == 1
        @test warnings[1]["kind"] == "manifest_absent"
        @test occursin("no Manifest.toml", warnings[1]["message"])
        @test !haskey(DistSSHQueue.execute_kwargs(got.job), :warnings)
    end
    mktempdir() do dir
        got = _submit_manifest_tree(dir, :manifest)
        @test got.code == 0
        @test !occursin("no Manifest.toml", got.stderr)
        @test !haskey(got.job.kwargs, "warnings")
    end
    mktempdir() do dir
        got = _submit_manifest_tree(dir, :none)
        @test got.code == 0
        @test !occursin("no Manifest.toml", got.stderr)
        @test !haskey(got.job.kwargs, "warnings")
    end
    mktempdir() do dir
        got = _submit_manifest_tree(dir, :empty_deps)
        @test got.code == 0
        @test !occursin("no Manifest.toml", got.stderr)
        @test !haskey(got.job.kwargs, "warnings")
    end
    mktempdir() do dir
        got = withenv("DISTSSHKIT_QUIET" => "1") do
            _submit_manifest_tree(dir, :deps)
        end
        @test got.code == 0
        @test !occursin("no Manifest.toml", got.stderr)
        @test got.job.kwargs["warnings"][1]["kind"] == "manifest_absent"
    end
end
