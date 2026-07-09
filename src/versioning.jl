# SPDX-License-Identifier: BSD-2-Clause

"""
    increase_patch()

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
    old_project = read(file, String)
    open(file, "w") do io
        return TOML.print(io, project)
    end

    try
        return crosswalk(git_dir, update = true)
    catch
        # Restore Project.toml so a failed crosswalk leaves files unchanged
        write(file, old_project)
        rethrow()
    end
end

"""
    increase_minor()

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
    old_project = read(file, String)
    open(file, "w") do io
        return TOML.print(io, project)
    end

    try
        return crosswalk(git_dir, update = true)
    catch
        # Restore Project.toml so a failed crosswalk leaves files unchanged
        write(file, old_project)
        rethrow()
    end
end

"""
    increase_major()

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
    old_project = read(file, String)
    open(file, "w") do io
        return TOML.print(io, project)
    end

    try
        return crosswalk(git_dir, update = true)
    catch
        # Restore Project.toml so a failed crosswalk leaves files unchanged
        write(file, old_project)
        rethrow()
    end
end
