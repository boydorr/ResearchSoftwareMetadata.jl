# SPDX-License-Identifier: MIT

# Licenses to suggest to a package that has none: approved by both the FSF and
# the OSI, and running from permissive to strong copyleft
const SUGGESTED_LICENSES = ["MIT", "BSD-2-Clause", "Apache-2.0", "MPL-2.0",
    "LGPL-3.0-or-later", "GPL-3.0-or-later"]

# Where to find a license identifier, and which licenses to consider
const LICENSE_ADVICE = "an SPDX identifier from https://spdx.org/licenses/. " *
                       "We suggest a license approved by both the FSF and " *
                       "the OSI, such as " *
                       join(SUGGESTED_LICENSES, ", ", " or ") * "."

"""
    ResearchSoftwareMetadata.spdx_identifier(license::AbstractString)

Return the bare SPDX identifier of a license that may be written as the
address of its page on spdx.org: `https://spdx.org/licenses/MIT`, the same
with `http` and the same with a trailing `.html` or `.json` all give `MIT`,
as does `MIT` itself.
"""
function spdx_identifier(license::AbstractString)
    return replace(strip(license), r"^https?://spdx\.org/licenses/" => "",
                   r"\.(html|json)$" => "")
end

# The names a license file may have, compared without regard to case
const LICENSE_FILENAMES = [stem * extension
                           for stem in ("LICENSE", "LICENCE", "COPYING")
                           for extension in ("", ".MD", ".TXT")]

"""
    ResearchSoftwareMetadata.license_files(git_dir::AbstractString)

Return the paths of the license files in the top directory of the
repository at `git_dir`: any called `LICENSE`, `LICENCE` or `COPYING`, with
or without a `.md` or `.txt` extension, in upper or lower case.
"""
function license_files(git_dir::AbstractString)
    names = filter(readdir(git_dir)) do name
        return uppercase(name) in LICENSE_FILENAMES &&
               isfile(joinpath(git_dir, name))
    end

    return joinpath.(git_dir, names)
end

"""
    ResearchSoftwareMetadata.license_text(template::AbstractString,
                                          years::AbstractString,
                                          names::AbstractVector)

Return the text of a license from its SPDX `template`, with the
placeholders for the copyright years and holders filled in.
"""
function license_text(template::AbstractString, years::AbstractString,
                      names::AbstractVector)
    holders = join(names, ", ", " and ")
    return replace(template,
                   r"<year>"i => years,
                   r"<owners?>"i => holders,
                   r"<copyright holders?>"i => holders,
                   r"<Owner Organization Name>"i => holders,
                   r"<Asset Owner>"i => holders,
                   r"<HOLDERS?>"i => holders,
                   r"<name of author>"i => holders,
                   r"<author's name or designee>"i => holders)
end

"""
    ResearchSoftwareMetadata.base_identifier(license::AbstractString)

Return an SPDX identifier without the `-only`, `-or-later` or `+` that says
which versions of a license apply. The text of a license is the same
whichever is meant, so a license file can only be matched this far.
"""
function base_identifier(license::AbstractString)
    return replace(license, r"(-only|-or-later|\+)$" => "")
end

"""
    ResearchSoftwareMetadata.licenses_found(file::AbstractString)

Return the SPDX identifiers of the licenses whose text is found in a file,
which is none if the file is not recognisable as a license.
"""
function licenses_found(file::AbstractString)
    return licensecheck(read(file, String)).licenses_found
end

"""
    ResearchSoftwareMetadata.holds_license(file::AbstractString,
                                           license::AbstractString)

Check whether the text of `license`, an SPDX identifier, is found in a
file, whichever versions of it the identifier allows.
"""
function holds_license(file::AbstractString, license::AbstractString)
    return base_identifier(license) in base_identifier.(licenses_found(file))
end

# A license text with every year or range of years replaced by a marker, so
# that two texts differing only in their copyright years compare equal
function without_years(text::AbstractString)
    return replace(strip(text), r"\b\d{4}(-\d{4})?\b" => "<year>")
end

"""
    ResearchSoftwareMetadata.is_generated(file::AbstractString,
                                          generated::AbstractVector)

Check whether a license file is one this package wrote: whether its text
is one of the `generated` texts, apart from the copyright years.
"""
function is_generated(file::AbstractString, generated::AbstractVector)
    existing = without_years(read(file, String))
    return any(text -> without_years(text) == existing, generated)
end

"""
    ResearchSoftwareMetadata.license_file_changes(git_dir::AbstractString,
                                                  license::AbstractString,
                                                  generated::AbstractVector;
                                                  replace::Bool)

Decide what a crosswalk does to the license files of the repository at
`git_dir`, whose license is the SPDX identifier `license`, and return it
as `(write, remove)`: whether to write a generated `LICENSE`, and the
files to remove. Nothing is written or removed here.

A file this package wrote itself (see
[`ResearchSoftwareMetadata.is_generated`](@ref), with the texts it could
have written in `generated`) is written afresh. Any other file that
contains `license` belongs to the user and is left as it is, in which case
no `LICENSE` is written beside it. A file that does not contain `license`
is removed if `replace` is set, and is otherwise an error, since replacing
it would change the licensing of the repository.
"""
function license_file_changes(git_dir::AbstractString, license::AbstractString,
                              generated::AbstractVector; replace::Bool)
    own = String[]
    kept = String[]
    foreign = String[]
    for file in license_files(git_dir)
        if is_generated(file, generated)
            push!(own, file)
        elseif holds_license(file, license)
            push!(kept, file)
        else
            push!(foreign, file)
        end
    end
    if !isempty(foreign) && !replace
        file = first(foreign)
        found = licenses_found(file)
        holds = isempty(found) ? "no license that can be recognised" :
                join(found, ", ", " and ")
        error("$(basename(file)) does not hold the $license license that " *
              "is declared: it holds $holds. Nothing has been changed. To " *
              "replace it with the $license license run " *
              "`crosswalk(update = true)`; if it is right, correct the " *
              "`license` in Project.toml")
    end
    @debug "License files" generated_here=basename.(own) left_alone=basename.(kept) replaced=basename.(foreign)
    write = !isempty(own) || isempty(kept)
    target = joinpath(git_dir, "LICENSE")
    remove = filter(!=(target), write ? vcat(own, foreign) : foreign)

    return (write = write, remove = remove)
