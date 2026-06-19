local GLib = import("GLib")
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
}
