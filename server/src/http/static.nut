local GLib = import("GLib")
local Gio = import("Gio")
local U = import("../util.nut")

function content_type(path) {
    if (U.ends_with(path, ".html")) return "text/html; charset=utf-8"
    if (U.ends_with(path, ".css")) return "text/css; charset=utf-8"
    if (U.ends_with(path, ".js")) return "application/javascript; charset=utf-8"
    if (U.ends_with(path, ".json")) return "application/json"
    if (U.ends_with(path, ".sha256")) return "text/plain"
    if (U.ends_with(path, ".tar.gz")) return "application/gzip"
    if (U.ends_with(path, ".exe")) return "application/vnd.microsoft.portable-executable"
    if (U.ends_with(path, ".ico")) return "image/x-icon"
    if (U.ends_with(path, ".png")) return "image/png"
    if (U.ends_with(path, ".svg")) return "image/svg+xml"
    if (U.ends_with(path, ".txt")) return "text/plain"
    return "application/octet-stream"
}

function unsafe_path(path) {
    if (path == null || path == "") return true
    if (path.find("\\") != null) return true
    if (path.find(":") != null) return true
    foreach (part in split_path(path)) {
        if (part == "..") return true
    }
    return false
}

function split_path(path) {
    local out = []
    local start = 0
    for (local i = 0; i < path.len(); i++) {
        if (path.slice(i, i + 1) == "/") {
            if (i > start) out.append(path.slice(start, i))
            start = i + 1
        }
    }
    if (start < path.len()) out.append(path.slice(start))
    return out
}

function replace_all(s, needle, replacement) {
    local out = ""
    local start = 0
    while (true) {
        local p = s.find(needle, start)
        if (p == null) break
        out += s.slice(start, p) + replacement
        start = p + needle.len()
    }
    return out + s.slice(start)
}

function first_word(text) {
    text = U.trim(text)
    local out = ""
    for (local i = 0; i < text.len(); i++) {
        local ch = text.slice(i, i + 1)
        if (ch == " " || ch == "\t" || ch == "\r" || ch == "\n") break
        out += ch
    }
    return out
}

function file_size(path) {
    try {
        return Gio.File.new_for_path(path).query_info("standard::size", 0, null).get_size()
    } catch (e) {
        return 0
    }
}

function sha256_file(path) {
    local data = GLib.file_get_contents(path)
    return GLib.compute_checksum_for_string(GLib.ChecksumType.sha256, data, data.len())
}

function installer_sha256(repo_dir, installer_path) {
    local checksum_path = GLib.build_filenamev([repo_dir, "downloads", "OoblergSetup.exe.sha256"])
    if (U.is_regular(checksum_path)) {
        local sha = first_word(GLib.file_get_contents(checksum_path))
        if (sha != "") return sha
    }
    if (U.is_regular(installer_path)) return sha256_file(installer_path)
    return "unavailable"
}

function format_bytes(bytes) {
    if (bytes <= 0) return "unknown bytes"
    local out = ""
    local s = bytes.tostring()
    local n = s.len()
    for (local i = 0; i < n; i++) {
        if (i > 0 && ((n - i) % 3) == 0) out += ","
        out += s.slice(i, i + 1)
    }
    return out + " bytes"
}

function format_size(bytes) {
    if (bytes <= 0) return "unknown size"
    local value = bytes.tofloat()
    foreach (unit in ["B", "KiB", "MiB", "GiB"]) {
        if (value < 1024.0 || unit == "GiB") {
            if (unit == "B") return bytes.tostring() + " B"
            return format("%.1f %s", value, unit)
        }
        value = value / 1024.0
    }
    return bytes.tostring() + " B"
}

function render_index(repo_dir, path) {
    local body = GLib.file_get_contents(path)
    local installer = GLib.build_filenamev([repo_dir, "downloads", "OoblergSetup.exe"])
    local bytes = file_size(installer)
    body = replace_all(body, "{{OOBLERG_INSTALLER_SIZE}}", format_size(bytes))
    body = replace_all(body, "{{OOBLERG_INSTALLER_BYTES}}", format_bytes(bytes))
    body = replace_all(body, "{{OOBLERG_INSTALLER_SHA256}}", installer_sha256(repo_dir, installer))
    return body
}

function body(repo_dir, resolved) {
    if (GLib.path_get_basename(resolved.path) == "index.html") {
        return render_index(repo_dir, resolved.path)
    }
    return GLib.file_get_contents(resolved.path)
}

function resolve(repo_dir, request_path) {
    local rel = request_path
    if (rel == "/" || rel == "") {
        local index_path = GLib.build_filenamev([repo_dir, "index.html"])
        if (U.is_regular(index_path)) {
            return {
                path = index_path,
                content_type = content_type(index_path),
            }
        }
        rel = "/v1/index.json"
    }
    if (U.starts_with(rel, "/")) rel = rel.slice(1)
    if (unsafe_path(rel)) return null
    local root = GLib.canonicalize_filename(repo_dir, null)
    local candidate = GLib.canonicalize_filename(GLib.build_filenamev([repo_dir, rel]), null)
    if (candidate != root && !U.starts_with(candidate, root + "/")) return null
    if (!U.is_regular(candidate)) return null
    return {
        path = candidate,
        content_type = content_type(candidate),
    }
}

return {
    content_type = content_type,
    unsafe_path = unsafe_path,
    resolve = resolve,
    body = body,
    render_index = render_index,
}
