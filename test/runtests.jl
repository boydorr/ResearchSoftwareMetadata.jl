# SPDX-License-Identifier: BSD-2-Clause

using Git
using Logging
using ResearchSoftwareMetadata
using TOML
using Test

function is_repo_clean(repo_path::String)
    # Get the status of the repository
    statuses = readlines(`$(Git.git()) status -s $repo_path`)

    is_clean = isempty(statuses)
    is_clean || @error "\n" * join(statuses, "\n")

    return is_clean
end

@testset "ResearchSoftwareMetadata.jl" begin
    cd("..")
    project = ResearchSoftwareMetadata.read_project()
    @test isnothing(ResearchSoftwareMetadata.crosswalk())
    @test_nowarn global_logger(SimpleLogger(stderr, Logging.Warn))
    @test_nowarn ResearchSoftwareMetadata.crosswalk()
    @test is_repo_clean(".")
    @test_nowarn ResearchSoftwareMetadata.increase_patch()
    @test_nowarn ResearchSoftwareMetadata.increase_minor()
    @test_nowarn ResearchSoftwareMetadata.increase_major()
    open("Project.toml", "w") do io
        TOML.print(io, project)
    end
    @test_nowarn ResearchSoftwareMetadata.crosswalk(update = true)
    @test is_repo_clean(".")
end
