using Test
using DistSSHRun
using DistSSHQueue

@testset "config path and store resolution" begin
    mktempdir() do d
        cfg = joinpath(d, "config.toml")
        store_cfg = joinpath(d, "from_config.toml")
        store_env = joinpath(d, "from_env.toml")
        write(cfg, "store = $(repr(store_cfg))\n\n[env]\nDISTSSHQUEUE_TEST_FROM_CFG = \"cfg\"\nDISTSSHQUEUE_TEST_KEEP = \"cfg\"\n")
        withenv(
            "DISTSSHQUEUE_CONFIG" => cfg,
            "DISTSSHQUEUE_STORE" => nothing,
            "DISTSSHQUEUE_TEST_FROM_CFG" => nothing,
            "DISTSSHQUEUE_TEST_KEEP" => "env",
        ) do
            @test DistSSHQueue.config_path() == cfg
            loaded = DistSSHQueue.load_config()
            @test DistSSHQueue.config_store_path(loaded) == store_cfg
            @test DistSSHQueue.store_path() == store_cfg
            DistSSHQueue.apply_config_env!(loaded)
            @test ENV["DISTSSHQUEUE_TEST_FROM_CFG"] == "cfg"
            @test ENV["DISTSSHQUEUE_TEST_KEEP"] == "env"
        end
        withenv("DISTSSHQUEUE_CONFIG" => cfg, "DISTSSHQUEUE_STORE" => store_env) do
            @test DistSSHQueue.store_path() == store_env
        end
        missing = joinpath(d, "nope.toml")
        withenv("DISTSSHQUEUE_CONFIG" => missing, "DISTSSHQUEUE_STORE" => nothing) do
            @test DistSSHQueue.load_config() == Dict{String, Any}()
            @test DistSSHQueue.store_path() == DistSSHQueue.default_store_path()
        end
        pop!(ENV, "DISTSSHQUEUE_TEST_FROM_CFG", nothing)
        pop!(ENV, "DISTSSHQUEUE_TEST_KEEP", nothing)
    end
end

@testset "with_store_lock retries EEXIST races" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        n = Threads.Atomic{Int}(0)
        tasks = [
            @async begin
                for _ in 1:40
                    DistSSHQueue.with_store_lock(store) do
                        Threads.atomic_add!(n, 1)
                        sleep(0.001)
                    end
                end
            end for _ in 1:4
        ]
        foreach(wait, tasks)
        @test n[] == 160
    end
end

@testset "serve pidfile" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        @test !DistSSHQueue.serve_alive(store)
        DistSSHQueue.write_pid_file(store)
        @test DistSSHQueue.serve_alive(store)
        DistSSHQueue.remove_pid_file(store)
        @test !DistSSHQueue.serve_alive(store)
        write(DistSSHQueue.store_pid_path(store), "999999999")
        @test !DistSSHQueue.serve_alive(store)
    end
end

@testset "detached serve script carries test tag" begin
    withenv("DISTSSHQUEUE_SERVE_TAG" => nothing) do
        script = DistSSHQueue.detached_serve_script("/julia", "/proj", "/tmp/q.log")
        @test occursin("nohup", script)
        @test !occursin("DISTSSHQUEUE_SERVE_TAG=", script)
    end
    withenv("DISTSSHQUEUE_SERVE_TAG" => "distsshqueue-test-tag") do
        tagged = DistSSHQueue.detached_serve_script("/julia", "/proj", "/tmp/q.log")
        @test occursin("DISTSSHQUEUE_SERVE_TAG='distsshqueue-test-tag'", tagged)
        @test occursin("nohup", tagged)
    end
end

@testset "write_pid_file appends DISTSSHQUEUE_TEST_PIDS" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        list = joinpath(d, "pids")
        write(list, "")
        withenv("DISTSSHKIT_TEST" => nothing, "DISTSSHQUEUE_TEST_PIDS" => list) do
            DistSSHQueue.write_pid_file(store)
        end
        @test !occursin(string(getpid()), read(list, String))
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHQUEUE_TEST_PIDS" => list) do
            DistSSHQueue.write_pid_file(store)
        end
        @test occursin(string(getpid()), read(list, String))
        DistSSHQueue.remove_pid_file(store)
    end
end

@testset "ensure_serve! skips when alive or opted out" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        withenv("DISTSSHQUEUE_NO_AUTOSERVE" => "1") do
            @test !DistSSHQueue.ensure_serve!(store)
        end
        DistSSHQueue.write_pid_file(store)
        withenv("DISTSSHQUEUE_NO_AUTOSERVE" => nothing) do
            @test !DistSSHQueue.ensure_serve!(store) # already alive (this test's own pid)
        end
        DistSSHQueue.remove_pid_file(store)
    end
end

@testset "stop latch holds off auto-serve until serve clears it" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        @test !DistSSHQueue.serve_stopped(store)
        DistSSHQueue.set_stopped!(store)
        @test DistSSHQueue.serve_stopped(store)
        @test isfile(DistSSHQueue.store_stop_path(store))
        withenv("DISTSSHQUEUE_NO_AUTOSERVE" => nothing) do
            @test !DistSSHQueue.ensure_serve!(store) # latched off, no spawn
        end
        DistSSHQueue.clear_stopped!(store)
        @test !DistSSHQueue.serve_stopped(store)
    end
end

@testset "stop_cli sets the latch and reports" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        write(store, "jobs = []\n")
        withenv("DISTSSHQUEUE_STORE" => store, "DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml")) do
            code, out, _ = capture_stdio() do
                DistSSHQueue.stop_cli(String[])
            end
            @test code == 0
            @test occursin("Stopped serve", out)
        end
        @test DistSSHQueue.serve_stopped(store)
    end
end

@testset "serve! refuses a second serve" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        write(store, "jobs = []\n")
        holder = run(pipeline(`sleep 30`; stdout = devnull, stderr = devnull); wait = false)
        try
            write(DistSSHQueue.store_pid_path(store), string(getpid(holder)))
            q = DistSSHQueue.Queue(; store = store, runner = _ -> nothing)
            _, out, _ = capture_stdio() do
                DistSSHQueue.serve!(q; interval = 0.02)
            end
            @test occursin("Already running", out)
            @test occursin("status or watch", out)
            @test DistSSHQueue.serve_pid(store) == getpid(holder)
        finally
            kill(holder)
            wait(holder)
        end
    end
end

