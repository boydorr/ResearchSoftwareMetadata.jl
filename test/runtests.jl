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

# Write the named workflow files into a throwaway repository directory and
# return what `f` reads from that directory
function from_workflows(f::Function, workflows::Pair{String, String}...)
    return mktempdir() do dir
        folder = joinpath(dir, ".github", "workflows")
        mkpath(folder)
        for (name, content) in workflows
            write(joinpath(folder, name), content)
        end
        return f(dir)
    end
end

# The operating systems read from the named workflow files
function workflow_os(workflows::Pair{String, String}...)
    return from_workflows(ResearchSoftwareMetadata.get_os_from_workflows,
                          workflows...)
end

# The continuous integration workflow chosen from the named workflow files
function ci_workflow(workflows::Pair{String, String}...)
    return from_workflows(ResearchSoftwareMetadata.get_ci_workflow,
                          workflows...)
end

# A workflow of one job, `test`, whose entries are given in YAML flow style,
# started by the events in `on`
function one_job(entries::String; on::String = "push")
    return "on: $on\njobs: {test: {$entries}}\n"
end

# The operating systems read from a workflow of one job
job_os(entries::String) = workflow_os("a.yaml" => one_job(entries))

# Steps that run the package's tests, through the action and through a script
const RUNTEST = "steps: [{uses: julia-actions/julia-runtest@v1}]"
const PKG_TEST = "steps: [{run: \"julia --project -e 'using Pkg; Pkg.test()'\"}]"

# A workflow that does not run the tests, on a runner the package may not use
const TAGBOT_JOB = "runs-on: ubuntu-latest, " *
                   "steps: [{uses: JuliaRegistries/TagBot@v1}]"
const TAGBOT = "TagBot.yaml" => one_job(TAGBOT_JOB, on = "issue_comment")

# A reusable workflow that lints on Linux and runs the tests on the runner it is
# given
const CALLED = """
               on:
                 workflow_call:
                   inputs:
                     os:
                       required: true
                       type: string
               jobs:
                 lint:
                   runs-on: ubuntu-latest
                   steps:
                     - run: echo lint
                 tests:
                   runs-on: \${{ inputs.os }}
                   steps:
                     - uses: julia-actions/julia-runtest@v1
               """

# A workflow of one job that calls `called.yaml` for the runner `os`
function calling(os::String; on::String = "push")
    return one_job("uses: ./.github/workflows/called.yaml, with: {os: $os}",
                   on = on)
end

