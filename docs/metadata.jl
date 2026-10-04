# SPDX-License-Identifier: MIT

using Pkg

# Update the package's own dependencies
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
        Pkg.develop(path = ".")
    end
end

# Update docs folder packages
Pkg.activate("docs")
Pkg.update()

# Reformat files in package
using JuliaFormatter
using ResearchSoftwareMetadata
format(ResearchSoftwareMetadata)

# Carry out crosswalk for metadata
ResearchSoftwareMetadata.crosswalk()