@testset "serve! stops when its pidfile is removed" begin
    mktempdir() do d::String
        store = joinpath(d, "jobs.toml")
        write(store, "jobs = []\n")
        q = DistSSHQueue.Queue(; store = store, runner = _ -> nothing)
        _, out, _ = capture_stdio() do
            t = @async DistSSHQueue.serve!(q; interval = 0.02)
            for _ in 1:200
                DistSSHQueue.serve_pid(store) == getpid() && break
                sleep(0.02)
            end
            rm(d; force = true, recursive = true)
            for _ in 1:200
                istaskdone(t) && break
                sleep(0.02)
            end
            @test istaskdone(t)
            wait(t)
        end
        @test occursin("Stopping serve", out)
        @test !isfile(store)
    end
end

@testset "joining an interrupted serve spinner does not throw" begin
    DistSSHQueue._join_serve_spin!(nothing)
    done = @async nothing
    wait(done)
    DistSSHQueue._join_serve_spin!(done)
    stop = Ref(false)
    spin = @async begin
        while !stop[]
            sleep(0.01)
        end
    end
    stop[] = true
    DistSSHQueue._join_serve_spin!(spin)
    @test istaskdone(spin)
    hit = @async sleep(30)
    schedule(hit, InterruptException(); error = true)
    DistSSHQueue._join_serve_spin!(hit)
    @test istaskdone(hit)
end

@testset "serve! clears the stop latch on start" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        write(store, "jobs = []\n")
        DistSSHQueue.set_stopped!(store)
        q = DistSSHQueue.Queue(; store = store, runner = _ -> nothing)
        capture_stdio() do
            t = @async DistSSHQueue.serve!(q; interval = 0.02)
            for _ in 1:100
                DistSSHQueue.serve_stopped(store) || break
                sleep(0.02)
            end
            @test !DistSSHQueue.serve_stopped(store)
            schedule(t, InterruptException(); error = true)
            try
                wait(t)
            catch
            end
        end
    end
end

@testset "default_queue_env prefers the dedicated env dir" begin
    mktempdir() do d
        dedicated = joinpath(d, "env")
        project = Base.active_project()
        @test project isa String
        fallback = DistSSHQueue.resolve_pkg_env(dirname(project::String)).env_dir
        @test DistSSHQueue.default_queue_env(; dedicated = dedicated) == fallback
        mkpath(dedicated)
        write(joinpath(dedicated, "Project.toml"), "name = \"x\"\n")
        @test DistSSHQueue.default_queue_env(; dedicated = dedicated) == dedicated
    end
end

@testset "leading_hop_span" begin
    args = ["--remote-julia", "J", "--queue-env", "E", "qhost:H", "status"]
    @test DistSSHQueue.leading_hop_span(args, 1) == (2, :remote_julia)
    @test DistSSHQueue.leading_hop_span(args, 3) == (2, :queue_env)
    @test DistSSHQueue.leading_hop_span(args, 5) == (1, :qhost)
    @test DistSSHQueue.leading_hop_span(args, 6) == (0, :none)
    @test DistSSHQueue.leading_hop_span(["--remote-julia"], 1) == (0, :none)
    @test DistSSHQueue.leading_hop_span(["--queue-env"], 1) == (0, :none)
    @test DistSSHQueue.leading_hop_span(["--project", "P"], 1) == (0, :none)
    @test DistSSHQueue.leading_hop_span(["--project=P"], 1) == (0, :none)
    @test DistSSHQueue.leading_hop_span(["--qhost"], 1) == (0, :none)
    @test DistSSHQueue.leading_hop_span(String[], 1) == (0, :none)
    @test !Base.isexported(DistSSHQueue, :leading_hop_span)
    @test !Base.ispublic(DistSSHQueue, :leading_hop_span)
end

