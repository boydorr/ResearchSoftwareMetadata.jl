# SPDX-License-Identifier: MIT

"""
    ResearchSoftwareMetadata.get_person_from_orcid(orcid::String)

Take an `ORCID` from the user and query the orcid.org API to return
a Dict containing the relevant metadata or nothing if no such ORCID exists.
Throws an error if orcid.org cannot be reached or returns an unexpected
HTTP status.
"""
function get_person_from_orcid(orcid::String)
    url = "https://pub.orcid.org/v3.0/$orcid"
    headers = ["Accept" => "application/json"]
    response = HTTP.get(url, headers, status_exception = false)

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
        response.status == 404 && return nothing
        error("Unable to retrieve ORCID $orcid from orcid.org, " *
              "HTTP status $(response.status)")
    end
end

"""
    ResearchSoftwareMetadata.get_organisation_from_ror(ror::String)

Take a `ROR` from the user and query the ror.org API to return
a Dict containing the relevant metadata or nothing if no such ROR exists.
Throws an error if ror.org cannot be reached or returns an unexpected
HTTP status.
"""
function get_organisation_from_ror(ror::String)
    url = "https://api.ror.org/organizations/$ror"

    response = HTTP.get(url, status_exception = false)

    if response.status == 200
        data = JSON.parse(String(response.body))
        if haskey(data, "name")
            name = data["name"]
        elseif haskey(data, "names") && length(data["names"]) ≥ 1
            names = [record["value"]
                     for record in data["names"]
                     if "ror_display" in record["types"]]
            if length(names) ≥ 1
                name = names[1]
            else
                @warn "No display name found for ROR $ror"
                names = [record["value"]
                         for record in data["names"] if record["lang"] == "en"]
                if length(names) ≥ 1
                    name = names[1]
                else
                    @info "No English name found for ROR $ror, using first available name"
                    name = data["names"][1]["value"]
                end
            end
        else
            @error "No name found for ROR $ror"
            name = "Unknown"
        end
        d = Dict("name" => name, "ror" => ror, "pid" => data["id"])
        return d
    else
        response.status == 404 && return nothing
        error("Unable to retrieve ROR $ror from ror.org, " *
              "HTTP status $(response.status)")
    end
end

"""
    ResearchSoftwareMetadata.get_license_from_spdx(license::AbstractString)

Take an SPDX license identifier and query spdx.org to return a Dict
containing its record, including the text of the license under
`licenseText` and whether the OSI approves it under `isOsiApproved`, or
nothing if spdx.org has no license with that identifier. Throws an error
if spdx.org cannot be reached or returns an unexpected HTTP status.
"""
function get_license_from_spdx(license::AbstractString)
    url = "https://spdx.org/licenses/$license.json"
    headers = ["Accept" => "application/json"]
    response = HTTP.get(url, headers, status_exception = false)
    response.status == 200 && return JSON.parse(String(response.body))
    response.status == 404 && return nothing
    return error("Unable to fetch license text for $license from " *
                 "spdx.org, HTTP status $(response.status)")
end

"""
    ResearchSoftwareMetadata.check_doi(doi::String)

Check that a DOI resolves by querying the doi.org handle API. Returns
`true` if it resolves and `false` if it does not exist. Throws an error
if doi.org cannot be reached or returns an unexpected HTTP status.
"""
function check_doi(doi::String)
    url = "https://doi.org/api/handles/$doi"
    response = HTTP.get(url, status_exception = false)
    response.status == 200 && return true
    response.status == 404 && return false
    return error("Unable to check DOI $doi on doi.org, " *
                 "HTTP status $(response.status)")
end

"""
    ResearchSoftwareMetadata.get_first_release_date()

Returns the first release date of this package on Julia's `General`
Registry, or `nothing` if the package has not been registered. The date is
that of the repository's tag for the release. Throws an error if the
repository has no such tag, or if the registry cannot be reached or
returns an unexpected HTTP status.
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
        releases = release_tags(git_dir)
        release = findfirst(release -> release.version == version, releases)
        isnothing(release) &&
            error("The repository has no tag for v$version, the first " *
                  "release of $package in Julia's General registry, which " *
                  "is where the date of that release is taken from. Fetch " *
                  "the tags of the repository: a shallow clone has none")
        tag = releases[release].name
        return readchomp(`$(Git.git()) -C $git_dir log -1 --format=%ad --date=format:%Y-%m-%d refs/tags/$tag`)
    elseif response.status == 404
        @info "No release yet on General"
        return nothing
    end

    return error("Unable to query Julia's General registry for $package, " *
                 "HTTP status $(response.status)")
end
