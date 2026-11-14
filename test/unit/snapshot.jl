using Test
using DistSSHRun
using DistSSHQueue

const _SNAP_A = "20260101T000000Z-aaaaaa"
const _SNAP_B = "20260102T000000Z-bbbbbb"

function _ok_ship(
        run_id::AbstractString = _SNAP_A;
        hosts = DistSSHRun.HostResult[],
    )
    return DistSSHRun.SyncResult(
        true,
        Vector{DistSSHRun.HostResult}(hosts),
        false,
        DistSSHRun.SetupWarning[],
        "0"^40,
        String(run_id),
    )
end

function _snap_job(proj::AbstractString; hosts = ["child:w1:1"], remote = "/deploy/a", id = nothing)
    write_shippable_project!(proj)
    script = joinpath(proj, "s.jl")
    write(script, "1\n")
    kw = Dict{String, Any}("project" => String(proj), "remote" => remote)
    j = if id === nothing
        DistSSHQueue.Job(; kind = :go, script = script, hosts = hosts, kwargs = kw)
    else
        DistSSHQueue.Job(; id = id, kind = :go, script = script, hosts = hosts, kwargs = kw)
    end
    return stamp_enqueue_verify!(j)
end

struct _SnapProbe
    modes::Vector{Symbol}
    run_ids::Vector{Union{Nothing, String}}
    ship::DistSSHRun.SyncResult
end

function (p::_SnapProbe)(_, mode::Symbol; gitignore::Bool = true, run_id = nothing)
    _ = gitignore
    push!(p.modes, mode)
    snap = run_id === nothing ? nothing : String(run_id)
    push!(p.run_ids, snap)
    mode === :ship_tree && return p.ship
    return (; ok = true)
end

# Live argv on Linux (`/proc`) and macOS (`ps`). `Process.cmd` is always
# included so a finished child or a missing `/proc` still shows `--run-id`.
function _proc_cmdline(proc::Base.Process)::String
    parts = String[string(proc.cmd)]
    pid = Int(getpid(proc))
    linux = "/proc/$(pid)/cmdline"
    if isfile(linux)
        push!(parts, replace(String(read(linux)), '\0' => ' '))
    else
        text = try
            strip(
                read(
                    addenv(`ps -ww -o args= -p $(pid)`, "LC_ALL" => "C"),
                    String,
                ),
            )
        catch
            ""
        end
        isempty(text) || push!(parts, text)
    end
    return join(parts, " ")
end

@testset "ship run_id is pinned and not the job id" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        j = _snap_job(d)
        probe = _SnapProbe(
            Symbol[], Union{Nothing, String}[], _ok_ship(_SNAP_A),
        )
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            DistSSHQueue._queue_kit_setup!(j, Returns(nothing); kit_setup! = probe)
        end
        @test j.kwargs["run_id"] == _SNAP_A
        @test j.kwargs["run_id"] != j.id
        @test j.kwargs["ship_hosts"] == ["child:w1:1"]
        @test j.kwargs["ship_project"] == DistSSHQueue.canonical_local_path(d)
        @test j.kwargs["ship_deploy_root"] == "/deploy/a"
        @test probe.modes == [:remote_root, :ship_tree, :instantiate, :check]
        @test probe.run_ids[1] === nothing
        @test probe.run_ids[2] === nothing
        @test probe.run_ids[3] == _SNAP_A
        @test probe.run_ids[4] == _SNAP_A
        kw = DistSSHQueue.execute_kwargs(j)
        @test kw.run_id == _SNAP_A
        @test !haskey(kw, :ship_hosts)
        @test !haskey(kw, :ship_project)
        @test !haskey(kw, :ship_deploy_root)
        @test !haskey(kw, :job_id)
        @test kw.run_id != j.id
    end
end

