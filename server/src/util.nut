local GLib = import("GLib")

function starts_with(s, prefix) {
    return s != null && prefix != null && s.find(prefix) == 0
}

function ends_with(s, suffix) {
    if (s == null || suffix == null) return false
    if (s.len() < suffix.len()) return false
    return s.slice(s.len() - suffix.len()) == suffix
}

function trim(s) {
    if (s == null) return ""
    local a = 0
    local b = s.len()
    while (a < b) {
        local ch = s.slice(a, a + 1)
        if (ch != " " && ch != "\t" && ch != "\r" && ch != "\n") break
        a++
    }
    while (b > a) {
        local ch = s.slice(b - 1, b)
        if (ch != " " && ch != "\t" && ch != "\r" && ch != "\n") break
        b--
    }
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

function shell_quote(s) {
    local out = "'"
    for (local i = 0; i < s.len(); i++) {
        local ch = s.slice(i, i + 1)
        if (ch == "'") out += "'\\''"
        else out += ch
    }
    return out + "'"
}

function file_exists(path) {
    return path != null && GLib.file_test(path, GLib.FileTest.exists)
}

function is_regular(path) {
    return path != null && GLib.file_test(path, GLib.FileTest.is_regular)
}

return {
    starts_with = starts_with,
    ends_with = ends_with,
    trim = trim,
    join = join,
    shell_quote = shell_quote,
    file_exists = file_exists,
    is_regular = is_regular,
}
