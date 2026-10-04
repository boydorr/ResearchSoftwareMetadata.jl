# SPDX-License-Identifier: MIT

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
                                        to_cm = identity, from_cm = identity,
                                        update = false)

Reconcile a metadata field between `Project.toml` (authoritative) and
`codemeta.json`. An explicit `value` (e.g. from a keyword argument to
`crosswalk`) takes precedence and is written into both; otherwise the
`Project.toml` entry is used, fixing `codemeta.json` with a warning if it
disagrees — or an informational message when `update` is true, meaning
the `Project.toml` change is deliberate and should just propagate. If the
field is missing from `Project.toml` but present in `codemeta.json`, it
is backfilled into `Project.toml`. If it is absent from both, `default`
is used for `codemeta.json` (when provided) without being backfilled.
`to_cm` and `from_cm` convert values between the `Project.toml` and
`codemeta.json` representations. Returns the `Project.toml`-side value,
or `nothing` if the field is absent everywhere.
"""
function reconcile!(project, codemeta, proj_key, cm_key;
                    value = nothing, default = nothing,
                    to_cm = identity, from_cm = identity, update = false)
    if !isnothing(value)
        project[proj_key] = value
    end
    if haskey(project, proj_key)
        val = project[proj_key]
        cm_val = to_cm(val)
        if haskey(codemeta, cm_key) && codemeta[cm_key] ≠ cm_val &&
           isnothing(value)
            msg = "Fixing codemeta.json $cm_key to match Project.toml " *
                  "($(codemeta[cm_key]) ≠ $cm_val)"
            update ? (@info msg) : (@warn msg)
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
    ResearchSoftwareMetadata.runner_os(label::AbstractString)

Return the operating system named by a GitHub runner label ("Linux",
"Windows" or "macOS"), or `nothing` if the label names none, as with
`self-hosted` or an architecture label.
"""
function runner_os(label::AbstractString)
    lower = lowercase(label)
    (startswith(lower, "ubuntu") || lower == "linux") && return "Linux"
    startswith(lower, "windows") && return "Windows"
    startswith(lower, "macos") && return "macOS"
    return nothing
end

"""
    ResearchSoftwareMetadata.expression_values(value, context::AbstractDict)

Return the values an entry of a GitHub workflow can take, as strings. A
literal is its own only value; a single `\${{ matrix.x }}` or
`\${{ inputs.x }}` reference takes the values `context` holds under
`"matrix.x"` or `"inputs.x"`; a list takes the values of all of its
elements that can be determined. Returns `nothing` when no value can be
determined: for any other expression, a reference `context` does not
hold, a mapping or an empty entry.
"""
function expression_values(value::AbstractString, context::AbstractDict)
    reference = match(r"^\s*\$\{\{\s*((?:matrix|inputs)\.[\w-]+)\s*\}\}\s*$",
                      value)
    if isnothing(reference)
        return occursin("\${{", value) ? nothing : [String(value)]
    end
    name = reference.captures[1]
    return haskey(context, name) ? copy(context[name]) : nothing
end

function expression_values(values::AbstractVector, context::AbstractDict)
    found = String[]
    for value in values
        vals = expression_values(value, context)
        isnothing(vals) || append!(found, vals)
    end

    return isempty(found) ? nothing : found
end

expression_values(::AbstractDict, ::AbstractDict) = nothing
expression_values(::Nothing, ::AbstractDict) = nothing
# Numbers and booleans, which YAML reads from unquoted entries
expression_values(value, ::AbstractDict) = [string(value)]

"""
    ResearchSoftwareMetadata.matrix_context(job::AbstractDict,
                                            context::AbstractDict)

Return `context` extended with the values each `matrix.x` reference can
take in a workflow job: the entries of that axis of the job's
`strategy.matrix`, together with any given for it under `include`.
`exclude` is not applied, and a matrix that is itself an expression adds
nothing.
"""
function matrix_context(job::AbstractDict, context::AbstractDict)
    extended = copy(context)
    strategy = get(job, "strategy", nothing)
    strategy isa AbstractDict || return extended
    matrix = get(strategy, "matrix", nothing)
    matrix isa AbstractDict || return extended
    for (key, value) in matrix
        key in ("include", "exclude") && continue
        vals = expression_values(value, context)
        isnothing(vals) || (extended["matrix.$key"] = vals)
    end
    included = get(matrix, "include", nothing)
    included isa AbstractVector || return extended
    for entry in included
        entry isa AbstractDict || continue
        for (key, value) in entry
            vals = expression_values(value, context)
            isnothing(vals) ||
                append!(get!(extended, "matrix.$key", String[]), vals)
        end
    end

    return extended
end

"""
    ResearchSoftwareMetadata.has_trigger(workflow::AbstractDict,
                                         name::AbstractString)

Check whether a GitHub workflow is started by the event `name`, such as
`workflow_call`. The workflow's `on` entry may be a single event, a list
of events or a mapping from events to their settings.
"""
function has_trigger(workflow::AbstractDict, name::AbstractString)
    return names_trigger(get(workflow, "on", nothing), name)
end

# Whether the `on` entry of a workflow, in any of its three forms, names an event
function names_trigger(triggers::AbstractDict, name::AbstractString)
    return haskey(triggers, name)
end

function names_trigger(triggers::AbstractVector, name::AbstractString)
    return name in triggers
end

names_trigger(triggers, name::AbstractString) = triggers == name

