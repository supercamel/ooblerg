local GLib = import("GLib")

local Config = import("../src/config.nut")
local U = import("../src/util.nut")
local Client = import("../src/repo/client.nut")
local Cache = import("../src/repo/cache.nut")
local Solver = import("../src/pkg/solver.nut")
local Status = import("../src/pkg/status.nut")
local Transaction = import("../src/pkg/transaction.nut")
local PathIntegration = import("../src/system/path.nut")

function fake_index() {
    return {
        schema = 1,
        target = "x86_64-w64-mingw32",
        packages = [
            { name = "runtime", version = "1", summary = "runtime", dependencies = [] },
            { name = "glib", version = "1", summary = "glib", dependencies = ["runtime"] },
            { name = "gtk4", version = "1", summary = "gtk", dependencies = ["glib"] },
            { name = "app", version = "1", summary = "app", dependencies = ["gtk4"] },
        ],
    }
}

function assert_names(items, expected) {
    assert(items.len() == expected.len())
    for (local i = 0; i < expected.len(); i++) {
        assert(items[i].name == expected[i])
    }
}

function test_install_closure() {
    local plan = Solver.install_plan(fake_index(), Status.empty(), ["gtk4"])
    assert_names(plan.install, ["runtime", "glib", "gtk4"])
}

function test_installed_dependency_skipped() {
    local status = Status.empty()
    status.packages["runtime"] <- { version = "1", manual = false }
    local plan = Solver.install_plan(fake_index(), status, ["gtk4"])
    assert_names(plan.install, ["glib", "gtk4"])
}

function test_remove_orphan_cleanup() {
    local status = Status.empty()
    status.packages["runtime"] <- { version = "1", manual = false }
    status.packages["glib"] <- { version = "1", manual = false }
    status.packages["gtk4"] <- { version = "1", manual = true }
    local plan = Solver.remove_plan(fake_index(), status, ["gtk4"])
    assert_names(plan.remove, ["gtk4", "glib", "runtime"])
    assert(plan.remove[1].reason == "orphan")
}

function test_remove_dependent_cascade() {
    local status = Status.empty()
    status.packages["runtime"] <- { version = "1", manual = false }
    status.packages["glib"] <- { version = "1", manual = false }
    status.packages["gtk4"] <- { version = "1", manual = true }
    status.packages["app"] <- { version = "1", manual = true }
    local plan = Solver.remove_plan(fake_index(), status, ["glib"])
    assert(plan.blocked.len() == 0)
    assert(plan.dependents.len() == 2)
    assert(plan.dependents[0].name == "gtk4")
    assert(plan.dependents[1].name == "app")
    assert_names(plan.remove, ["glib", "gtk4", "app", "runtime"])
    assert(plan.remove[1].reason == "dependent")
    assert(plan.remove[2].reason == "dependent")
    assert(plan.remove[3].reason == "orphan")
    assert(Solver.describe_plan(plan).find("also remove installed packages that depend") != null)
}

function test_path_integration_fallback() {
    local path = PathIntegration.mingw_bin_path()
    assert(path.find("mingw64") != null)
    if (!PathIntegration.native_ready()) {
        assert(!PathIntegration.is_on_user_path())
        local failed = false
        try {
            PathIntegration.add_to_user_path()
        } catch (e) {
            failed = e.tostring().find("Windows PATH integration") != null
        }
        assert(failed)
    }
}

function test_http_fallback_classification() {
    assert(Client.http_fallback_uri("https://ooblerg.xyz/v1/index.json") == "http://ooblerg.xyz/v1/index.json")
    assert(Client.http_fallback_uri("http://ooblerg.xyz/v1/index.json") == null)
    assert(Client.should_retry_http("https://ooblerg.xyz/v1/index.json",
        "g-tls-error-quark:2: Unacceptable TLS certificate"))
    assert(Client.should_retry_http("https://ooblerg.xyz/v1/index.json",
        "TLS certificate validation failed"))
    assert(!Client.should_retry_http("https://ooblerg.xyz/v1/index.json", "HTTP 404"))
    assert(!Client.should_retry_http("file:///tmp/index.json",
        "g-tls-error-quark:2: Unacceptable TLS certificate"))
}