@testset "extract_remote_opts" begin
    withenv("DISTSSHQUEUE_HOST" => nothing) do
        withenv("JULIA_DISTRIBUTED_EXE" => nothing) do
            host, rjulia, qenv, payload, explicit = DistSSHQueue.extract_remote_opts(["qhost:qbox", "status"])
            @test host == "qbox"
            @test rjulia === nothing
            @test qenv === nothing
            @test payload == ["status"]
            @test explicit === true
            dest, spec = DistSSHQueue.coalesce_remote(host, rjulia, nothing, nothing)
            @test dest == "qbox"
            @test spec == "auto"
            h2, j2, q2, p2, e2 = DistSSHQueue.extract_remote_opts(["--hosts", "other", "status"])
            @test h2 === nothing
            @test j2 === nothing
            @test q2 === nothing
            @test p2 == ["--hosts", "other", "status"]
            @test e2 === false
            h3, _, _, p3, e3 = DistSSHQueue.extract_remote_opts(["go", "--hosts", "child:w:2", "S.jl"])
            @test h3 === nothing
            @test p3 == ["go", "--hosts", "child:w:2", "S.jl"]
            @test e3 === false
            h4, j4, _, p4, _ = DistSSHQueue.extract_remote_opts(["go", "--julia", "/opt/julia", "S.jl"])
            @test h4 === nothing
            @test j4 === nothing
            @test p4 == ["go", "--julia", "/opt/julia", "S.jl"]
            hv, _, _, pv, ev = DistSSHQueue.extract_remote_opts(["status", "qhost:qbox"])
            @test hv == "qbox"
            @test pv == ["status"]
            @test ev === true
        end
        withenv("JULIA_DISTRIBUTED_EXE" => "/opt/from-env/julia") do
            h, j, _, p, _ = DistSSHQueue.extract_remote_opts(["qhost:qbox", "status"])
            _, spec = DistSSHQueue.coalesce_remote(h, j, nothing, nothing)
            @test spec == "/opt/from-env/julia"
            @test p == ["status"]
        end

        host2, rjulia2, qenv2, payload2, ex2 = DistSSHQueue.extract_remote_opts(
            [
                "qhost:qbox", "--remote-julia", "/opt/julia", "go", "parent:1", "S.jl",
            ]
        )
        @test host2 == "qbox"
        @test rjulia2 == "/opt/julia"
        @test qenv2 === nothing
        @test payload2 == ["go", "parent:1", "S.jl"]
        @test ex2 === true
        @test_throws ArgumentError DistSSHQueue.extract_remote_opts(["--qhost", "qbox", "status"])
        @test DistSSHQueue.parse_qhost_token("qhost:user@box") == "user@box"
        @test_throws ArgumentError DistSSHQueue.parse_qhost_token("qhost:-oBatchMode=yes")
        @test_throws ArgumentError DistSSHQueue.parse_qhost_token("child:w:2")
        err4 = try
            DistSSHQueue.parse_qhost_token("qhost:4")
            ""
        catch e
            e isa ArgumentError ? e.msg : sprint(showerror, e)
        end
        @test occursin("parent:4", err4)
        @test occursin("not Kit slots", err4)
        twice = try
            DistSSHQueue.extract_remote_opts(["qhost:box", "drive", "qhost:4", "child:w:1"])
            ""
        catch e
            e isa ArgumentError ? e.msg : sprint(showerror, e)
        end
        @test occursin("parent:4", twice)

        host_go, julia_go, _, payload_go, _ = DistSSHQueue.extract_remote_opts(["go", "child:w1:2", "S.jl"])
        @test host_go === nothing
        @test julia_go === nothing
        @test payload_go == ["go", "child:w1:2", "S.jl"]

        @test_throws ArgumentError DistSSHQueue.coalesce_remote("a", nothing, "b", nothing)
        @test_throws ArgumentError DistSSHQueue.reject_qhost_on_local("setup", "qbox")
        @test_throws ArgumentError DistSSHQueue.reject_qhost_on_local("enable", "qbox")
        @test_throws ArgumentError DistSSHQueue.reject_qhost_on_local("add-host", "qbox")
        @test_throws ArgumentError DistSSHQueue.reject_qhost_on_local("remove-host", "qbox")
        DistSSHQueue.reject_qhost_on_local("status", "qbox")
        DistSSHQueue.reject_qhost_on_local("list-host", "qbox")
        DistSSHQueue.reject_qhost_on_local("setup", nothing)
        withenv(DistSSHQueue.QHOST_DEFAULT_ENV => "qbox") do
            code_env, _, err_env = capture_stdio() do
                DistSSHQueue.main(["setup", "-h"])
            end
            @test code_env == 0
            @test !occursin("runs on the queue host", err_env)
        end
        code, _, err = capture_stdio() do
            DistSSHQueue.main(["qhost:qbox", "add-host", "host1"])
        end
        @test code == 1
        @test occursin("runs on the queue host", err)
        code2, _, err2 = capture_stdio() do
            DistSSHQueue.main(["qhost:qbox", "remove-host", "host1"])
        end
        @test code2 == 1
        @test occursin("runs on the queue host", err2)

        host4, _, _, payload4, e4 = DistSSHQueue.extract_remote_opts(String[])
        @test host4 === nothing
        @test payload4 == String[]
        @test e4 === false

        withenv("DISTSSHQUEUE_HOST" => "qbox") do
            hd, _, _, pd, ed = DistSSHQueue.extract_remote_opts(["status"])
            @test hd == "qbox"
            @test pd == ["status"]
            @test ed === false
            ht, _, _, _, et = DistSSHQueue.extract_remote_opts(["qhost:other", "status"])
            @test ht == "other"
            @test et === true
        end
        withenv("DISTSSHQUEUE_HOST" => "qhost:qbox") do
            hp, _, _, _, ep = DistSSHQueue.extract_remote_opts(["status"])
            @test hp == "qbox"
            @test ep === false
        end

        _, _, qe, pl, _ = DistSSHQueue.extract_remote_opts(
            [
                "qhost:qbox", "--queue-env", "~/test-queue", "list-host",
            ]
        )
        @test qe == "~/test-queue"
        @test pl == ["list-host"]
        @test DistSSHQueue.coalesce_queue_env(qe, nothing) == "~/test-queue"
        @test DistSSHQueue.coalesce_queue_env(nothing, nothing) ==
            DistSSHQueue.HOP_QUEUE_ENV_DEFAULT
        withenv(DistSSHQueue.QUEUE_ENV_ENV => "/opt/qenv") do
            @test DistSSHQueue.coalesce_queue_env(nothing, nothing) == "/opt/qenv"
            @test DistSSHQueue.coalesce_queue_env("~/test-queue", nothing) == "~/test-queue"
        end
        @test DistSSHQueue.hop_julia_prefix("~/.distsshqueue/env") ==
            ["--startup-file=no", "--project=~/.distsshqueue/env"]
        @test DistSSHQueue.hop_julia_prefix("@") == ["--startup-file=no"]
        code3, _, err3 = capture_stdio() do
            DistSSHQueue.main(["qhost:qbox", "--project", ".", "list-host"])
        end
        @test code3 == 1
        @test occursin("--queue-env", err3)
        @test occursin("not forwarded", err3)
    end
end

@testset "config host names" begin
    H = DistSSHQueue.HostAllow
    @test DistSSHQueue.config_host_names(Dict{String, Any}()) === nothing
    @test DistSSHQueue.config_host_names(Dict{String, Any}("store" => "x")) === nothing
    @test DistSSHQueue.config_host_names(Dict{String, Any}("hosts" => [" parent ", "child:host1"])) ==
        H("parent" => nothing, "host1" => nothing)
    @test DistSSHQueue.config_host_names(Dict{String, Any}("hosts" => ["child:host1", "parent:2"])) ==
        H("host1" => nothing, "parent" => 2)
    @test DistSSHQueue.config_host_names(Dict{String, Any}("allowed" => ["child:host1", "parent:2"])) ==
        H("host1" => nothing, "parent" => 2)
    @test DistSSHQueue.kit_ssh_name("child:host1:4") == "host1"
    @test DistSSHQueue.kit_ssh_name("parent") == "parent"
    @test_throws ArgumentError DistSSHQueue.kit_ssh_name("host1")
    @test DistSSHQueue.config_host_names(Dict{String, Any}("hosts" => Any[])) == H()
    @test_throws ArgumentError DistSSHQueue.config_host_names(Dict{String, Any}("hosts" => ["host1"]))
    @test_throws ArgumentError DistSSHQueue.config_host_names(Dict{String, Any}("hosts" => "parent"))
    @test_throws ArgumentError DistSSHQueue.config_host_names(
        Dict{String, Any}("hosts" => ["parent"], "allowed" => ["child:host1"]),
    )
end

