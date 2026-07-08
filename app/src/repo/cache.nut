local GLib = import("GLib")
local Gio = import("Gio")

local Config = import("../config.nut")
local U = import("../util.nut")
local Client = import("client.nut")

function artifact_dir() {
    return GLib.build_filenamev([Config.cache_dir(), "artifacts"])
}

function artifact_path(filename) {
    return GLib.build_filenamev([artifact_dir(), filename])
}

function sha256_file(path) {
    local data = GLib.file_get_contents(path)
    return GLib.compute_checksum_for_string(GLib.ChecksumType.sha256, data, data.len())
}

function query_local_size(path) {
    try {
        return Gio.File.new_for_path(path).query_info("standard::size", 0, null).get_size()
    } catch (e) {
        return -1
    }
}

function put(t, key, value) {
    if (key in t) t[key] = value
    else t[key] <- value
}

function report(progress, event) {
    if (progress != null) progress(event)
}

function report_file_progress(progress, phase, path, bytes_done, bytes_total, done) {
    if (progress == null) return
    local event = {
        phase = phase,
        path = path,
        bytes = bytes_done,
        total = bytes_total,
        done = done,
    }
    if (bytes_total > 0) event.fraction <- bytes_done.tofloat() / bytes_total.tofloat()
    progress(event)
}

function sha256_file_async(path, progress = null) {
    local task = sqgi.Task()
    local input = Gio.File.new_for_path(path).read(null)
    local checksum = GLib.Checksum.new(GLib.ChecksumType.sha256)
    local bytes_total = query_local_size(path)
    local bytes_done = 0
    local CHUNKS_PER_TICK = 16
    local CHUNK_SIZE = 65536

    report_file_progress(progress, "verify", path, bytes_done, bytes_total, false)
    sqgi.timeout_add(0, function() {
        try {
            for (local i = 0; i < CHUNKS_PER_TICK; i++) {
                local chunk = input.read_bytes(CHUNK_SIZE, null)
                local n = chunk.get_size()
                if (n == 0) {
                    try { input.close_sync(null) } catch (_) {}
                    local got = checksum.get_string()
                    report_file_progress(progress, "verify", path, bytes_done, bytes_total, true)
                    task.resolve(got)
                    return false
                }
                checksum.update(chunk.get_data(), n)
                bytes_done += n
            }
            report_file_progress(progress, "verify", path, bytes_done, bytes_total, false)
            return true
        } catch (e) {
            try { input.close_sync(null) } catch (_) {}
            task.reject(e)
            return false
        }
    })

    return task
}

function verify(path, expected) {
    if (expected == null || expected == "") throw "missing SHA-256 for " + path
    local got = sha256_file(path)
    if (got != expected) throw "SHA-256 mismatch for " + path + ": expected " + expected + ", got " + got
    return true
}

async function verify_async(path, expected, progress = null) {
    if (expected == null || expected == "") throw "missing SHA-256 for " + path
    local got = await sha256_file_async(path, progress)
    if (got != expected) throw "SHA-256 mismatch for " + path + ": expected " + expected + ", got " + got
    return true
}

function manifest_artifact(manifest) {
    if (manifest == null || !("artifact" in manifest) || manifest.artifact == null) return null
    local artifact = manifest.artifact
    if (!("filename" in artifact) || artifact.filename == "") throw manifest.name + " artifact has no filename"
    if (!("path" in artifact) || artifact.path == "") throw manifest.name + " artifact has no repository path"
    if (!("sha256" in artifact) || artifact.sha256 == "") throw manifest.name + " artifact has no SHA-256"
    return artifact
}

function ensure_artifact(source_uri, manifest, logger = null) {
    local artifact = manifest_artifact(manifest)
    if (artifact == null) return null

    GLib.mkdir_with_parents(artifact_dir(), 493)
    local dst = artifact_path(artifact.filename)
    if (U.file_exists(dst)) {
        try {
            verify(dst, artifact.sha256)
            if (logger != null) logger("cache hit: " + artifact.filename)
            return dst
        } catch (e) {
            if (logger != null) logger("discard corrupt cache entry: " + artifact.filename)
            U.delete_file(dst)
        }
    }

    local uri = Client.resolve_uri(source_uri, artifact.path)
    if (logger != null) logger("download: " + uri)
    local result = Client.fetch_bytes_result(uri)
    if (result.used_http_fallback && logger != null) logger("HTTP fallback: " + result.uri)
    U.write_binary(dst, result.bytes)
    verify(dst, artifact.sha256)
    if (logger != null) logger("verified: " + artifact.filename)
    return dst
}

async function ensure_artifact_async(source_uri, manifest, logger = null, progress = null) {
    local artifact = manifest_artifact(manifest)
    if (artifact == null) return null

    GLib.mkdir_with_parents(artifact_dir(), 493)
    local dst = artifact_path(artifact.filename)

    local wrap_progress = function(event) {
        put(event, "package", manifest.name)
        put(event, "filename", artifact.filename)
        report(progress, event)
    }

    if (U.file_exists(dst)) {
        try {
            await verify_async(dst, artifact.sha256, wrap_progress)
            if (logger != null) logger("cache hit: " + artifact.filename)
            report(progress, {
                phase = "cache",
                package = manifest.name,
                filename = artifact.filename,
                path = dst,
                done = true,
            })
            return dst
        } catch (e) {
            if (logger != null) logger("discard corrupt cache entry: " + artifact.filename)
            U.delete_file(dst)
        }
    }

    local uri = Client.resolve_uri(source_uri, artifact.path)
    local tmp = dst + ".part." + GLib.uuid_string_random()
    if (logger != null) logger("download: " + uri)
    try {
        local result = await Client.fetch_to_file_result(uri, tmp, wrap_progress)
        if (result.used_http_fallback && logger != null) logger("HTTP fallback: " + result.uri)
        await verify_async(tmp, artifact.sha256, wrap_progress)
        if (U.file_exists(dst)) U.delete_file(dst)
        GLib.rename(tmp, dst)
    } catch (e) {
        if (U.file_exists(tmp)) U.delete_file(tmp)
        throw e
    }

    if (logger != null) logger("verified: " + artifact.filename)
    return dst
}

return {
    artifact_dir = artifact_dir,
    artifact_path = artifact_path,
    sha256_file = sha256_file,
    sha256_file_async = sha256_file_async,
    verify = verify,
    verify_async = verify_async,
    ensure_artifact = ensure_artifact,
    ensure_artifact_async = ensure_artifact_async,
}
