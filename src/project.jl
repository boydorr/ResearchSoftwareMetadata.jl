# SPDX-License-Identifier: BSD-2-Clause

"""
    ResearchSoftwareMetadata.order_project(project_d::AbstractDict)

Take a parsed `Project.toml` dictionary and return it in its canonical
order in an OrderedDict.
"""
function order_project(project_d::AbstractDict)
    project_d = copy(project_d)
    project = OrderedDict{String, Any}()
    for key in [
        "name",
        "uuid",
        "license",
        "description",
        "keywords",
        "category",
        "development_status",
        "publications",
        "authors",
        "version",
        "deps",
        "weakdeps",
        "extensions",
        "compat",
        "author_details",
        "extras",
        "targets"
    ]
        if haskey(project_d, key)
            val = project_d[key]
            if val isa AbstractDict
                d = OrderedDict{String, Any}()
                for k2 in sort(collect(keys(val)))
                    d[k2] = val[k2]
                end
                project[key] = d
            else
                project[key] = val
            end
            delete!(project_d, key)
        end
    end
    for key in keys(project_d)
        project[key] = project_d[key]
    end

    return project
end

"""
    ResearchSoftwareMetadata.read_project()

Read a `Project.toml` file in and return it in its canonical order in
an OrderedDict.
"""
function read_project(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    file = joinpath(git_dir, "Project.toml")
    return order_project(TOML.parsefile(file))
end
