# SPDX-License-Identifier: BSD-2-Clause

# Pkg's canonical Project.toml key order (Pkg/src/project.jl, Julia 1.13)
const PROJECT_KEY_ORDER = ["name", "uuid", "keywords", "license", "desc",
    "version",
    "readonly", "workspace", "deps", "weakdeps", "sources",
    "extensions", "compat"]

"""
    ResearchSoftwareMetadata.project_key_order(key)

Sort key reproducing Pkg's `Project.toml` ordering: keys Pkg knows about
sort by their position in its canonical list, all other keys sort
alphabetically after them.
"""
function project_key_order(key)
    return (something(findfirst(==(key), PROJECT_KEY_ORDER),
                      length(PROJECT_KEY_ORDER) + 1), key)
end

"""
    ResearchSoftwareMetadata.order_project(project_d::AbstractDict)

Take a parsed `Project.toml` dictionary and return it as an OrderedDict
in canonical order — the order Pkg itself writes, applied recursively to
nested tables — so that files written from it are not reordered when Pkg
next edits them.
"""
function order_project(project_d::AbstractDict)
    project = OrderedDict{String, Any}()
    for key in sort!(collect(keys(project_d)); by = project_key_order)
        project[key] = order_value(project_d[key])
    end

    return project
end

order_value(val::AbstractDict) = order_project(val)
order_value(val::AbstractVector) = map(order_value, val)
order_value(val) = val

# The RSMD-specific keys that live in the [rsmd] table of Project.toml
const RSMD_KEYS = ["description", "keywords", "category", "development_status",
    "publications", "author_details"]

"""
    ResearchSoftwareMetadata.migrate_rsmd!(project_d::AbstractDict)

Move any legacy top-level RSMD keys (`description`, `keywords`,
`category`, `development_status`, `publications`, `author_details`) into
the `rsmd` table, where they now live. Existing `rsmd` entries win on
conflict. Returns the dictionary.
"""
function migrate_rsmd!(project_d::AbstractDict)
    for key in RSMD_KEYS
        if haskey(project_d, key)
            rsmd = get!(project_d, "rsmd", Dict{String, Any}())
            haskey(rsmd, key) ||
                (rsmd[key] = project_d[key])
            delete!(project_d, key)
        end
    end

    return project_d
end

"""
    ResearchSoftwareMetadata.read_project()

Read a `Project.toml` file in, migrate any legacy top-level RSMD keys
into the `rsmd` table, and return it in its canonical order in an
OrderedDict.
"""
function read_project(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    file = joinpath(git_dir, "Project.toml")
    return order_project(migrate_rsmd!(TOML.parsefile(file)))
end
