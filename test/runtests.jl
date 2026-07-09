# SPDX-License-Identifier: MIT

using Git
using JSON
using Logging
using ResearchSoftwareMetadata
using TOML
using Test

include("GitUtils.jl")
using .GitUtils

@testset "Version bumping" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    project = ResearchSoftwareMetadata.read_project()
    @test_nowarn global_logger(SimpleLogger(stderr, Logging.Warn))
    @test_nowarn ResearchSoftwareMetadata.increase_patch()
    @test_nowarn ResearchSoftwareMetadata.increase_minor()
    @test_nowarn ResearchSoftwareMetadata.increase_major()
    open(joinpath(git_dir, "Project.toml"), "w") do io
        return TOML.print(io, project)
    end
    @test_nowarn ResearchSoftwareMetadata.crosswalk(update = true)
    @test is_repo_clean(git_dir)
end

@testset "Failed metadata lookups" begin
    @test isnothing(ResearchSoftwareMetadata.get_person_from_orcid("0000-0000-0000-0000"))
    @test isnothing(ResearchSoftwareMetadata.get_organisation_from_ror("invalid"))
end

@testset "split_name" begin
    @test ResearchSoftwareMetadata.split_name("Ann B Smith") ==
          ("Ann B", "Smith")
    @test ResearchSoftwareMetadata.split_name("Plato") == (nothing, "Plato")
end

function make_fixture(dir; license = "MIT", extra = "", author_details = true)
    project_content = """
                      name = "RSMDFixture"
                      uuid = "d9a1c9c6-91f3-4f9a-8b4a-9b4c8d3a1e2f"
                      license = "$license"
                      authors = ["Ann B Smith <ann@example.com>"]
                      version = "0.1.0"
                      $extra
                      """
    if author_details
        project_content *= """

                           [[author_details]]
                           name = "Ann B Smith"
                           email = "ann@example.com"
                           """
    end
    open(joinpath(dir, "Project.toml"), "w") do io
        return write(io, project_content)
    end
    src_content = """
                  # SPDX-License-Identifier: $license

                  module RSMDFixture
                  end
                  """
    mkpath(joinpath(dir, "src"))
    open(joinpath(dir, "src", "RSMDFixture.jl"), "w") do io
        return write(io, src_content)
    end
    mkpath(joinpath(dir, ".github", "workflows"))
    open(joinpath(dir, ".github", "workflows", "testing.yaml"), "w") do io
        return write(io,
                     """
                     name: CI
                     on: push
                     jobs:
                       test:
                         runs-on: ubuntu-latest
                         steps:
                           - uses: actions/checkout@v4
                     """)
    end
    run(`$(Git.git()) -C $dir init -q -b main`)
    run(`$(Git.git()) -C $dir remote add origin
         https://github.com/example/RSMDFixture.jl`)
    run(`$(Git.git()) -C $dir add -A`)
    run(`$(Git.git()) -C $dir -c user.name=Test
         -c user.email=test@example.com commit -q -m Fixture`)

    return project_content, src_content
end

@testset "Crosswalk without ORCIDs" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    mktempdir() do dir
        make_fixture(dir)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test length(codemeta["author"]) == 1
        author = codemeta["author"][1]
        @test author["givenName"] == "Ann B"
        @test author["familyName"] == "Smith"
        @test author["email"] == "ann@example.com"
        @test !haskey(author, "id")
        zenodo = JSON.parsefile(joinpath(dir, ".zenodo.json"))
        @test [c["name"] for c in zenodo["creators"]] == ["Smith, Ann B"]
    end
end

@testset "Project.toml as metadata source" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    doi = "10.5281/zenodo.12789179"
    extra = """
            description = "A fixture package"
            keywords = ["fixture", "metadata"]
            category = "metadata"
            development_status = "wip"
            publications = ["$doi"]
            """
    mktempdir() do dir
        make_fixture(dir, extra = extra)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["description"] == "A fixture package"
        @test codemeta["keywords"] == ["fixture", "metadata"]
        @test codemeta["applicationCategory"] == "metadata"
        @test codemeta["developmentStatus"] == "wip"
        @test codemeta["referencePublication"] == ["https://doi.org/$doi"]
        zenodo = JSON.parsefile(joinpath(dir, ".zenodo.json"))
        @test zenodo["description"] == "A fixture package"
        @test zenodo["keywords"] == ["fixture", "metadata"]
        @test any(d -> get(d, "scheme", "") == "doi" &&
                       d["identifier"] == doi &&
                       d["relation"] == "isSupplementTo",
                  zenodo["related_identifiers"])
    end
