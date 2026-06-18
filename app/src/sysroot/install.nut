local GLib = import("GLib")
local Gio = import("Gio")

local Config = import("../config.nut")
local U = import("../util.nut")
local Client = import("../repo/client.nut")
local Cache = import("../repo/cache.nut")
local Manifest = import("../pkg/manifest.nut")
local Status = import("../pkg/status.nut")

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

function normalized_relative_path(path) {
    if (path == null) return null
    if (path == "") return ""
    local p = replace_all(path, "\\", "/")
    if (U.starts_with(p, "/")) return null
    if (p.len() >= 2 && p.slice(1, 2) == ":") return null
    local parts = []
    foreach (part in split_char(p, "/")) {
        if (part == "" || part == ".") continue
        if (part == "..") return null
        parts.append(part)
    }
    if (parts.len() == 0) return ""
    return U.join(parts, "/")
}

function path_depth(path) {
    if (path == "") return 0
    return split_char(path, "/").len()
}

function sort_deepest_first(items) {
    items.sort(function(a, b) {
        local da = path_depth(a)
        local db = path_depth(b)
        if (da > db) return -1
        if (da < db) return 1
        if (a > b) return -1
        if (a < b) return 1
        return 0
    })
    return items
}

function shell_status(status) {
    if (status > 255) return status / 256
    return status
}

function run_argv(argv, cwd = null) {
    local result = GLib.spawn_sync(cwd, argv, null, GLib.SpawnFlags.search_path, null, null)
    local code = shell_status(result[2])
    if (code != 0) {
        local err = result[1] == "" ? result[0] : result[1]
        throw argv[0] + " failed with exit " + code + ": " + err
    }
    return result[0]
}

function utc_now_iso() {
    return GLib.DateTime.new_now_utc().format("%Y-%m-%dT%H:%M:%SZ")
}

class SysrootTransaction {
    index = null
    status = null
    source_uri = null
    logger = null
    repo = null

    constructor(index, status, source_uri, logger = null) {
        this.index = index
        this.status = status == null ? Status.empty(source_uri) : status
        this.source_uri = source_uri
        this.logger = logger
        this.repo = Manifest.package_map(index)
        if (!("packages" in this.status)) this.status.packages <- {}
    }

    function log(line) {
        if (this.logger != null) this.logger(line)
    }

    function sysroot_path(rel = null) {
        if (rel == null || rel == "") return Config.sysroot_path()
        local parts = [Config.sysroot_path()]
        foreach (part in split_char(rel, "/")) parts.append(part)
        return GLib.build_filenamev(parts)
    }

    function package_manifest_rel(name) {
        return "var/lib/ooblerg/packages/" + name + ".pkg.json"
    }

    function package_manifest_path(name) {
        return GLib.build_filenamev([Config.package_db_dir(), name + ".pkg.json"])
    }

    function status_manifest_path(name) {
        local info = Status.info(this.status, name)
        if (info != null && "manifest" in info && info.manifest != "") {
            if (GLib.path_is_absolute(info.manifest)) return info.manifest
            local parts = [Config.sysroot_path()]
            foreach (part in split_char(replace_all(info.manifest, "\\", "/"), "/")) {
                if (part != "") parts.append(part)
            }
            return GLib.build_filenamev(parts)
        }
        return this.package_manifest_path(name)
    }

    function load_local_manifest(name, required = true) {
        local path = this.status_manifest_path(name)
        if (!U.file_exists(path)) {
            if (required) throw "missing local manifest for installed package " + name + ": " + path
            return null
        }
        return U.read_json(path)
    }

    function remote_manifest(name) {
        if (!(name in this.repo)) throw "missing package: " + name
        local manifest = Client.load_package_manifest(this.source_uri, this.repo[name])
        if (manifest.name != name) throw "manifest name mismatch for " + name + ": got " + manifest.name
        return manifest
    }

    function validate_manifest_paths(manifest) {
        if (manifest == null) throw "empty package manifest"
        if (!("name" in manifest) || manifest.name == "") throw "package manifest is missing a name"
        if (!("version" in manifest) || manifest.version == "") throw manifest.name + " is missing a version"
        if (!("files" in manifest)) manifest.files <- []
        if (!("directories" in manifest)) manifest.directories <- []

        local files = {}
        foreach (item in manifest.files) {
            if (item == null || !("path" in item)) throw manifest.name + " has a file entry without a path"
            local rel = normalized_relative_path(item.path)
            if (rel == null || rel == "") throw manifest.name + " has an unsafe file path: " + item.path
            item.path = rel
            files[rel] <- true
        }

        local dirs = {}
        foreach (path in manifest.directories) {
            local rel = normalized_relative_path(path)
            if (rel == null) throw manifest.name + " has an unsafe directory path: " + path
            if (rel != "") dirs[rel] <- true
        }

        manifest.directories = U.sorted_keys(dirs)
        return files
    }

    function expected_tar_paths(manifest) {
        local out = {}
        foreach (item in manifest.files) out[item.path] <- true
        foreach (path in manifest.directories) out[path] <- true
        return out
    }

    function validate_tar_listing(artifact_path, manifest) {
        local expected = this.expected_tar_paths(manifest)
        local listing = run_argv(["tar", "-tzf", artifact_path])
        foreach (line in split_char(listing, "\n")) {
            local trimmed = U.trim(line)
            if (trimmed == "") continue
            local rel = normalized_relative_path(trimmed)
            if (rel == null) throw manifest.name + " artifact contains an unsafe path: " + trimmed
            if (rel == "") continue
            if (!(rel in expected)) throw manifest.name + " artifact contains a path missing from its manifest: " + rel
        }
    }

