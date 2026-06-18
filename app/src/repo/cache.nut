local GLib = import("GLib")

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

function verify(path, expected) {
    if (expected == null || expected == "") throw "missing SHA-256 for " + path
    local got = sha256_file(path)
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
    U.write_binary(dst, Client.fetch_bytes(uri))
    verify(dst, artifact.sha256)
    if (logger != null) logger("verified: " + artifact.filename)
    return dst
}

return {
    artifact_dir = artifact_dir,
    artifact_path = artifact_path,
    sha256_file = sha256_file,
    verify = verify,
    ensure_artifact = ensure_artifact,
}
