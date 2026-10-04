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

"""
    ResearchSoftwareMetadata.read_json(file::AbstractString)

Read a JSON metadata file such as `codemeta.json` into an `OrderedDict`.
Throws an error that names the file if it cannot be parsed or does not
hold a JSON object.
"""
function read_json(file::AbstractString)
    contents = try
        JSON.parsefile(file, dicttype = OrderedDict)
    catch err
        error("Unable to read $(basename(file)): " * sprint(showerror, err))
    end
    contents isa AbstractDict ||
        error("Unable to read $(basename(file)): it does not hold a JSON object")

    return contents
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
    ResearchSoftwareMetadata.read_workflows(git_dir::AbstractString)

Return the GitHub workflows of the repository at `git_dir` as
`file => workflow` pairs in file name order: every `.yml` or `.yaml`
file in `.github/workflows` that holds a mapping. The list is empty if
the repository has no workflows.
"""
function read_workflows(git_dir::AbstractString)
    workflows = Pair{String, Any}[]
    folder = joinpath(git_dir, ".github", "workflows")
    isdir(folder) || return workflows
    for file in readdir(folder, join = true)
        isfile(file) && endswith(file, r"\.ya?ml") || continue
        workflow = YAML.load_file(file)
        workflow isa AbstractDict && push!(workflows, file => workflow)
    end

    return workflows
end

"""
    ResearchSoftwareMetadata.called_workflow(job::AbstractDict,
                                             git_dir::AbstractString,
                                             depth::Int)

Return the reusable workflow a job calls, or `nothing` if the job calls
none that can be read: only a workflow in the same repository can be,
and only while fewer than `MAX_WORKFLOW_DEPTH` have been followed to
reach the job, which `depth` counts.
"""
function called_workflow(job::AbstractDict, git_dir::AbstractString, depth::Int)
    uses = get(job, "uses", nothing)
    uses isa AbstractString && startswith(uses, "./") || return nothing
    depth < MAX_WORKFLOW_DEPTH || return nothing
    file = normpath(joinpath(git_dir, uses))
    isfile(file) || return nothing
    called = YAML.load_file(file)
    return called isa AbstractDict ? called : nothing
end

# Whether a step of a workflow job runs the package's tests
function step_runs_tests(step::AbstractDict)
    uses = get(step, "uses", nothing)
    uses isa AbstractString &&
        startswith(uses, "julia-actions/julia-runtest") && return true
    script = get(step, "run", nothing)
    return script isa AbstractString && occursin("Pkg.test(", script)
end

step_runs_tests(step) = false

"""
    ResearchSoftwareMetadata.runs_tests(job::AbstractDict,
                                        git_dir::AbstractString, depth::Int)

Check whether a workflow job runs the package's tests: one of its steps
uses the `julia-actions/julia-runtest` action or runs a script that
calls `Pkg.test`, or the job calls a reusable workflow in the same
repository that has such a job. `depth` counts the reusable workflows
followed to reach the job.
"""
function runs_tests(job::AbstractDict, git_dir::AbstractString, depth::Int)
    steps = get(job, "steps", nothing)
    steps isa AbstractVector && return any(step_runs_tests, steps)
    called = called_workflow(job, git_dir, depth)
    return !isnothing(called) && workflow_runs_tests(called, git_dir, depth + 1)
end

# Whether any job of a workflow runs the package's tests
function workflow_runs_tests(workflow::AbstractDict, git_dir::AbstractString,
                             depth::Int)
    jobs = get(workflow, "jobs", nothing)
    jobs isa AbstractDict || return false
    return any(values(jobs)) do job
        return job isa AbstractDict && runs_tests(job, git_dir, depth)
    end
end

"""
    ResearchSoftwareMetadata.job_runners(job::AbstractDict,
                                         context::AbstractDict,
                                         git_dir::AbstractString, depth::Int;
                                         tests_only::Bool = false)

Return the runner labels a workflow job can run on, or `nothing` if they
cannot be determined. A job that calls a reusable workflow in the same
repository runs on that workflow's runners, given the inputs the job
passes to it, and on only those of its jobs that run the package's tests
if `tests_only` is set; a reusable workflow in another repository cannot
be read. `depth` counts the reusable workflows followed to reach the job.
"""
function job_runners(job::AbstractDict, context::AbstractDict,
                     git_dir::AbstractString, depth::Int;
                     tests_only::Bool = false)
    context = matrix_context(job, context)
    haskey(job, "runs-on") && return runner_labels(job["runs-on"], context)
    called = called_workflow(job, git_dir, depth)
    isnothing(called) && return nothing
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

    return workflow_runners(called, inputs, git_dir, depth + 1,
                            tests_only = tests_only)
end

"""
    ResearchSoftwareMetadata.workflow_runners(workflow::AbstractDict,
                                              context::AbstractDict,
                                              git_dir::AbstractString,
                                              depth::Int;
                                              tests_only::Bool = false)

Return the runner labels the jobs of a reusable workflow can run on when
it is called with the inputs in `context`, or `nothing` if none can be
determined. If `tests_only` is set, only the jobs that run the package's
tests are counted.
"""
function workflow_runners(workflow::AbstractDict, context::AbstractDict,
                          git_dir::AbstractString, depth::Int;
                          tests_only::Bool = false)
    jobs = get(workflow, "jobs", nothing)
    jobs isa AbstractDict || return nothing
    labels = String[]
    for job in values(jobs)
        job isa AbstractDict || continue
        tests_only && !runs_tests(job, git_dir, depth) && continue
        found = job_runners(job, context, git_dir, depth,
                            tests_only = tests_only)
        isnothing(found) || append!(labels, found)
    end

    return isempty(labels) ? nothing : labels
end

"""
    ResearchSoftwareMetadata.get_os_from_workflows(git_dir)

