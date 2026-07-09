# Automated package checks

As well as running the crosswalk by hand, you can make your package's own test suite
verify that its metadata and formatting stay clean: that running
`ResearchSoftwareMetadata.crosswalk()` on the package regenerates exactly the files that
are committed (so the metadata is consistent and up to date), and that running
[JuliaFormatter](https://github.com/domluna/JuliaFormatter.jl) leaves the source code
unchanged (so the code is well formatted). If either check would change a file, the test
fails until you re-run the crosswalk or formatter and commit the result.

This is how ResearchSoftwareMetadata tests itself, and the test files are written so that
they can be copied into any other package.

## Files to copy

Copy these three files from ResearchSoftwareMetadata's
[`test/` directory](https://github.com/boydorr/ResearchSoftwareMetadata.jl/tree/main/test)
into your own package's `test/` directory:

- [`GitUtils.jl`](https://github.com/boydorr/ResearchSoftwareMetadata.jl/blob/main/test/GitUtils.jl)
  — provides `is_repo_clean`, which the other two files use to check whether the checks
  changed anything. It needs no adaptation (though you may want to change the SPDX header
  to your own package's licence identifier).
- [`clean_ResearchSoftwareMetadata.jl`](https://github.com/boydorr/ResearchSoftwareMetadata.jl/blob/main/test/clean_ResearchSoftwareMetadata.jl)
  — checks the metadata crosswalk is clean.
- [`clean_JuliaFormatter.jl`](https://github.com/boydorr/ResearchSoftwareMetadata.jl/blob/main/test/clean_JuliaFormatter.jl)
  — checks the code formatting is clean.

You can use either or both of the `clean_*.jl` files; the test-suite code below discovers
whichever ones are present.

In each `clean_*.jl` file, replace `ResearchSoftwareMetadata` in the `using` line with
your own package where it stands for the package under test, and set the SPDX header to
your package's licence (otherwise the crosswalk will rewrite it and the check will fail).
For a package called `MyPackage` with an MIT licence, the two files look like this:

```julia
# SPDX-License-Identifier: MIT

module CleanRSMD
using Test
using Git
using Logging
using MyPackage
using ResearchSoftwareMetadata

include("GitUtils.jl")
using .GitUtils

# Does not currently work on Windows runners on GitHub due to file writing issues
if !haskey(ENV, "RUNNER_OS") || ENV["RUNNER_OS"] ≠ "Windows"
    @testset "RSMD" begin
        git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
        @test isnothing(ResearchSoftwareMetadata.crosswalk())
        global_logger(SimpleLogger(stderr, Logging.Warn))
        @test_nowarn ResearchSoftwareMetadata.crosswalk()
        global_logger(SimpleLogger(stderr, Logging.Info))
        @test is_repo_clean(git_dir; strict = haskey(ENV, "RUNNER_OS"))
    end
else
    @test_broken !haskey(ENV, "RUNNER_OS") || ENV["RUNNER_OS"] ≠ "Windows"
end

end
```

```julia
# SPDX-License-Identifier: MIT

module CleanJuliaFormatter
using Test
using Git
using JuliaFormatter
using MyPackage

include("GitUtils.jl")
using .GitUtils

# Does not currently work on Windows runners on GitHub due to file writing issues
if !haskey(ENV, "RUNNER_OS") || ENV["RUNNER_OS"] ≠ "Windows"
    @testset "JuliaFormatter" begin
        git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
        @test_nowarn format(MyPackage)
        @test is_repo_clean(git_dir; strict = haskey(ENV, "RUNNER_OS"))
    end
else
    @test_broken !haskey(ENV, "RUNNER_OS") || ENV["RUNNER_OS"] ≠ "Windows"
end

end
```

The formatting check assumes a `.JuliaFormatter.toml` file in your package root defining
your formatting standard, as described at the end of the [home page](index.md).

## Running them from your test suite

Add this block to the end of your `test/runtests.jl`. It discovers any `clean_*.jl` files
in your `test/` directory and runs each one in its own testset:

```julia
rsmd = get(ENV, "RSMD_CROSSWALK", "FALSE")
if rsmd == "TRUE" || !haskey(ENV, "RUNNER_OS") # Crosswalk runner or local testing
    # Test RSMD crosswalk and other hygiene issues

    # Identify files that are checking package hygiene
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
```

The checks always run locally (when `RUNNER_OS` is not set); on GitHub runners they only
run when the `RSMD_CROSSWALK` environment variable is set to `TRUE` (see below).

Finally, add the test dependencies to your `Project.toml` — `Git`, `JuliaFormatter`,
`Logging`, `ResearchSoftwareMetadata` and `Test` need to appear in `[extras]` (with their
UUIDs) and in the `test` list in `[targets]`.

## Running them on CI

On GitHub Actions, set `RSMD_CROSSWALK: TRUE` on one canonical runner rather than the
whole matrix — formatter output can differ between Julia and JuliaFormatter versions, so
running the checks everywhere invites spurious failures. With a matrix like this
package's, that looks like:

```yaml
      - uses: julia-actions/julia-runtest@v1
        env:
          RSMD_CROSSWALK: ${{ (matrix.os == 'ubuntu-latest' && matrix.julia-version == '1') && 'TRUE' || 'FALSE' }}
```

Some things to be aware of:

- The crosswalk queries orcid.org, ror.org, spdx.org and the Julia General registry, so
  the runner needs network access, and it interrogates the git history and tags, so the
  repository must be checked out in full (`fetch-depth: 0` on `actions/checkout`).
- Windows runners are skipped by both checks (marked as broken) due to file writing
  issues.
- On CI the repository must be *strictly* clean — no staged, unstaged or untracked
  changes after the checks run. Locally the criterion is relaxed: only unstaged changes
  fail the tests, so work you have already staged doesn't stop you running the suite.
