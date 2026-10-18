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
 * Two more command lines are answered here, both from the REFUT launcher
 * (FIFA 20 online, a .NET app that runs this file by the same full path):
 *
 * - "-File ...\guard\match-end-guard.ps1 -LogPath X". The script compiles C#
 *   with Add-Type, which needs real PowerShell, and injects a vectored
 *   exception handler into every FIFA20.exe it sees. The handler recovers one
 *   known crash at the end of a match: an access-violation READ of address
 *   0x48 at a RIP inside FIFA20.exe with RAX = 0, by pointing RAX at a small
 *   scratch object; every other exception goes on as normal. REFUT reads
 *   "[PATCHED]" and "[STABLE]" from its output, and closes FIFA when the
 *   guard never gets to [STABLE] ("GUARD FAILSAFE"), so without this a match
 *   cannot even start. refut_guard() does what the script does, step for
 *   step, with the same handler bytes, log lines and exit codes.
 * - "-Command exit N", REFUT's check that PowerShell runs at all. It gets N.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -municode -s -Wl,--no-insert-timestamp
 *            -o cas-powershell.exe cas-powershell.c -lbcrypt
 * (build.sh does exactly this; -s and --no-insert-timestamp make two builds
 * with the same compiler byte-identical.)
 */
#include <windows.h>
#include <bcrypt.h>
#include <tlhelp32.h>
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
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

/* ---- REFUT match-end guard (guard\match-end-guard.ps1) ------------------- */

#define GUARD_SCRIPT L"match-end-guard.ps1"
#define GUARD_REFERENCE_SHA256 "885D86BC01354587DCB3E3DB410B6A2717FB987CA675112DFFE7AB594AF85630"

static FILE *guard_log;

/* Log-Line: "yyyy-MM-dd HH:mm:ss.fff message" to the log, the bare message
 * to standard output, which REFUT reads. */
static void guard_line(const char *fmt, ...)
{
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    if (guard_log) {
        SYSTEMTIME t;
        GetLocalTime(&t);
        fprintf(guard_log, "%04u-%02u-%02u %02u:%02u:%02u.%03u %s\r\n", t.wYear, t.wMonth, t.wDay,
                t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, msg);
        fflush(guard_log);
    }
    printf("%s\r\n", msg);
    fflush(stdout);
}

/* A failure the script would throw: PowerShell -File prints it and exits 1. */
static int guard_fail(const char *what, DWORD err)
{
    if (err) fprintf(stderr, "%s (Win32 error %lu)\r\n", what, (unsigned long)err);
    else fprintf(stderr, "%s\r\n", what);
    fflush(stderr);
    if (guard_log) { fprintf(guard_log, "[ERROR] %s (%lu)\r\n", what, (unsigned long)err); fflush(guard_log); }
    return 1;
}

static void make_parents(wchar_t *path)
{
    for (wchar_t *p = path + 3; *p; p++) {
        if (*p != L'\\' && *p != L'/') continue;
        wchar_t c = *p;
        *p = 0;
        CreateDirectoryW(path, NULL);
        *p = c;
    }
}

static int pid_alive(DWORD pid)
{
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return 0;
    DWORD code = 0;
    int alive = GetExitCodeProcess(h, &code) && code == STILL_ACTIVE;
    CloseHandle(h);
    return alive;
}

static int module_info(DWORD pid, const wchar_t *name, ULONG_PTR *base, DWORD *size, wchar_t *path)
{
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (s == INVALID_HANDLE_VALUE) return 0;
    MODULEENTRY32W m;
    m.dwSize = sizeof m;
    int found = 0;
    if (Module32FirstW(s, &m)) {
        do {
            if (!_wcsicmp(m.szModule, name)) {
                *base = (ULONG_PTR)m.modBaseAddr;
                if (size) *size = m.modBaseSize;
                if (path) wcscpy(path, m.szExePath);
                found = 1;
            }
        } while (!found && Module32NextW(s, &m));
    }
    CloseHandle(s);
    return found;
}

static int file_sha256(const wchar_t *path, char hex[65])
{
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    BCRYPT_HASH_HANDLE h = NULL;
    static UCHAR buf[1 << 20];
    UCHAR digest[32];
    DWORD got;
    int ok = BCryptCreateHash(BCRYPT_SHA256_ALG_HANDLE, &h, NULL, 0, NULL, 0, 0) == 0;
    while (ok && ReadFile(f, buf, sizeof buf, &got, NULL) && got)
        ok = BCryptHashData(h, buf, got, 0) == 0;
    ok = ok && BCryptFinishHash(h, digest, sizeof digest, 0) == 0;
    if (h) BCryptDestroyHash(h);
    CloseHandle(f);
    if (!ok) return 0;
    for (int i = 0; i < 32; i++) sprintf(hex + 2 * i, "%02X", digest[i]);
    return 1;
}

