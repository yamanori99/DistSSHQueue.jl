using Test

@testset "vendor DistSSHRun copy" begin
    mktempdir() do src
        mktempdir() do dest
            mkpath(joinpath(src, "src"))
            mkpath(joinpath(src, "downstream", "test"))
            write(joinpath(src, "Project.toml"), "name = \"DistSSHRun\"\n")
            write(joinpath(src, "src", "ok.jl"), "# ok\n")
            for name in (
                    "Manifest.toml",
                    "Manifest-v1.13.toml",
                    "JuliaManifest.toml",
                    "JuliaManifest-v1.13.toml",
                )
                write(joinpath(src, name), "# should not copy\n")
            end
            write(joinpath(src, "downstream", "Manifest.toml"), "# nested\n")
            _copy_distsshrun_vendor_tree!(src, dest)
            @test isfile(joinpath(dest, "Project.toml"))
            @test isdir(joinpath(dest, "src"))
            @test !isdir(joinpath(dest, "downstream"))
            for name in readdir(dest)
                @test !(
                    name == "Manifest.toml" ||
                        (startswith(name, "Manifest-v") && endswith(name, ".toml")) ||
                        name == "JuliaManifest.toml" ||
                        (startswith(name, "JuliaManifest-v") && endswith(name, ".toml"))
                )
            end
        end
    end
end