@testset "add-host / remove-host write hosts" begin
    mktempdir() do d
        H = DistSSHQueue.HostAllow
        cfg = joinpath(d, "config.toml")
        DistSSHQueue.write_config_template(cfg)
        DistSSHQueue.add_host_names!(cfg, ["parent", "child:host1"])
        text = read(cfg, String)
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path = cfg)) ==
            H("parent" => nothing, "host1" => nothing)
        @test occursin("hosts = [", text)
        @test occursin("child:host1", text)
        @test occursin("[env]", text)
        @test occursin("# DistSSHQueue", text)
        @test occursin("DISTRIBUTED_SSH_OPTS", text)
        @test occursin("Do not set DISTRIBUTED_REMOTE_PROJECT_ROOT here", text)
        @test !occursin("DISTRIBUTED_REMOTE_PROJECT_ROOT = ", text)
        @test !occursin("# hosts", text)
        DistSSHQueue.add_host_names!(cfg, ["child:host1"])
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path = cfg)) ==
            H("parent" => nothing, "host1" => nothing)
        DistSSHQueue.add_host_names!(cfg, ["child:host1:4"])
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path = cfg)) ==
            H("parent" => nothing, "host1" => 4)
        @test occursin("child:host1:4", read(cfg, String))
        DistSSHQueue.remove_host_names!(cfg, ["parent"])
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path = cfg)) ==
            H("host1" => 4)
        DistSSHQueue.remove_host_names!(cfg, ["child:host1"])
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path = cfg)) ==
            H()
        @test occursin("hosts = []", read(cfg, String))
        @test_throws ArgumentError DistSSHQueue.remove_host_names!(cfg, ["child:host1"])
        @test_throws ArgumentError DistSSHQueue.add_host_names!(cfg, ["host1"])
        missing = joinpath(d, "none.toml")
        DistSSHQueue.add_host_names!(missing, ["child:host1"])
        @test isfile(missing)
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path = missing)) ==
            H("host1" => nothing)
        @test_throws ArgumentError DistSSHQueue.add_host_names!(cfg, String[])
        @test DistSSHQueue.replace_or_insert_hosts_line("store = \"x\"\n", "hosts = []") ==
            "store = \"x\"\nhosts = []\n"
        old = joinpath(d, "old.toml")
        write(old, "store = \"x\"\nallowed = [\"parent\"]\n")
        DistSSHQueue.add_host_names!(old, ["child:host1"])
        migrated = read(old, String)
        @test occursin("hosts = [", migrated)
        @test occursin("child:host1", migrated)
        @test !occursin("allowed =", migrated)
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path = old)) ==
            H("parent" => nothing, "host1" => nothing)
    end
end

@testset "add-host replaces the live hosts span" begin
    H = DistSSHQueue.HostAllow
    line = "hosts = [\"parent\", \"child:host1\"]"
    commented = "# hosts = [\"stale\"]\nhosts = [\"parent\"]\n"
    out = DistSSHQueue.replace_or_insert_hosts_line(commented, line)
    @test out == "# hosts = [\"stale\"]\n" * line * "\n"
    @test count(r -> startswith(strip(r), "hosts ="), split(out, '\n')) == 1

    multi = "hosts = [\n  \"parent\",\n]\n"
    out = DistSSHQueue.replace_or_insert_hosts_line(multi, line)
    @test out == line * "\n"
    @test !occursin("  \"parent\"", out)

    @test_throws ArgumentError DistSSHQueue._require_written_hosts!(
        "hosts = [\n", H("parent" => nothing)
    )

    mktempdir() do d
        cfg = joinpath(d, "config.toml")
        write(cfg, multi)
        DistSSHQueue.add_host_names!(cfg, ["child:host1"])
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path = cfg)) ==
            H("parent" => nothing, "host1" => nothing)
        @test !occursin("  \"parent\"", read(cfg, String))
        write(cfg, "hosts = [\n")
        before = read(cfg, String)
        @test_throws ArgumentError DistSSHQueue.add_host_names!(cfg, ["parent"])
        @test read(cfg, String) == before
    end
end

@testset "invalid config is an error and host edits keep both names" begin
    mktempdir() do d::String
        cfg = joinpath(d, "config.toml")
        broken = "store = [\n"
        write(cfg, broken)
        err = try
            DistSSHQueue.load_config(; path = cfg)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("not valid TOML", err.msg)
        @test err isa ArgumentError && occursin("unexpected end of file", err.msg)
        @test read(cfg, String) == broken
        code = withenv("DISTSSHQUEUE_CONFIG" => cfg) do
            DistSSHQueue.main(["status"])
        end
        @test code == 1
        @test read(cfg, String) == broken

        nested = joinpath(d, "newdir", "config.toml")
        @test !isdir(dirname(nested))
        DistSSHQueue.add_host_names!(nested, ["parent"])
        @test isfile(nested)
        nested_names = DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path = nested))
        @test nested_names isa DistSSHQueue.HostAllow && haskey(nested_names, "parent")

        fresh = joinpath(d, "fresh.toml")
        write(fresh, "store = \"/tmp/jobs.toml\"\n")
        proj = Base.active_project()
        code_add = "using DistSSHQueue; DistSSHQueue.add_host_names!(ARGS[1], [ARGS[2]])"
        procs = Base.Process[]
        try
            for token in ("child:host1", "child:host2")
                cmd = `$(Base.julia_cmd()) --startup-file=no --project=$proj -e $code_add $fresh $token`
                push!(procs, run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false))
            end
            for p in procs
                wait(p)
                @test p.exitcode == 0
            end
        finally
            for p in procs
                process_running(p) && kill(p)
            end
        end
        names = DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path = fresh))
        @test names isa DistSSHQueue.HostAllow && haskey(names, "host1") && haskey(names, "host2")
        @test !any(n -> occursin(".tmp", n), readdir(d))
    end
end

@testset "setup writes config, not a dskq shim" begin
    mktempdir() do d
        bindir = joinpath(d, "bin")
        cfg = joinpath(d, "config.toml")
        other = joinpath(d, "keep.toml")
        write(other, "store = \"x\"\n")
        withenv("DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml")) do
            code, out, _ = capture_stdio() do
                DistSSHQueue.main(["setup", "--config", cfg])
            end
            @test code == 0
            @test occursin("Wrote", out)
        end
        @test !isfile(joinpath(bindir, "dskq"))
        @test isfile(cfg)
        @test occursin("[env]", read(cfg, String))
        @test occursin("# hosts", read(cfg, String))
        @test DistSSHQueue.write_config_template(other) === false
        @test read(other, String) == "store = \"x\"\n"
    end
end

