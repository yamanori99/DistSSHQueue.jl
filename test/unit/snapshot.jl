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
    script = joinpath(proj, "s.jl")
    isfile(script) || write(script, "1\n")
    kw = Dict{String, Any}("project" => String(proj), "remote" => remote)
    return if id === nothing
        DistSSHQueue.Job(; kind = :go, script = script, hosts = hosts, kwargs = kw)
    else
        DistSSHQueue.Job(; id = id, kind = :go, script = script, hosts = hosts, kwargs = kw)
    end
end

struct _SnapProbe
    modes::Vector{Symbol}
    snapshots::Vector{Union{Nothing, String}}
    ship::DistSSHRun.SyncResult
end

function (p::_SnapProbe)(_, mode::Symbol; gitignore::Bool = true, snapshot = nothing)
    _ = gitignore
    push!(p.modes, mode)
    snap = snapshot === nothing ? nothing : String(snapshot)
    push!(p.snapshots, snap)
    mode === :ship_tree && return p.ship
    return (; ok = true)
end

# Live argv on Linux (`/proc`) and macOS (`ps`). `Process.cmd` is always
# included so a finished child or a missing `/proc` still shows `--snapshot`.
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

@testset "ship snapshot is pinned and not the job id" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        j = _snap_job(d)
        probe = _SnapProbe(
            Symbol[], Union{Nothing, String}[], _ok_ship(_SNAP_A),
        )
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            DistSSHQueue._queue_kit_setup!(j, Returns(nothing); kit_setup! = probe)
        end
        @test j.kwargs["snapshot"] == _SNAP_A
        @test j.kwargs["snapshot"] != j.id
        @test j.kwargs["snapshot_hosts"] == ["child:w1:1"]
        @test j.kwargs["snapshot_project"] == DistSSHQueue.canonical_local_path(d)
        @test j.kwargs["snapshot_remote"] == "/deploy/a"
        @test probe.modes == [:remote_root, :ship_tree, :instantiate, :check]
        @test probe.snapshots[1] === nothing
        @test probe.snapshots[2] === nothing
        @test probe.snapshots[3] == _SNAP_A
        @test probe.snapshots[4] == _SNAP_A
        kw = DistSSHQueue.execute_kwargs(j)
        @test kw.snapshot == _SNAP_A
        @test !haskey(kw, :snapshot_hosts)
        @test !haskey(kw, :snapshot_project)
        @test !haskey(kw, :snapshot_remote)
        @test !haskey(kw, :job_id)
        @test kw.snapshot != j.id
    end
end

@testset "parent-only setup does not invent a snapshot" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = joinpath(d, "s.jl"),
            hosts = ["parent:1"],
            kwargs = Dict{String, Any}("project" => String(d)),
        )
        write(j.script, "1\n")
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            DistSSHQueue._queue_kit_setup!(j, Returns(nothing))
        end
        @test !haskey(j.kwargs, "snapshot")
        @test !haskey(DistSSHQueue.execute_kwargs(j), :snapshot)
    end
end

@testset "old jobs without snapshot stay unpinned" begin
    q = Queue(; runner = _ -> nothing)
    id = submit!(q, "old.jl", "parent:1")
    loaded = job(q, id)
    @test !haskey(loaded.kwargs, "snapshot")
    @test !haskey(DistSSHQueue.execute_kwargs(loaded), :snapshot)
end

@testset "jobs do not share snapshot kwargs" begin
    q = Queue(; runner = _ -> nothing)
    a = submit!(q, "a.jl", "parent:1")
    b = submit!(q, "b.jl", "parent:1")
    ja = job(q, a)
    jb = job(q, b)
    @test ja.kwargs !== jb.kwargs
    DistSSHQueue._record_job_snapshot!(q.jobs[1], _SNAP_A, String[], ".", nothing)
    @test q.jobs[1].kwargs["snapshot"] == _SNAP_A
    @test !haskey(q.jobs[2].kwargs, "snapshot")
    @test q.jobs[1].kwargs !== q.jobs[2].kwargs
end

@testset "explicit snapshot without context still reaches execute_kwargs" begin
    q = Queue(; runner = _ -> nothing)
    id = submit!(q, "s.jl", "parent:1"; snapshot = _SNAP_A)
    kw = DistSSHQueue.execute_kwargs(job(q, id))
    @test kw.snapshot == _SNAP_A
    @test !haskey(kw, :snapshot_hosts)
end

@testset "A remains A after B ships" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
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
        @test a.kwargs["snapshot"] == _SNAP_A
        @test b.kwargs["snapshot"] == _SNAP_B
        @test DistSSHQueue.execute_kwargs(a).snapshot == _SNAP_A
        @test DistSSHQueue.execute_kwargs(b).snapshot == _SNAP_B
    end
