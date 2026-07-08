local GLib = import("GLib")
local Gio = import("Gio")
local U = import("../util.nut")
local Manifest = import("../pkg/manifest.nut")

local Soup = null
try {
    Soup = import("Soup", "3.0")
} catch (e) {
    Soup = null
}

function is_http_uri(uri) {
    return U.starts_with(uri, "http://") || U.starts_with(uri, "https://")
}

function is_https_uri(uri) {
    return U.starts_with(uri, "https://")
}

function http_fallback_uri(uri) {
    if (!is_https_uri(uri)) return null
    return "http://" + uri.slice("https://".len())
}

function looks_like_tls_certificate_error(e) {
    local text = e == null ? "" : e.tostring().tolower()
    if (text.find("g-tls-error-quark") != null) return true
    if (text.find("unacceptable tls certificate") != null) return true
    if (text.find("tls") != null && text.find("certificate") != null) return true
    return false
}

function should_retry_http(uri, e) {
    return is_https_uri(uri) && looks_like_tls_certificate_error(e) &&
        http_fallback_uri(uri) != null
}

function env_value(name) {
    local value = GLib.getenv(name)
    if (value == null || value == "") return "<unset>"
    return value
}

function tls_backend_summary() {
    try {
        local backend = Gio.tls_backend_get_default()
        if (backend == null) return "GIO TLS backend: none"
        local supports = false
        try { supports = backend.supports_tls() } catch (e) {}
        return "GIO TLS backend: " + backend + ", supports TLS: " + (supports ? "yes" : "no")
    } catch (e) {
        return "GIO TLS backend diagnostics unavailable: " + e
    }
}

function network_diagnostics(uri) {
    local lines = []
    lines.append("libsoup 3.0: " + (Soup == null ? "unavailable" : "available"))
    if (is_https_uri(uri)) {
        lines.append(tls_backend_summary())
        lines.append("GIO_EXTRA_MODULES=" + env_value("GIO_EXTRA_MODULES"))
        lines.append("SSL_CERT_FILE=" + env_value("SSL_CERT_FILE"))
        lines.append("CURL_CA_BUNDLE=" + env_value("CURL_CA_BUNDLE"))
        lines.append("OPENSSL_CONF=" + env_value("OPENSSL_CONF"))
    }
    return U.join(lines, "\n")
}

function fetch_error(uri, e) {
    local text = e == null ? "unknown error" : e.tostring()
    if (is_https_uri(uri)) {
        return "failed to fetch " + uri + ": " + text + "\n" + network_diagnostics(uri)
    }
    return "failed to fetch " + uri + ": " + text
}