@testset "setup re-run is idempotent; --force rewrites" begin
    mktempdir() do d
        cfg = joinpath(d, "config.toml")
        run_setup(extra) = capture_stdio() do
            DistSSHQueue.main(vcat(["setup", "--config", cfg], extra))
        end
        withenv("DISTSSHQUEUE_CONFIG" => joinpath(d, "missing.toml")) do
            code1, out1, _ = run_setup(String[])
            @test code1 == 0
            @test occursin("Wrote", out1)
            write(cfg, "store = \"edited\"\n")
            code2, out2, _ = run_setup(String[])
            @test code2 == 0
            @test occursin("Present", out2)
            @test read(cfg, String) == "store = \"edited\"\n"
            code3, out3, _ = run_setup(["--force"])
            @test code3 == 0
            @test occursin("Wrote", out3)
            @test occursin("[env]", read(cfg, String))
            run_up(extra) = capture_stdio() do
                DistSSHQueue.main(vcat(["up", "--config", cfg], extra))
            end
            code_jf, _, err_jf = run_up(["--force"])
            @test code_jf == 1
            @test occursin("does not take --force", err_jf)
            code_jh, _, err_jh = run_up(String[])
            @test code_jh == 1
            @test occursin("needs add, default, update, or status", err_jh)
            code_jt, _, err_jt = run_up(["parent"])
            @test code_jt == 1
            @test occursin("needs add, default, update, or status", err_jt)
            code_uf, _, err_uf = run_up(["update", "--force"])
            @test code_uf == 1
            @test occursin("does not take --force", err_uf)
            code_uh, _, err_uh = run_up(["update"])
            @test code_uh == 1
            @test occursin("add-host", err_uh)
            code_ut, _, err_ut = run_up(["update", "child:mini-tak-ts"])
            @test code_ut == 1
            @test occursin("does not take host tokens", err_ut)
            code_old, _, err_old = run_setup(["--juliaup"])
            @test code_old == 1
            @test occursin("julia -m DistSSHQueue up", err_old)
            @test !occursin("qhost", err_old)
            code4, _, err4 = run_setup(["--service"])
            @test code4 == 1
            @test occursin("enable", err4)
            code5, _, err5 = capture_stdio() do
                DistSSHQueue.main(["service", "install"])
            end
            @test code5 == 1
            @test occursin("enable", err5)
        end
    end
end

@testset "teardown -y removes queue-host files" begin
    mktempdir() do home::String
        data = joinpath(home, ".distsshqueue")
        mkpath(joinpath(data, "env"))
        cfg = joinpath(data, "config.toml")
        store = joinpath(data, "jobs.toml")
        write(cfg, "store = $(repr(store))\n")
        write(store, "jobs = []\n")
        write(string(store, ".log"), "log\n")
        mkpath(string(store, ".lock"))
        write(joinpath(data, "env", "Project.toml"), "name = \"x\"\n")
        bindir = joinpath(home, ".local", "bin")
        mkpath(bindir)
        wrap = joinpath(bindir, "dskq")
        write(wrap, "#!/bin/sh\n")
        withenv(
            "DISTSSHQUEUE_CONFIG" => nothing,
            "DISTSSHQUEUE_STORE" => nothing,
            "DISTSSHKIT_YES" => nothing,
        ) do
            code1, out1, err1 = capture_stdio() do
                DistSSHQueue.teardown_main(["--home", home, "--write-only"])
            end
            @test code1 == 0
            @test occursin("Would remove", out1)
            @test occursin(".lock", out1)
            @test occursin("Pass -y / --yes to delete.", out1)
            @test occursin("Pass --confirm-path for each quoted path above.", out1)
            @test !occursin("Error:", err1)
            @test !occursin("Error:", out1)
            @test isfile(store)
            @test isfile(wrap)
            code_y, out_y, err_y = capture_stdio() do
                DistSSHQueue.teardown_main(["--home", home, "-y", "--write-only"])
            end
            @test code_y == 0
            @test occursin("still deletes", err_y)
            @test occursin("0.10", err_y)
            @test !occursin("Would remove", out_y)
            @test !isfile(store)
        end
        @test !ispath(data)
        @test !isfile(wrap)
    end
end

@testset "teardown confirm_paths" begin
    mktempdir() do home::String
        data = joinpath(home, ".distsshqueue")
        mkpath(data)
        write(joinpath(data, "config.toml"), "store = \"x\"\n")
        withenv(
            "DISTSSHQUEUE_CONFIG" => nothing,
            "DISTSSHQUEUE_STORE" => nothing,
            "DISTSSHKIT_YES" => "1",
        ) do
            code0, out0, _ = capture_stdio() do
                DistSSHQueue.teardown(; home = home, apply = false)
            end
            @test code0 == 0
            @test occursin("Would remove", out0)
            @test isdir(data)
            code_bad, out_bad, _ = capture_stdio() do
                DistSSHQueue.teardown(;
                    home = home,
                    apply = false,
                    confirm_paths = ["/no/such"],
                )
            end
            @test code_bad == 1
            @test occursin("confirm_paths does not match", out_bad)
            @test isdir(data)
            paths = String[p for p in DistSSHQueue.teardown_targets(; home = home) if ispath(p)]
            @test !isempty(paths)
            code_ok, _, _ = capture_stdio() do
                DistSSHQueue.teardown(;
                    home = home,
                    apply = false,
                    confirm_paths = paths,
                )
            end
            @test code_ok == 0
        end
        @test !ispath(data)
    end
    mktempdir() do home::String
        withenv(
            "DISTSSHQUEUE_CONFIG" => nothing,
            "DISTSSHQUEUE_STORE" => nothing,
        ) do
            code_empty, out_empty, _ = capture_stdio() do
                DistSSHQueue.teardown(;
                    home = home,
                    apply = false,
                    confirm_paths = [joinpath(home, "missing")],
                )
            end
            @test code_empty == 1
            @test occursin("confirm_paths does not match", out_empty)
        end
    end
end

