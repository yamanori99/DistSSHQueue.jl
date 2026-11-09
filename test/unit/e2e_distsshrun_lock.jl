using Test
using TOML

include(joinpath(@__DIR__, "..", "e2e_distsshrun_lock.jl"))

function _git_quiet(cmd)
    return run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = devnull))
end

function _write_manifest(path::AbstractString, distsshrun_entry::AbstractDict)
    data = Dict{String, Any}("deps" => Dict{String, Any}("DistSSHRun" => [distsshrun_entry]))
    open(path, "w") do io
        TOML.print(io, data)
    end
    return path
end

function _init_git_repo(dir::AbstractString; bare::Bool = false, remote::Union{Nothing, String} = nothing)
    if bare
        _git_quiet(`git init --bare $dir`)
        return dir
    end
    _git_quiet(`git -C $dir init -q`)
    _git_quiet(`git -C $dir config user.email test@example.com`)
    _git_quiet(`git -C $dir config user.name Test`)
    if remote !== nothing
        _git_quiet(`git -C $dir remote add origin $remote`)
    end
    return dir
end

function _commit_all(dir::AbstractString, msg::AbstractString)
    _git_quiet(`git -C $dir add -A`)
    _git_quiet(`git -C $dir -c commit.gpgsign=false commit -q -m $msg`)
    return readchomp(`git -C $dir rev-parse HEAD`)
end