"""
    ResearchSoftwareMetadata.workflow_inputs(workflow::AbstractDict)

Return the context a GitHub workflow starts with when nothing is passed
to it: the default of every input it declares under `workflow_dispatch`
or `workflow_call`, held under `"inputs.x"`.
"""
function workflow_inputs(workflow::AbstractDict)
    context = Dict{String, Vector{String}}()
    triggers = get(workflow, "on", nothing)
    triggers isa AbstractDict || return context
    for trigger in ("workflow_dispatch", "workflow_call")
        settings = get(triggers, trigger, nothing)
        settings isa AbstractDict || continue
        inputs = get(settings, "inputs", nothing)
        inputs isa AbstractDict || continue
        for (name, input) in inputs
            input isa AbstractDict || continue
            vals = expression_values(get(input, "default", nothing), context)
            isnothing(vals) || (context["inputs.$name"] = vals)
        end
    end

    return context
end

"""
    ResearchSoftwareMetadata.runner_labels(runs_on, context::AbstractDict)

Return the runner labels named by the `runs-on` entry of a workflow job,
or `nothing` if they cannot be determined. The entry may be one label, a
list of labels or a runner group, of which only the `labels` can name an
operating system.
"""
function runner_labels(runs_on::AbstractDict, context::AbstractDict)
    return expression_values(get(runs_on, "labels", nothing), context)
end

function runner_labels(runs_on, context::AbstractDict)
    return expression_values(runs_on, context)
end

# How deeply GitHub lets reusable workflows call one another, which also stops a
# workflow that calls itself from being followed for ever
const MAX_WORKFLOW_DEPTH = 10

"""
    ResearchSoftwareMetadata.job_runners(job::AbstractDict,
                                         context::AbstractDict,
                                         git_dir::AbstractString, depth::Int)

Return the runner labels a workflow job can run on, or `nothing` if they
cannot be determined. A job that calls a reusable workflow in the same
repository runs on that workflow's runners, given the inputs the job
passes to it; a reusable workflow in another repository cannot be read.
`depth` counts the reusable workflows followed to reach the job.
"""
function job_runners(job::AbstractDict, context::AbstractDict,
                     git_dir::AbstractString, depth::Int)
    context = matrix_context(job, context)
    haskey(job, "runs-on") && return runner_labels(job["runs-on"], context)
    uses = get(job, "uses", nothing)
    uses isa AbstractString && startswith(uses, "./") || return nothing
    depth < MAX_WORKFLOW_DEPTH || return nothing
    file = normpath(joinpath(git_dir, uses))
    isfile(file) || return nothing
    called = YAML.load_file(file)
    called isa AbstractDict || return nothing
    inputs = workflow_inputs(called)
    passed = get(job, "with", nothing)
    if passed isa AbstractDict
        for (name, value) in passed
            vals = expression_values(value, context)
            if isnothing(vals)
                delete!(inputs, "inputs.$name")
            else
                inputs["inputs.$name"] = vals
            end
        end
    end

    return workflow_runners(called, inputs, git_dir, depth + 1)
end

"""
    ResearchSoftwareMetadata.workflow_runners(workflow::AbstractDict,
                                              context::AbstractDict,
                                              git_dir::AbstractString,
                                              depth::Int)

Return the runner labels the jobs of a reusable workflow can run on when
it is called with the inputs in `context`, or `nothing` if none can be
determined.
"""
function workflow_runners(workflow::AbstractDict, context::AbstractDict,
                          git_dir::AbstractString, depth::Int)
    jobs = get(workflow, "jobs", nothing)
    jobs isa AbstractDict || return nothing
    labels = String[]
    for job in values(jobs)
        job isa AbstractDict || continue
        found = job_runners(job, context, git_dir, depth)
        isnothing(found) || append!(labels, found)
    end

    return isempty(labels) ? nothing : labels
end

"""
    ResearchSoftwareMetadata.get_os_from_workflows(git_dir)

Return the sorted names of the operating systems ("Linux", "Windows",
"macOS") that the GitHub workflows of the repository at `git_dir` run
on, which are presumed to be the ones the software runs on. The list is
empty if the repository has no workflows.

Each job's `runs-on` may be a runner label, a list of labels or a runner
group, and may refer to the job's matrix (`\${{ matrix.os }}`, including
values given under `include`) or to a workflow input
(`\${{ inputs.os }}`). A job that calls a reusable workflow in the same
repository counts the runners of that workflow. A job whose operating
system cannot be determined is reported and otherwise ignored: one that
uses any other expression, a self-hosted runner whose labels name no
operating system, or a reusable workflow from another repository. Matrix
`exclude` entries and `if` conditions are not taken into account.
"""
function get_os_from_workflows(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    workflow_folder = joinpath(git_dir, ".github", "workflows")
    isdir(workflow_folder) || return String[]
    files = filter(readdir(workflow_folder, join = true)) do file
        return isfile(file) && endswith(file, r"\.ya?ml")
    end
    platforms = Set{String}()
    for file in files
        workflow = YAML.load_file(file)
        workflow isa AbstractDict || continue
        jobs = get(workflow, "jobs", nothing)
        jobs isa AbstractDict || continue
        context = workflow_inputs(workflow)
        for (name, job) in jobs
            labels = job isa AbstractDict ?
                     job_runners(job, context, git_dir, 0) : nothing
            oses = isnothing(labels) ? String[] :
                   filter(!isnothing, runner_os.(labels))
            if !isempty(oses)
                union!(platforms, oses)
            elseif !has_trigger(workflow, "workflow_call")
                # A reusable workflow is counted through the jobs that call it
                @info "Cannot determine the operating system for job $name " *
                      "in $(basename(file)), so ignoring it"
            end
        end
    end

    return sort!(collect(platforms))
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