function shell_status(status) {
    if (status > 255) return status / 256
    return status
}

function run_argv(argv, cwd = null) {
    local result = GLib.spawn_sync(cwd, argv, null, GLib.SpawnFlags.search_path, null, null)
    local code = shell_status(result[2])
    if (code != 0) throw argv[0] + " failed: " + result[1]
    return result[0]
}

function make_fixture_repo(root) {
    local repo = GLib.build_filenamev([root, "repo", "v1"])
    local stage = GLib.build_filenamev([root, "stage"])
    local filename = "runtime-1-x86_64-w64-mingw32.tar.gz"
    local artifact_rel = "packages/runtime/" + filename
    local manifest_rel = "packages/runtime/runtime-1-x86_64-w64-mingw32.pkg.json"
    local artifact = GLib.build_filenamev([repo, "packages", "runtime", filename])

    U.write_text(GLib.build_filenamev([stage, "mingw64", "bin", "runtime.txt"]), "hello\n")
    GLib.mkdir_with_parents(GLib.path_get_dirname(artifact), 493)
    run_argv(["tar", "-czf", artifact, "-C", stage, "mingw64"])

    local sha = Cache.sha256_file(artifact)
    local manifest = {
        schema = 1,
        name = "runtime",
        version = "1",
        target = "x86_64-w64-mingw32",
        architecture = "x86_64",
        kind = "package",
        summary = "runtime",
        description = "runtime",
        artifact = {
            filename = filename,
            path = artifact_rel,
            sha256 = sha,
            size = 1,
        },
        dependencies = [],
        provides = ["runtime"],
        conflicts = [],
        replaces = [],
        files = [
            { path = "mingw64/bin/runtime.txt", kind = "file", size = 6 },
        ],
        directories = ["mingw64", "mingw64/bin"],
        installed_size = 6,
        tags = [],
    }

    U.write_json(GLib.build_filenamev([repo, "packages", "runtime", "runtime-1-x86_64-w64-mingw32.pkg.json"]), manifest)
    U.write_json(GLib.build_filenamev([repo, "index.json"]), {
        schema = 1,
        repository = "fixture",
        target = "x86_64-w64-mingw32",
        packages = [
            {
                name = "runtime",
                version = "1",
                kind = "package",
                summary = "runtime",
                description = "runtime",
                manifest = manifest_rel,
                artifact = artifact_rel,
                sha256 = sha,
                dependencies = [],
                installed_size = 6,
                size = 1,
                tags = [],
            },
        ],
    })

    return GLib.build_filenamev([repo, "index.json"])
}

function make_replacement_fixture_repo(root) {
    local repo = GLib.build_filenamev([root, "repo", "v1"])
    local stage = GLib.build_filenamev([root, "stage-replacement"])
    local filename = "runtime-2-x86_64-w64-mingw32.tar.gz"
    local artifact_rel = "packages/runtime/" + filename
    local manifest_rel = "packages/runtime/runtime-2-x86_64-w64-mingw32.pkg.json"
    local artifact = GLib.build_filenamev([repo, "packages", "runtime", filename])
    local dll_rel = "mingw64/bin/libstdc++-6.dll"

    U.write_text(GLib.build_filenamev([stage, "mingw64", "bin", "libstdc++-6.dll"]), "new\n")
    GLib.mkdir_with_parents(GLib.path_get_dirname(artifact), 493)
    run_argv(["tar", "-czf", artifact, "-C", stage, "mingw64"])

    local sha = Cache.sha256_file(artifact)
    local manifest = {
        schema = 1,
        name = "runtime",
        version = "2",
        target = "x86_64-w64-mingw32",
        architecture = "x86_64",
        kind = "package",
        summary = "runtime",
        description = "runtime",
        artifact = {
            filename = filename,
            path = artifact_rel,
            sha256 = sha,
            size = 1,
        },
        dependencies = [],
        provides = ["runtime"],
        conflicts = [],
        replaces = ["gcc"],
        files = [
            { path = dll_rel, kind = "file", size = 4 },
        ],
        directories = ["mingw64", "mingw64/bin"],
        installed_size = 4,
        tags = [],
    }

    U.write_json(GLib.build_filenamev([repo, "packages", "runtime", "runtime-2-x86_64-w64-mingw32.pkg.json"]), manifest)
    U.write_json(GLib.build_filenamev([repo, "index.json"]), {
        schema = 1,
        repository = "fixture",
        target = "x86_64-w64-mingw32",
        packages = [
            {
                name = "runtime",
                version = "2",
                kind = "package",
                summary = "runtime",
                description = "runtime",
                manifest = manifest_rel,
                artifact = artifact_rel,
                sha256 = sha,
                dependencies = [],
                installed_size = 4,
                size = 1,
                tags = [],
            },
        ],
    })

    return GLib.build_filenamev([repo, "index.json"])
}

