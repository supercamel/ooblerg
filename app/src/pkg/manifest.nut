local U = import("../util.nut")

function package_map(index) {
    local out = {}
    if (index == null || !("packages" in index)) return out
    foreach (pkg in index.packages) {
        if ("name" in pkg) out[pkg.name] <- pkg
    }
    return out
}

function dependency_names(pkg) {
    local out = []
    if (pkg == null || !("dependencies" in pkg)) return out
    foreach (dep in pkg.dependencies) {
        if (typeof dep == "string") out.append(dep)
        else if (dep != null && "name" in dep) out.append(dep.name)
    }
    return out
}

function validate_index(index) {
    if (index == null) throw "repository index is empty"
    if (!("schema" in index) || index.schema != 1) throw "unsupported repository index schema"
    if (!("packages" in index)) throw "repository index has no packages array"
    foreach (pkg in index.packages) {
        if (!("name" in pkg) || pkg.name == "") throw "package is missing a name"
        if (!("version" in pkg) || pkg.version == "") throw "package " + pkg.name + " is missing a version"
    }
    return true
}

function package_summary(pkg) {
    if (pkg == null) return ""
    if ("summary" in pkg && pkg.summary != "") return pkg.summary
    if ("description" in pkg && pkg.description != "") return pkg.description
    return pkg.name
}

function sorted_packages(index) {
    local map = package_map(index)
    local out = []
    foreach (name in U.sorted_keys(map)) out.append(map[name])
    return out
}

return {
    package_map = package_map,
    dependency_names = dependency_names,
    validate_index = validate_index,
    package_summary = package_summary,
    sorted_packages = sorted_packages,
}
