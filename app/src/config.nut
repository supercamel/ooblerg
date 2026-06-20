local GLib = import("GLib")
local U = import("util.nut")

local APP_NAME = "Ooblerg Package Manager"
local APP_ID = "dev.ooblerg.pkgmanager"
local DEFAULT_SOURCE_URI = "https://ooblerg.xyz/v1/index.json"
local LEGACY_DEFAULT_SOURCE_URI = "http://127.0.0.1:8787/v1/index.json"
local LEGACY_HTTP_SOURCE_URI = "http://ooblerg.xyz/v1/index.json"

function appdata_base() {
    local local_appdata = GLib.getenv("LOCALAPPDATA")
    if (local_appdata != null && local_appdata != "") {
        return GLib.build_filenamev([local_appdata, "Ooblerg"])
    }
    local data_dir = GLib.get_user_data_dir()
    if (data_dir == null || data_dir == "") data_dir = GLib.get_current_dir()
    return GLib.build_filenamev([data_dir, "ooblerg"])
}

function sysroot_path() {
    return GLib.build_filenamev([appdata_base(), "sysroot"])
}

function config_path() {
    return GLib.build_filenamev([appdata_base(), "config.json"])
}

function cache_dir() {
    return GLib.build_filenamev([appdata_base(), "cache"])
}

function status_dir() {
    return GLib.build_filenamev([sysroot_path(), "var", "lib", "ooblerg"])
}

function status_path() {
    return GLib.build_filenamev([status_dir(), "status.json"])
}

function package_db_dir() {
    return GLib.build_filenamev([status_dir(), "packages"])
}

function ensure_dirs() {
    GLib.mkdir_with_parents(appdata_base(), 493)
    GLib.mkdir_with_parents(cache_dir(), 493)
    GLib.mkdir_with_parents(package_db_dir(), 493)
}

function default_settings() {
    return {
        schema = 3,
        source_uri = DEFAULT_SOURCE_URI,
        sysroot = sysroot_path(),
    }
}

function is_legacy_default_source_uri(uri) {
    return uri == LEGACY_DEFAULT_SOURCE_URI || uri == LEGACY_HTTP_SOURCE_URI
}

function load_settings() {
    local path = config_path()
    if (!U.file_exists(path)) return default_settings()
    local settings = U.read_json(path)
    local schema = "schema" in settings ? settings.schema : 0
    if (!("source_uri" in settings) || settings.source_uri == "") {
        settings.source_uri <- DEFAULT_SOURCE_URI
    } else if (schema < 3 && is_legacy_default_source_uri(settings.source_uri)) {
        settings.source_uri <- DEFAULT_SOURCE_URI
    }
    settings.schema <- 3
    settings.sysroot <- sysroot_path()
    return settings
}

function save_settings(settings) {
    ensure_dirs()
    settings.sysroot <- sysroot_path()
    U.write_json(config_path(), settings)
}

return {
    APP_NAME = APP_NAME,
    APP_ID = APP_ID,
    DEFAULT_SOURCE_URI = DEFAULT_SOURCE_URI,
    appdata_base = appdata_base,
    sysroot_path = sysroot_path,
    config_path = config_path,
    cache_dir = cache_dir,
    status_dir = status_dir,
    status_path = status_path,
    package_db_dir = package_db_dir,
    ensure_dirs = ensure_dirs,
    default_settings = default_settings,
    load_settings = load_settings,
    save_settings = save_settings,
}
