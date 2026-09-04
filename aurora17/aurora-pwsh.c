/*
 * aurora-pwsh - a stand-in for powershell.exe inside a wine bottle.
 *
 * Wine ships programs/powershell as a stub that prints a FIXME and returns 0.
 * Aurora17Connector's PLAY button runs
 *
 *   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
 *                  -File <root>\scripts\Play.ps1
 *                  -ConnectorExecutable <exe> -PreserveConnectorProcessId <pid>
 *
 * and only checks the exit code, so the stub's silent 0 reads as success and the
 * launcher does nothing at all. This program implements the three Aurora17 scripts
 * natively so the launcher's own buttons work, without a PowerShell in the bottle.
 *
 * Anything it does not implement fails loudly with a non-zero exit code, so the
 * launcher reports a real error instead of silently succeeding.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <tlhelp32.h>
#include <shlobj.h>
#include <bcrypt.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <ctype.h>

#define CONTROL_PORT   47170
#define CDN_PORT       47175
#define SERVER_READY_TIMEOUT_MS  (4 * 60 * 1000)
#define FIFA_LAUNCH_TIMEOUT_MS   (5 * 60 * 1000)
#define LICENCE_SEED_TIMEOUT_MS  (30 * 1000)
/* How long after the launch a disappearing FIFA17.exe still counts as "it never
 * really started" rather than "the player quit". BUGS.md §18's game died 17-25 s
 * in, every time. */
#define FIFA_EARLY_QUIT_MS       (60 * 1000)
/* How many times one PLAY will relaunch on the code 25 start-up race before it
 * gives up and reports. At the measured ~14% per-launch success this takes a
 * user-visible launch to roughly 50%. */
#define FIFA_LAUNCH_ATTEMPTS     4

/* Distinct error codes */
#define ERR_MUTEX_LOCKED         10
#define ERR_PORT_UNOWNED         11
#define ERR_SERVER_START_FAIL    12
#define ERR_SERVER_TIMEOUT       13
#define ERR_KEY_FAIL             14
#define ERR_HEAD_CACHE           15
#define ERR_FIFA_RUNNING         16
#define ERR_ENROLL_FAIL          17
#define ERR_CONNECTOR_FAIL       18
#define ERR_CONNECTOR_MISSING    19
#define ERR_FIFA_TIMEOUT         20
#define ERR_RESET_CLUB_FAIL      21
#define ERR_PKI_MISSING          22
#define ERR_UNSUPPORTED_CMD      23
#define ERR_LICENCE_MISSING      24
#define ERR_FIFA_QUIT_EARLY      25

/* ------------------------------------------------------------------ output */

static void out(const wchar_t *fmt, ...)
{
    wchar_t buf[4096];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(buf, 4095, fmt, ap);
    va_end(ap);
    buf[4095] = 0;
    char utf8[8192];
    int n = WideCharToMultiByte(CP_UTF8, 0, buf, -1, utf8, sizeof(utf8) - 1, NULL, NULL);
    if (n > 0) { fwrite(utf8, 1, n - 1, stdout); fflush(stdout); }
}

static int fail_code(int code, const wchar_t *fmt, ...)
{
    wchar_t buf[4096];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(buf, 4095, fmt, ap);
    va_end(ap);
    buf[4095] = 0;
    out(L"ERROR [Code %d]: %s\n", code, buf);
    return code;
}

static int fail(const wchar_t *fmt, ...)
{
    wchar_t buf[4096];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(buf, 4095, fmt, ap);
    va_end(ap);
    buf[4095] = 0;
    out(L"ERROR: %s\n", buf);
    return 1;
}

/* -------------------------------------------------------------------- http */

/* Minimal HTTP/1.1 client for loopback JSON. Returns the status code, or 0 on a
 * transport failure; the body (NUL terminated) is written to *body_out, which the
 * caller frees. */
static int http_request(const char *method, int port, const char *path,
                        const char *control_key, const char *content_type,
                        const char *body, int timeout_ms, char **body_out)
{
    if (body_out) *body_out = NULL;

    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return 0;

    struct sockaddr_in sa;
    ZeroMemory(&sa, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((u_short)port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    DWORD tv = (DWORD)timeout_ms;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof(tv));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&tv, sizeof(tv));

    if (connect(s, (struct sockaddr *)&sa, sizeof(sa)) != 0) { closesocket(s); return 0; }

    char req[8192];
    int blen = body ? (int)strlen(body) : 0;
    int n = _snprintf(req, sizeof(req) - 1,
        "%s %s HTTP/1.1\r\n"
        "Host: 127.0.0.1:%d\r\n"
        "Connection: close\r\n"
        "Accept: */*\r\n"
        "User-Agent: aurora-pwsh/1.0\r\n",
        method, path, port);
    if (control_key && *control_key)
        n += _snprintf(req + n, sizeof(req) - 1 - n, "X-Aurora17-Control-Key: %s\r\n", control_key);
    if (content_type && blen)
        n += _snprintf(req + n, sizeof(req) - 1 - n, "Content-Type: %s\r\n", content_type);
    n += _snprintf(req + n, sizeof(req) - 1 - n, "Content-Length: %d\r\n\r\n", blen);
    if (blen) n += _snprintf(req + n, sizeof(req) - 1 - n, "%s", body);

    int sent = 0;
    while (sent < n)
    {
        int k = send(s, req + sent, n - sent, 0);
        if (k <= 0) { closesocket(s); return 0; }
        sent += k;
    }

    size_t cap = 65536, len = 0;
    char *buf = malloc(cap);
    if (!buf) { closesocket(s); return 0; }
    for (;;)
    {
        if (len + 8192 + 1 > cap)
        {
            size_t ncap = cap * 2;
            char *nb = realloc(buf, ncap);
            if (!nb) break;
            buf = nb; cap = ncap;
        }
        int k = recv(s, buf + len, 8192, 0);
        if (k <= 0) break;
        len += (size_t)k;
    }
    buf[len] = 0;
    closesocket(s);

    int status = 0;
    if (len > 12 && !strncmp(buf, "HTTP/1.", 7)) status = atoi(buf + 9);

    char *sep = strstr(buf, "\r\n\r\n");
    char *payload = sep ? sep + 4 : buf;

    /* de-chunk if needed */
    int chunked = 0;
    if (sep)
    {
        size_t hlen = (size_t)(sep - buf);
        for (size_t i = 0; i + 26 < hlen; i++)
            if (!_strnicmp(buf + i, "Transfer-Encoding:", 18) &&
                strstr(buf + i, "chunked") && strstr(buf + i, "chunked") < buf + hlen)
            { chunked = 1; break; }
    }
    if (chunked)
    {
        char *dec = malloc(len + 1);
        size_t dl = 0;
        char *p = payload;
        while (p && *p)
        {
            long csz = strtol(p, NULL, 16);
            char *crlf = strstr(p, "\r\n");
            if (!crlf || csz <= 0) break;
            p = crlf + 2;
            if (dec) { memcpy(dec + dl, p, (size_t)csz); dl += (size_t)csz; }
            p += csz;
            if (!strncmp(p, "\r\n", 2)) p += 2;
        }
        if (dec) { dec[dl] = 0; free(buf); buf = dec; payload = dec; }
    }

    if (body_out)
    {
        size_t plen = strlen(payload);
        char *o = malloc(plen + 1);
        if (o) { memcpy(o, payload, plen + 1); *body_out = o; }
    }
    if (payload != buf) { /* dec branch already owns buf */ }
    free(buf);
    return status;
}

static BOOL port_is_listening(int port)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return FALSE;
    struct sockaddr_in sa;
    ZeroMemory(&sa, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((u_short)port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    DWORD tv = 1500;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof(tv));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&tv, sizeof(tv));
    BOOL ok = connect(s, (struct sockaddr *)&sa, sizeof(sa)) == 0;
    closesocket(s);
    return ok;
}