@testset "teardown -y removes leftover DistSSHKitQueue home" begin
    mktempdir() do home::String
        data = joinpath(home, ".distsshqueue")
        mkpath(data)
        write(joinpath(data, "config.toml"), "store = \"x\"\n")
        legacy = joinpath(home, ".distsshkitqueue")
        mkpath(legacy)
        write(joinpath(legacy, "config.toml"), "store = \"old\"\n")
        withenv(
            "DISTSSHQUEUE_CONFIG" => nothing,
            "DISTSSHQUEUE_STORE" => nothing,
            "DISTSSHKIT_YES" => nothing,
        ) do
            confirm = String[]
            for p in DistSSHQueue.teardown_targets(; home = home)
                ispath(p) || continue
                push!(confirm, "--confirm-path", p)
            end
            code, _, _ = capture_stdio() do
                DistSSHQueue.teardown_main(["--home", home, "--write-only", confirm...])
            end
            @test code == 0
        end
        @test !ispath(data)
        @test !ispath(legacy)
    end
end

@testset "teardown DISTSSHKIT_YES still deletes" begin
    mktempdir() do home::String
        data = joinpath(home, ".distsshqueue")
        mkpath(data)
        cfg = joinpath(data, "config.toml")
        store = joinpath(data, "jobs.toml")
        write(cfg, "store = $(repr(store))\n")
        write(store, "jobs = []\n")
        withenv(
            "DISTSSHQUEUE_CONFIG" => nothing,
            "DISTSSHQUEUE_STORE" => nothing,
            "DISTSSHKIT_YES" => "true",
        ) do
            code, _, err = capture_stdio() do
                DistSSHQueue.teardown_main(["--home", home, "--write-only"])
            end
            @test code == 0
            @test occursin("still deletes", err)
            @test occursin("0.10", err)
            @test !ispath(data)
        end
    end
end

@testset "teardown DISTSSHKIT_YES from target config [env] still deletes" begin
    mktempdir() do home::String
        data = joinpath(home, ".distsshqueue")
        mkpath(data)
        cfg = joinpath(data, "config.toml")
        store = joinpath(data, "jobs.toml")
        write(cfg, "store = $(repr(store))\n\n[env]\nDISTSSHKIT_YES = \"1\"\n")
        write(store, "jobs = []\n")
        withenv(
            "DISTSSHQUEUE_CONFIG" => nothing,
            "DISTSSHQUEUE_STORE" => nothing,
            "DISTSSHKIT_YES" => nothing,
        ) do
            code, _, err = capture_stdio() do
                DistSSHQueue.teardown_main(["--home", home, "--write-only"])
            end
            @test code == 0
            @test occursin("still deletes", err)
            @test !ispath(data)
        end
    end
end

@testset "teardown config YES deletes and does not import test hooks" begin
    mktempdir() do home
        data = joinpath(home, ".distsshqueue")
        mkpath(data)
        cfg = joinpath(data, "config.toml")
        store = joinpath(data, "jobs.toml")
        write(
            cfg,
            "store = $(repr(store))\n\n[env]\nDISTSSHKIT_YES = \"1\"\n" *
                "DISTSSHKIT_TEST = \"1\"\nDISTSSHKIT_TEST_SSH = \"/tmp/not-ssh.jl\"\n" *
                "DISTSSHQUEUE_TEST_PIDS = \"/tmp/not-pids\"\n",
        )
        write(store, "jobs = []\n")
        try
            withenv(
                "HOME" => home,
                "DISTSSHQUEUE_CONFIG" => nothing,
                "DISTSSHQUEUE_STORE" => nothing,
                "DISTSSHKIT_YES" => nothing,
                "DISTSSHKIT_TEST" => nothing,
                "DISTSSHKIT_TEST_SSH" => nothing,
                "DISTSSHQUEUE_TEST_PIDS" => nothing,
            ) do
                code, out, err = capture_stdio() do
                    DistSSHQueue._main(["teardown", "--write-only"])
                end
                @test code == 0
                @test occursin("still deletes", err)
                @test get(ENV, "DISTSSHKIT_YES", "") == "1"
                @test get(ENV, "DISTSSHKIT_TEST", "") == ""
                @test get(ENV, "DISTSSHKIT_TEST_SSH", "") == ""
                @test get(ENV, "DISTSSHQUEUE_TEST_PIDS", "") == ""
                @test !occursin("Pass --confirm-path for each quoted path above.", out)
            end
        finally
            DistSSHQueue._forget_absent_config_env!()
        end
        @test !ispath(data)
    end
end

@testset "ssh_opts keeps a quoted path" begin
    withenv("DISTRIBUTED_SSH_OPTS" => "-F \"/tmp/cfg dir/config\" -o BatchMode=yes") do
        @test DistSSHQueue.ssh_opts() == ["-F", "/tmp/cfg dir/config", "-o", "BatchMode=yes"]
    end
    withenv("DISTRIBUTED_SSH_OPTS" => "-F \"unterminated") do
        @test_throws ArgumentError DistSSHQueue.ssh_opts()
    end
    withenv("DISTRIBUTED_SSH_OPTS" => nothing) do
        @test "BatchMode=yes" in DistSSHQueue.ssh_opts()
    end
end

@testset "stale store lock" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        lockdir = store * ".lock"
        @test !DistSSHQueue._store_lock_stale(joinpath(d, "missing.lock"); now = 1.0e12)
        mkdir(lockdir)
        @test !DistSSHQueue._store_lock_stale(lockdir)
        @test !DistSSHQueue._store_lock_stale(lockdir; now = mtime(lockdir) + DistSSHQueue._STORE_LOCK_STALE_SEC)
        @test DistSSHQueue._store_lock_stale(lockdir; now = mtime(lockdir) + DistSSHQueue._STORE_LOCK_STALE_SEC + 0.01)
        write(joinpath(lockdir, "pid"), string(getpid()))
        @test !DistSSHQueue._store_lock_stale(lockdir)
        write(joinpath(lockdir, "pid"), "999999999")
        @test DistSSHQueue._store_lock_stale(lockdir)
        ran = Ref(false)
        DistSSHQueue.with_store_lock(store) do
            ran[] = true
            @test read(joinpath(lockdir, "pid"), String) == string(getpid())
        end
        @test ran[]
        @test !isdir(lockdir)
    end
end

@testset "store lock pid disappears while it is opened" begin
    mktempdir() do d
        lockdir = joinpath(d, "jobs.toml.lock")
        stop = Threads.Atomic{Int}(0)
        reader = Task() do
            for _ in 1:100_000
                stop[] == 1 && break
                DistSSHQueue._read_lock_pid(lockdir)
                DistSSHQueue._store_lock_stale(lockdir)
                yield()
            end
            return nothing
        end
        reader.sticky = false
        schedule(reader)
        for _ in 1:5000
            mkpath(lockdir)
            write(joinpath(lockdir, "pid"), "1")
            rm(lockdir; force = true, recursive = true)
        end
        Threads.atomic_xchg!(stop, 1)
        wait(reader)
        @test DistSSHQueue._read_lock_pid(lockdir) === nothing
        @test !DistSSHQueue._store_lock_stale(lockdir)
    end
