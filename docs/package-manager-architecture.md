# Ooblerg Package Manager Architecture

This document sketches the first usable package-management system for the
Windows development sysroot produced by this repository. The goal is an
APT-like workflow without depending on Ubuntu packaging at install time:
Ooblerg builds `.tar.gz` artifacts, publishes package metadata to a repository
server, and a GTK4/SQGI client installs and removes packages into one
Windows sysroot under the user's AppData directory.

## Goals

- Let users add and remove packages through a GTK4/SQGI GUI.
- Resolve dependencies automatically before install or removal.
- Keep enough local state to know which files each package installed.
- Let a GUI source URI point at an Ooblerg repository server.
- Serve artifacts and metadata over HTTP using an SQGI/libsoup server app.
- Preserve the current artifact format as much as possible while adding package
  metadata alongside each tarball.
- Support generated packages like `native-sdk`, GTK4, GDAL, GStreamer plugins,
  typelibs, and future app-specific SDK bundles.

## Non-Goals For The First Cut

- No binary patch/delta updates.
- No multiple simultaneous repositories with complex pinning.
- No package scripts with arbitrary code execution.
- No system-wide Windows installer integration.
- No global package database outside the one AppData sysroot.
- No bundled Unix shell in the default package set; build tools should run as
  Windows-native executables and integrate with the Windows PATH.

## Repository Layout

The published repository should be static-file friendly, even though we will
also provide a libsoup server:

```text
repo/
  v1/
    index.json
    index.json.sha256
    packages/
      gtk4/
        gtk4-4.14.5+ds-0ubuntu0.10-x86_64-w64-mingw32.pkg.json
        gtk4-4.14.5+ds-0ubuntu0.10-x86_64-w64-mingw32.tar.gz
      native-sdk/
        native-sdk-1-x86_64-w64-mingw32.pkg.json
      ...
```

`index.json` is the fast catalogue. Per-package `.pkg.json` files are the
authoritative detailed metadata. Tarballs stay as the install payload.

## Package Metadata

Every artifact needs a package manifest. It should be generated during
`package_stage()` and stored both inside the tarball and next to it on the
server.

Suggested file inside each artifact:

```text
mingw64/share/ooblerg/packages/<name>.pkg.json
```

Suggested schema:

```json
{
  "schema": 1,
  "name": "gtk4",
  "version": "4.14.5+ds-0ubuntu0.10",
  "target": "x86_64-w64-mingw32",
  "architecture": "x86_64",
  "kind": "package",
  "summary": "GTK 4 runtime and development files",
  "description": "Optional longer text for the GUI detail pane.",
  "artifact": {
    "filename": "gtk4-4.14.5+ds-0ubuntu0.10-x86_64-w64-mingw32.tar.gz",
    "size": 12345678,
    "sha256": "..."
  },
  "dependencies": [
    { "name": "glib", "constraint": ">=2.80.0" },
    { "name": "pango" },
    { "name": "gdk-pixbuf" }
  ],
  "provides": [
    "gtk4",
    "libgtk-4-1",
    "gir:Gtk-4.0",
    "typelib:Gtk-4.0"
  ],
  "conflicts": [],
  "replaces": [],
  "files": [
    {
      "path": "mingw64/bin/libgtk-4-1.dll",
      "size": 123456,
      "sha256": "...",
      "kind": "file"
    }
  ],
  "directories": [
    "mingw64/share/gtk-4.0"
  ],
  "build": {
    "source": "gtk4",
    "version_package": "gtk-4-examples",
    "recipe_revision": "git:<commit>",
    "built_at": "2026-06-18T00:00:00Z"
  },
  "license": {
    "spdx": ["LGPL-2.1-or-later"],
    "files": ["mingw64/share/doc/gtk4/copyright"]
  },
  "tags": ["gui", "gtk", "runtime", "development"]
}
```

Notes:

- `files` should contain only regular files and symlinks, with paths relative to
  the sysroot root.
- `directories` is useful for cleanup but should never delete non-empty
  directories during removal.
- Meta packages such as `native-sdk` have no artifact payload, but still have
  dependencies and a package manifest.
- Dependency constraints can start simple: exact names, optional minimum
  versions, no alternative dependencies in the first cut.

## Repository Index

`index.json` should contain a compact list of packages:

```json
{
  "schema": 1,
  "repository": "ooblerg-local",
  "generated_at": "2026-06-18T00:00:00Z",
  "target": "x86_64-w64-mingw32",
  "packages": [
    {
      "name": "gtk4",
      "version": "4.14.5+ds-0ubuntu0.10",
      "summary": "GTK 4 runtime and development files",
      "manifest": "packages/gtk4/gtk4-4.14.5+ds-0ubuntu0.10-x86_64-w64-mingw32.pkg.json",
      "artifact": "packages/gtk4/gtk4-4.14.5+ds-0ubuntu0.10-x86_64-w64-mingw32.tar.gz",
      "sha256": "...",
      "dependencies": ["glib", "pango", "gdk-pixbuf"],
      "installed_size": 123456789,
      "tags": ["gui", "gtk"]
    }
  ]
}
```

The client starts by fetching the index from the configured source URI:

```text
https://example.invalid/ooblerg/v1/index.json
```

## Local Install Database

The client maintains local package state inside the fixed user-data sysroot:

```text
%LOCALAPPDATA%/Ooblerg/sysroot/
  mingw64/
  var/
    lib/
      ooblerg/
        status.json
        packages/
          gtk4.pkg.json
          glib.pkg.json
        transactions/
          20260618-120000-install-gtk4.json
        cache/
          artifacts/
```

