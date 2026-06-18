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

test_unsafe_paths()
test_content_types()
test_builder_normalizes_paths()
test_builder_rejects_unsafe_tar_members()
test_native_sdk_dependency_closure()

return true
