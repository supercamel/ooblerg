# SQGI Libsoup Repository Server TODO

This TODO covers the repository server in `server/`. The server scans the
artifact output directory, generates repository metadata, and serves it over
HTTP. It is currently aimed at local and staging repository publication before
we add signing and production deployment controls.

## Current Baseline

- [x] Create `server/main.nut` with `--help`, `--self-test`, `--serve`, and
      `--server`.
- [x] Use a Gio.Application-style entry point in `server/src/application.nut`.
- [x] Create `server/sqgipkg.json` with app id `dev.ooblerg.pkgserver`.
- [x] Import libsoup 3 through SQGI.
- [x] Start a `Soup.Server` on configurable host and port.
- [x] Add command-line options:
      - `--root`
      - `--artifact-dir`
      - `--repo-dir`
      - `--host`
      - `--port`
      - `--repository`
      - `--rebuild-index`
- [x] Add `GET /healthz`.

## Repository Build

- [x] Treat `manifest/packages.json` as the authoritative package list.
- [x] Generate canonical artifact filenames from package name, package version,
      and the `x86_64-w64-mingw32` target triplet.
- [x] Read dependency data from `manifest/packages.json`.
- [x] Preserve package descriptions and tags when present.
- [x] Support meta packages with no tarball payload.
- [x] Include `native-sdk` as a first-class meta package.
- [x] Compute artifact size and SHA-256.
- [x] List tarball files without extracting unsafely.
- [x] Reject tar members with absolute paths, `..`, backslashes, or drive
      prefixes.
- [x] Record regular files, symlinks, hardlinks, special entries, and
      directories.
- [x] Generate per-package `.pkg.json` metadata.
- [x] Copy or hardlink tarballs into `out/repo/v1/packages/<name>/`.
- [x] Generate `out/repo/v1/index.json`.
- [x] Generate `out/repo/v1/index.json.sha256`.
- [x] Sort package entries, file entries, and directory entries before writing
      metadata.
- [ ] Add strict schema validation for generated `.pkg.json` files.
- [ ] Add `repo verify` logic that rechecks all hashes, paths, and referenced
      artifacts.
- [ ] Make repository output fully deterministic by controlling generated
      timestamps.
- [ ] Optionally embed `.pkg.json` manifests into artifacts once the server no
      longer needs to synthesize them.

## HTTP Endpoints

- [x] `GET /` and `HEAD /` serve the repository index.
- [x] `GET /v1/index.json` and `HEAD /v1/index.json` serve repository index
      JSON.
- [x] `GET /v1/index.json.sha256` and `HEAD /v1/index.json.sha256` serve the
      index checksum.
- [x] `GET /v1/packages/<name>/<manifest>.pkg.json` serves package manifests.
- [x] `GET /v1/packages/<name>/<artifact>.tar.gz` serves package artifacts.
- [ ] Add optional debug JSON route for `GET /v1/packages`.
- [ ] Add optional debug JSON route for `GET /v1/packages/<name>`.

## Content Serving

- [x] Serve static files from `out/repo`.
- [x] Set content types:
      - JSON: `application/json`
      - tarballs: `application/gzip`
      - checksums: `text/plain`
      - fallback: `application/octet-stream`
- [x] Never serve files outside repo root.
- [x] Reject unsafe request paths before filesystem lookup.
- [ ] Set `ETag` from SHA-256.
- [ ] Set `Last-Modified`.
- [ ] Support conditional requests if libsoup makes it easy.
- [ ] Support ranged downloads for large artifacts.

## Repository Rebuild Workflow

- [x] Rebuild index on startup when `--rebuild-index` is passed.
- [x] Log indexed packages, skipped packages, link/copy operations, and written
      index files.
- [ ] Add `POST /admin/rebuild` for development mode only.
- [ ] Add filesystem watcher later if needed.
- [ ] Add clearer structured logs for scanned artifacts, generated manifests,
      hash mismatches, and rejected paths.
- [ ] Add release mode that serves only prebuilt repository files and refuses
      admin endpoints.

## Signing And Trust

- [ ] Add repository signing after the unsigned local server works.
- [ ] Sign `index.json`.
- [ ] Publish repository public key.
- [ ] Add key id and signature URI to index metadata.
- [ ] Keep client-side signature verification behind a clean module boundary.

## Server Tests

- [x] Add `sqgi server/main.nut --self-test`.
- [x] Test static content type mapping.
- [x] Test unsafe path detection.
- [x] Test builder option/root normalization.
- [x] Test tar member path rejection helper.
- [x] Test `native-sdk` dependency closure includes `gcc` and excludes
      `busybox-w32`.
- [x] Test HTTP health endpoint.
- [x] Cover index, manifest, and artifact HTTP serving through
      `./tools/test-app-gui`.
- [ ] Test package manifest generation from a tiny fixture artifact.
- [ ] Test index generation ordering and hash generation directly.
- [ ] Test static index, package manifest, artifact, HEAD, and 404 routes with
      a temporary repo directory.
- [ ] Test `repo verify` once implemented.

## Packaging

- [x] Add `server/sqgipkg.json`.
- [x] Add development run command:
      `sqgi server/main.nut --server --rebuild-index`.
- [ ] Package server as an SQGI app.
- [ ] Include libsoup typelib and DLL/shared library dependencies.
- [ ] Add release-mode packaging defaults.

## Current Module Boundaries

```text
server/main.nut                  command-line entry point
server/src/application.nut       Gio.Application command handling
server/src/repo/builder.nut      repository build, artifact scan, manifests, index
server/src/http/server.nut       libsoup server setup and request dispatch
server/src/http/static.nut       safe static file resolution and content types
server/src/http/metrics.nut      private JSONL request/download metrics
server/src/util.nut              shared utility helpers
server/test/repo_tests.nut       repository/static helper tests
server/test/http_tests.nut       libsoup health endpoint test
```

## Current Demo Status

- [x] Run:
      `sqgi server/main.nut --server --rebuild-index --artifact-dir=out/artifacts`.
- [x] Open:
      `http://127.0.0.1:8787/v1/index.json`.
- [x] Confirm the GUI can use that URL as its source URI.
- [x] Plan, apply, and remove packages from the GUI harness.
- [ ] Run a production-like signed repository demo once signing exists.
