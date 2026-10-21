using Test

@testset "child idle watch" begin
    @testset "CPU time that keeps growing is not a hang" begin
        watch = IdleWatch(10.0; now = 0.0)
        @test observe_progress!(watch; cpu = 0, output = 0, now = 0.0) === :busy
        for t in 1:25
            @test observe_progress!(watch; cpu = t, output = 0, now = Float64(t)) === :busy
        end
        growing = IdleWatch(10.0; now = 0.0)
        @test observe_progress!(growing; cpu = 4, output = 0, now = 0.0) === :busy
        @test observe_progress!(growing; cpu = 4, output = 1, now = 10.0) === :busy
        @test observe_progress!(growing; cpu = 4, output = 1, now = 19.9) === :busy
        @test observe_progress!(growing; cpu = 4, output = 1, now = 20.0) === :idle
    end

    @testset "CPU time that stays still is a hang" begin
        watch = IdleWatch(10.0; now = 0.0)
        @test observe_progress!(watch; cpu = 5, output = 0, now = 0.0) === :busy
        @test observe_progress!(watch; cpu = 5, output = 0, now = 9.9) === :busy
        @test observe_progress!(watch; cpu = 5, output = 0, now = 10.0) === :idle
    end

    @testset "unreadable CPU time uses the wall clock" begin
        watch = IdleWatch(10.0; now = 0.0)
        @test observe_progress!(watch; cpu = nothing, output = 0, now = 9.9) === :busy
        @test observe_progress!(watch; cpu = nothing, output = 50, now = 10.0) === :wall
    end

    @testset "proc stat and ps time" begin
        stat = "42 (julia proc) R 1 1 1 0 -1 0 0 0 0 0 10 20 0"
        @test proc_stat_cpu_ticks(stat) == 30
        @test proc_stat_cpu_ticks("no paren") === nothing
        @test proc_stat_cpu_ticks("1 (x) R") === nothing
        @test ps_time_centiseconds("0:01.50") == 150
        @test ps_time_centiseconds("1:02") == 6200
        @test ps_time_centiseconds("1:02:03") == 3723 * 100
        @test ps_time_centiseconds("2-01:02:03") == (2 * 86400 + 3723) * 100
        @test ps_time_centiseconds("  ") === nothing
        @test ps_time_centiseconds("nope") === nothing
    end
end
