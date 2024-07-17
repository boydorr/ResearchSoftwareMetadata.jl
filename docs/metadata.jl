# SPDX-License-Identifier: BSD-2-Clause

using Pkg

# Update Phylo folder packages 
Pkg.activate(".")
Pkg.update()

# Update examples folder packages
if isdir("examples")
    if isfile("examples/Project.toml")
        Pkg.activate("examples")
        "ResearchSoftwareMetadata" ∈
        [p.name for p in values(Pkg.dependencies())] &&
            Pkg.rm("ResearchSoftwareMetadata")
        Pkg.update()
        Pkg.develop(url = "https://github.com/richardreeve/ResearchSoftwareMetadata.jl.git")
    end
end

# Update docs folder packages
Pkg.activate("docs")
Pkg.update()
"ResearchSoftwareMetadata" ∈ [p.name for p in values(Pkg.dependencies())] &&
    Pkg.rm("ResearchSoftwareMetadata")
Pkg.develop(url = "https://github.com/richardreeve/ResearchSoftwareMetadata.jl.git")

# Reformat files in package
using JuliaFormatter
using ResearchSoftwareMetadata
format(ResearchSoftwareMetadata)

# Carry out crosswalk for metadata
ResearchSoftwareMetadata.crosswalk()
