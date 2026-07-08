local GLib = import("GLib")
local Gio = import("Gio")
local U = import("../util.nut")

function path_join(parts) {
    return GLib.build_filenamev(parts)
}

function split_lines(text) {
    local out = []
    local start = 0
    for (local i = 0; i < text.len(); i++) {
        local ch = text.slice(i, i + 1)
        if (ch == "\n") {
            out.append(text.slice(start, i))
            start = i + 1
        }
    }
    if (start < text.len()) out.append(text.slice(start))
    return out
}

function starts_with(s, prefix) {
    return U.starts_with(s, prefix)
}

function ends_with(s, suffix) {
    return U.ends_with(s, suffix)
}

function ensure_dir(path) {
    GLib.mkdir_with_parents(path, 493)
}

function read_text(path) {
    return GLib.file_get_contents(path)
}

function write_text(path, text) {
    ensure_dir(GLib.path_get_dirname(path))
    GLib.file_set_contents(path, text, -1)
}

function append_text(path, text) {
    ensure_dir(GLib.path_get_dirname(path))
    local file = Gio.File.new_for_path(path)
    local stream = file.append_to(Gio.FileCreateFlags.none, null)
    stream.write(text, text.len(), null)
    stream.close(null)
}

function month_for_iso(iso) {
    if (iso == null || iso.len() < 7) return "unknown"
    return iso.slice(0, 7)
}

function now_iso() {
    return GLib.DateTime.new_now_utc().format("%Y-%m-%dT%H:%M:%SZ")
}

function sha256(text) {
    return GLib.compute_checksum_for_string(GLib.ChecksumType.sha256, text, text.len())
}

function first_forwarded_for(value) {
    value = U.trim(value)
    local p = value.find(",")
    if (p != null) return U.trim(value.slice(0, p))
    return value
}

function header_one(msg, name) {
    try {
        local headers = msg.get_request_headers()
        if (headers == null) return ""
        local value = headers.get_one(name)
        return value == null ? "" : value
    } catch (e) {
        return ""
    }
}

function client_ip(msg) {
    local forwarded = first_forwarded_for(header_one(msg, "X-Forwarded-For"))
    if (forwarded != "") return forwarded
    local real = U.trim(header_one(msg, "X-Real-IP"))
    if (real != "") return real
    return ""
}

function kind_for_path(path) {
    if (path == "/" || path == "/index.html") return "page"
    if (path == "/downloads/OoblergSetup.exe") return "installer"
    if (path == "/downloads/OoblergSetup.exe.sha256") return "installer_checksum"
    if (path == "/v1/index.json") return "repo_index"
    if (starts_with(path, "/v1/packages/") && ends_with(path, ".pkg.json")) return "package_manifest"
    if (starts_with(path, "/packages/") && ends_with(path, ".tar.gz")) return "package_artifact"
    return "asset"
}

function event_path(metrics_dir) {
    return path_join([metrics_dir, "events.jsonl"])
}

function secret_path(metrics_dir) {
    return path_join([metrics_dir, "secret"])
}

function metrics_secret(metrics_dir) {
    local path = secret_path(metrics_dir)
    if (U.is_regular(path)) {
        local secret = U.trim(read_text(path))
        if (secret != "") return secret
    }
    local secret = GLib.uuid_string_random() + "-" + GLib.uuid_string_random()
    write_text(path, secret + "\n")
    return secret
}

class MetricsRecorder {
    metrics_dir = null
    secret = null

    constructor(metrics_dir) {
        this.metrics_dir = metrics_dir
        this.secret = metrics_secret(metrics_dir)
    }

    function record(msg, path, status, bytes) {
        local ip = client_ip(msg)
        local user_agent = header_one(msg, "User-Agent")
        local user_key = ip + "\n" + user_agent
        local ts = now_iso()
        local event = {
            ts = ts,
            month = month_for_iso(ts),
            method = msg.get_method(),
            path = path,
            kind = kind_for_path(path),
            status = status,
            bytes = bytes,
            user = sha256(this.secret + "\nuser\n" + user_key),
            ua = sha256(this.secret + "\nua\n" + user_agent),
        }
        append_text(event_path(this.metrics_dir), sqgi.json.stringify(event, 0) + "\n")
    }
}

