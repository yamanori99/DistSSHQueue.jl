using Test
using DistSSHKit
using DistSSHQueue

function _wait_state(q, id, st; tries=200)
    for _ in 1:tries
        job(q, id).state === st && return nothing
        sleep(0.01)
    end
    error("job $id stayed $(job(q, id).state), expected $st")
end

@testset "submit! rejects pre-0.4 host tokens" begin
    q = Queue(; runner=_ -> nothing)
    @test_throws ArgumentError submit!(q, "a.jl", "parenthost:2")
    @test_throws ArgumentError submit!(q, "a.jl", "worker:2")
    @test_throws ArgumentError submit!(q, "a.jl", "h1")
    @test_throws ArgumentError submit!(q, "a.jl", "64")
    id = submit!(q, "a.jl", "parent:1", "child:w1:2")
    @test job(q, id).hosts == ["parent:1", "child:w1:2"]
end

@testset "submit! rejects Kit names not on allowed" begin
    q = Queue(; runner=_ -> nothing, allowed=["parent", "child:host1"])
    id = submit!(q, "a.jl", "parent:2", "child:host1:4")
    @test job(q, id).hosts == ["parent:2", "child:host1:4"]
    @test_throws ArgumentError submit!(q, "b.jl", "child:other:1")
    tokened = Queue(; runner=_ -> nothing, allowed=["child:host1"])
    gid = submit!(tokened, "g.jl", "child:host1:4")
    @test job(tokened, gid).hosts == ["child:host1:4"]
    mixed = Queue(; runner=_ -> nothing, allowed=["parent"])
    @test_throws ArgumentError submit!(mixed, "m.jl", "parent:1", "child:other:1")
    @test isempty(jobs(mixed))
    closed = Queue(; runner=_ -> nothing, allowed=String[])
    @test_throws ArgumentError submit!(closed, "c.jl", "parent:1")
    open = Queue(; runner=_ -> nothing)
    @test submit!(open, "d.jl", "child:any:1") isa String
    @test_throws ArgumentError Queue(; allowed=["host1"])
    @test_throws ArgumentError Queue(; allowed=["parent"], follow_config=true)
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
        q = Queue(; runner=_ -> nothing)
        shared = "/tmp/distsshqueue-shared-remote"
        withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => shared) do
            id = submit!(q, joinpath(a, "x.jl"), "parent:1"; project=a)
            @test DistSSHKit.canonical_local_path(String(job(q, id).kwargs["project"])) ==
                  DistSSHKit.canonical_local_path(a)
            @test_throws ArgumentError submit!(q, joinpath(b, "x.jl"), "parent:1"; project=b)
            id2 = submit!(q, joinpath(a, "x.jl"), "parent:1"; project=a)
            @test job(q, id2).state === :queued
        end
        q2 = Queue(; runner=_ -> nothing)
        submit!(q2, joinpath(a, "x.jl"), "parent:1"; project=a, remote="/r/one")
        @test_throws ArgumentError submit!(q2, joinpath(b, "x.jl"), "parent:1"; project=b, remote="/r/one")
        submit!(q2, joinpath(b, "x.jl"), "parent:1"; project=b, remote="/r/two")
        @test DistSSHQueue.kit_worker_root(a, Dict{String,Any}("remote" => "~/jobs/x")) == "~/jobs/x"
        @test DistSSHQueue.kit_worker_root(a, Dict{String,Any}("remote" => "~/jobs/x")) !=
              DistSSHKit.canonical_local_path("~/jobs/x")
        @test DistSSHQueue.kit_worker_root(a, Dict{String,Any}("remote" => "/r/one")) ==
              DistSSHKit.remote_env_project_root("/r/one")
        q3 = Queue(; runner=_ -> nothing)
        submit!(q3, joinpath(a, "x.jl"), "parent:1"; project=a, remote="~/jobs/x")
        submit!(q3, joinpath(b, "x.jl"), "parent:1"; project=b, remote=DistSSHKit.canonical_local_path("~/jobs/x"))
    end
end

@testset "submit! rejects :N above the allowed max" begin
    q = Queue(; runner=_ -> nothing, allowed=["parent:2", "child:host1:4"])
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
            q = Queue(; store=store, runner=_ -> nothing, follow_config=true)
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
    q = Queue(; runner=_ -> wait(ev), allowed=["parent", "child:host1"])
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
    q = Queue(; runner=j -> (push!(started, j.id); sleep(0.05)))
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

@testset "cancel queued; stub running without a script has no output_dir" begin
    q = Queue(; runner=_ -> sleep(0.05))
    a = submit!(q, "a.jl", "parent:2")
    b = submit!(q, "b.jl", "parent:2")
    @test cancel!(q, b)
    @test job(q, b).state === :cancelled
    @test step!(q) == 1
    @test !cancel!(q, a)
    _wait_state(q, a, :done)