end

@testset "Reconstruct author_details" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    # From codemeta.json
    mktempdir() do dir
        make_fixture(dir, author_details = false)
        open(joinpath(dir, "codemeta.json"), "w") do io
            return write(io,
                         """
                         {
                             "author": [
                                 {
                                     "type": "Person",
                                     "givenName": "Ann B",
                                     "familyName": "Smith",
                                     "email": "ann@example.com",
                                     "affiliation": [
                                         {
                                             "type": "Organization",
                                             "name": "Example University"
                                         }
                                     ]
                                 }
                             ]
                         }
                         """)
        end
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        project = TOML.parsefile(joinpath(dir, "Project.toml"))
        @test haskey(project["rsmd"], "author_details")
        detail = project["rsmd"]["author_details"][1]
        @test detail["name"] == "Ann B Smith"
        @test detail["email"] == "ann@example.com"
        @test detail["affiliation"][1]["name"] == "Example University"
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test length(codemeta["author"]) == 1
    end
    # From .zenodo.json when codemeta.json is missing
    mktempdir() do dir
        make_fixture(dir, author_details = false)
        open(joinpath(dir, ".zenodo.json"), "w") do io
            return write(io,
                         """
                         {
                             "creators": [
                                 {
                                     "name": "Smith, Ann B",
                                     "affiliation": "Example University"
                                 }
                             ]
                         }
                         """)
        end
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        project = TOML.parsefile(joinpath(dir, "Project.toml"))
        detail = project["rsmd"]["author_details"][1]
        @test detail["name"] == "Ann B Smith"
        @test !haskey(detail, "email")
        @test detail["affiliation"][1]["name"] == "Example University"
    end
    # Inconsistent with authors, so rebuilt from Project.toml alone
    mktempdir() do dir
        make_fixture(dir, author_details = false)
        open(joinpath(dir, "codemeta.json"), "w") do io
            return write(io,
                         """
                         {
                             "author": [
                                 {
                                     "type": "Person",
                                     "givenName": "Someone",
                                     "familyName": "Else"
                                 }
                             ]
                         }
                         """)
        end
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        project = TOML.parsefile(joinpath(dir, "Project.toml"))
        @test project["rsmd"]["author_details"] ==
              [Dict("name" => "Ann B Smith", "email" => "ann@example.com")]
        # authors is definitive, so the inconsistent codemeta author goes
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test [a["familyName"] for a in codemeta["author"]] == ["Smith"]
    end
end

@testset "Add new author from authors" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    mktempdir() do dir
        make_fixture(dir)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        # Add an author to `authors` alone, with a missing closing bracket
        # to check the entry gets normalised
        toml = joinpath(dir, "Project.toml")
        project = TOML.parsefile(toml)
        push!(project["authors"], "Bob Jones <bob@example.com")
        open(toml, "w") do io
            return TOML.print(io, project)
        end
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        project = TOML.parsefile(toml)
        @test project["authors"] ==
              ["Ann B Smith <ann@example.com>", "Bob Jones <bob@example.com>"]
        details = project["rsmd"]["author_details"]
        @test length(details) == 2
        @test details[2]["name"] == "Bob Jones"
        @test details[2]["email"] == "bob@example.com"
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test length(codemeta["author"]) == 2
        @test codemeta["author"][2]["givenName"] == "Bob"
        @test codemeta["author"][2]["familyName"] == "Jones"
        zenodo = JSON.parsefile(joinpath(dir, ".zenodo.json"))
        @test [c["name"] for c in zenodo["creators"]] ==
              ["Smith, Ann B", "Jones, Bob"]
    end
end

