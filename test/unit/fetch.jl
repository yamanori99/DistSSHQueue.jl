using Test
using DistSSHKit
using DistSSHQueue

function _wait_fetch_state(q, id, want::Symbol; tries::Int=200)
    for _ = 1:tries
        job(q, id).state === want && return nothing
        sleep(0.01)
    end
    error("job $(id) did not reach $(want) (have $(job(q, id).state))")
end

@testset "fetch dest is project .distsshqueue/kind/leaf" begin
    mktempdir() do d
        proj = joinpath(d, "job")
        mkpath(proj)
        dest = DistSSHQueue.fetch_dest(proj, "go", "demo_807e3753")
        @test dest == DistSSHKit.canonical_local_path(
            joinpath(proj, ".distsshqueue", "go", "demo_807e3753"),
        )
        @test DistSSHQueue.path_has_queue_leaf(dest)
    end
    @test_throws ArgumentError DistSSHQueue.fetch_dest("/tmp/job", "out", "custom")
    root = "/qh/.distsshqueue"
    rel = DistSSHQueue.fetch_relpath(root * "/go/demo_807e3753", root)
    @test rel == "go/demo_807e3753"
    @test_throws ArgumentError DistSSHQueue.fetch_relpath("/tmp/other", root)
    stray = "/tmp/output/demo_807e3753"
    @test !DistSSHQueue.path_has_queue_leaf(stray)
    @test_throws ArgumentError DistSSHQueue.require_fetchable_leaf(
        "807e3753-0000-4000-8000-000000000001", stray,
    )
end

@testset "fetch_source exact id and states" begin
    mktempdir() do d
        proj = joinpath(d, "job")
        mkpath(proj)
        script = joinpath(proj, "S.jl")
        write(script, "1\n")
        queued_store = joinpath(d, "queued.toml")
        q = Queue(; store=queued_store, runner=_ -> nothing)
        queued = submit!(q, script, "parent:1"; project=proj)
        @test_throws ArgumentError DistSSHQueue.fetch_source(queued; store=queued_store)
        @test_throws ArgumentError DistSSHQueue.fetch_source("no-such-id"; store=queued_store)

        store = joinpath(d, "jobs.toml")
        hold = Base.Event()
        leaf = Ref{String}()
        q2 = Queue(; store=store, runner=function (_)
            wait(hold)
            return leaf[]
        end)
        running = submit!(q2, script, "parent:1"; project=proj)
        leaf[] = joinpath(d, ".distsshkit", "go", "S_" * first(running, 8))
        mkpath(leaf[])
        @test step!(q2) == 1
        for _ = 1:200
            job(q2, running).state === :running && break
            sleep(0.01)
        end
        @test job(q2, running).state === :running
        notify(hold)
        _wait_fetch_state(q2, running, :done)
        line = DistSSHQueue.fetch_source(running; store=store)
        st, path = DistSSHQueue.parse_fetch_source(line)
        @test st === :done
        @test path == leaf[]
        DistSSHQueue.require_fetchable_leaf(running, path)
        custom = joinpath(proj, "out")
        @test_throws ArgumentError DistSSHQueue.require_fetchable_leaf(running, custom)
        pref = first(running, 8)
        @test DistSSHQueue.fetch_source(pref; store=store) == line
        stray_store = joinpath(d, "stray.toml")
        stray_id = Ref{String}()
        q3 = Queue(; store=stray_store, runner=_ -> "/tmp/go/S_" * first(stray_id[], 8))
        stray_id[] = submit!(q3, script, "parent:1"; project=proj)
        @test step!(q3) == 1
        _wait_fetch_state(q3, stray_id[], :done)
        err = try
            DistSSHQueue.fetch_source(stray_id[]; store=stray_store)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("queue store", sprint(showerror, err))
    end
end

