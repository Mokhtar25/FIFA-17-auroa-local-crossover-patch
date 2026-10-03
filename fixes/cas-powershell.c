/*
 * powershell.exe stand-in for the CAS launcher under Wine.
 *
 * CAS (tested from the 0.3.7 installer, which updates itself to 0.4.3)
 * derives its device id by running Windows PowerShell:
 *   (Get-CimInstance Win32_ComputerSystemProduct).UUID, dashes removed,
 *   upper case, rejected if not 32 hex digits or all 0 / all F, then
 *   sha256("CAS-device-v1:" + uuid) printed as lower-case hex.
 * Wine's powershell.exe is a stub that prints nothing, so CAS reports
 * "Install the latest CAS launcher to verify this device." and sign-in
 * never starts. This answers that one script with the same value real
 * PowerShell would print. The UUID comes from Wine's own WMI, which on a
 * Mac is the machine's IOPlatformUUID, so each Mac keeps its own id. That
 * is on purpose and must stay so: CAS bans by device, and an id made up per
 * bottle or per run would look like dodging one.
 *
 * Every other command line belongs to somebody else. CAS runs this by its
 * full path, %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe,
 * and that is also where setup.sh step 8 puts Aurora17's stand-in
 * (aurora17/aurora-pwsh.c): Aurora17Connector finds it there on PATH when
 * its own folder has no copy. One file cannot be both, so setup.sh moves
 * Aurora17's beside this one as aurora17-powershell.exe, and when that file
 * is there the whole command line goes to it unchanged, on the same standard
 * handles, and its exit code comes back as this one's. When it is not there,
 * anything else gets what Wine's stub gives: no output, exit 0.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -municode -s -Wl,--no-insert-timestamp
 *            -o cas-powershell.exe cas-powershell.c -lbcrypt
 * (build.sh does exactly this; -s and --no-insert-timestamp make two builds
 * with the same compiler byte-identical.)
 */
#include <windows.h>
#include <bcrypt.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

/* The name setup.sh gives Aurora17's stand-in when this takes its place. */
#define HAND_OFF L"aurora17-powershell.exe"

static int read_uuid(char out[33])
{
    char line[256];
    FILE *p = _popen("wmic csproduct get uuid", "r");
    if (!p) return 0;
    int ok = 0;
    while (!ok && fgets(line, sizeof line, p)) {
        int n = 0;
        for (char *c = line; *c && n < 33; c++) {
            if (*c == '-') continue;
            if (isxdigit((unsigned char)*c)) out[n++] = (char)toupper((unsigned char)*c);
            else if (n) break;
        }
        if (n == 32) { out[32] = 0; ok = 1; }
    }
    _pclose(p);
    if (!ok) return 0;
    if (strspn(out, "0") == 32 || strspn(out, "F") == 32) return 0;
    return 1;
}

static int hand_off(void)
{
    wchar_t next[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, next, MAX_PATH);
    wchar_t *slash;
    if (!n || n >= MAX_PATH || !(slash = wcsrchr(next, L'\\'))) return 0;
    if ((size_t)(slash + 1 - next) + wcslen(HAND_OFF) >= MAX_PATH) return 0;
    wcscpy(slash + 1, HAND_OFF);
    DWORD attr = GetFileAttributesW(next);
    if (attr == INVALID_FILE_ATTRIBUTES || (attr & FILE_ATTRIBUTE_DIRECTORY))
        return 0;

    /* Everything after argv[0], found the way the C runtime finds it: a
     * quoted argv[0] runs to the next quote, a bare one to the first blank. */
    const wchar_t *args = GetCommandLineW();
    if (*args == L'"') {
        args++;
        while (*args && *args != L'"') args++;
        if (*args) args++;
    } else {
        while (*args && *args != L' ' && *args != L'\t') args++;
    }

    size_t len = wcslen(next) + wcslen(args) + 3;
    wchar_t *cmd = HeapAlloc(GetProcessHeap(), 0, len * sizeof *cmd);
    if (!cmd) return 1;
    wcscpy(cmd, L"\"");
    wcscat(cmd, next);
    wcscat(cmd, L"\"");
    wcscat(cmd, args);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    /* A stand-in that is there and will not start is a failure, not the
     * stub's silent success: the caller should see an error. */
    if (!CreateProcessW(next, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
        return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}

int wmain(void)
{
    const wchar_t *cmd = GetCommandLineW();
    if (!wcsstr(cmd, L"Win32_ComputerSystemProduct") || !wcsstr(cmd, L"CAS-device-v1:"))
        return hand_off();

    char uuid[33], msg[64];
    if (!read_uuid(uuid)) return 1;
    int len = snprintf(msg, sizeof msg, "CAS-device-v1:%s", uuid);

    UCHAR digest[32];
    if (BCryptHash(BCRYPT_SHA256_ALG_HANDLE, NULL, 0, (PUCHAR)msg, len, digest, sizeof digest) != 0)
        return 1;
    for (int i = 0; i < 32; i++) printf("%02x", digest[i]);
    printf("\r\n");
    return 0;
}