@testset "e2e_distsshrun_lock" verbose = true begin
    @testset "git runner entry yields portable lock without path" begin
        mktempdir() do d
            manifest = joinpath(d, "Manifest.toml")
            tree = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            entry = Dict{String, Any}(
                "uuid" => EXAMPLE_DISTSSHRUN_UUID,
                "version" => "0.2.0-DEV",
                "deps" => ["Dates"],
                "repo-url" => DISTSSHRUN_REPO_URL,
                "repo-rev" => "main",
                "git-tree-sha1" => tree,
            )
            _write_manifest(manifest, entry)
            portable = runner_distsshrun_portable_lock(manifest)
            @test portable["git-tree-sha1"] == tree
            @test !haskey(portable, "path")
            @test portable["repo-rev"] == "main"
        end
    end

    @testset "path runner entry synthesizes SHA rev and tree" begin
        mktempdir() do root
            bare = joinpath(root, "remote.git")
            _init_git_repo(bare; bare = true)
            url = "file://" * abspath(bare)
            clone = abspath(joinpath(root, "clone"))
            @test _git_quiet(`git clone -q $url $clone`).exitcode == 0
            write(joinpath(clone, "Project.toml"), "name = \"DistSSHRun\"\n")
            _git_quiet(`git -C $clone config user.email test@example.com`)
            _git_quiet(`git -C $clone config user.name Test`)
            _commit_all(clone, "init")
            _git_quiet(`git -C $clone push -q origin HEAD`)
            head = readchomp(`git -C $clone rev-parse HEAD`)
            tree = readchomp(Cmd(["git", "-C", clone, "rev-parse", "HEAD^{tree}"]))
            runner = joinpath(root, "runner.toml")
            _write_manifest(
                runner,
                Dict{String, Any}(
                    "uuid" => EXAMPLE_DISTSSHRUN_UUID,
                    "version" => "0.2.0-DEV",
                    "deps" => ["Dates"],
                    "path" => clone,
                    "repo-url" => url,
                ),
            )
            portable = runner_distsshrun_portable_lock(runner)
            @test portable["repo-rev"] == head
            @test portable["git-tree-sha1"] == tree
            @test !haskey(portable, "path")
        end
    end

    @testset "unpushed HEAD is rejected" begin
        mktempdir() do root
            bare = joinpath(root, "remote.git")
            clone = joinpath(root, "clone")
            mkpath(clone)
            _init_git_repo(bare; bare = true)
            url = "file://" * abspath(bare)
            _init_git_repo(clone; remote = url)
            write(joinpath(clone, "Project.toml"), "name = \"DistSSHRun\"\n")
            _commit_all(clone, "init")
            _git_quiet(`git -C $clone push -q -u origin HEAD`)
            write(joinpath(clone, "two.txt"), "2\n")
            _commit_all(clone, "two")
            err = nothing
            try
                git_dev_distsshrun_pin(clone, url)
            catch e
                err = e
            end
            @test err isa ArgumentError
            @test occursin("not on", err.msg)
        end
    end

    @testset "dirty develop checkout is rejected" begin
        mktempdir() do root
            bare = joinpath(root, "remote.git")
            clone = joinpath(root, "clone")
            mkpath(clone)
            _init_git_repo(bare; bare = true)
            url = "file://" * abspath(bare)
            _init_git_repo(clone; remote = url)
            write(joinpath(clone, "Project.toml"), "name = \"DistSSHRun\"\n")
            _commit_all(clone, "init")
            _git_quiet(`git -C $clone push -q -u origin HEAD`)
            write(joinpath(clone, "dirty.txt"), "x\n")
            err = nothing
            try
                git_dev_distsshrun_pin(clone, url)
            catch e
                err = e
            end
            @test err isa ArgumentError
            @test occursin("uncommitted changes", err.msg)
        end
    end

    @testset "missing git metadata on runner is rejected" begin
        mktempdir() do d
            manifest = joinpath(d, "Manifest.toml")
            _write_manifest(
                manifest,
                Dict{String, Any}(
                    "uuid" => EXAMPLE_DISTSSHRUN_UUID,
                    "version" => "0.2.0-DEV",
                    "deps" => ["Dates"],
                ),
            )
            err = nothing
            try
                runner_distsshrun_portable_lock(manifest)
            catch e
                err = e
            end
            @test err isa ArgumentError
            @test occursin("git-tree-sha1", err.msg)
        end
    end

    @testset "align writes job lock without path" begin
        mktempdir() do root
            bare = joinpath(root, "remote.git")
            clone = joinpath(root, "clone")
            job = joinpath(root, "job")
            mkpath(clone)
            mkpath(job)
            _init_git_repo(bare; bare = true)
            url = "file://" * abspath(bare)
            _init_git_repo(clone; remote = url)
            write(joinpath(clone, "Project.toml"), "name = \"DistSSHRun\"\n")
            head = _commit_all(clone, "init")
            _git_quiet(`git -C $clone push -q -u origin HEAD`)
            runner = joinpath(root, "runner.toml")
            _write_manifest(
                runner,
                Dict{String, Any}(
                    "uuid" => EXAMPLE_DISTSSHRUN_UUID,
                    "version" => "0.2.0-DEV",
                    "deps" => ["Dates"],
                    "path" => clone,
                    "repo-url" => url,
                ),
            )
            write(
                joinpath(job, "Project.toml"),
                "name = \"Job\"\n[deps]\nDistSSHRun = \"$EXAMPLE_DISTSSHRUN_UUID\"\n",
            )
            write(
                joinpath(job, "Manifest.toml"),
                """
                [deps]
                DistSSHRun = [{uuid = "$EXAMPLE_DISTSSHRUN_UUID", version = "0.2.0-DEV"}]
                """,
            )
            align_example_job_distsshrun!(job; runner_manifest = runner)
            data = TOML.parsefile(joinpath(job, "Manifest.toml"))
            entry = first(data["deps"]["DistSSHRun"])
            @test !haskey(entry, "path")
            @test entry["repo-rev"] == head
            @test occursin("git-tree-sha1", keys(entry) |> collect |> join)
        end
    end

    @testset "distsshrun_general_lock DEV vs main rev rule" begin
        mktempdir() do root
            tree = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            job_manifest = joinpath(root, "job.toml")
            _write_manifest(
                job_manifest,
                Dict{String, Any}(
                    "uuid" => EXAMPLE_DISTSSHRUN_UUID,
                    "version" => "0.2.0-DEV",
                    "deps" => ["Dates"],
                    "repo-url" => DISTSSHRUN_REPO_URL,
                    "repo-rev" => "deadbeef"^5,
                    "git-tree-sha1" => tree,
                ),
            )
            runner = joinpath(root, "runner.toml")
            _write_manifest(
                runner,
                Dict{String, Any}(
                    "uuid" => EXAMPLE_DISTSSHRUN_UUID,
                    "version" => "0.2.0-DEV",
                    "deps" => ["Dates"],
                    "repo-url" => DISTSSHRUN_REPO_URL,
                    "repo-rev" => "main",
                    "git-tree-sha1" => tree,
                ),
            )
            withenv("DISTSSHQUEUE_DEV_RUN" => "1") do
                @test distsshrun_general_lock(job_manifest; runner_manifest = runner)
            end
            withenv("DISTSSHQUEUE_DEV_RUN" => "") do
                @test !distsshrun_general_lock(job_manifest; runner_manifest = runner)
                _write_manifest(
                    job_manifest,
                    Dict{String, Any}(
                        "uuid" => EXAMPLE_DISTSSHRUN_UUID,
                        "version" => "0.2.0-DEV",
                        "deps" => ["Dates"],
                        "repo-url" => DISTSSHRUN_REPO_URL,
                        "repo-rev" => "main",
                        "git-tree-sha1" => tree,
                    ),
                )
                @test distsshrun_general_lock(job_manifest; runner_manifest = runner)
            end
        end
    end
end