end

@testset "save_jobs replaces the file" begin
    mktempdir() do d::String
        store = joinpath(d, "jobs.toml")
        j = DistSSHQueue.Job(;
            id = "aaaaaaaa-4444-4000-8000-000000000004",
            kind = :go,
            script = joinpath(d, "S.jl"),
            hosts = ["parent:1"],
            state = :queued,
        )
        DistSSHQueue.save_jobs(store, [j])
        @test !any(n -> occursin(".tmp.", n), readdir(d))
        jobs = DistSSHQueue.read_jobs(store)
        @test length(jobs) == 1
        @test jobs[1].id == j.id
        @test jobs[1].script == j.script
    end
end

@testset "corrupt jobs store is not rewritten" begin
    mktempdir() do d::String
        store = joinpath(d, "jobs.toml")
        write(store, "jobs = [\n")
        original = read(store, String)
        err = try
            DistSSHQueue.read_jobs(store)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test startswith(err.msg, "jobs store is not valid TOML:")
        err2 = try
            DistSSHQueue.save_jobs(store, DistSSHQueue.Job[])
            nothing
        catch e
            e
        end
        @test err2 isa ArgumentError
        @test read(store, String) == original

        write(store, "jobs = [{id = \"only\"}]\n")
        row = try
            DistSSHQueue.read_jobs(store)
            nothing
        catch e
            e
        end
        @test row isa ArgumentError
        @test occursin("missing a field or has the wrong type", row.msg)
        @test read(store, String) == "jobs = [{id = \"only\"}]\n"

        write(store, "jobs = 1\n")
        kept = read(store, String)
        warned = mktemp() do path, io
            redirect_stdout(io) do
                @test isempty(DistSSHQueue.read_jobs(store))
                @test isempty(DistSSHQueue.read_jobs(store))
            end
            close(io)
            return read(path, String)
        end
        refused = try
            DistSSHQueue.save_jobs(store, DistSSHQueue.Job[])
            nothing
        catch e
            e
        end
        @test refused isa ArgumentError
        @test occursin("not a list", refused.msg)
        @test read(store, String) == kept
        @test count("not a list", warned) == 1
        @test occursin("0.10 will reject", warned)

        rm(store)
        DistSSHQueue.save_jobs(
            store, [
                DistSSHQueue.Job(;
                    id = "bbbbbbbb-4444-4000-8000-000000000004",
                    kind = :go,
                    script = joinpath(d, "S.jl"),
                    hosts = ["parent:1"],
                    state = :queued,
                ),
            ]
        )
        dated = replace(read(store, String), r"queued_at = \"[^\"]*\"" => "queued_at = \"garbage\"")
        write(store, dated)
        bad_dt = try
            DistSSHQueue.read_jobs(store)
            nothing
        catch e
            e
        end
        @test bad_dt isa ArgumentError
        @test occursin("missing a field or has the wrong type", bad_dt.msg)
        @test read(store, String) == dated
    end
end

@testset "claim_serve replaces a dead pid and keeps a live one" begin
    mktempdir() do d::String
        store = joinpath(d, "jobs.toml")
        pid = DistSSHQueue.store_pid_path(store)
        write(pid, "999999999")
        @test DistSSHQueue.claim_serve!(store) === nothing
        @test DistSSHQueue.serve_pid(store) == getpid()
        @test DistSSHQueue.claim_serve!(store) === nothing
        @test strip(read(pid, String)) == string(getpid())
        @test !any(n -> occursin(".tmp.", n), readdir(d))
    end
end

@testset "a failed serve load drops only this process pidfile" begin
    mktempdir() do d::String
        store = joinpath(d, "jobs.toml")
        pid = DistSSHQueue.store_pid_path(store)
        write(store, "not toml {{\n")
        err = try
            DistSSHQueue.serve!(DistSSHQueue.Queue(; store = store))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test !isfile(pid)
        write(pid, "999999999")
        @test DistSSHQueue.remove_pid_file_if!(store, getpid()) == false
        @test strip(read(pid, String)) == "999999999"
        write(pid, string(getpid()))
        @test DistSSHQueue.stop_serve!(store) == false
        @test strip(read(pid, String)) == string(getpid())
        write(pid, "999999999")
        @test DistSSHQueue.stop_serve!(store)
        @test !isfile(pid)
        # stop reports success for a signaled pid even if the pidfile was taken
        # over in the meantime; here a fresh dead pid stands in for that file.
        write(pid, "888888888")
        @test DistSSHQueue.stop_serve!(store)
    end
end