function use_test_root(root) {
    GLib.setenv("LOCALAPPDATA", GLib.build_filenamev([root, "appdata"]), true)
    GLib.setenv("XDG_DATA_HOME", GLib.build_filenamev([root, "xdg-data"]), true)
    GLib.setenv("XDG_CACHE_HOME", GLib.build_filenamev([root, "xdg-cache"]), true)
}

function test_transaction_install_remove() {
    local root = GLib.build_filenamev([GLib.get_tmp_dir(), "ooblerg-app-test-" + GLib.uuid_string_random()])
    use_test_root(root)

    local source_uri = make_fixture_repo(root)
    local index = Client.load_index(source_uri)
    local status = Status.empty(source_uri)
    local install_plan = Solver.install_plan(index, status, ["runtime"])

    status = Transaction.apply(index, status, source_uri, install_plan)
    local installed_file = GLib.build_filenamev([Config.sysroot_path(), "mingw64", "bin", "runtime.txt"])
    assert(U.file_exists(installed_file))
    assert(Status.installed(status, "runtime"))
    assert(U.file_exists(GLib.build_filenamev([Config.package_db_dir(), "runtime.pkg.json"])))

    local remove_plan = Solver.remove_plan(index, status, ["runtime"])
    status = Transaction.apply(index, status, source_uri, remove_plan)
    assert(!U.file_exists(installed_file))
    assert(!Status.installed(status, "runtime"))
    assert(!U.file_exists(GLib.build_filenamev([Config.package_db_dir(), "runtime.pkg.json"])))
}

function test_transaction_install_rollback_after_failure() {
    local root = GLib.build_filenamev([GLib.get_tmp_dir(), "ooblerg-app-test-" + GLib.uuid_string_random()])
    use_test_root(root)

    local source_uri = make_fixture_repo(root)
    local index = Client.load_index(source_uri)
    local status = Status.empty(source_uri)
    local install_plan = Solver.install_plan(index, status, ["runtime"])
    local installed_file = GLib.build_filenamev([Config.sysroot_path(), "mingw64", "bin", "runtime.txt"])

    GLib.mkdir_with_parents(Config.status_dir(), 493)
    U.write_text(Config.package_db_dir(), "not a directory\n")

    local failed = false
    try {
        Transaction.apply(index, status, source_uri, install_plan)
    } catch (e) {
        failed = true
    }
    assert(failed)
    assert(!U.file_exists(installed_file))
    assert(!Status.installed(status, "runtime"))
}

function test_transaction_cleanup_leftovers() {
    local root = GLib.build_filenamev([GLib.get_tmp_dir(), "ooblerg-app-test-" + GLib.uuid_string_random()])
    use_test_root(root)

    local source_uri = make_fixture_repo(root)
    local index = Client.load_index(source_uri)
    local status = Status.empty(source_uri)
    local installed_file = GLib.build_filenamev([Config.sysroot_path(), "mingw64", "bin", "runtime.txt"])
    U.write_text(installed_file, "stale\n")

    local install_plan = Solver.install_plan(index, status, ["runtime"])
    local blocked = false
    try {
        Transaction.apply(index, status, source_uri, install_plan)
    } catch (e) {
        blocked = e.tostring().find("unmanaged file") != null
    }
    assert(blocked)
    assert(U.file_exists(installed_file))

    local cleanup_plan = Solver.cleanup_plan(index, status, ["runtime"])
    status = Transaction.apply(index, status, source_uri, cleanup_plan)
    assert(!U.file_exists(installed_file))
    assert(!Status.installed(status, "runtime"))

    status = Transaction.apply(index, status, source_uri, install_plan)
    assert(U.file_exists(installed_file))
    assert(Status.installed(status, "runtime"))
}