/* -------------------------------------------------------------------- json */

/* Finds "key" and returns the string value that follows, or NULL. Good enough for
 * the small, flat control-API documents this talks to. */
static char *json_string(const char *json, const char *key)
{
    char pat[128];
    _snprintf(pat, sizeof(pat) - 1, "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return NULL;
    p += strlen(pat);
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (*p != ':') return NULL;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (*p != '"') return NULL;
    p++;
    const char *e = p;
    while (*e && *e != '"') { if (*e == '\\' && e[1]) e++; e++; }
    size_t n = (size_t)(e - p);
    char *o = malloc(n + 1);
    if (!o) return NULL;
    memcpy(o, p, n);
    o[n] = 0;
    return o;
}

static BOOL json_true(const char *json, const char *key)
{
    char pat[128];
    _snprintf(pat, sizeof(pat) - 1, "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return FALSE;
    p += strlen(pat);
    while (*p == ' ' || *p == ':' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    return !strncmp(p, "true", 4);
}

static BOOL is_hex32(const char *s)
{
    if (!s) return FALSE;
    int n = 0;
    for (; s[n]; n++)
        if (!isxdigit((unsigned char)s[n])) return FALSE;
    return n == 32;
}

/* ------------------------------------------------------------------- paths */

static void join(wchar_t *dst, size_t cap, const wchar_t *a, const wchar_t *b)
{
    _snwprintf(dst, cap - 1, L"%s\\%s", a, b);
    dst[cap - 1] = 0;
}

static BOOL file_exists(const wchar_t *p)
{
    DWORD a = GetFileAttributesW(p);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

static BOOL dir_exists(const wchar_t *p)
{
    DWORD a = GetFileAttributesW(p);
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}

static void ensure_dir(const wchar_t *p)
{
    if (dir_exists(p)) return;
    wchar_t tmp[MAX_PATH];
    wcsncpy(tmp, p, MAX_PATH - 1);
    tmp[MAX_PATH - 1] = 0;
    for (wchar_t *q = tmp + 3; *q; q++)
    {
        if (*q == L'\\') { *q = 0; CreateDirectoryW(tmp, NULL); *q = L'\\'; }
    }
    CreateDirectoryW(tmp, NULL);
}

static char *read_all_utf8(const wchar_t *path, size_t *len_out)
{
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return NULL;
    DWORD sz = GetFileSize(h, NULL);
    if (sz == INVALID_FILE_SIZE || sz > 8u * 1024 * 1024) { CloseHandle(h); return NULL; }
    char *b = malloc(sz + 1);
    if (!b) { CloseHandle(h); return NULL; }
    DWORD rd = 0;
    ReadFile(h, b, sz, &rd, NULL);
    b[rd] = 0;
    CloseHandle(h);
    if (len_out) *len_out = rd;
    return b;
}

static BOOL write_all_utf8(const wchar_t *path, const char *text)
{
    HANDLE h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    DWORD wr = 0;
    BOOL ok = WriteFile(h, text, (DWORD)strlen(text), &wr, NULL);
    CloseHandle(h);
    return ok;
}

/* ---------------------------------------------------------------- processes */

typedef struct { DWORD pid; ULONGLONG start; } procid;

static ULONGLONG process_start(HANDLE p)
{
    FILETIME c, e, k, u;
    if (!GetProcessTimes(p, &c, &e, &k, &u)) return 0;
    ULARGE_INTEGER v;
    v.LowPart = c.dwLowDateTime;
    v.HighPart = c.dwHighDateTime;
    return v.QuadPart;
}

/* Collects every running process whose image name matches, newest last. */
static int find_processes(const wchar_t *exe_name, procid *out_list, int cap)
{
    int n = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W pe;
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe))
    {
        do {
            if (_wcsicmp(pe.szExeFile, exe_name)) continue;
            if (n >= cap) break;
            HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
            ULONGLONG st = 0;
            if (h) { st = process_start(h); CloseHandle(h); }
            out_list[n].pid = pe.th32ProcessID;
            out_list[n].start = st;
            n++;
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return n;
}

static BOOL process_is(DWORD pid, const wchar_t *exe_name, ULONGLONG expect_start)
{
    procid list[64];
    int n = find_processes(exe_name, list, 64);
    for (int i = 0; i < n; i++)
        if (list[i].pid == pid && (!expect_start || list[i].start == expect_start))
            return TRUE;
    return FALSE;
}

static void kill_pid(DWORD pid)
{
    HANDLE h = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pid);
    if (!h) return;
    TerminateProcess(h, 1);
    WaitForSingleObject(h, 10000);
    CloseHandle(h);
}

/* Starts a child, optionally redirecting its stdout/stderr to files and its stdin
 * from one. Returns the process handle, or NULL. */
static HANDLE spawn(const wchar_t *cmdline, const wchar_t *cwd,
                    const wchar_t *stdout_path, const wchar_t *stderr_path,
                    const wchar_t *stdin_path, DWORD *pid_out)
{
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = TRUE;

    HANDLE ho = INVALID_HANDLE_VALUE, he = INVALID_HANDLE_VALUE, hi = INVALID_HANDLE_VALUE;
    if (stdout_path)
        ho = CreateFileW(stdout_path, GENERIC_WRITE, FILE_SHARE_READ, &sa,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (stderr_path)
        he = CreateFileW(stderr_path, GENERIC_WRITE, FILE_SHARE_READ, &sa,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (stdin_path)
        hi = CreateFileW(stdin_path, GENERIC_READ, FILE_SHARE_READ, &sa,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);

    BOOL inherit = FALSE;
    if (ho != INVALID_HANDLE_VALUE || he != INVALID_HANDLE_VALUE || hi != INVALID_HANDLE_VALUE)
    {
        si.dwFlags |= STARTF_USESTDHANDLES;
        si.hStdInput  = (hi != INVALID_HANDLE_VALUE) ? hi : GetStdHandle(STD_INPUT_HANDLE);
        si.hStdOutput = (ho != INVALID_HANDLE_VALUE) ? ho : GetStdHandle(STD_OUTPUT_HANDLE);
        si.hStdError  = (he != INVALID_HANDLE_VALUE) ? he : si.hStdOutput;
        inherit = TRUE;
    }

    wchar_t mutable_cmd[4096];
    wcsncpy(mutable_cmd, cmdline, 4095);
    mutable_cmd[4095] = 0;

    BOOL ok = CreateProcessW(NULL, mutable_cmd, NULL, NULL, inherit,
                             CREATE_NO_WINDOW, NULL, cwd, &si, &pi);
    DWORD err = GetLastError();
    if (ho != INVALID_HANDLE_VALUE) CloseHandle(ho);
    if (he != INVALID_HANDLE_VALUE) CloseHandle(he);
    if (hi != INVALID_HANDLE_VALUE) CloseHandle(hi);
    if (!ok) { SetLastError(err); return NULL; }
    CloseHandle(pi.hThread);
    if (pid_out) *pid_out = pi.dwProcessId;
    return pi.hProcess;
}

/* ------------------------------------------------------------------ licence */

/* BUGS.md §18. Aurora's connector starts FIFA17.exe directly, and FIFA 17 only
 * takes its normal start-up path when EA's licence file is present:
 *
 *   C:\ProgramData\Electronic Arts\EA Services\License\1027460.dlf
 *
 * Without it the game goes into Origin activation, relaunches itself, and the
 * first process -- the one the connector is bound to -- exits 0xFFFFFFFA about
 * twenty seconds in. The connector then discards the session and the launcher
 * sits on "WORKING..." forever. The game's own loader, _fifa17.exe, writes the
 * file within a few seconds of starting, so one loader run per bottle is the
 * whole fix. The file is not machine-bound; it is the same bytes in every
 * bottle that has ever worked. */

static void licence_file_path(wchar_t *dst, size_t cap)
{
    wchar_t programdata[MAX_PATH];
    if (!GetEnvironmentVariableW(L"ProgramData", programdata, MAX_PATH))
        wcscpy(programdata, L"C:\\ProgramData");
    _snwprintf(dst, cap - 1, L"%s\\Electronic Arts\\EA Services\\License\\1027460.dlf", programdata);
    dst[cap - 1] = 0;
}

static BOOL licence_present(void)
{
    wchar_t lic[MAX_PATH];
    licence_file_path(lic, MAX_PATH);
    return file_exists(lic);
}

/* The connector records the folder it launches the game from; that is where
 * _fifa17.exe is. The value arrives as JSON, so its separators are doubled. */
static BOOL connector_game_dir(const wchar_t *localappdata, wchar_t *dst, size_t cap)
{
    wchar_t conn[MAX_PATH];
    join(conn, MAX_PATH, localappdata, L"Aurora17\\Connector\\connector.json");
    char *j = read_all_utf8(conn, NULL);
    if (!j) return FALSE;
    char *raw = json_string(j, "gameDirectory");
    free(j);
    if (!raw) return FALSE;

    char clean[1024];
    size_t n = 0;
    for (const char *q = raw; *q && n + 1 < sizeof(clean); q++)
    {
        if (*q == '\\' && q[1]) { clean[n++] = q[1]; q++; }
        else clean[n++] = *q;
    }
    clean[n] = 0;
    free(raw);
    if (!n) return FALSE;
    return MultiByteToWideChar(CP_UTF8, 0, clean, -1, dst, (int)cap) > 0;
}

static int kill_all(const wchar_t *exe_name)
{
    procid list[16];
    int n = find_processes(exe_name, list, 16);
    for (int i = 0; i < n; i++) kill_pid(list[i].pid);
    return n;
}

/* The loader starts the game, so stopping it means stopping both, and the next
 * step refuses to run while any FIFA17.exe is left. */
static void stop_loader_tree(void)
{
    for (int round = 0; round < 30; round++)
    {
        if (!(kill_all(L"FIFA17.exe") + kill_all(L"_fifa17.exe"))) return;
        Sleep(500);
    }
}

/* Returns 0 when the bottle has a licence file, seeding one if it can. */
static int ensure_licence(const wchar_t *localappdata)
{
    wchar_t lic[MAX_PATH];
    licence_file_path(lic, MAX_PATH);
    if (file_exists(lic)) return 0;

    procid running[8];
    if (find_processes(L"FIFA17.exe", running, 8) > 0)
    {
        /* A running game writes the file itself; killing it to seed one would
         * be worse than going on without. */
        out(L"FIFA 17 is already running, so the licence file is left to it.\n");
        return 0;
    }

    wchar_t gamedir[MAX_PATH], loader[MAX_PATH];
    BOOL have_dir = connector_game_dir(localappdata, gamedir, MAX_PATH);
    if (have_dir) join(loader, MAX_PATH, gamedir, L"_fifa17.exe");
    if (!have_dir || !file_exists(loader))
        return fail_code(ERR_LICENCE_MISSING,
            L"FIFA 17 has no licence file in this bottle and no _fifa17.exe to make one. "
            L"Start FIFA 17 once from CrossOver, then PLAY again.");

    out(L"Seeding the FIFA 17 licence file (first launch in this bottle)...\n");
    wchar_t cmd[MAX_PATH + 8];
    _snwprintf(cmd, MAX_PATH + 7, L"\"%s\"", loader);
    cmd[MAX_PATH + 7] = 0;
    DWORD pid = 0;
    HANDLE h = spawn(cmd, gamedir, NULL, NULL, NULL, &pid);
    if (!h)
        return fail_code(ERR_LICENCE_MISSING,
            L"Windows did not start the FIFA 17 loader %s (%lu), so this bottle still has no "
            L"licence file. Start FIFA 17 once from CrossOver, then PLAY again.",
            loader, GetLastError());
    CloseHandle(h);

    BOOL made = FALSE;
    for (DWORD waited = 0; waited < LICENCE_SEED_TIMEOUT_MS; waited += 250)
    {
        Sleep(250);
        if (file_exists(lic)) { made = TRUE; break; }
    }
    stop_loader_tree();

    if (!made)
        return fail_code(ERR_LICENCE_MISSING,
            L"The FIFA 17 loader ran for %d seconds but did not write %s. Start FIFA 17 once "
            L"from CrossOver, let it reach its menu, then PLAY again.",
            LICENCE_SEED_TIMEOUT_MS / 1000, lic);

    out(L"Licence file written; the loader has been stopped.\n");
    return 0;
}

/* FIFA is gone within a minute of the launch. Which of the two failures is it?
 * `attempts` is how many launches this PLAY made, so the code 25 text says out loud
 * that the retry ran and how often. */
static int fifa_quit_early(DWORD seconds, DWORD connector_code, BOOL have_connector_code,
                           int attempts)
{
    wchar_t lic[MAX_PATH];
    licence_file_path(lic, MAX_PATH);
    if (!file_exists(lic))
        return fail_code(ERR_LICENCE_MISSING,
            L"FIFA 17 quit %lu seconds after starting and this bottle still has no licence file "
            L"at %s. That is the Origin activation path: the game relaunches itself and the "
            L"process Aurora17 is watching exits 0xFFFFFFFA. Start FIFA 17 once from CrossOver, "
            L"then PLAY again.", (unsigned long)seconds, lic);

    wchar_t tried[192];
    if (attempts > 1)
        _snwprintf(tried, 191,
                   L"FIFA 17 was launched %d times and quit %lu seconds in on the last try",
                   attempts, (unsigned long)seconds);
    else
        _snwprintf(tried, 191, L"FIFA 17 quit %lu seconds after starting",
                   (unsigned long)seconds);
    tried[191] = 0;

    if (have_connector_code)
        return fail_code(ERR_FIFA_QUIT_EARLY,
            L"%s; the Aurora17 launch connector exited with code %lu (0x%08lx). If you closed "
            L"FIFA yourself, ignore this. Otherwise see the newest client-*.log in "
            L"%%LOCALAPPDATA%%\\Aurora17\\Logs.",
            tried, (unsigned long)connector_code, (unsigned long)connector_code);
    return fail_code(ERR_FIFA_QUIT_EARLY,
            L"%s (the launch connector still owns the process, so its exit code is not visible "
            L"here). If you closed FIFA yourself, ignore this. Otherwise see the newest "
            L"client-*.log in %%LOCALAPPDATA%%\\Aurora17\\Logs.", tried);
}

/* --------------------------------------------------------------- shim state */

/* Our own receipt. Play.ps1's play-session.json is left untouched so a real
 * PowerShell, if one is ever installed, still owns its own file. */
static wchar_t g_state_file[MAX_PATH];

static void state_read(DWORD *server_pid, ULONGLONG *server_start,
                       DWORD *launch_pid, ULONGLONG *launch_start)
{
    *server_pid = 0; *server_start = 0; *launch_pid = 0; *launch_start = 0;
    char *j = read_all_utf8(g_state_file, NULL);
    if (!j) return;
    char *v;
    if ((v = json_string(j, "serverPid")))   { *server_pid   = (DWORD)strtoul(v, NULL, 10); free(v); }
    if ((v = json_string(j, "serverStart"))) { *server_start = _strtoui64(v, NULL, 10); free(v); }
    if ((v = json_string(j, "launchPid")))   { *launch_pid   = (DWORD)strtoul(v, NULL, 10); free(v); }
    if ((v = json_string(j, "launchStart"))) { *launch_start = _strtoui64(v, NULL, 10); free(v); }
    free(j);
}

static void state_write(DWORD server_pid, ULONGLONG server_start,
                        DWORD launch_pid, ULONGLONG launch_start)
{
    char buf[512];
    _snprintf(buf, sizeof(buf) - 1,
        "{\n  \"schemaVersion\": \"1\",\n  \"writer\": \"aurora-pwsh\",\n"
        "  \"serverPid\": \"%lu\",\n  \"serverStart\": \"%llu\",\n"
        "  \"launchPid\": \"%lu\",\n  \"launchStart\": \"%llu\"\n}\n",
        (unsigned long)server_pid, (unsigned long long)server_start,
        (unsigned long)launch_pid, (unsigned long long)launch_start);
    write_all_utf8(g_state_file, buf);
}

/* ------------------------------------------------------------ control key */

static BOOL load_control_key(const wchar_t *localappdata, char *key_out, size_t cap)
{
    wchar_t dir[MAX_PATH], file[MAX_PATH];
    join(dir, MAX_PATH, localappdata, L"Aurora17");
    ensure_dir(dir);
    join(file, MAX_PATH, dir, L"control-key.txt");

    char *existing = read_all_utf8(file, NULL);
    if (existing)
    {
        char *p = existing;
        /* Skip a whole UTF-8 BOM, not just its first byte. Stopping on 0xBB left
         * clean[] empty, which fell through to minting a NEW key over a file the
         * running server and the connector were still authenticating against. */
        if ((unsigned char)p[0] == 0xEF && (unsigned char)p[1] == 0xBB && (unsigned char)p[2] == 0xBF) p += 3;
        while (*p == ' ' || *p == '\r' || *p == '\n' || *p == '\t') p++;
        char clean[128];
        int n = 0;
        while (*p && isxdigit((unsigned char)*p) && n < 127) clean[n++] = *p++;
        clean[n] = 0;
        free(existing);
        if (n == 64) { strncpy(key_out, clean, cap - 1); key_out[cap - 1] = 0; return TRUE; }
        /* Play.ps1 throws here ("The Aurora17 control key is malformed; it will
         * not be used.") rather than replacing the file. Match it: silently
         * re-minting the key is what makes an already-running server answer 403. */
        return FALSE;
    }

    unsigned char raw[32];
    NTSTATUS st = BCryptGenRandom(NULL, raw, sizeof(raw), BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (st != 0)
    {
        /* Wine always has RtlGenRandom; fall back to it rather than to a weak source. */
        HMODULE adv = LoadLibraryW(L"advapi32.dll");
        BOOLEAN (WINAPI *genrandom)(PVOID, ULONG) = NULL;
        if (adv) genrandom = (void *)GetProcAddress(adv, "SystemFunction036");
        if (!genrandom || !genrandom(raw, sizeof(raw))) return FALSE;
    }
    char hex[65];
    for (int i = 0; i < 32; i++) _snprintf(hex + i * 2, 3, "%02x", raw[i]);
    hex[64] = 0;
    SecureZeroMemory(raw, sizeof(raw));
    if (!write_all_utf8(file, hex)) return FALSE;
    strncpy(key_out, hex, cap - 1);
    key_out[cap - 1] = 0;
    return TRUE;
}

/* ------------------------------------------------------------ server health */

/* What the last probe saw, so a failure can name the condition that did not hold
 * instead of only reporting that four minutes elapsed. */
typedef struct {
    int  status;          /* HTTP status, or 0 for a transport failure */
    char detail[320];     /* the first condition that did not hold */
} health_probe;

/* Mirrors Play.ps1's Get-AuthenticatedServerHealth: a 200 is not enough, the
 * identity fields have to match too, so a foreign server is never mistaken for ours. */
static BOOL server_probe(const char *key, health_probe *p)
{
    if (p)
    {
        p->status = 0;
        strcpy(p->detail, "no reply from 127.0.0.1:47170 within 5 s (connect or read failed)");
    }

    char *body = NULL;
    int st = http_request("GET", CONTROL_PORT, "/v1/health", key, NULL, NULL, 5000, &body);
    if (p) p->status = st;
    if (st != 200 || !body)
    {
        if (p && (st == 401 || st == 403))
            _snprintf(p->detail, sizeof(p->detail) - 1,
                      "HTTP %d on GET /v1/health, expected 200 - the server on 47170 rejected this "
                      "control key, i.e. it was started with a different one", st);
        else if (p && st)
            _snprintf(p->detail, sizeof(p->detail) - 1,
                      "HTTP %d on GET /v1/health, expected 200", st);
        if (p) p->detail[sizeof(p->detail) - 1] = 0;
        free(body);
        return FALSE;
    }

    BOOL ok = FALSE;
    char *product = json_string(body, "product");
    char *id = json_string(body, "id");
    char *version = json_string(body, "version");
    char *build = json_string(body, "buildId");
    char *nonce = json_string(body, "instanceNonce");
    char *schema = json_string(body, "schemaVersion");
    BOOL ready = json_true(body, "ready");
    BOOL schema_ok = strstr(body, "\"schemaVersion\": 1") || strstr(body, "\"schemaVersion\":1") ||
                     (schema && !strcmp(schema, "1"));

    if (product && !strcmp(product, "aurora17-server") &&
        id && !strcmp(id, "Aurora17.Server") &&
        version && *version &&
        is_hex32(build) && is_hex32(nonce) &&
        schema_ok && ready)
        ok = TRUE;

    if (p && !ok)
    {
        /* Name the first condition that did not hold, observed against expected. */
        if (!product || strcmp(product, "aurora17-server"))
            _snprintf(p->detail, sizeof(p->detail) - 1,
                      "product=\"%s\", expected \"aurora17-server\" - a foreign process answers on 47170",
                      product ? product : "(absent)");
        else if (!id || strcmp(id, "Aurora17.Server"))
            _snprintf(p->detail, sizeof(p->detail) - 1,
                      "package.id=\"%s\", expected \"Aurora17.Server\"", id ? id : "(absent)");
        else if (!version || !*version)
            _snprintf(p->detail, sizeof(p->detail) - 1, "package.version was empty or absent");
        else if (!is_hex32(build))
            _snprintf(p->detail, sizeof(p->detail) - 1,
                      "package.buildId=\"%s\", expected 32 hex digits", build ? build : "(absent)");
        else if (!is_hex32(nonce))
            _snprintf(p->detail, sizeof(p->detail) - 1,
                      "process.instanceNonce=\"%s\", expected 32 hex digits", nonce ? nonce : "(absent)");
        else if (!schema_ok)
            _snprintf(p->detail, sizeof(p->detail) - 1,
                      "state.schemaVersion=\"%s\", expected 1", schema ? schema : "(absent)");
        else
            _snprintf(p->detail, sizeof(p->detail) - 1,
                      "readiness.ready was not true - HTTP 200 and every identity field matched, so this "
                      "is our server and it has not finished starting");
        p->detail[sizeof(p->detail) - 1] = 0;
    }

    free(product); free(id); free(version); free(build); free(nonce); free(schema); free(body);
    return ok;
}

static BOOL server_healthy(const char *key)
{
    return server_probe(key, NULL);
}

/* ------------------------------------------------------------- head cache */

/* Deletes everything inside `dir`, depth first, keeping `dir` itself. Returns TRUE
 * when it ends up empty; on FALSE, *first_err (when given) holds the Win32 error of
 * the first thing that would not go. Deliberately plain Win32 - no SHFileOperation,
 * so no new library dependency. */
static BOOL remove_tree_contents(const wchar_t *dir, DWORD *first_err)
{
    wchar_t pattern[MAX_PATH];
    _snwprintf(pattern, MAX_PATH - 1, L"%s\\*", dir);
    pattern[MAX_PATH - 1] = 0;

    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE)
    {
        DWORD e = GetLastError();
        if (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND) return TRUE;
        if (first_err && !*first_err) *first_err = e;
        return FALSE;
    }

    BOOL all = TRUE;
    do {
        if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
        wchar_t child[MAX_PATH];
        join(child, MAX_PATH, dir, fd.cFileName);
        BOOL ok;
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
            !(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
        {
            /* Contents first; a directory only goes once it is empty. */
            ok = remove_tree_contents(child, first_err);
            if (!RemoveDirectoryW(child)) ok = FALSE;
        }
        else if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
            ok = RemoveDirectoryW(child);        /* a junction: unlink, never follow */
        else
        {
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_READONLY)
                SetFileAttributesW(child, fd.dwFileAttributes & ~(DWORD)FILE_ATTRIBUTE_READONLY);
            ok = DeleteFileW(child);
        }
        if (!ok)
        {
            if (first_err && !*first_err) *first_err = GetLastError();
            all = FALSE;
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return all;
}

static int refresh_player_head_cache(const char *generation)
{
    procid list[8];
    if (find_processes(L"FIFA17.exe", list, 8) > 0)
        return fail_code(ERR_FIFA_RUNNING, L"FIFA17 is running. Close it before refreshing the player-head cache.");

    wchar_t docs[MAX_PATH];
    if (FAILED(SHGetFolderPathW(NULL, CSIDL_PERSONAL, NULL, 0, docs)))
        return fail_code(ERR_HEAD_CACHE, L"Windows did not return a Documents directory.");

    wchar_t root[MAX_PATH], cache[MAX_PATH], marker[MAX_PATH];
    join(root, MAX_PATH, docs, L"FIFA 17\\filesystemcache");
    join(cache, MAX_PATH, root, L"atlFUTPlayerHeads");
    join(marker, MAX_PATH, root, L"aurora17-player-head-generation.txt");
    ensure_dir(root);

    if (generation && *generation && dir_exists(cache) && file_exists(marker))
    {
        char *cur = read_all_utf8(marker, NULL);
        if (cur)
        {
            char *e = cur + strlen(cur);
            while (e > cur && (e[-1] == '\r' || e[-1] == '\n' || e[-1] == ' ')) *--e = 0;
            BOOL same = !strcmp(cur, generation);
            free(cur);
            if (same)
            {
                out(L"Player-head cache already matches content generation %S.\n", generation);
                return 0;
            }
        }
    }

    if (!dir_exists(cache))
    {
        ensure_dir(cache);
        if (generation && *generation) write_all_utf8(marker, generation);
        out(L"Created empty player-head cache.\n");
        return 0;
    }

    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t quarantine[MAX_PATH];
    _snwprintf(quarantine, MAX_PATH - 1, L"%s\\atlFUTPlayerHeads.aurora17-stale-%04d%02d%02dT%02d%02d%02d%03d",
               root, st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);

    /* TODO item 6b. Player-head images are FUT player faces: cosmetic. A cache that
     * cannot be renamed is never a reason to refuse to start the game -- and it does
     * happen, because the bottle symlinks Documents out to the real ~/Documents, which
     * since Ventura sits behind macOS TCC and returns ERROR_ACCESS_DENIED (5).
     * MoveFileW -> empty in place -> warn and carry on. */
    BOOL quarantined = FALSE;
    if (dir_exists(quarantine))
        out(L"Warning: a player-head cache quarantine already exists at %s; emptying the "
            L"stale cache in place instead.\n", quarantine);
    else if (MoveFileW(cache, quarantine))
        quarantined = TRUE;
    else
        out(L"Warning: could not quarantine the stale player-head cache (%lu); emptying it "
            L"in place instead.\n", (unsigned long)GetLastError());

    if (!quarantined)
    {
        DWORD del_err = 0;
        if (!remove_tree_contents(cache, &del_err))
            out(L"Warning: some player-head cache files could not be deleted (%lu). Carrying "
                L"on -- player faces are cosmetic and some may be stale.\n",
                (unsigned long)del_err);
    }

    ensure_dir(cache);
    if (generation && *generation) write_all_utf8(marker, generation);
    if (quarantined)
        out(L"Quarantined the stale player-head cache and created an empty one.\n");
    else
        out(L"Refreshed the stale player-head cache in place.\n");
    return 0;
}

/* Pulls the live cfgrouting.xml and reads the fut2dheads.big generation from it,
 * exactly as Play.ps1 does, so a content rebuild evicts the loose cache. */
static BOOL read_head_generation(char *out_gen, size_t cap)
{
    char *xml = NULL;
    int st = http_request("GET", CDN_PORT, "/routing/cfgrouting.xml", NULL, NULL, NULL, 30000, &xml);
    if (st != 200 || !xml) { free(xml); return FALSE; }

    BOOL ok = FALSE;
    const char *p = strstr(xml, "fifa/dl/gen4/fut2dheads.big");
    if (p)
    {
        /* back up to the start of this <file .../> element, then read its attributes */
        const char *start = p;
        while (start > xml && *start != '<') start--;
        const char *end = strchr(p, '>');
        if (end)
        {
            char elem[2048];
            size_t n = (size_t)(end - start);
            if (n < sizeof(elem))
            {
                memcpy(elem, start, n);
                elem[n] = 0;
                const char *v = strstr(elem, "version=\"");
                const char *c = strstr(elem, "crc=\"");
                if (v && c)
                {
                    char ver[64], crc[64];
                    int i = 0;
                    for (v += 9; *v && *v != '"' && i < 63; v++) ver[i++] = *v;
                    ver[i] = 0;
                    i = 0;
                    for (c += 5; *c && *c != '"' && i < 63; c++) crc[i++] = *c;
                    crc[i] = 0;
                    if (*ver && *crc)
                    {
                        _snprintf(out_gen, cap - 1, "%s:%s", ver, crc);
                        out_gen[cap - 1] = 0;
                        ok = TRUE;
                    }
                }
            }
        }
    }
    free(xml);
    return ok;
}

/* ------------------------------------------------------------------ Play.ps1 */

static int start_server(const wchar_t *root, const wchar_t *localappdata, const char *key)
{
    wchar_t server_dir[MAX_PATH], server_exe[MAX_PATH];
    join(server_dir, MAX_PATH, root, L"server\\Aurora17Server");
    join(server_exe, MAX_PATH, server_dir, L"Aurora17.Server.exe");
    if (!file_exists(server_exe))
        return fail_code(ERR_SERVER_START_FAIL, L"The packaged Aurora17 server is missing: %s", server_exe);

    wchar_t logdir[MAX_PATH], log[MAX_PATH], errlog[MAX_PATH];
    join(logdir, MAX_PATH, localappdata, L"Aurora17\\Logs");
    ensure_dir(logdir);
    SYSTEMTIME st;
    GetLocalTime(&st);
    _snwprintf(log, MAX_PATH - 1, L"%s\\server-%04d%02d%02d-%02d%02d%02d.log",
               logdir, st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    _snwprintf(errlog, MAX_PATH - 1, L"%s.err", log);

    /* The server reads its control key from the environment; Play.ps1 sets the same
     * variable, and a key mismatch is what turns into "servers have been shut down". */
    wchar_t wkey[128];
    MultiByteToWideChar(CP_UTF8, 0, key, -1, wkey, 128);
    SetEnvironmentVariableW(L"AURORA17_Control__ControlKey", wkey);

    wchar_t cmd[MAX_PATH + 8];
    _snwprintf(cmd, MAX_PATH + 7, L"\"%s\"", server_exe);

    out(L"Starting the server...\n");
    DWORD pid = 0;
    HANDLE h = spawn(cmd, server_dir, log, errlog, NULL, &pid);
    if (!h) return fail_code(ERR_SERVER_START_FAIL, L"Windows did not start the Aurora17 server (%lu).", GetLastError());

    ULONGLONG start_time = process_start(h);
    DWORD sp, lp; ULONGLONG ss, ls;
    state_read(&sp, &ss, &lp, &ls);
    state_write(pid, start_time, lp, ls);

    DWORD waited = 0;
    health_probe probe;
    probe.status = 0;
    strcpy(probe.detail, "the readiness poll never ran");
    for (;;)
    {
        Sleep(2000);
        waited += 2000;
        if (WaitForSingleObject(h, 0) == WAIT_OBJECT_0)
        {
            DWORD code = 1;
            GetExitCodeProcess(h, &code);
            CloseHandle(h);
            return fail_code(ERR_SERVER_START_FAIL, L"The server exited during startup with code %lu. Log: %s", code, log);
        }
        char *text = read_all_utf8(log, NULL);
        if (text)
        {
            BOOL rejected = strstr(text, "Redirector listener not started:") != NULL;
            free(text);
            if (rejected)
            {
                kill_pid(pid);
                CloseHandle(h);
                return fail_code(ERR_SERVER_START_FAIL, L"The redirector listener was rejected during startup. Log: %s", log);
            }
        }
        if (server_probe(key, &probe)) break;
        if (waited >= SERVER_READY_TIMEOUT_MS)
        {
            /* Play.ps1's catch stops the server on every failure out of this
             * loop, and so must this: a server left listening on 47170 makes
             * the NEXT run take the "already listening but not healthy" branch
             * instead of starting cleanly. That was seen in the field -- a
             * Code 13 at 15:19 and, four minutes later, "A server is running
             * but was started with a different control key". One bug, twice. */
            kill_pid(pid);
            CloseHandle(h);
            /* On a working bottle the very first poll succeeds (~2 s against a
             * 240 s budget), so arriving here is never "the server was slow" --
             * it is a condition that was never going to become true. Say which. */
            wchar_t wdetail[512];
            MultiByteToWideChar(CP_UTF8, 0, probe.detail, -1, wdetail, 512);
            return fail_code(ERR_SERVER_TIMEOUT,
                L"The server did not pass its authenticated readiness check.\n"
                L"  Waited %lu s, polling GET http://127.0.0.1:%d/v1/health every 2 s.\n"
                L"  Last probe: %s\n"
                L"  The server process (pid %lu) has been stopped.\n"
                L"  Server log:    %s\n"
                L"  Server stderr: %s.err\n"
                L"  Control key:   %%LOCALAPPDATA%%\\Aurora17\\control-key.txt",
                (unsigned long)(waited / 1000), CONTROL_PORT, wdetail,
                (unsigned long)pid, log, log);
        }
    }
    CloseHandle(h);
    out(L"Server is up.\n");
    return 0;
}

static int run_play(const wchar_t *script_path, int argc, wchar_t **argv)
{
    BOOL server_only = FALSE;
    const wchar_t *connector_arg = NULL;
    DWORD preserve_pid = 0;

    for (int i = 0; i < argc; i++)
    {
        if (!_wcsicmp(argv[i], L"-ServerOnly")) server_only = TRUE;
        else if (!_wcsicmp(argv[i], L"-ConnectorExecutable") && i + 1 < argc) connector_arg = argv[++i];
        else if (!_wcsicmp(argv[i], L"-PreserveConnectorProcessId") && i + 1 < argc)
            preserve_pid = (DWORD)wcstoul(argv[++i], NULL, 10);
    }

    /* <root>\scripts\Play.ps1 -> <root> */
    wchar_t root[MAX_PATH];
    wcsncpy(root, script_path, MAX_PATH - 1);
    root[MAX_PATH - 1] = 0;
    wchar_t *slash = wcsrchr(root, L'\\');
    if (slash) *slash = 0;               /* strip Play.ps1  */
    slash = wcsrchr(root, L'\\');
    if (slash) *slash = 0;               /* strip \scripts  */
    if (!dir_exists(root)) return fail_code(ERR_CONNECTOR_MISSING, L"The Aurora17 installation could not be located: %s", root);

    wchar_t localappdata[MAX_PATH];
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", localappdata, MAX_PATH))
        return fail_code(ERR_KEY_FAIL, L"The current Windows LocalAppData folder could not be resolved.");

    wchar_t statedir[MAX_PATH];
    join(statedir, MAX_PATH, localappdata, L"Aurora17");
    ensure_dir(statedir);
    join(g_state_file, MAX_PATH, statedir, L"aurora-pwsh-session.json");

    HANDLE mutex = CreateMutexW(NULL, FALSE, L"Local\\Aurora17.PlayLifecycle.v1");
    BOOL held = FALSE;
    if (mutex)
    {
        DWORD w = WaitForSingleObject(mutex, 5000);
        held = (w == WAIT_OBJECT_0 || w == WAIT_ABANDONED);
    }
    if (!held) return fail_code(ERR_MUTEX_LOCKED, L"Another Aurora17 launch operation is already in progress.");

    int rc = 0;
    char key[128] = {0};
    if (!load_control_key(localappdata, key, sizeof(key)))
    { rc = fail_code(ERR_KEY_FAIL, L"The Aurora17 control key could not be created or read."); goto done; }

    wchar_t wkey[128];
    MultiByteToWideChar(CP_UTF8, 0, key, -1, wkey, 128);
    SetEnvironmentVariableW(L"AURORA17_Control__ControlKey", wkey);

    DWORD server_pid, launch_pid;
    ULONGLONG server_start, launch_start;
    state_read(&server_pid, &server_start, &launch_pid, &launch_start);

    /* BUGS.md §18. The licence file is checked -- and made -- before the server
     * is started or restarted, so a bottle that cannot play never ends up with
     * a server left running behind a failed launch. */
    if (!server_only && (rc = ensure_licence(localappdata))) goto done;

    if (port_is_listening(CONTROL_PORT))
    {
        if (server_healthy(key))
            out(L"Server already running - leaving it alone.\n");
        else if (server_pid && process_is(server_pid, L"Aurora17.Server.exe", server_start))
        {
            /* Play.ps1 words this as a control-key mismatch. It is only one of
             * the reasons server_healthy() says no -- a server that is
             * listening but never became ready lands here too, with the very
             * same key -- so do not name a cause that has not been shown. */
            out(L"A server is running but is not answering its readiness check. Restarting it...\n");
            kill_pid(server_pid);
            Sleep(3000);
            if ((rc = start_server(root, localappdata, key))) goto done;
        }
        else
        {
            /* Self-healing: check if any unrecorded/orphaned Aurora17.Server.exe is running */
            procid srvs[8];
            int srv_count = find_processes(L"Aurora17.Server.exe", srvs, 8);
            if (srv_count > 0)
            {
                out(L"Found %d orphaned Aurora17 server process(es). Restarting fresh...\n", srv_count);
                for (int i = 0; i < srv_count; i++) kill_pid(srvs[i].pid);
                Sleep(3000);
                if ((rc = start_server(root, localappdata, key))) goto done;
            }
            else
            {
                /* A server that is mid-start answers late; two more probes cost
                 * two seconds and save a wrong diagnosis. */
                BOOL late = FALSE;
                for (int i = 0; i < 2 && !late; i++) { Sleep(1000); late = server_healthy(key); }
                if (late)
                    out(L"The server passed its readiness check on a later attempt - it was "
                        L"still starting. Leaving it alone.\n");
                else
                {
                    /* Not "a non-Aurora process": our own leaked Aurora17.Server.exe
                     * from a previous launcher session is invisible to this one --
                     * different wineserver session, same listening socket -- and
                     * that is what this almost always is. Say only what is known. */
                    rc = fail_code(ERR_PORT_UNOWNED,
                                   L"Port %d is busy and the holder is not visible from this launch. "
                                   L"It is almost always the Aurora server left over from an earlier "
                                   L"launch. Quit the launcher completely, run ./setup.sh --unstick "
                                   L"in Terminal, then PLAY again.", CONTROL_PORT);
                    goto done;
                }
            }
        }
    }
    else
    {
        if (server_pid && process_is(server_pid, L"Aurora17.Server.exe", server_start))
        {
            out(L"Stopping the recorded server process that is no longer listening...\n");
            kill_pid(server_pid);
        }
        else
        {
            procid srvs[8];
            int srv_count = find_processes(L"Aurora17.Server.exe", srvs, 8);
            for (int i = 0; i < srv_count; i++) kill_pid(srvs[i].pid);
        }
        if ((rc = start_server(root, localappdata, key))) goto done;
    }

    if (server_only) goto done;

    procid fifa[8];
    if (find_processes(L"FIFA17.exe", fifa, 8) > 0)
    {
        out(L"FIFA 17 is already running.\n");
        goto done;
    }

    char generation[160] = {0};
    if (!read_head_generation(generation, sizeof(generation)))
    { rc = fail_code(ERR_HEAD_CACHE, L"The live routing document does not identify the player-head archive generation."); goto done; }
    if ((rc = refresh_player_head_cache(generation))) goto done;

    /* Only a launch connector this shim started may be stopped, and never the
     * desktop launcher that invoked us. */
    state_read(&server_pid, &server_start, &launch_pid, &launch_start);
    if (launch_pid && launch_pid != preserve_pid &&
        process_is(launch_pid, L"Aurora17Connector.exe", launch_start))
    {
        out(L"Stopping the previous launch connector...\n");
        kill_pid(launch_pid);
        Sleep(2000);
    }

    wchar_t connector[MAX_PATH];
    if (connector_arg && *connector_arg)
    {
        wcsncpy(connector, connector_arg, MAX_PATH - 1);
        connector[MAX_PATH - 1] = 0;
    }
    else
        join(connector, MAX_PATH, root, L"Aurora17Connector.exe");
    if (!file_exists(connector))
    { rc = fail_code(ERR_CONNECTOR_MISSING, L"The supplied Aurora17 connector does not exist: %s", connector); goto done; }

    wchar_t connector_dir[MAX_PATH];
    wcsncpy(connector_dir, connector, MAX_PATH - 1);
    connector_dir[MAX_PATH - 1] = 0;
    slash = wcsrchr(connector_dir, L'\\');
    if (slash) *slash = 0;

    /* TODO item 1: code 25 is a start-up race, not a configuration fault -- FIFA17.exe
     * abort()s ~1.3 s after its first Origin GetDefaultUser on roughly six launches in
     * seven, and simply pressing PLAY again eventually works. Retry that one signature
     * (the game appeared, went away inside the watch window, licence file present) and
     * nothing else: code 24, a connector that dies before the game appears, a failed
     * enrolment and the five-minute timeout are all deterministic and still fail once. */
    int attempt;
    for (attempt = 1; ; attempt++)
    {
        BOOL      race = FALSE;      /* this attempt hit the code 25 signature */
        DWORD     race_seconds = 0;
        DWORD     race_ccode = 0;
        BOOL      race_have_ccode = FALSE;

        out(L"Enrolling...\n");
        char *resp = NULL;
        int st = http_request("POST", CONTROL_PORT, "/v1/control/bootstrap-tickets", key,
                              "application/json",
                              "{\"AccountId\":\"1000000000001\",\"PersonaId\":\"2000000000001\","
                              "\"DisplayName\":\"Aurora17\",\"Audience\":\"fifa17\"}",
                              30000, &resp);
        if (st < 200 || st > 299 || !resp)
        { free(resp); rc = fail_code(ERR_ENROLL_FAIL, L"The Aurora17 server refused to mint a bootstrap ticket (HTTP %d).", st); goto done; }
        char *ticket = json_string(resp, "bootstrapTicket");
        free(resp);
        if (!ticket || !*ticket)
        { free(ticket); rc = fail_code(ERR_ENROLL_FAIL, L"The ticket response contained no bootstrapTicket."); goto done; }

        wchar_t temp_dir[MAX_PATH], ticket_file[MAX_PATH];
        GetTempPathW(MAX_PATH, temp_dir);
        _snwprintf(ticket_file, MAX_PATH - 1, L"%saurora17-ticket-%lu-%lu",
                   temp_dir, (unsigned long)GetCurrentProcessId(), GetTickCount());
        BOOL wrote = write_all_utf8(ticket_file, ticket);
        SecureZeroMemory(ticket, strlen(ticket));
        free(ticket);
        if (!wrote) { rc = fail_code(ERR_ENROLL_FAIL, L"The one-time ticket could not be staged."); goto done; }

        wchar_t cmd[MAX_PATH + 32];
        _snwprintf(cmd, MAX_PATH + 31, L"\"%s\" enroll", connector);
        DWORD epid = 0;
        HANDLE eh = spawn(cmd, connector_dir, NULL, NULL, ticket_file, &epid);
        DWORD ecode = 1;
        if (eh)
        {
            WaitForSingleObject(eh, 120000);
            GetExitCodeProcess(eh, &ecode);
            CloseHandle(eh);
        }
        DeleteFileW(ticket_file);
        if (!eh || ecode != 0)
        { rc = fail_code(ERR_ENROLL_FAIL, L"The Aurora17 connector could not enroll the account (exit %lu).", ecode); goto done; }

        out(L"Launching FIFA 17...\n");
        out(L"If FIFA Configuration opens, click Play; Aurora17 keeps the session ready for four minutes.\n");
        _snwprintf(cmd, MAX_PATH + 31, L"\"%s\" launch", connector);
        DWORD lpid = 0;
        HANDLE lh = spawn(cmd, connector_dir, NULL, NULL, NULL, &lpid);
        if (!lh) { rc = fail_code(ERR_CONNECTOR_FAIL, L"Windows did not start the Aurora17 launch connector (%lu).", GetLastError()); goto done; }

        ULONGLONG lstart = process_start(lh);
        /* Every attempt records its own launch pid, so a later PLAY still stops the
         * connector that is actually running. */
        state_read(&server_pid, &server_start, &launch_pid, &launch_start);
        state_write(server_pid, server_start, lpid, lstart);

        DWORD waited = 0;
        DWORD game_pid = 0;
        for (;;)
        {
            Sleep(1000);
            waited += 1000;
            if (WaitForSingleObject(lh, 0) == WAIT_OBJECT_0)
            {
                DWORD code = 0;
                GetExitCodeProcess(lh, &code);
                /* A launch connector that exits before the game appears has failed; its
                 * own log carries the reason (an expired session returns HTTP 401). */
                if (!game_pid)
                {
                    CloseHandle(lh);
                    if (!licence_present())
                    {
                        wchar_t lic[MAX_PATH];
                        licence_file_path(lic, MAX_PATH);
                        rc = fail_code(ERR_LICENCE_MISSING,
                                       L"The Aurora17 launch connector exited with code %lu (0x%08lx) "
                                       L"before FIFA 17 started, and this bottle has no licence file at "
                                       L"%s. Start FIFA 17 once from CrossOver, then PLAY again.",
                                       code, code, lic);
                    }
                    else
                        rc = fail_code(ERR_CONNECTOR_FAIL,
                                       L"The Aurora17 launch connector exited with code %lu (0x%08lx) "
                                       L"before FIFA 17 started. See the connector log.", code, code);
                    goto done;
                }
            }
            int n = find_processes(L"FIFA17.exe", fifa, 8);
            for (int i = 0; i < n; i++)
            {
                if (fifa[i].start >= lstart) { game_pid = fifa[i].pid; break; }
            }
            if (game_pid)
            {
                Sleep(2000);
                waited += 2000;
                if (process_is(game_pid, L"FIFA17.exe", 0)) break;
                /* Gone in two seconds. Without a licence the game relaunches itself,
                 * so look for the replacement before calling the launch dead. */
                n = find_processes(L"FIFA17.exe", fifa, 8);
                game_pid = 0;
                for (int i = 0; i < n; i++)
                    if (fifa[i].start >= lstart) { game_pid = fifa[i].pid; break; }
                if (game_pid) continue;
                race = TRUE;
                race_seconds = waited / 1000;
                break;
            }
            if (waited >= FIFA_LAUNCH_TIMEOUT_MS)
            {
                CloseHandle(lh);
                rc = fail_code(ERR_FIFA_TIMEOUT, L"FIFA 17 did not start before the five-minute launch deadline.");
                goto done;
            }
        }

        if (!race)
        {
            out(L"FIFA 17 is running (pid %lu). Go to Ultimate Team.\n", (unsigned long)game_pid);

            /* §18 again: on a bottle without the licence file the game gets exactly this
             * far every time, then exits 0xFFFFFFFA seventeen to twenty-five seconds in
             * while the connector reports nothing and the launcher shows "WORKING...".
             * Watching the first minute is what turns that silence into an error code. */
            DWORD watch_until = waited + 25000;
            if (watch_until < FIFA_EARLY_QUIT_MS) watch_until = FIFA_EARLY_QUIT_MS;
            while (waited < watch_until)
            {
                Sleep(1000);
                waited += 1000;
                if (process_is(game_pid, L"FIFA17.exe", 0)) continue;
                int alive = find_processes(L"FIFA17.exe", fifa, 8);
                if (alive > 0) { game_pid = fifa[alive - 1].pid; continue; }

                race_have_ccode = (WaitForSingleObject(lh, 0) == WAIT_OBJECT_0) &&
                                  GetExitCodeProcess(lh, &race_ccode);
                race = TRUE;
                race_seconds = waited / 1000;
                break;
            }
        }

        CloseHandle(lh);
        if (!race) break;                        /* the game survived the watch window */

        /* Code 24 is deterministic (fifa_quit_early says so itself), and the last
         * attempt has to report rather than retry. */
        if (!licence_present() || attempt >= FIFA_LAUNCH_ATTEMPTS)
        {
            rc = fifa_quit_early(race_seconds, race_ccode, race_have_ccode, attempt);
            goto done;
        }

        out(L"FIFA 17 quit %lu seconds in with the licence file present. This is the known "
            L"start-up race; trying again (attempt %d of %d)...\n",
            (unsigned long)race_seconds, attempt + 1, FIFA_LAUNCH_ATTEMPTS);

        /* Leave nothing from this attempt behind: the next one refuses to run while a
         * FIFA17.exe is up, and its own connector must not race ours. */
        procid stale[8];
        int stale_n = find_processes(L"FIFA17.exe", stale, 8);
        for (int i = 0; i < stale_n; i++) kill_pid(stale[i].pid);
        if (lpid && process_is(lpid, L"Aurora17Connector.exe", lstart)) kill_pid(lpid);
        Sleep(3000);
    }

done:
    if (mutex) { if (held) ReleaseMutex(mutex); CloseHandle(mutex); }
    return rc;
}

/* ----------------------------------------------------- Reset-FutClub.ps1 */

static int run_reset_club(int argc, wchar_t **argv)
{
    (void)argc; (void)argv;
    wchar_t localappdata[MAX_PATH];
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", localappdata, MAX_PATH))
        return fail_code(ERR_KEY_FAIL, L"The current Windows LocalAppData folder could not be resolved.");

    char key[128] = {0};
    wchar_t keyfile[MAX_PATH];
    join(keyfile, MAX_PATH, localappdata, L"Aurora17\\control-key.txt");
    if (!file_exists(keyfile))
    {
        wchar_t env[128];
        if (GetEnvironmentVariableW(L"AURORA17_Control__ControlKey", env, 128))
            WideCharToMultiByte(CP_UTF8, 0, env, -1, key, sizeof(key), NULL, NULL);
        else
            return fail_code(ERR_KEY_FAIL, L"No control key. Start Aurora17 with PLAY first.");
    }
    else if (!load_control_key(localappdata, key, sizeof(key)))
        return fail_code(ERR_KEY_FAIL, L"The Aurora17 control key could not be read.");

    char *resp = NULL;
    int st = http_request("POST", CONTROL_PORT, "/v1/control/reset-fut-club", key,
                          "application/json", "", 120000, &resp);
    if (st < 200 || st > 299)
    {
        free(resp);
        return fail_code(ERR_RESET_CLUB_FAIL, L"The FUT club reset failed (HTTP %d). Make sure the Aurora17 server is running.", st);
    }
    out(L"Reset complete. Leave Ultimate Team and re-enter it to refresh the club.\n");
    free(resp);
    return 0;
}

/* ------------------------------------------------- New-DevCertificate.ps1 */

static int run_new_dev_certificate(const wchar_t *script_path, int argc, wchar_t **argv)
{
    BOOL force = FALSE;
    for (int i = 0; i < argc; i++)
        if (!_wcsicmp(argv[i], L"-Force")) force = TRUE;

    wchar_t root[MAX_PATH];
    wcsncpy(root, script_path, MAX_PATH - 1);
    root[MAX_PATH - 1] = 0;
    wchar_t *slash = wcsrchr(root, L'\\');
    if (slash) *slash = 0;
    slash = wcsrchr(root, L'\\');
    if (slash) *slash = 0;

    wchar_t target[MAX_PATH];
    join(target, MAX_PATH, root, L"server\\Aurora17Server\\redirector-dev.pfx");
    if (file_exists(target) && !force)
    {
        out(L"Already present: %s\n", target);
        return 0;
    }
    return fail_code(ERR_PKI_MISSING,
                     L"Creating a new redirector certificate needs Windows PowerShell's PKI module, "
                     L"which this bottle does not have. Restore %s from the Aurora17 archive.", target);
}

/* -------------------------------------------------------------------- main */

int wmain(int argc, wchar_t **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    const wchar_t *script = NULL;
    int rest = argc;
    for (int i = 1; i < argc; i++)
    {
        if ((!_wcsicmp(argv[i], L"-File") || !_wcsicmp(argv[i], L"-f")) && i + 1 < argc)
        {
            script = argv[i + 1];
            rest = i + 2;
            break;
        }
    }
    if (!script)
    {
        out(L"aurora-pwsh: this bottle has no PowerShell. Only Aurora17's own scripts are\n"
            L"implemented, and only through -File. Command line was:\n  %s\n", GetCommandLineW());
        return ERR_UNSUPPORTED_CMD;
    }

    const wchar_t *name = wcsrchr(script, L'\\');
    name = name ? name + 1 : script;

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
        return fail(L"Winsock could not start.");

    int rc;
    if (!_wcsicmp(name, L"Play.ps1"))
        rc = run_play(script, argc - rest, argv + rest);
    else if (!_wcsicmp(name, L"Reset-FutClub.ps1"))
        rc = run_reset_club(argc - rest, argv + rest);
    else if (!_wcsicmp(name, L"Refresh-PlayerHeadCache.ps1"))
    {
        char gen[160] = {0};
        for (int i = rest; i + 1 < argc; i++)
            if (!_wcsicmp(argv[i], L"-Generation"))
                WideCharToMultiByte(CP_UTF8, 0, argv[i + 1], -1, gen, sizeof(gen), NULL, NULL);
        rc = refresh_player_head_cache(gen);
    }
    else if (!_wcsicmp(name, L"New-DevCertificate.ps1"))
        rc = run_new_dev_certificate(script, argc - rest, argv + rest);
    else
        rc = fail_code(ERR_UNSUPPORTED_CMD, L"aurora-pwsh does not implement %s.", name);

    WSACleanup();
    return rc;
}
