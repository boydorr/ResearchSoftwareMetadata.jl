# SPDX-License-Identifier: BSD-2-Clause

using Pkg

# Update Phylo folder packages 
Pkg.activate(".")
Pkg.update()

# Update examples folder packages
if isdir("examples")
    if isfile("examples/Project.toml")
        Pkg.activate("examples")
        Pkg.rm("ResearchSoftwareMetadata")
        Pkg.update()
        Pkg.develop("ResearchSoftwareMetadata")
    end
end

# Update docs folder packages
Pkg.activate("docs")
Pkg.rm("ResearchSoftwareMetadata")
Pkg.update()
Pkg.develop("ResearchSoftwareMetadata")

# Reformat files in package
using JuliaFormatter
using ResearchSoftwareMetadata
format(ResearchSoftwareMetadata)

# Carry out crosswalk for metadata
ResearchSoftwareMetadata.crosswalk()