end

@testset "snapshot survives jobs.toml reload" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        store = joinpath(d, "jobs.toml")
        q = Queue(; store, runner = _ -> nothing)
        id = submit!(q, joinpath(d, "s.jl"), "child:w1:1"; project = String(d), remote = "/deploy/a")
        write(joinpath(d, "s.jl"), "1\n")
        j = job(q, id)
        DistSSHQueue._record_job_snapshot!(j, _SNAP_A, ["child:w1:1"], d, "/deploy/a")
        DistSSHQueue.save_jobs(store, [j])
        loaded = only(DistSSHQueue.load_jobs(store))
        @test loaded.kwargs["snapshot"] == _SNAP_A
        @test loaded.id != _SNAP_A
        @test DistSSHQueue.execute_kwargs(loaded).snapshot == _SNAP_A
        q2 = Queue(; store, runner = _ -> nothing)
        load!(q2)
        @test job(q2, id).kwargs["snapshot"] == _SNAP_A
        @test DistSSHQueue.execute_kwargs(job(q2, id)).snapshot == _SNAP_A
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
        @test occursin("PR 357", err.msg)
        @test !haskey(j.kwargs, "snapshot")
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
        @test !haskey(j.kwargs, "snapshot")
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
        @test !haskey(j2.kwargs, "snapshot")
    end
end

@testset "snapshot context does not move to another host or root" begin
    mktempdir() do d
        write(joinpath(d, "Project.toml"), "[deps]\n")
        j = _snap_job(d; hosts = ["child:w1:1"], remote = "/deploy/a")
        DistSSHQueue._record_job_snapshot!(j, _SNAP_A, ["child:w1:1"], d, "/deploy/a")
        other = _snap_job(d; hosts = ["child:w2:1"], remote = "/deploy/a")
        other.kwargs["snapshot"] = _SNAP_A
        other.kwargs["snapshot_hosts"] = ["child:w1:1"]
        other.kwargs["snapshot_project"] = DistSSHQueue.canonical_local_path(d)
        other.kwargs["snapshot_remote"] = "/deploy/a"
        session = DistSSHQueue._kit_setup_session(other, d; workers = ["child:w2:1"])
        err = try
            DistSSHQueue._assert_snapshot_context!(
                other, d, session, ["child:w2:1"],
            )
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("recorded for hosts", err.msg)
        root = _snap_job(d; hosts = ["child:w1:1"], remote = "/deploy/b")
        root.kwargs["snapshot"] = _SNAP_A
        root.kwargs["snapshot_hosts"] = ["child:w1:1"]
        root.kwargs["snapshot_project"] = DistSSHQueue.canonical_local_path(d)
        root.kwargs["snapshot_remote"] = "/deploy/a"
        session_b = DistSSHQueue._kit_setup_session(root, d; workers = ["child:w1:1"])
        err_root = try
            DistSSHQueue._assert_snapshot_context!(
                root, d, session_b, ["child:w1:1"],
            )
            nothing
        catch e
            e
        end
        @test err_root isa ErrorException
        @test occursin("recorded for remote", err_root.msg)
        err_swap = try
            DistSSHQueue._record_job_snapshot!(j, _SNAP_B, ["child:w1:1"], d, "/deploy/a")
            nothing
        catch e
            e
        end
        @test err_swap isa ErrorException
        @test occursin("already has snapshot", err_swap.msg)
        @test j.kwargs["snapshot"] == _SNAP_A
    end
end

@testset "persisted snapshot reaches detached execute argv" begin
    isdefined(DistSSHRun, :result_remote_run_id) || error(
        "DistSSHRun.result_remote_run_id missing; DistSSHRun PR 357 is required",
    )
    DistSSHRun.execute_detached_accepts(:snapshot; kind = :go) || error(
        "DistSSHRun.execute! detached does not accept snapshot=; DistSSHRun PR 357 is required",
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
                "snapshot" => _SNAP_A,
                "output_dir" => joinpath(d, "out"),
            ),
        )
        DistSSHQueue.save_jobs(store, [j])
        loaded = only(DistSSHQueue.load_jobs(store))
        kw = DistSSHQueue.execute_kwargs(loaded)
        @test kw.snapshot == _SNAP_A
        launched = DistSSHRun.execute!(
            loaded.kind,
            loaded.script,
            loaded.hosts;
            detached = true,
            job_id = loaded.id,
            kw...,
        )
        launched isa DistSSHRun.KitProcess || error("detached execute! did not return KitProcess")
        kp = launched::DistSSHRun.KitProcess
        cmd = _proc_cmdline(kp.process)
        try
            @test occursin("--snapshot", cmd)
            @test occursin(_SNAP_A, cmd)
            @test !occursin("--snapshot $(loaded.id)", cmd)
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
