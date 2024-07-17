var documenterSearchIndex = {"docs":
[{"location":"#ResearchSoftwareMetadata-documentation","page":"Home","title":"ResearchSoftwareMetadata documentation","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"CurrentModule = ResearchSoftwareMetadata","category":"page"},{"location":"#ResearchSoftwareMetadata","page":"Home","title":"ResearchSoftwareMetadata","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"Documentation for ResearchSoftwareMetadata.","category":"page"},{"location":"","page":"Home","title":"Home","text":"","category":"page"},{"location":"","page":"Home","title":"Home","text":"Modules = [ResearchSoftwareMetadata]","category":"page"},{"location":"#ResearchSoftwareMetadata.crosswalk-Tuple{}","page":"Home","title":"ResearchSoftwareMetadata.crosswalk","text":"ResearchSoftwareMetadata.crosswalk(; category = nothing, keywords = nothing, build = false)\n\nRuns a crosswalk across Project.toml, LICENSE, codemeta.json and .zenodo.json as well as the julia source files to enforce consistency between the different metadata formats. It logs warnings and errors if it identifies inconsistencies while it is editing the files. The software category can be set with the category argument, likewise the keywords argument can contain a vector of keyword strings. The build argument sets the buildInstructions RSMD field - false leaves the instructions as is, true sets it to the same as the README, and a string sets it to that value. If update is true, mismatches between version numbers in codemeta.json are accepted.\n\n\n\n\n\n","category":"method"},{"location":"#ResearchSoftwareMetadata.get_first_release_date-Tuple{}","page":"Home","title":"ResearchSoftwareMetadata.get_first_release_date","text":"ResearchSoftwareMetadata.get_first_release_date()\n\nReturns the first release date of this package on Julia's General Registry, or today's date if the package has not been registered yet.\n\n\n\n\n\n","category":"method"},{"location":"#ResearchSoftwareMetadata.get_organisation_from_ror-Tuple{String}","page":"Home","title":"ResearchSoftwareMetadata.get_organisation_from_ror","text":"ResearchSoftwareMetadata.get_organisation_from_ror(ror::String)\n\nTake a ROR from the user and query the ror.org API to return a Dict containing the relevant metadata or nothing if no such ROR exists.\n\n\n\n\n\n","category":"method"},{"location":"#ResearchSoftwareMetadata.get_os_from_workflows-Tuple{}","page":"Home","title":"ResearchSoftwareMetadata.get_os_from_workflows","text":"ResearchSoftwareMetadata.get_os_from_workflows()\n\nReturns the operating systems that the GitHub workflows associated with this package work on. This is presumed to represent the operating systems that the software runs on.\n\n\n\n\n\n","category":"method"},{"location":"#ResearchSoftwareMetadata.get_person_from_orcid-Tuple{String}","page":"Home","title":"ResearchSoftwareMetadata.get_person_from_orcid","text":"ResearchSoftwareMetadata.get_person_from_orcid(orcid::String)\n\nTake an ORCID from the user and query the orcid.org API to return a Dict containing the relevant metadata or nothing if no such ORCID exists.\n\n\n\n\n\n","category":"method"},{"location":"#ResearchSoftwareMetadata.increase_major-Tuple{}","page":"Home","title":"ResearchSoftwareMetadata.increase_major","text":"ResearchSoftwareMetadata.increase_major()\n\nIncreases the Project.toml version number by a major number (e.g. 0.4.1 to 1.0.0), and then runs ResearchSoftwareMetadata.crosswalk() to propagate this information.\n\n\n\n\n\n","category":"method"},{"location":"#ResearchSoftwareMetadata.increase_minor-Tuple{}","page":"Home","title":"ResearchSoftwareMetadata.increase_minor","text":"ResearchSoftwareMetadata.increase_minor()\n\nIncreases the Project.toml version number by a minor number (e.g. 0.4.1 to 0.5.0), and then runs ResearchSoftwareMetadata.crosswalk() to propagate this information.\n\n\n\n\n\n","category":"method"},{"location":"#ResearchSoftwareMetadata.increase_patch-Tuple{}","page":"Home","title":"ResearchSoftwareMetadata.increase_patch","text":"ResearchSoftwareMetadata.increase_patch()\n\nIncreases the Project.toml version number by a patch (e.g. 0.4.1 to 0.4.2), and then runs ResearchSoftwareMetadata.crosswalk() to propagate this information.\n\n\n\n\n\n","category":"method"},{"location":"#ResearchSoftwareMetadata.read_project-Tuple{}","page":"Home","title":"ResearchSoftwareMetadata.read_project","text":"ResearchSoftwareMetadata.read_project()\n\nRead a Project.toml file in and return it in its canonical order in an OrderedDict.\n\n\n\n\n\n","category":"method"}]
}