Return the sorted names of the operating systems ("Linux", "Windows",
"macOS") that the GitHub workflows of the repository at `git_dir` run
the package's tests on, which are presumed to be the ones the software
runs on. If the jobs that run the tests give none, whether because no job
is recognised as running them or because their runners cannot be
determined, the operating systems of every job are returned in their
place. The list is empty if the repository has no workflows.

A job runs the tests if it uses the `julia-actions/julia-runtest` action
or calls `Pkg.test` in a script. Each job's `runs-on` may be a runner
label, a list of labels or a runner group, and may refer to the job's
matrix (`\${{ matrix.os }}`, including values given under `include`) or
to a workflow input (`\${{ inputs.os }}`). A job that calls a reusable
workflow in the same repository counts the runners of that workflow. A
job whose operating system cannot be determined is reported and
otherwise ignored: one that uses any other expression, a self-hosted
runner whose labels name no operating system, or a reusable workflow
from another repository. Matrix `exclude` entries and `if` conditions
are not taken into account.
"""
function get_os_from_workflows(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    tested = Set{String}()
    untested = Set{String}()
    # Each job whose operating system is unknown, with whether it runs the tests
    unknown = Pair{String, Bool}[]
    for (file, workflow) in read_workflows(git_dir)
        jobs = get(workflow, "jobs", nothing)
        jobs isa AbstractDict || continue
        context = workflow_inputs(workflow)
        for (name, job) in jobs
            tests = job isa AbstractDict && runs_tests(job, git_dir, 0)
            labels = job isa AbstractDict ?
                     job_runners(job, context, git_dir, 0, tests_only = tests) :
                     nothing
            oses = isnothing(labels) ? String[] :
                   filter(!isnothing, runner_os.(labels))
            if !isempty(oses)
                union!(tests ? tested : untested, oses)
            elseif !has_trigger(workflow, "workflow_call")
                # A reusable workflow is counted through the jobs that call it
                push!(unknown, "job $name in $(basename(file))" => tests)
            end
        end
    end

    # The jobs that do not run the tests only matter when the others give nothing
    for (job, tests) in unknown
        (tests || isempty(tested)) &&
            @info "Cannot determine the operating system for $job, " *
                  "so ignoring it"
    end

    return sort!(collect(isempty(tested) ? untested : tested))
end

# Whether a workflow is started by any event other than a call from another
# workflow, so that it runs in its own right
function has_own_trigger(workflow::AbstractDict)
    return own_trigger(get(workflow, "on", nothing))
end

own_trigger(triggers::AbstractDict) = any(!=("workflow_call"), keys(triggers))
own_trigger(triggers::AbstractVector) = any(!=("workflow_call"), triggers)
own_trigger(triggers::AbstractString) = triggers != "workflow_call"
own_trigger(triggers) = false

# Rank of a workflow file by how conventional its name is for the workflow that
# runs the tests: `testing` first, then `CI`, in any case and with either extension
function ci_name_rank(file::AbstractString)
    stem = lowercase(first(splitext(basename(file))))
    return stem == "testing" ? 0 : stem == "ci" ? 1 : 2
end

"""
    ResearchSoftwareMetadata.get_ci_workflow(git_dir)

Return the file name of the GitHub workflow that carries out continuous
integration for the repository at `git_dir`, or `nothing` if there is
none. It is a workflow that runs in its own right, not only when called
by another, and that either has a job running the package's tests (see
[`ResearchSoftwareMetadata.runs_tests`](@ref)) or is named `testing` or
`CI`. Where there are several, a workflow that runs the tests is chosen
over one that does not, then one started by a pull request, then one
started by a push, then one named `testing`, then one named `CI`, then
the first in file name order.
"""
function get_ci_workflow(git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`))
    ranked = Tuple{Bool, Bool, Bool, Int, String}[]
    for (file, workflow) in read_workflows(git_dir)
        has_own_trigger(workflow) || continue
        tests = workflow_runs_tests(workflow, git_dir, 0)
        name_rank = ci_name_rank(file)
        tests || name_rank < 2 || continue
        push!(ranked,
              (!tests, !has_trigger(workflow, "pull_request"),
               !has_trigger(workflow, "push"), name_rank, basename(file)))
    end

    return isempty(ranked) ? nothing : last(minimum(ranked))
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
    ResearchSoftwareMetadata.header_changes(git_dir::AbstractString,
                                            license::AbstractString)

Return the julia source files of the repository at `git_dir` whose first
line has to change for it to be the SPDX header of `license`, as
`file => new content` pairs. A file without a header gains one followed by
a blank line, a header naming another license is corrected, and an empty
file becomes the header alone. Files that already carry the header are
left out, as are Pluto notebooks, whose first line Pluto needs. Nothing
is written.
"""
function header_changes(git_dir::AbstractString, license::AbstractString)
    header = "# SPDX-License-Identifier: $license"
    changes = Pair{String, String}[]
    for file in source_files(git_dir)
        lines = readlines(file)
        if isempty(lines)
            lines = [header]
        elseif startswith(first(lines), "# SPDX-License-Identifier:")
            first(lines) == header && continue
            lines[1] = header
        elseif startswith(first(lines), "### A Pluto.jl notebook ###")
            continue
        else
            pushfirst!(lines, header, "")
        end
        push!(changes, file => join(lines, "\n") * "\n")
    end

    return changes
end
