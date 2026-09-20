using Test
using DistSSHKit
using DistSSHQueue

function _wait_fetch_state(q, id, want::Symbol; tries::Int = 200)
    for _ in 1:tries
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
    kit_go = "/job/.distsshkit/go/S_20260101T000000Z"
    @test DistSSHQueue.path_has_kit_artifact_leaf(kit_go)
    @test !DistSSHQueue.path_has_queue_leaf(kit_go)
    DistSSHQueue.require_fetchable_leaf("807e3753-0000-4000-8000-000000000001", kit_go)
    runs = "/job/.distsshkit/runs/go/S_20260101T000000Z"
    @test !DistSSHQueue.path_has_kit_artifact_leaf(runs)
    @test_throws ArgumentError DistSSHQueue.require_fetchable_leaf(
        "807e3753-0000-4000-8000-000000000001", runs,
    )
end

@testset "fetch_source exact id and states" begin
    mktempdir() do d
        proj = joinpath(d, "job")
        mkpath(proj)
        script = joinpath(proj, "S.jl")
        write(script, "1\n")
        queued_store = joinpath(d, "queued.toml")
        q = Queue(; store = queued_store, runner = _ -> nothing)
        queued = submit!(q, script, "parent:1"; project = proj)
        @test_throws ArgumentError DistSSHQueue.fetch_source(queued; store = queued_store)
        @test_throws ArgumentError DistSSHQueue.fetch_source("no-such-id"; store = queued_store)

        store = joinpath(d, "jobs.toml")
        hold = Base.Event()
        leaf = Ref{String}()
        q2 = Queue(;
            store = store, runner = function (_)
                wait(hold)
                return leaf[]
            end
        )
        running = submit!(q2, script, "parent:1"; project = proj)
        leaf[] = joinpath(d, ".distsshkit", "go", "S_" * first(running, 8))
        mkpath(leaf[])
        @test step!(q2) == 1
        for _ in 1:200
            job(q2, running).state === :running && break
            sleep(0.01)
        end
        @test job(q2, running).state === :running
        notify(hold)
        _wait_fetch_state(q2, running, :done)
        line = DistSSHQueue.fetch_source(running; store = store)
        st, path, src_id, dest_rel, extras = DistSSHQueue.parse_fetch_source(line)
        @test st === :done
        @test path == leaf[]
        @test src_id == running
        @test dest_rel == "go/S_" * first(running, 8)
        @test extras == String[]
        DistSSHQueue.require_fetchable_leaf(running, path)
        custom = joinpath(proj, "out")
        @test_throws ArgumentError DistSSHQueue.require_fetchable_leaf(running, custom)
        pref = first(running, 8)
        @test DistSSHQueue.fetch_source(pref; store = store) == line
        st2, path2, old_id, dest2, extras2 = DistSSHQueue.parse_fetch_source(
            string(:done, '\t', path),
        )
        @test st2 === :done
        @test path2 == path
        @test old_id === nothing
        @test dest2 === nothing
        @test extras2 == String[]
        stray_store = joinpath(d, "stray.toml")
        stray_id = Ref{String}()
        q3 = Queue(; store = stray_store, runner = _ -> "/tmp/go/S_" * first(stray_id[], 8))
        stray_id[] = submit!(q3, script, "parent:1"; project = proj)
        @test step!(q3) == 1
        _wait_fetch_state(q3, stray_id[], :done)
        err = try
            DistSSHQueue.fetch_source(stray_id[]; store = stray_store)
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
        q = Queue(;
            store = store, runner = function (_)
                leaf = joinpath(d, ".distsshkit", "go", "S_" * first(idbox[], 8))
                mkpath(leaf)
                write(joinpath(leaf, "kit.result"), "ok\n")
                return leaf
            end
        )
        id = submit!(q, script, "parent:1"; project = proj)
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
            code_ep, _, err_ep = capture_stdio() do
                DistSSHQueue.main(["fetch", "--progress"])
            end
            @test code_ep == 1
            @test occursin("need a job id", err_ep)
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
            proj, id * "\n"; script = script, qhost = "mini",
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
        @test DistSSHQueue.resolve_fetch_job_id(dest; root = proj) == id
        @test DistSSHQueue.resolve_fetch_job_id(
            joinpath(".distsshqueue", "tickets", id); root = proj,
        ) == id
        @test DistSSHQueue.resolve_fetch_job_id(id; root = proj) == id
        @test DistSSHQueue.resolve_fetch_job_id(first(id, 8); root = proj) == first(id, 8)
    end