typedef struct { UCHAR b[256]; int n; } code_buf;

static void emit(code_buf *c, int n, ...)
{
    va_list ap;
    va_start(ap, n);
    while (n--) c->b[c->n++] = (UCHAR)va_arg(ap, int);
    va_end(ap);
}

static int jcc32(code_buf *c, int cond) { emit(c, 6, 0x0F, cond, 0, 0, 0, 0); return c->n - 4; }
static int qword_slot(code_buf *c) { int at = c->n; c->n += 8; return at; }
static void put_rel32(code_buf *c, int at, int target) { INT32 rel = target - (at + 4); memcpy(c->b + at, &rel, 4); }
static void put_qword(UCHAR *b, int at, ULONG_PTR v) { memcpy(b + at, &v, 8); }

/* BuildVeh: the script's handler, byte for byte. rcx = EXCEPTION_POINTERS. */
static void build_veh(code_buf *c, ULONG_PTR fifa_base, ULONG_PTR fifa_end, ULONG_PTR scratch)
{
    c->n = 0;
    emit(c, 3, 0x48, 0x8B, 0x01);                         /* mov rax,[rcx]                */
    emit(c, 6, 0x81, 0x38, 0x05, 0x00, 0x00, 0xC0);       /* cmp dword [rax],C0000005     */
    int j_code = jcc32(c, 0x85);                          /* jne search                   */
    emit(c, 4, 0x83, 0x78, 0x18, 0x02);                   /* cmp dword [rax+18],2         */
    int j_params = jcc32(c, 0x82);                        /* jb search                    */
    emit(c, 5, 0x48, 0x83, 0x78, 0x20, 0x00);             /* cmp qword [rax+20],0 (read)  */
    int j_op = jcc32(c, 0x85);
    emit(c, 5, 0x48, 0x83, 0x78, 0x28, 0x48);             /* cmp qword [rax+28],48h       */
    int j_addr = jcc32(c, 0x85);
    emit(c, 4, 0x48, 0x8B, 0x50, 0x10);                   /* mov rdx,[rax+10] ExceptionAddress */
    emit(c, 4, 0x4C, 0x8B, 0x49, 0x08);                   /* mov r9,[rcx+8] ContextRecord */
    emit(c, 7, 0x49, 0x3B, 0x91, 0xF8, 0, 0, 0);          /* cmp rdx,[r9+F8] Context.Rip  */
    int j_rip = jcc32(c, 0x85);
    emit(c, 2, 0x49, 0xB8);                               /* mov r8,fifa_base             */
    int base_imm = qword_slot(c);
    emit(c, 3, 0x4C, 0x39, 0xC2);                         /* cmp rdx,r8                   */
    int j_below = jcc32(c, 0x82);                         /* jb search                    */
    emit(c, 2, 0x49, 0xB8);                               /* mov r8,fifa_end              */
    int end_imm = qword_slot(c);
    emit(c, 3, 0x4C, 0x39, 0xC2);
    int j_above = jcc32(c, 0x83);                         /* jae search                   */
    emit(c, 8, 0x49, 0x83, 0xB9, 0x78, 0, 0, 0, 0);       /* cmp qword [r9+78],0 Context.Rax */
    int j_rax = jcc32(c, 0x85);
    emit(c, 2, 0x48, 0xBA);                               /* mov rdx,scratch              */
    int scratch_imm = qword_slot(c);
    emit(c, 7, 0x49, 0x89, 0x91, 0x78, 0, 0, 0);          /* mov [r9+78],rdx              */
    emit(c, 6, 0xB8, 0xFF, 0xFF, 0xFF, 0xFF, 0xC3);       /* EXCEPTION_CONTINUE_EXECUTION */
    int search = c->n;
    emit(c, 3, 0x31, 0xC0, 0xC3);                         /* EXCEPTION_CONTINUE_SEARCH    */
    int jumps[] = { j_code, j_params, j_op, j_addr, j_rip, j_below, j_above, j_rax };
    for (int i = 0; i < 8; i++) put_rel32(c, jumps[i], search);
    put_qword(c->b, base_imm, fifa_base);
    put_qword(c->b, end_imm, fifa_end);
    put_qword(c->b, scratch_imm, scratch);
}

static int write_exact(HANDLE p, ULONG_PTR at, const void *b, SIZE_T n)
{
    SIZE_T w = 0;
    return WriteProcessMemory(p, (void *)at, b, n, &w) && w == n;
}

