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
        k = DistSSHQueue.client_stage_key(proj)
        @test DistSSHQueue.client_stage_key(proj) == k
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
    @test ":- .gitignore" in opts
    @test ".distsshqueue/" in opts
    @test ".distsshkit/" in opts
    @test ".git/" in opts
end
