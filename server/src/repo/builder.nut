local GLib = import("GLib")
local U = import("../util.nut")

class CommandRunner {
    constructor() {}

    function shell_status(result) {
        local status = result[2]
        if (status > 255) return status / 256
        return status
    }

    function run(command, cwd = null) {
        local script = cwd == null ? command : "cd " + U.shell_quote(cwd) + " && " + command
        local result = GLib.spawn_command_line_sync("/bin/sh -c " + U.shell_quote(script))
        local code = this.shell_status(result)
        if (code != 0) throw "command failed with exit " + code + ": " + command + "\n" + result[1]
        return result[0]
    }

    function output(command, fallback = null) {
        try {
            return U.trim(this.run(command))
        } catch (e) {
            if (fallback != null) return fallback
            throw e
        }
    }
}

class RepositoryBuilder {
    runner = null
    logs = null

    constructor(runner = null) {
        this.runner = runner == null ? CommandRunner() : runner
        this.logs = []
    }

    function canonical(path) {
        return GLib.canonicalize_filename(path, null)
    }

    function path_join(parts) {
        return GLib.build_filenamev(parts)
    }

    function root_path(root, path) {
        if (GLib.path_is_absolute(path)) return this.canonical(path)
        return this.canonical(this.path_join([root, path]))
    }

    function find_root() {
        local cur = this.canonical(GLib.get_current_dir())
        while (true) {
            if (U.file_exists(this.path_join([cur, "manifest", "packages.json"])) &&
                U.file_exists(this.path_join([cur, "tools", "ooblerg.nut"]))) {
                return cur
            }
            local parent = GLib.path_get_dirname(cur)
            if (parent == cur || parent == "" || parent == null) break
            cur = parent
        }
        throw "could not find ooblerg repository root"
    }

    function normalize_options(opts) {
        local out = {}
        foreach (key, value in opts) out[key] <- value

        local root = ""
        if ("root" in opts && opts.root != null && opts.root != "") root = this.canonical(opts.root)
        else root = this.find_root()

        out.root <- root
        out.artifact_dir <- this.root_path(root, "artifact_dir" in opts ? opts.artifact_dir : "out/artifacts")
        out.repo_dir <- this.root_path(root, "repo_dir" in opts ? opts.repo_dir : "out/repo")
        out.repository <- "repository" in opts ? opts.repository : "ooblerg-local"
        out.packages <- "packages" in opts ? opts.packages : []
        out.include_deps <- "include_deps" in opts ? opts.include_deps : false
        out.only <- "only" in opts ? opts.only : false
        return out
    }

    function log(line) {
        this.logs.append(line)
    }

    function mkdir_p(path) {
        GLib.mkdir_with_parents(path, 493)
    }

    function write_text(path, text) {
        this.mkdir_p(GLib.path_get_dirname(path))
        GLib.file_set_contents(path, text, -1)
    }

    function write_json(path, value) {
        this.write_text(path, sqgi.json.stringify(value, 2) + "\n")
    }

    function assign_package_value(pkg, key, value) {
        if (key in pkg) pkg[key] = value
        else pkg[key] <- value
    }

    function package_value_missing(pkg, key) {
        if (!(key in pkg)) return true
        local value = pkg[key]
        if (typeof value == "string") return value == ""
        if (typeof value == "array") return value.len() == 0
        return false
    }

    function merge_package_tags(pkg, metadata) {
        if (!("tags" in metadata)) return
        local out = []
        local seen = {}
        if ("tags" in pkg) {
            foreach (tag in pkg.tags) {
                if (tag in seen) continue
                seen[tag] <- true
                out.append(tag)
            }
        }
        foreach (tag in metadata.tags) {
            if (tag in seen) continue
            seen[tag] <- true
            out.append(tag)
        }
        if (out.len() > 0) this.assign_package_value(pkg, "tags", out)
    }

    function merge_package_metadata(root, data) {
        local path = this.path_join([root, "manifest", "package-metadata.json"])
        if (!U.file_exists(path)) return
        local metadata = sqgi.json.parse(GLib.file_get_contents(path))
        if (!("packages" in metadata)) return
        foreach (pkg in data.packages) {
            if (!(pkg.name in metadata.packages)) continue
            local item = metadata.packages[pkg.name]
            foreach (key in ["summary", "description"]) {
                if ((key in item) && this.package_value_missing(pkg, key)) {
                    this.assign_package_value(pkg, key, item[key])
                }
            }
            this.merge_package_tags(pkg, item)
        }
    }

    function load_manifest(root) {
        local data = sqgi.json.parse(GLib.file_get_contents(this.path_join([root, "manifest", "packages.json"])))
        this.merge_package_metadata(root, data)
        local packages = {}
        foreach (pkg in data.packages) packages[pkg.name] <- pkg
        return { data = data, packages = packages }
    }

