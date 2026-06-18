# GTK4 SQGI Package Manager TODO

This TODO covers the GUI client in `app/`. It follows the RFDTool-style shape:
`main.nut` as the entry point, Squirrel modules under `src/`, GTK4 through SQGI
introspection, and `sqgipkg.json` packaging metadata.

## Current Baseline

- [x] Create `app/main.nut` with `--help`, `--self-test`, normal GTK launch,
      `--auto-refresh`, and `--gtk-smoke-test` modes.
- [x] Create `app/sqgipkg.json` with app id `dev.ooblerg.pkgmanager`.
- [x] Add module directories under `src/ui`, `src/pkg`, `src/repo`,
      `src/sysroot`, and `test`.
- [x] Build the first screen as the package management tool itself, not a
      landing page.
- [x] Use one fixed user-data sysroot. On Windows this resolves under
      `%LOCALAPPDATA%/Ooblerg/sysroot`; on Linux development hosts it uses the
      GLib user data directory.
- [x] Add settings, artifact cache, and local package database paths.
- [x] Add self-tests that run without launching GTK.
- [x] Add the GUI/server smoke harness:
      `./tools/test-app-gui`.

## Data And Repository

- [x] Implement repository index loading and validation.
- [x] Implement package map, sorted package list, dependency helpers, and
      summary helpers.
- [x] Load per-package `.pkg.json` manifests from repository metadata.
- [x] Validate manifest schema, name, version, file paths, and directory paths
      before sysroot mutation.
- [x] Implement local status database under
      `var/lib/ooblerg/status.json`.
- [x] Implement transaction plan data for install and remove flows.
- [x] Add JSON parse/serialize helpers using `sqgi.json`.
- [ ] Add stricter package manifest validation for `provides`, `conflicts`,
      `replaces`, artifact metadata, file kinds, and license metadata.
- [ ] Add focused tests for valid and invalid package manifests.
- [ ] Validate repository target compatibility before displaying installable
      packages.
- [ ] Cache the latest repository index locally for offline browsing.
- [ ] Persist and display the last repository refresh time.

## Source URI And Sysroot

- [x] Add a source URI entry in the GUI.
- [x] Add a refresh action that fetches `index.json`.
- [x] Keep HTTP and file loading behind `app/src/repo/client.nut`.
- [x] Use libsoup through SQGI when fetching HTTP URLs.
- [x] Show source refresh status in the status bar and log pane.
- [x] Create sysroot metadata directories automatically on first use.
- [x] Detect existing sysroot/status metadata with `Sysroot.looks_initialized()`.
- [ ] Add a first-run source URI flow.
- [ ] Add an "initialize sysroot metadata" flow for an existing unpacked
      sysroot.
- [ ] Support imported installs by scanning embedded package manifests once
      artifacts contain them.
- [ ] Add hardening tests for suspicious sysroot paths and metadata
      initialization.

## Dependency Planner

- [x] Implement install closure for requested packages, missing dependencies,
      already-installed packages, and missing package errors.
- [x] Implement removal closure for requested packages, reverse-dependency
      blocks, and automatic orphan cleanup.
- [x] Track manual vs automatic installs.
- [x] Detect file conflicts before installation.
- [x] Produce a transaction plan suitable for GUI review.
- [x] Add solver tests for simple install, deep dependency install, already
      installed dependencies, leaf removal, reverse-dependency blocking, orphan
      cleanup, missing dependencies, and conflicts.
- [ ] Detect package conflicts declared in metadata.

## Package List And Details UI

- [x] Build a main window with source/sysroot toolbar, package list, detail
      pane, action buttons, operation log, and bottom status bar.
- [x] Show package list columns for status, name, version, and summary.
- [ ] Add package list size/download column.
- [x] Add search/filter entry.
- [ ] Add filter modes for all, installed, available, upgrades, and selected
      changes.
- [ ] Add tags/categories if metadata includes tags.
- [x] Show description, dependencies, artifact size, installed size, and source
      manifest path in the detail pane.
- [ ] Show reverse dependencies and installed file count in the detail pane.
- [x] Add install/remove buttons with icons and tooltips.

## Transaction Review UI

