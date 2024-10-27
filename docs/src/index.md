# ResearchSoftwareMetadata documentation

```@meta
CurrentModule = ResearchSoftwareMetadata
```

Documentation for [ResearchSoftwareMetadata](https://github.com/boydorr/ResearchSoftwareMetadata.jl).

## Summary

**ResearchSoftwareMetadata** is a [Julia](http://www.julialang.org) package that
provides functionality for to allow a crosswalk between Project.toml, codemeta.json, .zenodo.json and the package LICENSE file to allow a consistent way of providing metadata for research software which allows the Julia General Registry to pick up the same metadata as GitHub and Zenodo while following the Research Software MetaData [guidelines](https://fair-impact.github.io/RSMD-guidelines/).

## Installation

The package is registered in the `General` registry so can be
built and installed with `add`. For example:

```julia
(@v1.10) pkg> add ResearchSoftwareMetadata
   Resolving package versions...
    Updating `~/.julia/environments/v1.10/Project.toml`
  [aea672f4] + ResearchSoftwareMetadata v0.1.0
    Updating `~/.julia/environments/v1.10/Manifest.toml`

(@v1.10) pkg>
```

## Usage

First you need to add a small amount of additional metadata into your `Project.toml` file.

To  capture the license you are using and propagate it throughout the metadata files and through your julia code, add an [SPDX license identifier](https://spdx.org/licenses/) to the file:

```toml
[license]
SPDX = "BSD-2-Clause"
```

To supplement the metadata on the authors of the package, add the [ORCID](https://orcid.org) for each author and the [ROR](https://ror.org) for the organisation(s) they are affiliated with. You can add as many authors and as much or as little information as you like about each one by adding additional `[[author_details]]` blocks.

```toml
[[author_details]]
name = "Richard Reeve"
orcid = "0000-0003-2589-8091"

    [[author_details.affiliation]]
    ror = "00vtgdb53"
```

Then, from the root of your package, you can just run a crosswalk:

```julia
using Pkg

# Create a new project with ResearchSoftwareMetadata in it
Pkg.activate(; temp = true)
Pkg.add("ResearchSoftwareMetadata")

# Carry out a crosswalk between the different metadata formats
using ResearchSoftwareMetadata
ResearchSoftwareMetadata.crosswalk()
```


If you want to add in some additional metadata (the `category` of the software, or the `keywords` associated with it, or you want to increase the package version during the crosswalk, this is possible as follows:

```julia
# Add in additional metadata
ResearchSoftwareMetadata.crosswalk(category = "ecology", keywords = ["julia", "metadata", "research software", "RSMD"])

# Increase version number during crosswalk
ResearchSoftwareMetadata.increase_patch() # Bump patch version (e.g. 0.4.1 -> 0.4.2)
ResearchSoftwareMetadata.increase_minor() # Bump minor version (e.g. 0.4.1 -> 0.5.0)
ResearchSoftwareMetadata.increase_major() # Bump major version (e.g. 0.4.1 -> 1.0.0)
```

You might also consider reformatting all of your julia code to a consistent format. A `.JuliaJormatter.toml` file in the package root defines what the formatting standard should be.

```julia
Pkg.add("JuliaFormatter")
Pkg.develop("MyPackage")
using JuliaFormatter
using MyPackage
format(MyPackage)
```

## Reference guide

```@index
```

```@autodocs
Modules = [ResearchSoftwareMetadata]
```
