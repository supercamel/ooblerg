local Static = import("../src/http/static.nut")
local Builder = import("../src/repo/builder.nut")

function test_unsafe_paths() {
    assert(Static.unsafe_path("../secret"))
    assert(Static.unsafe_path("v1/../../secret"))
    assert(Static.unsafe_path("C:/Windows"))
    assert(Static.unsafe_path("v1\\index.json"))
    assert(!Static.unsafe_path("v1/index.json"))
}

function test_content_types() {
    assert(Static.content_type("index.json") == "application/json")
    assert(Static.content_type("index.json.sha256") == "text/plain")
    assert(Static.content_type("pkg.tar.gz") == "application/gzip")
}

function test_builder_normalizes_paths() {
    local builder = Builder.RepositoryBuilder()
    local opts = builder.normalize_options({
        artifact_dir = "out/artifacts",
        repo_dir = "out/repo",
        repository = "test-repo",
        packages = ["native-sdk"],
    })
    assert(opts.root != "")
    assert(opts.artifact_dir.find(opts.root) == 0)
    assert(opts.repo_dir.find(opts.root) == 0)
    assert(opts.packages.len() == 1)
    assert(opts.packages[0] == "native-sdk")
}

function test_builder_rejects_unsafe_tar_members() {
    local builder = Builder.RepositoryBuilder()
    assert(builder.safe_tar_member_name("mingw64/bin/tool.exe") == "mingw64/bin/tool.exe")
    assert(builder.safe_tar_member_name("./mingw64/bin/tool.exe") == "mingw64/bin/tool.exe")
    assert(builder.safe_tar_member_name("../escape") == null)
    assert(builder.safe_tar_member_name("/absolute") == null)
    assert(builder.safe_tar_member_name("C:/Windows") == null)
}

function test_native_sdk_dependency_closure() {
    local builder = Builder.RepositoryBuilder()
    local opts = builder.normalize_options({
        artifact_dir = "out/artifacts",
        repo_dir = "out/repo",
        repository = "test-repo",
        packages = [],
    })
    local loaded = builder.load_manifest(opts.root)
    local names = builder.dependency_closure(loaded.packages, ["native-sdk"])
    assert(names.top() == "native-sdk")

    local found_gcc = false
    local found_busybox = false
    foreach (name in names) {
        if (name == "gcc") found_gcc = true
        if (name == "busybox-w32") found_busybox = true
    }
    assert(found_gcc)
    assert(!found_busybox)
}

function package_count(index_path) {
    return sqgi.json.parse(GLib.file_get_contents(index_path)).packages.len()
}

function has_package(index_path, name) {
    local index = sqgi.json.parse(GLib.file_get_contents(index_path))
    foreach (pkg in index.packages) {
        if (pkg.name == name) return true
    }
    return false
}

function test_partial_repo_index_preserves_existing_entries() {
    local root = GLib.build_filenamev([GLib.get_tmp_dir(), "ooblerg-repo-test-" + GLib.uuid_string_random()])
    local manifest_dir = GLib.build_filenamev([root, "manifest"])
    local tools_dir = GLib.build_filenamev([root, "tools"])
    GLib.mkdir_with_parents(manifest_dir, 493)
    GLib.mkdir_with_parents(tools_dir, 493)
    GLib.file_set_contents(GLib.build_filenamev([tools_dir, "ooblerg.nut"]), "", -1)
    GLib.file_set_contents(GLib.build_filenamev([manifest_dir, "packages.json"]), sqgi.json.stringify({
        target = "x86_64-w64-mingw32",
        prefix = "/mingw64",
        packages = [
            { name = "alpha", kind = "meta", version = "1", description = "Alpha package" },
            { name = "beta", kind = "meta", version = "1", description = "Beta package" },
        ],
    }, 2), -1)

    local builder = Builder.RepositoryBuilder()
    local repo_dir = GLib.build_filenamev([root, "out", "repo"])
    local index_path = GLib.build_filenamev([repo_dir, "v1", "index.json"])
    builder.rebuild({
        root = root,
        artifact_dir = GLib.build_filenamev([root, "out", "artifacts"]),
        repo_dir = repo_dir,
        repository = "test-repo",
        packages = [],
    })
    assert(package_count(index_path) == 2)

    builder.rebuild({
        root = root,
        artifact_dir = GLib.build_filenamev([root, "out", "artifacts"]),
        repo_dir = repo_dir,
        repository = "test-repo",
        packages = ["alpha"],
    })
    assert(package_count(index_path) == 2)
    assert(has_package(index_path, "alpha"))
    assert(has_package(index_path, "beta"))

    builder.rebuild({
        root = root,
        artifact_dir = GLib.build_filenamev([root, "out", "artifacts"]),
        repo_dir = repo_dir,
        repository = "test-repo",
        packages = ["alpha"],
        only = true,
    })
    assert(package_count(index_path) == 1)
    assert(has_package(index_path, "alpha"))
    assert(!has_package(index_path, "beta"))
}

test_unsafe_paths()
test_content_types()
test_builder_normalizes_paths()
test_builder_rejects_unsafe_tar_members()
test_native_sdk_dependency_closure()
test_partial_repo_index_preserves_existing_entries()

return true
