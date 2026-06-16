# ooblerg

`ooblerg` curates Ubuntu 24.04-pinned GNOME-ish libraries and programs as
`x86_64-w64-mingw32` tarballs. The tarballs are meant to be extracted together
to form a `/mingw64` sysroot usable on Windows and usable from this Ubuntu host
while building later dependencies.

The initial target set is GTK 4, Vala, libgee, libsoup 3, their dependency
closure, and a packaged MinGW runtime seed compatible with Ubuntu 24.04's
MinGW cross tools.

## Host assumptions

- Ubuntu 24.04 (`noble`) with updates/security enabled.
- `x86_64-w64-mingw32` cross tools installed.
- MSVCRT MinGW runtime, matching Ubuntu's MinGW packages.
- Host `g-ir-scanner` and `g-ir-compiler` for generating GIR and typelib
  data.
- A Windows executable wrapper, such as Wine, available via
  `OOBLERG_EXE_WRAPPER` when building packages with introspection enabled.
- Ubuntu source packages are the preferred source of truth for versions and
  downstream patches.

Enable source repositories before fetching Ubuntu sources:

```sh
sudo sed -i 's/^# deb-src/deb-src/' /etc/apt/sources.list
sudo apt update
```

On Ubuntu systems using `.sources` files, enable `Types: deb deb-src` in the
relevant `noble`, `noble-updates`, and `noble-security` entries instead.

## Quick start

```sh
./tools/ooblerg.py doctor
./tools/ooblerg.py versions
./tools/ooblerg.py seed-runtime
./tools/ooblerg.py fetch vala
./tools/ooblerg.py build vala
```

Artifacts are written to `out/artifacts`. The accumulated build sysroot lives
at `out/sysroot`.

GObject introspection is a cross-build special case. The host
`g-ir-scanner` compiles a temporary `x86_64-w64-mingw32` program and then must
run it to dump GType data. Set `OOBLERG_EXE_WRAPPER` to a wrapper executable
that can run those Windows programs before building introspection-enabled
packages:

```sh
export OOBLERG_EXE_WRAPPER=/path/to/wine64-or-wrapper
./tools/ooblerg.py build glib-introspection
```

To rebuild a clean Windows-style sysroot from the current artifact set:

```sh
./tools/ooblerg.py rebuild-sysroot --no-build-shims vala gtk4 libgee libsoup3
```

## Layout

- `manifest/packages.json` describes packages, source names, dependencies, and
  build recipes.
- `tools/ooblerg.py` fetches Ubuntu sources, cross-compiles, packages staged
  installs, and installs artifacts into the sysroot.
- `out/sources` stores downloaded/extracted Ubuntu source packages.
- `out/build` stores build directories.
- `out/stage` stores per-package installation roots before packaging.
- `out/artifacts` stores `.tar.gz` packages.
- `out/sysroot` stores the cumulative sysroot used by later builds.

## Current status

The current artifact set includes GTK 4, Vala, libgee, libsoup 3, and the
dependency closure currently needed for those roots. Several recipes carry
cross-compilation fixes for build-machine tools, Windows resource generation,
and Ubuntu source packages that omit generated files.

GObject introspection plumbing is present in the manifest. The
`gobject-introspection` metadata artifact provides Ubuntu-pinned
`gobject-introspection-1.0.pc` compatibility data for Meson and Autotools while
the actual scanner/compiler remain host tools. `glib-introspection` bootstraps
GLib/GObject/Gio GIR and typelib files after the GLib libraries are available.

The runtime seed is not a Windows-hosted GCC. It repackages Windows-target
headers, import libraries, CRT objects, and GCC runtime DLLs from Ubuntu's
installed MinGW cross toolchain. A Windows-runnable GCC should be built later as
its own package using these runtime files as part of the sysroot.

`libpsl` is currently built with Ubuntu's `publicsuffix` data compiled in, but
without the optional libidn2 runtime conversion path. That avoids adding a
non-Ubuntu libiconv dependency to the MinGW sysroot.
