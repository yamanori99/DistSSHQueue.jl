using Test
using DistSSHQueue

@testset "client verbs need argv qhost:HOST" begin
    mktempdir() do d
        cfg = joinpath(d, "none.toml")
        store = joinpath(d, "jobs.toml")
        withenv(
            DistSSHQueue.LOCAL_QUEUE_ENV => nothing,
            DistSSHQueue.QHOST_DEFAULT_ENV => "from-env-only",
            "DISTSSHQUEUE_CONFIG" => cfg,
            "DISTSSHQUEUE_STORE" => store,
        ) do
            code, _, err = capture_stdio() do
                DistSSHQueue.main(["status"])
            end
            @test code == 1
            @test occursin("qhost:HOST", err)
            code_h, _, err_h = capture_stdio() do
                DistSSHQueue.main(["status"])
            end
            @test code_h == 1
            @test occursin("qhost:HOST", err_h)
            withenv(DistSSHQueue.LOCAL_QUEUE_ENV => "1", DistSSHQueue.QHOST_DEFAULT_ENV => nothing) do
                code_ok, out, _ = capture_stdio() do
                    DistSSHQueue.main(["status"])
                end
                @test code_ok == 0
                @test occursin("Store", out)
            end
        end
        cfg2 = joinpath(d, "after-setup.toml")
        withenv(
            DistSSHQueue.LOCAL_QUEUE_ENV => nothing,
            DistSSHQueue.QHOST_DEFAULT_ENV => nothing,
            "DISTSSHQUEUE_CONFIG" => cfg2,
            "DISTSSHQUEUE_STORE" => store,
            "DISTSSHQUEUE_NO_AUTOSERVE" => "1",
        ) do
            code_setup, _, _ = capture_stdio() do
                DistSSHQueue.main(["setup", "--config", cfg2])
            end
            @test code_setup == 0
            @test isfile(cfg2)
            code_host, out_s, err_s = capture_stdio() do
                DistSSHQueue.main(["status"])
            end
            @test code_host == 0
            @test !occursin("qhost:HOST", err_s)
            @test occursin("Store", out_s)
        end
    end
end