    function package_or_die(packages, name) {
        if (!(name in packages)) throw "unknown package: " + name
        return packages[name]
    }

    function dependency_closure(packages, roots) {
        local seen = {}
        local ordered = []
        local stack = []
        for (local i = roots.len() - 1; i >= 0; i--) stack.append({ name = roots[i], expanded = false })

        while (stack.len() > 0) {
            local frame = stack.pop()
            local name = frame.name
            if (frame.expanded) {
                if (!(name in seen)) {
                    seen[name] <- true
                    ordered.append(name)
                }
                continue
            }
            if (name in seen) continue

            local pkg = this.package_or_die(packages, name)
            stack.append({ name = name, expanded = true })
            if ("deps" in pkg) {
                for (local i = pkg.deps.len() - 1; i >= 0; i--) {
                    if (!(pkg.deps[i] in seen)) stack.append({ name = pkg.deps[i], expanded = false })
                }
            }
        }
        return ordered
    }

    function split_char(s, ch) {
        local out = []
        local start = 0
        for (local i = 0; i < s.len(); i++) {
            if (s.slice(i, i + 1) == ch) {
                out.append(s.slice(start, i))
                start = i + 1
            }
        }
        out.append(s.slice(start))
        return out
    }

    function split_lines(s) {
        local out = []
        foreach (line in this.split_char(s == null ? "" : s, "\n")) {
            local t = U.trim(line)
            if (t != "") out.append(t)
        }
        return out
    }

    function split_words(s) {
        local out = []
        local cur = ""
        for (local i = 0; i < s.len(); i++) {
            local ch = s.slice(i, i + 1)
            if (ch == " " || ch == "\t" || ch == "\n" || ch == "\r") {
                if (cur != "") {
                    out.append(cur)
                    cur = ""
                }
            } else {
                cur += ch
            }
        }
        if (cur != "") out.append(cur)
        return out
    }

    function array_tail(items, start) {
        local out = []
        for (local i = start; i < items.len(); i++) out.append(items[i])
        return out
    }

    function replace_all(s, needle, replacement) {
        if (needle == "") return s
        local out = ""
        local start = 0
        while (true) {
            local p = s.find(needle, start)
            if (p == null) {
                out += s.slice(start)
                break
            }
            out += s.slice(start, p) + replacement
            start = p + needle.len()
        }
        return out
    }

    function compare_strings(a, b) {
        if (a < b) return -1
        if (a > b) return 1
        return 0
    }

    function sorted_keys(table) {
        local out = []
        foreach (key, value in table) out.append(key)
        out.sort()
        return out
    }

    function tar_version(version) {
        return this.replace_all(this.replace_all(this.replace_all(version, ":", "_"), "~", "."), "+", "+")
    }

    function apt_candidate(binary_pkg) {
        local text = this.runner.output("apt-cache policy " + U.shell_quote(binary_pkg), "")
        foreach (line in this.split_lines(text)) {
            local t = U.trim(line)
            if (U.starts_with(t, "Candidate:")) return U.trim(t.slice("Candidate:".len()))
        }
        return null
    }

    function package_version(pkg) {
        local version = null
        if (!("version_package" in pkg) || pkg.version_package == "") {
            if ("kind" in pkg && pkg.kind == "meta") return ("version" in pkg) ? pkg.version : "1"
            version = ("version" in pkg) ? pkg.version : "unknown"
        } else {
            local candidate = this.apt_candidate(pkg.version_package)
            version = (candidate != null && candidate != "") ? candidate : (("version" in pkg) ? pkg.version : "unknown")
        }
        if ("version_suffix" in pkg && pkg.version_suffix != "") version += pkg.version_suffix
        return version
    }

    function artifact_filename(pkg, version) {
        return pkg.name + "-" + this.tar_version(version) + "-x86_64-w64-mingw32.tar.gz"
    }

    function file_size(path) {
        return this.runner.output("stat -c %s " + U.shell_quote(path)).tointeger()
    }

    function file_hash(path) {
        return this.split_words(this.runner.output("sha256sum " + U.shell_quote(path)))[0]
    }

    function safe_tar_member_name(name) {
        if (name == "") return null
        local normalized = this.replace_all(name, "\\", "/")
        if (U.starts_with(normalized, "/")) return null
        if (normalized.len() >= 2 && normalized.slice(1, 2) == ":") return null
        local parts = []
        foreach (part in this.split_char(normalized, "/")) {
            if (part == "" || part == ".") continue
            if (part == "..") return null
            parts.append(part)
        }
        return U.join(parts, "/")
    }