end

"""
    ResearchSoftwareMetadata.describe_license_files(git_dir::AbstractString)

Return sentences saying which licenses the license files of the repository
at `git_dir` hold, and for a file holding a single license how to declare
it, to help a package that has declared none. The string is empty if
there are no license files or none can be recognised.
"""
function describe_license_files(git_dir::AbstractString)
    sentences = String[]
    for file in license_files(git_dir)
        found = unique(base_identifier.(licenses_found(file)))
        isempty(found) && continue
        if length(found) > 1
            push!(sentences,
                  "$(basename(file)) holds the " * join(found, ", ", " and ") *
                  " licenses. ")
            continue
        end
        # The text of a GNU license does not say which versions are meant
        license = only(found)
        choices = occursin(r"^[AL]?GPL-", license) ?
                  [license * "-or-later", license * "-only"] : [license]
        calls = join(["`crosswalk(license = \"$choice\")`"
                      for choice in choices], " or ")
        push!(sentences,
              "$(basename(file)) holds the $license license, which $calls " *
              "would declare. ")
    end

    return join(sentences)
end

"""
    ResearchSoftwareMetadata.source_files(git_dir::AbstractString)

Return the paths of the julia source files of the repository at
`git_dir`: every `.jl` file that git tracks, or would track because it is
not ignored. Files that git ignores and the contents of submodules are
not included.
"""
function source_files(git_dir::AbstractString)
    # NUL-separated, so that git does not quote unusual file names. Precomposed
    # unicode has to be off: with it on, as it is by default on macOS, the git
    # that Git.jl supplies cannot convert file names, and fails to scan a
    # working tree that has any file whose name is not ASCII. The names then
    # come back as they are on disk, which is what opening them needs.
    listing = read(`$(Git.git()) -c core.precomposeunicode=false -C $git_dir
                    ls-files -z --cached --others --exclude-standard -- '*.jl'`,
                   String)
    files = joinpath.(git_dir, split(listing, '\0', keepempty = false))
    return unique!(filter!(isfile, files))
end

"""
    ResearchSoftwareMetadata.header_licenses(expression::AbstractString)

Return the license identifiers named in the SPDX expression of a source
file header: the one identifier of a plain header, and each of those
joined by `AND` or `OR` in a compound one. The exception that follows a
`WITH` is not a license and is left out.
"""
function header_licenses(expression::AbstractString)
    licenses = String[]
    exception_next = false
    for token in split(replace(expression, r"[()]" => " "))
        if exception_next
            exception_next = false
        elseif uppercase(token) == "WITH"
            exception_next = true
        elseif uppercase(token) ∉ ("AND", "OR")
            push!(licenses, token)
        end
    end

    return licenses
end

"""
    ResearchSoftwareMetadata.header_changes(git_dir::AbstractString,
                                            license::AbstractString;
                                            additional::AbstractVector = String[],
                                            previous::AbstractVector = String[])

Return the julia source files of the repository at `git_dir` whose first
line has to change for the package to be licensed under `license`, as
`file => new content` pairs. Nothing is written.

A file without an SPDX header gains one for `license`, followed by a blank
line, and an empty file becomes the header alone. A header is left as it
is if every license it names is `license` or one of the `additional`
licenses the package declares. A header naming one of the `previous`
licenses, which the package is being moved from, is changed to `license`.
A header naming any other license is an error, listing every such file,
since changing it would change the licensing of the file. Pluto notebooks,
whose first line Pluto needs, are passed over.
"""
function header_changes(git_dir::AbstractString, license::AbstractString;
                        additional::AbstractVector = String[],
                        previous::AbstractVector = String[])
    prefix = "# SPDX-License-Identifier:"
    header = "$prefix $license"
    allowed = vcat(license, additional)
    changes = Pair{String, String}[]
    undeclared = String[]
    for file in source_files(git_dir)
        lines = readlines(file)
        if isempty(lines)
            lines = [header]
        elseif startswith(first(lines), prefix)
            named = strip(chopprefix(first(lines), prefix))
            licenses = header_licenses(named)
            if !isempty(licenses) && all(in(allowed), licenses)
                continue
            elseif isempty(licenses) || named in previous
                lines[1] = header
            else
                push!(undeclared, "  $(relpath(file, git_dir)): $named")
                continue
            end
        elseif startswith(first(lines), "### A Pluto.jl notebook ###")
            continue
        else
            pushfirst!(lines, header, "")
        end
        push!(changes, file => join(lines, "\n") * "\n")
    end
    isempty(undeclared) ||
        error("These files are marked with a license that is neither " *
              "$license nor one of the package's additional licenses:\n" *
              join(undeclared, "\n") * "\nNothing has been changed. If a " *
              "file is meant to have that license, add the license to " *
              "`additional_licenses` in the [rsmd] table of Project.toml; " *
              "if not, correct the first line of the file")

    return changes
end
