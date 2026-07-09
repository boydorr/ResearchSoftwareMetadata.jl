# SPDX-License-Identifier: MIT

"""
    ResearchSoftwareMetadata

`ResearchSoftwareMetadata` provides a crosswalk between `Project.toml`,
`codemeta.json`, `.zenodo.json` and the package `LICENSE` file, so that
consistent research software metadata can be picked up from a package by
Julia's General registry, GitHub and Zenodo, following the FAIR-IMPACT
Research Software MetaData (RSMD) guidelines. `Project.toml` is treated
as the authoritative source of metadata wherever possible.

The entry points are [`ResearchSoftwareMetadata.crosswalk()`](@ref),
which enforces consistency across the metadata files and the julia source
code, and [`ResearchSoftwareMetadata.increase_patch()`](@ref),
[`ResearchSoftwareMetadata.increase_minor()`](@ref) and
[`ResearchSoftwareMetadata.increase_major()`](@ref), which bump the package
version and then re-run the crosswalk.
"""
module ResearchSoftwareMetadata

using Dates
using Git
using TOML
using JSON
using DataStructures
using HTTP
using YAML

include("project.jl")
include("remotequeries.jl")
include("utils.jl")
include("crosswalk.jl")
include("versioning.jl")

end
