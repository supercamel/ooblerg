#pragma once

#include <glib-object.h>

G_BEGIN_DECLS

#ifdef _WIN32
#define OOBLERG_WIN_API __declspec(dllexport)
#else
#define OOBLERG_WIN_API
#endif

OOBLERG_WIN_API gboolean ooblerg_win_is_supported(void);
OOBLERG_WIN_API gchar *ooblerg_win_last_error(void);
OOBLERG_WIN_API gchar *ooblerg_win_user_path(void);
OOBLERG_WIN_API gboolean ooblerg_win_user_path_contains(const gchar *path);
OOBLERG_WIN_API gboolean ooblerg_win_add_user_path(const gchar *path);
OOBLERG_WIN_API gboolean ooblerg_win_remove_user_path(const gchar *path);

G_END_DECLS
