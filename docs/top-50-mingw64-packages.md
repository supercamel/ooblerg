# Top 50 MinGW64 Cross Packages

Target: `x86_64-w64-mingw32`  
Prefix: `/mingw64`  
Artifact format: `out/artifacts/<name>-<ubuntu-version>-x86_64-w64-mingw32.tar.gz`

This is the first 50-package production queue for the ooblerg sysroot. The order favors broadly reusable packages first: a complete Windows-hosted MinGW toolchain, compression/data formats, graphics/UI, game/media, math/science, and the core GIS stack.

Status values:
- `built`: package artifact already exists in `out/artifacts`.
- `queued`: recipe is planned next for this manifest.
- `large`: useful, but expected to need a dependency pass or special recipe work.

| # | Package | Ubuntu source | Area | Why it belongs | Status |
|---:|---|---|---|---|---|
| 1 | `mingw-w64-runtime` | system seed | Toolchain | Windows headers, CRT, import libs, runtime DLLs | built |
| 2 | `mingw-binutils` | `binutils-mingw-w64` | Toolchain | Windows-hosted assembler, linker, objdump, strip | built |
| 3 | `mingw-gcc` | `gcc-13` | Toolchain | Windows-hosted C/C++ compiler | built |
| 4 | `zlib` | `zlib` | Compression | Baseline deflate support used everywhere | built |
| 5 | `brotli` | `brotli` | Compression | Modern web/content compression | built |
| 6 | `zstd` | `libzstd` | Compression | Fast modern archive/data compression | built |
| 7 | `bzip2` | `bzip2` | Compression | Common archive compatibility | built |
| 8 | `xz` | `xz-utils` | Compression | LZMA/XZ archive and TIFF/GDAL support | built |
| 9 | `sqlite` | `sqlite3` | Data | Embedded database, also GIS infrastructure | built |
| 10 | `expat` | `expat` | Data/XML | Small XML parser used by many C stacks | built |
| 11 | `libpng` | `libpng1.6` | Image | PNG decode/encode | built |
| 12 | `jpeg` | `libjpeg-turbo` | Image | Fast JPEG decode/encode | built |
| 13 | `tiff` | `tiff` | Image/GIS | TIFF and GeoTIFF foundation | built |
| 14 | `libwebp` | `libwebp` | Image | WebP images for games, UI, and web assets | built |
| 15 | `freetype` | `freetype` | Text | Font rasterization | built |
| 16 | `fontconfig` | `fontconfig` | Text | Font discovery and matching | built |
| 17 | `harfbuzz` | `harfbuzz` | Text | Text shaping | built |
| 18 | `fribidi` | `fribidi` | Text | Bidirectional text support | built |
| 19 | `pixman` | `pixman` | Graphics | Low-level pixel compositing | built |
| 20 | `cairo` | `cairo` | Graphics | 2D vector drawing | built |
| 21 | `pango` | `pango1.0` | Text/UI | International text layout | built |
| 22 | `gdk-pixbuf` | `gdk-pixbuf` | Image/UI | Image loading for GTK-style stacks | built |
| 23 | `glib` | `glib2.0` | Core/UI | Core C runtime utilities and GObject | built |
| 24 | `gobject-introspection` | host metadata seed | Core/UI | GIR and typelib production support | built |
| 25 | `gtk4` | `gtk4` | UI | Native Win32 GTK4 toolkit with GIR/typelibs | built |
| 26 | `openssl` | `openssl` | Security | TLS and crypto baseline | built |
| 27 | `curl` | `curl` | Networking | HTTP(S), FTP, and transfer client library | built |
| 28 | `libsoup3` | `libsoup3` | Networking | GLib-native HTTP client/server stack | built |
| 29 | `libxml2` | `libxml2` | XML | XML parsing for office, GIS, and metadata stacks | built |
| 30 | `assimp` | `assimp` | Game/3D | 3D model import/export library | built |
| 31 | `SDL2` | `libsdl2` | Game | Window, input, audio, and platform abstraction | built |
| 32 | `SDL2_image` | `libsdl2-image` | Game/Image | Image loaders for SDL2 apps | built |
| 33 | `SDL2_mixer` | `libsdl2-mixer` | Game/Audio | SDL2 audio mixing and music formats | built |
| 34 | `SDL2_ttf` | `libsdl2-ttf` | Game/Text | TrueType text rendering for SDL2 | built |
| 35 | `openal-soft` | `openal-soft` | Game/Audio | Cross-platform 3D audio API | built |
| 36 | `glfw` | `glfw3` | Game/GL | Lightweight OpenGL/Vulkan windowing | built |
| 37 | `box2d` | `box2d` | Game/Physics | 2D rigid-body physics | built |
| 38 | `opus` | `opus` | Audio | Modern low-latency audio codec | built |
| 39 | `libsndfile` | `libsndfile` | Audio | WAV/FLAC/Ogg-style audio file I/O | built |
| 40 | `gmp` | `gmp` | Math | Multiple-precision integer arithmetic | built |
| 41 | `mpfr` | `mpfr4` | Math | Multiple-precision floating point | built |
| 42 | `mpc` | `mpclib3` | Math | Multiple-precision complex arithmetic | built |
| 43 | `isl` | `isl` | Math/Compiler | Integer set library used by compilers/optimizers | built |
| 44 | `eigen3` | `eigen3` | Math | Header-only C++ linear algebra | built |
| 45 | `openblas` | `openblas` | Math | Optimized BLAS/CBLAS implementation | built |
| 46 | `fftw3` | `fftw3` | Math/DSP | Fast Fourier transforms | built |
| 47 | `gsl` | `gsl` | Math | GNU Scientific Library | built |
| 48 | `proj` | `proj` | GIS | Coordinate reference systems and transforms | built |
| 49 | `geos` | `geos` | GIS | Geometry engine used by spatial stacks | built |
| 50 | `gdal` | `gdal` | GIS | Raster/vector geospatial data abstraction | built |

Already-built support artifacts outside the headline 50 include `libffi`, `pcre2`, `libepoxy`, `graphene`, `nghttp2`, `libpsl`, `gettext`, `vala`, `libgee`, `glib-introspection`, `minizip`, `pugixml`, `rapidjson`, `stb`, and `utfcpp`. They remain important for the current GTK/GIR sysroot and for downstream builds.

Execution result:

All 50 headline packages now have MinGW64 artifacts in `out/artifacts`. The large GIS finish used dependency-constrained builds: `proj` includes its generated `proj.db`, and `gdal` includes core raster/vector support with GeoTIFF, VRT, MEM, Shape, GeoJSON, KML, MapInfo TAB, GEOS, PROJ, curl, SQLite, libxml2, TIFF, JPEG, PNG, WebP, zlib, zstd, and xz support where detected.
