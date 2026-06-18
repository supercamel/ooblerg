local GLib = import("GLib")

local Config = import("../src/config.nut")
local U = import("../src/util.nut")
local Client = import("../src/repo/client.nut")
local Cache = import("../src/repo/cache.nut")
local Solver = import("../src/pkg/solver.nut")
local Status = import("../src/pkg/status.nut")
local Transaction = import("../src/pkg/transaction.nut")

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

function test_block_reverse_dependency() {
    local status = Status.empty()
    status.packages["runtime"] <- { version = "1", manual = false }
    status.packages["glib"] <- { version = "1", manual = false }
    status.packages["gtk4"] <- { version = "1", manual = true }
    local plan = Solver.remove_plan(fake_index(), status, ["glib"])
    assert(plan.blocked.len() == 1)
    assert(plan.blocked[0].required_by == "gtk4")
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

function test_transaction_install_remove() {
    local root = GLib.build_filenamev([GLib.get_tmp_dir(), "ooblerg-app-test-" + GLib.uuid_string_random()])
    GLib.setenv("LOCALAPPDATA", GLib.build_filenamev([root, "appdata"]), true)
    GLib.setenv("XDG_DATA_HOME", GLib.build_filenamev([root, "xdg-data"]), true)
    GLib.setenv("XDG_CACHE_HOME", GLib.build_filenamev([root, "xdg-cache"]), true)

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

test_install_closure()
test_installed_dependency_skipped()
test_remove_orphan_cleanup()
test_block_reverse_dependency()
test_transaction_install_remove()

return true