end

@testset "cancel running without submit output_dir" begin
    mktempdir() do d
        script = joinpath(d, "hold.jl")
        write(script, "1\n")
        ev = Base.Event()
        q = Queue(; runner=_ -> wait(ev))
        id = submit!(q, script, "parent:1"; project=d)
        @test step!(q) == 1
        j = job(q, id)
        @test j.state === :running
        @test j.result_path !== nothing
        @test isdir(j.result_path)
        @test get(j.kwargs, "output_dir", nothing) == j.result_path
        @test cancel!(q, id)
        @test job(q, id).state === :cancelled
        notify(ev)
        sleep(0.05)
        @test job(q, id).state === :cancelled
    end
end

@testset "load! keeps running without submit output_dir when kit.pid is live" begin
    mktempdir() do d
        script = joinpath(d, "hold.jl")
        write(script, "1\n")
        store = joinpath(d, "jobs.toml")
        ev = Base.Event()
        q = Queue(; store, runner=_ -> wait(ev))
        id = submit!(q, script, "parent:1"; project=d)
        @test step!(q) == 1
        dir = job(q, id).result_path
        @test dir !== nothing
        write(joinpath(dir, "kit.pid"), string(getpid()))
        q2 = Queue(; store, runner=_ -> error("must not re-run"))
        load!(q2)
        loaded = job(q2, id)
        @test loaded.state === :running
        @test DistSSHQueue.kit_child_alive(loaded)
        @test loaded.result_path == dir
        notify(ev)
        _wait_state(q, id, :done)
    end
end

@testset "cancel running via terminate_run! when output_dir is known" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        ev = Base.Event()
        q = Queue(; runner=_ -> wait(ev))
        id = submit!(q, "a.jl", "parent:1"; output_dir=out)
        @test step!(q) == 1
        @test job(q, id).state === :running
        @test cancel!(q, id)
        @test job(q, id).state === :cancelled
        notify(ev)
        sleep(0.05)
        @test job(q, id).state === :cancelled
    end
end

@testset "cancel running overwrites a concurrent :failed finish" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        q = Queue(; runner=_ -> wait(Base.Event()))
        id = submit!(q, "a.jl", "parent:1"; output_dir=out)
        @test step!(q) == 1
        DistSSHQueue._finish!(q, id, :failed, "terminated"; result_path=out)
        DistSSHQueue._finish!(q, id, :cancelled, nothing; result_path=out)
        @test job(q, id).state === :cancelled
    end
end

@testset "cancel running overwrites a concurrent :done finish" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        q = Queue(; runner=_ -> wait(Base.Event()))
        id = submit!(q, "a.jl", "parent:1"; output_dir=out)
        @test step!(q) == 1
        DistSSHQueue._finish!(q, id, :done, nothing; result_path=out)
        DistSSHQueue._finish!(q, id, :cancelled, nothing; result_path=out)
        @test job(q, id).state === :cancelled
    end
end

@testset "reload keeps serve :running over a stale disk snapshot" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        out = joinpath(d, "kit-out")
        mkpath(out)
        q = Queue(; store, runner=_ -> wait(Base.Event()))
        id = submit!(q, "a.jl", "parent:1"; output_dir=out)
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
        q = Queue(; store, runner=_ -> wait(ev))
        id = submit!(q, "a.jl", "parent:1"; output_dir=out)
        @test step!(q) == 1
        @test q.live_id == id
        client = Queue(; store, runner=_ -> error("client must not run"))
        @test cancel!(client, id)
        @test job(client, id).state === :cancelled
        DistSSHQueue._finish!(q, id, :done, nothing; result_path=out)
        @test job(q, id).state === :cancelled
        @test q.live_id === nothing
        @test DistSSHQueue.read_jobs(store)[1].state === :cancelled
        notify(ev)
        sleep(0.05)
        @test job(q, id).state === :cancelled
    end
end

@testset "kit throw does not stall" begin
    q = Queue(; runner=j -> basename(j.script) == "bad.jl" ? error("boom") : nothing)
    a = submit!(q, "bad.jl", "parent:1")
    b = submit!(q, "ok.jl", "parent:1")
    @test step!(q) == 1
    _wait_state(q, a, :failed)
    @test occursin("boom", something(job(q, a).error, ""))
    @test step!(q) == 1
    _wait_state(q, b, :done)
end

@testset "kind=:drive" begin
    q = Queue(; runner=_ -> nothing)
    id = submit!(q, "d.jl", "parent:1"; kind=:drive)
    j = job(q, id)
    @test j.kind === :drive
    @test haskey(j.kwargs, "project")
    @test !haskey(j.kwargs, "path_anchor")
    gid = submit!(q, "g.jl", "parent:1")
    g = job(q, gid)
    @test g.kind === :go
    @test !haskey(g.kwargs, "path_anchor")
    rid = submit!(q, "m.jl", "parent:1"; kind=:ride)
    @test job(q, rid).kind === :ride