@testset "parent-only setup does not invent a run_id" begin
    mktempdir() do d
        write_shippable_project!(d)
        j = DistSSHQueue.Job(;
            kind = :go,
            script = joinpath(d, "s.jl"),
            hosts = ["parent:1"],
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        write(j.script, "1\n")
        stamp_enqueue_verify!(j)
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            DistSSHQueue._queue_kit_setup!(j, Returns(nothing))
        end
        @test !haskey(j.kwargs, "run_id")
        @test !haskey(DistSSHQueue.execute_kwargs(j), :run_id)
    end
end

@testset "old jobs without run_id stay unpinned" begin
    with_submit_project() do _, script
        q = Queue(; runner = _ -> nothing)
        id = submit!(q, script, "parent:1")
        loaded = job(q, id)
        @test !haskey(loaded.kwargs, "run_id")
        @test !haskey(DistSSHQueue.execute_kwargs(loaded), :run_id)
    end
end

@testset "jobs do not share run_id kwargs" begin
    with_submit_project() do _, script
        q = Queue(; runner = _ -> nothing)
        a = submit!(q, script, "parent:1")
        b = submit!(q, script, "parent:1")
        ja = job(q, a)
        jb = job(q, b)
        @test ja.kwargs !== jb.kwargs
        DistSSHQueue._record_job_run_id!(q.jobs[1], _SNAP_A, String[], ".", nothing)
        @test q.jobs[1].kwargs["run_id"] == _SNAP_A
        @test !haskey(q.jobs[2].kwargs, "run_id")
        @test q.jobs[1].kwargs !== q.jobs[2].kwargs
    end
end

@testset "explicit run_id without context still reaches execute_kwargs" begin
    with_submit_project() do _, script
        q = Queue(; runner = _ -> nothing)
        id = submit!(q, script, "parent:1"; run_id = _SNAP_A)
        kw = DistSSHQueue.execute_kwargs(job(q, id))
        @test kw.run_id == _SNAP_A
        @test !haskey(kw, :ship_hosts)
    end
end

@testset "A remains A after B ships" begin
    mktempdir() do d
        a = _snap_job(d; remote = "/deploy/a")
        b = _snap_job(d; remote = "/deploy/b")
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            DistSSHQueue._queue_kit_setup!(
                a, Returns(nothing);
                kit_setup! = _SnapProbe(
                    Symbol[], Union{Nothing, String}[], _ok_ship(_SNAP_A),
                ),
            )
            DistSSHQueue._queue_kit_setup!(
                b, Returns(nothing);
                kit_setup! = _SnapProbe(
                    Symbol[], Union{Nothing, String}[], _ok_ship(_SNAP_B),
                ),
            )
        end
        @test a.kwargs["run_id"] == _SNAP_A
        @test b.kwargs["run_id"] == _SNAP_B
        @test DistSSHQueue.execute_kwargs(a).run_id == _SNAP_A
        @test DistSSHQueue.execute_kwargs(b).run_id == _SNAP_B
    end
end

@testset "run_id survives jobs.toml reload" begin
    mktempdir() do d
        write_shippable_project!(d)
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        store = joinpath(d, "jobs.toml")
        q = Queue(; store, runner = _ -> nothing)
        id = submit!(q, script, "child:w1:1"; project = String(d), remote = "/deploy/a")
        j = job(q, id)
        DistSSHQueue._record_job_run_id!(j, _SNAP_A, ["child:w1:1"], d, "/deploy/a")
        DistSSHQueue.save_jobs(store, [j])
        loaded = only(DistSSHQueue.load_jobs(store))
        @test loaded.kwargs["run_id"] == _SNAP_A
        @test loaded.id != _SNAP_A
        @test DistSSHQueue.execute_kwargs(loaded).run_id == _SNAP_A
        q2 = Queue(; store, runner = _ -> nothing)
        load!(q2)
        @test job(q2, id).kwargs["run_id"] == _SNAP_A
        @test DistSSHQueue.execute_kwargs(job(q2, id)).run_id == _SNAP_A
    end
end

@testset "missing ship id does not fall back" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        j = _snap_job(d)
        blank = DistSSHRun.SyncResult(
            true,
            DistSSHRun.HostResult[],
            false,
            DistSSHRun.SetupWarning[],
            "0"^40,
            nothing,
        )
        err = try
            withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
                DistSSHQueue._queue_kit_setup!(
                    j, Returns(nothing);
                    kit_setup! = _SnapProbe(
                        Symbol[], Union{Nothing, String}[], blank,
                    ),
                )
            end
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("result_remote_run_id", err.msg)
        @test occursin("PR 357", err.msg) || occursin("result_remote_run_id", err.msg)
        @test !haskey(j.kwargs, "run_id")
    end
end

@testset "mixed and missing ship hosts are refused" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        j = _snap_job(d; hosts = ["child:w1:1", "child:w2:1"])
        mixed = _ok_ship(
            _SNAP_A;
            hosts = [
                DistSSHRun.HostResult("w1", true, "ok"),
                DistSSHRun.HostResult("w2", false, "down"),
            ],
        )
        err_mixed = try
            withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
                DistSSHQueue._queue_kit_setup!(
                    j, Returns(nothing);
                    kit_setup! = _SnapProbe(
                        Symbol[], Union{Nothing, String}[], mixed,
                    ),
                )
            end
            nothing
        catch e
            e
        end
        @test err_mixed isa ErrorException
        @test occursin("failed on hosts", err_mixed.msg)
        @test occursin("w2", err_mixed.msg)
        @test !haskey(j.kwargs, "run_id")
        missing = _ok_ship(
            _SNAP_A;
            hosts = [DistSSHRun.HostResult("w1", true, "ok")],
        )
        j2 = _snap_job(d; hosts = ["child:w1:1", "child:w2:1"])
        err_missing = try
            withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
                DistSSHQueue._queue_kit_setup!(
                    j2, Returns(nothing);
                    kit_setup! = _SnapProbe(
                        Symbol[], Union{Nothing, String}[], missing,
                    ),
                )
            end
            nothing
        catch e
            e
        end
        @test err_missing isa ErrorException
        @test occursin("does not match", err_missing.msg)
        @test !haskey(j2.kwargs, "run_id")
    end
end

@testset "run_id context does not move to another host or root" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        j = _snap_job(d; hosts = ["child:w1:1"], remote = "/deploy/a")
        DistSSHQueue._record_job_run_id!(j, _SNAP_A, ["child:w1:1"], d, "/deploy/a")
        other = _snap_job(d; hosts = ["child:w2:1"], remote = "/deploy/a")
        other.kwargs["run_id"] = _SNAP_A
        other.kwargs["ship_hosts"] = ["child:w1:1"]
        other.kwargs["ship_project"] = DistSSHQueue.canonical_local_path(d)
        other.kwargs["ship_deploy_root"] = "/deploy/a"
        session = DistSSHQueue._kit_setup_session(other, d; workers = ["child:w2:1"])
        err = try
            DistSSHQueue._assert_run_id_context!(
                other, d, session, ["child:w2:1"],
            )
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("recorded for hosts", err.msg)
        root = _snap_job(d; hosts = ["child:w1:1"], remote = "/deploy/b")
        root.kwargs["run_id"] = _SNAP_A
        root.kwargs["ship_hosts"] = ["child:w1:1"]
        root.kwargs["ship_project"] = DistSSHQueue.canonical_local_path(d)
        root.kwargs["ship_deploy_root"] = "/deploy/a"
        session_b = DistSSHQueue._kit_setup_session(root, d; workers = ["child:w1:1"])
        err_root = try
            DistSSHQueue._assert_run_id_context!(
                root, d, session_b, ["child:w1:1"],
            )
            nothing
        catch e
            e
        end
        @test err_root isa ErrorException
        @test occursin("recorded for remote", err_root.msg)
        err_swap = try
            DistSSHQueue._record_job_run_id!(j, _SNAP_B, ["child:w1:1"], d, "/deploy/a")
            nothing
        catch e
            e
        end
        @test err_swap isa ErrorException
        @test occursin("already has run_id", err_swap.msg)
        @test j.kwargs["run_id"] == _SNAP_A
    end
end

@testset "persisted run_id reaches detached execute argv" begin
    isdefined(DistSSHRun, :result_remote_run_id) || error(
        "DistSSHRun.result_remote_run_id missing; DistSSHRun PR 402 is required",
    )
    DistSSHRun.execute_detached_accepts(:run_id; kind = :go) || error(
        "DistSSHRun.execute! detached does not accept run_id=; DistSSHRun PR 402 is required",
    )
    let d = durable_tmpdir(; prefix = "distsshqueue-snap-")
        copy_registry_distsshrun_project!(d)
        mark = joinpath(d, "RAN")
        write(joinpath(d, "mark.jl"), "write($(repr(mark)), \"yes\")\n")
        store = joinpath(d, "jobs.toml")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = joinpath(d, "mark.jl"),
            hosts = ["parent:1"],
            kwargs = Dict{String, Any}(
                "project" => d,
                "run_id" => _SNAP_A,
                "output_dir" => joinpath(d, "out"),
            ),
        )
        DistSSHQueue.save_jobs(store, [j])
        loaded = only(DistSSHQueue.load_jobs(store))
        kw = DistSSHQueue.execute_kwargs(loaded)
        @test kw.run_id == _SNAP_A
        launched = DistSSHRun.execute!(
            loaded.kind,
            loaded.script,
            loaded.hosts;
            detached = true,
            job_id = loaded.id,
            kw...,
        )
        launched isa DistSSHRun.DetachedProcess || error("detached execute! did not return DetachedProcess")
        kp = launched::DistSSHRun.DetachedProcess
        cmd = _proc_cmdline(kp.process)
        try
            @test occursin("--run-id", cmd)
            @test occursin(_SNAP_A, cmd)
            @test !occursin("--run-id $(loaded.id)", cmd)
            r = wait(kp)
            @test r.ok
            @test isfile(mark)
        catch
            process_running(kp.process) && kill(kp.process)
            try
                wait(kp.process)
            catch
            end
            rethrow()
        end
    end
end
