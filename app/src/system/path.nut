local GLib = import("GLib")

local Config = import("../config.nut")

local Native = null
local native_load_error = null

try {
    Native = import("OoblergWin", "1.0")
} catch (e) {
    native_load_error = e.tostring()
}

function mingw_bin_path() {
    return GLib.build_filenamev([Config.sysroot_path(), "mingw64", "bin"])
}

function native_ready() {
    return Native != null && Native.is_supported()
}

function unavailable_message() {
    if (Native == null) return "Windows PATH integration is not available in this runtime"
    return "Windows PATH integration is not available on this platform"
}

function last_error() {
    if (Native == null) return native_load_error == null ? unavailable_message() : native_load_error
    local err = Native.last_error()
    if (err == null || err == "") return unavailable_message()
    return err
}

function is_on_user_path(path = null) {
    if (path == null || path == "") path = mingw_bin_path()
    if (!native_ready()) return false
    return Native.user_path_contains(path)
}

function add_to_user_path(path = null) {
    if (path == null || path == "") path = mingw_bin_path()
    if (!native_ready()) throw unavailable_message()
    if (!Native.add_user_path(path)) throw last_error()
    return true
}

function remove_from_user_path(path = null) {
    if (path == null || path == "") path = mingw_bin_path()
    if (!native_ready()) throw unavailable_message()
    if (!Native.remove_user_path(path)) throw last_error()
    return true
}

return {
    mingw_bin_path = mingw_bin_path,
    native_ready = native_ready,
    is_on_user_path = is_on_user_path,
    add_to_user_path = add_to_user_path,
    remove_from_user_path = remove_from_user_path,
    last_error = last_error,
}
