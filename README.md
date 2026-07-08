# Ooblerg

**Ooblerg is a Windows package manager and MinGW-w64 sysroot for building native desktop apps without hand-stitching a GTK/GNOME-adjacent Windows toolchain.**

It gives you a curated `x86_64-w64-mingw32` `/mingw64` environment with native Windows build tools, GTK 4, GObject Introspection, Vala, SQGI, GStreamer, GDAL, SDL, and their supporting libraries.

- **Website:** <https://ooblerg.xyz>
- **Windows installer:** <https://ooblerg.xyz/downloads/OoblergSetup.exe>
- **Repository index:** <https://ooblerg.xyz/v1/index.json>
- **Target:** `x86_64-w64-mingw32`
- **Prefix:** `/mingw64`
- **Primary host for building packages:** Ubuntu 24.04 (`noble`)

## What this repository contains

Ooblerg is three related pieces that share one package format and one target sysroot.

| Piece | Path | Purpose |
| --- | --- | --- |
| Package manager app | `app/` | GTK 4/SQGI desktop app for browsing a repository, installing/removing packages, repairing installs, and managing the local sysroot. |
| Package builder | `tools/ooblerg.nut`, `manifest/`, `ports/` | Fetches Ubuntu-pinned sources, cross-builds them with MinGW-w64, stages installs, and emits `.tar.gz` package artifacts plus metadata. |
| Repository server | `server/` | Generates and serves repository metadata, package manifests, checksums, and package tarballs. |
| Documentation | `docs/` | Architecture notes and package-set planning/status. |

The package manager is for Windows users. The builder is for maintainers producing the packages. The server is for publishing the artifacts in a format the app can consume.

## For Windows users

1. Download and run the installer from <https://ooblerg.xyz/downloads/OoblergSetup.exe>.
2. Launch **Ooblerg Package Manager**.
3. Refresh the repository index from the default source.
4. Install packages such as `native-sdk`, `gcc`, `gtk4`, `vala`, `sqgi`, `gstreamer`, `gdal`, or SDL packages.

The default Windows sysroot is:

```text
%LOCALAPPDATA%\Ooblerg\sysroot
```

The package manager can add the sysroot binary directory to the current user's `PATH`:

```text
%LOCALAPPDATA%\Ooblerg\sysroot\mingw64\bin
```

After installing build tools and libraries, you can use the sysroot from `cmd`, PowerShell, VS Code, or other Windows-native tooling.

## What the app does

The GTK package manager app can:

- fetch an Ooblerg repository index from HTTP or a local file URI;
- show available and installed packages with search and filters;
- plan installs and removals with dependency closure;
- track manually requested packages separately from automatic dependencies;
- download artifacts into a local cache;
- verify SHA-256 hashes before extraction;
- reject unsafe archive paths;
- detect file conflicts before installation;
- track installed package metadata under the sysroot;
- remove files owned by packages without deleting shared or non-empty directories;
- add or remove the sysroot `mingw64/bin` directory from the current user's Windows `PATH`.

## Package set

Ooblerg is aimed at native Windows app experiments that want the GNOME-adjacent stack and practical build tools in one sysroot.

The current package work includes:

- **toolchain and build tools:** MinGW-w64 runtime seed, `gcc`, `gdb`, `binutils`, `pkgconf`, `cmake`, `ninja`, `make`, `python`, `meson`, `git`;
- **GTK/GObject stack:** `glib`, `gobject-introspection` metadata, `glib-introspection`, `gtk4`, `libgee`, `vala`, Cairo, Pango, HarfBuzz, FreeType, Fontconfig, GdkPixbuf, Graphene, libepoxy;
- **networking and TLS:** `openssl`, `curl`, `libsoup3`, `glib-networking`, `ca-certificates`;
- **media and games:** GStreamer core plus curated base/good/bad/ugly plugin sets, SDL2 family packages, OpenAL Soft, GLFW, codecs and image libraries;
- **data, math, and GIS:** SQLite, libxml2, GMP, MPFR, MPC, ISL, Eigen, OpenBLAS, FFTW, GSL, PROJ, GEOS, GDAL.

