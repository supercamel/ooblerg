project('ooblerg-native', 'c', version: '1.0.0')

cc = meson.get_compiler('c')
glib_dep = dependency('glib-2.0')
gobject_dep = dependency('gobject-2.0')
native_deps = [glib_dep, gobject_dep]

if host_machine.system() == 'windows'
  native_deps += [
    cc.find_library('advapi32'),
    cc.find_library('user32'),
  ]
endif

ooblerg_win_lib = shared_library(
  'ooblerg-win-1.0',
  'ooblerg-win.c',
  dependencies: native_deps,
  include_directories: include_directories('.'),
  install: false,
)

if host_machine.system() != 'windows'
  gnome = import('gnome')
  gnome.generate_gir(
    ooblerg_win_lib,
    sources: ['ooblerg-win.c', 'ooblerg-win.h'],
    namespace: 'OoblergWin',
    nsversion: '1.0',
    symbol_prefix: 'ooblerg_win',
    identifier_prefix: 'OoblergWin',
    includes: ['GObject-2.0'],
    dependencies: [glib_dep, gobject_dep],
    install: false,
  )
endif
