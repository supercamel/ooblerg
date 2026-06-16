#!/usr/bin/env python3
import argparse
import hashlib
import json
import lzma
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from urllib.parse import quote
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "manifest" / "packages.json"
OUT = ROOT / "out"
UBUNTU_SOURCE_BASE = "http://ports.ubuntu.com/ubuntu-ports"
UBUNTU_SOURCE_FILE_BASE = "https://launchpad.net/ubuntu/+archive/primary/+sourcefiles"
UBUNTU_SUITES = ["noble", "noble-updates", "noble-security"]
UBUNTU_COMPONENTS = ["main", "universe", "restricted", "multiverse"]


def run(argv, cwd=None, env=None, check=True):
    print("+", " ".join(str(a) for a in argv), flush=True)
    return subprocess.run(argv, cwd=cwd, env=env, check=check)


def output(argv, cwd=None, env=None, check=True):
    return subprocess.check_output(argv, cwd=cwd, env=env, text=True).strip()


def load_manifest():
    data = json.loads(MANIFEST.read_text())
    packages = {pkg["name"]: pkg for pkg in data["packages"]}
    return data, packages


def package_or_die(packages, name):
    try:
        return packages[name]
    except KeyError:
        raise SystemExit(f"unknown package: {name}")


def mkdirs():
    for path in [
        OUT / "sources",
        OUT / "source-index",
        OUT / "source-cache",
        OUT / "build",
        OUT / "stage",
        OUT / "artifacts",
        OUT / "sysroot",
        OUT / "logs",
    ]:
        path.mkdir(parents=True, exist_ok=True)


def have_tool(name):
    return shutil.which(name) is not None


def detect_build_triplet():
    try:
        return output(["dpkg-architecture", "-qDEB_BUILD_GNU_TYPE"])
    except Exception:
        return output(["gcc", "-dumpmachine"])


def apt_candidate(binary_pkg):
    try:
        text = output(["apt-cache", "policy", binary_pkg])
    except subprocess.CalledProcessError:
        return None
    match = re.search(r"^\s*Candidate:\s+(\S+)", text, re.MULTILINE)
    return match.group(1) if match else None


def tar_version(version):
    return version.replace(":", "_").replace("~", ".").replace("+", "+")


def package_version(pkg):
    version_pkg = pkg.get("version_package")
    if not version_pkg:
        return pkg.get("version", "unknown")
    return apt_candidate(version_pkg) or pkg.get("version", "unknown")


def env_for_build(manifest, destdir=None):
    target = manifest["target"]
    prefix = manifest["prefix"]
    sysroot = OUT / "sysroot"
    prefix_root = sysroot / prefix.lstrip("/")
    include_arg = f"-I{prefix_root / 'include'}"
    lib_arg = f"-L{prefix_root / 'lib'}"
    env = os.environ.copy()
    host_tools = OUT / "host-tools" / "usr"
    host_bin = host_tools / "bin"
    host_lib = host_tools / "lib" / output(["dpkg-architecture", "-qDEB_HOST_MULTIARCH"])
    path_parts = [
        str(host_bin),
        str(sysroot / prefix.lstrip("/") / "bin"),
        env.get("PATH", ""),
    ]
    pkg_dirs = [
        sysroot / prefix.lstrip("/") / "lib" / "pkgconfig",
        sysroot / prefix.lstrip("/") / "share" / "pkgconfig",
    ]
    gir_path = sysroot / prefix.lstrip("/") / "share" / "gir-1.0"
    typelib_path = sysroot / prefix.lstrip("/") / "lib" / "girepository-1.0"
    env.update(
        {
            "CHOST": target,
            "CC": f"{target}-gcc",
            "CXX": f"{target}-g++",
            "AR": f"{target}-ar",
            "RANLIB": f"{target}-ranlib",
            "STRIP": f"{target}-strip",
            "WINDRES": f"{target}-windres",
            "PKG_CONFIG": "pkg-config",
            "PKG_CONFIG_LIBDIR": os.pathsep.join(str(p) for p in pkg_dirs),
            "PKG_CONFIG_SYSROOT_DIR": str(sysroot),
            "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS": "1",
            "PKG_CONFIG_ALLOW_SYSTEM_LIBS": "1",
            "GI_GIR_PATH": os.pathsep.join(
                p for p in [str(gir_path), env.get("GI_GIR_PATH", "")] if p
            ),
            "GI_TYPELIB_PATH": os.pathsep.join(
                p for p in [str(typelib_path), env.get("GI_TYPELIB_PATH", "")] if p
            ),
            "CPPFLAGS": f"{include_arg} {env.get('CPPFLAGS', '')}".strip(),
            "CFLAGS": f"{include_arg} {env.get('CFLAGS', '')}".strip(),
            "CXXFLAGS": f"{include_arg} {env.get('CXXFLAGS', '')}".strip(),
            "LDFLAGS": f"{lib_arg} {env.get('LDFLAGS', '')}".strip(),
            "PATH": os.pathsep.join(path_parts),
        }
    )
    if host_lib.exists():
        env["LD_LIBRARY_PATH"] = os.pathsep.join(
            p for p in [str(host_lib), env.get("LD_LIBRARY_PATH", "")] if p
        )
    wrapper = env.get("OOBLERG_EXE_WRAPPER")
    if wrapper:
        env["GI_CROSS_LAUNCHER"] = wrapper
    if destdir:
        env["DESTDIR"] = str(destdir)
    return env


