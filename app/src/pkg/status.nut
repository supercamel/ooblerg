local Config = import("../config.nut")
local U = import("../util.nut")

function empty(source_uri = null) {
    return {
        schema = 1,
        target = "x86_64-w64-mingw32",
        source_uri = source_uri == null ? Config.DEFAULT_SOURCE_URI : source_uri,
        packages = {},
    }
}

function load(source_uri = null) {
    local path = Config.status_path()
    if (!U.file_exists(path)) return empty(source_uri)
    local status = U.read_json(path)
    if (!("packages" in status)) status.packages <- {}
    if (source_uri != null) status.source_uri <- source_uri
    return status
}

function save(status) {
    Config.ensure_dirs()
    U.write_json_atomic(Config.status_path(), status)
}

function installed(status, name) {
    return status != null && "packages" in status && name in status.packages
}

function info(status, name) {
    if (!installed(status, name)) return null
    return status.packages[name]
}

function is_manual(status, name) {
    local item = info(status, name)
    if (item == null) return false
    return !("manual" in item) || item.manual
}

return {
    empty = empty,
    load = load,
    save = save,
    installed = installed,
    info = info,
    is_manual = is_manual,
}