end

@testset "kit setup session uses job remote" begin
    mktempdir() do d
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        j = DistSSHQueue.Job(;
            kind=:go,
            script=script,
            hosts=["parent:1"],
            kwargs=Dict{String,Any}("project" => String(d), "remote" => "/custom/root"),
        )
        s = DistSSHQueue._kit_setup_session(j, String(d))
        @test s.remote == "/custom/root"
        j2 = DistSSHQueue.Job(;
            kind=:go,
            script=script,
            hosts=["parent:1"],
            kwargs=Dict{String,Any}("project" => String(d)),
        )
        s2 = DistSSHQueue._kit_setup_session(j2, String(d))
        @test s2.remote === nothing
    end
end

@testset "run_kit skips execute when no longer running" begin
    mktempdir() do d
        script = joinpath(d, "nope.jl")
        write(script, "error(\"must not execute\")\n")
        j = DistSSHQueue.Job(;
            kind=:go,
            script=script,
            hosts=["parent:1"],
            state=:running,
            kwargs=Dict{String,Any}("project" => String(d)),
        )
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => "1") do
            out = DistSSHQueue.run_kit(j, Returns(nothing); still_running=Returns(false))
            @test out == ""
        end
    end
end

@testset "drive leaf is store-dir/kind/stem_id8" begin
    mktempdir() do d
        sdir = joinpath(d, "with_kit")
        mkpath(sdir)
        script = joinpath(sdir, "square_file.jl")
        write(script, """
        using DistSSHKit
        function init_output_dir!(_)
            DistSSHKit.resolve_distributed_output_dir!(ARGS, joinpath(@__DIR__, "output"))
        end
        """)
        q = Queue(; runner=_ -> nothing, store=joinpath(d, "jobs.toml"))
        id = submit!(q, script, "parent:1"; kind=:drive, project=d)
        @test step!(q) == 1
        _wait_state(q, id, :done)
        j = job(q, id)
        p = DistSSHKit.canonical_local_path(something(j.result_path))
        @test occursin(first(id, 8), basename(p))
        @test basename(dirname(p)) == "drive"
        @test dirname(dirname(p)) == DistSSHKit.canonical_local_path(d)
        DistSSHQueue.require_fetchable_leaf(id, p)
        mod = Module()
        Base.include(mod, script)
        got = withenv("DISTRIBUTED_OUTPUT_DIR" => p) do
            @eval mod init_output_dir!(String[])
        end
        @test DistSSHKit.canonical_local_path(got) == p
        write(joinpath(p, "square_results.csv"), "param,result\n")
        @test isfile(joinpath(p, "square_results.csv"))
        @test !isdir(joinpath(sdir, "output"))
    end
end

@testset "kit.pid keeps a live detached child across load" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        write(joinpath(out, "kit.pid"), string(getpid()))
        p = joinpath(d, "jobs.toml")
        j = DistSSHQueue.Job(;
            kind=:go,
            script="/tmp/job.jl",
            hosts=["parent:1"],
            state=:running,
            result_path=out,
        )
        DistSSHQueue.save_jobs(p, [j])
        q = Queue(; store=p, runner=_ -> error("must not re-run"))
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
        st = DistSSHKit.kit_process_start_key(getpid())
        body = st === nothing ? string(getpid(), '\n') : string(getpid(), '\n', st, '\n')
        write(joinpath(out, "kit.pid"), body)
        j = DistSSHQueue.Job(;
            kind=:go,
            script="/tmp/job.jl",
            hosts=["parent:1"],
            state=:running,
            result_path=out,
        )
        @test DistSSHQueue.kit_child_alive(j)
        @test DistSSHKit.kit_pid_file_running(out)
    end
end

@testset "kit.result settles a finished running row on load" begin
    mktempdir() do d
        out = joinpath(d, "kit-out")
        mkpath(out)
        DistSSHKit._write_kit_result_file(DistSSHKit.KitRunResult(
            true, :go, out, nothing, nothing, 0,
        ))
        p = joinpath(d, "jobs.toml")
        j = DistSSHQueue.Job(;
            kind=:go,
            script="/tmp/job.jl",
            hosts=["parent:1"],
            state=:running,
            result_path=out,
        )
        DistSSHQueue.save_jobs(p, [j])
        q = Queue(; store=p, runner=_ -> error("must not re-run"))
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
        DistSSHKit._write_kit_result_file(DistSSHKit.KitRunResult(
            true, :drive, out, nothing, nothing, 0,
        ))
        p = joinpath(d, "jobs.toml")
        j = DistSSHQueue.Job(;
            kind=:drive,
            script="/tmp/job.jl",
            hosts=["parent:2", "child:mini-alpha:2"],
            state=:running,
            result_path=out,
        )
        DistSSHQueue.save_jobs(p, [j])
        q = Queue(; store=p, runner=_ -> error("must not re-run"))
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
        q = Queue(; store=p, runner=_ -> wait(ev))
        id = submit!(q, "a.jl", "parent:1")
        @test step!(q) == 1
        @test job(q, id).state === :running
        q2 = Queue(; store=p, runner=_ -> nothing)
        load!(q2)
        notify(ev)
        _wait_state(q, id, :done)
        @test job(q2, id).state === :failed
        @test occursin("serve restarted", something(job(q2, id).error, ""))
    end