    function parse_tar_listing_line(line) {
        local words = this.split_words(line)
        if (words.len() < 6) return null
        local perms = words[0]
        local kind_ch = perms.slice(0, 1)
        local size = 0
        try { size = words[2].tointeger() } catch (e) { size = 0 }
        local name = U.join(this.array_tail(words, 5), " ")
        local target = ""
        if (kind_ch == "l") {
            local arrow = name.find(" -> ")
            if (arrow != null) {
                target = name.slice(arrow + 4)
                name = name.slice(0, arrow)
            }
        } else if (kind_ch == "h") {
            local hardlink = name.find(" link to ")
            if (hardlink != null) {
                target = name.slice(hardlink + 9)
                name = name.slice(0, hardlink)
            }
        }
        local safe = this.safe_tar_member_name(name)
        if (safe == null) throw "unsafe tar member: " + name
        return { kind_ch = kind_ch, path = safe, size = size, target = target }
    }

    function add_parent_dir(set, path) {
        local dir = GLib.path_get_dirname(path)
        if (dir != "." && dir != "" && dir != null) set[this.replace_all(dir, "\\", "/")] <- true
    }

    function artifact_members(artifact) {
        local files = []
        local dirs = {}
        local installed_size = 0
        local listing = this.runner.output("tar -tvzf " + U.shell_quote(artifact))
        foreach (line in this.split_lines(listing)) {
            local item = this.parse_tar_listing_line(line)
            if (item == null) continue
            if (item.kind_ch == "d") {
                if (item.path != "") dirs[item.path] <- true
            } else if (item.kind_ch == "l") {
                this.add_parent_dir(dirs, item.path)
                files.append({ path = item.path, size = 0, kind = "symlink", target = item.target })
            } else if (item.kind_ch == "h") {
                this.add_parent_dir(dirs, item.path)
                files.append({ path = item.path, size = 0, kind = "hardlink", target = item.target })
            } else if (item.kind_ch == "-") {
                this.add_parent_dir(dirs, item.path)
                files.append({ path = item.path, size = item.size, kind = "file" })
                installed_size += item.size
            } else {
                this.add_parent_dir(dirs, item.path)
                files.append({ path = item.path, size = 0, kind = "special" })
            }
        }
        files.sort(function(a, b) { return this.compare_strings(a.path, b.path) }.bindenv(this))
        return { files = files, directories = this.sorted_keys(dirs), installed_size = installed_size }
    }

    function summarize_package(pkg) {
        local text = ("summary" in pkg) ? pkg.summary : (("description" in pkg) ? pkg.description : pkg.name)
        local p = text.find(".")
        return U.trim(p == null ? text : text.slice(0, p))
    }

    function package_manifest(data, pkg, version, artifact, artifact_rel, built_at) {
        local deps = []
        if ("deps" in pkg) foreach (dep in pkg.deps) deps.append({ name = dep })
        local files = []
        local directories = []
        local installed_size = 0
        local artifact_info = null
        if (artifact != null && U.file_exists(artifact)) {
            local members = this.artifact_members(artifact)
            files = members.files
            directories = members.directories
            installed_size = members.installed_size
            artifact_info = {
                filename = GLib.path_get_basename(artifact),
                size = this.file_size(artifact),
                sha256 = this.file_hash(artifact),
                path = artifact_rel,
            }
        }
        local provides = ("provides" in pkg) ? pkg.provides : [pkg.name]
        return {
            schema = 1,
            name = pkg.name,
            version = version,
            target = data.target,
            architecture = "x86_64",
            kind = ("kind" in pkg) ? pkg.kind : "package",
            summary = this.summarize_package(pkg),
            description = ("description" in pkg) ? pkg.description : this.summarize_package(pkg),
            artifact = artifact_info,
            dependencies = deps,
            provides = provides,
            conflicts = ("conflicts" in pkg) ? pkg.conflicts : [],
            replaces = ("replaces" in pkg) ? pkg.replaces : [],
            files = files,
            directories = directories,
            installed_size = installed_size,
            build = {
                source = ("source" in pkg) ? pkg.source : (("source_from" in pkg) ? pkg.source_from : pkg.name),
                version_package = ("version_package" in pkg) ? pkg.version_package : "",
                recipe_revision = "workspace",
                built_at = built_at,
            },
            license = ("license" in pkg) ? pkg.license : {},
            tags = ("tags" in pkg) ? pkg.tags : [],
        }
    }

