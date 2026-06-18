local GLib = import("GLib")
local U = import("../util.nut")
local Manifest = import("../pkg/manifest.nut")

local Soup = null
try {
    Soup = import("Soup", "3.0")
} catch (e) {
    Soup = null
}

function local_path_from_uri(uri) {
    if (U.starts_with(uri, "file://")) return uri.slice("file://".len())
    return uri
}

function last_slash(uri) {
    local pos = null
    for (local i = 0; i < uri.len(); i++) {
        if (uri.slice(i, i + 1) == "/") pos = i
    }
    return pos
}

function is_absolute_uri(uri) {
    return U.starts_with(uri, "http://") || U.starts_with(uri, "https://") ||
        U.starts_with(uri, "file://")
}

function resolve_uri(base_uri, rel) {
    rel = U.trim(rel)
    if (rel == "") throw "repository item has a blank path"
    if (is_absolute_uri(rel)) return rel

    base_uri = U.trim(base_uri)
    local slash = last_slash(base_uri)
    if (slash == null) return rel
    local base_dir = base_uri.slice(0, slash)

    if (U.starts_with(base_uri, "http://") || U.starts_with(base_uri, "https://") ||
        U.starts_with(base_uri, "file://")) {
        return base_dir + "/" + rel
    }

    return GLib.build_filenamev([GLib.path_get_dirname(local_path_from_uri(base_uri)), rel])
}

function fetch_bytes(uri) {
    uri = U.trim(uri)
    if (uri == "") throw "source URI is blank"
    if (!U.starts_with(uri, "http://") && !U.starts_with(uri, "https://")) {
        return GLib.file_get_contents(local_path_from_uri(uri))
    }
    if (Soup == null) throw "libsoup 3.0 is not available in this SQGI runtime"
    local msg = Soup.Message.new("GET", uri)
    if (msg == null) throw "invalid URI: " + uri
    local session = Soup.Session.new()
    local bytes = session.send_and_read(msg, null)
    local status = msg.get_status()
    if (status < 200 || status >= 300) throw "HTTP " + status + " for " + uri
    return bytes.get_data()
}

function fetch_text(uri) {
    return fetch_bytes(uri)
}

function load_index(uri) {
    local index = sqgi.json.parse(fetch_text(uri))
    Manifest.validate_index(index)
    return index
}

function load_package_manifest(source_uri, pkg) {
    if (pkg == null || !("manifest" in pkg) || pkg.manifest == "") throw "package has no manifest URI"
    local manifest = sqgi.json.parse(fetch_text(resolve_uri(source_uri, pkg.manifest)))
    if (!("schema" in manifest) || manifest.schema != 1) throw "unsupported package manifest schema"
    if (!("name" in manifest) || manifest.name == "") throw "package manifest is missing a name"
    if (!("version" in manifest) || manifest.version == "") throw "package manifest is missing a version"
    return manifest
}

return {
    resolve_uri = resolve_uri,
    fetch_bytes = fetch_bytes,
    fetch_text = fetch_text,
    load_index = load_index,
    load_package_manifest = load_package_manifest,
}