def substitute(items, manifest, destdir=None):
    build_triplet = detect_build_triplet()
    jobs = str(os.cpu_count() or 2)
    values = {
        "ROOT": str(ROOT),
        "BUILD_TRIPLET": build_triplet,
        "JOBS": jobs,
        "DESTDIR": str(destdir) if destdir else "",
        "PREFIX": manifest["prefix"],
        "TARGET": manifest["target"],
    }
    result = []
    for item in items:
        for key, value in values.items():
            item = item.replace("${" + key + "}", value)
        result.append(item)
    return result


def meson_cross_file(manifest):
    mkdirs()
    target = manifest["target"]
    prefix = manifest["prefix"]
    sysroot = OUT / "sysroot"
    path = OUT / "meson-cross.ini"
    scanner = ROOT / "tools" / "ooblerg-g-ir-scanner"
    compiler = shutil.which("g-ir-compiler") or "/usr/bin/g-ir-compiler"
    generate = shutil.which("g-ir-generate") or "/usr/bin/g-ir-generate"
    exe_wrapper = os.environ.get("OOBLERG_EXE_WRAPPER")
    exe_wrapper_line = ""
    if exe_wrapper:
        wrapper_args = shlex.split(exe_wrapper)
        exe_wrapper_line = f"exe_wrapper = {wrapper_args!r}\n"
    path.write_text(
        f"""[binaries]
c = '{target}-gcc'
cpp = '{target}-g++'
ar = '{target}-ar'
strip = '{target}-strip'
windres = '{target}-windres'
pkgconfig = 'pkg-config'
g-ir-scanner = '{scanner}'
g-ir-compiler = '{compiler}'
g-ir-generate = '{generate}'
{exe_wrapper_line}

[properties]
sys_root = '{sysroot}'
pkg_config_libdir = ['{sysroot / prefix.lstrip("/") / "lib" / "pkgconfig"}', '{sysroot / prefix.lstrip("/") / "share" / "pkgconfig"}']

[built-in options]
c_args = ['-I{sysroot / prefix.lstrip("/") / "include"}']
cpp_args = ['-I{sysroot / prefix.lstrip("/") / "include"}']
c_link_args = ['-L{sysroot / prefix.lstrip("/") / "lib"}']
cpp_link_args = ['-L{sysroot / prefix.lstrip("/") / "lib"}']

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
"""
    )
    return path


def cmake_toolchain_file(manifest):
    mkdirs()
    target = manifest["target"]
    prefix = manifest["prefix"]
    sysroot = OUT / "sysroot"
    path = OUT / "cmake-mingw-toolchain.cmake"
    path.write_text(
        f"""set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER {target}-gcc)
set(CMAKE_CXX_COMPILER {target}-g++)
set(CMAKE_RC_COMPILER {target}-windres)
set(CMAKE_FIND_ROOT_PATH {sysroot} {sysroot / prefix.lstrip("/")})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
"""
    )
    return path


def source_dir(pkg):
    base = OUT / "sources" / pkg.get("source_from", pkg["name"])
    if not base.exists():
        return None
    candidates = [p for p in base.iterdir() if p.is_dir() and (p / "debian").exists()]
    if candidates:
        return sorted(candidates)[-1]
    dirs = [p for p in base.iterdir() if p.is_dir()]
    return sorted(dirs)[-1] if dirs else None


