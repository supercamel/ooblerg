#define UNICODE
#define _UNICODE

#include <process.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

static int dirname_in_place(wchar_t *path)
{
    size_t len = wcslen(path);
    while (len > 0 && path[len - 1] != L'\\' && path[len - 1] != L'/') len--;
    if (len == 0) return 0;
    path[len - 1] = L'\0';
    return 1;
}

static wchar_t *join3(const wchar_t *a, const wchar_t *b, const wchar_t *c)
{
    size_t len = wcslen(a) + 1 + wcslen(b) + 1 + wcslen(c) + 1;
    wchar_t *out = (wchar_t *)calloc(len, sizeof(wchar_t));
    if (!out) return NULL;
    swprintf(out, len, L"%ls\\%ls\\%ls", a, b, c);
    return out;
}

static void prepend_git_path(const wchar_t *prefix)
{
    wchar_t *old_path = _wgetenv(L"PATH");
    const wchar_t *suffix = old_path ? old_path : L"";
    size_t len = wcslen(prefix) * 3 + wcslen(suffix) + 128;
    wchar_t *new_path = (wchar_t *)calloc(len, sizeof(wchar_t));
    if (!new_path) return;
    swprintf(new_path, len,
        L"PATH=%ls\\opt\\git\\cmd;%ls\\opt\\git\\mingw64\\bin;%ls\\opt\\git\\usr\\bin;%ls",
        prefix, prefix, prefix, suffix);
    _wputenv(new_path);
}

int wmain(int argc, wchar_t **argv)
{
    wchar_t self[MAX_PATH];
    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) {
        fwprintf(stderr, L"git-launcher: could not locate executable\n");
        return 127;
    }

    wchar_t prefix[MAX_PATH];
    wcsncpy(prefix, self, MAX_PATH - 1);
    prefix[MAX_PATH - 1] = L'\0';
    if (!dirname_in_place(prefix) || !dirname_in_place(prefix)) {
        fwprintf(stderr, L"git-launcher: could not locate prefix\n");
        return 127;
    }

    wchar_t *target = join3(prefix, L"opt\\git\\cmd", L"git.exe");
    if (!target) return 127;

    wchar_t **child_argv = (wchar_t **)calloc((size_t)argc + 1, sizeof(wchar_t *));
    if (!child_argv) {
        free(target);
        return 127;
    }
    child_argv[0] = target;
    for (int i = 1; i < argc; i++) child_argv[i] = argv[i];
    child_argv[argc] = NULL;

    prepend_git_path(prefix);
    int status = _wspawnv(_P_WAIT, target, child_argv);
    if (status < 0) {
        fwprintf(stderr, L"git-launcher: failed to run %ls\n", target);
        status = 127;
    }

    free(child_argv);
    free(target);
    return status;
}
