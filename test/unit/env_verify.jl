using Test
using DistSSHQueue
using TOML

@testset "jobs store format_version" begin
    mktempdir() do d
        store = joinpath(d, "jobs.toml")
        write(
            store,
            """
            jobs = [
              { id = "x", job_format_version = 1, kind = "go", script = "s.jl", hosts = ["parent:1"], state = "queued", queued_at = "2020-01-01T00:00:00", started_at = "", finished_at = "", error = "", result_path = "", kwargs = {} },
            ]
            """,
        )
        @test_throws ArgumentError DistSSHQueue.read_jobs(store)

        store2 = joinpath(d, "jobs2.toml")
        q = Queue(; store = store2, runner = _ -> nothing)
        with_submit_project() do _, script
            id = submit!(q, script, "parent:1")
            @test !isempty(id)
        end
        raw = TOML.parsefile(store2)
        @test raw["store_format_version"] == 1
        @test only(raw["jobs"])["job_format_version"] == 1
        rows = DistSSHQueue.read_jobs(store2)
        @test only(rows).kwargs["enqueue_content_tree_hash"] isa String
        @test length(only(rows).kwargs["enqueue_content_tree_hash"]) == 40
    end
end

@testset "tree hash mismatch fails at setup" begin
    mktempdir() do d
        write_shippable_project!(d)
        script = joinpath(d, "s.jl")
        write(script, "1\n")
        j = Job(;
            kind = :go,
            script = script,
            hosts = ["parent:1"],
            kwargs = Dict{String, Any}("project" => d),
        )
        stamp_enqueue_verify!(j)
        open(joinpath(d, "Project.toml"), "a") do io
            write(io, "# drift\n")
        end
        withenv(DistSSHQueue.NO_KIT_SETUP_ENV => nothing) do
            @test_throws ErrorException DistSSHQueue._queue_kit_setup!(j, Returns(nothing))
        end
    end
end
