using Test

include(joinpath(@__DIR__, "..", "..", ".github", "downstream_public.jl"))

@testset "downstream public names" begin
    @test Base.ispublic(DistSSHQueue, :CLIENT_COMMAND_LINES)
    @test Base.ispublic(DistSSHQueue, :QUEUE_HOST_COMMAND_LINES)
    @test Base.ispublic(DistSSHQueue, :KIT_EXECUTE_KINDS)
    @test !Base.ispublic(DistSSHQueue, :leading_hop_span)
    @test !Base.ispublic(DistSSHQueue, :main)
    @test length(DOWNSTREAM_PUBLIC_ALLOW) == 2

    mktempdir() do tmp
        src = joinpath(tmp, "src")
        mkpath(src)
        write(joinpath(src, "ok.jl"), "DistSSHQueue.CLIENT_COMMAND_LINES\n")
        write(joinpath(src, "field.jl"), "DistSSHQueue.Job.id\n")
        write(joinpath(src, "allow.jl"), "DistSSHQueue.main(String[])\n")
        write(joinpath(src, "imp.jl"), "using DistSSHQueue: leading_hop_span\n")
        write(joinpath(src, "dotted.jl"), "import DistSSHQueue.main\n")
        write(joinpath(src, "pkg.jl"), "import DistSSHQueue\n")
        @test isempty(downstream_public_failures(src))

        write(joinpath(src, "bad.jl"), "DistSSHQueue._help_command_argv(String[])\n")
        fails = downstream_public_failures(src)
        @test length(fails) == 1
        @test fails[1] == "bad.jl:1: DistSSHQueue._help_command_argv is not public"
        rm(joinpath(src, "bad.jl"))

        write(
            joinpath(src, "bound.jl"),
            """
            const _QUALIFIED = (
                :_help_command_argv,
            )
            for _n in _QUALIFIED
                _bind!(DistSSHQueue, _n; export_name = false)
            end
            """,
        )
        fails = downstream_public_failures(src)
        @test length(fails) == 1
        @test startswith(fails[1], "bound.jl:")
        @test occursin("DistSSHQueue._help_command_argv is not public", fails[1])
        rm(joinpath(src, "bound.jl"))

        testdir = joinpath(tmp, "test")
        mkpath(testdir)
        write(joinpath(testdir, "skip.jl"), "DistSSHQueue._help_command_argv(String[])\n")
        @test isempty(downstream_public_failures(src))
    end

    mktempdir() do tmp
        src = joinpath(tmp, "src")
        mkpath(src)
        write(joinpath(src, "ok.jl"), "DistSSHQueue.CLIENT_COMMAND_LINES\n")
        allow = Dict{Tuple{Symbol, Symbol}, Int}(
            (:DistSSHQueue, :CLIENT_COMMAND_LINES) => 310,
        )
        fails = downstream_public_failures(src; allow = allow)
        @test fails == ["allowlist: DistSSHQueue.CLIENT_COMMAND_LINES is public; remove the #310 entry"]
    end
end