`status.json` tracks package install state:

```json
{
  "schema": 1,
  "target": "x86_64-w64-mingw32",
  "source_uri": "http://127.0.0.1:8787/v1/index.json",
  "packages": {
    "gtk4": {
      "version": "4.14.5+ds-0ubuntu0.10",
      "manual": true,
      "installed_at": "2026-06-18T00:00:00Z",
      "manifest": "var/lib/ooblerg/packages/gtk4.pkg.json"
    },
    "glib": {
      "version": "2.80.0-6ubuntu3.8",
      "manual": false,
      "installed_at": "2026-06-18T00:00:00Z",
      "manifest": "var/lib/ooblerg/packages/glib.pkg.json"
    }
  }
}
```

The `manual` flag lets dependency cleanup behave like APT:

- Packages the user explicitly selected are manual.
- Packages pulled only as dependencies are automatic.
- On removal, automatic packages can be offered for cleanup if nothing still
  depends on them.

## Dependency Solver

The first solver should be deterministic and conservative:

1. Load remote index and local status.
2. Build a package map keyed by name.
3. For install:
   - Walk dependencies depth-first.
   - Skip already-installed compatible packages.
   - Add missing dependencies before the requested package.
   - Fail if a dependency cannot be found or conflicts with installed packages.
4. For removal:
   - Refuse to remove a package needed by another manual package unless the user
     chooses a cascading removal.
   - Calculate automatic packages that become orphaned.
   - Present the full removal plan before touching the sysroot.
5. Produce a transaction plan with ordered operations.

The first cut does not need SAT solving. If version alternatives become
necessary later, the solver can grow behind the same transaction-plan API.

## Transactions

All installs and removals should flow through a transaction object:

```json
{
  "schema": 1,
  "id": "20260618-120000-install-gtk4",
  "operation": "install",
  "requested": ["gtk4"],
  "install": ["glib", "pango", "gtk4"],
  "remove": [],
  "download_bytes": 12345678,
  "installed_bytes": 45678901,
  "warnings": []
}
```

Install sequence:

1. Download missing artifacts to `var/lib/ooblerg/cache/artifacts`.
2. Verify SHA-256 before extraction.
3. Check file conflicts against local package manifests.
4. Extract each artifact into a staging directory.
5. Copy into the sysroot.
6. Write each installed package manifest.
7. Update `status.json` atomically.
8. Save transaction log.

Removal sequence:

1. Load installed package manifest.
2. Remove files owned only by that package.
3. Leave files that are also owned by another package.
4. Remove empty directories listed by the manifest, deepest first.
5. Update `status.json` atomically.
6. Save transaction log.

Atomicity is limited by filesystem operations, but we can still avoid corrupt
metadata by writing JSON to `.tmp` and renaming it into place.

## GUI App Responsibilities

The GUI owns user decisions and local sysroot mutations:

- Source URI configuration.
- Repository refresh.
- Package search and filtering.
- Install/remove/upgrade action selection.
- Dependency plan display.
- Transaction execution and progress.
- Local status database.
- Download cache.
- File extraction.

On Windows the sysroot is `%LOCALAPPDATA%\Ooblerg\sysroot`. On non-Windows
development hosts the SQGI prototype resolves the same concept through
`GLib.get_user_data_dir()/ooblerg/sysroot`.

The GUI should be usable offline for inspecting installed packages and removing
packages whose manifests are already local.

## Server Responsibilities

The server owns repository publication:

- Scan artifact directory.
- Generate per-package manifests when missing.
- Generate `index.json`.
- Serve index, manifests, and tarballs.
- Provide optional JSON API endpoints for clients.
- Support local development mode with a configurable artifact root.

The server should not mutate client sysroots.

## Build Tool Integration

The server-side `RepositoryBuilder` owns repository metadata generation. The
`tools/ooblerg.nut repo-index` command is only a CLI entry point into that
server implementation:

```bash
sqgi tools/ooblerg.nut repo-index
sqgi tools/ooblerg.nut repo-index --artifact-dir out/artifacts --repo-dir out/repo native-sdk gtk4
```

The package manager should consume the metadata generated by these commands,
not parse `manifest/packages.json` directly at runtime.

## Security Model

First cut:

- Verify artifact SHA-256 from `.pkg.json`.
- Verify `.pkg.json` SHA-256 from `index.json`.
- Refuse paths that are absolute or contain `..`.
- Refuse extraction outside the AppData sysroot.
- Do not run package scripts.

Next cut:

- Sign `index.json` with a repository key.
- Pin trusted source keys in the GUI config.
- Add transparent key rotation metadata.

## Directory Plan

```text
app/
  TODO.md
  main.nut
  sqgipkg.json
  src/
    ui/
    pkg/
    repo/
    sysroot/

server/
  TODO.md
  main.nut
  sqgipkg.json
  src/
    http/
    repo/

docs/
  package-manager-architecture.md
```

The initial implementation should follow the RFDTool pattern:

- `main.nut` parses command-line flags and launches the GTK/Soup application.
- Domain logic lives under `src/`.
- UI construction lives under `src/ui/`.
- `sqgipkg.json` packages the SQGI runtime and required native libraries.

## Open Questions

- Installed package metadata lives under `<sysroot>/var/lib/ooblerg`.
- Do we want packages to own files outside `mingw64/`?
- Should artifacts be recompressed with deterministic metadata for stable
  hashes?
- Do we want a command-line client sharing the same package manager core?
