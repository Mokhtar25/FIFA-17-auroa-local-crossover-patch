/*
 * ipconfig.exe stand-in: answers "ipconfig /flushdns" the way Windows does.
 *
 * Wine's ipconfig knows only "/?" and "/all"; anything else prints
 * "Error: Unknown or invalid command line parameters specified" and exits 1.
 * The REFUT launcher (FIFA 20 online) runs "ipconfig.exe /flushdns" after it
 * writes its hosts routes and stops the whole start-up when that fails
 * ("STARTUP FAILED ... ipconfig.exe failed (1)"), so FIFA never starts.
 *
 * There is nothing to flush in this CrossOver: names go through
 * a17hosts.dylib, which rereads the bottle's hosts file whenever it changes,
 * and macOS's own cache is not Windows' to clear. So /flushdns prints what
 * Windows prints and exits 0. Every other command line goes to Wine's own
 * ipconfig.exe (found through WINEDLLDIR1, the lib/wine/x86_64-windows
 * folder Wine names in every process's environment), on the same standard
 * handles, and its exit code comes back as this one's.
 *
 * Installed as C:\windows\system32\ipconfig.exe in a bottle; a real PE there
 * runs in place of Wine's builtin placeholder.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -municode -s
 *            -Wl,--no-insert-timestamp -o cx-ipconfig.exe cx-ipconfig.c
 */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static int wine_ipconfig(void)
{
    wchar_t dir[MAX_PATH], exe[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"WINEDLLDIR1", dir, MAX_PATH);
    if (!n || n >= MAX_PATH) return 1;
    const wchar_t *d = dir;
    if (!wcsncmp(d, L"\\??\\", 4)) d += 4;
    if (_snwprintf(exe, MAX_PATH, L"%s\\ipconfig.exe", d) < 0) return 1;
    exe[MAX_PATH - 1] = 0;

    /* Everything after argv[0], found the way the C runtime finds it. */
    const wchar_t *args = GetCommandLineW();
    if (*args == L'"') {
        args++;
        while (*args && *args != L'"') args++;
        if (*args) args++;
    } else {
        while (*args && *args != L' ' && *args != L'\t') args++;
    }
    size_t len = wcslen(exe) + wcslen(args) + 3;
    wchar_t *cmd = HeapAlloc(GetProcessHeap(), 0, len * sizeof *cmd);
    if (!cmd) return 1;
    _snwprintf(cmd, len, L"\"%s\"%s", exe, args);
    cmd[len - 1] = 0;

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    if (!CreateProcessW(exe, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
        return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc == 2 && (!_wcsicmp(argv[1], L"/flushdns") || !_wcsicmp(argv[1], L"-flushdns"))) {
        printf("\nWindows IP Configuration\n\nSuccessfully flushed the DNS Resolver Cache.\n");
        return 0;
    }
    return wine_ipconfig();
}