@testset "Operating systems from workflows" begin
    runner_os = ResearchSoftwareMetadata.runner_os
    unknown = (:info, r"Cannot determine the operating system for job test")

    @testset "Runner labels" begin
        @test runner_os.(["ubuntu-22.04", "ubuntu-24.04-arm", "linux"]) ==
              fill("Linux", 3)
        @test runner_os.(["windows-2022", "Windows"]) == fill("Windows", 2)
        @test runner_os.(["macos-latest", "macOS-latest", "macos-14"]) ==
              fill("macOS", 3)
        @test all(isnothing, runner_os.(["self-hosted", "x64", "ARM64"]))
    end

    @testset "runs-on" begin
        @test job_os("runs-on: ubuntu-latest") == ["Linux"]
        @test workflow_os("a.yaml" => """
                          on: push
                          jobs:
                            a: {runs-on: ubuntu-22.04}
                            b: {runs-on: windows-2022}
                            c: {runs-on: macos-14}
                            d: {runs-on: macOS-latest}
                          """) == ["Linux", "Windows", "macOS"]
        # A list of labels describes one runner
        @test job_os("runs-on: [self-hosted, linux, x64]") == ["Linux"]
        # Only the labels of a runner group can name an operating system
        @test job_os("runs-on: {group: big, labels: [windows-latest]}") ==
              ["Windows"]
        @test_logs unknown @test isempty(job_os("runs-on: {group: big}"))
        @test_logs unknown @test isempty(job_os("runs-on: self-hosted"))
    end

    @testset "Matrix" begin
        on_matrix = "runs-on: '\${{ matrix.os }}', strategy: "
        @test job_os(on_matrix *
                     "{matrix: {os: [ubuntu-latest, windows-latest]}}") ==
              ["Linux", "Windows"]
        @test job_os(on_matrix * "{matrix: {os: macos-latest}}") == ["macOS"]
        @test job_os("runs-on: '\${{matrix.os}}', strategy: " *
                     "{matrix: {os: [macos-latest]}}") == ["macOS"]
        @test job_os(on_matrix * "{matrix: {include: " *
                     "[{os: ubuntu-latest}, {os: windows-latest}]}}") ==
              ["Linux", "Windows"]
        @test job_os(on_matrix * "{matrix: {os: [ubuntu-latest], include: " *
                     "[{os: macos-latest, julia: 1.11}]}}") ==
              ["Linux", "macOS"]
        # A reference to an axis the matrix does not have
        @test_logs unknown @test isempty(job_os(on_matrix *
                                                "{matrix: {julia: [1]}}"))
        # Expressions beyond a single reference are not evaluated
        fallback = "runs-on: \"\${{ matrix.os || 'ubuntu-latest' }}\", " *
                   "strategy: {matrix: {os: [ubuntu-latest]}}"
        @test_logs unknown @test isempty(job_os(fallback))
    end

    @testset "Reusable workflows" begin
        called = """
                 on:
                   workflow_call:
                     inputs:
                       os:
                         required: true
                         type: string
                 jobs:
                   tests:
                     runs-on: \${{ inputs.os }}
                     steps:
                       - run: echo tests
                 """
        with_matrix = """
                      on: push
                      jobs:
                        test:
                          strategy:
                            matrix:
                              julia-version: ['1.11', '1']
                              os: [ubuntu-latest, macOS-latest, windows-latest]
                          uses: ./.github/workflows/called.yaml
                          with:
                            julia-version: \${{ matrix.julia-version }}
                            os: \${{ matrix.os }}
                      """
        with_literal = """
                       on: push
                       jobs:
                         test:
                           uses: ./.github/workflows/called.yaml
                           with:
                             os: ubuntu-latest
                       """
        with_default = """
                       on:
                         workflow_call:
                           inputs:
                             os: {type: string, default: macos-latest}
                       jobs: {tests: {runs-on: '\${{ inputs.os }}'}}
                       """
        # The called workflow is counted through its callers, without a report
        @test_logs @test workflow_os("called.yaml" => called,
                                     "matrix.yaml" => with_matrix) ==
                         ["Linux", "Windows", "macOS"]
        @test workflow_os("called.yaml" => called,
                          "literal.yaml" => with_literal) == ["Linux"]
        @test_logs @test isempty(workflow_os("called.yaml" => called))
        # An input's default applies when the workflow is not passed one
        @test workflow_os("called.yaml" => with_default) == ["macOS"]
        # Neither a workflow in another repository nor a missing one can be read
        remote = "uses: org/repo/.github/workflows/x.yaml@main"
        @test_logs unknown @test isempty(job_os(remote))
        @test_logs unknown @test isempty(workflow_os("matrix.yaml" =>
                                                         with_matrix))
        # A workflow that calls itself is not followed for ever
        @test_logs unknown @test isempty(job_os("uses: ./.github/workflows/a.yaml"))
    end

    @testset "Jobs that run the tests" begin
        docs = "steps: [{run: make docs}]"
        # Only the runners of the jobs that run the tests are counted
        action = one_job("runs-on: windows-latest, $RUNTEST")
        script = one_job("runs-on: windows-latest, $PKG_TEST")
        @test workflow_os("CI.yaml" => action, TAGBOT) == ["Windows"]
        @test workflow_os("CI.yaml" => script, TAGBOT) == ["Windows"]
        # ... and so are only the jobs of a called workflow that run them
        @test workflow_os("called.yaml" => CALLED,
                          "CI.yaml" => calling("windows-latest")) == ["Windows"]
        # With no job running the tests, every job is counted
        no_tests = one_job("runs-on: macos-latest, $docs")
        @test workflow_os("docs.yaml" => no_tests, TAGBOT) == ["Linux", "macOS"]
        # ... as it is when the runners of those that do cannot be determined
        self_hosted = one_job("runs-on: self-hosted, $RUNTEST")
        @test_logs unknown @test workflow_os("CI.yaml" => self_hosted,
                                             TAGBOT) == ["Linux"]
        # Test jobs whose runner is unknown are reported, others are not
        two_tests = """
                    on: push
                    jobs:
                      test: {runs-on: self-hosted, $RUNTEST}
                      windows: {runs-on: windows-latest, $RUNTEST}
                      docs: {runs-on: [self-hosted, x64], $docs}
                    """
        @test_logs unknown @test workflow_os("CI.yaml" => two_tests, TAGBOT) ==
                                 ["Windows"]
    end

    @testset "Workflow files" begin
        linux = "on: push\njobs: {test: {runs-on: ubuntu-latest}}\n"
        @test workflow_os("a.yml" => linux) == ["Linux"]
        # Only YAML files are workflows, and an empty one has no jobs
        @test workflow_os("a.yaml" => linux,
                          "README.md" => "# Workflows: [unclosed\n",
                          "empty.yaml" => "") == ["Linux"]
        @test isempty(workflow_os())
        mktempdir() do dir
            @test isempty(ResearchSoftwareMetadata.get_os_from_workflows(dir))
        end
    end
end