def parse_deb822(text):
    paragraphs = []
    current = {}
    key = None
    for line in text.splitlines():
        if not line:
            if current:
                paragraphs.append(current)
                current = {}
                key = None
            continue
        if line[0].isspace() and key:
            current[key] += "\n" + line
            continue
        key, value = line.split(":", 1)
        current[key] = value.strip()
    if current:
        paragraphs.append(current)
    return paragraphs


def download(url, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        return
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    print(f"+ download {url}", flush=True)
    if have_tool("curl"):
        cmd = [
            "curl",
            "-fL",
            "--retry",
            "5",
            "--retry-delay",
            "2",
            "--connect-timeout",
            "20",
            "--max-time",
            "900",
            "-C",
            "-",
            "-o",
            str(tmp),
            url,
        ]
        try:
            run(cmd)
        except subprocess.CalledProcessError:
            tmp.unlink(missing_ok=True)
            run([arg for arg in cmd if arg not in ["-C", "-"]])
    else:
        with urllib.request.urlopen(url, timeout=120) as response, tmp.open("wb") as fh:
            shutil.copyfileobj(response, fh)
    tmp.replace(dest)


def sources_index_path(suite, component):
    return OUT / "source-index" / suite / component / "Sources.xz"


def load_sources_index(suite, component):
    path = sources_index_path(suite, component)
    url = f"{UBUNTU_SOURCE_BASE}/dists/{suite}/{component}/source/Sources.xz"
    download(url, path)
    return parse_deb822(lzma.decompress(path.read_bytes()).decode("utf-8", "replace"))


def dpkg_version_gt(left, right):
    return subprocess.run(["dpkg", "--compare-versions", left, "gt", right]).returncode == 0


def find_source_record(source_name):
    best = None
    best_suite_index = -1
    for suite_index, suite in enumerate(UBUNTU_SUITES):
        for component in UBUNTU_COMPONENTS:
            for record in load_sources_index(suite, component):
                if record.get("Package") != source_name:
                    continue
                if not best:
                    best = (suite, component, record)
                    best_suite_index = suite_index
                    continue
                version = record.get("Version", "0")
                best_version = best[2].get("Version", "0")
                if dpkg_version_gt(version, best_version) or (
                    version == best_version and suite_index > best_suite_index
                ):
                    best = (suite, component, record)
                    best_suite_index = suite_index
    return best


def file_hash(path, algorithm):
    h = hashlib.new(algorithm)
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_checksums(record):
    checksums = {}
    for field, algorithm in [("Checksums-Sha256", "sha256"), ("Checksums-Sha1", "sha1"), ("Files", "md5")]:
        for line in record.get(field, "").splitlines():
            parts = line.split()
            if len(parts) != 3:
                continue
            checksum, size, filename = parts
            checksums.setdefault(filename, {})[algorithm] = checksum
            checksums[filename]["size"] = int(size)
    return checksums


def fetch_source_from_ubuntu(pkg):
    source = pkg["source"]
    found = find_source_record(source)
    if not found:
        raise SystemExit(f"could not find Ubuntu source package {source!r} in noble source indices")
    _suite, _component, record = found
    dest = OUT / "sources" / pkg["name"]
    cache = OUT / "source-cache" / source / record["Version"].replace(":", "_")
    dest.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    checksums = parse_checksums(record)
    for filename, sums in checksums.items():
        source_part = quote(source, safe="")
        version_part = quote(record["Version"], safe="")
        filename_part = quote(filename, safe="")
        url = f"{UBUNTU_SOURCE_FILE_BASE}/{source_part}/{version_part}/{filename_part}"
        path = cache / filename
        download(url, path)
        if path.stat().st_size != sums["size"]:
            path.unlink(missing_ok=True)
            raise SystemExit(f"size mismatch for {filename}")
        if "sha256" in sums and file_hash(path, "sha256") != sums["sha256"]:
            path.unlink(missing_ok=True)
            raise SystemExit(f"sha256 mismatch for {filename}")
    dsc_files = [cache / name for name in checksums if name.endswith(".dsc")]
    if not dsc_files:
        raise SystemExit(f"source package {source!r} has no .dsc in Sources metadata")
    run(["dpkg-source", "-x", str(dsc_files[0])], cwd=dest)


def command_doctor(_args):
    data, _packages = load_manifest()
    required = [
        "apt-cache",
        "apt-get",
        "dpkg-source",
        "tar",
        "pkg-config",
        "make",
        "meson",
        "ninja",
        "cmake",
        "g-ir-scanner",
        "g-ir-compiler",
        f"{data['target']}-gcc",
        f"{data['target']}-g++",
        f"{data['target']}-ar",
        f"{data['target']}-ranlib",
        f"{data['target']}-strip",
        f"{data['target']}-windres",
        f"{data['target']}-objdump",
    ]
    missing = [tool for tool in required if not have_tool(tool)]
    print(f"root: {ROOT}")
    print(f"target: {data['target']}")
    print(f"prefix: {data['prefix']}")
    print(f"build triplet: {detect_build_triplet()}")
    if missing:
        print("missing tools:")
        for tool in missing:
            print(f"  - {tool}")
        return 1
    print("all required host tools are present")
    wrapper = os.environ.get("OOBLERG_EXE_WRAPPER")
    if wrapper:
        print(f"introspection exe wrapper: {wrapper}")
    else:
        print("introspection exe wrapper: not set (set OOBLERG_EXE_WRAPPER for GIR builds)")
    return 0


def command_versions(_args):
    _data, packages = load_manifest()
    for name, pkg in packages.items():
        version = package_version(pkg)
        marker = "" if version != "unknown" else " (no apt candidate found)"
        print(f"{name:20} {version}{marker}")
    return 0


def dependency_closure(packages, roots):
    seen = set()
    ordered = []

    def visit(name):
        if name in seen:
            return
        pkg = package_or_die(packages, name)
        seen.add(name)
        for dep in pkg.get("deps", []):
            visit(dep)
        ordered.append(name)

    for root in roots:
        visit(root)
    return ordered


def command_plan(args):
    _data, packages = load_manifest()
    for name in dependency_closure(packages, args.packages):
        print(name)
    return 0


def command_fetch(args):
    _data, packages = load_manifest()
    mkdirs()
    names = dependency_closure(packages, args.packages) if args.deps else args.packages
    for name in names:
        pkg = package_or_die(packages, name)
        if pkg.get("kind") == "runtime-seed":
            continue
        source = pkg.get("source")
        if not source:
            raise SystemExit(f"{name} has no source package")
        source_from = pkg.get("source_from")
        if source_from and (OUT / "sources" / source_from).exists():
            print(f"{name}: using source tree from {source_from}")
            continue
        dest = OUT / "sources" / name
        dest.mkdir(parents=True, exist_ok=True)
        if source_dir(pkg):
            print(f"{name}: source already present")
            continue
        try:
            run(["apt-get", "source", source], cwd=dest)
        except subprocess.CalledProcessError as exc:
            print(f"apt-get source failed for {source!r}; falling back to Ubuntu Sources indices")
            fetch_source_from_ubuntu(pkg)
    return 0


def install_artifact(path, build_shims=True):
    sysroot = OUT / "sysroot"
    sysroot.mkdir(parents=True, exist_ok=True)
    remove_build_tool_shims()
    with tarfile.open(path, "r:gz") as tar:
        tar.extractall(sysroot, filter="fully_trusted")
    if build_shims:
        install_build_tool_shims()


def remove_build_tool_shims():
    data, _packages = load_manifest()
    bindir = OUT / "sysroot" / data["prefix"].lstrip("/") / "bin"
    for tool in BUILD_TOOL_SHIMS:
        target_path = bindir / tool
        if target_path.is_symlink():
            target_path.unlink()


BUILD_TOOL_SHIMS = [
    "glib-compile-resources",
    "glib-compile-schemas",
    "glib-genmarshal",
    "glib-mkenums",
    "gdbus-codegen",
]


def install_build_tool_shims():
    """Add local-only host tool shims needed while cross-building dependents."""
    data, _packages = load_manifest()
    bindir = OUT / "sysroot" / data["prefix"].lstrip("/") / "bin"
    if not bindir.exists():
        return
    for tool in BUILD_TOOL_SHIMS:
        target_path = bindir / tool
        if target_path.exists():
            continue
        if not (bindir / f"{tool}.exe").exists():
            continue
        host_path = shutil.which(tool)
        if host_path:
            target_path.symlink_to(host_path)


def artifact_path(pkg, version):
    return OUT / "artifacts" / f"{pkg['name']}-{tar_version(version)}-x86_64-w64-mingw32.tar.gz"


def package_stage(pkg, version):
    stage = OUT / "stage" / pkg["name"]
    artifact = artifact_path(pkg, version)
    artifact.parent.mkdir(parents=True, exist_ok=True)
    if artifact.exists():
        artifact.unlink()
    with tarfile.open(artifact, "w:gz") as tar:
        for child in sorted(stage.iterdir()):
            tar.add(child, arcname=child.name)
    install_artifact(artifact)
    print(f"wrote {artifact}")


def active_gcc_runtime_dir(target):
    libgcc = output([f"{target}-gcc", "-print-libgcc-file-name"])
    return Path(libgcc).resolve().parent


def command_seed_runtime(_args):
    data, packages = load_manifest()
    mkdirs()
    pkg = package_or_die(packages, "mingw-w64-runtime")
    version = package_version(pkg)
    stage = OUT / "stage" / pkg["name"]
    if stage.exists():
        shutil.rmtree(stage)
    prefix = stage / data["prefix"].lstrip("/")
    prefix.mkdir(parents=True, exist_ok=True)
    (prefix / "bin").mkdir(parents=True, exist_ok=True)

    src_root = Path("/usr") / data["target"]
    if not src_root.exists():
        raise SystemExit(f"{src_root} does not exist; install mingw-w64-x86-64-dev")
    shutil.copytree(src_root / "include", prefix / "include", symlinks=True)
    shutil.copytree(src_root / "lib", prefix / "lib", symlinks=True)

    gcc_runtime = active_gcc_runtime_dir(data["target"])
    gcc_dest = prefix / "lib" / "gcc" / data["target"] / gcc_runtime.name
    shutil.copytree(gcc_runtime, gcc_dest, symlinks=True)
    for dll in gcc_runtime.glob("*.dll"):
        shutil.copy2(dll, prefix / "bin" / dll.name)

    package_stage(pkg, version)
    return 0


def ensure_deps_built(packages, pkg):
    missing = []
    for dep in pkg.get("deps", []):
        dep_pkg = package_or_die(packages, dep)
        version = package_version(dep_pkg)
        if not artifact_path(dep_pkg, version).exists():
            missing.append(dep)
    if missing:
        raise SystemExit(
            f"{pkg['name']} needs missing artifacts: {', '.join(missing)}. Build or seed dependencies first."
        )


def run_shell(command, cwd, env):
    print("+", command, flush=True)
    return subprocess.run(command, cwd=cwd, env=env, shell=True, check=True)


def run_recipe_commands(pkg, key, data, cwd, env, destdir=None):
    for command in substitute(pkg.get(key, []), data, destdir):
        run_shell(command, cwd=cwd, env=env)


def build_one(data, packages, name):
    pkg = package_or_die(packages, name)
    if pkg.get("kind") == "runtime-seed":
        return command_seed_runtime(None)
    ensure_deps_built(packages, pkg)
    system = pkg["build_system"]
    src = source_dir(pkg)
    if not src:
        if system == "custom":
            src = ROOT
        else:
            raise SystemExit(f"no source tree for {name}; run ./tools/ooblerg.py fetch {name}")
    if pkg.get("source_subdir"):
        src = src / pkg["source_subdir"]
    install_build_tool_shims()
    version = package_version(pkg)
    build = OUT / "build" / name
    stage = OUT / "stage" / name
    if build.exists():
        shutil.rmtree(build)
    if stage.exists():
        shutil.rmtree(stage)
    build.mkdir(parents=True)
    stage.mkdir(parents=True)
    env = env_for_build(data, stage)
    run_recipe_commands(pkg, "pre_configure", data, src, env, stage)

    if system == "meson":
        cross = meson_cross_file(data)
        cmd = [
            "meson",
            "setup",
            str(build),
            str(src),
            f"--cross-file={cross}",
            f"--prefix={data['prefix']}",
            "--libdir=lib",
            "--buildtype=release",
        ] + pkg.get("meson_options", [])
        run(cmd, env=env)
        run(["meson", "compile", "-C", str(build)], env=env)
        run(["meson", "install", "-C", str(build), f"--destdir={stage}"], env=env)
    elif system == "cmake":
        run_recipe_commands(pkg, "pre_build", data, src, env, stage)
        toolchain = cmake_toolchain_file(data)
        cmd = [
            "cmake",
            "-S",
            str(src),
            "-B",
            str(build),
            f"-DCMAKE_TOOLCHAIN_FILE={toolchain}",
            f"-DCMAKE_INSTALL_PREFIX={data['prefix']}",
            "-DCMAKE_BUILD_TYPE=Release",
        ] + pkg.get("cmake_options", [])
        run(cmd, env=env)
        run(["cmake", "--build", str(build), "--parallel", str(os.cpu_count() or 2)], env=env)
        run(["cmake", "--install", str(build), "--prefix", data["prefix"]], env={**env, "DESTDIR": str(stage)})
    elif system == "autotools":
        run(substitute(["./configure"] + pkg.get("configure", []), data, stage), cwd=src, env=env)
        run_recipe_commands(pkg, "pre_build", data, src, env, stage)
        run(substitute(pkg.get("make", ["make", "-j${JOBS}"]), data, stage), cwd=src, env=env)
        run(substitute(pkg.get("install", ["make", "DESTDIR=${DESTDIR}", "install"]), data, stage), cwd=src, env=env)
    elif system == "custom":
        for command in substitute(pkg.get("commands", []), data, stage):
            run_shell(command, cwd=src, env=env)
    else:
        raise SystemExit(f"unsupported build system for {name}: {system}")

    run_recipe_commands(pkg, "post_install", data, src, env, stage)
    package_stage(pkg, version)
    return 0


def command_build(args):
    data, packages = load_manifest()
    mkdirs()
    names = dependency_closure(packages, args.packages) if args.deps else args.packages
    for name in names:
        build_one(data, packages, name)
    return 0


def command_install(args):
    mkdirs()
    for artifact in args.artifacts:
        install_artifact(Path(artifact))
        print(f"installed {artifact}")
    return 0


def command_rebuild_sysroot(args):
    data, packages = load_manifest()
    mkdirs()
    sysroot = OUT / "sysroot"
    if sysroot.exists():
        shutil.rmtree(sysroot)
    sysroot.mkdir(parents=True, exist_ok=True)
    roots = args.packages or ["vala", "gtk4"]
    for name in dependency_closure(packages, roots):
        pkg = package_or_die(packages, name)
        artifact = artifact_path(pkg, package_version(pkg))
        if artifact.exists():
            install_artifact(artifact, build_shims=not args.no_build_shims)
            print(f"installed {artifact}")
    if args.no_build_shims:
        remove_build_tool_shims()
    return 0


def main():
    parser = argparse.ArgumentParser(description="Build Ubuntu-pinned MinGW GNOME package tarballs.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("doctor", help="check host tools")
    p.set_defaults(func=command_doctor)

    p = sub.add_parser("versions", help="show apt candidate versions used for pinning")
    p.set_defaults(func=command_versions)

    p = sub.add_parser("plan", help="print dependency build order")
    p.add_argument("packages", nargs="+")
    p.set_defaults(func=command_plan)

    p = sub.add_parser("fetch", help="fetch Ubuntu source packages")
    p.add_argument("--deps", action="store_true", help="also fetch dependency closure")
    p.add_argument("packages", nargs="+")
    p.set_defaults(func=command_fetch)

    p = sub.add_parser("seed-runtime", help="package Ubuntu's installed MinGW target runtime seed")
    p.set_defaults(func=command_seed_runtime)

    p = sub.add_parser("build", help="build and package one or more packages")
    p.add_argument("--deps", action="store_true", help="build dependency closure first")
    p.add_argument("packages", nargs="+")
    p.set_defaults(func=command_build)

    p = sub.add_parser("install", help="extract artifact tarballs into out/sysroot")
    p.add_argument("artifacts", nargs="+")
    p.set_defaults(func=command_install)

    p = sub.add_parser("rebuild-sysroot", help="recreate out/sysroot from currently built artifacts")
    p.add_argument("--no-build-shims", action="store_true", help="omit local host-tool shims from out/sysroot")
    p.add_argument("packages", nargs="*", help="root packages to include; defaults to vala gtk4")
    p.set_defaults(func=command_rebuild_sysroot)

    args = parser.parse_args()
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())