end

@testset "kit ok=false is failed" begin
    @test_throws ErrorException DistSSHQueue.require_kit_ok((ok=false, kind=:go))
    detailed = try
        DistSSHQueue.require_kit_ok((ok=false, kind=:drive, failed_step="drive", exit_code=42))
    catch e
        e
    end
    @test detailed isa ErrorException
    @test occursin("drive", detailed.msg)
    @test occursin("exit 42", detailed.msg)
    @test DistSSHQueue.require_kit_ok((ok=true, kind=:go, output_dir="/tmp/out")) === nothing
    @test DistSSHQueue.kit_result_path((ok=true, output_dir="/tmp/out")) == "/tmp/out"
    q = Queue(; runner=_ -> error("DistSSHKit go failed (ok=false)"))
    id = submit!(q, "a.jl", "parent:1")
    @test step!(q) == 1
    _wait_state(q, id, :failed)
end

@testset "execute_kwargs drops names execute! detached rejects" begin
    q = Queue(; runner=_ -> nothing)
    gid = submit!(q, "g.jl", "parent:1"; path_anchor="/x", yes=false, log_dir="/logs", quiet=true)
    gkw = DistSSHQueue.execute_kwargs(job(q, gid))
    @test gkw.yes === true
    @test gkw.quiet === true
    @test !haskey(gkw, :path_anchor)
    @test !haskey(gkw, :job_id)
    @test !haskey(gkw, :log_dir)
    did = submit!(q, "d.jl", "parent:1"; kind=:drive, log_dir="/logs", skip_hash_check=false)
    dkw = DistSSHQueue.execute_kwargs(job(q, did))
    @test dkw.log_dir == "/logs"
    @test dkw.skip_hash_check === false
    @test dkw.yes === true
    wid = submit!(q, "w.jl", "child:h1:1"; kind=:drive, workers=4, mem_headroom=0.5)
    wkw = DistSSHQueue.execute_kwargs(job(q, wid))
    @test wkw.workers == 4
    @test wkw.mem_headroom == 0.5
    @test !haskey(DistSSHQueue.execute_kwargs(job(q, gid)), :workers)
    rid = submit!(q, "r.jl", "parent:1"; kind=:go, repeat=8)
    @test DistSSHQueue.execute_kwargs(job(q, rid)).repeat == 8
    didr = submit!(q, "rd.jl", "parent:1"; kind=:drive, repeat=8)
    @test !haskey(DistSSHQueue.execute_kwargs(job(q, didr)), :repeat)
    ride = submit!(q, "m.jl", "parent:2"; kind=:ride, spi_check=false, repeat=8)
    rkw = DistSSHQueue.execute_kwargs(job(q, ride))
    @test rkw.spi_check === false
    @test !haskey(rkw, :repeat)
    @test_throws ArgumentError submit!(q, "x.jl", "parent:1"; kind=:pipeline)
end

@testset "result_path from runner and kwargs" begin
    q = Queue(; runner=_ -> "/tmp/kit-out")
    id = submit!(q, "a.jl", "parent:1"; output_dir="/tmp/unused")
    @test step!(q) == 1
    _wait_state(q, id, :done)
    @test job(q, id).result_path == "/tmp/kit-out"

    q2 = Queue(; runner=_ -> nothing)
    id2 = submit!(q2, "b.jl", "parent:1"; output_dir="/tmp/bag")
    @test step!(q2) == 1
    _wait_state(q2, id2, :done)
    @test job(q2, id2).result_path == "/tmp/bag"
end

@testset "client cancel reloads store" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        q = Queue(; store=p, runner=_ -> sleep(0.05))
        a = submit!(q, "a.jl", "parent:1")
        b = submit!(q, "b.jl", "parent:1")
        @test step!(q) == 1
        other = Queue(; store=p)
        @test cancel!(other, b)
        @test !cancel!(other, a)
        @test job(other, b).state === :cancelled
        _wait_state(q, a, :done)
        @test step!(q) == 0
    end
end

