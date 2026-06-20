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

function put(t, key, value) {
    if (key in t) t[key] = value
    else t[key] <- value
}

async function run_argv_async(argv, cwd = null) {
    local flags = Gio.SubprocessFlags.stdout_pipe + Gio.SubprocessFlags.stderr_pipe
    local proc = null
    if (cwd == null) {
        proc = Gio.Subprocess.new(argv, flags)
    } else {
        local launcher = Gio.SubprocessLauncher.new(flags)
        launcher.set_cwd(cwd)
        proc = launcher.spawnv(argv)
    }

    local out = ""
    local err = ""
    local result = await proc.communicate_utf8_async(null, null)
    if (typeof result == "array") {
        if (result.len() > 0 && result[0] != null) out = result[0]
        if (result.len() > 1 && result[1] != null) err = result[1]
    }
    if (!proc.get_successful()) {
        local detail = err == "" ? out : err
        throw argv[0] + " failed with exit " + proc.get_exit_status() + ": " + detail
    }
    return out
}

function utc_now_iso() {
    return GLib.DateTime.new_now_utc().format("%Y-%m-%dT%H:%M:%SZ")
}

function clone_data(value) {
    return sqgi.json.parse(sqgi.json.stringify(value))
}

function add_parent_dirs(dirs, rel) {
    local parts = split_char(rel, "/")
    local path = ""
    for (local i = 0; i < parts.len() - 1; i++) {
        if (parts[i] == "") continue
        path = path == "" ? parts[i] : path + "/" + parts[i]
        dirs[path] <- true
    }
}

class SysrootTransaction {
    index = null
    status = null
    source_uri = null
    logger = null
    progress = null
    repo = null

    constructor(index, status, source_uri, logger = null, progress = null) {
        this.index = index
        this.status = status == null ? Status.empty(source_uri) : clone_data(status)
        this.source_uri = source_uri
        this.logger = logger
        this.progress = progress
        this.repo = Manifest.package_map(index)
        if (!("packages" in this.status)) this.status.packages <- {}
    }

    function log(line) {
        if (this.logger != null) this.logger(line)
    }