    function index_entry(manifest_rel, artifact_rel, manifest) {
        local deps = []
        foreach (dep in manifest.dependencies) deps.append(dep.name)
        local entry = {
            name = manifest.name,
            version = manifest.version,
            kind = manifest.kind,
            summary = manifest.summary,
            description = manifest.description,
            manifest = manifest_rel,
            dependencies = deps,
            installed_size = manifest.installed_size,
            tags = manifest.tags,
        }
        if (manifest.artifact != null) {
            entry.artifact <- artifact_rel
            entry.sha256 <- manifest.artifact.sha256
            entry.size <- manifest.artifact.size
        }
        return entry
    }

    function link_or_copy(src, dst) {
        this.mkdir_p(GLib.path_get_dirname(dst))
        local cmd = "rm -f " + U.shell_quote(dst) +
            " && (ln " + U.shell_quote(src) + " " + U.shell_quote(dst) +
            " || cp -a " + U.shell_quote(src) + " " + U.shell_quote(dst) + ")"
        this.log("+ " + cmd)
        this.runner.run(cmd)
    }

    function utc_now_iso() {
        return this.runner.output("date -u +%Y-%m-%dT%H:%M:%SZ")
    }

    function selected_name_set(names) {
        local out = {}
        foreach (name in names) out[name] <- true
        return out
    }

    function existing_index_entries(index_path, selected) {
        local out = []
        if (!U.file_exists(index_path)) return out
        local index = sqgi.json.parse(GLib.file_get_contents(index_path))
        if (!("packages" in index)) return out
        foreach (entry in index.packages) {
            if (("name" in entry) && entry.name in selected) continue
            out.append(entry)
        }
        return out
    }

    function package_names(loaded, opts) {
        if (opts.packages.len() == 0) {
            local names = []
            foreach (pkg in loaded.data.packages) names.append(pkg.name)
            return names
        }
        return opts.include_deps ? this.dependency_closure(loaded.packages, opts.packages) : opts.packages
    }

    function rebuild(opts) {
        this.logs = []
        local normalized = this.normalize_options(opts)
        local loaded = this.load_manifest(normalized.root)
        local data = loaded.data
        local v1 = this.path_join([normalized.repo_dir, "v1"])
        local built_at = this.utc_now_iso()
        local entries = []
        local names = this.package_names(loaded, normalized)
        local index_path = this.path_join([v1, "index.json"])

        if (normalized.packages.len() > 0 && !normalized.only) {
            local selected = this.selected_name_set(names)
            entries = this.existing_index_entries(index_path, selected)
            if (!U.file_exists(index_path)) {
                this.log("partial repo-index: no existing index found; writing selected packages only")
            } else {
                this.log("partial repo-index: preserving " + entries.len() + " existing package entries; use --only to write a subset index")
            }
        }

        foreach (name in names) {
            local pkg = this.package_or_die(loaded.packages, name)
            local version = this.package_version(pkg)
            local filename = this.artifact_filename(pkg, version)
            local artifact = this.path_join([normalized.artifact_dir, filename])
            local manifest_rel = "packages/" + name + "/" + this.replace_all(filename, ".tar.gz", ".pkg.json")
            local artifact_rel = "packages/" + name + "/" + filename
            local is_meta = ("kind" in pkg && pkg.kind == "meta")

            if (!is_meta && !U.file_exists(artifact)) {
                this.log(name + ": skipping; artifact not found: " + artifact)
                continue
            }

            local has_artifact = U.file_exists(artifact)
            local manifest = this.package_manifest(data, pkg, version, has_artifact ? artifact : null, has_artifact ? artifact_rel : null, built_at)
            this.write_json(this.path_join([v1, manifest_rel]), manifest)
            if (has_artifact) this.link_or_copy(artifact, this.path_join([v1, artifact_rel]))
            entries.append(this.index_entry(manifest_rel, has_artifact ? artifact_rel : null, manifest))
            this.log(name + ": indexed " + version)
        }

        entries.sort(function(a, b) { return this.compare_strings(a.name, b.name) }.bindenv(this))
        local index = {
            schema = 1,
            repository = normalized.repository,
            generated_at = built_at,
            target = data.target,
            prefix = data.prefix,
            packages = entries,
        }
        this.write_json(index_path, index)
        this.write_text(this.path_join([v1, "index.json.sha256"]), this.file_hash(index_path) + "  index.json\n")
        this.log("wrote " + index_path)
        this.log("wrote " + this.path_join([v1, "index.json.sha256"]))
        return U.join(this.logs, "\n") + "\n"
    }
}

function find_root() {
    return RepositoryBuilder().find_root()
}

function normalize_options(opts) {
    return RepositoryBuilder().normalize_options(opts)
}

function rebuild(opts) {
    return RepositoryBuilder().rebuild(opts)
}

return {
    CommandRunner = CommandRunner,
    RepositoryBuilder = RepositoryBuilder,
    find_root = find_root,
    normalize_options = normalize_options,
    rebuild = rebuild,
}
