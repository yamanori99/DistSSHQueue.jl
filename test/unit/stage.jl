using Test
using DistSSHQueue

@testset "qhost stage path rewrite" begin
    mktempdir() do d
        proj = joinpath(d, "job")
        mkpath(proj)
        script = joinpath(proj, "S.jl")
        write(script, "1\n")
        outdir = joinpath(proj, "out", "x")
        remote = "~/.distsshqueue/stage/abc"
        payload = [
            "go",
            "child:w:1",
            "--output-dir",
            outdir,
            "S.jl",
        ]
        got = DistSSHQueue.rewrite_payload_paths(payload, proj, remote)
        @test got[1] == "go"
        @test got[2] == "child:w:1"
        @test got[3] == "--output-dir"
        @test got[4] == remote * "/out/x"
        @test got[5] == remote * "/S.jl"
        @test DistSSHQueue.rewrite_one_path("parent:1", proj, remote) == "parent:1"
        @test DistSSHQueue.remote_stage_root("abc") == remote
        k = DistSSHQueue.new_job_id()
        @test DistSSHQueue.new_job_id() != k
        @test occursin(r"^[0-9a-fA-F-]{36}$", k)
        @test DistSSHQueue.remote_stage_root(k; home="/qh") == "/qh/.distsshqueue/stage/" * k
    end
    @test DistSSHQueue.should_stage("status", ["--interval", "1"]) == false
    @test DistSSHQueue.should_submit_ticket("submit", ["go", "S.jl"])
    @test DistSSHQueue.should_submit_ticket("go", ["S.jl"]) == false
    @test DistSSHQueue.should_submit_ticket("status", ["--interval", "1"]) == false
    withenv(DistSSHQueue.NO_STAGE_ENV => "1") do
        @test DistSSHQueue.staging_enabled() == false
        @test DistSSHQueue.should_stage("submit", ["go", "S.jl"]) == false
        @test DistSSHQueue.should_submit_ticket("submit", ["go", "S.jl"])
    end
    opts = DistSSHQueue.stage_rsync_push_opts("ssh -o BatchMode=yes")
    @test opts[1] == "-az"
    @test !("--info=progress2" in opts)
    @test ":- .gitignore" in opts
    @test ".distsshqueue/" in opts
    @test ".distsshkit/" in opts
    @test ".git/" in opts
    @test "--info=progress2" in DistSSHQueue.stage_rsync_push_opts("ssh"; progress=true)
    buf = IOBuffer()
    DistSSHQueue.print_rsync_start("qh", "/Users/me/.distsshqueue/stage/abc"; io=buf)
    @test occursin("rsync → qh:", String(take!(buf)))
    buf2 = IOBuffer()
    DistSSHQueue.print_rsync_start("qh", "/tmp/leaf"; pulling=true, io=buf2)
    @test occursin("rsync ← qh:", String(take!(buf2)))
    withenv("DISTSSHKIT_QUIET" => "1") do
        bufq = IOBuffer()
        DistSSHQueue.print_rsync_start("qh", "/x"; io=bufq)
        @test isempty(String(take!(bufq)))
        @test DistSSHQueue.rsync_progress_on(["--progress"]) == false
    end
    withenv("DISTSSHKIT_QUIET" => nothing, "DISTSSHKIT_PROGRESS" => "1") do
        @test DistSSHQueue.rsync_progress_on() == true
    end
    withenv("DISTSSHKIT_QUIET" => nothing, "DISTSSHKIT_PROGRESS" => nothing) do
        @test DistSSHQueue.rsync_progress_on() == false
        @test DistSSHQueue.rsync_progress_on(["go", "--progress", "S.jl"]) == true
    end
    fetch_h = sprint(io -> DistSSHQueue.print_queue_command_usage(io, "fetch"))
    @test occursin("--progress", fetch_h)
    @test occursin("progress2", fetch_h)
end
