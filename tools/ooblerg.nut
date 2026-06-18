#!/usr/bin/env sqgi
local GLib = import("GLib")
local Gio = import("Gio")

local BUILD_TOOL_SHIMS = [
    "glib-compile-resources",
    "glib-compile-schemas",
    "glib-genmarshal",
    "glib-mkenums",
    "gdbus-codegen",
]

function starts_with(s, prefix) {
    return s != null && prefix != null && s.find(prefix) == 0
}

function ends_with(s, suffix) {
    if (s == null || suffix == null) return false
    if (s.len() < suffix.len()) return false
    return s.slice(s.len() - suffix.len()) == suffix
}

function trim(s) {
    if (s == null) return ""
    local a = 0
    local b = s.len()
    while (a < b) {
        local ch = s.slice(a, a + 1)
        if (ch != " " && ch != "\t" && ch != "\n" && ch != "\r") break
        a++
    }
    while (b > a) {
        local ch = s.slice(b - 1, b)
        if (ch != " " && ch != "\t" && ch != "\n" && ch != "\r") break
        b--
    }
    return s.slice(a, b)
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
    foreach (line in split_char(s == null ? "" : s, "\n")) {
        local t = trim(line)
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

function join(parts, sep) {
    local out = ""
    for (local i = 0; i < parts.len(); i++) {
        if (i > 0) out += sep
        out += parts[i].tostring()
    }
    return out
}

function array_tail(items, start) {
    local out = []
    for (local i = start; i < items.len(); i++) out.append(items[i])
    return out
}

function quote_join(items) {
    local out = []
    foreach (item in items) out.append(shell_quote(item))
    return join(out, " ")
}

function compare_strings(a, b) {
    if (a < b) return -1
    if (a > b) return 1
    return 0
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

function shell_quote(s) {
    s = s.tostring()
    local out = "'"
    for (local i = 0; i < s.len(); i++) {
        local ch = s.slice(i, i + 1)
        if (ch == "'") out += "'\\''"
        else out += ch
    }
    return out + "'"
}

function path_join(parts) {
    return GLib.build_filenamev(parts)
}

function canonical(path) {
    return GLib.canonicalize_filename(path, null)
}

function is_abs(path) {
    return GLib.path_is_absolute(path)
}

function file_exists(path) {
    return GLib.file_test(path, GLib.FileTest.exists)
}

function is_dir(path) {
    return GLib.file_test(path, GLib.FileTest.is_dir)
}

function mkdir_p(path) {
    GLib.mkdir_with_parents(path, 493)
}

function write_text(path, text) {
    mkdir_p(GLib.path_get_dirname(path))
    GLib.file_set_contents(path, text, -1)
}

function read_text(path) {
    return GLib.file_get_contents(path)
}

function opt_value(args, name, fallback = "") {
    for (local i = 0; i < args.len(); i++) {
        local a = args[i]
        if (a == name && i + 1 < args.len()) return args[i + 1]
        if (starts_with(a, name + "=")) return a.slice(name.len() + 1)
    }
    return fallback
}

function has_flag(args, name) {
    foreach (a in args) {
        if (a == name) return true
    }
    return false
}

function has_value_option(options_with_values, name) {
    foreach (opt in options_with_values) if (opt == name) return true
    return false
}

function global_value_options() {
    return ["--root", "--artifact-dir", "--repo-dir", "--repository"]
}

function command_index(args) {
    for (local i = 0; i < args.len(); i++) {
        local a = args[i]
        if (starts_with(a, "--")) {
            local eq = a.find("=")
            local key = eq == null ? a : a.slice(0, eq)
            if (eq == null && has_value_option(global_value_options(), key) && i + 1 < args.len()) i++
            continue
        }
        return i
    }
    return -1
}

function find_command(args) {
    local idx = command_index(args)
    return idx < 0 ? "" : args[idx]
}

function command_positionals(args, options_with_values) {
    local idx = command_index(args)
    local out = []
    if (idx < 0) return out
    for (local i = idx + 1; i < args.len(); i++) {
        local a = args[i]
        if (starts_with(a, "--")) {
            local eq = a.find("=")
            local key = eq == null ? a : a.slice(0, eq)
            if (eq == null && has_value_option(options_with_values, key) && i + 1 < args.len()) i++
            continue
        }
        out.append(a)
    }
    return out
}

function command_positionals_default(args, extra_value_options = []) {
    local options = global_value_options()
    foreach (opt in extra_value_options) options.append(opt)
    return command_positionals(args, options)
}

function shell_status(result) {
    local status = result[2]
    if (status > 255) return status / 256
    return status
}

function shell_raw(command, cwd = null, print_command = false) {
    local script = cwd == null ? command : "cd " + shell_quote(cwd) + " && " + command
    local cmd = "/bin/sh -c " + shell_quote(script)
    if (print_command) print("+ " + command + "\n")
    local result = GLib.spawn_command_line_sync(cmd)
    local code = shell_status(result)
    if (code != 0) {
        throw "command failed with exit " + code + ": " + command + "\n" + result[1]
    }
    return result[0]
}

function shell(command, cwd = null) {
    return shell_raw(command, cwd, true)
}

function output(command, cwd = null) {
    return trim(shell_raw(command, cwd, false))
}

function maybe_output(command, fallback = "") {
    try {
        return output(command)
    } catch (e) {
        return fallback
    }
}

class OoblergTool {
    args = null
    root = null
    out = null
    manifest = null

    constructor(args = []) {
        this.args = clone args
        this.root = this.find_root(this.args)
        this.out = path_join([this.root, "out"])
        this.manifest = path_join([this.root, "manifest", "packages.json"])
    }

function find_root(args) {
    local explicit = opt_value(args, "--root", "")
    if (explicit != "") return canonical(explicit)
    local env_root = GLib.getenv("OOBLERG_ROOT")
    if (env_root != null && env_root != "") return canonical(env_root)
    local cur = canonical(GLib.get_current_dir())
    while (true) {
        if (file_exists(path_join([cur, "manifest", "packages.json"])) &&
            file_exists(path_join([cur, "tools"]))) {
            return cur
        }
        local parent = GLib.path_get_dirname(cur)
        if (parent == cur || parent == "" || parent == null) break
        cur = parent
    }
    throw "could not find ooblerg repository root; pass --root=/path/to/ooblerg"
}

function root_path(path) {
    if (is_abs(path)) return canonical(path)
    return canonical(path_join([this.root, path]))
}

function load_manifest() {
    local data = sqgi.json.parse(read_text(this.manifest))
    local packages = {}
    foreach (pkg in data.packages) packages[pkg.name] <- pkg
    return { data = data, packages = packages }
}

function package_or_die(packages, name) {
    if (!(name in packages)) throw "unknown package: " + name
    return packages[name]
}

function mkdirs() {
    foreach (name in ["sources", "source-index", "source-cache", "build", "stage", "artifacts", "sysroot", "logs"]) {
        mkdir_p(path_join([this.out, name]))
    }
}

function have_tool(name) {
    local found = GLib.find_program_in_path(name)
    return found != null && found != ""
}

function detect_build_triplet() {
    local v = maybe_output("dpkg-architecture -qDEB_BUILD_GNU_TYPE", "")
    if (v != "") return v
    return output("gcc -dumpmachine")
}

function apt_candidate(binary_pkg) {
    local text = maybe_output("apt-cache policy " + shell_quote(binary_pkg), "")
    foreach (line in split_lines(text)) {
        local t = trim(line)
        if (starts_with(t, "Candidate:")) return trim(t.slice("Candidate:".len()))
    }
    return null
}

function apt_has_source_uris() {
    return maybe_output("apt-get indextargets --format '$(URI)' 'Created-By: Sources'", "") != ""
}

function tar_version(version) {
    return replace_all(replace_all(replace_all(version, ":", "_"), "~", "."), "+", "+")
}

function package_version(pkg) {
    if (!("version_package" in pkg) || pkg.version_package == "") {
        if ("kind" in pkg && pkg.kind == "meta") return "version" in pkg ? pkg.version : "1"
        return "version" in pkg ? pkg.version : "unknown"
    }
    local candidate = apt_candidate(pkg.version_package)
    if (candidate != null && candidate != "") return candidate
    return "version" in pkg ? pkg.version : "unknown"
}

function substitute(items, data, destdir = null) {
    local jobs = maybe_output("getconf _NPROCESSORS_ONLN", "2")
    if (jobs == "") jobs = "2"
    local values = {
        ROOT = this.root,
        BUILD_TRIPLET = detect_build_triplet(),
        JOBS = jobs,
        DESTDIR = destdir == null ? "" : destdir,
        PREFIX = data.prefix,
        TARGET = data.target,
    }
    local out = []
    foreach (item in items) {
        local v = item
        foreach (key, value in values) v = replace_all(v, "${" + key + "}", value)
        out.append(v)
    }
    return out
}

function env_prefix(data, destdir = null) {
    local target = data.target
    local prefix_root = path_join([this.out, "sysroot", data.prefix.slice(1)])
    local host_tools = path_join([this.out, "host-tools", "usr"])
    local host_bin = path_join([host_tools, "bin"])
    local host_multiarch = maybe_output("dpkg-architecture -qDEB_HOST_MULTIARCH", "")
    local host_lib = host_multiarch == "" ? "" : path_join([host_tools, "lib", host_multiarch])
    local path_value = host_bin + ":" + path_join([prefix_root, "bin"]) + ":" + (GLib.getenv("PATH") == null ? "" : GLib.getenv("PATH"))
    local pkg_dirs = path_join([prefix_root, "lib", "pkgconfig"]) + ":" + path_join([prefix_root, "share", "pkgconfig"])
    local gir_path = path_join([prefix_root, "share", "gir-1.0"]) + ":" + (GLib.getenv("GI_GIR_PATH") == null ? "" : GLib.getenv("GI_GIR_PATH"))
    local typelib_path = path_join([prefix_root, "lib", "girepository-1.0"]) + ":" + (GLib.getenv("GI_TYPELIB_PATH") == null ? "" : GLib.getenv("GI_TYPELIB_PATH"))
    local parts = [
        "CHOST=" + shell_quote(target),
        "CC=" + shell_quote(target + "-gcc"),
        "CXX=" + shell_quote(target + "-g++"),
        "AR=" + shell_quote(target + "-ar"),
        "RANLIB=" + shell_quote(target + "-ranlib"),
        "STRIP=" + shell_quote(target + "-strip"),
        "WINDRES=" + shell_quote(target + "-windres"),
        "PKG_CONFIG='pkg-config'",
        "PKG_CONFIG_LIBDIR=" + shell_quote(pkg_dirs),
        "PKG_CONFIG_SYSROOT_DIR=" + shell_quote(path_join([this.out, "sysroot"])),
        "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1",
        "PKG_CONFIG_ALLOW_SYSTEM_LIBS=1",
        "GI_GIR_PATH=" + shell_quote(gir_path),
        "GI_TYPELIB_PATH=" + shell_quote(typelib_path),
        "CPPFLAGS=" + shell_quote("-I" + path_join([prefix_root, "include"])),
        "CFLAGS=" + shell_quote("-I" + path_join([prefix_root, "include"])),
        "CXXFLAGS=" + shell_quote("-I" + path_join([prefix_root, "include"])),
        "LDFLAGS=" + shell_quote("-L" + path_join([prefix_root, "lib"])),
        "PATH=" + shell_quote(path_value),
    ]
    if (host_lib != "" && is_dir(host_lib)) {
        local old_ld = GLib.getenv("LD_LIBRARY_PATH")
        parts.append("LD_LIBRARY_PATH=" + shell_quote(host_lib + ":" + (old_ld == null ? "" : old_ld)))
    }
    local wrapper = GLib.getenv("OOBLERG_EXE_WRAPPER")
    if (wrapper != null && wrapper != "") parts.append("GI_CROSS_LAUNCHER=" + shell_quote(wrapper))
    if (destdir != null) parts.append("DESTDIR=" + shell_quote(destdir))
    return join(parts, " ") + " "
}

function meson_cross_file(data) {
    mkdirs()
    local target = data.target
    local prefix_root = path_join([this.out, "sysroot", data.prefix.slice(1)])
    local scanner = path_join([this.root, "tools", "ooblerg-g-ir-scanner"])
    local compiler = maybe_output("command -v g-ir-compiler", "/usr/bin/g-ir-compiler")
    local generate = maybe_output("command -v g-ir-generate", "/usr/bin/g-ir-generate")
    local exe_wrapper = GLib.getenv("OOBLERG_EXE_WRAPPER")
    local exe_wrapper_line = ""
    if (exe_wrapper != null && exe_wrapper != "") exe_wrapper_line = "exe_wrapper = " + sqgi.json.stringify(split_words(exe_wrapper)) + "\n"
    local path = path_join([this.out, "meson-cross.ini"])
    write_text(path,
        "[binaries]\n" +
        "c = '" + target + "-gcc'\n" +
        "cpp = '" + target + "-g++'\n" +
        "ar = '" + target + "-ar'\n" +
        "strip = '" + target + "-strip'\n" +
        "windres = '" + target + "-windres'\n" +
        "pkgconfig = 'pkg-config'\n" +
        "g-ir-scanner = '" + scanner + "'\n" +
        "g-ir-compiler = '" + compiler + "'\n" +
        "g-ir-generate = '" + generate + "'\n" +
        exe_wrapper_line + "\n" +
        "[properties]\n" +
        "sys_root = '" + path_join([this.out, "sysroot"]) + "'\n" +
        "pkg_config_libdir = ['" + path_join([prefix_root, "lib", "pkgconfig"]) + "', '" + path_join([prefix_root, "share", "pkgconfig"]) + "']\n\n" +
        "[built-in options]\n" +
        "c_args = ['-I" + path_join([prefix_root, "include"]) + "']\n" +
        "cpp_args = ['-I" + path_join([prefix_root, "include"]) + "']\n" +
        "c_link_args = ['-L" + path_join([prefix_root, "lib"]) + "']\n" +
        "cpp_link_args = ['-L" + path_join([prefix_root, "lib"]) + "']\n\n" +
        "[host_machine]\n" +
        "system = 'windows'\n" +
        "cpu_family = 'x86_64'\n" +
        "cpu = 'x86_64'\n" +
        "endian = 'little'\n")
    return path
}

function cmake_toolchain_file(data) {
    mkdirs()
    local target = data.target
    local sysroot = path_join([this.out, "sysroot"])
    local prefix_root = path_join([sysroot, data.prefix.slice(1)])
    local path = path_join([this.out, "cmake-mingw-toolchain.cmake"])
    write_text(path,
        "set(CMAKE_SYSTEM_NAME Windows)\n" +
        "set(CMAKE_SYSTEM_PROCESSOR x86_64)\n" +
        "set(CMAKE_C_COMPILER " + target + "-gcc)\n" +
        "set(CMAKE_CXX_COMPILER " + target + "-g++)\n" +
        "set(CMAKE_RC_COMPILER " + target + "-windres)\n" +
        "set(CMAKE_FIND_ROOT_PATH " + sysroot + " " + prefix_root + ")\n" +
        "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)\n" +
        "set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)\n" +
        "set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)\n" +
        "set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)\n")
    return path
}

function list_dirs(path) {
    if (!is_dir(path)) return []
    local text = maybe_output("find " + shell_quote(path) + " -mindepth 1 -maxdepth 1 -type d | sort", "")
    return split_lines(text)
}

function source_dir(pkg) {
    local source_name = ("source_from" in pkg) ? pkg.source_from : pkg.name
    local source_root = path_join([this.out, "sources", source_name])
    if (!is_dir(source_root)) return null
    local candidates = []
    foreach (p in list_dirs(source_root)) {
        if (is_dir(path_join([p, "debian"]))) candidates.append(p)
    }
    if (candidates.len() > 0) return candidates.top()
    local dirs = list_dirs(source_root)
    return dirs.len() > 0 ? dirs.top() : null
}

function dependency_closure(packages, roots) {
    local seen = {}
    local ordered = []
    local visit = null
    visit = function(name) {
        if (name in seen) return
        local pkg = package_or_die(packages, name)
        seen[name] <- true
        if ("deps" in pkg) foreach (dep in pkg.deps) visit(dep)
        ordered.append(name)
    }
    foreach (root in roots) visit(root)
    return ordered
}

function artifact_filename(pkg, version) {
    return pkg.name + "-" + tar_version(version) + "-x86_64-w64-mingw32.tar.gz"
}

function artifact_path(pkg, version) {
    return path_join([this.out, "artifacts", artifact_filename(pkg, version)])
}

function file_size(path) {
    return output("stat -c %s " + shell_quote(path)).tointeger()
}

function file_hash(path) {
    return split_words(output("sha256sum " + shell_quote(path)))[0]
}

function safe_tar_member_name(name) {
    if (name == "") return null
    local normalized = replace_all(name, "\\", "/")
    if (starts_with(normalized, "/")) return null
    if (normalized.len() >= 2 && normalized.slice(1, 2) == ":") return null
    local parts = []
    foreach (part in split_char(normalized, "/")) {
        if (part == "" || part == ".") continue
        if (part == "..") return null
        parts.append(part)
    }
    return join(parts, "/")
}

function parse_tar_listing_line(line) {
    local words = split_words(line)
    if (words.len() < 6) return null
    local perms = words[0]
    local kind_ch = perms.slice(0, 1)
    local size = 0
    try { size = words[2].tointeger() } catch (e) { size = 0 }
    local name = join(array_tail(words, 5), " ")
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
    local safe = safe_tar_member_name(name)
    if (safe == null) throw "unsafe tar member: " + name
    return { kind_ch = kind_ch, path = safe, size = size, target = target }
}

function add_parent_dir(set, path) {
    local dir = GLib.path_get_dirname(path)
    if (dir != "." && dir != "" && dir != null) set[replace_all(dir, "\\", "/")] <- true
}

function sorted_keys(table) {
    local out = []
    foreach (k, v in table) out.append(k)
    out.sort()
    return out
}

function artifact_members(artifact) {
    local files = []
    local dirs = {}
    local installed_size = 0
    local listing = output("tar -tvzf " + shell_quote(artifact))
    foreach (line in split_lines(listing)) {
        local item = parse_tar_listing_line(line)
        if (item == null) continue
        if (item.kind_ch == "d") {
            if (item.path != "") dirs[item.path] <- true
        } else if (item.kind_ch == "l") {
            add_parent_dir(dirs, item.path)
            files.append({ path = item.path, size = 0, kind = "symlink", target = item.target })
        } else if (item.kind_ch == "h") {
            add_parent_dir(dirs, item.path)
            files.append({ path = item.path, size = 0, kind = "hardlink", target = item.target })
        } else if (item.kind_ch == "-") {
            add_parent_dir(dirs, item.path)
            files.append({ path = item.path, size = item.size, kind = "file" })
            installed_size += item.size
        } else {
            add_parent_dir(dirs, item.path)
            files.append({ path = item.path, size = 0, kind = "special" })
        }
    }
    files.sort(function(a, b) { return compare_strings(a.path, b.path) })
    return { files = files, directories = sorted_keys(dirs), installed_size = installed_size }
}

function summarize_package(pkg) {
    local text = ("summary" in pkg) ? pkg.summary : (("description" in pkg) ? pkg.description : pkg.name)
    local p = text.find(".")
    return trim(p == null ? text : text.slice(0, p))
}

function package_manifest(data, pkg, version, artifact, artifact_rel, built_at) {
    local deps = []
    if ("deps" in pkg) foreach (dep in pkg.deps) deps.append({ name = dep })
    local files = []
    local directories = []
    local installed_size = 0
    local artifact_info = null
    if (artifact != null && file_exists(artifact)) {
        local members = artifact_members(artifact)
        files = members.files
        directories = members.directories
        installed_size = members.installed_size
        artifact_info = {
            filename = GLib.path_get_basename(artifact),
            size = file_size(artifact),
            sha256 = file_hash(artifact),
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
        kind = "kind" in pkg ? pkg.kind : "package",
        summary = summarize_package(pkg),
        description = "description" in pkg ? pkg.description : summarize_package(pkg),
        artifact = artifact_info,
        dependencies = deps,
        provides = provides,
        conflicts = "conflicts" in pkg ? pkg.conflicts : [],
        replaces = "replaces" in pkg ? pkg.replaces : [],
        files = files,
        directories = directories,
        installed_size = installed_size,
        build = {
            source = "source" in pkg ? pkg.source : ("source_from" in pkg ? pkg.source_from : pkg.name),
            version_package = "version_package" in pkg ? pkg.version_package : "",
            recipe_revision = "workspace",
            built_at = built_at,
        },
        license = "license" in pkg ? pkg.license : {},
        tags = "tags" in pkg ? pkg.tags : [],
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

function write_json(path, value) {
    write_text(path, sqgi.json.stringify(value, 2) + "\n")
}

function link_or_copy(src, dst) {
    mkdir_p(GLib.path_get_dirname(dst))
    shell("rm -f " + shell_quote(dst) + " && (ln " + shell_quote(src) + " " + shell_quote(dst) + " || cp -a " + shell_quote(src) + " " + shell_quote(dst) + ")")
}

function utc_now_iso() {
    return output("date -u +%Y-%m-%dT%H:%M:%SZ")
}

function command_doctor(args) {
    local loaded = load_manifest()
    local data = loaded.data
    local required = [
        "apt-cache", "apt-get", "dpkg-source", "tar", "pkg-config",
        "make", "meson", "ninja", "cmake", "g-ir-scanner", "g-ir-compiler",
        data.target + "-gcc", data.target + "-g++", data.target + "-ar",
        data.target + "-ranlib", data.target + "-strip", data.target + "-windres",
        data.target + "-objdump",
    ]
    local missing = []
    foreach (tool in required) if (!have_tool(tool)) missing.append(tool)
    print("root: " + this.root + "\n")
    print("target: " + data.target + "\n")
    print("prefix: " + data.prefix + "\n")
    print("build triplet: " + detect_build_triplet() + "\n")
    if (missing.len() > 0) {
        print("missing tools:\n")
        foreach (tool in missing) print("  - " + tool + "\n")
        return 1
    }
    print("all required host tools are present\n")
    local wrapper = GLib.getenv("OOBLERG_EXE_WRAPPER")
    print(wrapper == null || wrapper == "" ? "introspection exe wrapper: not set (set OOBLERG_EXE_WRAPPER for GIR builds)\n" : "introspection exe wrapper: " + wrapper + "\n")
    return 0
}

function command_versions(args) {
    local loaded = load_manifest()
    foreach (pkg in loaded.data.packages) {
        local version = package_version(pkg)
        local name = pkg.name
        local pad = "                    "
        print(name + pad.slice(0, pad.len() > name.len() ? pad.len() - name.len() : 1) + version + (version == "unknown" ? " (no apt candidate found)" : "") + "\n")
    }
    return 0
}

function command_plan(args) {
    local loaded = load_manifest()
    foreach (name in dependency_closure(loaded.packages, command_positionals_default(args))) print(name + "\n")
    return 0
}

function command_fetch(args) {
    local loaded = load_manifest()
    mkdirs()
    if (!apt_has_source_uris()) throw "no deb-src URIs configured; Squirrel fetch currently uses apt-get source"
    local roots = command_positionals_default(args)
    local names = has_flag(args, "--deps") ? dependency_closure(loaded.packages, roots) : roots
    foreach (name in names) {
        local pkg = package_or_die(loaded.packages, name)
        if ("kind" in pkg && (pkg.kind == "runtime-seed" || pkg.kind == "meta")) continue
        if (!("source" in pkg)) {
            print(name + ": no source package to fetch\n")
            continue
        }
        local source_from = ("source_from" in pkg) ? pkg.source_from : null
        if (source_from != null && is_dir(path_join([this.out, "sources", source_from]))) {
            print(name + ": using source tree from " + source_from + "\n")
            continue
        }
        if (source_dir(pkg) != null) {
            print(name + ": source already present\n")
            continue
        }
        local dest = path_join([this.out, "sources", name])
        mkdir_p(dest)
        shell("apt-get source " + shell_quote(pkg.source), dest)
    }
    return 0
}

function remove_build_tool_shims() {
    local data = load_manifest().data
    local bindir = path_join([this.out, "sysroot", data.prefix.slice(1), "bin"])
    foreach (tool in BUILD_TOOL_SHIMS) {
        local target_path = path_join([bindir, tool])
        shell_raw("[ ! -L " + shell_quote(target_path) + " ] || rm -f " + shell_quote(target_path), null, false)
    }
}

function install_build_tool_shims() {
    local data = load_manifest().data
    local bindir = path_join([this.out, "sysroot", data.prefix.slice(1), "bin"])
    if (!is_dir(bindir)) return
    foreach (tool in BUILD_TOOL_SHIMS) {
        local target_path = path_join([bindir, tool])
        local exe_path = path_join([bindir, tool + ".exe"])
        if (file_exists(target_path) || !file_exists(exe_path)) continue
        local host_path = maybe_output("command -v " + shell_quote(tool), "")
        if (host_path != "") shell("ln -s " + shell_quote(host_path) + " " + shell_quote(target_path))
    }
}

function install_artifact(path, build_shims = true) {
    local sysroot = path_join([this.out, "sysroot"])
    mkdir_p(sysroot)
    remove_build_tool_shims()
    shell("tar -xzf " + shell_quote(path) + " -C " + shell_quote(sysroot))
    if (build_shims) install_build_tool_shims()
}

function package_stage(pkg, version) {
    local stage = path_join([this.out, "stage", pkg.name])
    local artifact = artifact_path(pkg, version)
    mkdir_p(GLib.path_get_dirname(artifact))
    shell_raw("rm -f " + shell_quote(path_join([stage, "mingw64", "share", "info", "dir"])) + " 2>/dev/null || true")
    shell("rm -f " + shell_quote(artifact) + " && tar -czf " + shell_quote(artifact) + " -C " + shell_quote(stage) + " .")
    install_artifact(artifact)
    print("wrote " + artifact + "\n")
}

function command_repo_index(args) {
    local Builder = import(path_join([this.root, "server", "src", "repo", "builder.nut"]))
    local roots = command_positionals(args, ["--artifact-dir", "--repo-dir", "--repository", "--root"])
    local builder = Builder.RepositoryBuilder()
    print(builder.rebuild({
        root = this.root,
        artifact_dir = opt_value(args, "--artifact-dir", "out/artifacts"),
        repo_dir = opt_value(args, "--repo-dir", "out/repo"),
        repository = opt_value(args, "--repository", "ooblerg-local"),
        packages = roots,
        include_deps = has_flag(args, "--deps"),
    }))
    return 0
}

function active_gcc_runtime_dir(target) {
    return GLib.path_get_dirname(canonical(output(target + "-gcc -print-libgcc-file-name")))
}

function prune_runtime_seed(prefix) {
    shell("rm -rf " +
        shell_quote(path_join([prefix, "lib", "ldscripts"])) + " " +
        shell_quote(path_join([prefix, "lib", "bfd-plugins"])) + " " +
        shell_quote(path_join([prefix, "lib", "gcc"])))
    shell_raw("rm -f " +
        shell_quote(path_join([prefix, "bin", "libatomic-1.dll"])) + " " +
        shell_quote(path_join([prefix, "bin", "libquadmath-0.dll"])) + " " +
        shell_quote(path_join([prefix, "bin", "libssp-0.dll"])) + " " +
        shell_quote(path_join([prefix, "bin", "libstdc++-6.dll"])) +
        " 2>/dev/null || true")
}

function command_seed_runtime(args) {
    local loaded = load_manifest()
    local data = loaded.data
    local pkg = package_or_die(loaded.packages, "mingw-w64-runtime")
    local version = package_version(pkg)
    local stage = path_join([this.out, "stage", pkg.name])
    local prefix = path_join([stage, data.prefix.slice(1)])
    shell("rm -rf " + shell_quote(stage))
    mkdir_p(path_join([prefix, "bin"]))
    local src_root = path_join(["/usr", data.target])
    if (!is_dir(src_root)) throw src_root + " does not exist; install mingw-w64-x86-64-dev"
    shell("cp -aL " + shell_quote(path_join([src_root, "include"])) + " " + shell_quote(path_join([prefix, "include"])))
    shell("cp -a " + shell_quote(path_join([src_root, "lib"])) + " " + shell_quote(path_join([prefix, "lib"])))
    local gcc_runtime = active_gcc_runtime_dir(data.target)
    local gcc_dest = path_join([prefix, "lib", "gcc", data.target, GLib.path_get_basename(gcc_runtime)])
    mkdir_p(GLib.path_get_dirname(gcc_dest))
    shell("cp -a " + shell_quote(gcc_runtime) + " " + shell_quote(gcc_dest))
    shell_raw("cp -a " + shell_quote(path_join([gcc_runtime, "*.dll"])) + " " + shell_quote(path_join([prefix, "bin"])) + " 2>/dev/null || true")
    prune_runtime_seed(prefix)
    run_recipe_commands(pkg, "post_install", data, this.root, stage)
    package_stage(pkg, version)
    return 0
}

function ensure_deps_built(packages, pkg) {
    local missing = []
    if ("deps" in pkg) foreach (dep in pkg.deps) {
        local dep_pkg = package_or_die(packages, dep)
        if (!file_exists(artifact_path(dep_pkg, package_version(dep_pkg)))) missing.append(dep)
    }
    if (missing.len() > 0) throw pkg.name + " needs missing artifacts: " + join(missing, ", ") + ". Build or seed dependencies first."
}

function run_recipe_commands(pkg, key, data, cwd, destdir = null) {
    if (!(key in pkg)) return
    foreach (cmd in substitute(pkg[key], data, destdir)) shell(env_prefix(data, destdir) + cmd, cwd)
}

function apply_patch_file(path, cwd) {
    local patch = root_path(path)
    if (!file_exists(patch)) throw "patch does not exist: " + path
    local dry = "patch --dry-run -p1 -i " + shell_quote(patch)
    try {
        shell(dry, cwd)
        shell("patch -p1 -i " + shell_quote(patch), cwd)
        return
    } catch (e) {}
    try {
        shell("patch --dry-run -R -p1 -i " + shell_quote(patch), cwd)
        print(path + ": already applied\n")
        return
    } catch (e2) {}
    throw "patch does not apply cleanly: " + path
}

function apply_package_patches(pkg, data, cwd, destdir = null) {
    if (!("patches" in pkg)) return
    foreach (patch in substitute(pkg.patches, data, destdir)) apply_patch_file(patch, cwd)
}

function apply_package_overlays(pkg, data, cwd, destdir = null) {
    if (!("overlays" in pkg)) return
    foreach (overlay in substitute(pkg.overlays, data, destdir)) {
        local src = root_path(overlay)
        if (!is_dir(src)) throw "overlay does not exist: " + overlay
        shell("cp -a " + shell_quote(src) + "/. " + shell_quote(cwd))
    }
}

function build_one(data, packages, name) {
    local pkg = package_or_die(packages, name)
    if ("kind" in pkg && pkg.kind == "meta") return
    if ("kind" in pkg && pkg.kind == "runtime-seed") {
        command_seed_runtime([])
        return
    }
    ensure_deps_built(packages, pkg)
    local system = pkg.build_system
    local src = source_dir(pkg)
    if (src == null) {
        if (system == "custom") src = this.root
        else throw "no source tree for " + name + "; run ./tools/ooblerg.nut fetch " + name
    }
    if ("source_subdir" in pkg) src = path_join([src, pkg.source_subdir])
    install_build_tool_shims()
    local version = package_version(pkg)
    local build = path_join([this.out, "build", name])
    local stage = path_join([this.out, "stage", name])
    shell("rm -rf " + shell_quote(build) + " " + shell_quote(stage))
    mkdir_p(build)
    mkdir_p(stage)
    apply_package_overlays(pkg, data, src, stage)
    apply_package_patches(pkg, data, src, stage)
    run_recipe_commands(pkg, "pre_configure", data, src, stage)
    if (system == "meson") {
        local cross = meson_cross_file(data)
        local opts = ("meson_options" in pkg) ? quote_join(substitute(pkg.meson_options, data, stage)) : ""
        shell(env_prefix(data, stage) + "meson setup " + shell_quote(build) + " " + shell_quote(src) + " --cross-file=" + shell_quote(cross) + " --prefix=" + shell_quote(data.prefix) + " --libdir=lib --buildtype=release " + opts)
        shell(env_prefix(data, stage) + "meson compile -C " + shell_quote(build))
        shell(env_prefix(data, stage) + "meson install -C " + shell_quote(build) + " --destdir=" + shell_quote(stage))
    } else if (system == "cmake") {
        run_recipe_commands(pkg, "pre_build", data, src, stage)
        local toolchain = cmake_toolchain_file(data)
        local opts = ("cmake_options" in pkg) ? quote_join(substitute(pkg.cmake_options, data, stage)) : ""
        shell(env_prefix(data, stage) + "cmake -S " + shell_quote(src) + " -B " + shell_quote(build) + " -DCMAKE_TOOLCHAIN_FILE=" + shell_quote(toolchain) + " -DCMAKE_INSTALL_PREFIX=" + shell_quote(data.prefix) + " -DCMAKE_BUILD_TYPE=Release " + opts)
        shell(env_prefix(data, stage) + "cmake --build " + shell_quote(build) + " --parallel " + maybe_output("getconf _NPROCESSORS_ONLN", "2"))
        shell(env_prefix(data, stage) + "cmake --install " + shell_quote(build) + " --prefix " + shell_quote(data.prefix))
    } else if (system == "autotools") {
        local configure = ["./configure"]
        if ("configure" in pkg) foreach (c in pkg.configure) configure.append(c)
        shell(env_prefix(data, stage) + quote_join(substitute(configure, data, stage)), src)
        run_recipe_commands(pkg, "pre_build", data, src, stage)
        local make_cmd = ("make" in pkg) ? join(substitute(pkg.make, data, stage), " ") : "make -j" + maybe_output("getconf _NPROCESSORS_ONLN", "2")
        shell(env_prefix(data, stage) + make_cmd, src)
        local install_cmd = ("install" in pkg) ? join(substitute(pkg.install, data, stage), " ") : "make DESTDIR=" + shell_quote(stage) + " install"
        shell(env_prefix(data, stage) + install_cmd, src)
    } else if (system == "custom") {
        if ("commands" in pkg) foreach (cmd in substitute(pkg.commands, data, stage)) shell(env_prefix(data, stage) + cmd, src)
    } else {
        throw "unsupported build system for " + name + ": " + system
    }
    run_recipe_commands(pkg, "post_install", data, src, stage)
    package_stage(pkg, version)
}

function command_build(args) {
    local loaded = load_manifest()
    mkdirs()
    local roots = command_positionals_default(args)
    local names = has_flag(args, "--deps") ? dependency_closure(loaded.packages, roots) : roots
    foreach (name in names) build_one(loaded.data, loaded.packages, name)
    return 0
}

function command_install(args) {
    mkdirs()
    foreach (artifact in command_positionals_default(args)) {
        install_artifact(root_path(artifact))
        print("installed " + artifact + "\n")
    }
    return 0
}

function command_rebuild_sysroot(args) {
    local loaded = load_manifest()
    mkdirs()
    local sysroot = path_join([this.out, "sysroot"])
    shell("rm -rf " + shell_quote(sysroot))
    mkdir_p(sysroot)
    local roots = command_positionals(args, ["--root"])
    if (roots.len() == 0) roots = ["vala", "gtk4"]
    foreach (name in dependency_closure(loaded.packages, roots)) {
        local pkg = package_or_die(loaded.packages, name)
        local artifact = artifact_path(pkg, package_version(pkg))
        if (file_exists(artifact)) {
            install_artifact(artifact, !has_flag(args, "--no-build-shims"))
            print("installed " + artifact + "\n")
        }
    }
    if (has_flag(args, "--no-build-shims")) remove_build_tool_shims()
    return 0
}

function print_help() {
    print("Ooblerg Squirrel build tool\n")
    print("  sqgi tools/ooblerg.nut help\n")
    print("  sqgi tools/ooblerg.nut doctor\n")
    print("  sqgi tools/ooblerg.nut versions\n")
    print("  sqgi tools/ooblerg.nut plan PACKAGE...\n")
    print("  sqgi tools/ooblerg.nut fetch [--deps] PACKAGE...\n")
    print("  sqgi tools/ooblerg.nut seed-runtime\n")
    print("  sqgi tools/ooblerg.nut build [--deps] PACKAGE...\n")
    print("  sqgi tools/ooblerg.nut install ARTIFACT...\n")
    print("  sqgi tools/ooblerg.nut rebuild-sysroot [--no-build-shims] [PACKAGE...]\n")
    print("  sqgi tools/ooblerg.nut repo-index [--deps] [--artifact-dir DIR] [--repo-dir DIR] [PACKAGE...]\n")
}

function run(args) {
    if (has_flag(args, "--help") || has_flag(args, "-h") || args.len() == 0) {
        print_help()
        return 0
    }
    local cmd = find_command(args)
    if (cmd == "help") {
        print_help()
        return 0
    }
    if (cmd == "doctor") return command_doctor(args)
    if (cmd == "versions") return command_versions(args)
    if (cmd == "plan") return command_plan(args)
    if (cmd == "fetch") return command_fetch(args)
    if (cmd == "seed-runtime") return command_seed_runtime(args)
    if (cmd == "build") return command_build(args)
    if (cmd == "install") return command_install(args)
    if (cmd == "rebuild-sysroot") return command_rebuild_sysroot(args)
    if (cmd == "repo-index") return command_repo_index(args)
    throw "unknown command: " + cmd
}

}

class OoblergApplication {
    app = null
    args = null

    constructor(args) {
        this.args = clone args
        this.app = Gio.Application.new(
            "org.ooblerg.build-tool",
            Gio.ApplicationFlags.handles_command_line | Gio.ApplicationFlags.non_unique
        )
        this.add_options()
        this.app.connect("command-line", function(command_line) {
            return this.on_command_line(command_line)
        }.bindenv(this))
    }

    function add_options() {
        this.app.add_main_option("root", 0, 0, GLib.OptionArg.string,
            "Ooblerg checkout root", "DIR")
        this.app.add_main_option("deps", 0, 0, GLib.OptionArg.none,
            "Include package dependencies for commands that support it", null)
        this.app.add_main_option("artifact-dir", 0, 0, GLib.OptionArg.string,
            "Artifact directory for repo-index", "DIR")
        this.app.add_main_option("repo-dir", 0, 0, GLib.OptionArg.string,
            "Repository output directory for repo-index", "DIR")
        this.app.add_main_option("repository", 0, 0, GLib.OptionArg.string,
            "Repository name for repo-index", "NAME")
        this.app.add_main_option("no-build-shims", 0, 0, GLib.OptionArg.none,
            "Do not install host build-tool shims when rebuilding the sysroot", null)
    }

    function on_command_line(command_line) {
        try {
            return OoblergTool(this.args).run(this.args)
        } catch (e) {
            print("error: " + e + "\n")
            return 1
        }
    }

    function run(args) {
        local argv = ["tools/ooblerg.nut"]
        foreach (arg in args) argv.append(arg)
        return this.app.run(argv.len(), argv)
    }
}

local application = OoblergApplication(vargv)
return application.run(vargv)
