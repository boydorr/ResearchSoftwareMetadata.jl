# SPDX-License-Identifier: BSD-2-Clause

module ResearchSoftwareMetadata

using Dates
using Git
using TOML
using JSON
using DataStructures
using HTTP
using YAML

"""
    ResearchSoftwareMetadata.read_project()

Read a `Project.toml` file in and return it in its canonical order in
an OrderedDict.
"""
function read_project(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    file = joinpath(git_dir, "Project.toml")
    project_d = TOML.parsefile(file)
    project = OrderedDict{String, Any}()
    for key in [
        "name",
        "uuid",
        "authors",
        "version",
        "license",
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
    ResearchSoftwareMetadata.get_person_from_orcid(orcid::String)

Take an `ORCID` from the user and query the orcid.org API to return
a Dict containing the relevant metadata or nothing if no such ORCID exists.
"""
function get_person_from_orcid(orcid::String)
    url = "https://pub.orcid.org/v3.0/$orcid"
    headers = ["Accept" => "application/json"]
    response = HTTP.get(url, headers)

    if response.status == 200
        data = JSON.parse(String(response.body))
        name = data["person"]["name"]
        given_names = name["given-names"]["value"]
        family_name = name["family-name"]["value"]
        d = Dict("orcid" => orcid, "pid" => data["orcid-identifier"]["uri"],
                 "givenName" => given_names, "familyName" => family_name,
                 "full_name" => "$given_names $family_name")
        emails = data["person"]["emails"]["email"]
        if length(emails) ≥ 1
            d["email"] = emails[1]["email"]
            d["name_with_email"] = d["full_name"] * " <" * d["email"] * ">"
        else
            d["name_with_email"] = d["full_name"]
        end
        return d
    else
        return nothing
    end
end

"""
    ResearchSoftwareMetadata.get_organisation_from_ror(ror::String)

Take a `ROR` from the user and query the ror.org API to return
a Dict containing the relevant metadata or nothing if no such ROR exists.
"""
function get_organisation_from_ror(ror::String)
    url = "https://api.ror.org/organizations/$ror"

    response = HTTP.get(url)

    if response.status == 200
        data = JSON.parse(String(response.body))
        d = Dict("name" => data["name"], "ror" => ror, "pid" => data["id"])
        return d
    else
        return nothing
    end
end

"""
    ResearchSoftwareMetadata.get_first_release_date()

Returns the first release date of this package on Julia's `General`
Registry, or today's date if the package has not been registered yet.
"""
function get_first_release_date(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    project = read_project(git_dir)
    package = project["name"]
    url = "https://raw.githubusercontent.com/JuliaRegistries/General/master/$(package[1])/$package/Versions.toml"
    headers = ["Accept" => "application/toml"]
    response = HTTP.get(url, headers, status_exception = false)

    if response.status == 200
        data = TOML.parse(String(response.body))
        version = minimum(VersionNumber.(keys(data)))
        cd(git_dir)
        date = readchomp(`$(Git.git()) log -1 --format=%ad --date=format:%Y-%m-%d refs/tags/v$version`)
        return date
    elseif response.status == 404
        @info "No release yet on General, imputing first release will be today"
        return string(today())
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
    ResearchSoftwareMetadata.crosswalk(; category = nothing, keywords = nothing, build = false)

Runs a crosswalk across `Project.toml`, `LICENSE`, `codemeta.json` and `.zenodo.json` as
well as the julia source files to enforce consistency between the different metadata formats.
It logs warnings and errors if it identifies inconsistencies while it is editing the files.
The software category can be set with the `category` argument, likewise the `keywords` argument
can contain a vector of keyword strings. The `build` argument sets the `buildInstructions` RSMD
field - `false` leaves the instructions as is, `true` sets it to the same as the README,
and a string sets it to that value. If `update` is true, mismatches between version numbers in
`codemeta.json` are accepted.
"""
function crosswalk(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`);
                   category = nothing, keywords = nothing, build = false,
                   update = false)
    project = read_project(git_dir)
    proj_version = VersionNumber(project["version"])

    now = string(today())
    cd(git_dir)
    init = readchomp(`$(Git.git()) log --max-parents=0 --format=%ad --date=short -n 1`)
    tags = readlines(`$(Git.git()) tag -l --sort="version:refname"`)
    tag = isempty(tags) ? proj_version : maximum(VersionNumber.(tags))
    tag_date = isempty(tags) ? now :
               readchomp(`$(Git.git()) log -1 --format=%ad --date=format:%Y-%m-%d refs/tags/v$tag`)
    branch = readchomp(`$(Git.git()) branch --show-current`)
    remotes = split(readchomp(`$(Git.git()) remote`), '\n')
    urls = String[]
    for remote in remotes
        push!(urls,
              replace(readchomp(`$(Git.git()) remote get-url $remote`),
                      r"\.git" => ""))
    end

    repos = replace.(urls, r"^.*/([^/]+)$" => s"\1")

    file = joinpath(git_dir, "codemeta.json")
    codemeta = isfile(file) ?
               JSON.parsefile(file, dicttype = OrderedDict) :
               OrderedDict{String, Any}()

    codemeta["@context"] = "https://w3id.org/codemeta/3.0"
    codemeta["type"] = "SoftwareSourceCode"
    if isnothing(category)
        get!(codemeta, "applicationCategory", "ecology")
    else
        codemeta["applicationCategory"] = category
    end
    codemeta["programmingLanguage"] = "julia"
    codemeta["developmentStatus"] = "active"

    repo_index = "origin" ∈ remotes ?
                 repo_index = findfirst(==("origin"), remotes) : 1

    if haskey(codemeta, "codeRepository")
        cm_url = codemeta["codeRepository"]
        if cm_url ∉ urls
            @error "codemeta has wrong repo URL – $cm_url not in $urls – using $(remotes[repo_index])"
        else
            repo_index = findfirst(==(cm_url), urls)
        end
    end
    codemeta["codeRepository"] = urls[repo_index]

    if haskey(codemeta, "name")
        cm_name = codemeta["name"]
        if cm_name ≠ repos[repo_index]
            @error "codemeta has wrong repo repo name – $cm_name not $(repos[repo_index]) – fixing"
        end
    end
    codemeta["name"] = repos[repo_index]

    codemeta["issueTracker"] = urls[repo_index] * "/issues"

    readme = urls[repo_index] * "/blob/" * branch * "/README.md"
    cm_readme = get!(codemeta, "readme", readme)
    cm_readme == readme ||
        @info "README set to $cm_readme, not $readme"

    if build isa Bool
        if build
            codemeta["buildInstructions"] = cm_readme
        elseif !haskey(codemeta, "buildInstructions")
            @warn "No build instructions, set using `build` keyword argument"
        end
    else
        codemeta["buildInstructions"] = build
    end

    cm_created = get(codemeta, "dateCreated", "")
    if cm_created ≠ init
        @warn "Fixing creation date to first git commit: $init"
        codemeta["dateCreated"] = init
    end

    platforms = get_os_from_workflows()
    cm_platforms = sort(string.(get(codemeta, "operatingSystem", String[])))
    if length(platforms) ≠ length(cm_platforms) ||
       any(platforms .≠ cm_platforms)
        if isempty(cm_platforms)
            @info "No platform info in codemeta.json, so filling from workflows ($platforms)"
        else
            @error "codemeta platforms do not match workflows ($cm_platforms ≠ $platforms), fixing"
        end
        codemeta["operatingSystem"] = platforms
    end

    years = string(year(Date(init)))

    cm_version = VersionNumber(get!(codemeta, "version", string(proj_version)))

    if proj_version == tag
        @debug "Still on latest release version: $tag"
        codemeta["dateModified"] = tag_date
        if cm_version ≠ tag
            if !update
                @warn "Correcting codemeta tag version ($cm_version) to release tag ($tag)"
            end
            cm_version = tag
            tag_year = string(year(Date(tag_date)))
            if tag_year ≠ years
                years = years * "-" * tag_year
            end
        else
            tag_year = string(year(Date(codemeta["dateModified"])))
            if tag_year ≠ years
                years = years * "-" * tag_year
            end
        end
    elseif proj_version > tag
        @info "Preparing for new release"
        codemeta["dateModified"] = now
        if cm_version ≠ proj_version
            @info "Updating codemeta tag version ($cm_version) to " *
                  "new release ($proj_version)"
            cm_version = proj_version
            this_year = string(year(Date(now)))
            if this_year ≠ years
                years = years * "-" * this_year
            end
        else
            tag_year = string(year(Date(codemeta["dateModified"])))
            if tag_year ≠ years
                years = years * "-" * tag_year
            end
        end
    else # Project version is lower than latest release!
        @error "Project.toml version is behind release ($proj_version < $tag), fixing."
        proj_version = tag
        cm_version = tag
        codemeta["dateModified"] = tag_date
        tag_year = string(year(Date(codemeta["dateModified"])))
        if tag_year ≠ years
            years = years * "-" * tag_year
        end
    end

    first_release_date = get_first_release_date(git_dir)
    if !isnothing(first_release_date)
        if haskey(codemeta, "datePublished")
            codemeta["datePublished"] == first_release_date ||
                @warn "codemeta.json publication date inconsistent with Julia's General registry, fixing ($(codemeta["datePublished"]) ≠ $first_release_date)"
        end
        codemeta["datePublished"] = first_release_date
    end
    project["version"] = string(proj_version)
    codemeta["version"] = "v$cm_version"

    codemeta["downloadUrl"] = urls[repo_index] * "/archive/refs/tags/" *
                              codemeta["version"] * ".tar.gz"

    authors = String[]
    author_data = []
    if haskey(project, "author_details")
        for author in project["author_details"]
            if haskey(author, "orcid")
                person = get_person_from_orcid(author["orcid"])
                push!(authors, person["name_with_email"])
                if haskey(author, "name")
                    person["full_name"] == author["name"] ||
                        @warn "Name mismatch between ORCID and Project.toml: " *
                              "$(person["full_name"]) ≠ $(author["name"])"
                end
                if haskey(author, "email") && haskey(person, "email")
                    person["email"] == author["email"] ||
                        @warn "Email mismatch between ORCID and Project.toml: " *
                              "$(person["email"]) ≠ $(author["email"])"
                end
            elseif haskey(author, "name")
                if haskey(author, "email")
                    push!(authors,
                          author["name"] * " <" * author["email"] * ">")
                else
                    push!(authors, author["name"])
                end
            else
                @warn "Missing name and ORCID in authors block"
            end
        end
    else
        authors = project["authors"]
        for author in authors
            name = replace(author, r" *<.*> *$" => "")
            if '<' ∈ author
                email = replace(author, r"^.*<([^>]+)>.*$" => s"\1")
                push!(author_data, Dict("name" => name, "email" => email))
            else
                push!(author_data, Dict("name" => name))
            end
        end
        project["author_details"] = author_data
    end

    replace_authors = true
    if !isempty(authors)
        proj_authors = project["authors"]
        for author in authors
            if author ∉ proj_authors
                if lowercase(author) ∈ lowercase.(proj_authors)
                    @info "Changing case of $author in Project.toml"
                elseif any(occursin.(author, proj_authors))
                    @info "Completing $author in Project.toml"
                else
                    @error "Author $author not in $proj_authors"
                    replace_authors = false
                end
            end
        end

        if length(authors) < length(proj_authors)
            @error "Author mismatch between $authors and $proj_authors"
            replace_authors = false
        end
    end

    if replace_authors
        project["authors"] = authors
    end

    haslicense = false
    license = nothing

    if haskey(project, "license")
        proj_license = project["license"]["SPDX"]
        cm_license = "https://spdx.org/licenses/" * proj_license
        if haskey(codemeta, "license")
            if codemeta["license"] == cm_license
                haslicense = true
                license = proj_license
            else
                @error "License mismatch between Project.toml and codemeta.json: " *
                       "$(codemeta["license"]) ≠ $cm_license"
            end
        else
            codemeta["license"] = cm_license
            haslicense = true
            license = proj_license
        end
    else
        if haskey(codemeta, "license")
            project["license"] = Dict("SPDX" => replace(codemeta["license"],
                                                        "https://spdx.org/licenses/" => ""))
            haslicense = true
            license = project["license"]["SPDX"]
        else
            @warn "No license metadata"
        end
    end

    open_license = nothing
    if haslicense
        url = "https://spdx.org/licenses/$license.json"
        headers = ["Accept" => "application/json"]
        response = HTTP.get(url, headers)

        if response.status == 200
            just_names = replace.(project["authors"], r" *<[^>]+> *" => "")
            name_list = join(just_names, ", ", " and ")
            json = JSON.parse(String(response.body))
            open_license = json["isOsiApproved"]
            content = json["licenseText"]
            replaces = [r"<year>"i => years,
                r"<owners?>"i => name_list,
                r"<copyright holders?>"i => name_list,
                r"<Owner Organization Name>"i => name_list,
                r"<Asset Owner>"i => name_list,
                r"<HOLDERS?>"i => name_list,
                r"<name of author>"i => name_list,
                r"<author's name or designee>"i => name_list]
            for r in replaces
                content = replace(content, r)
            end
            file = joinpath(git_dir, "LICENSE")
            open(file, "w") do file
                return write(file, content)
            end
            file = joinpath(git_dir, "LICENSE.md")
            rm(file, force = true)
        end
    end

    file = joinpath(git_dir, "Project.toml")
    open(file, "w") do io
        return TOML.print(io, project)
    end

    # Repeat ro ensure correct order if there were elements missing
    project = read_project(git_dir)
    open(file, "w") do io
        return TOML.print(io, project)
    end

    cm_authors = get(codemeta, "author", OrderedDict{String, Any}[])
    proj_authors = project["author_details"]
    cm_from_proj = OrderedDict{String, Any}[]
    for author in proj_authors
        if haskey(author, "orcid")
            person = get_person_from_orcid(author["orcid"])
            dict = OrderedDict{String, Any}("type" => "Person")
            if haskey(person, "givenName")
                dict["givenName"] = person["givenName"]
            end
            if haskey(person, "familyName")
                dict["familyName"] = person["familyName"]
            end
            if haskey(person, "email")
                dict["email"] = person["email"]
            end
            if haskey(person, "orcid")
                dict["id"] = person["pid"]
            end
            if haskey(author, "affiliation")
                dict["affiliation"] = OrderedDict{String, String}[]
                for org in author["affiliation"]
                    d = OrderedDict("type" => "Organization")
                    if haskey(org, "ror")
                        ror = org["ror"]
                        info = get_organisation_from_ror(ror)
                        d["name"] = info["name"]
                        d["identifier"] = info["pid"]
                    else
                        d["name"] = org["name"]
                    end
                    push!(dict["affiliation"], d)
                end
            end
            push!(cm_from_proj, dict)
        end
    end

    if isempty(cm_authors)
        @info "Filling codemeta authors from Project.toml"
        codemeta["author"] = cm_from_proj
    else
        if length(cm_authors) == length(cm_from_proj)
            ids = [dict["id"] for dict in cm_from_proj]
            for dict in cm_authors
                if get(dict, "id", nothing) ∉ ids
                    @error "$dict not found in Project.toml"
                end
            end
        else
            @error "Mismatch between Project.toml and codemeta.json authors: " *
                   "$(cm_authors) ≠ $(proj_authors)"
        end
    end

    if haskey(codemeta, "continuousIntegration")
        if haskey(codemeta, "codemeta:contIntegration")
            if codemeta["continuousIntegration"] ≠
               codemeta["codemeta:contIntegration"]["id"]
                @error "Mismatch between continuousIntegration and codemeta:contIntegration, " *
                       "$(codemeta["continuousIntegration"]) ≠ $(codemeta["codemeta:contIntegration"]["id"])"
            end
        else
            codemeta["codemeta:contIntegration"] = Dict("id" => codemeta["continuousIntegration"])
        end
    else
        if haskey(codemeta, "codemeta:contIntegration")
            codemeta["continuousIntegration"] = codemeta["codemeta:contIntegration"]["id"]
        elseif isfile(".github/workflows/testing.yaml")
            @info "Using .github/workflows/testing.yaml for CI"
            codemeta["continuousIntegration"] = urls[repo_index] *
                                                "/actions/workflows/testing.yaml"
            codemeta["codemeta:contIntegration"] = Dict("id" => codemeta["continuousIntegration"])
        elseif isfile(".github/workflows/CI.yaml")
            @info "Using .github/workflows/CI.yaml for CI"
            codemeta["continuousIntegration"] = urls[repo_index] *
                                                "/actions/workflows/CI.yaml"
            codemeta["codemeta:contIntegration"] = Dict("id" => codemeta["continuousIntegration"])
        elseif isdir(".github/workflows")
            @warn "CI not found in codemeta.json, but .github/workflows exists"
        end
    end

    if isnothing(keywords)
        keywords = get(codemeta, "keywords", ["julia"])
    end
    codemeta["keywords"] = sort(keywords)

    file = joinpath(git_dir, "codemeta.json")
    open(file, "w") do io
        return JSON.print(io, codemeta, 4)
    end

    crosswalk_d = OrderedDict{String, Any}()
    crosswalk_d["title"] = codemeta["name"]
    if haskey(codemeta, "description")
        crosswalk_d["description"] = codemeta["description"]
    end
    crosswalk_d["upload_type"] = "software"
    crosswalk_d["creators"] = []
    for author in codemeta["author"]
        dict = OrderedDict{String, String}()
        dict["name"] = "$(author["familyName"]), $(author["givenName"])"
        if haskey(author, "id")
            dict["orcid"] = replace(author["id"], "https://orcid.org/" => "")
        end
        if haskey(author, "affiliation")
            affiliations = author["affiliation"]
            affiliation = affiliations isa Vector ? first(affiliations) :
                          affiliations
            if haskey(affiliation, "name")
                dict["affiliation"] = affiliation["name"]
            end
            if haskey(affiliation, "identifier")
                dict["ror"] = replace(affiliation["identifier"],
                                      "https://ror.org/" => "")
            end
        end
        push!(crosswalk_d["creators"], dict)
    end
    if !isnothing(open_license)
        crosswalk_d["access_right"] = open_license ? "open" : "closed"
    end
    crosswalk_d["license"] = project["license"]["SPDX"]
    dict = OrderedDict{String, String}()
    dict["scheme"] = "url"
    dict["identifier"] = codemeta["codeRepository"]
    dict["relation"] = "isOriginalFormOf"
    crosswalk_d["related_identifiers"] = [dict]
    crosswalk_d["keywords"] = codemeta["keywords"]

    file = joinpath(git_dir, ".zenodo.json")
    open(file, "w") do io
        return JSON.print(io, crosswalk_d, 4)
    end

    # Recursively walk through the directory
    path = joinpath(git_dir, ".git")
    notpath = joinpath(git_dir, ".github")
    for (root, _, files) in walkdir(git_dir)
        if !startswith(root, path) || startswith(root, notpath)
            for file in files
                if endswith(file, ".jl")
                    jl_file = joinpath(root, file)
                    data = readlines(jl_file)
                    if startswith(data[1], "# SPDX-License-Identifier:")
                        data[1] = "# SPDX-License-Identifier: $(project["license"]["SPDX"])"
                    else
                        pushfirst!(data, "")
                        pushfirst!(data,
                                   "# SPDX-License-Identifier: $(project["license"]["SPDX"])")
                    end
                    open(jl_file, "w") do io
                        return println.(Ref(io), data)
                    end
                end
            end
        end
    end

    return nothing
end

"""
    ResearchSoftwareMetadata.increase_patch()

Increases the `Project.toml` version number by a patch (e.g. 0.4.1 to 0.4.2), and then
runs `ResearchSoftwareMetadata.crosswalk()` to propagate this information.
"""
function increase_patch(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    project = read_project(git_dir)
    version = project["version"]
    v = VersionNumber(version)
    new_version = VersionNumber(v.major, v.minor, v.patch + 1)
    @info "Bumping patch version from $version to $new_version"
    project["version"] = string(new_version)
    file = joinpath(git_dir, "Project.toml")
    open(file, "w") do io
        return TOML.print(io, project)
    end

    return crosswalk(git_dir, update = true)
end

"""
    ResearchSoftwareMetadata.increase_minor()

Increases the `Project.toml` version number by a minor number (e.g. 0.4.1 to 0.5.0), and then
runs `ResearchSoftwareMetadata.crosswalk()` to propagate this information.
"""
function increase_minor(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    project = read_project(git_dir)
    version = project["version"]
    v = VersionNumber(version)
    new_version = VersionNumber(v.major, v.minor + 1, 0)
    @info "Bumping minor version from $version to $new_version"
    project["version"] = string(new_version)
    file = joinpath(git_dir, "Project.toml")
    open(file, "w") do io
        return TOML.print(io, project)
    end

    return crosswalk(git_dir, update = true)
end

"""
    ResearchSoftwareMetadata.increase_major()

Increases the `Project.toml` version number by a major number (e.g. 0.4.1 to 1.0.0), and then
runs `ResearchSoftwareMetadata.crosswalk()` to propagate this information.
"""
function increase_major(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    project = read_project(git_dir)
    version = project["version"]
    v = VersionNumber(version)
    new_version = VersionNumber(v.major + 1, 0, 0)
    @info "Bumping major version from $version to $new_version"
    project["version"] = string(new_version)
    file = joinpath(git_dir, "Project.toml")
    open(file, "w") do io
        return TOML.print(io, project)
    end

    return crosswalk(git_dir, update = true)
end

end