`mingw-w64-runtime` is only the runtime seed: headers, CRT objects, import libraries, and runtime DLLs repackaged from the Ubuntu MinGW cross toolchain. The Windows-runnable compiler is the separate `gcc` package, and `native-sdk` is the convenience meta package that pulls the normal Windows-native build tools together.

See [`docs/top-50-mingw64-packages.md`](docs/top-50-mingw64-packages.md) for the headline package queue and status.

## Repository API

The hosted repository starts at:

```text
https://ooblerg.xyz/v1/index.json
```

The repository layout is static-file friendly:

```text
repo/
  v1/
    index.json
    index.json.sha256
    packages/
      <name>/
        <name>-<version>-x86_64-w64-mingw32.pkg.json
        <name>-<version>-x86_64-w64-mingw32.tar.gz
```

`index.json` is the compact catalogue. Per-package `.pkg.json` files contain detailed metadata, dependency information, artifact checksums, file lists, and build provenance. Tarballs are the install payload.

## Building packages

Ooblerg package builds currently assume:

- Ubuntu 24.04 (`noble`) with updates/security enabled;
- `x86_64-w64-mingw32` cross tools installed;
- the Ubuntu/MSVCRT MinGW runtime matching Ubuntu's MinGW packages;
- host `g-ir-scanner` and `g-ir-compiler` for GIR/typelib generation;
- a Windows executable wrapper, usually Wine, for packages that need GObject Introspection during cross-builds;
- Ubuntu source packages as the preferred source of versions and downstream patches.

Enable Ubuntu source repositories before fetching Ubuntu sources:

```sh
sudo sed -i 's/^# deb-src/deb-src/' /etc/apt/sources.list
sudo apt update
```

On Ubuntu systems using `.sources` files, enable `Types: deb deb-src` in the relevant `noble`, `noble-updates`, and `noble-security` entries instead.

Then run the builder from the repository root:

```sh
sqgi tools/ooblerg.nut doctor
sqgi tools/ooblerg.nut versions
sqgi tools/ooblerg.nut seed-runtime
sqgi tools/ooblerg.nut fetch gtk4
sqgi tools/ooblerg.nut build gtk4
```

Builder output goes under `out/`:

```text
out/sources      downloaded/extracted Ubuntu source packages
out/build        build directories
out/stage        per-package staged installs
out/artifacts    generated .tar.gz packages
out/sysroot      accumulated build sysroot used by later packages
out/repo         generated repository metadata and publishable package tree
```

To rebuild a clean Windows-style sysroot from existing artifacts:

```sh
sqgi tools/ooblerg.nut rebuild-sysroot --no-build-shims \
  vala gtk4 libgee libsoup3 gdal \
  gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly
```

To generate repository metadata from artifacts:

```sh
sqgi tools/ooblerg.nut repo-index
sqgi tools/ooblerg.nut repo-index --artifact-dir out/artifacts --repo-dir out/repo native-sdk gtk4
```

## GObject Introspection during cross-builds

GObject Introspection is the awkward part of this build. The host `g-ir-scanner` compiles a temporary Windows program and then has to run it to dump GType metadata. On an x86_64 Linux host, set `OOBLERG_EXE_WRAPPER` to Wine or another wrapper that can run those Windows binaries:

```sh
export OOBLERG_EXE_WRAPPER=/path/to/wine64-or-wrapper
sqgi tools/ooblerg.nut build glib-introspection
```

On non-x86_64 hosts, one working path is an amd64 VM with Wine. `tools/ooblerg-remote-wine` syncs the dump executable plus DLLs into the VM, runs it with Wine, and syncs the generated GIR inputs/outputs back:

