using Test
using DistSSHKit
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
            @test DistSSHQueue.load_config() == Dict{String,Any}()
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
        tasks = [@async begin
            for _ in 1:40
                DistSSHQueue.with_store_lock(store) do
                    Threads.atomic_add!(n, 1)
                    sleep(0.001)
                end
            end
        end for _ in 1:4]
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
        withenv("DISTSSHQUEUE_TEST_PIDS" => list) do
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
        holder = run(pipeline(`sleep 30`; stdout=devnull, stderr=devnull); wait=false)
        try
            write(DistSSHQueue.store_pid_path(store), string(getpid(holder)))
            q = DistSSHQueue.Queue(; store=store, runner=_ -> nothing)
            _, out, _ = capture_stdio() do
                DistSSHQueue.serve!(q; interval=0.02)
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
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        write(store, "jobs = []\n")
        q = DistSSHQueue.Queue(; store=store, runner=_ -> nothing)
        _, out, _ = capture_stdio() do
            t = @async DistSSHQueue.serve!(q; interval=0.02)
            for _ in 1:200
                DistSSHQueue.serve_pid(store) == getpid() && break
                sleep(0.02)
            end
            rm(d; force=true, recursive=true)
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
    schedule(hit, InterruptException(); error=true)
    DistSSHQueue._join_serve_spin!(hit)
    @test istaskdone(hit)
end

@testset "serve! clears the stop latch on start" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        write(store, "jobs = []\n")
        DistSSHQueue.set_stopped!(store)
        q = DistSSHQueue.Queue(; store=store, runner=_ -> nothing)
        capture_stdio() do
            t = @async DistSSHQueue.serve!(q; interval=0.02)
            for _ in 1:100
                DistSSHQueue.serve_stopped(store) || break
                sleep(0.02)
            end
            @test !DistSSHQueue.serve_stopped(store)
            schedule(t, InterruptException(); error=true)
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
        fallback = DistSSHKit.canonical_local_path(dirname(Base.active_project()))
        @test DistSSHQueue.default_queue_env(; dedicated=dedicated) == fallback
        mkpath(dedicated)
        write(joinpath(dedicated, "Project.toml"), "name = \"x\"\n")
        @test DistSSHQueue.default_queue_env(; dedicated=dedicated) == dedicated
    end
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

    host2, rjulia2, qenv2, payload2, ex2 = DistSSHQueue.extract_remote_opts([
        "qhost:qbox", "--remote-julia", "/opt/julia", "go", "parent:1", "S.jl",
    ])
    @test host2 == "qbox"
    @test rjulia2 == "/opt/julia"
    @test qenv2 === nothing
    @test payload2 == ["go", "parent:1", "S.jl"]
    @test ex2 === true
    @test_throws ArgumentError DistSSHQueue.extract_remote_opts(["--qhost", "qbox", "status"])
    @test DistSSHQueue.parse_qhost_token("qhost:user@box") == "user@box"
    @test_throws ArgumentError DistSSHQueue.parse_qhost_token("child:w:2")

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

    _, _, qe, pl, _ = DistSSHQueue.extract_remote_opts([
        "qhost:qbox", "--queue-env", "~/test-queue", "list-host",
    ])
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
    @test DistSSHQueue.config_host_names(Dict{String,Any}()) === nothing
    @test DistSSHQueue.config_host_names(Dict{String,Any}("store" => "x")) === nothing
    @test DistSSHQueue.config_host_names(Dict{String,Any}("hosts" => [" parent ", "child:host1"])) ==
          H("parent" => nothing, "host1" => nothing)
    @test DistSSHQueue.config_host_names(Dict{String,Any}("hosts" => ["child:host1", "parent:2"])) ==
          H("host1" => nothing, "parent" => 2)
    @test DistSSHQueue.config_host_names(Dict{String,Any}("allowed" => ["child:host1", "parent:2"])) ==
          H("host1" => nothing, "parent" => 2)
    @test DistSSHQueue.kit_ssh_name("child:host1:4") == "host1"
    @test DistSSHQueue.kit_ssh_name("parent") == "parent"
    @test_throws ArgumentError DistSSHQueue.kit_ssh_name("host1")
    @test DistSSHQueue.config_host_names(Dict{String,Any}("hosts" => Any[])) == H()
    @test_throws ArgumentError DistSSHQueue.config_host_names(Dict{String,Any}("hosts" => ["host1"]))
    @test_throws ArgumentError DistSSHQueue.config_host_names(Dict{String,Any}("hosts" => "parent"))
    @test_throws ArgumentError DistSSHQueue.config_host_names(
        Dict{String,Any}("hosts" => ["parent"], "allowed" => ["child:host1"]),
    )