function bump_count(t, key, amount = 1) {
    if (!(key in t)) t[key] <- 0
    t[key] += amount
}

function ensure_month(summary, month) {
    if (!(month in summary)) {
        summary[month] <- {
            requests = 0,
            downloads = 0,
            bytes = 0,
            users = {},
            download_users = {},
            kinds = {},
        }
    }
    return summary[month]
}

function ensure_kind(month, kind) {
    if (!(kind in month.kinds)) {
        month.kinds[kind] <- {
            requests = 0,
            downloads = 0,
            bytes = 0,
            users = {},
            download_users = {},
        }
    }
    return month.kinds[kind]
}

function summarize(metrics_dir) {
    local path = event_path(metrics_dir)
    local summary = {}
    if (!U.is_regular(path)) return summary
    foreach (line in split_lines(read_text(path))) {
        line = U.trim(line)
        if (line == "") continue
        local event = null
        try {
            event = sqgi.json.parse(line)
        } catch (e) {
            continue
        }
        local month_key = "month" in event ? event.month : month_for_iso(event.ts)
        local status = "status" in event ? event.status : 0
        if (status < 200 || status >= 300) continue
        local month = ensure_month(summary, month_key)
        local kind_name = "kind" in event ? event.kind : "unknown"
        local kind = ensure_kind(month, kind_name)
        local method = "method" in event ? event.method : "GET"
        local is_download = method == "GET" &&
            (kind_name == "installer" || kind_name == "package_artifact")
        local bytes = "bytes" in event ? event.bytes : 0
        month.requests++
        month.bytes += bytes
        kind.requests++
        kind.bytes += bytes
        if (is_download) {
            month.downloads++
            kind.downloads++
        }
        if ("user" in event && event.user != "") {
            month.users[event.user] <- true
            kind.users[event.user] <- true
            if (is_download) {
                month.download_users[event.user] <- true
                kind.download_users[event.user] <- true
            }
        }
    }
    return summary
}

function table_count(t) {
    local n = 0
    foreach (k, v in t) n++
    return n
}

function format_size(bytes) {
    local value = bytes.tofloat()
    foreach (unit in ["B", "KiB", "MiB", "GiB", "TiB"]) {
        if (value < 1024.0 || unit == "TiB") {
            if (unit == "B") return bytes.tostring() + " B"
            return format("%.1f %s", value, unit)
        }
        value = value / 1024.0
    }
    return bytes.tostring() + " B"
}

function report_text(metrics_dir, only_month = "") {
    local summary = summarize(metrics_dir)
    local lines = []
    lines.append("Ooblerg Metrics")
    lines.append("events: " + event_path(metrics_dir))
    lines.append("")
    local months = U.sorted_keys(summary)
    if (months.len() == 0) {
        lines.append("No metrics recorded yet.")
        return U.join(lines, "\n") + "\n"
    }
    foreach (month_key in months) {
        if (only_month != "" && month_key != only_month) continue
        local month = summary[month_key]
        lines.append(month_key + ": " + month.requests + " requests, " +
            month.downloads + " downloads, " +
            table_count(month.users) + " unique users, " +
            table_count(month.download_users) + " download users, " +
            format_size(month.bytes))
        foreach (kind_name in U.sorted_keys(month.kinds)) {
            local kind = month.kinds[kind_name]
            lines.append("  " + kind_name + ": " + kind.requests + " requests, " +
                kind.downloads + " downloads, " +
                table_count(kind.users) + " unique users, " +
                table_count(kind.download_users) + " download users, " +
                format_size(kind.bytes))
        }
        lines.append("")
    }
    return U.join(lines, "\n")
}

return {
    MetricsRecorder = MetricsRecorder,
    event_path = event_path,
    kind_for_path = kind_for_path,
    report_text = report_text,
    summarize = summarize,
}