```sh
export OOBLERG_EXE_WRAPPER=$PWD/tools/ooblerg-remote-wine
export OOBLERG_REMOTE=user@127.0.0.1
export OOBLERG_REMOTE_SSH_PORT=2222
export OOBLERG_REMOTE_SSH_KEY=$PWD/out/vm/id_ed25519
export OOBLERG_REMOTE_WINE=/usr/lib/wine/wine64
```

## Developing the package manager app

Run the non-GUI tests from the repository root:

```sh
sqgi app/main.nut --self-test
```

Launch the app from the repository root:

```sh
sqgi app/main.nut
```

Launch without refreshing the repository on startup:

```sh
sqgi app/main.nut --no-auto-refresh
```

Check that a repository source can be loaded and then exit:

```sh
sqgi app/main.nut --check-source --source-uri=https://ooblerg.xyz/v1/index.json
```

Run the local end-to-end GUI smoke harness:

```sh
./tools/test-app-gui
```

The harness rebuilds repository metadata, starts a local server, launches the GTK app, refreshes the package list, and exercises an install path.

## Building the Windows installer

Build the distributable Windows installer from `app/`:

```sh
cd app
sqgipkg --target win-nsis
```

The installer is written to:

```text
app/dist-windows-x86_64/Ooblerg Package Manager-Setup.exe
```

The expanded app bundle is written beside it:

```text
app/dist-windows-x86_64/Ooblerg Package Manager/
```

After changing app code, assets, native helper code, bundled certificates, or `app/sqgipkg.json`, rebuild the installer before testing the installed Windows app.

## Repository layout

```text
app/                      GTK/SQGI package manager app
app/native/               Windows GI helper for user PATH updates
app/src/pkg/              package models, status database, solver, transactions
app/src/repo/             repository client and artifact cache
app/src/sysroot/          sysroot paths, extraction, conflict checks, installs/removals
app/src/system/           Windows integration wrappers
app/src/ui/               GTK UI
app/test/                 package-manager self-tests

docs/                     architecture and package-set notes
manifest/packages.json    package recipes, dependencies, source names, metadata
ports/                    local patches and custom build helpers
server/                   SQGI/libsoup repository server
support/gir/              support data for GIR/typelib work
tools/                    builder, introspection wrappers, Wine helpers, smoke harness
```

## Security and trust model

Current package safety is deliberately simple:

- artifact hashes are checked with SHA-256;
- package manifests and index metadata carry checksums;
- archive members with absolute paths, `..`, Windows drive prefixes, or backslashes are rejected;
- packages do not run arbitrary install scripts;
- local install metadata is written under the single user-data sysroot.

Repository signing is planned but not implemented yet. Treat the current hosted repository as suitable for development and experimentation, not as a hardened production supply chain.

## Known sharp edges

- The supported build target is currently `x86_64-w64-mingw32` with `/mingw64` as the prefix.
- Recipes are pinned around Ubuntu 24.04-era sources and downstream Ubuntu patches.
- Cross-building introspection-enabled packages requires a working Windows executable wrapper.
- `webkitgtk` and the `ports/webkitgtkwin` patch series are experimental and are not part of the low-friction package path.
- The package manager owns one user-data sysroot; it is not a system-wide Windows installer.

## Release checklist

Before cutting a Windows app build:

1. Run `sqgi app/main.nut --self-test`.
2. Run `./tools/test-app-gui` when a GTK-capable host is available.
3. Build from `app/` with `sqgipkg --target win-nsis`.
4. Confirm the installer exists at `app/dist-windows-x86_64/Ooblerg Package Manager-Setup.exe`.
5. Install on Windows and confirm the app launches, refreshes the repository, installs/removes a small package, and updates the local status database.
6. Publish the installer and update the website checksum.

## License

The Ooblerg server and app code are MIT licensed. Package artifacts should preserve the upstream and Ubuntu license metadata for the components they contain.