@testset "claim_serve admits one process" begin
    # The winner waits for a release file. A child stuck in startup can
    # ignore SIGTERM (PkgEval then sees a silent wait and kills for
    # inactivity), so the reaper escalates to SIGKILL on a bound.
    function reap!(p::Base.Process)
        process_running(p) || return
        try
            kill(p)
        catch
        end
        killer = Timer(wait_seconds(:stop_grace)) do _
            process_running(p) || return
            try
                kill(p, Base.SIGKILL)
            catch
            end
        end
        try
            wait(p)
        finally
            close(killer)
        end
    end
    mktempdir() do d::String
        store = joinpath(d, "jobs.toml")
        release = joinpath(d, "release")
        proj = Base.active_project()
        # The winner waits for the parent's release file, with no deadline of
        # its own: a slow second child must still see one winner. The parent
        # always `touch`es the file (both in the body and in `finally`), and
        # `reap!` escalates to SIGKILL, so this wait is already bounded.
        code = "using DistSSHQueue; other = DistSSHQueue.claim_serve!(ARGS[1]); open(ARGS[2], \"w\") do io; println(io, other === nothing ? \"won \$(getpid())\" : \"lost \$other\"); end; other === nothing || exit(0); while !isfile(ARGS[3]); sleep(0.05); end"
        procs = Base.Process[]
        try
            for i in 1:2
                out = joinpath(d, "out$i")
                err = joinpath(d, "err$i")
                cmd = `$(Base.julia_cmd()) --startup-file=no --project=$proj -e $code $store $out $release`
                push!(procs, run(pipeline(cmd; stdout = devnull, stderr = err); wait = false))
            end
            # Both lines, both exits, or CPU under a few percent and no output
            # growth for `:child_reply`. Unreadable CPU time is that long on
            # the wall clock.
            lines = String[]
            watch = IdleWatch(wait_seconds(:child_reply))
            seen = Dict{Int, Int}()
            while true
                lines = String[]
                output = 0
                for i in 1:2
                    out = joinpath(d, "out$i")
                    isfile(out) || continue
                    output += filesize(out)
                    s = strip(read(out, String))
                    isempty(s) || push!(lines, s)
                end
                length(lines) == 2 && break
                any(process_running, procs) || break
                mark = observe_progress!(
                    watch;
                    cpu = monotonic_group_cpu!(seen, procs),
                    output,
                    now = time(),
                )
                mark === :busy || break
                sleep(CHILD_POLL_S)
            end
            touch(release)
            won_lines = filter(startswith("won "), lines)
            lost_lines = filter(startswith("lost "), lines)
            if length(won_lines) != 1 || length(lost_lines) != 1
                for i in 1:2
                    err = joinpath(d, "err$i")
                    isfile(err) || continue
                    text = read(err, String)
                    isempty(strip(text)) && continue
                    println(stderr, "──── claim_serve child $i ────")
                    println(stderr, text)
                    println(stderr, "──── end claim_serve child $i ────")
                end
            end
            @test length(won_lines) == 1
            @test length(lost_lines) == 1
            if length(won_lines) == 1 && length(lost_lines) == 1
                won = parse(Int, split(first(won_lines))[2])
                lost = parse(Int, split(first(lost_lines))[2])
                @test lost == won
            end
        finally
            touch(release)
            for p in procs
                reap!(p)
            end
        end
    end
end

@testset "status prints Error for invalid jobs TOML" begin
    mktempdir() do d::String
        store = joinpath(d, "jobs.toml")
        write(store, "jobs = [\n")
        proj = Base.active_project()
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$proj -m DistSSHQueue status`
        out = IOBuffer()
        err = IOBuffer()
        p = withenv(
            "DISTSSHQUEUE_STORE" => store,
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
        ) do
            run(pipeline(cmd; stdout = out, stderr = err); wait = false)
        end
        wait(p)
        text = String(take!(err))
        @test p.exitcode == 1
        @test occursin("Error:", text)
        @test occursin("not valid TOML", text)
        @test read(store, String) == "jobs = [\n"
    end
end

@testset "non-finite --interval is rejected; serve <= 0 warns once" begin
    for raw in ("NaN", "Inf", "-Inf")
        err = try
            DistSSHQueue.parse_cli_interval("watch", raw)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("must be finite", err.msg)
    end
    code, _, err = capture_stdio() do
        DistSSHQueue.main(["serve", "--interval", "Inf"])
    end
    @test code == 1
    @test occursin("Error:", err)
    @test occursin("must be finite", err)
    _, warned, _ = capture_stdio() do
        DistSSHQueue._note_serve_interval!(0.0)
        DistSSHQueue._note_serve_interval!(-1.0)
        DistSSHQueue._note_serve_interval!(0.2)
    end
    @test count("will require --interval > 0", warned) == 1
end

@testset "DISTSSHQUEUE_STORE=~ warns once and stays a relative path" begin
    raw = "~/distsshqueue-010-warn/jobs.toml"
    withenv("DISTSSHQUEUE_STORE" => raw, "DISTSSHQUEUE_CONFIG" => nothing) do
        _, warned, _ = capture_stdio() do
            @test DistSSHQueue.store_path() == raw
            @test DistSSHQueue.store_path() == raw
        end
        @test count("starts with ~", warned) == 1
        @test occursin("0.10 will reject", warned)
    end
end

@testset "teardown warns once for a symlink and still lists it" begin
    mktempdir() do home::String
        real = joinpath(home, "real.toml")
        write(real, "store = $(repr(joinpath(home, "jobs.toml")))\n")
        link = joinpath(home, ".distsshqueue", "config.toml")
        mkpath(dirname(link))
        symlink(real, link)
        withenv("DISTSSHQUEUE_STORE" => nothing, "DISTSSHQUEUE_CONFIG" => nothing) do
            _, warned, _ = capture_stdio() do
                @test DistSSHQueue.teardown(; home = home, config = link, apply = false) == 0
                @test DistSSHQueue.teardown(; home = home, config = link, apply = false) == 0
            end
            @test count("will refuse", warned) == 1
            @test islink(link)
            @test isfile(real)
        end
    end
end

@testset "declining up default warns once and exits 0" begin
    prev = DistSSHRun.kit_noninteractive()
    DistSSHRun.set_kit_noninteractive!(false)
    try
        decline() = mktemp() do path, io
            println(io, "no")
            close(io)
            open(path) do inp
                redirect_stdin(inp) do
                    DistSSHQueue._up_run_on_hosts(
                        ["parent"]; verb = "default", channel = "1.13", confirm = true,
                    )
                end
            end
        end
        code, warned, _ = capture_stdio(decline)
        code2, warned2, _ = capture_stdio(decline)
        @test code == 0
        @test code2 == 0
        @test count("will exit 1", warned) == 1
        @test !occursin("will exit 1", warned2)
    finally
        DistSSHRun.set_kit_noninteractive!(prev)
    end
end

@testset "status warns once for a dead kit.pid and does not rewrite the store" begin
    mktempdir() do d::String
        store = joinpath(d, "jobs.toml")
        script = joinpath(d, "a.jl")
        write(script, "1\n")
        rundir = joinpath(d, "run")
        mkpath(rundir)
        write(joinpath(rundir, "kit.pid"), "99999999\n")
        DistSSHQueue.save_jobs(
            store,
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
        before = read(store, String)
        _, warned, _ = capture_stdio() do
            DistSSHQueue.show_status(store)
            DistSSHQueue.show_status(store)
        end
        @test read(store, String) == before
        @test count("kit.pid is dead", warned) == 1
        @test occursin("running", warned)
        fresh = joinpath(d, "live.toml")
        DistSSHQueue.save_jobs(
            fresh,
            [
                DistSSHQueue.Job(;
                    kind = :go,
                    script = script,
                    hosts = ["parent"],
                    state = :running,
                ),
            ],
        )
        _, quiet, _ = capture_stdio() do
            DistSSHQueue.show_status(fresh)
        end
        @test !occursin("kit.pid is dead", quiet)
    end
end
