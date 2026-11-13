/* cx-tasklist.exe -- tasklist's "Not Responding" filter, for a bottle.
 *
 * Wine's tasklist.exe ignores /FI "STATUS eq ..." and lists every process the
 * other filters let through. Aurora 12's helper asks
 *
 *   tasklist /FI "IMAGENAME eq fifa.exe" /FI "STATUS eq NOT RESPONDING" /NH
 *
 * once a second, so it took a running FIFA 12 for a hung one and attached a
 * second debugger to it twice in the first 70 s; each of those stops the game
 * for 5 to 10 s.
 *
 * This answers that one filter the way Windows does: a process is Not
 * Responding when one of its visible top-level windows is hung
 * (IsHungAppWindow). Every other command line goes to Wine's own tasklist,
 * kept beside this file as tasklist.exe.wine-stub, unchanged.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <wchar.h>

#define MAX_HUNG 64
static DWORD hung[MAX_HUNG];
static int nhung;

static BOOL CALLBACK each_window(HWND w, LPARAM unused)
{
    DWORD pid = 0;
    int i;
    (void)unused;
    if (!IsWindowVisible(w) || !IsHungAppWindow(w)) return TRUE;
    GetWindowThreadProcessId(w, &pid);
    for (i = 0; i < nhung; i++) if (hung[i] == pid) return TRUE;
    if (pid && nhung < MAX_HUNG) hung[nhung++] = pid;
    return TRUE;
}

/* "status eq not responding" from `STATUS eq NOT RESPONDING`, any spacing. */
static void squeeze(const wchar_t *s, wchar_t *out, size_t n)
{
    size_t k = 0;
    BOOL gap = FALSE;
    while (*s == L' ' || *s == L'\t') s++;
    for (; *s && k + 2 < n; s++)
    {
        if (*s == L' ' || *s == L'\t') { gap = TRUE; continue; }
        if (gap) out[k++] = L' ';
        gap = FALSE;
        out[k++] = towlower(*s);
    }
    out[k] = 0;
}

static int own_tasklist(void)
{
    wchar_t self[MAX_PATH + 16];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) return 1;
    wcscat(self, L".wine-stub");
    memset(&si, 0, sizeof(si)); si.cb = sizeof(si);
    if (!CreateProcessW(self, GetCommandLineW(), NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    return (int)code;
}

int wmain(int argc, wchar_t **argv)
{
    wchar_t f[512], image[260] = L"";
    BOOL status = FALSE, other = FALSE, header = TRUE;
    HANDLE snap;
    PROCESSENTRY32W pe;
    int i, shown = 0;

    for (i = 1; i < argc; i++)
    {
        if (!_wcsicmp(argv[i], L"/NH")) header = FALSE;
        else if (!_wcsicmp(argv[i], L"/FI") && i + 1 < argc)
        {
            squeeze(argv[++i], f, 512);
            if (!wcscmp(f, L"status eq not responding")) status = TRUE;
            else if (!wcsncmp(f, L"imagename eq ", 13)) lstrcpynW(image, f + 13, 260);
            else other = TRUE;
        }
        else other = TRUE;
    }
    if (!status || other) return own_tasklist();

    EnumWindows(each_window, 0);
    snap = nhung ? CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) : INVALID_HANDLE_VALUE;
    if (snap != INVALID_HANDLE_VALUE)
    {
        pe.dwSize = sizeof(pe);
        if (Process32FirstW(snap, &pe)) do
        {
            for (i = 0; i < nhung && hung[i] != pe.th32ProcessID; i++) ;
            if (i == nhung || (image[0] && _wcsicmp(pe.szExeFile, image))) continue;
            if (header && !shown)
                printf("\r\nImage Name                     PID Session Name        Session#    Mem Usage\r\n"
                       "========================= ======== ================ =========== ============\r\n");
            printf("%-25ls %8lu %-16s %11u %10s K\r\n", pe.szExeFile, pe.th32ProcessID, "Console", 1, "0");
            shown++;
        } while (Process32NextW(snap, &pe));
        CloseHandle(snap);
    }
    if (!shown) printf("INFO: No tasks are running which match the specified criteria.\r\n");
    return 0;
}