    function extract_artifact(artifact_path, manifest) {
        GLib.mkdir_with_parents(Config.sysroot_path(), 493)
        this.validate_tar_listing(artifact_path, manifest)
        this.log("extract: " + manifest.name)
        run_argv(["tar", "-xzf", artifact_path, "-C", Config.sysroot_path()])
    }

    function local_file_owners(excluded = null) {
        local owners = {}
        foreach (name in U.sorted_keys(this.status.packages)) {
            if (excluded != null && name in excluded) continue
            local manifest = this.load_local_manifest(name, false)
            if (manifest == null) continue
            this.validate_manifest_paths(manifest)
            foreach (item in manifest.files) owners[item.path] <- name
        }
        return owners
    }

    function detect_conflicts(manifests) {
        local owners = this.local_file_owners()
        local incoming = {}
        foreach (manifest in manifests) {
            this.validate_manifest_paths(manifest)
            foreach (item in manifest.files) {
                if (item.path in incoming && incoming[item.path] != manifest.name) {
                    throw "file conflict between " + incoming[item.path] + " and " + manifest.name + ": " + item.path
                }
                incoming[item.path] <- manifest.name
                if (item.path in owners && owners[item.path] != manifest.name) {
                    throw "file conflict: " + manifest.name + " would overwrite " + item.path +
                        " owned by " + owners[item.path]
                }
                local disk_path = this.sysroot_path(item.path)
                if (U.file_exists(disk_path) && (!(item.path in owners) || owners[item.path] != manifest.name)) {
                    throw "refusing to overwrite unmanaged file: " + item.path
                }
            }
        }
    }

    function write_local_manifest(manifest) {
        U.write_json_atomic(this.package_manifest_path(manifest.name), manifest)
    }

    function mark_installed(manifest, manual) {
        this.status.packages[manifest.name] <- {
            version = manifest.version,
            kind = "kind" in manifest ? manifest.kind : "package",
            manual = manual,
            installed_at = utc_now_iso(),
            manifest = this.package_manifest_rel(manifest.name),
        }
    }

    function save_status() {
        this.status.source_uri <- this.source_uri
        Status.save(this.status)
    }

    function requested_set(plan) {
        local out = {}
        if (plan != null && "requested" in plan) {
            foreach (name in plan.requested) out[name] <- true
        }
        return out
    }

    function install(plan) {
        if (plan == null) throw "missing install plan"
        if ("blocked" in plan && plan.blocked.len() > 0) throw "transaction is blocked"
        local requested = this.requested_set(plan)
        local manifests = []
        local artifacts = {}

        foreach (item in plan.install) {
            local manifest = this.remote_manifest(item.name)
            this.validate_manifest_paths(manifest)
            manifests.append(manifest)
        }

        this.detect_conflicts(manifests)

        foreach (manifest in manifests) {
            local artifact = Cache.ensure_artifact(this.source_uri, manifest, function(line) { this.log(line) }.bindenv(this))
            if (artifact != null) artifacts[manifest.name] <- artifact
        }

        foreach (manifest in manifests) {
            if (manifest.name in artifacts) this.extract_artifact(artifacts[manifest.name], manifest)
            else this.log("record meta package: " + manifest.name)

            local old_manual = Status.is_manual(this.status, manifest.name)
            local manual = old_manual || (manifest.name in requested)
            this.write_local_manifest(manifest)
            this.mark_installed(manifest, manual)
        }

        foreach (name in U.sorted_keys(requested)) {
            if (Status.installed(this.status, name)) this.status.packages[name].manual <- true
        }

        this.save_status()
        this.log("status saved")
        return this.status
    }

    function remove(plan) {
        if (plan == null) throw "missing remove plan"
        if ("blocked" in plan && plan.blocked.len() > 0) throw "transaction is blocked"

        local removing = {}
        local manifests = []
        foreach (item in plan.remove) {
            removing[item.name] <- true
            local manifest = this.load_local_manifest(item.name, true)
            this.validate_manifest_paths(manifest)
            manifests.append(manifest)
        }

        local remaining_owners = this.local_file_owners(removing)
        local files = {}
        local dirs = {}
        foreach (manifest in manifests) {
            foreach (item in manifest.files) files[item.path] <- manifest.name
            foreach (dir in manifest.directories) dirs[dir] <- true
        }

        foreach (rel in U.sorted_keys(files)) {
            if (rel in remaining_owners) {
                this.log("keep shared: " + rel)
                continue
            }
            local path = this.sysroot_path(rel)
            if (U.file_exists(path)) {
                this.log("remove: " + rel)
                U.delete_file(path)
            }
        }

        local dir_list = U.sorted_keys(dirs)
        sort_deepest_first(dir_list)
        foreach (rel in dir_list) {
            if (rel == "") continue
            local path = this.sysroot_path(rel)
            if (U.is_directory(path)) {
                try {
                    Gio.File.new_for_path(path).delete(null)
                    this.log("rmdir: " + rel)
                } catch (e) {
                    this.log("keep non-empty dir: " + rel)
                }
            }
        }

        foreach (item in plan.remove) {
            local manifest_path = this.status_manifest_path(item.name)
            if (U.file_exists(manifest_path)) U.delete_file(manifest_path)
            if (item.name in this.status.packages) this.status.packages.rawdelete(item.name)
        }

        this.save_status()
        this.log("status saved")
        return this.status
    }
}

return {
    SysrootTransaction = SysrootTransaction,
    normalized_relative_path = normalized_relative_path,
}