function test_transaction_replaces_file_owner() {
    local root = GLib.build_filenamev([GLib.get_tmp_dir(), "ooblerg-app-test-" + GLib.uuid_string_random()])
    use_test_root(root)

    local source_uri = make_replacement_fixture_repo(root)
    local index = Client.load_index(source_uri)
    local status = Status.empty(source_uri)
    local dll_rel = "mingw64/bin/libstdc++-6.dll"
    local installed_file = GLib.build_filenamev([Config.sysroot_path(), "mingw64", "bin", "libstdc++-6.dll"])

    Config.ensure_dirs()
    U.write_text(installed_file, "old\n")
    U.write_json(GLib.build_filenamev([Config.package_db_dir(), "gcc.pkg.json"]), {
        schema = 1,
        name = "gcc",
        version = "1",
        target = "x86_64-w64-mingw32",
        architecture = "x86_64",
        kind = "package",
        summary = "gcc",
        description = "gcc",
        artifact = null,
        dependencies = [],
        provides = ["gcc"],
        conflicts = [],
        replaces = [],
        files = [
            { path = dll_rel, kind = "file", size = 4 },
        ],
        directories = ["mingw64", "mingw64/bin"],
        installed_size = 4,
        tags = [],
    })
    status.packages["gcc"] <- {
        version = "1",
        kind = "package",
        manual = true,
        installed_at = "test",
        manifest = "var/lib/ooblerg/packages/gcc.pkg.json",
    }

    local install_plan = Solver.install_plan(index, status, ["runtime"])
    status = Transaction.apply(index, status, source_uri, install_plan)

    assert(Status.installed(status, "gcc"))
    assert(Status.installed(status, "runtime"))
    assert(U.read_text(installed_file) == "new\n")

    local gcc_manifest = U.read_json(GLib.build_filenamev([Config.package_db_dir(), "gcc.pkg.json"]))
    assert(gcc_manifest.files.len() == 0)

    local remove_plan = Solver.remove_plan(index, status, ["gcc"])
    status = Transaction.apply(index, status, source_uri, remove_plan)
    assert(!Status.installed(status, "gcc"))
    assert(Status.installed(status, "runtime"))
    assert(U.file_exists(installed_file))
}

function run_async_test(task) {
    local loop = GLib.MainLoop.new(null, false)
    local failure = null
    task.then(function(_) {
        loop.quit()
    }, function(e) {
        failure = e
        loop.quit()
    })
    loop.run()
    if (failure != null) throw failure
}

async function test_transaction_install_progress() {
    local root = GLib.build_filenamev([GLib.get_tmp_dir(), "ooblerg-app-test-" + GLib.uuid_string_random()])
    use_test_root(root)

    local source_uri = make_fixture_repo(root)
    local index = Client.load_index(source_uri)
    local status = Status.empty(source_uri)
    local install_plan = Solver.install_plan(index, status, ["runtime"])
    local saw_download = false
    local saw_verify = false
    local saw_extract = false
    local progress_events = 0

    status = await Transaction.apply_async(index, status, source_uri, install_plan, null, function(event) {
        progress_events++
        if ("phase" in event && event.phase == "download") saw_download = true
        if ("phase" in event && event.phase == "verify") saw_verify = true
        if ("phase" in event && event.phase == "extract") saw_extract = true
    })

    assert(Status.installed(status, "runtime"))
    assert(progress_events > 0)
    assert(saw_download)
    assert(saw_verify)
    assert(saw_extract)
}

test_install_closure()
test_installed_dependency_skipped()
test_remove_orphan_cleanup()
test_remove_dependent_cascade()
test_path_integration_fallback()
test_http_fallback_classification()
test_transaction_install_remove()
test_transaction_install_rollback_after_failure()
test_transaction_cleanup_leftovers()
test_transaction_replaces_file_owner()
run_async_test(test_transaction_install_progress())

return true