@testset "Continuous integration workflow" begin
    tests = "runs-on: ubuntu-latest, $RUNTEST"
    no_tests = "runs-on: ubuntu-latest, steps: [{run: make docs}]"

    @testset "Workflows that run the tests" begin
        @test ci_workflow("whatever.yml" => one_job(tests), TAGBOT) ==
              "whatever.yml"
        @test ci_workflow("whatever.yml" =>
                              one_job("runs-on: ubuntu-latest, $PKG_TEST")) ==
              "whatever.yml"
        # A workflow that runs the tests is chosen over one named for them
        @test ci_workflow("CI.yaml" => one_job(no_tests),
                          "whatever.yaml" => one_job(tests)) == "whatever.yaml"
        # The tests may be run by a workflow the job calls
        @test ci_workflow("called.yaml" => CALLED,
                          "caller.yaml" => calling("ubuntu-latest")) ==
              "caller.yaml"
    end

    @testset "Choosing between workflows" begin
        on_pr = "[push, pull_request]"
        scheduled = "{schedule: [{cron: '0 2 * * 0'}]}"
        # Started by a pull request, then by a push, whatever the names
        @test ci_workflow("called.yaml" => CALLED,
                          "CI.yaml" => calling("ubuntu-latest"),
                          "checks.yaml" => calling("ubuntu-latest", on = on_pr)) ==
              "checks.yaml"
        @test ci_workflow("a.yaml" => one_job(tests, on = scheduled),
                          "b.yaml" => one_job(tests)) == "b.yaml"
        # Then by name, `testing` before `CI`, then in file name order
        @test ci_workflow("a.yaml" => one_job(tests),
                          "CI.yml" => one_job(tests),
                          "Testing.yml" => one_job(tests)) == "Testing.yml"
        @test ci_workflow("a.yaml" => one_job(tests),
                          "CI.yml" => one_job(tests)) == "CI.yml"
        @test ci_workflow("b.yaml" => one_job(tests),
                          "a.yaml" => one_job(tests)) == "a.yaml"
    end

    @testset "No workflow that runs the tests" begin
        # A conventionally named workflow is taken to be the one
        @test ci_workflow("CI.yml" => one_job(no_tests), TAGBOT) == "CI.yml"
        @test ci_workflow("CI.yaml" => one_job(no_tests),
                          "testing.yaml" => one_job(no_tests)) == "testing.yaml"
        @test isnothing(ci_workflow(TAGBOT))
        # A workflow that is only ever called does not run in its own right
        @test isnothing(ci_workflow("called.yaml" => CALLED))
        @test isnothing(ci_workflow("CI.yaml" =>
                                        one_job(tests, on = "workflow_call")))
        @test isnothing(ci_workflow())
        mktempdir() do dir
            @test isnothing(ResearchSoftwareMetadata.get_ci_workflow(dir))
        end
    end
end

