using Test

@testset "child idle watch" begin
    @testset "a compiling child is not a hang" begin
        watch = IdleWatch(300.0; now = 0.0)
        @test observe_progress!(watch; cpu = 0.0, output = 0, now = 0.0) === :busy
        for t in 1:400
            @test observe_progress!(watch; cpu = Float64(t), output = 0, now = Float64(t)) === :busy
        end
    end

    @testset "a polling child is a hang" begin
        watch = IdleWatch(300.0; now = 0.0)
        @test observe_progress!(watch; cpu = 0.0, output = 0, now = 0.0) === :busy
        for i in 1:40
            mark = observe_progress!(watch; cpu = 0.05 * i, output = 0, now = 7.5 * i)
            @test mark === (i < 40 ? :busy : :idle)
        end
    end

    @testset "one tick in a short sample is not progress" begin
        watch = IdleWatch(300.0; now = 0.0)
        @test observe_progress!(watch; cpu = 0.0, output = 0, now = 0.0) === :busy
        @test observe_progress!(watch; cpu = 0.01, output = 0, now = 0.2) === :busy
        @test observe_progress!(watch; cpu = 0.01, output = 0, now = 300.0) === :idle
    end

    @testset "output growth resets the idle window" begin
        watch = IdleWatch(10.0; now = 0.0)
        @test observe_progress!(watch; cpu = 4.0, output = 0, now = 0.0) === :busy
        @test observe_progress!(watch; cpu = 4.0, output = 1, now = 10.0) === :busy
        @test observe_progress!(watch; cpu = 4.0, output = 1, now = 19.9) === :busy
        @test observe_progress!(watch; cpu = 4.0, output = 1, now = 20.0) === :idle
        # A quiet child that already accumulated a little CPU must not look
        # busy again just because output moved the window.
        quiet = IdleWatch(300.0; now = 0.0)
        @test observe_progress!(quiet; cpu = 0.0, output = 0, now = 0.0) === :busy
        @test observe_progress!(quiet; cpu = 2.0, output = 0, now = 200.0) === :busy
        @test observe_progress!(quiet; cpu = 2.0, output = 1, now = 200.0) === :busy
        @test observe_progress!(quiet; cpu = 2.0, output = 1, now = 210.0) === :busy
        @test observe_progress!(quiet; cpu = 2.0, output = 1, now = 500.0) === :idle
    end

    @testset "a compile after a long quiet stretch is not a hang" begin
        watch = IdleWatch(300.0; now = 0.0)
        @test observe_progress!(watch; cpu = 0.0, output = 0, now = 0.0) === :busy
        @test observe_progress!(watch; cpu = 0.0, output = 0, now = 290.0) === :busy
        for t in 291:400
            @test observe_progress!(watch; cpu = Float64(t - 290), output = 0, now = Float64(t)) === :busy
        end
    end

    # 286s is not a window boundary when samples are `CHILD_POLL_S` apart.
    @testset "a compile that starts off a window boundary is not a hang" begin
        watch = IdleWatch(300.0; now = 0.0)
        compile_at = 286.0
        i = 0
        while true
            t = i * CHILD_POLL_S
            t > 400.0 && break
            cpu = t <= compile_at ? 0.0 : t - compile_at
            @test observe_progress!(watch; cpu = cpu, output = 0, now = t) === :busy
            i += 1
        end
    end

    @testset "CPU time that stays still is a hang" begin
        watch = IdleWatch(10; now = 0, min_window = 10)
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
        @test cpu_time_seconds(100) == (Sys.islinux() ? 100 / clock_ticks_per_second() : 1.0)
    end
end
