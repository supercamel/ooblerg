#include "ooblerg-win.h"

#include <string.h>

#ifdef _WIN32
#include <glib/gwin32.h>
#include <windows.h>
#endif

static GMutex error_lock;
static gchar *last_error = NULL;

static void
set_last_error(const gchar *message)
{
    g_mutex_lock(&error_lock);
    g_free(last_error);
    last_error = g_strdup(message != NULL ? message : "");
    g_mutex_unlock(&error_lock);
}

#ifdef _WIN32
static void
set_last_win32_error(const gchar *prefix, LONG code)
{
    gchar *msg = g_win32_error_message((gint) code);
    gchar *full = g_strdup_printf("%s: %s", prefix, msg != NULL ? msg : "Windows API error");
    set_last_error(full);
    g_free(full);
    g_free(msg);
}

static gboolean
utf8_to_wide(const gchar *value, gunichar2 **out)
{
    GError *error = NULL;
    *out = g_utf8_to_utf16(value != NULL ? value : "", -1, NULL, NULL, &error);
    if (*out != NULL) return TRUE;
    set_last_error(error != NULL ? error->message : "failed to convert UTF-8 to UTF-16");
    g_clear_error(&error);
    return FALSE;
}

static gchar *
wide_to_utf8(const gunichar2 *value)
{
    GError *error = NULL;
    gchar *out = g_utf16_to_utf8(value != NULL ? value : (const gunichar2 *) L"", -1, NULL, NULL, &error);
    if (out != NULL) return out;
    set_last_error(error != NULL ? error->message : "failed to convert UTF-16 to UTF-8");
    g_clear_error(&error);
    return NULL;
}

static gboolean
open_environment_key(REGSAM access, HKEY *key)
{
    LONG status = RegOpenKeyExW(HKEY_CURRENT_USER, L"Environment", 0, access, key);
    if (status == ERROR_FILE_NOT_FOUND) {
        status = RegCreateKeyExW(HKEY_CURRENT_USER, L"Environment", 0, NULL, 0, access, NULL, key, NULL);
    }
    if (status == ERROR_SUCCESS) return TRUE;
    set_last_win32_error("failed to open HKCU\\Environment", status);
    return FALSE;
}

static gchar *
read_user_path_with_type(DWORD *value_type)
{
    HKEY key = NULL;
    if (!open_environment_key(KEY_QUERY_VALUE, &key)) return NULL;

    DWORD type = REG_EXPAND_SZ;
    DWORD bytes = 0;
    LONG status = RegQueryValueExW(key, L"Path", NULL, &type, NULL, &bytes);
    if (status == ERROR_FILE_NOT_FOUND) {
        RegCloseKey(key);
        if (value_type != NULL) *value_type = REG_EXPAND_SZ;
        return g_strdup("");
    }
    if (status != ERROR_SUCCESS) {
        RegCloseKey(key);
        set_last_win32_error("failed to read user Path", status);
        return NULL;
    }
    if (type != REG_SZ && type != REG_EXPAND_SZ) {
        RegCloseKey(key);
        set_last_error("HKCU\\Environment\\Path is not a string value");
        return NULL;
    }

    gunichar2 *buffer = g_malloc0(bytes + sizeof(gunichar2));
    status = RegQueryValueExW(key, L"Path", NULL, &type, (LPBYTE) buffer, &bytes);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) {
        g_free(buffer);
        set_last_win32_error("failed to read user Path", status);
        return NULL;
    }

    if (value_type != NULL) *value_type = type;
    gchar *out = wide_to_utf8(buffer);
    g_free(buffer);
    return out;
}

static void
broadcast_environment_change(void)
{
    SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, (LPARAM) L"Environment",
        SMTO_ABORTIFHUNG, 5000, NULL);
}

static gboolean
write_user_path(const gchar *path, DWORD value_type)
{
    HKEY key = NULL;
    if (!open_environment_key(KEY_SET_VALUE, &key)) return FALSE;

    gunichar2 *wide = NULL;
    if (!utf8_to_wide(path != NULL ? path : "", &wide)) {
        RegCloseKey(key);
        return FALSE;
    }

    if (value_type != REG_SZ && value_type != REG_EXPAND_SZ) value_type = REG_EXPAND_SZ;
    DWORD bytes = (DWORD) ((wcslen((const wchar_t *) wide) + 1) * sizeof(wchar_t));
    LONG status = RegSetValueExW(key, L"Path", 0, value_type, (const BYTE *) wide, bytes);
    RegCloseKey(key);
    g_free(wide);

    if (status != ERROR_SUCCESS) {
        set_last_win32_error("failed to write user Path", status);
        return FALSE;
    }

    broadcast_environment_change();
    set_last_error("");
    return TRUE;
}

static gchar *
normalize_path_segment(const gchar *value)
{
    gchar *copy = g_strdup(value != NULL ? value : "");
    g_strstrip(copy);
    for (gchar *p = copy; *p != '\0'; p++) {
        if (*p == '/') *p = '\\';
    }
    while (copy[0] != '\0') {
        gsize len = strlen(copy);
        if (len <= 1 || (copy[len - 1] != '\\' && copy[len - 1] != '/')) break;
        copy[len - 1] = '\0';
    }
    gchar *lower = g_utf8_strdown(copy, -1);
    g_free(copy);
    return lower;
}