function make_fixture(dir; license = "MIT", extra = "", author_details = true,
                      workflows = true,
                      remote = "https://github.com/example/RSMDFixture.jl")
    # A fixture with no license has neither the Project.toml entry nor a header
    license_entry = isnothing(license) ? "" : "license = \"$license\"\n"
    header = isnothing(license) ? "" : "# SPDX-License-Identifier: $license\n\n"
    project_content = """
                      name = "RSMDFixture"
                      uuid = "d9a1c9c6-91f3-4f9a-8b4a-9b4c8d3a1e2f"
                      $(license_entry)authors = ["Ann B Smith <ann@example.com>"]
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
    src_content = header * """
                           module RSMDFixture
                           end
                           """
    mkpath(joinpath(dir, "src"))
    open(joinpath(dir, "src", "RSMDFixture.jl"), "w") do io
        return write(io, src_content)
    end
    if workflows
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
    end
    run(`$(Git.git()) -C $dir init -q -b main`)
    isnothing(remote) || run(`$(Git.git()) -C $dir remote add origin $remote`)
    run(`$(Git.git()) -C $dir add -A`)
    run(`$(Git.git()) -C $dir -c user.name=Test
         -c user.email=test@example.com commit -q -m Fixture`)

    return project_content, src_content
end

# The contents of every file of a fixture, to show whether anything has changed
function fixture_files(dir)
    files = Dict{String, String}()
    for (root, dirs, names) in walkdir(dir)
        filter!(!=(".git"), dirs)
        for name in names
            path = joinpath(root, name)
            files[relpath(path, dir)] = read(path, String)
        end
    end

    return files
end

# The license a fixture has in each of the places that record one
function fixture_licenses(dir)
    codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
    zenodo = JSON.parsefile(joinpath(dir, ".zenodo.json"))
    return (project = TOML.parsefile(joinpath(dir, "Project.toml"))["license"],
            codemeta = codemeta["license"], zenodo = zenodo["license"],
            access = zenodo["access_right"],
            header = readline(joinpath(dir, "src", "RSMDFixture.jl")))
end

# What fixture_licenses gives when every place agrees on an open license
function all_licensed(license)
    return (project = license,
            codemeta = "https://spdx.org/licenses/" * license,
            zenodo = license, access = "open",
            header = "# SPDX-License-Identifier: " * license)
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
    # Without update, a license mismatch stops the crosswalk and changes nothing
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
        before = fixture_files(dir)
        @test_throws "License mismatch" ResearchSoftwareMetadata.crosswalk(dir)
        cd(git_dir)
        @test fixture_files(dir) == before
    end
end

@testset "Declaring the license" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    spdx = "https://spdx.org/licenses/MIT"
    codemeta_license(license) = "{\n    \"license\": \"$license\"\n}\n"

    @test ResearchSoftwareMetadata.spdx_identifier.(["MIT", spdx,
                                                        spdx * ".json",
                                                        "http://spdx.org/licenses/MIT.html"
                                                    ]) ==
          fill("MIT", 4)

    # The same license written another way in codemeta.json is not a mismatch,
    # on the run that puts it right or on the next
    for written in ("MIT", "http://spdx.org/licenses/MIT.html", spdx * ".json")
        mktempdir() do dir
            make_fixture(dir)
            write(joinpath(dir, "codemeta.json"), codemeta_license(written))
            @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
            @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
            cd(git_dir) # crosswalk leaves the working directory changed
            @test fixture_licenses(dir) == all_licensed("MIT")
        end
    end

    # A license only codemeta.json has is taken up, however it is written
    mktempdir() do dir
        make_fixture(dir, license = nothing)
        write(joinpath(dir, "codemeta.json"), codemeta_license("MIT"))
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir)
        @test fixture_licenses(dir) == all_licensed("MIT")
    end

    # No license anywhere: an error that says how to choose one, and no change
    mktempdir() do dir
        make_fixture(dir, license = nothing)
        before = fixture_files(dir)
        message = try
            ResearchSoftwareMetadata.crosswalk(dir)
            "no error"
        catch err
            sprint(showerror, err)
        end
        cd(git_dir)
        @test all(occursin(message),
                  ["No license found", "crosswalk(license = \"",
                      "https://spdx.org/licenses/", "FSF", "OSI",
                      ResearchSoftwareMetadata.SUGGESTED_LICENSES...])
        @test fixture_files(dir) == before
    end

    # Not an SPDX identifier: likewise
    mktempdir() do dir
        make_fixture(dir, license = "mit")
        before = fixture_files(dir)
        @test_throws "`mit` is not a recognised SPDX license identifier" ResearchSoftwareMetadata.crosswalk(dir)
        cd(git_dir)
        @test fixture_files(dir) == before
    end

    # The license argument gives a package its first license ...
    mktempdir() do dir
        make_fixture(dir, license = nothing)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir,
                                                           license = "MIT"))
        cd(git_dir)
        @test fixture_licenses(dir) == all_licensed("MIT")
        @test startswith(read(joinpath(dir, "LICENSE"), String), "MIT License")
        # ... and changes one that is already there, without update
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir,
                                                           license = "BSD-2-Clause"))
        cd(git_dir)
        @test fixture_licenses(dir) == all_licensed("BSD-2-Clause")
        @test occursin("Redistribution",
                       read(joinpath(dir, "LICENSE"), String))
        # One that SPDX does not have changes nothing
        before = fixture_files(dir)
        @test_throws "not a recognised SPDX" ResearchSoftwareMetadata.crosswalk(dir,
                                                                                license = "nonsense")
        cd(git_dir)
        @test fixture_files(dir) == before
    end
end

@testset "License files" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    names(dir) = basename.(ResearchSoftwareMetadata.license_files(dir))
    # The texts this package writes, from which to make other license files
    generated = Dict(map(("MIT", "BSD-2-Clause", "GPL-3.0-or-later")) do license
                         return mktempdir() do dir
                             make_fixture(dir, license = license)
                             ResearchSoftwareMetadata.crosswalk(dir)
                             cd(git_dir) # crosswalk changes the directory
                             return license =>
                                 read(joinpath(dir, "LICENSE"), String)
                         end
                     end)
    # An MIT license with someone else's notice, and in the form of older packages
    mit = replace(generated["MIT"], "Ann B Smith" => "The Original Holder")
    quoted = "The Fixture package is licensed under the MIT \"Expat\" " *
             "License:\n\n" * join("> " .* split(mit, '\n'), '\n')

    @testset "Recognising them" begin
        @test ResearchSoftwareMetadata.base_identifier.(["GPL-3.0-or-later",
                                                            "GPL-3.0-only",
                                                            "GPL-3.0+", "MIT"]) ==
              ["GPL-3.0", "GPL-3.0", "GPL-3.0", "MIT"]
        mktempdir() do dir
            for name in ("LICENSE", "Licence.md", "COPYING.txt", "LICENSE.rst",
                "NOTICE")
                write(joinpath(dir, name), "")
            end
            @test Set(names(dir)) ==
                  Set(["LICENSE", "Licence.md", "COPYING.txt"])
            file = joinpath(dir, "LICENSE")
            write(file, mit)
            @test ResearchSoftwareMetadata.holds_license(file, "MIT")
            @test !ResearchSoftwareMetadata.holds_license(file, "BSD-2-Clause")
            # Generated by this package if only the years differ
            @test ResearchSoftwareMetadata.is_generated(file,
                                                        [replace(mit,
                                                                 r"\d{4}" => "1999")])
            @test !ResearchSoftwareMetadata.is_generated(file,
                                                         [generated["MIT"]])
            write(file, generated["GPL-3.0-or-later"])
            @test ResearchSoftwareMetadata.holds_license(file, "GPL-3.0-only")
            write(file, "All rights reserved.\n")
            @test isempty(ResearchSoftwareMetadata.licenses_found(file))
        end
    end

    # A file of the user's own that holds the declared license is left exactly
    # as it is, under its own name, whatever else it says
    restricted = mit * "\nThis software may not be used on Sundays.\n"
    for (name, text) in ("LICENSE" => mit, "LICENSE.md" => quoted,
        "LICENCE" => mit, "COPYING" => mit,
        "LICENSE.txt" => restricted)
        mktempdir() do dir
            make_fixture(dir)
            write(joinpath(dir, name), text)
            @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
            @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
            cd(git_dir) # crosswalk leaves the working directory changed
            @test read(joinpath(dir, name), String) == text
            @test names(dir) == [name]
        end
    end

    # One that holds another license, or none, stops the crosswalk ...
    for text in (generated["BSD-2-Clause"], "All rights reserved.\n")
        mktempdir() do dir
            make_fixture(dir)
            write(joinpath(dir, "COPYING"), text)
            before = fixture_files(dir)
            @test_throws "COPYING does not hold the MIT license" ResearchSoftwareMetadata.crosswalk(dir)
            cd(git_dir)
            @test fixture_files(dir) == before
            # ... unless the change is deliberate, when LICENSE takes its place
            @test isnothing(ResearchSoftwareMetadata.crosswalk(dir,
                                                               update = true))
            cd(git_dir)
            @test names(dir) == ["LICENSE"]
            @test startswith(read(joinpath(dir, "LICENSE"), String),
                             "MIT License")
        end
    end

    # The file this package wrote is kept up to date when an author is added
    mktempdir() do dir
        make_fixture(dir)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        toml = joinpath(dir, "Project.toml")
        project = TOML.parsefile(toml)
        push!(project["authors"], "Bob Jones <bob@example.com>")
        open(toml, "w") do io
            return TOML.print(io, project)
        end
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir)
        @test occursin("Ann B Smith and Bob Jones",
                       read(joinpath(dir, "LICENSE"), String))
    end

    # With no license declared, the error says what a license file holds, and
    # declaring that license leaves the file alone
    mktempdir() do dir
        make_fixture(dir, license = nothing)
        write(joinpath(dir, "LICENSE.md"), quoted)
        @test_throws "LICENSE.md holds the MIT license, which `crosswalk(license = \"MIT\")`" ResearchSoftwareMetadata.crosswalk(dir)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir,
                                                           license = "MIT"))
        cd(git_dir)
        @test read(joinpath(dir, "LICENSE.md"), String) == quoted
        @test names(dir) == ["LICENSE.md"]
    end
    # The text of a GNU license does not say which versions apply
    mktempdir() do dir
        make_fixture(dir, license = nothing)
        write(joinpath(dir, "COPYING"), generated["GPL-3.0-or-later"])
        described = ResearchSoftwareMetadata.describe_license_files(dir)
        @test occursin("COPYING holds the GPL-3.0 license", described)
        @test occursin("\"GPL-3.0-or-later\")` or `crosswalk(license = " *
                       "\"GPL-3.0-only\")`", described)
    end
end

@testset "Crosswalk without workflows" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    mktempdir() do dir
        make_fixture(dir, workflows = false)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test !haskey(codemeta, "operatingSystem")
    end
    # Operating systems already in codemeta.json are kept
    mktempdir() do dir
        make_fixture(dir, workflows = false)
        open(joinpath(dir, "codemeta.json"), "w") do io
            return write(io,
                         """
                         {
                             "operatingSystem": ["Linux", "macOS"]
                         }
                         """)
        end
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["operatingSystem"] == ["Linux", "macOS"]
    end
end

@testset "Crosswalk finds the CI workflow" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    repo = "https://github.com/example/RSMDFixture.jl"
    # The workflow that runs the tests, whatever it is called
    mktempdir() do dir
        make_fixture(dir, workflows = false)
        folder = joinpath(dir, ".github", "workflows")
        mkpath(folder)
        write(joinpath(folder, "CI.yml"),
              one_job("runs-on: windows-latest, $RUNTEST"))
        write(joinpath(folder, first(TAGBOT)), last(TAGBOT))
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["continuousIntegration"] ==
              repo * "/actions/workflows/CI.yml"
        @test codemeta["codemeta:contIntegration"]["id"] ==
              codemeta["continuousIntegration"]
        @test codemeta["operatingSystem"] == ["Windows"]
    end
    # Workflows, but none for continuous integration
    mktempdir() do dir
        make_fixture(dir, workflows = false)
        folder = joinpath(dir, ".github", "workflows")
        mkpath(folder)
        write(joinpath(folder, first(TAGBOT)), last(TAGBOT))
        @test_logs (:warn, r"CI not found") match_mode=:any ResearchSoftwareMetadata.crosswalk(dir)
        cd(git_dir)
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test !haskey(codemeta, "continuousIntegration")
    end
end

@testset "Metadata files that cannot be read" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    # A missing comma between two entries of a list
    broken = """
             {
                 "creators": [
                     {"name": "Smith, Ann B"}
                     {"name": "Jones, Bob"}
                 ]
             }
             """
    mktempdir() do dir
        file = joinpath(dir, "codemeta.json")
        write(file, broken)
        @test_throws "Unable to read codemeta.json" ResearchSoftwareMetadata.read_json(file)
        write(file, "[1, 2]\n")
        @test_throws "does not hold a JSON object" ResearchSoftwareMetadata.read_json(file)
        write(file, "{\"name\": \"Fixture\"}\n")
        @test ResearchSoftwareMetadata.read_json(file)["name"] == "Fixture"
    end
    # .zenodo.json is rewritten whatever it holds, so the crosswalk carries on,
    # whether or not the file would have been used as a source of authors
    lost = (:warn, r"Unable to read \.zenodo\.json.*has been overwritten")
    for author_details in (false, true)
        mktempdir() do dir
            make_fixture(dir, author_details = author_details)
            write(joinpath(dir, ".zenodo.json"), broken)
            @test_logs lost match_mode=:any ResearchSoftwareMetadata.crosswalk(dir)
            cd(git_dir) # crosswalk leaves the working directory changed
            zenodo = JSON.parsefile(joinpath(dir, ".zenodo.json"))
            @test [c["name"] for c in zenodo["creators"]] == ["Smith, Ann B"]
        end
    end
    # codemeta.json holds metadata kept nowhere else, so the crosswalk stops
    mktempdir() do dir
        project_content, src_content = make_fixture(dir)
        write(joinpath(dir, "codemeta.json"), broken)
        @test_throws "Unable to read codemeta.json" ResearchSoftwareMetadata.crosswalk(dir)
        cd(git_dir) # crosswalk leaves the working directory changed
        @test read(joinpath(dir, "codemeta.json"), String) == broken
        @test read(joinpath(dir, "Project.toml"), String) == project_content
        @test !isfile(joinpath(dir, ".zenodo.json"))
        @test !isfile(joinpath(dir, "LICENSE"))
    end
end

@testset "Repository addresses" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    web = "https://github.com/example/RSMDFixture.jl"

    @testset "Remotes" begin
        url = ResearchSoftwareMetadata.repository_url
        @test url("https://github.com/o/r.git") == "https://github.com/o/r"
        @test url("https://github.com/o/r/") == "https://github.com/o/r"
        # Only an ending is taken off, not every ".git" in the address
        @test url("https://github.com/o/r.github.io.git") ==
              "https://github.com/o/r.github.io"
        @test url("git@github.com:o/r.jl.git") == "https://github.com/o/r.jl"
        @test url("ssh://git@github.com/o/r.git") == "https://github.com/o/r"
        @test url("ssh://git@host:2222/o/r.git") == "https://host/o/r"
        @test url("git://github.com/o/r.git") == "https://github.com/o/r"
        # A password or token does not go into the metadata, a port does
        @test url("https://user:token@github.com/o/r.git") ==
              "https://github.com/o/r"
        @test url("https://host:8443/o/r.git") == "https://host:8443/o/r"
        @test url("/some/local/path") == "/some/local/path"
    end

    # A clone made over ssh still gives web addresses throughout
    mktempdir() do dir
        make_fixture(dir, remote = "git@github.com:example/RSMDFixture.jl.git")
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["codeRepository"] == web
        @test codemeta["name"] == "RSMDFixture.jl"
        @test codemeta["issueTracker"] == web * "/issues"
        @test codemeta["readme"] == web * "/blob/HEAD/README.md"
        @test startswith(codemeta["downloadUrl"], web * "/archive/")
        zenodo = JSON.parsefile(joinpath(dir, ".zenodo.json"))
        @test zenodo["related_identifiers"][1]["identifier"] == web
    end

    # The address of the remote written as git has it is the same repository
    mktempdir() do dir
        make_fixture(dir)
        write(joinpath(dir, "codemeta.json"),
              "{\n    \"codeRepository\": " *
              "\"git@github.com:example/RSMDFixture.jl\"\n}\n")
        @test_logs (:info, r"Writing the repository in codemeta.json as") match_mode=:any ResearchSoftwareMetadata.crosswalk(dir)
        cd(git_dir)
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["codeRepository"] == web
    end

    # Without a remote there is no address to record
    mktempdir() do dir
        make_fixture(dir, remote = nothing)
        before = fixture_files(dir)
        @test_throws "has no git remote" ResearchSoftwareMetadata.crosswalk(dir)
        cd(git_dir)
        @test fixture_files(dir) == before
    end
end

@testset "Release tags" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    tag(dir, name) = run(`$(Git.git()) -C $dir tag $name`)

    # Only a v and a version number is a release of the package
    mktempdir() do dir
        make_fixture(dir)
        @test isempty(ResearchSoftwareMetadata.release_tags(dir))
        foreach(name -> tag(dir, name),
                ["v0.1.0", "v0.2", "docs-preview", "2024.1", "vnext",
                    "Sub-v1.0.0"])
        releases = ResearchSoftwareMetadata.release_tags(dir)
        @test Set(releases) == Set([(version = v"0.1.0", name = "v0.1.0"),
                      (version = v"0.2.0", name = "v0.2")])
    end

    # Other tags do not stop the crosswalk, or pass for a later release than
    # the one in Project.toml
    mktempdir() do dir
        make_fixture(dir)
        foreach(name -> tag(dir, name), ["v0.1.0", "docs-preview", "2024.1"])
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        @test TOML.parsefile(joinpath(dir, "Project.toml"))["version"] ==
              "0.1.0"
        @test JSON.parsefile(joinpath(dir, "codemeta.json"))["version"] ==
              "v0.1.0"
    end

    # A release tag is looked up under the name it has
    mktempdir() do dir
        make_fixture(dir)
        tag(dir, "v0.1")
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir)
        @test JSON.parsefile(joinpath(dir, "codemeta.json"))["version"] ==
              "v0.1.0"
    end

    # A registered package whose first release has no tag in the repository,
    # as in a shallow clone
    mktempdir() do dir
        make_fixture(dir)
        toml = joinpath(dir, "Project.toml")
        project = TOML.parsefile(toml)
        project["name"] = "Example"
        open(toml, "w") do io
            return TOML.print(io, project)
        end
        @test_throws "The repository has no tag for v" ResearchSoftwareMetadata.get_first_release_date(dir)
    end
end

@testset "Links to the default branch" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    web = "https://github.com/example/RSMDFixture.jl"
    # HEAD is the default branch of the repository, whatever it is called
    readme = web * "/blob/HEAD/README.md"

    # A crosswalk on another branch does not link to that branch
    mktempdir() do dir
        make_fixture(dir)
        run(`$(Git.git()) -C $dir checkout -q -b feature`)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir, build = true))
        cd(git_dir) # crosswalk leaves the working directory changed
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["readme"] == readme
        @test codemeta["buildInstructions"] == readme
    end

    # Links of that form which name a branch are brought into line ...
    links(readme, build) = "{\n    \"readme\": \"$readme\",\n    " *
                           "\"buildInstructions\": \"$build\"\n}\n"
    mktempdir() do dir
        make_fixture(dir)
        write(joinpath(dir, "codemeta.json"),
              links(web * "/blob/rr/feature/README.md",
                    web * "/blob/main/README.md"))
        @test_logs (:info, r"Moving readme in codemeta.json") (:info,
                                                               r"Moving buildInstructions") match_mode=:any ResearchSoftwareMetadata.crosswalk(dir)
        cd(git_dir)
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["readme"] == readme
        @test codemeta["buildInstructions"] == readme
    end
    # ... and any others are kept
    mktempdir() do dir
        make_fixture(dir)
        elsewhere = "https://example.org/RSMDFixture/"
        install = web * "/blob/feature/INSTALL.md"
        write(joinpath(dir, "codemeta.json"), links(elsewhere, install))
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir)
        codemeta = JSON.parsefile(joinpath(dir, "codemeta.json"))
        @test codemeta["readme"] == elsewhere
        @test codemeta["buildInstructions"] == install
    end
end

@testset "Source file headers" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    header = "# SPDX-License-Identifier: MIT"
    mktempdir() do dir
        make_fixture(dir)
        # Added after the fixture's commit, so none of these is tracked
        before = Dict("src/empty.jl" => "",
                      "src/bare.jl" => "x = 1\n",
                      "src/unnamed.jl" => "# SPDX-License-Identifier:\n\nx = 1\n",
                      "test/deep/with space δ.jl" => "x = 1\n",
                      "src/done.jl" => "$header\n\nx = 1",
                      "src/notebook.jl" => "### A Pluto.jl notebook ###\nx = 1",
                      "scratch/junk.jl" => "x = 1",
                      ".gitignore" => "scratch/\n")
        after = Dict("src/empty.jl" => "$header\n",
                     "src/bare.jl" => "$header\n\nx = 1\n",
                     "src/unnamed.jl" => "$header\n\nx = 1\n",
                     "test/deep/with space δ.jl" => "$header\n\nx = 1\n")
        for (name, content) in before
            mkpath(dirname(joinpath(dir, name)))
            write(joinpath(dir, name), content)
        end
        contents() = Dict(name => read(joinpath(dir, name), String)
                          for name in keys(before))

        # Only the files that need a header are listed, and listing writes nothing
        changes = ResearchSoftwareMetadata.header_changes(dir, "MIT")
        @test Dict(changes) ==
              Dict(joinpath(dir, name) => content for (name, content) in after)
        @test contents() == before

        # A file with its header, a notebook and an ignored file are not rewritten
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        @test contents() == merge(before, after)
        @test isempty(ResearchSoftwareMetadata.header_changes(dir, "MIT"))
    end
    # A tracked file that has been deleted is passed over
    mktempdir() do dir
        make_fixture(dir)
        rm(joinpath(dir, "src", "RSMDFixture.jl"))
        @test isempty(ResearchSoftwareMetadata.source_files(dir))
        @test isempty(ResearchSoftwareMetadata.header_changes(dir, "MIT"))
    end
end

# Declare the licenses that some files of a fixture are under instead of its own
function declare_additional(dir, licenses)
    toml = joinpath(dir, "Project.toml")
    project = TOML.parsefile(toml)
    get!(project, "rsmd", Dict{String, Any}())["additional_licenses"] = licenses
    open(toml, "w") do io
        return TOML.print(io, project)
    end
end

@testset "Files under another license" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    changes = ResearchSoftwareMetadata.header_changes
    other = "# SPDX-License-Identifier: BSD-3-Clause\n\nx = 1\n"
    either = "# SPDX-License-Identifier: MIT OR BSD-3-Clause\n\nx = 1\n"

    @test ResearchSoftwareMetadata.header_licenses.(["MIT", "MIT OR Apache-2.0",
                                                        "(GPL-2.0-only WITH " *
                                                        "Classpath-exception-2.0) " *
                                                        "AND MIT", ""]) ==
          [["MIT"], ["MIT", "Apache-2.0"], ["GPL-2.0-only", "MIT"], String[]]

    mktempdir() do dir
        make_fixture(dir)
        file = joinpath(dir, "src", "other.jl")
        write(file, other)
        # A license the package has not declared is an error naming the file,
        # one it has declared is left, and one it is moving from is replaced
        @test_throws "src/other.jl: BSD-3-Clause" changes(dir, "MIT")
        @test isempty(changes(dir, "MIT", additional = ["BSD-3-Clause"]))
        @test changes(dir, "MIT", previous = ["BSD-3-Clause"]) ==
              [file => "# SPDX-License-Identifier: MIT\n\nx = 1\n"]
        # Every license in a choice of licenses has to be one the package has
        write(joinpath(dir, "src", "either.jl"), either)
        @test_throws "src/either.jl: MIT OR BSD-3-Clause" changes(dir, "MIT",
                                                                  previous = ["BSD-3-Clause"])
        @test isempty(changes(dir, "MIT", additional = ["BSD-3-Clause"]))
        rm(joinpath(dir, "src", "either.jl"))

        # The crosswalk stops, deliberate change of license or not, and
        # changes nothing
        before = fixture_files(dir)
        @test_throws "additional_licenses" ResearchSoftwareMetadata.crosswalk(dir)
        @test_throws "src/other.jl: BSD-3-Clause" ResearchSoftwareMetadata.crosswalk(dir,
                                                                                     update = true)
        cd(git_dir) # crosswalk leaves the working directory changed
        @test fixture_files(dir) == before

        # Once the license is declared the file is left as it is ...
        declare_additional(dir, ["BSD-3-Clause"])
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir)
        @test read(file, String) == other
        @test fixture_licenses(dir) == all_licensed("MIT")
        project = TOML.parsefile(joinpath(dir, "Project.toml"))
        @test project["rsmd"]["additional_licenses"] == ["BSD-3-Clause"]
        # ... and stays so when the package changes license, while the files
        # that were under the package's license follow it
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir,
                                                           license = "BSD-2-Clause"))
        cd(git_dir)
        @test read(file, String) == other
        @test fixture_licenses(dir) == all_licensed("BSD-2-Clause")
    end

    # An additional license has to be one SPDX recognises
    mktempdir() do dir
        make_fixture(dir)
        declare_additional(dir, ["nonsense"])
        before = fixture_files(dir)
        @test_throws "`nonsense` in additional_licenses is not a recognised" ResearchSoftwareMetadata.crosswalk(dir)
        cd(git_dir)
        @test fixture_files(dir) == before
    end
end

@testset "Relicensing" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    relicense! = ResearchSoftwareMetadata.relicense!
    names(dir) = basename.(ResearchSoftwareMetadata.license_files(dir))
    other = "# SPDX-License-Identifier: BSD-3-Clause\n\nx = 1\n"
    relicensed = "# SPDX-License-Identifier: BSD-2-Clause\n\nx = 1\n"
    # A fixture with a license file of the user's own, in LICENSE.md, and a
    # file under another license, which is declared only if asked for
    function tangled(dir; declared)
        make_fixture(dir)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        own = replace(read(joinpath(dir, "LICENSE"), String),
                      "Ann B Smith" => "The Original Holder")
        mv(joinpath(dir, "LICENSE"), joinpath(dir, "LICENSE.md"))
        write(joinpath(dir, "LICENSE.md"), own)
        write(joinpath(dir, "src", "other.jl"), other)
        declared && declare_additional(dir, ["BSD-3-Clause"])
        return own
    end
    additional(dir) = get(TOML.parsefile(joinpath(dir, "Project.toml"))["rsmd"],
                          "additional_licenses", nothing)

    # As it stands, relicensing respects what the package has declared ...
    mktempdir() do dir
        own = tangled(dir, declared = true)
        @test isnothing(relicense!("MIT", dir))
        cd(git_dir) # crosswalk leaves the working directory changed
        @test read(joinpath(dir, "LICENSE.md"), String) == own
        @test isnothing(relicense!("BSD-2-Clause", dir))
        cd(git_dir)
        @test fixture_licenses(dir) == all_licensed("BSD-2-Clause")
        @test names(dir) == ["LICENSE"]
        @test read(joinpath(dir, "src", "other.jl"), String) == other
        @test additional(dir) == ["BSD-3-Clause"]
    end
    # ... and stops at what it has not
    mktempdir() do dir
        tangled(dir, declared = false)
        before = fixture_files(dir)
        @test_throws "src/other.jl: BSD-3-Clause" relicense!("BSD-2-Clause",
                                                             dir)
        cd(git_dir)
        @test fixture_files(dir) == before
    end

    # Overwriting everything does neither
    for declared in (true, false)
        mktempdir() do dir
            tangled(dir, declared = declared)
            @test isnothing(relicense!("BSD-2-Clause", dir,
                                       overwrite_all = true))
            cd(git_dir)
            @test fixture_licenses(dir) == all_licensed("BSD-2-Clause")
            @test names(dir) == ["LICENSE"]
            @test occursin("Ann B Smith",
                           read(joinpath(dir, "LICENSE"), String))
            @test read(joinpath(dir, "src", "other.jl"), String) == relicensed
            @test isnothing(additional(dir))
            # The package is consistent afterwards
            before = fixture_files(dir)
            @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
            cd(git_dir)
            @test fixture_files(dir) == before
        end
    end
    # ... even to the license the package has, which hands over a license
    # file of the user's own to be kept up to date
    mktempdir() do dir
        tangled(dir, declared = true)
        @test isnothing(relicense!("MIT", dir, overwrite_all = true))
        cd(git_dir)
        @test names(dir) == ["LICENSE"]
        @test occursin("Ann B Smith", read(joinpath(dir, "LICENSE"), String))
    end

    # A license that SPDX does not have changes nothing, whichever way
    for overwrite_all in (false, true)
        mktempdir() do dir
            tangled(dir, declared = true)
            before = fixture_files(dir)
            @test_throws "not a recognised SPDX" relicense!("nonsense", dir,
                                                            overwrite_all = overwrite_all)
            cd(git_dir)
            @test fixture_files(dir) == before
        end
    end

    # A file this package wrote is not lost where the file system ignores case
    mktempdir() do dir
        make_fixture(dir)
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir)
        # In two steps, as the names are one file where case is ignored
        mv(joinpath(dir, "LICENSE"), joinpath(dir, "renaming"))
        mv(joinpath(dir, "renaming"), joinpath(dir, "License"))
        @test isnothing(ResearchSoftwareMetadata.crosswalk(dir))
        cd(git_dir)
        @test names(dir) == ["LICENSE"]
        @test startswith(read(joinpath(dir, "LICENSE"), String), "MIT License")
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
