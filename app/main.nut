local GLib = import("GLib")

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
    print("  sqgi app/main.nut --auto-refresh  refresh repository after launch\n")
    print("  sqgi app/main.nut --gtk-smoke-test --source-uri=URI\n")
}

if (has_arg("--help") || has_arg("-h")) {
    print_help()
    return 0
}

if (has_arg("--self-test")) {
    import("test/package_tests.nut")
    print("[OK] app self-tests passed\n")
    return 0
}

local UI = import("src/ui/window.nut")
local app = UI.create_app({
    auto_refresh = has_arg("--auto-refresh"),
    gtk_smoke_test = has_arg("--gtk-smoke-test"),
    source_uri = arg_value("--source-uri", ""),
    test_package = arg_value("--test-package", "cairo"),
    test_timeout_ms = arg_value("--test-timeout-ms", "10000").tointeger(),
})
local run_code = app.run(0, null)
if (has_arg("--gtk-smoke-test")) return UI.test_exit_code()
return run_code