function fetch_fallback_error(uri, fallback, first_error, fallback_error) {
    return "failed to fetch " + uri + ": " + first_error +
        "\nRetried over HTTP as " + fallback + " but that also failed: " + fallback_error +
        "\n" + network_diagnostics(uri)
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

function fetch_bytes_once(uri) {
    uri = U.trim(uri)
    if (uri == "") throw "source URI is blank"
    if (!is_http_uri(uri)) {
        return GLib.file_get_contents(local_path_from_uri(uri))
    }
    if (Soup == null) throw "libsoup 3.0 is not available in this SQGI runtime"
    try {
        local msg = Soup.Message.new("GET", uri)
        if (msg == null) throw "invalid URI: " + uri
        local session = Soup.Session.new()
        local bytes = session.send_and_read(msg, null)
        local status = msg.get_status()
        if (status < 200 || status >= 300) throw "HTTP " + status + " for " + uri
        return bytes.get_data()
    } catch (e) {
        throw fetch_error(uri, e)
    }
}

function fetch_bytes_result(uri) {
    uri = U.trim(uri)
    try {
        return {
            uri = uri,
            bytes = fetch_bytes_once(uri),
            used_http_fallback = false,
            original_uri = uri,
        }
    } catch (e) {
        if (!should_retry_http(uri, e)) throw e
        local fallback = http_fallback_uri(uri)
        try {
            return {
                uri = fallback,
                bytes = fetch_bytes_once(fallback),
                used_http_fallback = true,
                original_uri = uri,
                fallback_reason = e.tostring(),
            }
        } catch (fallback_error) {
            throw fetch_fallback_error(uri, fallback, e, fallback_error)
        }
    }
}

function fetch_bytes(uri) {
    return fetch_bytes_result(uri).bytes
}

function query_local_size(path) {
    try {
        return Gio.File.new_for_path(path).query_info("standard::size", 0, null).get_size()
    } catch (e) {
        return -1
    }
}

function report_download(progress, uri, output_path, bytes_written, bytes_total, done) {
    if (progress == null) return
    local event = {
        phase = "download",
        uri = uri,
        path = output_path,
        bytes = bytes_written,
        total = bytes_total,
        done = done,
    }
    if (bytes_total > 0) event.fraction <- bytes_written.tofloat() / bytes_total.tofloat()
    progress(event)
}

function stream_to_file(uri, in_stream, output_path, bytes_total, progress = null) {
    local task = sqgi.Task()
    local out_file = Gio.File.new_for_path(output_path)
    local out_stream = out_file.replace(null, false, Gio.FileCreateFlags.none, null)

    local CHUNKS_PER_TICK = 8
    local CHUNK_SIZE = 65536
    local bytes_written = 0

    report_download(progress, uri, output_path, bytes_written, bytes_total, false)
    sqgi.timeout_add(0, function() {
        try {
            for (local i = 0; i < CHUNKS_PER_TICK; i++) {
                local chunk = in_stream.read_bytes(CHUNK_SIZE, null)
                local n = chunk.get_size()
                if (n == 0) {
                    try { out_stream.close_sync(null) } catch (_) {}
                    try { in_stream.close_sync(null) } catch (_) {}
                    report_download(progress, uri, output_path, bytes_written, bytes_total, true)
                    task.resolve(bytes_written)
                    return false
                }
                out_stream.write_bytes(chunk, null)
                bytes_written += n
            }
            report_download(progress, uri, output_path, bytes_written, bytes_total, false)
            return true
        } catch (e) {
            try { out_stream.close_sync(null) } catch (_) {}
            try { in_stream.close_sync(null) } catch (_) {}
            task.reject(e)
            return false
        }
    })

    return task
}

function fetch_to_file_once(uri, output_path, progress = null) {
    uri = U.trim(uri)
    if (uri == "") throw "source URI is blank"

    if (!is_http_uri(uri)) {
        local path = local_path_from_uri(uri)
        local in_stream = Gio.File.new_for_path(path).read(null)
        return stream_to_file(uri, in_stream, output_path, query_local_size(path), progress)
    }

    if (Soup == null) throw "libsoup 3.0 is not available in this SQGI runtime"
    local msg = null
    local in_stream = null
    try {
        msg = Soup.Message.new("GET", uri)
        if (msg == null) throw "invalid URI: " + uri
        local session = Soup.Session.new()
        in_stream = session.send(msg, null)
        local status = msg.get_status()
        if (status < 200 || status >= 300) {
            try { in_stream.close_sync(null) } catch (_) {}
            throw "HTTP " + status + " for " + uri
        }
    } catch (e) {
        if (in_stream != null) try { in_stream.close_sync(null) } catch (_) {}
        throw fetch_error(uri, e)
    }

    local bytes_total = -1
    try {
        bytes_total = msg.get_response_headers().get_content_length()
    } catch (e) {}
    return stream_to_file(uri, in_stream, output_path, bytes_total, progress)
}

async function fetch_to_file_result(uri, output_path, progress = null) {
    uri = U.trim(uri)
    try {
        local bytes_written = await fetch_to_file_once(uri, output_path, progress)
        return {
            uri = uri,
            bytes = bytes_written,
            used_http_fallback = false,
            original_uri = uri,
        }
    } catch (e) {
        if (!should_retry_http(uri, e)) throw e
        local fallback = http_fallback_uri(uri)
        try {
            local bytes_written = await fetch_to_file_once(fallback, output_path, progress)
            return {
                uri = fallback,
                bytes = bytes_written,
                used_http_fallback = true,
                original_uri = uri,
                fallback_reason = e.tostring(),
            }
        } catch (fallback_error) {
            throw fetch_fallback_error(uri, fallback, e, fallback_error)
        }
    }
}

function fetch_to_file(uri, output_path, progress = null) {
    local task = sqgi.Task()
    fetch_to_file_result(uri, output_path, progress).then(
        function(result) { task.resolve(result.bytes) },
        function(e) { task.reject(e) })
    return task
}

function fetch_text(uri) {
    return fetch_bytes(uri)
}

function load_index_result(uri) {
    local result = fetch_bytes_result(uri)
    local index = sqgi.json.parse(result.bytes)
    Manifest.validate_index(index)
    result.index <- index
    return result
}

function load_index(uri) {
    return load_index_result(uri).index
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
    http_fallback_uri = http_fallback_uri,
    looks_like_tls_certificate_error = looks_like_tls_certificate_error,
    should_retry_http = should_retry_http,
    fetch_bytes_result = fetch_bytes_result,
    fetch_bytes = fetch_bytes,
    fetch_to_file_result = fetch_to_file_result,
    fetch_to_file = fetch_to_file,
    fetch_text = fetch_text,
    load_index_result = load_index_result,
    load_index = load_index,
    load_package_manifest = load_package_manifest,
    network_diagnostics = network_diagnostics,
}
