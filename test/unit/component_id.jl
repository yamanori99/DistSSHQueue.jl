using Test
using DistSSHQueue
using DistSSHRun.DistSSHBase: src_component_digest
using TOML

function _queue_repo_root()::String
    return abspath(joinpath(@__DIR__, "..", ".."))
end

function _component_id_matches_project!(mod::Module, project_file::AbstractString)
    id = getfield(mod, :COMPONENT_ID)
    proj = TOML.parsefile(String(project_file))
    @test String(getproperty(id, :name)) == string(proj["name"])
    @test getproperty(id, :uuid) == Base.UUID(string(proj["uuid"]))
    @test String(getproperty(id, :version)) == string(proj["version"])
    @test Int(getproperty(id, :schema)) == 1
    dig = String(getproperty(id, :digest))
    @test !isempty(dig)
    @test length(dig) == 64
    return nothing
end

@testset "COMPONENT_ID" begin
    root = _queue_repo_root()

    @testset "literals match Project.toml and src digest" begin
        _component_id_matches_project!(DistSSHQueue, joinpath(root, "Project.toml"))
        queue_src = joinpath(root, "src")
        @test DistSSHQueue.COMPONENT_ID.digest ==
            src_component_digest(queue_src, DistSSHQueue._QUEUE_SRC_FILES)
    end
end