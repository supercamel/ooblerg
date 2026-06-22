# Ooblerg Package Manager

This directory contains the GTK 4 desktop app used to browse an Ooblerg
repository and install packages into the user's Windows-style sysroot. The app
is written in Squirrel, runs through SQGI, and uses GObject Introspection for
GTK, GLib, Gio, and libsoup.

The app is separate from the repository builder in `tools/ooblerg.nut`.
`tools/ooblerg.nut` builds package artifacts; this app installs those artifacts
on a user machine.

## What It Does

- Loads an Ooblerg repository index from an HTTP or file URI.
- Shows available and installed packages with search and filters.
- Plans installs/removals with dependency closure and orphan cleanup.
- Downloads package artifacts into a local cache and verifies SHA-256 hashes.
- Extracts packages into a fixed sysroot.
- Tracks installed package metadata under the sysroot.
- On Windows, can add/remove the sysroot `mingw64/bin` directory from the user
  `PATH`.

The default repository source is:

```sh
https://ooblerg.xyz/v1/index.json
```

The Windows sysroot lives at:

```text
%LOCALAPPDATA%/Ooblerg/sysroot
```

On Linux development hosts, the same code uses GLib's user data directory.

## Layout

```text
app/main.nut                  command-line entry point
app/sqgipkg.json              SQGI packaging manifest
app/assets/icons/             app icons and hicolor theme files
app/src/config.nut            app id, default source URI, user data paths
app/src/pkg/manifest.nut      repository index/package helpers
app/src/pkg/solver.nut        dependency planning
app/src/pkg/status.nut        local install database
app/src/pkg/transaction.nut   install/remove transaction facade
app/src/repo/client.nut       source URI, index fetch, package manifest fetch
app/src/repo/cache.nut        artifact cache and checksum verification
app/src/sysroot/install.nut   archive validation, conflicts, filesystem writes
app/src/sysroot/paths.nut     sysroot path helpers
app/src/system/path.nut       Windows user PATH integration
app/src/ui/window.nut         GTK application and smoke test driver
app/test/package_tests.nut    model, solver, and fixture transaction tests
app/native/                   Windows native GI helper module
```

## Development Commands

Run the non-GUI self-tests from the repository root:

```sh
sqgi app/main.nut --self-test
```

Launch the app from the repository root:

```sh
sqgi app/main.nut
```

The app refreshes the configured source automatically after launch. To skip
that refresh during debugging:

```sh
sqgi app/main.nut --no-auto-refresh
```

Run the local end-to-end GUI smoke harness:

```sh
./tools/test-app-gui
```

The harness rebuilds repository metadata, starts a local server, launches the
GTK app, refreshes the package list, and exercises a package install path.

## Building The Windows Installer

Build the distributable Windows installer from this directory:

```sh
cd app
sqgipkg --target win-nsis
```

This is the app packaging command. Do not substitute the repository package
builder here; `tools/ooblerg.nut` is for building sysroot packages, not the GUI
installer.

Relative to the repository root, the installer is written to:

```text
app/dist-windows-x86_64/Ooblerg Package Manager-Setup.exe
```

Relative to the repository root, the expanded Windows app bundle is written
beside it at:

```text
app/dist-windows-x86_64/Ooblerg Package Manager/
```

After changing app code, assets, native helper code, or `app/sqgipkg.json`,
rebuild with `sqgipkg --target win-nsis` before testing the installed Windows
app.

## Packaging Notes

`app/sqgipkg.json` controls the packaged runtime. It pins the SQGI source,
builds the Windows SQGI executable, stages the Squirrel app resources, includes
the native Windows helper module, copies MSYS2 runtime dependencies, and
generates the NSIS installer.

HTTPS repository downloads use libsoup through Gio. Keep `libsoup3`,
`glib-networking`, `ca-certificates`, and `openssl` in the Windows package
list so the NSIS payload includes the TLS modules, certificate bundle, and SSL
runtime DLLs needed on a clean Windows machine. At startup the app points
`SSL_CERT_FILE`, `CURL_CA_BUNDLE`, and `OPENSSL_CONF` at bundled files when it
is running from an SQGI app directory.

GTK window icons are resolved by name in GTK 4. Keep the hicolor icon files in
the package manifest so `dev.ooblerg.pkgmanager` can resolve inside the
installed app:

```text
share/icons/hicolor/index.theme
share/icons/hicolor/1024x1024/apps/dev.ooblerg.pkgmanager.png
share/icons/hicolor/1024x1024/apps/ooblerg-icon.png
```

The NSIS installer icon and shortcut icon use:

```text
assets/icons/ooblerg-icon.ico
```

The packaged launcher sets runtime environment variables such as
`SQGI_APPDIR`, `SQGI_APP_RESOURCES`, `XDG_DATA_DIRS`, `GI_TYPELIB_PATH`,
`GSETTINGS_SCHEMA_DIR`, `GDK_PIXBUF_MODULEDIR`, and the GTK/GStreamer module
paths. If a packaged Windows app can import GLib but fails on GTK, check the
expanded bundle first:

```sh
find "dist-windows-x86_64/Ooblerg Package Manager/lib/girepository-1.0" -maxdepth 1 -type f | sort
find "dist-windows-x86_64/Ooblerg Package Manager/bin" -maxdepth 1 -type f | sort
```

Missing GTK transitive typelibs or DLLs there usually mean the packaging inputs
need to include another runtime package or explicit typelib.

## Native Helper

`app/native/` builds `OoblergWin-1.0.typelib` and
`libooblerg-win-1.0.dll`. The app uses this helper on Windows for registry
backed user `PATH` updates. Its build is invoked by `sqgipkg` through the
`native_projects` section in `app/sqgipkg.json`.

## Release Checklist

1. Run `sqgi app/main.nut --self-test`.
2. Run `./tools/test-app-gui` when a GTK-capable host is available.
3. Build from `app/` with `sqgipkg --target win-nsis`.
4. Confirm the installer exists at
   `dist-windows-x86_64/Ooblerg Package Manager-Setup.exe`.
5. On Windows, install fresh and confirm:
   - the app launches,
   - `import("Gtk", "4.0")` works through packaged SQGI,
   - the window/taskbar icon uses the Ooblerg icon,
   - installing and removing a small package updates the sysroot and status
     database.
