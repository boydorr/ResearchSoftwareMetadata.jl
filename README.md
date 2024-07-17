# ResearchSoftwareMetadata

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://richardreeve.github.io/ResearchSoftwareMetadata.jl/stable/)
[![Build Status](https://github.com/richardreeve/ResearchSoftwareMetadata.jl/actions/workflows/testing.yml/badge.svg?branch=main)](https://github.com/richardreeve/ResearchSoftwareMetadata.jl/actions/workflows/testing.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/richardreeve/ResearchSoftwareMetadata.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/richardreeve/ResearchSoftwareMetadata.jl)
[![PkgEval](https://JuliaCI.github.io/NanosoldierReports/pkgeval_badges/R/ResearchSoftwareMetadata.svg)](https://JuliaCI.github.io/NanosoldierReports/pkgeval_badges/R/ResearchSoftwareMetadata.html)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)

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

From the root of your package:

```julia
using Pkg

# Create a new project with ResearchSoftwareMetadata in it
Pkg.activate(; temp = true)
Pkg.add("ResearchSoftwareMetadata")

# Carry out a crosswalk between the different metadata formats
using ResearchSoftwareMetadata
ResearchSoftwareMetadata.crosswalk()

# If you want to increase the package version during the crosswalk, other possibilities are:
ResearchSoftwareMetadata.increase_patch() # Bump patch version (e.g. 0.4.1 -> 0.4.2)
ResearchSoftwareMetadata.increase_minor() # Bump minor version (e.g. 0.4.1 -> 0.5.0)
ResearchSoftwareMetadata.increase_major() # Bump major version (e.g. 0.4.1 -> 1.0.0)
```

You might also consider reformatting all of your julia code to a consistent format:

```julia

Pkg.add("JuliaFormatter")
Pkg.develop("MyPackage")
using JuliaFormatter
using MyPackage
format(MyPackage)
```