end

@testset "fetch --into dest and marker skip/force" begin
    id = "aaaaaaaa-1111-4000-8000-000000000001"
    id2 = "bbbbbbbb-2222-4000-8000-000000000002"
    src = "/qh/.distsshqueue/drive/demo_aaaaaaaa"
    mktempdir() do d
        dest = joinpath(d, "payoff456")
        @test DistSSHQueue.check_fetch_dest(dest, id) === :copy
        mkpath(dest)
        @test DistSSHQueue.check_fetch_dest(dest, id) === :copy
        DistSSHQueue.write_fetch_marker!(dest, id)
        write(joinpath(dest, "out.tsv"), "1\n")
        @test DistSSHQueue.check_fetch_dest(dest, id) === :skip
        @test DistSSHQueue.check_fetch_dest(dest, first(id, 8)) === :skip
        DistSSHQueue.write_fetch_marker!(dest, first(id, 8))
        @test DistSSHQueue.check_fetch_dest(dest, id) === :skip
        DistSSHQueue.write_fetch_marker!(dest, id)
        @test DistSSHQueue.read_fetch_marker(dest) == id
        as_file = joinpath(d, "not-a-dir")
        write(as_file, "x\n")
        @test_throws ArgumentError DistSSHQueue.check_fetch_dest(as_file, id)
        @test_throws ArgumentError DistSSHQueue.check_fetch_dest(as_file, id; force = true)
        DistSSHQueue.write_fetch_marker!(dest, id)
        @test DistSSHQueue.check_fetch_dest(dest, id; force = true) === :copy
        @test_throws ArgumentError DistSSHQueue.check_fetch_dest(dest, id2)
        DistSSHQueue.write_fetch_marker!(dest, id2)
        @test_throws ArgumentError DistSSHQueue.check_fetch_dest(dest, id)
        other = joinpath(d, "occupied")
        mkpath(other)
        write(joinpath(other, "keep.txt"), "x\n")
        @test_throws ArgumentError DistSSHQueue.check_fetch_dest(other, id)
        @test DistSSHQueue.check_fetch_dest(other, id; force = true) === :copy
        fresh = joinpath(d, "fresh-dest")
        @test DistSSHQueue.fetch_dest_is_fresh(fresh)
        mkpath(fresh)
        @test DistSSHQueue.fetch_dest_is_fresh(fresh)
        @test_throws ErrorException DistSSHQueue.with_fresh_fetch_dest(fresh) do
            write(joinpath(fresh, "partial.tsv"), "1\n")
            error("extra rsync failed")
        end
        @test !ispath(fresh)
        keep = joinpath(d, "keep-dest")
        mkpath(keep)
        write(joinpath(keep, "keep.txt"), "x\n")
        @test !DistSSHQueue.fetch_dest_is_fresh(keep)
        @test_throws ErrorException DistSSHQueue.with_fresh_fetch_dest(keep) do
            write(joinpath(keep, "partial.tsv"), "1\n")
            error("extra rsync failed")
        end
        @test isfile(joinpath(keep, "keep.txt"))
        @test isfile(joinpath(keep, "partial.tsv"))
        rest, into, force, progress = DistSSHQueue.peel_fetch_opts(
            ["--into", dest, "--force", "--progress", id],
        )
        @test rest == [id]
        @test into == dest
        @test force
        @test progress
        withenv("DISTRIBUTED_PROJECT_ROOT" => d) do
            rel = DistSSHQueue.resolve_into_path("data/payoff")
            @test rel == DistSSHKit.canonical_local_path(joinpath(d, "data", "payoff"))
            abs = DistSSHQueue.resolve_into_path(joinpath(d, "outside"))
            @test abs == DistSSHKit.canonical_local_path(joinpath(d, "outside"))
            got = DistSSHQueue.fetch_dest_target(id, src, "/qh/.distsshqueue"; into = joinpath(d, "outside"))
            @test got == DistSSHKit.canonical_local_path(joinpath(d, "outside"))
            @test !startswith(got, DistSSHKit.canonical_local_path(d) * "/.distsshqueue")
        end
    end
