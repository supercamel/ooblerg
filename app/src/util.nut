local GLib = import("GLib")
local Gio = import("Gio")

function starts_with(s, prefix) {
    return s != null && prefix != null && s.find(prefix) == 0
}

function ends_with(s, suffix) {
    if (s == null || suffix == null) return false
    if (s.len() < suffix.len()) return false
    return s.slice(s.len() - suffix.len()) == suffix
}

function is_space(ch) {
    return ch == " " || ch == "\t" || ch == "\r" || ch == "\n"
}

function trim(s) {
    if (s == null) return ""
    local a = 0
    local b = s.len()
    while (a < b && is_space(s.slice(a, a + 1))) a++
    while (b > a && is_space(s.slice(b - 1, b))) b--
    return s.slice(a, b)
}

function join(parts, sep) {
    local out = ""
    for (local i = 0; i < parts.len(); i++) {
        if (i > 0) out += sep
        out += parts[i].tostring()
    }
    return out
}

function sorted_keys(t) {
    local keys = []
    if (t == null) return keys
    foreach (k, v in t) keys.append(k)
    keys.sort()
    return keys
}

function table_get(t, key, fallback = null) {
    if (t == null) return fallback
    return key in t ? t[key] : fallback
}

function file_exists(path) {
    if (path == null || path == "") return false
    return Gio.File.new_for_path(path).query_exists(null)
}

function read_text(path) {
    return GLib.file_get_contents(path)
}

function write_text(path, text) {
    local dir = GLib.path_get_dirname(path)
    GLib.mkdir_with_parents(dir, 493)
    GLib.file_set_contents(path, text, -1)
}

function write_binary(path, data) {
    local dir = GLib.path_get_dirname(path)
    GLib.mkdir_with_parents(dir, 493)
    GLib.file_set_contents(path, data, data.len())
}

function write_text_atomic(path, text) {
    local dir = GLib.path_get_dirname(path)
    GLib.mkdir_with_parents(dir, 493)
    local tmp = path + ".tmp." + GLib.uuid_string_random()
    GLib.file_set_contents(tmp, text, -1)
    GLib.rename(tmp, path)
}

function read_json(path) {
    return sqgi.json.parse(read_text(path))
}

function write_json(path, value) {
    write_text(path, sqgi.json.stringify(value, 2) + "\n")
}

function write_json_atomic(path, value) {
    write_text_atomic(path, sqgi.json.stringify(value, 2) + "\n")
}

function file_type(path) {
    return Gio.File.new_for_path(path).query_file_type(Gio.FileQueryInfoFlags.none, null)
}

function is_regular(path) {
    return file_type(path) == Gio.FileType.regular
}

function is_directory(path) {
    return file_type(path) == Gio.FileType.directory
}

function delete_file(path) {
    local f = Gio.File.new_for_path(path)
    if (!f.query_exists(null)) return false
    return f.delete(null)
}

function human_size(n) {
    if (n == null) return ""
    local value = n.tofloat()
    foreach (unit in ["B", "KB", "MB", "GB"]) {
        if (value < 1024.0 || unit == "GB") {
            if (unit == "B") return n.tostring() + " B"
            return format("%.1f %s", value, unit)
        }
        value = value / 1024.0
    }
    return n.tostring()
}

function array_contains(a, value) {
    if (a == null) return false
    foreach (item in a) {
        if (item == value) return true
    }
    return false
}

return {
    starts_with = starts_with,
    ends_with = ends_with,
    trim = trim,
    join = join,
    sorted_keys = sorted_keys,
    table_get = table_get,
    file_exists = file_exists,
    read_text = read_text,
    write_text = write_text,
    write_binary = write_binary,
    write_text_atomic = write_text_atomic,
    read_json = read_json,
    write_json = write_json,
    write_json_atomic = write_json_atomic,
    file_type = file_type,
    is_regular = is_regular,
    is_directory = is_directory,
    delete_file = delete_file,
    human_size = human_size,
    array_contains = array_contains,
}
