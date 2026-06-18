#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <wchar.h>

static int
debug_enabled(void)
{
  return GetEnvironmentVariableW(L"OOBLERG_LAUNCHER_DEBUG", NULL, 0) > 0;
}

static int
append_text(wchar_t **buffer, size_t *used, size_t *capacity, const wchar_t *text)
{
  size_t len = wcslen(text);
  if (*used + len + 1 > *capacity) {
    size_t next = *capacity ? *capacity : 256;
    while (*used + len + 1 > next) {
      next *= 2;
    }
    wchar_t *grown = *buffer
      ? HeapReAlloc(GetProcessHeap(), 0, *buffer, next * sizeof(wchar_t))
      : HeapAlloc(GetProcessHeap(), 0, next * sizeof(wchar_t));
    if (!grown) {
      return 0;
    }
    *buffer = grown;
    *capacity = next;
  }
  memcpy(*buffer + *used, text, len * sizeof(wchar_t));
  *used += len;
  (*buffer)[*used] = L'\0';
  return 1;
}

static int
append_quoted_arg(wchar_t **buffer, size_t *used, size_t *capacity, const wchar_t *arg)
{
  if (!append_text(buffer, used, capacity, L"\"")) {
    return 0;
  }

  size_t slashes = 0;
  for (const wchar_t *p = arg; *p; ++p) {
    if (*p == L'\\') {
      ++slashes;
      continue;
    }
    if (*p == L'"') {
      for (size_t i = 0; i < slashes * 2 + 1; ++i) {
        if (!append_text(buffer, used, capacity, L"\\")) {
          return 0;
        }
      }
      slashes = 0;
      if (!append_text(buffer, used, capacity, L"\"")) {
        return 0;
      }
      continue;
    }
    for (size_t i = 0; i < slashes; ++i) {
      if (!append_text(buffer, used, capacity, L"\\")) {
        return 0;
      }
    }
    slashes = 0;
    wchar_t ch[2] = { *p, L'\0' };
    if (!append_text(buffer, used, capacity, ch)) {
      return 0;
    }
  }

  for (size_t i = 0; i < slashes * 2; ++i) {
    if (!append_text(buffer, used, capacity, L"\\")) {
      return 0;
    }
  }
  return append_text(buffer, used, capacity, L"\"");
}

int
wmain(int argc, wchar_t **argv)
{
  wchar_t module[MAX_PATH];
  DWORD len = GetModuleFileNameW(NULL, module, MAX_PATH);
  int debug = debug_enabled();
  if (debug) {
    fwprintf(stderr, L"module=%ls\n", module);
  }
  if (len == 0 || len >= MAX_PATH) {
    if (debug) {
      fwprintf(stderr, L"GetModuleFileNameW failed: len=%lu error=%lu\n", len, GetLastError());
    }
    return 1;
  }

  wchar_t *last_backslash = wcsrchr(module, L'\\');
  wchar_t *last_forwardslash = wcsrchr(module, L'/');
  wchar_t *last_slash = last_backslash;
  if (!last_slash || (last_forwardslash && last_forwardslash > last_slash)) {
    last_slash = last_forwardslash;
  }
  if (!last_slash) {
    if (debug) {
      fwprintf(stderr, L"could not find path separator in module path\n");
    }
    return 1;
  }
  *last_slash = L'\0';

  wchar_t python[MAX_PATH];
  wchar_t meson[MAX_PATH];
  if (swprintf(python, MAX_PATH, L"%ls\\python.exe", module) < 0 ||
      swprintf(meson, MAX_PATH, L"%ls\\meson.pyz", module) < 0) {
    if (debug) {
      fwprintf(stderr, L"failed to format child paths\n");
    }
    return 1;
  }
  if (debug) {
    fwprintf(stderr, L"python=%ls\nmeson=%ls\n", python, meson);
  }

  wchar_t *command = NULL;
  size_t used = 0;
  size_t capacity = 0;
  if (!append_quoted_arg(&command, &used, &capacity, python) ||
      !append_text(&command, &used, &capacity, L" ") ||
      !append_quoted_arg(&command, &used, &capacity, meson)) {
    if (debug) {
      fwprintf(stderr, L"failed to allocate command line\n");
    }
    HeapFree(GetProcessHeap(), 0, command);
    return 1;
  }
  for (int i = 1; i < argc; ++i) {
    if (!append_text(&command, &used, &capacity, L" ") ||
      !append_quoted_arg(&command, &used, &capacity, argv[i])) {
      if (debug) {
        fwprintf(stderr, L"failed to append argument %d\n", i);
      }
      HeapFree(GetProcessHeap(), 0, command);
      return 1;
    }
  }
  if (debug) {
    fwprintf(stderr, L"command=%ls\n", command);
  }

  STARTUPINFOW startup;
  PROCESS_INFORMATION process;
  ZeroMemory(&startup, sizeof(startup));
  ZeroMemory(&process, sizeof(process));
  startup.cb = sizeof(startup);

  BOOL ok = CreateProcessW(python, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process);
  HeapFree(GetProcessHeap(), 0, command);
  if (!ok) {
    if (debug) {
      fwprintf(stderr, L"CreateProcessW failed: error=%lu\n", GetLastError());
    }
    return (int)GetLastError();
  }

  WaitForSingleObject(process.hProcess, INFINITE);
  DWORD exit_code = 1;
  GetExitCodeProcess(process.hProcess, &exit_code);
  if (debug) {
    fwprintf(stderr, L"child exit=%lu\n", exit_code);
  }
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return (int)exit_code;
}