/* Install: one RWX page in FIFA (stub at +0, handler at +0x100, scratch at
 * +0x800, marker at +0xA00), a remote thread that calls
 * RtlAddVectoredExceptionHandler(1, handler), then the page goes read/execute. */
static int guard_install(DWORD pid, ULONG_PTR fifa_base, DWORD fifa_size, char *detail, size_t cap)
{
    HANDLE hp = OpenProcess(PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION |
                            PROCESS_VM_READ | PROCESS_VM_WRITE, FALSE, pid);
    if (!hp) return guard_fail("OpenProcess failed", GetLastError());
    int rc = 1;
    ULONG_PTR pg = (ULONG_PTR)VirtualAllocEx(hp, NULL, 0x2000, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!pg) { rc = guard_fail("VirtualAllocEx failed", GetLastError()); goto out; }
    ULONG_PTR handler = pg + 0x100, scratch = pg + 0x800, fifa_end = fifa_base + fifa_size;

    if (!write_exact(hp, scratch + 0x48, &scratch, 8)) { rc = guard_fail("WriteProcessMemory failed", GetLastError()); goto out; }
    code_buf veh;
    build_veh(&veh, fifa_base, fifa_end, scratch);
    if (!write_exact(hp, handler, veh.b, veh.n)) { rc = guard_fail("WriteProcessMemory failed", GetLastError()); goto out; }

    HMODULE lb = GetModuleHandleW(L"ntdll.dll");
    FARPROC lp = lb ? GetProcAddress(lb, "RtlAddVectoredExceptionHandler") : NULL;
    ULONG_PTR rbase;
    if (!lp) { rc = guard_fail("GetProcAddress failed", GetLastError()); goto out; }
    if (!module_info(pid, L"ntdll.dll", &rbase, NULL, NULL)) { rc = guard_fail("Module not found: ntdll.dll", 0); goto out; }
    ULONG_PTR add = rbase + ((ULONG_PTR)lp - (ULONG_PTR)lb);

    UCHAR stub[] = { 0x48, 0x83, 0xEC, 0x28,                  /* sub rsp,28         */
                     0xB9, 1, 0, 0, 0,                        /* mov ecx,1 (first)  */
                     0x48, 0xBA, 0, 0, 0, 0, 0, 0, 0, 0,      /* mov rdx,handler    */
                     0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0,      /* mov rax,add        */
                     0xFF, 0xD0,                              /* call rax           */
                     0x48, 0x83, 0xC4, 0x28,                  /* add rsp,28         */
                     0xC3 };
    put_qword(stub, 11, handler);
    put_qword(stub, 21, add);
    static const char marker[] = "F20V40-ADAPTIVE-RAX48-VEH";
    if (!write_exact(hp, pg, stub, sizeof stub) || !write_exact(hp, pg + 0xA00, marker, sizeof marker)) {
        rc = guard_fail("WriteProcessMemory failed", GetLastError());
        goto out;
    }
    FlushInstructionCache(hp, (void *)pg, 0xB00);

    HANDLE ht = CreateRemoteThread(hp, NULL, 0, (LPTHREAD_START_ROUTINE)pg, NULL, 0, NULL);
    if (!ht) { rc = guard_fail("CreateRemoteThread failed", GetLastError()); goto out; }
    DWORD waited = WaitForSingleObject(ht, 10000);
    CloseHandle(ht);
    if (waited != WAIT_OBJECT_0) { rc = guard_fail("Adaptive guard registration thread did not complete.", 0); goto out; }

    DWORD old;
    if (!VirtualProtectEx(hp, (void *)pg, 0x2000, PAGE_EXECUTE_READ, &old)) {
        rc = guard_fail("Could not make the adaptive guard page read/execute-only", GetLastError());
        goto out;
    }
    snprintf(detail, cap, "remotePage=0x%llX handler=0x%llX scratch=0x%llX fifaRange=0x%llX-0x%llX",
             (unsigned long long)pg, (unsigned long long)handler, (unsigned long long)scratch,
             (unsigned long long)fifa_base, (unsigned long long)fifa_end);
    rc = 0;
out:
    CloseHandle(hp);
    return rc;
}

