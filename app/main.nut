local GLib = import("GLib")
local Gio = import("Gio")

function setenv_if_missing(name, value) {
    local existing = GLib.getenv(name)
    if (existing == null || existing == "") GLib.setenv(name, value, true)
}

function first_existing_bundle_path(appdir, rels) {
    foreach (rel in rels) {
        local parts = [appdir]
        foreach (part in rel) parts.push(part)
        local path = GLib.build_filenamev(parts)
        local file = Gio.File.new_for_path(path)
        if (!file.query_exists(null)) continue
        try {
            if (file.query_info("standard::size", 0, null).get_size() > 0) return path
        } catch (e) {}
    }
    return null
}

function configure_bundle_tls() {
    local appdir = GLib.getenv("SQGI_APPDIR")
    if (appdir == null || appdir == "") return

    local cert_file = first_existing_bundle_path(appdir, [
        ["share", "ooblerg", "certs", "ca-bundle.crt"],
        ["etc", "ssl", "certs", "ca-bundle.crt"],
        ["etc", "ssl", "cert.pem"],
        ["etc", "pki", "ca-trust", "extracted", "pem", "tls-ca-bundle.pem"],
    ])
    if (cert_file != null) {
        setenv_if_missing("SSL_CERT_FILE", cert_file)
        setenv_if_missing("CURL_CA_BUNDLE", cert_file)
    }

    local openssl_conf = first_existing_bundle_path(appdir, [
        ["etc", "ssl", "openssl.cnf"],
    ])
    if (openssl_conf != null) setenv_if_missing("OPENSSL_CONF", openssl_conf)
}

function arg_value(name, fallback) {
    foreach (a in vargv) {
        if (a.find(name + "=") == 0) return a.slice(name.len() + 1)
    }
    return fallback
}

function has_arg(name) {
    foreach (a in vargv) {
        if (a == name) return true
    }
    return false
}

function print_help() {
    print("Ooblerg Package Manager\n")
    print("  sqgi app/main.nut                 launch GTK4 package manager\n")
    print("  sqgi app/main.nut --self-test     run package model/solver tests\n")
    print("  sqgi app/main.nut --check-source  load repository index and exit\n")
    print("  sqgi app/main.nut --no-auto-refresh  skip startup repository refresh\n")
    print("  sqgi app/main.nut --gtk-smoke-test --source-uri=URI\n")
}

if (has_arg("--help") || has_arg("-h")) {
    print_help()
    return 0
}

configure_bundle_tls()

if (has_arg("--self-test")) {
    import("test/package_tests.nut")
    print("[OK] app self-tests passed\n")
    return 0
}

if (has_arg("--check-source")) {
    local Config = import("src/config.nut")
    local Client = import("src/repo/client.nut")
    local uri = arg_value("--source-uri", Config.DEFAULT_SOURCE_URI)
    try {
        local index = Client.load_index(uri)
        print("[OK] source: " + uri + " loaded " + index.packages.len() + " packages\n")
        return 0
    } catch (e) {
        print("[FAIL] source: " + e + "\n")
        return 1
    }
}

function log_uncaught_error(e) {
    try {
        local Config = import("src/config.nut")
        local U = import("src/util.nut")
        local stamp = GLib.DateTime.new_now_local().format("%Y-%m-%d %H:%M:%S")
        U.append_text(Config.log_path(), "[" + stamp + "] fatal: " + e + "\n")
    } catch (_) {}
}

try {
    local UI = import("src/ui/window.nut")
    local app = UI.create_app({
        auto_refresh = !has_arg("--no-auto-refresh"),
        gtk_smoke_test = has_arg("--gtk-smoke-test"),
        source_uri = arg_value("--source-uri", ""),
        test_package = arg_value("--test-package", "cairo"),
        test_timeout_ms = arg_value("--test-timeout-ms", "10000").tointeger(),
    })
    local run_code = app.run(0, null)
    if (has_arg("--gtk-smoke-test")) return UI.test_exit_code()
    return run_code
} catch (e) {
    log_uncaught_error(e)
    print("[FAIL] app: " + e + "\n")
    return 1
}