end

@testset "fetch extras from run.toml and setup_logs" begin
    mktempdir() do d
        art = joinpath(d, ".distsshkit", "go", "S_aaaaaaaa")
        logf = joinpath(d, ".distsshkit", "runs", "go", "r", "kit.out")
        cold = joinpath(d, "more")
        setup = joinpath(d, ".distsshkit", "setup", "setup.log")
        mkpath(dirname(logf))
        mkpath(cold)
        mkpath(dirname(setup))
        mkpath(art)
        write(logf, "log\n")
        write(joinpath(cold, "x.tsv"), "1\n")
        write(setup, "fail\n")
        j = DistSSHQueue.Job(;
            kind = :go,
            script = "S.jl",
            hosts = ["parent:1"],
            result_path = art,
            kwargs = Dict{String, Any}(
                "run_toml" => Dict{String, Any}(
                    "output_dir" => art,
                    "logs" => [logf],
                    "collect_dirs" => [cold],
                ),
                "setup_logs" => [setup],
            ),
        )
        extras = DistSSHQueue.fetch_extra_paths(j)
        @test logf in extras
        @test cold in extras
        @test setup in extras
        @test art ∉ extras
        specs = DistSSHQueue.fetch_extra_specs(j)
        @test "f:" * logf in specs
        @test "d:" * cold in specs
        @test "f:" * setup in specs
        _, _, hid = DistSSHQueue.fetch_hidden_dest("/dest", "f:" * logf)
        @test endswith(replace(hid, '\\' => '/'), "/.distsshkit/logs/kit.out")
        a = "/run/a/output.log"
        b = "/run/b/output.log"
        hids = DistSSHQueue.fetch_hidden_dests("/dest", ["f:" * a, "f:" * b])
        @test hids[1][2] == a
        @test hids[2][2] == b
        @test endswith(replace(hids[1][3], '\\' => '/'), "/.distsshkit/logs/output.log")
        @test endswith(replace(hids[2][3], '\\' => '/'), "/.distsshkit/logs/b_output.log")
        @test hids[1][3] != hids[2][3]
        case = DistSSHQueue.fetch_hidden_dests(
            "/dest", ["f:/run/a/output.log", "f:/run/c/OUTPUT.LOG"],
        )
        @test lowercase(basename(case[1][3])) != lowercase(basename(case[2][3]))
        @test_throws ArgumentError DistSSHQueue.fetch_hidden_dest("/dest", "d:/run/..")
        @test_throws ArgumentError DistSSHQueue.fetch_hidden_dests("/dest", ["d:/run/.."])
        j.kwargs["run_toml"]["collect_dirs"] = [cold, joinpath(d, "..")]
        extras2 = DistSSHQueue.fetch_extra_paths(j)
        @test cold in extras2
        @test joinpath(d, "..") ∉ extras2
        j.kwargs["run_toml"]["collect_dirs"] = [cold, "/"]
        extras3 = DistSSHQueue.fetch_extra_paths(j)
        @test cold in extras3
        @test "/" ∉ extras3
        st, path, _, dest, got = DistSSHQueue.parse_fetch_source(
            string(:done, '\t', art, '\t', "aaaaaaaa-1111-4000-8000-000000000001", '\t', "go/S_aaaaaaaa", '\t', join(specs, DistSSHQueue.FETCH_EXTRA_SEP)),
        )
        @test st === :done
        @test path == art
        @test dest == "go/S_aaaaaaaa"
        @test got == specs
    end
end