static int refut_guard(int argc, wchar_t **argv)
{
    wchar_t log[MAX_PATH] = L"";
    for (int i = 1; i + 1 < argc; i++)
        if (!_wcsicmp(argv[i], L"-LogPath") && argv[i + 1][0]) {
            wcsncpy(log, argv[i + 1], MAX_PATH - 1);
            log[MAX_PATH - 1] = 0;
        }
    if (!log[0]) {
        DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", log, MAX_PATH);
        if (!n || n >= MAX_PATH - 40) return guard_fail("LOCALAPPDATA is not set.", 0);
        wcscat(log, L"\\REFUT\\Logs\\match-end-guard.log");
    }
    make_parents(log);
    guard_log = _wfopen(log, L"ab");

    guard_line("[V40] Adaptive runtime-only FIFA20 crash guard starting.");
    guard_line("[V40] Hash whitelist removed: the guard is semantic, not RVA/hash based.");
    guard_line("[V40] Rule: only a FIFA20.exe RIP access violation READ at address 0x48 with RAX=0 is recovered.");
    guard_line("[V40] Known reference build SHA256: " GUARD_REFERENCE_SHA256);
    guard_line("[V40] Historical reference evidence: fault RVA 0x%X; preceding call RVA 0x%X", 0xE0C7C0, 0xD88210);
    guard_line("[V40] Waiting for FIFA20.exe.");

    DWORD patched[64];
    int npatched = 0;
    DWORD stable_pid = 0;
    ULONGLONG stable_since = 0, deadline = GetTickCount64() + 3 * 60 * 1000;

    while (GetTickCount64() < deadline) {
        HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        PROCESSENTRY32W e;
        e.dwSize = sizeof e;
        for (BOOL more = s != INVALID_HANDLE_VALUE && Process32FirstW(s, &e); more; more = Process32NextW(s, &e)) {
            if (_wcsicmp(e.szExeFile, L"FIFA20.exe")) continue;
            DWORD pid = e.th32ProcessID;
            int seen = 0;
            for (int i = 0; i < npatched; i++) seen |= patched[i] == pid;
            if (seen) continue;

            ULONG_PTR base;
            DWORD size;
            wchar_t exe[MAX_PATH];
            char hash[65] = "", detail[256];
            if (!module_info(pid, L"FIFA20.exe", &base, &size, exe)) {
                CloseHandle(s);
                return guard_fail("Module not found: FIFA20.exe", 0);
            }
            if (!file_sha256(exe, hash)) {
                CloseHandle(s);
                return guard_fail("Could not hash FIFA20.exe", GetLastError());
            }
            if (guard_install(pid, base, size, detail, sizeof detail)) {
                CloseHandle(s);
                return 1;
            }
            if (npatched < 64) patched[npatched++] = pid;
            stable_pid = pid;
            stable_since = GetTickCount64();
            if (!strcmp(hash, GUARD_REFERENCE_SHA256))
                guard_line("[PATCHED] FIFA20.exe PID %lu reference-build exact historical case + adaptive guard: %s",
                           (unsigned long)pid, detail);
            else
                guard_line("[PATCHED] FIFA20.exe PID %lu adaptive build SHA256=%s: %s", (unsigned long)pid, hash, detail);
        }
        if (s != INVALID_HANDLE_VALUE) CloseHandle(s);

        if (stable_pid) {
            if (!pid_alive(stable_pid)) {
                guard_line("[WAIT] PID %lu exited during launch hand-off; waiting for replacement.", (unsigned long)stable_pid);
                stable_pid = 0;
            } else if (GetTickCount64() - stable_since >= 8000) {
                guard_line("[STABLE] V40 adaptive guard resident in FIFA20.exe PID %lu. Gameplay polling is not running.",
                           (unsigned long)stable_pid);
                guard_line("[STABLE] No FIFA20.exe file was modified on disk.");
                return 0;
            }
        }
        Sleep(250);
    }
    return guard_fail("Timed out waiting for FIFA20.exe. Nothing was changed on disk.", 0);
}

/* "-Command exit N" (one argument or two): REFUT's check that PowerShell runs. */
static int exit_probe(int argc, wchar_t **argv, int *code)
{
    for (int i = 1; i < argc; i++) {
        if (_wcsicmp(argv[i], L"-Command") && _wcsicmp(argv[i], L"-c")) continue;
        wchar_t text[64] = L"";
        for (int j = i + 1; j < argc; j++) {
            if (wcslen(text) + wcslen(argv[j]) + 2 >= 64) return 0;
            if (text[0]) wcscat(text, L" ");
            wcscat(text, argv[j]);
        }
        wchar_t *p = text, *end;
        while (iswspace(*p)) p++;
        if (_wcsnicmp(p, L"exit", 4) || !iswspace(p[4])) return 0;
        long n = wcstol(p + 4, &end, 10);
        if (end == p + 4) return 0;
        while (iswspace(*end) || *end == L';') end++;
        if (*end) return 0;
        *code = (int)n;
        return 1;
    }
    return 0;
}

int wmain(int argc, wchar_t **argv)
{
    const wchar_t *cmd = GetCommandLineW();
    int code;
    if (wcsstr(cmd, GUARD_SCRIPT))
        return refut_guard(argc, argv);
    if (exit_probe(argc, argv, &code))
        return code;
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