    function report(event) {
        if (this.progress != null) this.progress(event)
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

    function validate_tar_listing_text(listing, manifest) {
        local expected = this.expected_tar_paths(manifest)
        foreach (line in split_char(listing, "\n")) {
            local trimmed = U.trim(line)
            if (trimmed == "") continue
            local rel = normalized_relative_path(trimmed)
            if (rel == null) throw manifest.name + " artifact contains an unsafe path: " + trimmed
            if (rel == "") continue
            if (!(rel in expected)) throw manifest.name + " artifact contains a path missing from its manifest: " + rel
        }
    }

    function validate_tar_listing(artifact_path, manifest) {
        this.validate_tar_listing_text(run_argv(["tar", "-tzf", artifact_path]), manifest)
    }

    async function validate_tar_listing_async(artifact_path, manifest) {
        this.validate_tar_listing_text(await run_argv_async(["tar", "-tzf", artifact_path]), manifest)
    }

    function extract_artifact(artifact_path, manifest) {
        GLib.mkdir_with_parents(Config.sysroot_path(), 493)
        this.validate_tar_listing(artifact_path, manifest)
        this.log("extract: " + manifest.name)
        run_argv(["tar", "-xzf", artifact_path, "-C", Config.sysroot_path()])
    }

    async function extract_artifact_async(artifact_path, manifest, current = 0, total = 0) {
        GLib.mkdir_with_parents(Config.sysroot_path(), 493)
        this.report({
            phase = "extract",
            package = manifest.name,
            path = artifact_path,
            current = current,
            total = total,
            fraction = 0.0,
            done = false,
        })
        await this.validate_tar_listing_async(artifact_path, manifest)
        this.log("extract: " + manifest.name)
        await run_argv_async(["tar", "-xzf", artifact_path, "-C", Config.sysroot_path()])
        this.report({
            phase = "extract",
            package = manifest.name,
            path = artifact_path,
            current = current,
            total = total,
            fraction = 1.0,
            done = true,
        })
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

    function local_dir_owners(excluded = null) {
        local owners = {}
        foreach (name in U.sorted_keys(this.status.packages)) {
            if (excluded != null && name in excluded) continue
            local manifest = this.load_local_manifest(name, false)
            if (manifest == null) continue
            this.validate_manifest_paths(manifest)
            foreach (dir in manifest.directories) owners[dir] <- name
        }
        return owners
    }

    function manifest_dir_set(manifest) {
        local dirs = {}
        foreach (dir in manifest.directories) dirs[dir] <- true
        foreach (item in manifest.files) add_parent_dirs(dirs, item.path)
        return dirs
    }

    function detect_conflicts(manifests) {
        local owners = this.local_file_owners()
        local incoming = {}
        local replacements = {}
        foreach (manifest in manifests) {
            this.validate_manifest_paths(manifest)
            foreach (item in manifest.files) {
                if (item.path in incoming && incoming[item.path] != manifest.name) {
                    throw "file conflict between " + incoming[item.path] + " and " + manifest.name + ": " + item.path
                }
                incoming[item.path] <- manifest.name
                if (item.path in owners && owners[item.path] != manifest.name) {
                    local owner = owners[item.path]
                    if (!this.manifest_replaces_owner(manifest, owner)) {
                        throw "file conflict: " + manifest.name + " would overwrite " + item.path +
                            " owned by " + owner
                    }
                    if (!(owner in replacements)) replacements[owner] <- {}
                    replacements[owner][item.path] <- manifest.name
                }
                local disk_path = this.sysroot_path(item.path)
                local replaced_owner = item.path in owners && owners[item.path] != manifest.name &&
                    this.manifest_replaces_owner(manifest, owners[item.path])
                if (U.file_exists(disk_path) && (!(item.path in owners) ||
                    (owners[item.path] != manifest.name && !replaced_owner))) {
                    throw "refusing to overwrite unmanaged file: " + item.path +
                        " (use Clean Leftovers if this came from a failed install)"
                }
            }
        }
        return replacements
    }

    function manifest_replaces_owner(manifest, owner) {
        if (!("replaces" in manifest)) return false
        foreach (item in manifest.replaces) {
            if (typeof item == "string" && item == owner) return true
            if (item != null && typeof item == "table" && "name" in item && item.name == owner) return true
        }
        return false
    }

    function apply_replacement_transfers(replacements) {
        foreach (owner in U.sorted_keys(replacements)) {
            local manifest = this.load_local_manifest(owner, false)
            if (manifest == null) continue
            this.validate_manifest_paths(manifest)

            local kept = []
            local changed = 0
            foreach (item in manifest.files) {
                if (item.path in replacements[owner]) {
                    this.log("transfer ownership: " + item.path + " from " + owner +
                        " to " + replacements[owner][item.path])
                    changed++
                } else {
                    kept.append(item)
                }
            }

            if (changed > 0) {
                manifest.files = kept
                this.write_local_manifest(manifest)
            }
        }
    }

    function begin_install_rollback(manifests, replacement_owners = null) {
        local rollback = {
            status = clone_data(this.status),
            files = {},
            dirs = {},
            manifests = {},
        }

        foreach (manifest in manifests) {
            local files = {}
            foreach (item in manifest.files) {
                files[item.path] <- U.file_exists(this.sysroot_path(item.path))
            }
            rollback.files[manifest.name] <- files

            local dirs = {}
            foreach (dir in U.sorted_keys(this.manifest_dir_set(manifest))) {
                dirs[dir] <- U.is_directory(this.sysroot_path(dir))
            }
            rollback.dirs[manifest.name] <- dirs
        }

        local manifest_names = {}
        foreach (manifest in manifests) manifest_names[manifest.name] <- true
        if (replacement_owners != null) {
            foreach (name, files in replacement_owners) manifest_names[name] <- true
        }

        foreach (name in U.sorted_keys(manifest_names)) {
            local manifest_path = this.package_manifest_path(name)
            local existed = U.file_exists(manifest_path)
            rollback.manifests[name] <- {
                path = manifest_path,
                existed = existed,
                text = existed && U.is_regular(manifest_path) ? U.read_text(manifest_path) : "",
            }
        }

        return rollback
    }

    function rollback_install(rollback) {
        if (rollback == null) return
        this.log("install failed; rolling back extracted files")

        local files = {}
        foreach (name, package_files in rollback.files) {
            foreach (rel, existed in package_files) {
                if (!(rel in files)) files[rel] <- existed
                else if (existed) files[rel] = true
            }
        }

        foreach (rel in U.sorted_keys(files)) {
            if (files[rel]) continue
            local path = this.sysroot_path(rel)
            if (!U.file_exists(path)) continue
            try {
                U.delete_file(path)
                this.log("rollback: " + rel)
            } catch (e) {
                this.log("rollback kept: " + rel + " (" + e + ")")
            }
        }

        local dirs = {}
        foreach (name, package_dirs in rollback.dirs) {
            foreach (rel, existed in package_dirs) {
                if (!(rel in dirs)) dirs[rel] <- existed
                else if (existed) dirs[rel] = true
            }
        }

        local dir_list = U.sorted_keys(dirs)
        sort_deepest_first(dir_list)
        foreach (rel in dir_list) {
            if (dirs[rel] || rel == "") continue
            local path = this.sysroot_path(rel)
            if (!U.is_directory(path)) continue
            try {
                Gio.File.new_for_path(path).delete(null)
                this.log("rollback rmdir: " + rel)
            } catch (e) {
                this.log("rollback kept non-empty dir: " + rel)
            }
        }

        foreach (name in U.sorted_keys(rollback.manifests)) {
            local record = rollback.manifests[name]
            if (record.existed) {
                U.write_text_atomic(record.path, record.text)
            } else if (U.file_exists(record.path)) {
                try { U.delete_file(record.path) } catch (e) {}
            }
        }

        this.status = rollback.status
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

        local replacements = this.detect_conflicts(manifests)

        foreach (manifest in manifests) {
            local artifact = Cache.ensure_artifact(this.source_uri, manifest, function(line) { this.log(line) }.bindenv(this))
            if (artifact != null) artifacts[manifest.name] <- artifact
        }

        local rollback = this.begin_install_rollback(manifests, replacements)
        try {
            this.apply_replacement_transfers(replacements)
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
        } catch (e) {
            this.rollback_install(rollback)
            throw e
        }
        return this.status
    }

    async function install_async(plan) {
        if (plan == null) throw "missing install plan"
        if ("blocked" in plan && plan.blocked.len() > 0) throw "transaction is blocked"
        local requested = this.requested_set(plan)
        local manifests = []
        local artifacts = {}
        local total = plan.install.len()

        for (local i = 0; i < plan.install.len(); i++) {
            local item = plan.install[i]
            this.report({
                phase = "manifest",
                package = item.name,
                current = i + 1,
                total = total,
                done = false,
            })
            await sqgi.sleep(0)
            local manifest = this.remote_manifest(item.name)
            this.validate_manifest_paths(manifest)
            manifests.append(manifest)
        }

        this.report({ phase = "prepare", message = "Checking file conflicts", done = false })
        await sqgi.sleep(0)
        local replacements = this.detect_conflicts(manifests)

        for (local i = 0; i < manifests.len(); i++) {
            local manifest = manifests[i]
            local annotate = function(event) {
                put(event, "package", manifest.name)
                put(event, "current", i + 1)
                put(event, "total", manifests.len())
                this.report(event)
            }
            local artifact = await Cache.ensure_artifact_async(this.source_uri, manifest,
                function(line) { this.log(line) }.bindenv(this),
                annotate.bindenv(this))
            if (artifact != null) artifacts[manifest.name] <- artifact
        }

        local rollback = this.begin_install_rollback(manifests, replacements)
        try {
            this.apply_replacement_transfers(replacements)
            for (local i = 0; i < manifests.len(); i++) {
                local manifest = manifests[i]
                if (manifest.name in artifacts) {
                    await this.extract_artifact_async(artifacts[manifest.name], manifest, i + 1, manifests.len())
                } else {
                    this.log("record meta package: " + manifest.name)
                }

                local old_manual = Status.is_manual(this.status, manifest.name)
                local manual = old_manual || (manifest.name in requested)
                this.write_local_manifest(manifest)
                this.mark_installed(manifest, manual)
                await sqgi.sleep(0)
            }

            foreach (name in U.sorted_keys(requested)) {
                if (Status.installed(this.status, name)) this.status.packages[name].manual <- true
            }

            this.report({ phase = "status", message = "Saving status", done = false })
            this.save_status()
            this.log("status saved")
            this.report({ phase = "status", message = "Status saved", done = true })
        } catch (e) {
            this.report({ phase = "cleanup", message = "Rolling back failed install", done = false })
            this.rollback_install(rollback)
            this.report({ phase = "cleanup", message = "Rolled back failed install", done = true })
            throw e
        }
        return this.status
    }

    function cleanup_items(plan) {
        if (plan != null && "cleanup" in plan) return plan.cleanup
        if (plan != null && "install" in plan) return plan.install
        return []
    }

    function cleanup_manifest(manifest) {
        this.validate_manifest_paths(manifest)
        local owners = this.local_file_owners()
        local dir_owners = this.local_dir_owners()
        local cleaned = 0

        foreach (item in manifest.files) {
            if (item.path in owners) {
                this.log("keep owned: " + item.path)
                continue
            }
            local path = this.sysroot_path(item.path)
            if (U.file_exists(path)) {
                this.log("clean leftover: " + item.path)
                U.delete_file(path)
                cleaned++
            }
        }

        if (!Status.installed(this.status, manifest.name)) {
            local manifest_path = this.package_manifest_path(manifest.name)
            if (U.file_exists(manifest_path)) {
                this.log("clean stale manifest: " + manifest.name)
                U.delete_file(manifest_path)
                cleaned++
            }
        }

        local dir_list = U.sorted_keys(this.manifest_dir_set(manifest))
        sort_deepest_first(dir_list)
        foreach (rel in dir_list) {
            if (rel == "" || rel in dir_owners) continue
            local path = this.sysroot_path(rel)
            if (U.is_directory(path)) {
                try {
                    Gio.File.new_for_path(path).delete(null)
                    this.log("clean rmdir: " + rel)
                    cleaned++
                } catch (e) {
                    this.log("keep non-empty dir: " + rel)
                }
            }
        }

        return cleaned
    }

    function cleanup(plan) {
        if (plan == null) throw "missing cleanup plan"
        local total = 0
        foreach (item in this.cleanup_items(plan)) {
            local manifest = this.remote_manifest(item.name)
            total += this.cleanup_manifest(manifest)
        }
        this.log("cleaned " + total + " leftover item(s)")
        return this.status
    }

    async function cleanup_async(plan) {
        if (plan == null) throw "missing cleanup plan"
        local items = this.cleanup_items(plan)
        local total_cleaned = 0
        for (local i = 0; i < items.len(); i++) {
            local item = items[i]
            this.report({
                phase = "cleanup",
                package = item.name,
                current = i + 1,
                total = items.len(),
                done = false,
            })
            await sqgi.sleep(0)
            local manifest = this.remote_manifest(item.name)
            total_cleaned += this.cleanup_manifest(manifest)
        }
        this.log("cleaned " + total_cleaned + " leftover item(s)")
        this.report({
            phase = "cleanup",
            message = "Cleaned " + total_cleaned + " leftover item(s)",
            done = true,
        })
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

    async function remove_async(plan) {
        if (plan == null) throw "missing remove plan"
        if ("blocked" in plan && plan.blocked.len() > 0) throw "transaction is blocked"

        local removing = {}
        local manifests = []
        for (local i = 0; i < plan.remove.len(); i++) {
            local item = plan.remove[i]
            this.report({
                phase = "remove",
                package = item.name,
                current = i + 1,
                total = plan.remove.len(),
                done = false,
            })
            removing[item.name] <- true
            local manifest = this.load_local_manifest(item.name, true)
            this.validate_manifest_paths(manifest)
            manifests.append(manifest)
            await sqgi.sleep(0)
        }

        local remaining_owners = this.local_file_owners(removing)
        local files = {}
        local dirs = {}
        foreach (manifest in manifests) {
            foreach (item in manifest.files) files[item.path] <- manifest.name
            foreach (dir in manifest.directories) dirs[dir] <- true
        }

        local file_list = U.sorted_keys(files)
        for (local i = 0; i < file_list.len(); i++) {
            local rel = file_list[i]
            this.report({
                phase = "remove",
                path = rel,
                current = i + 1,
                total = file_list.len(),
                fraction = file_list.len() > 0 ? (i + 1).tofloat() / file_list.len().tofloat() : 1.0,
                done = false,
            })
            if (rel in remaining_owners) {
                this.log("keep shared: " + rel)
            } else {
                local path = this.sysroot_path(rel)
                if (U.file_exists(path)) {
                    this.log("remove: " + rel)
                    U.delete_file(path)
                }
            }
            if ((i % 64) == 0) await sqgi.sleep(0)
        }

        local dir_list = U.sorted_keys(dirs)
        sort_deepest_first(dir_list)
        for (local i = 0; i < dir_list.len(); i++) {
            local rel = dir_list[i]
            if (rel != "") {
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
            if ((i % 64) == 0) await sqgi.sleep(0)
        }

        foreach (item in plan.remove) {
            local manifest_path = this.status_manifest_path(item.name)
            if (U.file_exists(manifest_path)) U.delete_file(manifest_path)
            if (item.name in this.status.packages) this.status.packages.rawdelete(item.name)
        }

        this.save_status()
        this.log("status saved")
        this.report({ phase = "status", message = "Status saved", done = true })
        return this.status
    }
}

return {
    SysrootTransaction = SysrootTransaction,
    normalized_relative_path = normalized_relative_path,
}