- [x] Show a review dialog before modifying the sysroot.
- [x] Add working close/cancel and apply actions.
- [x] Display packages to install, packages to remove, automatic dependencies,
      automatic orphan removals, blocked removals, and warnings.
- [x] Make dependency-added packages visibly distinct from manually requested
      packages in the review text.
- [x] Explain which installed package still depends on a blocked removal.
- [ ] Add download-size and installed-size totals to the review dialog.

## Download, Install, And Remove Engine

- [x] Implement artifact cache keyed by filename and SHA-256.
- [x] Verify existing cache entries before reuse.
- [x] Delete corrupt cache entries.
- [x] Download artifacts and verify SHA-256 before extraction.
- [x] Log cache hits, downloads, verification, extraction, removal, and status
      saves to the operation log pane.
- [ ] Add byte-level download progress.
- [ ] Extract artifacts to a staging directory before moving files into the
      sysroot.
- [x] Reject absolute paths, drive-prefixed paths, backslash paths, and `..` in
      tar members.
- [x] Validate tar listings against package manifests before extraction.
- [x] Apply install payloads in dependency order.
- [x] Write installed package manifests to the local package database.
- [x] Atomically update `status.json`.
- [x] Refresh UI state after transaction completion.
- [x] Add install/remove tests using tiny fixture tarballs.
- [x] Remove files listed in installed package manifests.
- [x] Preserve files owned by another installed package.
- [x] Remove empty directories deepest first.
- [x] Never remove non-empty directories.
- [ ] Persist transaction logs to disk.
- [ ] Add undo information where practical.
- [ ] Expose installed file manifests in the GUI.

## Upgrade Flow

- [ ] Compare local installed versions with repository versions.
- [ ] Mark upgradeable packages.
- [ ] Implement upgrade as remove old metadata plus install new payload.
- [ ] Preserve manual/automatic flags across upgrades.
- [ ] Detect file ownership changes between versions.
- [ ] Add an "Upgrade all" flow.

## UX Polish

- [x] Add activity spinner/progress indicator while work is running.
- [x] Add a detailed operation log pane.
- [x] Add a status bar with package counts, selected package, and source URI.
- [x] Keep controls dense and practical for a developer package manager.
- [ ] Make operations cancellable.
- [ ] Add keyboard shortcuts for refresh, search focus, install, remove, and
      transaction review.
- [ ] Add error dialogs with copyable details.
- [ ] Add dark/light theme sanity checks.

## Packaging

- [ ] Package the GUI with SQGI for Linux development.
- [ ] Package the GUI for Windows using the Ooblerg sysroot.
- [ ] Include required typelibs:
      - GLib
      - Gio
      - GObject
      - Gtk 4
      - Soup 3
- [ ] Add app icon and desktop metadata.
- [x] Add CI smoke command:
      `sqgi app/main.nut --self-test`.
- [x] Add end-to-end GUI harness command:
      `./tools/test-app-gui`.

## Current Module Boundaries

```text
app/main.nut                  command-line entry point
app/src/config.nut            AppData/user-data paths and settings
app/src/pkg/manifest.nut      repository index/package helpers
app/src/pkg/status.nut        local install database
app/src/pkg/solver.nut        dependency planning
app/src/pkg/transaction.nut   transaction facade
app/src/repo/client.nut       source URI, index fetch, manifest fetch
app/src/repo/cache.nut        artifact cache and checksums
app/src/sysroot/install.nut   extraction, conflict detection, filesystem mutation
app/src/sysroot/paths.nut     fixed sysroot path helpers
app/src/ui/window.nut         GTK application, main window, review dialog, smoke test
app/test/package_tests.nut    model, solver, and fixture transaction tests
```

## Current Demo Status

- [x] Start local repository server from the harness.
- [x] Launch the GTK GUI from the harness.
- [x] Enter/generated source URI and refresh package list.
- [x] Use the fixed AppData/user-data sysroot path.
- [x] Plan, apply, and remove `native-sdk` through the GUI harness.
- [x] Verify dependency conflict regressions for packages such as `gcc`,
      `python`, and `native-sdk` through targeted harness runs.
- [ ] Demonstrate upgrade flow once version comparison exists.
