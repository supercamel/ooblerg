local GLib = import("GLib")
local Config = import("../config.nut")
local U = import("../util.nut")

function path() {
    return Config.sysroot_path()
}

function looks_initialized() {
    local root = path()
    return U.file_exists(GLib.build_filenamev([root, "mingw64"])) ||
        U.file_exists(Config.status_path())
}

function ensure_metadata_dirs() {
    Config.ensure_dirs()
}

return {
    path = path,
    looks_initialized = looks_initialized,
    ensure_metadata_dirs = ensure_metadata_dirs,
}
