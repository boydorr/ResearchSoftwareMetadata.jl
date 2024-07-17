# SPDX-License-Identifier: BSD-2-Clause

using ResearchSoftwareMetadata
using Documenter

DocMeta.setdocmeta!(ResearchSoftwareMetadata, :DocTestSetup,
                    :(using ResearchSoftwareMetadata); recursive = true)

makedocs(;
         modules = [ResearchSoftwareMetadata],
         authors = "Richard Reeve <richard.reeve@glasgow.ac.uk>",
         sitename = "ResearchSoftwareMetadata.jl",
         format = Documenter.HTML(;
                                  canonical = "https://richardreeve.github.io/ResearchSoftwareMetadata.jl",
                                  edit_link = "main",
                                  assets = String[],),
         pages = ["Home" => "index.md"],)

deploydocs(;
           repo = "github.com/richardreeve/ResearchSoftwareMetadata.jl",
           devbranch = "main",)
