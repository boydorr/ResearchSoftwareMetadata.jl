# SPDX-License-Identifier: BSD-2-Clause

using Pkg
"ResearchSoftwareMetadata" ∈ [p.name for p in values(Pkg.dependencies())] &&
    Pkg.rm("ResearchSoftwareMetadata")
Pkg.develop(url = "https://github.com/boydorr/ResearchSoftwareMetadata.jl.git")

using ResearchSoftwareMetadata
using Documenter

DocMeta.setdocmeta!(ResearchSoftwareMetadata, :DocTestSetup,
                    :(using ResearchSoftwareMetadata); recursive = true)

makedocs(;
         modules = [ResearchSoftwareMetadata],
         authors = "Richard Reeve <richard.reeve@glasgow.ac.uk>",
         sitename = "ResearchSoftwareMetadata.jl",
         format = Documenter.HTML(;
                                  canonical = "https://boydorr.github.io/ResearchSoftwareMetadata.jl",
                                  edit_link = "main",
                                  assets = String[]),
         pages = ["Home" => "index.md",
             "Automated package checks" => "testing.md"])

deploydocs(;
           repo = "github.com/boydorr/ResearchSoftwareMetadata.jl",
           devbranch = "main")