@testset "fetch CLI identity on the queue host" begin
    mktempdir() do d
        proj = joinpath(d, "job")
        mkpath(proj)
        script = joinpath(proj, "S.jl")
        write(script, "1\n")
        store = joinpath(d, "jobs.toml")
        idbox = Ref{String}()
        q = Queue(; store=store, runner=function (_)
            leaf = joinpath(d, ".distsshkit", "go", "S_" * first(idbox[], 8))
            mkpath(leaf)
            write(joinpath(leaf, "kit.result"), "ok\n")
            return leaf
        end)
        id = submit!(q, script, "parent:1"; project=proj)
        idbox[] = id
        @test step!(q) == 1
        _wait_fetch_state(q, id, :done)
        want = DistSSHKit.canonical_local_path(joinpath(d, ".distsshkit", "go", "S_" * first(id, 8)))
        withenv(
            "DISTSSHQUEUE_STORE" => store,
            "DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml"),
            "DISTSSHQUEUE_HOST" => nothing,
            "DISTSSHQUEUE_NO_STAGE" => "1",
            DistSSHQueue.LOCAL_QUEUE_ENV => "1",
            "DISTRIBUTED_PROJECT_ROOT" => proj,
            "DISTSSHKIT_TEST_SSH" => nothing,
        ) do
            code, out, err = capture_stdio() do
                DistSSHQueue.main(["fetch", id])
            end
            @test code == 0
            @test isempty(err) || !occursin("Error:", err)
            @test strip(out) == want
            code_p, out_p, _ = capture_stdio() do
                DistSSHQueue.main(["fetch", first(id, 8)])
            end
            @test code_p == 0
            @test strip(out_p) == want
            code_q, _, err_q = capture_stdio() do
                DistSSHQueue.main(["fetch", "no-such-id"])
            end
            @test code_q == 1
            @test occursin("unknown job", err_q)
            code_r, _, err_r = capture_stdio() do
                DistSSHQueue.main(["qhost:h", "fetch", id])
            end
            @test code_r == 1
            @test occursin("rsync", err_r)
            code_e, _, err_e = capture_stdio() do
                DistSSHQueue.main(["fetch"])
            end
            @test code_e == 1
            @test occursin("need a job id", err_e)
        end
    end
end

@testset "qhost submit ticket is not a Kit leaf" begin
    mktempdir() do d
        proj = joinpath(d, "job")
        mkpath(proj)
        script = joinpath(proj, "S.jl")
        write(script, "1\n")
        id = "96392aaa-4387-5ffe-07ee-8f69406890bb"
        @test DistSSHQueue.job_id_from_submit_stdout("Queued  1\n") === nothing
        @test DistSSHQueue.job_id_from_submit_stdout(id * "\n") == id
        dest = DistSSHQueue.write_submit_ticket(
            proj, id * "\n"; script=script, qhost="mini",
        )
        @test dest == DistSSHQueue.submit_ticket_path(proj, id)
        @test occursin(joinpath(".distsshqueue", "tickets"), dest)
        @test isfile(dest)
        body = read(dest, String)
        @test occursin("id = ", body)
        @test occursin("S.jl", body)
        @test occursin("qhost = \"mini\"", body)
        @test !occursin("/go/", dest)
        @test !occursin("/drive/", dest)
        id2 = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        dest2 = DistSSHQueue.write_submit_ticket(proj, id2 * "\n")
        @test dest2 == DistSSHQueue.submit_ticket_path(proj, id2)
        @test isfile(dest)
        @test isfile(dest2)
        @test length(readdir(DistSSHQueue.submit_ticket_dir(proj))) == 2
        @test DistSSHQueue.write_submit_ticket(proj, "not-an-id\n") === nothing
        @test DistSSHQueue.resolve_fetch_job_id(dest; root=proj) == id
        @test DistSSHQueue.resolve_fetch_job_id(
            joinpath(".distsshqueue", "tickets", id); root=proj,
        ) == id
        @test DistSSHQueue.resolve_fetch_job_id(id; root=proj) == id
        @test DistSSHQueue.resolve_fetch_job_id(first(id, 8); root=proj) == first(id, 8)
    end
end