end

@testset "add-host / remove-host write hosts" begin
    mktempdir() do d
        H = DistSSHQueue.HostAllow
        cfg = joinpath(d, "config.toml")
        DistSSHQueue.write_config_template(cfg)
        DistSSHQueue.add_host_names!(cfg, ["parent", "child:host1"])
        text = read(cfg, String)
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path=cfg)) ==
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
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path=cfg)) ==
              H("parent" => nothing, "host1" => nothing)
        DistSSHQueue.add_host_names!(cfg, ["child:host1:4"])
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path=cfg)) ==
              H("parent" => nothing, "host1" => 4)
        @test occursin("child:host1:4", read(cfg, String))
        DistSSHQueue.remove_host_names!(cfg, ["parent"])
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path=cfg)) ==
              H("host1" => 4)
        DistSSHQueue.remove_host_names!(cfg, ["child:host1"])
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path=cfg)) ==
              H()
        @test occursin("hosts = []", read(cfg, String))
        @test_throws ArgumentError DistSSHQueue.remove_host_names!(cfg, ["child:host1"])
        @test_throws ArgumentError DistSSHQueue.add_host_names!(cfg, ["host1"])
        missing = joinpath(d, "none.toml")
        DistSSHQueue.add_host_names!(missing, ["child:host1"])
        @test isfile(missing)
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path=missing)) ==
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
        @test DistSSHQueue.config_host_names(DistSSHQueue.load_config(; path=old)) ==
              H("parent" => nothing, "host1" => nothing)
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
            code_jf, _, err_jf = run_setup(["--juliaup", "--force"])
            @test code_jf == 1
            @test occursin("cannot combine", err_jf)
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
    mktempdir() do home
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
            @test occursin("Pass -y / --yes to delete", out1)
            @test !occursin("Error:", err1)
            @test !occursin("Error:", out1)
            @test isfile(store)
            @test isfile(wrap)
            code2, out2, _ = capture_stdio() do
                DistSSHQueue.teardown_main(["--home", home, "-y", "--write-only"])
            end
            @test code2 == 0
            @test occursin("Removed", out2)
        end
        @test !ispath(data)
        @test !isfile(wrap)
    end
end

@testset "teardown -y removes leftover DistSSHKitQueue home" begin
    mktempdir() do home
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
            code, _, _ = capture_stdio() do
                DistSSHQueue.teardown_main(["--home", home, "-y", "--write-only"])
            end
            @test code == 0
        end
        @test !ispath(data)
        @test !ispath(legacy)
    end
end

@testset "teardown honors DISTSSHKIT_YES like DistSSHKit" begin
    mktempdir() do home
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
            @test !occursin("Would remove", err)
            @test !occursin("Pass -y / --yes to delete", err)
        end
        @test !ispath(data)
    end
end

@testset "teardown DISTSSHKIT_YES from target config [env]" begin
    mktempdir() do home
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
            code, _, _ = capture_stdio() do
                DistSSHQueue.teardown_main(["--home", home, "--write-only"])
            end
            @test code == 0
        end
        @test !ispath(data)
    end
end