@testset "client enqueue keeps running row" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        ev = Base.Event()
        q = Queue(; store=p, runner=_ -> wait(ev))
        a = submit!(q, "a.jl", "parent:1")
        @test step!(q) == 1
        q2 = Queue(; store=p, runner=_ -> nothing)
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
                proj = DistSSHKit.canonical_local_path(pwd())
                help = sprint(DistSSHQueue.print_queue_usage)
                @test occursin("Usage", help)
                @test occursin("Examples", help)
                @test occursin("qhost:HOST", help)
                @test occursin("list-host", help)
                @test occursin("  size ", help)
                @test occursin("add-host", help)
                @test occursin("remove-host", help)
                @test occursin("watch", help)
                @test occursin("status [-q] [--tail N|full]  Snapshot; --interval is live", help)
                @test occursin("watch [-q] [--tail N|full]    Same as status --interval", help)
                @test occursin("enable", help)
                @test occursin("disable", help)
                @test occursin("fetch <id>", help)
                @test occursin("size", help)
                @test occursin("plan", help)
                @test occursin("pool", help)
                @test occursin("ride", help)
                @test occursin("julia -m DistSSHQueue <command> -h", help)
                @test !occursin("Notes", help)
                @test !occursin("[--size]", help)
                @test !occursin("qhost:HOST add-host", help)
                @test !occursin("IdentityFile", help)
                @test !occursin("sleeping laptop", help)
                @test !occursin("service install", help)
                code_h, out_h, _ = capture_stdio() do
                    DistSSHQueue.main(["-h"])
                end
                @test code_h == 0
                @test occursin("Usage", out_h)
                qv = string(pkgversion(DistSSHQueue))
                kv = string(DistSSHKit.dist_ssh_kit_version())
                for flag in ("--version", "-v", "-V")
                    code_v, out_v, _ = capture_stdio() do
                        DistSSHQueue.main([flag])
                    end
                    @test code_v == 0
                    lines = split(strip(out_v), '\n')
                    @test length(lines) >= 2
                    @test lines[1] == "DistSSHQueue $(qv)"
                    @test lines[2] == "DistSSHKit $(kv)"
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
                @test occursin("local ($(gethostname()))", out_st)
                @test occursin("  path   none", out_st)
                @test occursin("(none)", out_st)
                @test !occursin("(empty)", out_st)
                empty = sprint(io -> DistSSHQueue.show_status(p; io=io))
                @test occursin("Store", empty)
                @test occursin("(none)", empty)
                @test !occursin("(empty)", empty)
                via_out = sprint(io -> DistSSHQueue.show_status(p; io=io, qhost="qbox"))
                @test occursin("qbox ($(gethostname()))", via_out)
                @test DistSSHQueue._qhost_disp(gethostname()) == gethostname()
                env_out = withenv(DistSSHQueue.QHOST_DISPLAY_ENV => "from-env") do
                    sprint(io -> DistSSHQueue.show_status(p; io=io))
                end
                @test occursin("from-env ($(gethostname()))", env_out)
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
                code_go, out_go, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "child:host1:4", "job.jl"])
                end
                @test code_go == 0
                rows = DistSSHQueue.read_jobs(p)
                @test length(rows) == 1
                @test strip(out_go) == rows[1].id
                @test rows[1].kind === :go
                @test rows[1].script == DistSSHKit.canonical_local_path(joinpath(pwd(), "job.jl"))
                @test rows[1].hosts == ["child:host1:4"]
                @test rows[1].state === :queued
                @test rows[1].kwargs["project"] == proj
                listed = sprint(io -> DistSSHQueue.show_status(p; io=io))
                @test occursin(first(rows[1].id, 8), listed)
                @test !occursin(rows[1].id, listed)
                @test occursin("queued", listed)
                @test occursin("STATE", listed)
                code_alias, _, _ = capture_stdio() do
                    DistSSHQueue.main(["go", "parent:1", "alias.jl"])
                end
                @test code_alias == 0
                code_drv, _, _ = capture_stdio() do
                    DistSSHQueue.main(["submit", "drive", "parent:2", "drv.jl"])
                end
                @test code_drv == 0
                rows = DistSSHQueue.read_jobs(p)
                @test length(rows) == 3
                @test rows[2].kind === :go
                @test rows[2].script == DistSSHKit.canonical_local_path(joinpath(pwd(), "alias.jl"))
                @test rows[3].kind === :drive
                @test rows[3].script == DistSSHKit.canonical_local_path(joinpath(pwd(), "drv.jl"))
                @test rows[3].hosts == ["parent:2"]
                @test rows[3].kwargs["project"] == proj
                code_ride, _, _ = capture_stdio() do
                    DistSSHQueue.main(["ride", "--no-spi-check", "parent:1", "map.jl"])
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
                want = DistSSHKit.host_tokens(
                    DistSSHKit.parse_drive_args(["--workers", "4", "child:host1:1", "drv.jl"]);
                    kind=:drive,
                )
                @test rows[end].hosts == want
                @test rows[end].kwargs["workers"] == 4
                n_hosts = length(rows)
                code_bare, _, err_bare = capture_stdio() do
                    DistSSHQueue.main(["submit", "drive", "--workers", "4", "child:host1", "drv.jl"])
                end
                if pkgversion(DistSSHKit) >= v"0.7"
                    @test code_bare == 1
                    @test occursin("needs :N", err_bare)
                    @test length(DistSSHQueue.read_jobs(p)) == n_hosts
                end
                code_hf, _, _ = capture_stdio() do
                    DistSSHQueue.main(["go", "--hosts", "child:w:2", "job.jl"])
                end
                @test code_hf == 0
                rows = DistSSHQueue.read_jobs(p)
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
                cid = rows[2].id
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
                @test occursin("queue: local", err_ok)
                @test !occursin("Queued", out_ok)
                id1 = strip(out_ok)
                @test !isempty(id1)
                code2, out2, err2 = capture_stdio() do
                    DistSSHQueue.main(["submit", "go", "parent:1", "job.jl"])
                end
                @test code2 == 0
                @test occursin(r"Queued\s+2\b", err2)
                @test strip(out2) != id1
                withenv("DISTSSHKIT_QUIET" => "1") do
                    code_q, out_q, err_q = capture_stdio() do
                        DistSSHQueue.main(["submit", "go", "parent:1", "job.jl"])
                    end
                    @test code_q == 0
                    @test !occursin("Queued", err_q)
                    @test !occursin("queue: local", err_q)
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

