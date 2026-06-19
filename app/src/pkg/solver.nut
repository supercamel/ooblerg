local U = import("../util.nut")
local Manifest = import("manifest.nut")
local Status = import("status.nut")

function action(name, pkg, reason) {
    return {
        name = name,
        version = pkg != null && "version" in pkg ? pkg.version : "",
        reason = reason,
        summary = pkg != null ? Manifest.package_summary(pkg) : "",
    }
}

function install_plan(index, status, requests) {
    Manifest.validate_index(index)
    local repo = Manifest.package_map(index)
    local installed = status != null && "packages" in status ? status.packages : {}
    local seen = {}
    local visiting = {}
    local install = []

    function visit(name, reason) {
        if (name in seen) return
        if (name in visiting) throw "dependency cycle at " + name
        if (!(name in repo)) throw "missing package: " + name
        visiting[name] <- true
        local pkg = repo[name]
        foreach (dep in Manifest.dependency_names(pkg)) visit(dep, "dependency")
        visiting.rawdelete(name)
        seen[name] <- true
        local installed_version = name in installed && "version" in installed[name] ? installed[name].version : null
        if (installed_version != pkg.version) {
            install.append(action(name, pkg, reason))
        }
    }

    foreach (name in requests) visit(name, "manual")

    return {
        action = "install",
        requested = requests,
        install = install,
        remove = [],
        blocked = [],
        warnings = [],
    }
}

function cleanup_plan(index, status, requests) {
    local plan = install_plan(index, status, requests)
    return {
        action = "cleanup",
        requested = requests,
        install = [],
        remove = [],
        cleanup = plan.install,
        blocked = [],
        warnings = [
            "Only unmanaged files listed in these package manifests will be removed.",
        ],
    }
}

function installed_depends_on(repo, installed, pkg_name, dep_name) {
    if (!(pkg_name in repo)) return false
    foreach (dep in Manifest.dependency_names(repo[pkg_name])) {
        if (dep == dep_name && dep in installed) return true
    }
    return false
}

function add_dependent_removals(repo, installed, remove_set) {
    local dependents = []
    local changed = true
    while (changed) {
        changed = false
        foreach (pkg_name in U.sorted_keys(installed)) {
            if (pkg_name in remove_set) continue
            foreach (target in U.sorted_keys(remove_set)) {
                if (installed_depends_on(repo, installed, pkg_name, target)) {
                    remove_set[pkg_name] <- true
                    dependents.append({ name = pkg_name, depends_on = target })
                    changed = true
                    break
                }
            }
        }
    }
    return dependents
}

function append_remove_action(out, repo, name, reason) {
    out.append(action(name, name in repo ? repo[name] : null, reason))
}

function remove_plan(index, status, requests) {
    Manifest.validate_index(index)
    local repo = Manifest.package_map(index)
    local installed = status != null && "packages" in status ? status.packages : {}
    local remove_set = {}
    local remove = []
    local warnings = []

    foreach (name in requests) {
        if (!(name in installed)) {
            warnings.append(name + " is not installed")
            continue
        }
        remove_set[name] <- true
    }

    local dependents = add_dependent_removals(repo, installed, remove_set)

    foreach (name in U.sorted_keys(remove_set)) {
        local is_requested = false
        foreach (request in requests) {
            if (request == name) {
                is_requested = true
                break
            }
        }
        if (is_requested) append_remove_action(remove, repo, name, "manual")
    }
    foreach (item in dependents) {
        append_remove_action(remove, repo, item.name, "dependent")
    }

    local keep = {}
    function mark_keep(name) {
        if (name in keep || name in remove_set || !(name in installed)) return
        keep[name] <- true
        if (name in repo) {
            foreach (dep in Manifest.dependency_names(repo[name])) mark_keep(dep)
        }
    }

    foreach (name in U.sorted_keys(installed)) {
        if (name in remove_set) continue
        local item = installed[name]
        local manual = !("manual" in item) || item.manual
        if (manual) mark_keep(name)
    }

    foreach (name in U.sorted_keys(installed)) {
        if (name in remove_set || name in keep) continue
        local item = installed[name]
        local manual = !("manual" in item) || item.manual
        if (!manual) {
            remove_set[name] <- true
            append_remove_action(remove, repo, name, "orphan")
        }
    }

    return {
        action = "remove",
        requested = requests,
        install = [],
        remove = remove,
        blocked = [],
        dependents = dependents,
        warnings = warnings,
    }
}

function remove_reason_text(item) {
    if (!("reason" in item)) return ""
    if (item.reason == "manual") return "requested"
    if (item.reason == "dependent") return "depends on removed package"
    if (item.reason == "orphan") return "automatic orphan"
    return item.reason
}

function describe_plan(plan) {
    local lines = []
    if (plan == null) return ""
    if ("blocked" in plan && plan.blocked.len() > 0) {
        lines.append("Blocked")
        foreach (item in plan.blocked) {
            lines.append("  " + item.name + " is still required by " + item.required_by)
        }
        lines.append("")
    }
    if ("install" in plan && plan.install.len() > 0) {
        lines.append("Install")
        foreach (item in plan.install) {
            lines.append("  " + item.name + " " + item.version + " (" + item.reason + ")")
        }
        lines.append("")
    }
    if ("remove" in plan && plan.remove.len() > 0) {
        lines.append("Remove")
        foreach (item in plan.remove) {
            local reason = remove_reason_text(item)
            lines.append("  " + item.name + (reason == "" ? "" : " (" + reason + ")"))
        }
        if ("dependents" in plan && plan.dependents.len() > 0) {
            lines.append("")
            lines.append("This will also remove installed packages that depend on the requested package.")
        }
        lines.append("")
    }
    if ("cleanup" in plan && plan.cleanup.len() > 0) {
        lines.append("Clean Leftovers")
        foreach (item in plan.cleanup) {
            lines.append("  " + item.name + " " + item.version)
        }
        lines.append("")
    }
    if ("warnings" in plan && plan.warnings.len() > 0) {
        lines.append("Warnings")
        foreach (warning in plan.warnings) lines.append("  " + warning)
        lines.append("")
    }
    if (lines.len() == 0) lines.append("No package changes are needed.")
    return U.join(lines, "\n")
}

return {
    install_plan = install_plan,
    cleanup_plan = cleanup_plan,
    remove_plan = remove_plan,
    describe_plan = describe_plan,
}
