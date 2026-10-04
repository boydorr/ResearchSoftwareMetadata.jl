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
                      workflows = true)
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
