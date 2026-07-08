# SPDX-License-Identifier: BSD-2-Clause

"""
    ResearchSoftwareMetadata.split_name(full_name::AbstractString)

Split a full name into given and family names, treating the last word as
the family name. Returns a `(givenName, familyName)` tuple, where
`givenName` is `nothing` if `full_name` contains only a single word.
"""
function split_name(full_name::AbstractString)
    parts = split(strip(full_name))
    length(parts) < 2 && return nothing, String(strip(full_name))
    return join(parts[1:(end - 1)], " "), String(parts[end])
end

"""
    ResearchSoftwareMetadata.parse_author(author::AbstractString)

Parse a `Project.toml` authors entry of the form "Name <email>" into a
`(name, email)` tuple, where `email` is `nothing` if the entry contains
no email address. Tolerates a missing closing bracket on the email.
"""
function parse_author(author::AbstractString)
    m = match(r"^\s*([^<]*?)\s*<\s*([^<>\s]+?)\s*>?\s*$", author)
    isnothing(m) && return String(strip(author)), nothing
    return String(m.captures[1]), String(m.captures[2])
end

"""
    ResearchSoftwareMetadata.reconcile!(project, codemeta, proj_key, cm_key;
                                        value = nothing, default = nothing,
                                        to_cm = identity, from_cm = identity)

Reconcile a metadata field between `Project.toml` (authoritative) and
`codemeta.json`. An explicit `value` (e.g. from a keyword argument to
`crosswalk`) takes precedence and is written into both; otherwise the
`Project.toml` entry is used, fixing `codemeta.json` with a warning if it
disagrees. If the field is missing from `Project.toml` but present in
`codemeta.json`, it is backfilled into `Project.toml`. If it is absent
from both, `default` is used for `codemeta.json` (when provided) without
being backfilled. `to_cm` and `from_cm` convert values between the
`Project.toml` and `codemeta.json` representations. Returns the
`Project.toml`-side value, or `nothing` if the field is absent everywhere.
"""
function reconcile!(project, codemeta, proj_key, cm_key;
                    value = nothing, default = nothing,
                    to_cm = identity, from_cm = identity)
    if !isnothing(value)
        project[proj_key] = value
    end
    if haskey(project, proj_key)
        val = project[proj_key]
        cm_val = to_cm(val)
        if haskey(codemeta, cm_key) && codemeta[cm_key] ≠ cm_val &&
           isnothing(value)
            @warn "Fixing codemeta.json $cm_key to match Project.toml " *
                  "($(codemeta[cm_key]) ≠ $cm_val)"
        end
        codemeta[cm_key] = cm_val
        return val
    elseif haskey(codemeta, cm_key)
        val = from_cm(codemeta[cm_key])
        @info "Backfilling $proj_key into Project.toml from codemeta.json"
        project[proj_key] = val
        codemeta[cm_key] = to_cm(val)
        return val
    elseif !isnothing(default)
        codemeta[cm_key] = to_cm(default)
        return default
    end

    return nothing
end

"""
    ResearchSoftwareMetadata.get_os_from_workflows()

Returns the operating systems that the GitHub workflows associated with this package
work on. This is presumed to represent the operating systems that the software runs on.
"""
function get_os_from_workflows(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    workflow_folder = joinpath(git_dir, ".github", "workflows")
    files = filter(isfile, readdir(workflow_folder, join = true))
    oses = Set{String}()
    for file in files
        jobs = YAML.load_file(file)["jobs"]
        for job in keys(jobs)
            os = jobs[job]["runs-on"]
            if occursin(r"\${{.*}}", os)
                k2s = split(replace(os, r"\${{ *([^ ]*) *}}" => s"\1"), ".")
                os = jobs[job]["strategy"]
                for k2 in k2s
                    os = os[k2]
                end
                if os isa String
                    push!(oses, os)
                else
                    for val in os
                        push!(oses, val)
                    end
                end
            else
                push!(oses, os)
            end
        end
    end

    platforms = Set{String}()
    for os in oses
        push!(platforms,
              replace(replace(replace(os, "ubuntu" => "Linux"),
                              "windows" => "Windows"),
                      r"-.*" => ""))
    end

    return sort(collect(platforms))
end

"""
    ResearchSoftwareMetadata.author_details_from_codemeta(cm_authors)

Reconstruct a `Project.toml` `author_details` array from the `author`
array of a `codemeta.json` file. Each entry contains a `name`, plus an
`orcid`, an `email` and an `affiliation` array where available.
"""
function author_details_from_codemeta(cm_authors)
    details = OrderedDict{String, Any}[]
    for author in cm_authors
        detail = OrderedDict{String, Any}()
        if haskey(author, "givenName") && haskey(author, "familyName")
            detail["name"] = author["givenName"] * " " * author["familyName"]
        elseif haskey(author, "name")
            detail["name"] = author["name"]
        end
        id = get(author, "id", "")
        if startswith(id, "https://orcid.org/")
            detail["orcid"] = replace(id, "https://orcid.org/" => "")
        end
        if haskey(author, "email")
            detail["email"] = author["email"]
        end
        if haskey(author, "affiliation")
            affiliations = author["affiliation"]
            affiliations isa Vector || (affiliations = [affiliations])
            orgs = OrderedDict{String, Any}[]
            for org in affiliations
                d = OrderedDict{String, Any}()
                identifier = get(org, "identifier", "")
                if startswith(identifier, "https://ror.org/")
                    d["ror"] = replace(identifier, "https://ror.org/" => "")
                elseif haskey(org, "name")
                    d["name"] = org["name"]
                end
                isempty(d) || push!(orgs, d)
            end
            isempty(orgs) || (detail["affiliation"] = orgs)
        end
        push!(details, detail)
    end

    return details
end

"""
    ResearchSoftwareMetadata.author_details_from_zenodo(creators)

Reconstruct a `Project.toml` `author_details` array from the `creators`
array of a `.zenodo.json` file. Each entry contains a `name` (reversing
Zenodo's "Family, Given" format), plus an `orcid` and an `affiliation`
array where available. Zenodo does not record email addresses.
"""
function author_details_from_zenodo(creators)
    details = OrderedDict{String, Any}[]
    for creator in creators
        detail = OrderedDict{String, Any}()
        if haskey(creator, "name")
            parts = split(creator["name"], ", ")
            detail["name"] = length(parts) == 2 ?
                             parts[2] * " " * parts[1] : creator["name"]
        end
        if haskey(creator, "orcid")
            detail["orcid"] = creator["orcid"]
        end
        d = OrderedDict{String, Any}()
        if haskey(creator, "ror")
            d["ror"] = creator["ror"]
        elseif haskey(creator, "affiliation")
            d["name"] = creator["affiliation"]
        end
        isempty(d) || (detail["affiliation"] = [d])
        push!(details, detail)
    end

    return details
end

"""
    ResearchSoftwareMetadata.author_details_consistent(details, proj_authors)

Check whether a reconstructed `author_details` array is consistent with
the definitive `authors` entries in `Project.toml`. Every entry must match
an author string by name (and email when it has one), and the counts must
agree.
"""
function author_details_consistent(details, proj_authors)
    length(details) == length(proj_authors) || return false
    for detail in details
        haskey(detail, "name") || return false
        name = detail["name"]
        candidates = haskey(detail, "email") ?
                     [name * " <" * detail["email"] * ">", name] : [name]
        matches(author) = author ∈ candidates ||
                          (!haskey(detail, "email") &&
                           startswith(author, name * " <"))
        any(matches, proj_authors) || return false
    end

    return true
end
