# WebKitGTKWin

This directory carries the local WebKitGTK-on-Windows port used by ooblerg.

The rule for this port is to keep GTK/Linux behavior intact and introduce
Windows behavior behind explicit backend boundaries. Prefer cross-platform
GLib, GIO, Cairo, Pango, HarfBuzz, ICU, libsoup, and GTK APIs. When WebKitGTK
uses Unix-only APIs, keep the existing implementation as the Unix backend and
add a Windows backend with the same internal interface.

Patch series:

- `patches/0001-webkitgtkwin-bootstrap.patch` starts the port by making GTK's
  CMake configuration distinguish Windows from Unix dependencies and by
  steering WTF/GTK toward Windows low-level platform sources.

Current status:

- Parked as an experimental target. JavaScriptCore, WebCore, and the
  JavaScriptCore typelib build with the current patch series, but the WebKit
  library is not finished.
- The next substantial blocker is the WebKit multi-process backend: GTK's Unix
  launcher/IPC path still passes file descriptors, while the Windows IPC layer
  expects handles. That needs a real Windows backend rather than another small
  compile guard.

Known major backend seams:

- WTF low-level OS support: files, mapped files, threads, timing, memory
  pressure, language, logging.
- WebKit IPC: Unix-domain sockets and `GUnixFDList`/`GUnixConnection` need a
  Windows transport backend.
- GLib API surface: public APIs exposing `GUnixFDList` need Windows-safe
  alternatives or conditional availability.
- Process launching and sandbox hooks: keep Linux/Bubblewrap code isolated and
  add Windows process/handle behavior.