@testset "Backfill Project.toml from codemeta.json" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    mktempdir() do dir
        make_fixture(dir)
        open(joinpath(dir, "codemeta.json"), "w") do io
            return write(io,
                         """
                         {
                             "description": "A fixture package",
                             "keywords": ["fixture", "metadata"],
                             "applicationCategory": "metadata"
                         }
                         """)
        end
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        project = TOML.parsefile(joinpath(dir, "Project.toml"))
        @test project["rsmd"]["description"] == "A fixture package"
        @test project["rsmd"]["keywords"] == ["fixture", "metadata"]
        @test project["rsmd"]["category"] == "metadata"
        # Defaults are not backfilled into Project.toml
        @test !haskey(project["rsmd"], "development_status")
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["developmentStatus"] == "active"
    end
end

@testset "Propagate Project.toml changes with update" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    extra = """
            description = "A fixture package"
            category = "metadata"
            """
    # With update = true, deliberate Project.toml changes propagate with @info
    mktempdir() do dir
        make_fixture(dir, extra = extra)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir, build = true))
        cd(git_dir) # crosswalk leaves the working directory changed
        toml = joinpath(dir, "Project.toml")
        project = TOML.parsefile(toml)
        project["license"] = "BSD-2-Clause"
        project["rsmd"]["description"] = "An updated fixture package"
        open(toml, "w") do io
            return TOML.print(io, project)
        end
        @test_nowarn ResearchSoftwareMetadata.crosswalk(dir, update = true)
        cd(git_dir)
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["license"] == "https://spdx.org/licenses/BSD-2-Clause"
        @test codemeta["description"] == "An updated fixture package"
        zenodo = JSON.parsefile(joinpath(dir, ".zenodo.json"))
        @test zenodo["license"] == "BSD-2-Clause"
        @test zenodo["description"] == "An updated fixture package"
        @test occursin("Redistribution",
                       read(joinpath(dir, "LICENSE"), String))
        src = readlines(joinpath(dir, "src", "RSMDFixture.jl"))
        @test src[1] == "# SPDX-License-Identifier: BSD-2-Clause"
    end
    # Without update, a license mismatch is an error and is not propagated
    mktempdir() do dir
        make_fixture(dir, extra = extra)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir, build = true))
        cd(git_dir) # crosswalk leaves the working directory changed
        toml = joinpath(dir, "Project.toml")
        project = TOML.parsefile(toml)
        project["license"] = "BSD-2-Clause"
        open(toml, "w") do io
            return TOML.print(io, project)
        end
        @test_logs (:error, r"License mismatch") match_mode=:any ResearchSoftwareMetadata.crosswalk(dir)
        cd(git_dir)
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["license"] == "https://spdx.org/licenses/MIT"
    end
end

@testset "Failed crosswalk leaves files unchanged" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    mktempdir() do dir
        # An invalid SPDX identifier makes the license lookup fail
        project_content, src_content = make_fixture(dir,
                                                    license = "Not-A-License")
        @test_throws ErrorException ResearchSoftwareMetadata.crosswalk(dir)
        cd(git_dir) # crosswalk leaves the working directory changed
        @test read(joinpath(dir, "Project.toml"), String) == project_content
        @test read(joinpath(dir, "src", "RSMDFixture.jl"), String) ==
              src_content
        @test !isfile(joinpath(dir, "codemeta.json"))
        @test !isfile(joinpath(dir, ".zenodo.json"))
        @test !isfile(joinpath(dir, "LICENSE"))
    end
end

rsmd = get(ENV, "RSMD_CROSSWALK", "FALSE")
if rsmd == "TRUE" || !haskey(ENV, "RUNNER_OS") # Crosswalk runner or local testing
    # Test RSMD crosswalk and other hygiene issues

    # Identify files that are checking package hygiene; use @__DIR__ because
    # crosswalk() in earlier testsets leaves the working directory changed
    cleanbase = map(file -> replace(file, r"clean_(.*).jl$" => s"\1"),
                    filter(str -> occursin(r"^clean_.*\.jl$", str),
                           readdir(@__DIR__)))

    if length(cleanbase) > 0
        @info "Crosswalk and clean testing:"
        @testset begin
            for c in cleanbase
                println("    = $c")
            end
            println()

            @testset for c in cleanbase
                fn = "clean_$c.jl"
                println("    * Verifying $c.jl ...")
                include(fn)
            end
        end
    end
end