@testset "CLI add-host applies while serve is running" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        cfg = joinpath(d, "config.toml")
        write(cfg, "store = $(repr(p))\nhosts = [\"parent\"]\n")
        jobdir = mktempdir()
        write(joinpath(jobdir, "Project.toml"), "[deps]\n")
        write(joinpath(jobdir, "job.jl"), "1\n")
        q = Queue(; store=p, runner=_ -> nothing)
        withenv(
            "DISTSSHQUEUE_STORE" => p,
            "DISTSSHQUEUE_CONFIG" => cfg,
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
        ) do
            cd(jobdir) do
                capture_stdio() do
                    t = @async DistSSHQueue.serve!(q; interval=0.02)
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
                    schedule(t, InterruptException(); error=true)
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
exit 0
""",
        )
        chmod(joinpath(fake, "ssh"), 0o755)
        path = fake * ":" * get(ENV, "PATH", "")
        write(cfg, "hosts = [\"parent\", \"child:host1\"]\n")
        withenv("DISTSSHQUEUE_CONFIG" => cfg, "PATH" => path) do
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["list-host"])
            end
            @test code == 0
            @test occursin("parent", out)
            @test occursin("child:host1", out)
            @test occursin(gethostname(), out)
            @test occursin("this machine", out)
            @test !occursin("queue host", out)
            @test occursin("HostName 10.0.0.8", out)
            @test occursin("User lab", out)
            @test occursin("Port 2222", out)
            @test !occursin("identityfile", lowercase(out))
            @test !occursin("id_rsa", out)
            @test occursin("MAX", out)
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
            @test occursin(gethostname(), out)
            @test occursin("parent", out)
        end
        write(cfg, "store = \"x\"\n")
        withenv("DISTSSHQUEUE_CONFIG" => cfg, "PATH" => path) do
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["list-host"])
            end
            @test code == 0
            @test occursin("any Kit name", out)
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
        write(cfg, DistSSHQueue.default_config_body(; store=joinpath(d, "jobs.toml")))
        withenv("DISTSSHQUEUE_CONFIG" => cfg, "PATH" => path) do
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["add-host", "parent", "child:host1"])
            end
            @test code == 0
            @test occursin("child:host1", out)
            @test DistSSHQueue.config_host_names(DistSSHQueue.load_config()) ==
                  DistSSHQueue.HostAllow("parent" => nothing, "host1" => nothing)
            code2, out2, _ = capture_stdio() do
                DistSSHQueue.main(["remove-host", "parent"])
            end
            @test code2 == 0
            @test occursin("host1", out2)
            @test DistSSHQueue.config_host_names(DistSSHQueue.load_config()) ==
                  DistSSHQueue.HostAllow("host1" => nothing)
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
    @test occursin("DistSSHKit size", out)
    @test occursin("Queue", out)
    @test occursin("qhost:HOST", out)
    @test occursin("Does not enqueue", out)
end

@testset "plan inspects a script and does not enqueue" begin
    code, out, _ = capture_stdio() do
        DistSSHQueue.main(["plan", "-h"])
    end
    @test code == 0
    @test occursin("DistSSHKit plan", out)
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
            @test occursin("DistSSHKit pool", out)
            @test occursin("Queue", out)
            @test occursin("Does not enqueue", out)
            @test !isfile(p)
        end
    end
end

@testset "inspect CLI chrome" begin
    _, out, _ = capture_stdio() do
        DistSSHQueue.print_inspect_submit_template("drive", String["parent:2", "child:host1:4"])
    end
    @test occursin("Suggested submit (template):", out)
    @test occursin("submit drive parent:2 child:host1:4 SCRIPT.jl", out)

    line = DistSSHQueue.pool_sizing_assumption_line(;
        gb_per_worker=nothing,
        mem_headroom=DistSSHKit.DEFAULT_MEM_HEADROOM,
        parent_gb=DistSSHKit.DEFAULT_PARENT_GB,
    )
    @test occursin("1.5 GB/worker", line)
    @test occursin("no RSS; use size to measure", line)

    _, notes, _ = capture_stdio() do
        DistSSHQueue.print_pool_inventory_notes!(;
            gb_per_worker=2.0,
            mem_headroom=0.75,
            parent_gb=0.4,
        )
    end
    @test occursin("2.0 GB/worker", notes)
    @test occursin("parent is this queue host", notes)
    @test occursin("not free queue capacity", notes)
end

@testset "pool submit template respects Queue host caps" begin
    pool = DistSSHKit.ResourcePool(
        true,
        [
            DistSSHKit.HostInventory(DistSSHKit.PARENT_HOST_NAME, true, 8, 64.0, 8, ""),
            DistSSHKit.HostInventory("host1", true, 8, 64.0, 8, ""),
        ],
        16,
        128.0,
        16,
    )
    allow = DistSSHQueue.HostAllow("parent" => 2, "host1" => 4)
    _, out, _ = capture_stdio() do
        DistSSHQueue.print_queue_pool_submit(pool, allow)
    end
    @test occursin("Suggested submit (template):", out)
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
        withenv(
            "DISTSSHQUEUE_STORE" => p,
            "DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml"),
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
                frame = sprint(io -> DistSSHQueue.print_watch_frame(p, DistSSHQueue.Job[]; io=io))
                @test occursin("Store", frame)
                @test occursin("serve", frame)
                @test occursin("Ctrl-C stops watch", frame)
                @test !occursin("Process", frame)
            end
        end
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
        miss = sprint(io -> DistSSHQueue.show_status(p; io=io))
        @test occursin("  path   none", miss)
        @test occursin("(none)", miss)
        @test !occursin("(empty)", miss)
        DistSSHQueue.save_jobs(p, DistSSHQueue.Job[])
        z = sprint(io -> DistSSHQueue.show_status(p; io=io))
        @test occursin("(empty)", z)
        @test !occursin("  path   none", z)
        @test occursin("path", z)
        hop = sprint(io -> DistSSHQueue.show_status(p; io=io, qhost="qbox"))
        @test occursin("qbox:", hop)
        @test occursin("qbox ($(gethostname()))", hop)
        hopnone = sprint(io -> DistSSHQueue.show_status(joinpath(d, "gone.toml"); io=io, qhost="qbox"))
        @test occursin("  path   none", hopnone)
        @test !occursin("qbox:none", hopnone)
        q = sprint(io -> DistSSHQueue.show_status(p; io=io, quiet=true))
        @test occursin("(empty)", q)
        @test !occursin("Store", q)
        mq = sprint(io -> DistSSHQueue.show_status(joinpath(d, "gone.toml"); io=io, quiet=true))
        @test occursin("(none)", mq)
        @test !occursin("(empty)", mq)
        @test !occursin("Store", mq)
    end
end

@testset "status table shows the error line for failed jobs" begin
    mktempdir() do d
        p = joinpath(d, "jobs.toml")
        q = Queue(; store=p, runner=_ -> error("boom: kaboom"))
        id = submit!(q, "a.jl", "parent:1")
        @test step!(q) == 1
        _wait_state(q, id, :failed)
        listed = sprint(io -> DistSSHQueue.show_status(p; io=io))
        @test occursin("error", listed)
        @test occursin("boom: kaboom", listed)
    end
end

@testset "serve live line" begin
    @test DistSSHQueue._serve_live_text('⠋', nothing) == "  ⠋  idle"
    mktempdir() do d
        script = joinpath(d, "demos", "pi_echo.jl")
        mkpath(dirname(script))
        write(script, "1\n")
        j = DistSSHQueue.Job(;
            kind=:go,
            script=script,
            hosts=["parent:1"],
            state=:running,
            kwargs=Dict{String,Any}("project" => d),
        )
        ids = [j.id]
        t = DistSSHQueue._serve_live_text('⠙', j, ids)
        @test startswith(t, "  ⠙  running  $(first(j.id, 8))  go")
        @test !occursin(j.id, t)
        @test occursin("demos/pi_echo.jl", t) || occursin(joinpath("demos", "pi_echo.jl"), t)
        @test !occursin(d, t)
        narrow = DistSSHQueue._serve_live_text('⠙', j, ids; cols=20)
        @test textwidth(narrow) <= 20
        @test endswith(narrow, "…")
    end
    buf = IOBuffer()
    DistSSHQueue.print_serve_banner(1, "/tmp/jobs.toml"; io=buf)
    s = String(take!(buf))
    @test occursin("pid 1", s)
    @test occursin("store", s)
    @test !occursin("Process", s)
    buf2 = IOBuffer()
    DistSSHQueue.print_serve_idle_note(; io=buf2)
    note = String(take!(buf2))
    @test occursin("Ctrl-C stops serve", note)
    @test occursin("DistSSHKit job already running is not killed", note)
end

@testset "job id prefix and status paths relative to project" begin
    mktempdir() do d
        stage = joinpath(d, ".distsshqueue", "stage", "1f7276b9bbc65609")
        mkpath(joinpath(stage, "demos"))
        script = joinpath(stage, "demos", "pi_echo.jl")
        write(script, "1\n")
        leaf = joinpath(stage, "demos", ".distsshkit", "go", "pi_echo_x_aaaaaaaa-1111-4000-8000-000000000001")
        a = DistSSHQueue.Job(;
            id="aaaaaaaa-1111-4000-8000-000000000001",
            kind=:go,
            script=script,
            hosts=["parent:1"],
            state=:done,
            result_path=leaf,
            kwargs=Dict{String,Any}("project" => stage),
        )
        b = DistSSHQueue.Job(;
            id="aaaaaaaa-2222-4000-8000-000000000002",
            kind=:go,
            script=script,
            hosts=["parent:1"],
            state=:queued,
            kwargs=Dict{String,Any}("project" => stage),
        )
        q = DistSSHQueue.Queue()
        push!(q.jobs, a, b)
        @test job(q, a.id).id == a.id
        @test job(q, "aaaaaaaa-1111").id == a.id
        @test_throws ArgumentError job(q, "aaaaaaaa")
        @test_throws ArgumentError job(q, "nope")
        p = joinpath(d, "jobs.toml")
        DistSSHQueue.save_jobs(p, [a, b])
        listed = sprint(io -> DistSSHQueue.show_status(p; io=io))
        @test occursin("aaaaaaaa-1", listed)
        @test occursin("aaaaaaaa-2", listed)
        @test occursin("pi_echo_x_aaaaaaaa-1111-4000-8000-000000000001", listed)
        @test occursin(joinpath("demos", "pi_echo.jl"), listed) || occursin("demos/pi_echo.jl", listed)
        @test !occursin(stage * "/", listed)
        @test occursin(DistSSHKit.short_path(stage), listed)
    end
end

@testset "go with job_id still runs the user script" begin
    mktempdir() do d
        mark = joinpath(d, "RAN")
        write(joinpath(d, "Project.toml"), "[deps]\n")
        write(joinpath(d, "mark.jl"), "write($(repr(mark)), \"yes\")\n")
        kp = DistSSHKit.execute!(
            :go,
            joinpath(d, "mark.jl"),
            ["parent:1"];
            detached=true,
            yes=true,
            job_id="queue-slot-include",
            project=d,
            output_dir=joinpath(d, "out"),
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
    @test occursin("<key>KeepAlive</key>", plist)
    unit = DistSSHQueue.systemd_user_unit("/usr/bin/julia", "/opt/Queue.jl")
    @test occursin("ExecStart=/usr/bin/julia --startup-file=no --project=/opt/Queue.jl -m DistSSHQueue serve", unit)
    @test occursin("Restart=on-failure", unit)
    @test occursin("Type=simple", unit)
    @test occursin("WantedBy=default.target", unit)
end

# README / docs paths. Literal strings so Linux Pkg.test still catches a macOS
# path drift (and the reverse). `enable --write-only` then pins the live OS.
@testset "enable unit paths match docs (macOS and Linux)" begin
    @test DistSSHQueue.launch_agent_path(; home="/Users/lab") ==
        "/Users/lab/Library/LaunchAgents/org.distsshqueue.serve.plist"
    @test DistSSHQueue.systemd_user_path(; home="/home/lab") ==
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
            jl = DistSSHKit.canonical_local_path(julia)
            proj = DistSSHKit.canonical_local_path(envdir)
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

@testset "enable refuses --project; --queue-env is the Queue env" begin
    code, _, err = capture_stdio() do
        DistSSHQueue.main(["enable", "--write-only", "--project", "/opt/Queue.jl"])
    end
    @test code == 1
    @test occursin("--queue-env", err)
    @test occursin("not --project", err)
end