static gboolean
path_contains_segment(const gchar *path_value, const gchar *entry)
{
    gchar *needle = normalize_path_segment(entry);
    if (needle[0] == '\0') {
        g_free(needle);
        return FALSE;
    }

    gboolean found = FALSE;
    gchar **parts = g_strsplit(path_value != NULL ? path_value : "", ";", -1);
    for (gint i = 0; parts[i] != NULL; i++) {
        gchar *candidate = normalize_path_segment(parts[i]);
        if (g_strcmp0(candidate, needle) == 0) found = TRUE;
        g_free(candidate);
        if (found) break;
    }
    g_strfreev(parts);
    g_free(needle);
    return found;
}

static gboolean
valid_entry(const gchar *path)
{
    if (path == NULL || *path == '\0') {
        set_last_error("PATH entry is empty");
        return FALSE;
    }
    if (strchr(path, ';') != NULL) {
        set_last_error("PATH entry must not contain semicolons");
        return FALSE;
    }
    return TRUE;
}
#endif

/**
 * ooblerg_win_is_supported:
 *
 * Returns: whether Windows user PATH integration is available.
 */
gboolean
ooblerg_win_is_supported(void)
{
#ifdef _WIN32
    return TRUE;
#else
    return FALSE;
#endif
}

/**
 * ooblerg_win_last_error:
 *
 * Returns: (transfer full): the last native integration error message.
 */
gchar *
ooblerg_win_last_error(void)
{
    g_mutex_lock(&error_lock);
    gchar *out = g_strdup(last_error != NULL ? last_error : "");
    g_mutex_unlock(&error_lock);
    return out;
}

/**
 * ooblerg_win_user_path:
 *
 * Returns: (transfer full): the current-user PATH value, or an empty string on unsupported systems.
 */
gchar *
ooblerg_win_user_path(void)
{
#ifdef _WIN32
    DWORD type = REG_EXPAND_SZ;
    gchar *path = read_user_path_with_type(&type);
    if (path == NULL) return g_strdup("");
    set_last_error("");
    return path;
#else
    set_last_error("Windows PATH integration is not available on this platform");
    return g_strdup("");
#endif
}

/**
 * ooblerg_win_user_path_contains:
 * @path: PATH entry to query.
 *
 * Returns: whether @path is already present in the current-user PATH.
 */
gboolean
ooblerg_win_user_path_contains(const gchar *path)
{
#ifdef _WIN32
    if (!valid_entry(path)) return FALSE;
    DWORD type = REG_EXPAND_SZ;
    gchar *current = read_user_path_with_type(&type);
    if (current == NULL) return FALSE;
    gboolean found = path_contains_segment(current, path);
    g_free(current);
    set_last_error("");
    return found;
#else
    (void) path;
    set_last_error("Windows PATH integration is not available on this platform");
    return FALSE;
#endif
}

/**
 * ooblerg_win_add_user_path:
 * @path: PATH entry to add.
 *
 * Returns: %TRUE if the PATH value was updated or already contained @path.
 */
gboolean
ooblerg_win_add_user_path(const gchar *path)
{
#ifdef _WIN32
    if (!valid_entry(path)) return FALSE;
    DWORD type = REG_EXPAND_SZ;
    gchar *current = read_user_path_with_type(&type);
    if (current == NULL) return FALSE;
    if (path_contains_segment(current, path)) {
        g_free(current);
        set_last_error("");
        return TRUE;
    }

    gchar *updated = NULL;
    if (current[0] == '\0') updated = g_strdup(path);
    else updated = g_strconcat(current, ";", path, NULL);
    g_free(current);

    gboolean ok = write_user_path(updated, type);
    g_free(updated);
    return ok;
#else
    (void) path;
    set_last_error("Windows PATH integration is not available on this platform");
    return FALSE;
#endif
}

/**
 * ooblerg_win_remove_user_path:
 * @path: PATH entry to remove.
 *
 * Returns: %TRUE if the PATH value was updated or did not contain @path.
 */
gboolean
ooblerg_win_remove_user_path(const gchar *path)
{
#ifdef _WIN32
    if (!valid_entry(path)) return FALSE;
    DWORD type = REG_EXPAND_SZ;
    gchar *current = read_user_path_with_type(&type);
    if (current == NULL) return FALSE;

    gchar *needle = normalize_path_segment(path);
    GString *updated = g_string_new("");
    gboolean removed = FALSE;
    gchar **parts = g_strsplit(current, ";", -1);
    for (gint i = 0; parts[i] != NULL; i++) {
        gchar *raw = g_strdup(parts[i]);
        g_strstrip(raw);
        if (raw[0] == '\0') {
            g_free(raw);
            continue;
        }

        gchar *candidate = normalize_path_segment(raw);
        if (g_strcmp0(candidate, needle) == 0) {
            removed = TRUE;
        } else {
            if (updated->len > 0) g_string_append_c(updated, ';');
            g_string_append(updated, raw);
        }
        g_free(candidate);
        g_free(raw);
    }
    g_strfreev(parts);
    g_free(needle);
    g_free(current);

    gboolean ok = TRUE;
    if (removed) ok = write_user_path(updated->str, type);
    else set_last_error("");
    g_string_free(updated, TRUE);
    return ok;
#else
    (void) path;
    set_last_error("Windows PATH integration is not available on this platform");
    return FALSE;
#endif
}
