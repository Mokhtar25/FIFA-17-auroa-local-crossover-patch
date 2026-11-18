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
 * It also implements the Aurora launcher's FIFA 21 client-pack script,
 * Start-Aurora21.ps1 (see that section).
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
#include <winhttp.h>
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
#define ERR_FIFA_CRASHED         26

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

/* The game's own exit code, as the launch connector wrote it. This program never
 * holds a handle on FIFA17.exe -- the connector owns it -- so the only place that
 * code exists is the connector's log: "... exited with code 0xC0000005." Read every
 * connector-*.log written since this launch started and take the line from the one
 * written last. FALSE when no such line has appeared yet; the connector writes it
 * within a second of the game going, so the caller waits a little and asks again. */
static BOOL game_exit_code_from_log(const wchar_t *localappdata, ULONGLONG since, DWORD *code)
{
    wchar_t logdir[MAX_PATH], pattern[MAX_PATH];
    join(logdir, MAX_PATH, localappdata, L"Aurora17\\Logs");
    _snwprintf(pattern, MAX_PATH - 1, L"%s\\connector-*.log", logdir);
    pattern[MAX_PATH - 1] = 0;

    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return FALSE;

    ULONGLONG best_time = 0;
    BOOL found = FALSE;
    do {
        ULARGE_INTEGER t;
        t.LowPart = fd.ftLastWriteTime.dwLowDateTime;
        t.HighPart = fd.ftLastWriteTime.dwHighDateTime;
        if (t.QuadPart < since || t.QuadPart < best_time) continue;

        wchar_t path[MAX_PATH];
        join(path, MAX_PATH, logdir, fd.cFileName);
        char *text = read_all_utf8(path, NULL);
        if (!text) continue;
        const char *needle = "exited with code 0x", *p = text, *last = NULL;
        while ((p = strstr(p, needle))) { last = p + strlen(needle); p = last; }
        if (last)
        {
            char *end = NULL;
            unsigned long v = strtoul(last, &end, 16);
            if (end && end > last) { *code = (DWORD)v; found = TRUE; best_time = t.QuadPart; }
        }
        free(text);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return found;
}

/* An NTSTATUS exit code (0xC0000005 and friends) is the game dying on an unhandled
 * exception. That is not the start-up race: on every machine it has been seen on it
 * came back identically on every launch, so relaunching it four times only costs
 * two minutes and then calls it the race. Say what it is, and where the one thing
 * that can locate it -- CrossOver's own log of the launch -- comes from. */
static int fifa_crashed(DWORD seconds, DWORD code)
{
    const wchar_t *what = L"an unhandled exception";
    if (code == 0xC0000005) what = L"an access violation";
    else if (code == 0xC000001D) what = L"an illegal instruction";
    else if (code == 0xC00000FD) what = L"a stack overflow";
    return fail_code(ERR_FIFA_CRASHED,
        L"FIFA 17 crashed %lu seconds after starting: exit code 0x%08lX, %s inside the game. "
        L"This is not the start-up race, so it was not relaunched; pressing PLAY again gives "
        L"the same result. To find out where it crashed: quit CrossOver, double-click "
        L"'12 Play with a crash log.command' in the diagnostics folder, press PLAY in the "
        L"launcher it opens, and once the game has crashed run '1 Collect diagnostics.command' "
        L"and send the zip.",
        (unsigned long)seconds, (unsigned long)code, what);
}

/* FIFA is gone within a minute of the launch. Which of the two failures is it?
 * `attempts` is how many launches this PLAY made, so the code 25 text says out loud
 * that the retry ran and how often. */
static int fifa_quit_early(DWORD seconds, DWORD connector_code, BOOL have_connector_code,
                           DWORD game_code, BOOL have_game_code, int attempts)
{
    wchar_t lic[MAX_PATH];
    licence_file_path(lic, MAX_PATH);
    if (!file_exists(lic))
        return fail_code(ERR_LICENCE_MISSING,
            L"FIFA 17 quit %lu seconds after starting and this bottle still has no licence file "
            L"at %s. That is the Origin activation path: the game relaunches itself and the "
            L"process Aurora17 is watching exits 0xFFFFFFFA. Start FIFA 17 once from CrossOver, "
            L"then PLAY again.", (unsigned long)seconds, lic);

    wchar_t tried[256];
    if (attempts > 1)
        _snwprintf(tried, 255,
                   L"FIFA 17 was launched %d times and quit %lu seconds in on the last try",
                   attempts, (unsigned long)seconds);
    else
        _snwprintf(tried, 255, L"FIFA 17 quit %lu seconds after starting",
                   (unsigned long)seconds);
    tried[255] = 0;
    if (have_game_code)
    {
        size_t n = wcslen(tried);
        _snwprintf(tried + n, 255 - n, L" (the game's exit code was 0x%08lX)",
                   (unsigned long)game_code);
        tried[255] = 0;
    }

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

        /* Which early exit was it? The connector logs the game's own exit code, and
         * that is what tells them apart: 0x00000003 is the abort() of the start-up
         * race, which a relaunch does get past; 0xC0000005 is an unhandled exception
         * inside the game, which has never been seen to clear on a relaunch. Before
         * this was read, a crash was relaunched four times, cost two minutes, and was
         * then reported as the race -- which sent people to the race's remedies. */
        DWORD game_code = 0;
        BOOL have_game_code = FALSE;
        for (int i = 0; i < 4 && !have_game_code; i++)
        {
            have_game_code = game_exit_code_from_log(localappdata, lstart, &game_code);
            if (!have_game_code) Sleep(1000);
        }
        if (have_game_code && (game_code & 0xC0000000) == 0xC0000000)
        {
            rc = fifa_crashed(race_seconds, game_code);
            goto done;
        }

        /* Code 24 is deterministic (fifa_quit_early says so itself), and the last
         * attempt has to report rather than retry. */
        if (!licence_present() || attempt >= FIFA_LAUNCH_ATTEMPTS)
        {
            rc = fifa_quit_early(race_seconds, race_ccode, race_have_ccode,
                                 game_code, have_game_code, attempt);
            goto done;
        }

        if (have_game_code)
            out(L"FIFA 17 quit %lu seconds in (exit code 0x%08lX) with the licence file present. "
                L"This is the known start-up race; trying again (attempt %d of %d)...\n",
                (unsigned long)race_seconds, (unsigned long)game_code,
                attempt + 1, FIFA_LAUNCH_ATTEMPTS);
        else
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

/* ------------------------------------------------------ Start-Aurora21.ps1 */

/* FIFA 21 is played through the Aurora launcher (Aurora15Connector), not
 * Aurora17's. Its PLAY downloads a client pack and runs, per the pack's
 * runtime.json,
 *
 *   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <pack>\Start-Aurora21.ps1
 *                  -GamePath <game>\FIFA21.exe -ServerAddress <ipv4>
 *                  -TrustAnchors <pack>\trust-anchors -LogPath <logs>
 *
 * with a one-time launch code on standard input, and waits for a line starting
 * "[READY]" or "[FAILED]". After FIFA closes it runs the same script with
 * -Cleanup. This is that script for the one kind of copy a bottle can start:
 * a direct one (anadius files or a _crack folder), which the script never
 * hands to the EA app either.
 *
 *   1. FIFA21.exe starts, runs until its window is up, and is suspended.
 *   2. Aurora21-MathBridge.exe is started on it (best effort, as in the script).
 *   3. trust\Aurora21-UltimateTeam-Server.exe trust-patch patches its trust
 *      tables in memory, including the Origin client bootstrap bypass.
 *   4. Aurora21-LocalAuthBridge.exe takes the code.
 *   5. spring18.gosredirector.ea.com and its three test twins point at the
 *      server in the bottle's hosts file, which a17hosts.dylib makes Wine
 *      read, and must resolve there.
 *   6. The game resumes, and "[READY]".
 *
 * Step 1 is the one difference. The script starts the game suspended and
 * patches it before it runs. Under Wine a FIFA21.exe patched that way never
 * gets out of its copy protection's start-up phase -- one thread, one core at
 * 100%, no window, for as long as anyone waits -- whether the patch is the
 * whole set or only the certificate. Once its window is up that phase is
 * over and the same patches hold. The game is suspended there all the same,
 * because it looks spring18.gosredirector.ea.com up about 15 s after its
 * window appears, and steps 3 and 4 take longer than that (the auth bridge
 * hashes the 570 MB executable first): left running, its first try went to
 * EA before the redirect was in place, and it showed "The EA servers are not
 * available". The Origin bypass still lands in time; the check it removes is
 * made when the game goes online, not at start-up.
 *
 * The messages and exit codes are the script's own (0 ready, 2 bad input,
 * 3 game, 4 trust patch, 5 auth bridge, 6 hosts), so the launcher shows the
 * player the same text it would on Windows. The code is never written to a
 * file, a log or a command line. */

#define A21_TRUST_TIMEOUT_MS     (60 * 1000)
#define A21_BRIDGE_TIMEOUT_MS    (60 * 1000)
#define A21_START_TIMEOUT_MS     (180 * 1000)
#define A21_WINDOW_TIMEOUT_MS    (180 * 1000)
#define A21_HOSTS_ATTEMPTS       20

static const wchar_t *A21_REDIRECT_HOSTS[] = {
    L"spring18.gosredirector.ea.com",
    L"spring18.gosredirector.stest.ea.com",
    L"spring18.gosredirector.scert.ea.com",
    L"spring18.gosredirector.sdev.ea.com",
};
#define A21_NREDIRECT (sizeof(A21_REDIRECT_HOSTS) / sizeof(A21_REDIRECT_HOSTS[0]))

/* The server's HTTPS fronts, in the order the pack's script tries them ($MathReportHosts).
 * 21.aurorafut.com no longer resolves; the pack's current list has the .co.uk name. */
static const wchar_t *A21_MATH_REPORT_HOSTS[] = {
    L"21.aurcdn.com", L"21.aurorafut.co.uk", L"21.onlyonemzy.com",
};

/* The FIFA21.exe digest a21_binary_preflight already computed (545 MB: not read twice). */
static wchar_t cm_exe_digest_path[1024];
static char cm_exe_digest_hex[65];

static int a21_fail(int code, const wchar_t *fmt, ...)
{
    wchar_t buf[4096];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(buf, 4095, fmt, ap);
    va_end(ap);
    buf[4095] = 0;
    out(L"[FAILED] %s\n", buf);
    return code;
}

static void a21_parent_dir(const wchar_t *path, wchar_t *dst, size_t cap)
{
    wcsncpy(dst, path, cap - 1);
    dst[cap - 1] = 0;
    wchar_t *slash = wcsrchr(dst, L'\\');
    if (slash) *slash = 0;
}

static const wchar_t *a21_leaf(const wchar_t *path)
{
    const wchar_t *slash = wcsrchr(path, L'\\');
    return slash ? slash + 1 : path;
}

/* ------------------------------------------------------- child processes */

/* Starts a hidden child on the three given handles, none of which may be
 * NULL. Like the script's Start-DetachedHelper, the launcher's own pipes (our
 * standard handles) are kept out of it: they are made non-inheritable for the
 * moment of the CreateProcess and put back after. A helper that outlives this
 * program must not hold the launcher's view of it open. */
static HANDLE a21_spawn(const wchar_t *cmdline, const wchar_t *cwd,
                        HANDLE in, HANDLE outh, HANDLE errh, DWORD *pid_out)
{
    HANDLE saved[3];
    int nsaved = 0;
    static const DWORD std_ids[3] = { STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE };
    for (int i = 0; i < 3; i++)
    {
        HANDLE h = GetStdHandle(std_ids[i]);
        DWORD flags = 0;
        if (h && h != INVALID_HANDLE_VALUE && h != in && h != outh && h != errh &&
            GetHandleInformation(h, &flags) && (flags & HANDLE_FLAG_INHERIT) &&
            SetHandleInformation(h, HANDLE_FLAG_INHERIT, 0))
            saved[nsaved++] = h;
    }

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdInput = in;
    si.hStdOutput = outh;
    si.hStdError = errh;

    wchar_t mutable_cmd[4096];
    wcsncpy(mutable_cmd, cmdline, 4095);
    mutable_cmd[4095] = 0;
    BOOL ok = CreateProcessW(NULL, mutable_cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW,
                             NULL, cwd, &si, &pi);
    DWORD err = GetLastError();
    for (int i = 0; i < nsaved; i++)
        SetHandleInformation(saved[i], HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    if (!ok) { SetLastError(err); return NULL; }
    CloseHandle(pi.hThread);
    if (pid_out) *pid_out = pi.dwProcessId;
    return pi.hProcess;
}

static HANDLE a21_inheritable_file(const wchar_t *path, BOOL write)
{
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    return CreateFileW(path, write ? GENERIC_WRITE : GENERIC_READ,
                       FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                       write ? CREATE_ALWAYS : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
}

/* A pipe whose child end is inheritable and whose parent end is not. */
static BOOL a21_pipe(HANDLE *child_end, HANDLE *parent_end, BOOL child_reads)
{
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    HANDLE r, w;
    if (!CreatePipe(&r, &w, &sa, 0)) return FALSE;
    *child_end = child_reads ? r : w;
    *parent_end = child_reads ? w : r;
    SetHandleInformation(*parent_end, HANDLE_FLAG_INHERIT, 0);
    return TRUE;
}

/* Runs a console child to completion with stdout and stderr captured together
 * (the script's "& $server @arguments 2>&1"). Returns the output, NUL
 * terminated, or NULL if it could not start. */
static char *a21_run_capture(const wchar_t *cmdline, const wchar_t *cwd, DWORD timeout_ms,
                             DWORD *exit_out)
{
    HANDLE child_out, parent_out;
    if (!a21_pipe(&child_out, &parent_out, FALSE)) return NULL;
    HANDLE nul = a21_inheritable_file(L"NUL", FALSE);
    HANDLE p = a21_spawn(cmdline, cwd, nul, child_out, child_out, NULL);
    CloseHandle(child_out);
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    if (!p) { CloseHandle(parent_out); return NULL; }

    size_t cap = 65536, len = 0;
    char *buf = malloc(cap);
    DWORD rd;
    while (buf && ReadFile(parent_out, buf + len, (DWORD)(cap - len - 1), &rd, NULL) && rd)
    {
        len += rd;
        if (cap - len < 4096)
        {
            char *nb = realloc(buf, cap * 2);
            if (!nb) break;
            buf = nb;
            cap *= 2;
        }
    }
    CloseHandle(parent_out);
    if (WaitForSingleObject(p, timeout_ms) != WAIT_OBJECT_0) TerminateProcess(p, 1);
    DWORD code = 1;
    GetExitCodeProcess(p, &code);
    CloseHandle(p);
    if (exit_out) *exit_out = code;
    if (buf) buf[len] = 0;
    return buf;
}

/* ----------------------------------------------------------------- the game */

typedef struct { DWORD pid; ULONGLONG start; } a21_game;

/* Get-NewestGameProcess. */
static BOOL a21_newest_game(a21_game *g)
{
    static const wchar_t *names[] = { L"FIFA21.exe", L"FIFA21_Trial.exe" };
    BOOL found = FALSE;
    for (int k = 0; k < 2; k++)
    {
        procid list[16];
        int n = find_processes(names[k], list, 16);
        for (int i = 0; i < n; i++)
            if (!found || list[i].start > g->start)
            {
                g->pid = list[i].pid;
                g->start = list[i].start;
                found = TRUE;
            }
    }
    return found;
}

typedef struct { DWORD pid; BOOL found; } a21_window_search;

static BOOL CALLBACK a21_window_of(HWND hwnd, LPARAM lp)
{
    a21_window_search *ws = (a21_window_search *)lp;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == ws->pid && IsWindowVisible(hwnd) && !GetWindow(hwnd, GW_OWNER))
    {
        ws->found = TRUE;
        return FALSE;
    }
    return TRUE;
}

/* Waits for the game's first visible top-level window: the sign that it is
 * past its copy protection's start-up and may be patched (see the top of this
 * section). Returns 0, or the script's exit code after printing why not. */
static int a21_wait_game_window(HANDLE process, DWORD pid)
{
    DWORD deadline = GetTickCount() + A21_WINDOW_TIMEOUT_MS;
    for (;;)
    {
        a21_window_search ws = { pid, FALSE };
        EnumWindows(a21_window_of, (LPARAM)&ws);
        if (ws.found) return 0;
        if (WaitForSingleObject(process, 500) == WAIT_OBJECT_0)
        {
            DWORD code = 0;
            GetExitCodeProcess(process, &code);
            return a21_fail(3, L"FIFA21.exe closed during startup (exit code 0x%08lX) before it opened its window.",
                            code);
        }
        if ((LONG)(GetTickCount() - deadline) >= 0)
            return a21_fail(3, L"FIFA21.exe did not open its window within %d seconds.",
                            A21_WINDOW_TIMEOUT_MS / 1000);
    }
}

typedef LONG (NTAPI *a21_nt_process_fn)(HANDLE);

/* NtSuspendProcess / NtResumeProcess. Suspend counts nest, so the helpers'
 * own suspend-resume pairs leave the game suspended until this resumes it. */
static BOOL a21_suspend_process(HANDLE process, BOOL suspend)
{
    static a21_nt_process_fn nt_suspend, nt_resume;
    if (!nt_suspend)
    {
        HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
        nt_suspend = (a21_nt_process_fn)(void *)GetProcAddress(ntdll, "NtSuspendProcess");
        nt_resume = (a21_nt_process_fn)(void *)GetProcAddress(ntdll, "NtResumeProcess");
        if (!nt_suspend || !nt_resume) return FALSE;
    }
    return (suspend ? nt_suspend : nt_resume)(process) >= 0;
}

/* Resolve-LaunchMethod. Returns L"direct", L"steam" or L"ea-app" and the
 * script's reason text. */
static const wchar_t *a21_launch_method(const wchar_t *game_path, wchar_t *reason, size_t cap)
{
    wchar_t folder[MAX_PATH], p[MAX_PATH];
    a21_parent_dir(game_path, folder, MAX_PATH);
    static const wchar_t *markers[] = { L"anadius64.dll", L"anadius32.dll", L"anadius.cfg" };
    for (int i = 0; i < 3; i++)
    {
        join(p, MAX_PATH, folder, markers[i]);
        if (file_exists(p))
        {
            _snwprintf(reason, cap - 1, L"an emulated copy: %s", markers[i]);
            reason[cap - 1] = 0;
            return L"direct";
        }
    }
    join(p, MAX_PATH, folder, L"_crack");
    if (dir_exists(p))
    {
        _snwprintf(reason, cap - 1, L"an emulated copy: _crack folder");
        reason[cap - 1] = 0;
        return L"direct";
    }
    wchar_t lower[MAX_PATH];
    wcsncpy(lower, folder, MAX_PATH - 1);
    lower[MAX_PATH - 1] = 0;
    _wcslwr(lower);
    if (wcsstr(lower, L"\\steamapps\\common\\"))
    {
        _snwprintf(reason, cap - 1, L"a Steam copy");
        reason[cap - 1] = 0;
        return L"steam";
    }
    join(p, MAX_PATH, folder, L"__Installer\\installerdata.xml");
    if (file_exists(p))
    {
        _snwprintf(reason, cap - 1, L"an EA app install: __Installer");
        reason[cap - 1] = 0;
        return L"ea-app";
    }
    static const wchar_t *keys[] = { L"SOFTWARE\\WOW6432Node\\EA Games\\FIFA 21",
                                     L"SOFTWARE\\EA Games\\FIFA 21" };
    for (int i = 0; i < 2; i++)
    {
        wchar_t dir[MAX_PATH];
        DWORD sz = sizeof(dir);
        if (RegGetValueW(HKEY_LOCAL_MACHINE, keys[i], L"Install Dir", RRF_RT_REG_SZ,
                         NULL, dir, &sz) != ERROR_SUCCESS)
            continue;
        size_t n = wcslen(dir);
        while (n && dir[n - 1] == L'\\') dir[--n] = 0;
        if (!_wcsicmp(dir, folder))
        {
            _snwprintf(reason, cap - 1, L"an EA app install: registry");
            reason[cap - 1] = 0;
            return L"ea-app";
        }
    }
    _snwprintf(reason, cap - 1, L"no EA app, Steam or emulator markers");
    reason[cap - 1] = 0;
    return L"direct";
}

/* Test-GameBinaryPreflight: the build Aurora refuses, by hash and by bytes. */
static int a21_binary_preflight(const wchar_t *path)
{
    static const BYTE malformed_hash[32] = {
        0xE1,0x02,0x2A,0x95,0x0C,0x08,0x72,0x4E,0x12,0x64,0x93,0xD6,0x02,0x22,0xCE,0x76,
        0x3D,0x51,0x0D,0x1C,0x6E,0xBD,0x30,0x85,0x06,0x86,0x0F,0x01,0x9B,0xC0,0x27,0x63 };
    static const BYTE malformed_bytes[4] = { 0x66, 0xE9, 0x18, 0x01 };
    const ULONGLONG known_length = 571958064ULL;
    const LONGLONG patch_offset = 0xDBFD82;

    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (h == INVALID_HANDLE_VALUE)
        return a21_fail(3, L"FIFA21.exe could not be read (Windows error %lu).", GetLastError());

    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    BYTE digest[32] = {0};
    BOOL hashed = FALSE;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) == 0 &&
        BCryptCreateHash(alg, &hash, NULL, 0, NULL, 0, 0) == 0)
    {
        BYTE *chunk = malloc(1 << 20);
        DWORD rd;
        hashed = chunk != NULL;
        while (chunk && ReadFile(h, chunk, 1 << 20, &rd, NULL) && rd)
            if (BCryptHashData(hash, chunk, rd, 0) != 0) { hashed = FALSE; break; }
        free(chunk);
        if (hashed) hashed = BCryptFinishHash(hash, digest, sizeof(digest), 0) == 0;
    }
    if (hash) BCryptDestroyHash(hash);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    if (hashed)
    {
        for (int i = 0; i < 32; i++) _snprintf(cm_exe_digest_hex + i * 2, 3, "%02x", digest[i]);
        wcsncpy(cm_exe_digest_path, path, 1023);
        cm_exe_digest_path[1023] = 0;
    }
    if (hashed && !memcmp(digest, malformed_hash, 32))
    {
        CloseHandle(h);
        return a21_fail(3, L"This FIFA21.exe matches the known malformed four-byte patch. "
                           L"Repair the game in the EA App first.");
    }

    LARGE_INTEGER size;
    if (GetFileSizeEx(h, &size) && (ULONGLONG)size.QuadPart == known_length)
    {
        LARGE_INTEGER at;
        at.QuadPart = patch_offset;
        BYTE b[4];
        DWORD rd = 0;
        if (SetFilePointerEx(h, at, NULL, FILE_BEGIN) && ReadFile(h, b, 4, &rd, NULL) &&
            rd == 4 && !memcmp(b, malformed_bytes, 4))
        {
            CloseHandle(h);
            return a21_fail(3, L"This FIFA21.exe contains the known malformed bytes at 0xDBFD82. "
                               L"Repair the game in the EA App first.");
        }
    }
    CloseHandle(h);
    return 0;
}

/* ------------------------------------------------- anadius.cfg Username */

/* Sync-DirectGameUsername. The launcher passes the player's verified Discord
 * name in AURORA21_DISCORD_USERNAME; a direct copy's anadius.cfg carries the
 * name FIFA logs in with, and it has to be that one. The file is handled as
 * bytes so its encoding, comments and line endings survive; exactly one plain
 * quoted "Username" line is accepted, as in the script. Returns 0, or the
 * category of the failure for the script's "[INFO] ... failed" line. */
static const wchar_t *a21_sync_username(const wchar_t *game_path, const char *username,
                                        DWORD *hresult)
{
    *hresult = 0;
    if (!username || !*username) return NULL;
    wchar_t folder[MAX_PATH], config[MAX_PATH];
    a21_parent_dir(game_path, folder, MAX_PATH);
    join(config, MAX_PATH, folder, L"anadius.cfg");
    if (!file_exists(config)) return NULL;

    size_t ulen = strlen(username);
    BOOL valid = ulen >= 2 && ulen <= 32;
    for (size_t i = 0; valid && i < ulen; i++)
        valid = isalnum((unsigned char)username[i]) || username[i] == '.' || username[i] == '_';
    if (!valid) { *hresult = 0x80070057; return L"invalid-username"; }

    size_t len = 0;
    char *text = read_all_utf8(config, &len);
    if (!text) { *hresult = HRESULT_FROM_WIN32(GetLastError()); return L"profile-io-or-race"; }

    /* Walk the lines (a line ends at \n; a trailing \r belongs to it, as in .NET's
     * multiline $). Count every "Username" key, and match the one plain form. */
    int keys = 0, plain = 0;
    size_t vstart = 0, vlen = 0;
    for (size_t ls = 0; ls <= len; )
    {
        size_t le = ls;
        while (le < len && text[le] != '\n') le++;
        size_t eol = (le > ls && text[le - 1] == '\r') ? le - 1 : le;
        size_t q = ls;
        while (q < le && (text[q] == ' ' || text[q] == '\t')) q++;
        if (le - q >= 10 && !_strnicmp(text + q, "\"Username\"", 10))
        {
            size_t k = q + 10;
            if (k == le || text[k] == ' ' || text[k] == '\t') keys++;
            /* prefix: [ \t]+"   value: [^"\r\n]*   suffix: "[ \t]*(//[^\r\n]*)?  then \r?$ */
            size_t r = k;
            while (r < eol && (text[r] == ' ' || text[r] == '\t')) r++;
            if (r > k && r < eol && text[r] == '"')
            {
                size_t vs = r + 1, ve = vs;
                while (ve < eol && text[ve] != '"' && text[ve] != '\r') ve++;
                if (ve < eol && text[ve] == '"')
                {
                    size_t s = ve + 1;
                    while (s < eol && (text[s] == ' ' || text[s] == '\t')) s++;
                    BOOL ok = s == eol;
                    if (!ok && eol - s >= 2 && text[s] == '/' && text[s + 1] == '/')
                    {
                        ok = TRUE;
                        for (size_t c = s; c < eol; c++)
                            if (text[c] == '\r') ok = FALSE;
                    }
                    if (ok) { plain++; vstart = vs; vlen = ve - vs; }
                }
            }
        }
        if (le >= len) break;
        ls = le + 1;
    }
    if (keys != 1 || plain != 1)
    {
        free(text);
        *hresult = 0x80131501;
        return L"profile-format";
    }
    if (vlen == ulen && !memcmp(text + vstart, username, ulen)) { free(text); return NULL; }

    size_t nlen = len - vlen + ulen;
    char *updated = malloc(nlen + 1);
    if (!updated) { free(text); *hresult = 0x8007000E; return L"unexpected"; }
    memcpy(updated, text, vstart);
    memcpy(updated + vstart, username, ulen);
    memcpy(updated + vstart + ulen, text + vstart + vlen, len - vstart - vlen);
    updated[nlen] = 0;

    wchar_t temporary[MAX_PATH], backup[MAX_PATH], repeat_backup[MAX_PATH];
    BYTE g[16] = {0};
    BCryptGenRandom(NULL, g, sizeof(g), BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    wchar_t guid[33];
    for (int i = 0; i < 16; i++) _snwprintf(guid + 2 * i, 3, L"%02x", g[i]);
    guid[32] = 0;
    _snwprintf(temporary, MAX_PATH - 1, L"%s\\anadius.cfg.aurora21.%s.tmp", folder, guid);
    temporary[MAX_PATH - 1] = 0;
    _snwprintf(backup, MAX_PATH - 1, L"%s.aurora21.bak", config);
    backup[MAX_PATH - 1] = 0;
    _snwprintf(repeat_backup, MAX_PATH - 1, L"%s.bak", temporary);
    repeat_backup[MAX_PATH - 1] = 0;

    const wchar_t *failure = NULL;
    DWORD attrs = GetFileAttributesW(config);
    BOOL restore = FALSE;
    HANDLE h = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD wr = 0;
    if (h == INVALID_HANDLE_VALUE || !WriteFile(h, updated, (DWORD)nlen, &wr, NULL) || wr != nlen)
    {
        *hresult = HRESULT_FROM_WIN32(GetLastError());
        failure = *hresult == (DWORD)HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED) ? L"access-denied"
                                                                       : L"profile-io-or-race";
    }
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);

    /* Refuse if the profile changed while the replacement was prepared. */
    if (!failure)
    {
        size_t clen = 0;
        char *current = read_all_utf8(config, &clen);
        BOOL same = current && clen == len && !memcmp(current, text, len);
        free(current);
        if (!same || GetFileAttributesW(config) != attrs)
        {
            *hresult = 0x80131620;
            failure = L"profile-io-or-race";
        }
    }
    if (!failure && (attrs & FILE_ATTRIBUTE_READONLY))
    {
        DWORD writable = attrs & ~FILE_ATTRIBUTE_READONLY;
        SetFileAttributesW(config, writable ? writable : FILE_ATTRIBUTE_NORMAL);
        restore = TRUE;
    }
    if (!failure)
    {
        const wchar_t *target = file_exists(backup) ? repeat_backup : backup;
        if (!ReplaceFileW(config, temporary, target, REPLACEFILE_IGNORE_MERGE_ERRORS, NULL, NULL))
        {
            *hresult = HRESULT_FROM_WIN32(GetLastError());
            failure = *hresult == (DWORD)HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED) ? L"access-denied"
                                                                           : L"profile-io-or-race";
        }
        else
        {
            restore = TRUE;
            if (target == backup) SetFileAttributesW(backup, attrs);
        }
    }
    if (restore && file_exists(config)) SetFileAttributesW(config, attrs);
    DeleteFileW(temporary);
    DeleteFileW(repeat_backup);
    free(updated);
    free(text);
    return failure;
}

/* ------------------------------------------------------------- hosts file */

static void a21_hosts_path(wchar_t *dst, size_t cap)
{
    wchar_t sys[MAX_PATH];
    GetSystemDirectoryW(sys, MAX_PATH);
    _snwprintf(dst, cap - 1, L"%s\\drivers\\etc\\hosts", sys);
    dst[cap - 1] = 0;
}

static BOOL a21_is_redirect_name(const char *name, size_t n)
{
    while (n && name[n - 1] == '.') n--;
    for (size_t i = 0; i < A21_NREDIRECT; i++)
    {
        size_t m = wcslen(A21_REDIRECT_HOSTS[i]);
        if (m != n) continue;
        size_t k = 0;
        while (k < n && tolower((unsigned char)name[k]) == (wchar_t)A21_REDIRECT_HOSTS[i][k]) k++;
        if (k == n) return TRUE;
    }
    return FALSE;
}

typedef struct { char *buf; size_t len, cap; } a21_text;

static void a21_append(a21_text *t, const char *s, size_t n)
{
    if (t->len + n + 1 > t->cap)
    {
        size_t cap = t->cap ? t->cap : 4096;
        while (t->len + n + 1 > cap) cap *= 2;
        char *nb = realloc(t->buf, cap);
        if (!nb) return;
        t->buf = nb;
        t->cap = cap;
    }
    memcpy(t->buf + t->len, s, n);
    t->len += n;
    t->buf[t->len] = 0;
}

/* Remove-RedirectNames over the whole file: Windows uses the first line that
 * names a host, so every earlier redirect has to go -- also one with a
 * trailing comment, several names on one line, or another case. Other names
 * on such a line stay. Lines come back CRLF-terminated, as WriteAllLines
 * writes them; a UTF-8 byte order mark is dropped, as Get-Content drops it. */
static void a21_remove_redirect_names(const char *text, size_t len, a21_text *outt)
{
    if (len >= 3 && (unsigned char)text[0] == 0xEF && (unsigned char)text[1] == 0xBB &&
        (unsigned char)text[2] == 0xBF)
    {
        text += 3;
        len -= 3;
    }
    size_t ls = 0;
    while (ls < len)
    {
        size_t le = ls;
        while (le < len && text[le] != '\r' && text[le] != '\n') le++;
        const char *line = text + ls;
        size_t n = le - ls;

        const char *hash = memchr(line, '#', n);
        size_t content = hash ? (size_t)(hash - line) : n;
        /* Fields of the part before any comment. */
        size_t fs[64], fl[64];
        int nf = 0;
        for (size_t i = 0; i < content && nf < 64; )
        {
            while (i < content && isspace((unsigned char)line[i])) i++;
            if (i >= content) break;
            size_t s = i;
            while (i < content && !isspace((unsigned char)line[i])) i++;
            fs[nf] = s;
            fl[nf] = i - s;
            nf++;
        }
        int removed = 0;
        for (int f = 1; f < nf; f++)
            if (a21_is_redirect_name(line + fs[f], fl[f])) removed++;

        if (nf < 2 || removed == 0)
        {
            a21_append(outt, line, n);
            a21_append(outt, "\r\n", 2);
        }
        else if (removed < nf - 1)
        {
            a21_append(outt, line + fs[0], fl[0]);
            for (int f = 1; f < nf; f++)
            {
                if (a21_is_redirect_name(line + fs[f], fl[f])) continue;
                a21_append(outt, " ", 1);
                a21_append(outt, line + fs[f], fl[f]);
            }
            if (hash)
            {
                a21_append(outt, " ", 1);
                a21_append(outt, hash, n - content);
            }
            a21_append(outt, "\r\n", 2);
        }

        /* Next line: \r\n, \r or \n each end one. */
        if (le < len && text[le] == '\r' && le + 1 < len && text[le + 1] == '\n') le++;
        ls = le + 1;
    }
}

/* Write-HostsLines: written even when marked read-only, hidden or system (block
 * lists tell people to do that), with the attributes put back after. */
static BOOL a21_write_hosts(const wchar_t *path, const a21_text *t, DWORD *err)
{
    DWORD attrs = GetFileAttributesW(path);
    if (attrs == INVALID_FILE_ATTRIBUTES) { *err = GetLastError(); return FALSE; }
    DWORD blocking = FILE_ATTRIBUTE_READONLY | FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM;
    if (attrs & blocking)
    {
        DWORD plain = attrs & ~blocking;
        SetFileAttributesW(path, plain ? plain : FILE_ATTRIBUTE_NORMAL);
    }
    HANDLE h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, TRUNCATE_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    BOOL ok = h != INVALID_HANDLE_VALUE;
    DWORD wr = 0;
    if (ok && t->len) ok = WriteFile(h, t->buf, (DWORD)t->len, &wr, NULL) && wr == t->len;
    *err = ok ? 0 : GetLastError();
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    if (attrs & blocking) SetFileAttributesW(path, attrs);
    return ok;
}

/* Every IPv4 address a name resolves to, comma separated, the way the game will
 * see it: through ws2_32, which is where a17hosts.dylib answers from the
 * bottle's hosts file. Nothing like ipconfig /flushdns is needed first; the
 * dylib rereads the file whenever its modification time changes. */
static BOOL a21_resolves_to(const wchar_t *name, const wchar_t *address, wchar_t *seen, size_t cap)
{
    seen[0] = 0;
    ADDRINFOW hints, *res = NULL;
    ZeroMemory(&hints, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int rc = GetAddrInfoW(name, NULL, &hints, &res);
    if (rc != 0)
    {
        _snwprintf(seen, cap - 1, L"nothing (lookup error %d)", rc);
        seen[cap - 1] = 0;
        return FALSE;
    }
    BOOL match = FALSE;
    for (ADDRINFOW *a = res; a; a = a->ai_next)
    {
        wchar_t ip[64];
        DWORD iplen = 64;
        if (WSAAddressToStringW(a->ai_addr, (DWORD)a->ai_addrlen, NULL, ip, &iplen) != 0) continue;
        if (a->ai_family == AF_INET6) continue;
        wchar_t *colon = wcschr(ip, L':');
        if (colon) *colon = 0;
        if (!_wcsicmp(ip, address)) match = TRUE;
        if (!wcsstr(seen, ip))
        {
            if (seen[0]) wcsncat(seen, L", ", cap - wcslen(seen) - 1);
            wcsncat(seen, ip, cap - wcslen(seen) - 1);
        }
    }
    FreeAddrInfoW(res);
    return match;
}

/* Remove-RedirectHostsEntry (-Cleanup): only writes when something changes. */
static int a21_remove_hosts_entry(wchar_t *error, size_t cap)
{
    wchar_t path[MAX_PATH];
    a21_hosts_path(path, MAX_PATH);
    size_t len = 0;
    char *text = read_all_utf8(path, &len);
    if (!text)
    {
        _snwprintf(error, cap - 1, L"Could not read %s (Windows error %lu).", path, GetLastError());
        error[cap - 1] = 0;
        return 0;
    }
    a21_text kept = {0};
    a21_remove_redirect_names(text, len, &kept);
    /* Compare the kept lines with the file's own lines, line endings aside. */
    a21_text normalised = {0};
    {
        const char *t = text;
        size_t n = len;
        if (n >= 3 && (unsigned char)t[0] == 0xEF && (unsigned char)t[1] == 0xBB &&
            (unsigned char)t[2] == 0xBF) { t += 3; n -= 3; }
        size_t ls = 0;
        while (ls < n)
        {
            size_t le = ls;
            while (le < n && t[le] != '\r' && t[le] != '\n') le++;
            a21_append(&normalised, t + ls, le - ls);
            a21_append(&normalised, "\r\n", 2);
            if (le < n && t[le] == '\r' && le + 1 < n && t[le + 1] == '\n') le++;
            ls = le + 1;
        }
    }
    BOOL changed = kept.len != normalised.len ||
                   (kept.len && memcmp(kept.buf, normalised.buf, kept.len));
    BOOL ok = TRUE;
    if (changed)
    {
        DWORD err;
        ok = a21_write_hosts(path, &kept, &err);
        if (!ok)
        {
            _snwprintf(error, cap - 1, L"Hosts file write failed: Windows error %lu.", err);
            error[cap - 1] = 0;
        }
    }
    free(text);
    free(kept.buf);
    free(normalised.buf);
    return ok;
}

/* Set-RedirectHostsEntry: replaces any earlier redirect with this server's
 * address, then checks that it resolves. Tries for about 20 s, as the script
 * does for antivirus that holds the file open on Windows. */
static int a21_set_hosts_entry(const wchar_t *address, wchar_t *error, size_t cap)
{
    wchar_t path[MAX_PATH], last[1024] = L"";
    a21_hosts_path(path, MAX_PATH);
    char addr8[64];
    WideCharToMultiByte(CP_UTF8, 0, address, -1, addr8, sizeof(addr8), NULL, NULL);

    for (int attempt = 1; attempt <= A21_HOSTS_ATTEMPTS; attempt++)
    {
        size_t len = 0;
        char *text = read_all_utf8(path, &len);
        if (!text)
        {
            _snwprintf(last, 1023, L"Could not read %s (Windows error %lu).", path, GetLastError());
        }
        else
        {
            a21_text t = {0};
            a21_remove_redirect_names(text, len, &t);
            free(text);
            for (size_t i = 0; i < A21_NREDIRECT; i++)
            {
                char line[256];
                int n = _snprintf(line, sizeof(line), "%s %ls\r\n", addr8, A21_REDIRECT_HOSTS[i]);
                if (n > 0) a21_append(&t, line, (size_t)n);
            }
            DWORD err;
            BOOL ok = a21_write_hosts(path, &t, &err);
            free(t.buf);
            if (!ok)
                _snwprintf(last, 1023, L"Access to the path '%s' failed (Windows error %lu).", path, err);
            else
            {
                wchar_t seen[512];
                if (a21_resolves_to(A21_REDIRECT_HOSTS[0], address, seen, 512)) return 1;
                _snwprintf(last, 1023, L"%s resolves to %s, not %s", A21_REDIRECT_HOSTS[0], seen, address);
            }
        }
        last[1023] = 0;
        if (attempt < A21_HOSTS_ATTEMPTS) Sleep(1000);
    }
    _snwprintf(error, cap - 1, L"Hosts file write failed after %d attempts: %s",
               A21_HOSTS_ATTEMPTS, last);
    error[cap - 1] = 0;
    return 0;
}

/* ------------------------------------------------------------ the helpers */

typedef struct {
    HANDLE process;
    HANDLE stdin_write;
    DWORD  game_pid;
    wchar_t log[MAX_PATH];
} a21_math;

/* The shim's own step; the script needs none of it. The maths bridge loads the
 * client pack's ucrt\ucrtbase.dll into FIFA by its full path and expects a
 * second module beside the system one. Wine's default load order tries its
 * builtin first, finds the ucrtbase FIFA already has loaded and hands that
 * back, so the bridge saw no new module and gave up ("FIFA did not load the
 * bundled maths library"). With no bridge report the server groups this Mac by
 * the bottle's Windows build, "pre24h2", where nobody else is, and matchmaking
 * never pairs it.
 *
 * native,builtin for ucrtbase, for the game and the bridge only, lets the file
 * at that path load as itself. FIFA's own start-up is unchanged: neither its
 * folder nor system32 holds a native ucrtbase, so its imports still bind to
 * Wine's until the bridge switches them. The bridge needs it as well: it reads
 * the pinned copy's version and FMA3 state in its own process, and handed the
 * builtin it reports Wine's version (10.0.14393) with FMA3 off -- a different
 * group, and not the maths FIFA then runs.
 *
 * Wine opens a program's AppDefaults key once per process, so this has to be
 * in place before FIFA starts. */
static BOOL a21_prefer_pinned_ucrt(const wchar_t *program, LSTATUS *err)
{
    static const wchar_t value[] = L"native,builtin";
    wchar_t key[MAX_PATH];
    _snwprintf(key, MAX_PATH - 1, L"Software\\Wine\\AppDefaults\\%s\\DllOverrides", program);
    key[MAX_PATH - 1] = 0;
    HKEY k;
    LSTATUS st = RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL);
    if (st == ERROR_SUCCESS)
    {
        st = RegSetValueExW(k, L"ucrtbase", 0, REG_SZ, (const BYTE *)value, sizeof(value));
        RegCloseKey(k);
    }
    *err = st;
    return st == ERROR_SUCCESS;
}

/* Start-MathBridge. Its standard input stays open for the code, which only goes
 * to it once the launch is ready; its output goes to a file beside its log
 * (the script redirects it to pipes it never reads). */
static BOOL a21_start_math_bridge(const wchar_t *pack, const wchar_t *game_path, DWORD game_pid,
                                  const wchar_t *log, a21_math *m, wchar_t *why, size_t cap)
{
    wchar_t helper[MAX_PATH], dll[MAX_PATH];
    join(helper, MAX_PATH, pack, L"Aurora21-MathBridge.exe");
    join(dll, MAX_PATH, pack, L"ucrt\\ucrtbase.dll");
    const wchar_t *missing = !file_exists(helper) ? L"Aurora21-MathBridge.exe"
                           : !file_exists(dll) ? L"ucrtbase.dll" : NULL;
    if (missing)
    {
        _snwprintf(why, cap - 1, L"%s is not in this client pack", missing);
        why[cap - 1] = 0;
        return FALSE;
    }
    wchar_t cmd[4096];
    int n = _snwprintf(cmd, 4095,
                       L"\"%s\" --pid %lu --game \"%s\" --dll \"%s\" --log \"%s\" --code-stdin",
                       helper, game_pid, game_path, dll, log);
    for (size_t i = 0; n > 0 && i < sizeof(A21_MATH_REPORT_HOSTS) / sizeof(A21_MATH_REPORT_HOSTS[0]); i++)
        n += _snwprintf(cmd + n, 4095 - n, L" --report \"https://%s/client/launch/math\"",
                        A21_MATH_REPORT_HOSTS[i]);
    cmd[4095] = 0;

    wchar_t stdio_log[MAX_PATH];
    _snwprintf(stdio_log, MAX_PATH - 1, L"%s.stdio", log);
    stdio_log[MAX_PATH - 1] = 0;
    HANDLE child_in, parent_in;
    if (!a21_pipe(&child_in, &parent_in, TRUE))
    {
        _snwprintf(why, cap - 1, L"no pipe (Windows error %lu)", GetLastError());
        why[cap - 1] = 0;
        return FALSE;
    }
    HANDLE outh = a21_inheritable_file(stdio_log, TRUE);
    HANDLE p = a21_spawn(cmd, pack, child_in, outh, outh, NULL);
    DWORD err = GetLastError();
    CloseHandle(child_in);
    if (outh != INVALID_HANDLE_VALUE) CloseHandle(outh);
    if (!p)
    {
        CloseHandle(parent_in);
        _snwprintf(why, cap - 1, L"Windows error %lu starting it", err);
        why[cap - 1] = 0;
        return FALSE;
    }
    m->process = p;
    m->stdin_write = parent_in;
    m->game_pid = game_pid;
    wcsncpy(m->log, log, MAX_PATH - 1);
    m->log[MAX_PATH - 1] = 0;
    return TRUE;
}

/* Submit-MathBridgeCode: the code goes only to the helper of the process the
 * trust patch and auth bridge used; its standard input closes either way. */
static void a21_submit_math_code(a21_math *m, DWORD game_pid, const char *code)
{
    if (!m->process) return;
    if (m->stdin_write)
    {
        if (code && m->game_pid == game_pid &&
            WaitForSingleObject(m->process, 0) == WAIT_TIMEOUT)
        {
            char line[64];
            int n = _snprintf(line, sizeof(line), "%s\r\n", code);
            DWORD wr;
            if (n > 0) WriteFile(m->stdin_write, line, (DWORD)n, &wr, NULL);
            SecureZeroMemory(line, sizeof(line));
        }
        CloseHandle(m->stdin_write);
        m->stdin_write = NULL;
    }
}

/* The text after "<tag> " on the first line starting with it, or NULL. */
static BOOL a21_line_value(const char *text, const char *tag, char *dst, size_t cap)
{
    size_t tl = strlen(tag);
    for (const char *p = text; p && *p; )
    {
        if (!strncmp(p, tag, tl))
        {
            const char *v = p + tl;
            size_t n = strcspn(v, "\r\n");
            if (n >= cap) n = cap - 1;
            memcpy(dst, v, n);
            dst[n] = 0;
            return TRUE;
        }
        p = strchr(p, '\n');
        if (p) p++;
    }
    return FALSE;
}

static BOOL a21_has_line(const char *text, const char *tag)
{
    char tmp[8];
    return a21_line_value(text, tag, tmp, sizeof(tmp));
}

/* Get-MathBridgeStatus / Format-MathBridgeResult: one [INFO] line. */
static void a21_math_status(a21_math *m)
{
    if (!m->process) return;
    const wchar_t *leaf = a21_leaf(m->log);
    char *text = read_all_utf8(m->log, NULL);
    if (!text) text = _strdup("");
    char math[512];
    BOOL has_math = text && a21_line_value(text, "[MATH] ", math, sizeof(math));
    if (WaitForSingleObject(m->process, 0) == WAIT_TIMEOUT)
    {
        if (has_math && a21_has_line(text, "[READY] Maths bridge installed"))
            out(L"[INFO] maths bridge: FIFA uses the pinned ucrtbase (%S); the helper is reporting it (see %s)\n",
                math, leaf);
        else
            out(L"[INFO] maths bridge: switching FIFA's maths to the pinned ucrtbase; the helper reports it itself (see %s)\n",
                leaf);
        free(text);
        return;
    }
    DWORD code = 1;
    GetExitCodeProcess(m->process, &code);
    if (code == 0 && has_math && a21_has_line(text, "[READY] Maths bridge installed for PID "))
    {
        if (a21_has_line(text, "[REPORTED] "))
            out(L"[INFO] maths bridge: FIFA uses the pinned ucrtbase (%S); reported\n", math);
        else
            out(L"[INFO] maths bridge: FIFA uses the pinned ucrtbase (%S) but it was not reported; pairing uses the Windows build\n",
                math);
    }
    else
    {
        char reason[512];
        if (a21_line_value(text, "[ERROR] ", reason, sizeof(reason)))
        {
            size_t n = strlen(reason);
            while (n && reason[n - 1] == '.') reason[--n] = 0;
            out(L"[INFO] maths bridge: %S; pairing uses the Windows build\n", reason);
        }
        else
            out(L"[INFO] maths bridge: exit %lu; pairing uses the Windows build\n", code);
    }
    free(text);
}

/* ------------------------------------------------- the friendlies parser */

/* Not in the script: a fix for this client. Aurora's Online Friendlies house
 * rules end with "lastPlayedFriend":0, and CardsDLL hands that key to a reader
 * that expects an object and only stops at the object's end. Given a number it
 * reads on to the end of the text and spins there for good: one CardsDLL
 * thread at 100%, the screen frozen, Esc dead. The server's own templates
 * carry the same 0, so it is not a bad response to one player.
 *
 * The key's id is 0x25f. Where CardsDLL dispatches on it, the jump to the
 * object reader becomes a 6-byte nop, and the key goes the way of every key
 * the parser does not know: its value is skipped. The friend shown as last
 * played is all that is lost. The bytes either side are checked first, so any
 * other build of CardsDLL is left alone.
 *
 * CardsDLL is not loaded yet when the game is held for the other patches;
 * FIFA loads it when Ultimate Team opens, minutes later or never. So a copy of
 * this program waits beside the game (-WatchFriendlies), patches CardsDLL when
 * it appears -- and again if it is ever loaded afresh -- and goes when the
 * game does. By then the game is long past its copy protection's start-up
 * phase, the one a patch must not land in. */
#define A21_CARDS_DLL       L"CardsDLL_Win64_retail.dll"
#define A21_CARDS_SITE_RVA  0x35564d
#define A21_CARDS_JUMP_AT   18          /* the je at RVA 0x35565f */
#define A21_CARDS_JUMP_LEN  6

static const BYTE A21_CARDS_SITE[33] = {
    0x41, 0x8b, 0xd7,                       /* mov edx, r15d                  */
    0x81, 0xea, 0x10, 0x02, 0x00, 0x00,     /* sub edx, 0x210                 */
    0x0f, 0x84, 0x91, 0x03, 0x00, 0x00,     /* je  ...                        */
    0x83, 0xea, 0x4f,                       /* sub edx, 0x4f    (key 0x25f)   */
    0x0f, 0x84, 0xf8, 0x02, 0x00, 0x00,     /* je  the object reader          */
    0x83, 0xea, 0x01,                       /* sub edx, 1                     */
    0x0f, 0x84, 0x32, 0x02, 0x00, 0x00,     /* je  ...                        */
};
static const BYTE A21_CARDS_SITE_PATCHED[33] = {
    0x41, 0x8b, 0xd7,
    0x81, 0xea, 0x10, 0x02, 0x00, 0x00,
    0x0f, 0x84, 0x91, 0x03, 0x00, 0x00,
    0x83, 0xea, 0x4f,
    0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00,     /* nop word [rax+rax]             */
    0x83, 0xea, 0x01,
    0x0f, 0x84, 0x32, 0x02, 0x00, 0x00,
};

static BYTE *a21_module_base(DWORD pid, const wchar_t *name)
{
    BYTE *base = NULL;
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, pid);
    if (s == INVALID_HANDLE_VALUE) return NULL;
    MODULEENTRY32W me;
    me.dwSize = sizeof(me);
    for (BOOL ok = Module32FirstW(s, &me); ok && !base; ok = Module32NextW(s, &me))
        if (!_wcsicmp(me.szModule, name)) base = me.modBaseAddr;
    CloseHandle(s);
    return base;
}

static BOOL a21_read_cards_site(HANDLE game, BYTE *base, BYTE *dst)
{
    SIZE_T n = 0;
    return ReadProcessMemory(game, base + A21_CARDS_SITE_RVA, dst, sizeof(A21_CARDS_SITE), &n) &&
           n == sizeof(A21_CARDS_SITE);
}

/* 1 patched now, 0 already patched, -1 not the build this fix knows,
 * -2 could not read or write it. The game is paused only for the write. */
static int a21_patch_cards(HANDLE game, BYTE *base)
{
    BYTE cur[sizeof(A21_CARDS_SITE)];
    if (!a21_read_cards_site(game, base, cur)) return -2;
    if (!memcmp(cur, A21_CARDS_SITE_PATCHED, sizeof(cur))) return 0;
    if (memcmp(cur, A21_CARDS_SITE, sizeof(cur))) return -1;

    BYTE *at = base + A21_CARDS_SITE_RVA + A21_CARDS_JUMP_AT;
    BOOL ok = FALSE;
    DWORD old;
    SIZE_T n = 0;
    if (!a21_suspend_process(game, TRUE)) return -2;
    if (VirtualProtectEx(game, at, A21_CARDS_JUMP_LEN, PAGE_EXECUTE_READWRITE, &old))
    {
        ok = WriteProcessMemory(game, at, A21_CARDS_SITE_PATCHED + A21_CARDS_JUMP_AT,
                                A21_CARDS_JUMP_LEN, &n) && n == A21_CARDS_JUMP_LEN;
        VirtualProtectEx(game, at, A21_CARDS_JUMP_LEN, old, &old);
        FlushInstructionCache(game, at, A21_CARDS_JUMP_LEN);
    }
    a21_suspend_process(game, FALSE);
    return ok && a21_read_cards_site(game, base, cur) &&
           !memcmp(cur, A21_CARDS_SITE_PATCHED, sizeof(cur)) ? 1 : -2;
}

static void a21_clock(wchar_t *dst)
{
    SYSTEMTIME t;
    GetLocalTime(&t);
    _snwprintf(dst, 15, L"%02u:%02u:%02u", t.wHour, t.wMinute, t.wSecond);
    dst[15] = 0;
}

/* -WatchFriendlies <pid>. Writes only to its standard output, which the game's
 * launch points at friendlies-patch.log. Polls for CardsDLL twice a second; once
 * it is seen to, only rereads those 33 bytes every two seconds, so the module
 * list is not walked for the rest of the session. */
static int a21_watch_friendlies(DWORD pid)
{
    wchar_t now[16];
    HANDLE game = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_INFORMATION | PROCESS_VM_READ |
                              PROCESS_VM_WRITE | PROCESS_VM_OPERATION | PROCESS_SUSPEND_RESUME,
                              FALSE, pid);
    if (!game)
    {
        out(L"[ERROR] FIFA 21 (PID %lu) could not be opened: Windows error %lu\n", pid, GetLastError());
        return 3;
    }
    a21_clock(now);
    out(L"[WAIT] %s waiting for Ultimate Team to load %s in FIFA 21 (PID %lu)\n", now, A21_CARDS_DLL, pid);

    BYTE *seen = NULL;
    int failures = 0, rc = 0;
    while (WaitForSingleObject(game, seen ? 2000 : 500) == WAIT_TIMEOUT)
    {
        BYTE cur[sizeof(A21_CARDS_SITE)];
        if (seen)
        {
            if (a21_read_cards_site(game, seen, cur) && !memcmp(cur, A21_CARDS_SITE_PATCHED, sizeof(cur)))
                continue;
            seen = NULL;    /* unloaded, or loaded afresh */
        }
        BYTE *base = a21_module_base(pid, A21_CARDS_DLL);
        if (!base) continue;
        int r = a21_patch_cards(game, base);
        a21_clock(now);
        if (r == -2)
        {
            if (++failures < 5) continue;
            out(L"[ERROR] %s %s at %p could not be patched: Windows error %lu; Online Friendlies will freeze\n",
                now, A21_CARDS_DLL, base, GetLastError());
            rc = 4;
            break;
        }
        if (r == -1)
        {
            out(L"[SKIPPED] %s %s at %p is not the build this fix knows; left alone\n", now, A21_CARDS_DLL, base);
            rc = 2;
            break;
        }
        out(r == 1 ? L"[PATCHED] %s %s at %p: \"lastPlayedFriend\" is skipped\n"
                   : L"[ALREADY] %s %s at %p: \"lastPlayedFriend\" is skipped\n", now, A21_CARDS_DLL, base);
        seen = base;
        failures = 0;
    }
    if (rc == 0)
    {
        a21_clock(now);
        out(L"[DONE] %s FIFA 21 has closed\n", now);
    }
    CloseHandle(game);
    return rc;
}

/* Starts the watcher above for PID, detached: like the maths helper it
 * outlives this program, and it gets none of this program's standard handles,
 * so the launcher's pipes close when this program exits. */
static BOOL a21_start_friendlies_watch(const wchar_t *script_path, DWORD pid, const wchar_t *log,
                                       wchar_t *why, size_t cap)
{
    wchar_t self[MAX_PATH], dir[MAX_PATH], cmd[4096];
    DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (!n || n >= MAX_PATH)
    {
        _snwprintf(why, cap - 1, L"this program's path is unknown (Windows error %lu)", GetLastError());
        why[cap - 1] = 0;
        return FALSE;
    }
    a21_parent_dir(self, dir, MAX_PATH);
    _snwprintf(cmd, 4095, L"\"%s\" -File \"%s\" -WatchFriendlies %lu", self, script_path, pid);
    cmd[4095] = 0;
    HANDLE logh = a21_inheritable_file(log, TRUE);
    if (logh == INVALID_HANDLE_VALUE)
    {
        _snwprintf(why, cap - 1, L"%s could not be written (Windows error %lu)", a21_leaf(log), GetLastError());
        why[cap - 1] = 0;
        return FALSE;
    }
    HANDLE p = a21_spawn(cmd, dir, NULL, logh, logh, NULL);
    DWORD err = GetLastError();
    CloseHandle(logh);
    if (!p)
    {
        _snwprintf(why, cap - 1, L"Windows error %lu starting it", err);
        why[cap - 1] = 0;
        return FALSE;
    }
    CloseHandle(p);
    return TRUE;
}

/* Test-TrustPatched: "[SUCCESS] Patched", the GOS 2015 CA patched or already
 * patched on one line, and for a direct copy the Origin client bootstrap
 * bypass the same way. */
static BOOL a21_line_has(const char *text, const char *a, const char *b)
{
    for (const char *p = text; p && *p; )
    {
        size_t n = strcspn(p, "\r\n");
        const char *hit = NULL;
        for (const char *q = p; q < p + n; q++)
            if (!strncmp(q, a, strlen(a))) { hit = q; break; }
        if (hit)
        {
            for (const char *q = hit; q < p + n; q++)
                if (!strncmp(q, b, strlen(b))) return TRUE;
        }
        p = strchr(p, '\n');
        if (p) p++;
    }
    return FALSE;
}

static BOOL a21_trust_patched(const char *text, BOOL patch_origin)
{
    if (!text || !strstr(text, "[SUCCESS] Patched")) return FALSE;
    if (!a21_line_has(text, "[PATCHED]", "GOS 2015 Certificate Authority") &&
        !a21_line_has(text, "[ALREADY]", "GOS 2015 Certificate Authority"))
        return FALSE;
    if (patch_origin &&
        !a21_line_has(text, "[PATCHED]", "Origin client bootstrap bypass") &&
        !a21_line_has(text, "[ALREADY]", "Origin client bootstrap bypass"))
        return FALSE;
    return TRUE;
}

/* ------------------------------------------------------------- client mod
 *
 * Install-ClientMod, Test-ClientModRequired and Send-ClientModReport of
 * Start-Aurora21.ps1, with the prebuilt-patch path of Client-Mods.ps1, in C.
 * The pack's script gets them from PowerShell; this bottle has none, and the
 * pack's server exe has no command for it (its usage lists trust-patch,
 * export-trust-anchors, redirector, ... and nothing that installs a mod).
 *
 * What it does, as the script does: ask the server for its client mod
 * (/client/mods/manifest.json), download the patch (resuming a partial file),
 * check its SHA-256, and build a ModData folder under
 * %LOCALAPPDATA%\Aurora21\UltimateTeam\client-mods\leaderboards\<revision>:
 * every archive of the game's Data and Patch folders linked (hard link, else
 * symbolic link; never a 40 GB copy), the nine files the patch changes rebuilt from the
 * game's own copy and checked against their result hash, and the mod's own
 * archives added. Nothing in the game folder changes. FIFA then starts with
 * -dataPath <ModData>. The profile and its compiled-profile.json are the
 * script's own, so the two read each other's.
 *
 * The server requires the mod now (GET /client/mods/policy): a FIFA without
 * it is refused at Ultimate Team's login, and the player sees a connection
 * error. Everything is logged to client-mod.log beside the other helper logs.
 */

#define CM_JSON_MAX  (1u << 20)
#define CM_PATH      1024

typedef struct
{
    HMODULE dll;
    HINTERNET (WINAPI *Open)(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
    HINTERNET (WINAPI *Connect)(HINTERNET, LPCWSTR, INTERNET_PORT, DWORD);
    HINTERNET (WINAPI *OpenRequest)(HINTERNET, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR *, DWORD);
    BOOL (WINAPI *SetTimeouts)(HINTERNET, int, int, int, int);
    BOOL (WINAPI *SendRequest)(HINTERNET, LPCWSTR, DWORD, LPVOID, DWORD, DWORD, DWORD_PTR);
    BOOL (WINAPI *ReceiveResponse)(HINTERNET, LPVOID);
    BOOL (WINAPI *QueryHeaders)(HINTERNET, DWORD, LPCWSTR, LPVOID, LPDWORD, LPDWORD);
    BOOL (WINAPI *ReadData)(HINTERNET, LPVOID, DWORD, LPDWORD);
    BOOL (WINAPI *CloseHandle_)(HINTERNET);
} cm_winhttp;

static cm_winhttp cm_wh;
static HANDLE cm_logh = INVALID_HANDLE_VALUE;
static wchar_t cm_err[768];
/* What this launch ended up with, for the report to matchmaking. */
static char cm_revision[65];
static const char *cm_install_state = "skipped";

static void cm_log_line(const wchar_t *w)
{
    if (cm_logh == INVALID_HANDLE_VALUE) return;
    char u[3072];
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, u, (int)sizeof(u) - 3, NULL, NULL);
    if (n <= 0) return;
    u[n - 1] = '\r';
    u[n] = '\n';
    DWORD wr;
    WriteFile(cm_logh, u, (DWORD)n + 1, &wr, NULL);
}

/* Progress for the launcher ([INFO] lines) and for the log. */
static void cm_say(const wchar_t *fmt, ...)
{
    wchar_t buf[1024];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(buf, 1023, fmt, ap);
    va_end(ap);
    buf[1023] = 0;
    cm_log_line(buf);
    out(L"[INFO] %s\n", buf);
}

/* Detail for the log only. */
static void cm_note(const wchar_t *fmt, ...)
{
    wchar_t buf[1024];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(buf, 1023, fmt, ap);
    va_end(ap);
    buf[1023] = 0;
    cm_log_line(buf);
}

static BOOL cm_fail(const wchar_t *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(cm_err, 767, fmt, ap);
    va_end(ap);
    cm_err[767] = 0;
    return FALSE;
}

static void cm_path(wchar_t *dst, const wchar_t *a, const wchar_t *b)
{
    _snwprintf(dst, CM_PATH - 1, L"%s\\%s", a, b);
    dst[CM_PATH - 1] = 0;
}

static BOOL cm_is_hex64(const char *s)
{
    if (!s || strlen(s) != 64) return FALSE;
    for (int i = 0; i < 64; i++)
        if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return FALSE;
    return TRUE;
}

static void cm_widen(const char *s, wchar_t *dst, size_t cap)
{
    if (!MultiByteToWideChar(CP_UTF8, 0, s, -1, dst, (int)cap)) dst[0] = 0;
    dst[cap - 1] = 0;
}

/* --------------------------------------------------------------- SHA-256 */

typedef struct { BCRYPT_ALG_HANDLE alg; BCRYPT_HASH_HANDLE h; BOOL ok; } cm_sha;

static void cm_sha_begin(cm_sha *s)
{
    s->alg = NULL;
    s->h = NULL;
    s->ok = BCryptOpenAlgorithmProvider(&s->alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) == 0 &&
            BCryptCreateHash(s->alg, &s->h, NULL, 0, NULL, 0, 0) == 0;
}

static void cm_sha_add(cm_sha *s, const void *p, size_t n)
{
    const BYTE *b = p;
    while (s->ok && n)
    {
        ULONG c = n > (1u << 24) ? (1u << 24) : (ULONG)n;
        if (BCryptHashData(s->h, (PUCHAR)b, c, 0) != 0) s->ok = FALSE;
        b += c;
        n -= c;
    }
}

static BOOL cm_sha_end(cm_sha *s, char hex[65])
{
    BYTE d[32];
    BOOL ok = s->ok && BCryptFinishHash(s->h, d, 32, 0) == 0;
    if (s->h) BCryptDestroyHash(s->h);
    if (s->alg) BCryptCloseAlgorithmProvider(s->alg, 0);
    if (ok)
        for (int i = 0; i < 32; i++) _snprintf(hex + i * 2, 3, "%02x", d[i]);
    else
        hex[0] = 0;
    return ok;
}

static BOOL cm_sha_file(const wchar_t *path, char hex[65])
{
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                           OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (h == INVALID_HANDLE_VALUE) return cm_fail(L"%s could not be read (Windows error %lu).", path, GetLastError());
    BYTE *buf = malloc(1 << 20);
    if (!buf) { CloseHandle(h); return cm_fail(L"Out of memory."); }
    cm_sha s;
    cm_sha_begin(&s);
    DWORD rd;
    BOOL read_ok = TRUE;
    for (;;)
    {
        if (!ReadFile(h, buf, 1 << 20, &rd, NULL)) { read_ok = FALSE; break; }
        if (!rd) break;
        cm_sha_add(&s, buf, rd);
    }
    free(buf);
    CloseHandle(h);
    BOOL ok = cm_sha_end(&s, hex);
    if (!read_ok) return cm_fail(L"%s could not be read to the end.", path);
    return ok || cm_fail(L"SHA-256 is not available.");
}

/* ------------------------------------------------------------------ JSON */

enum { CJ_NULL, CJ_BOOL, CJ_NUM, CJ_STR, CJ_ARR, CJ_OBJ };

typedef struct cm_j
{
    int t;
    char *s;
    long long n;
    struct cm_j **v;
    char **k;
    int c, cap;
} cm_j;

static void cj_free(cm_j *j)
{
    if (!j) return;
    for (int i = 0; i < j->c; i++)
    {
        cj_free(j->v[i]);
        if (j->k) free(j->k[i]);
    }
    free(j->v);
    free(j->k);
    free(j->s);
    free(j);
}

static void cj_ws(const char **p)
{
    while (**p == ' ' || **p == '\t' || **p == '\r' || **p == '\n') (*p)++;
}

static char *cj_string(const char **p)
{
    if (**p != '"') return NULL;
    (*p)++;
    size_t cap = 64, n = 0;
    char *o = malloc(cap);
    if (!o) return NULL;
    while (**p && **p != '"')
    {
        unsigned ch = (unsigned char)**p;
        (*p)++;
        if (ch == '\\')
        {
            ch = (unsigned char)**p;
            if (!ch) break;
            (*p)++;
            switch (ch)
            {
            case 'n': ch = '\n'; break;
            case 'r': ch = '\r'; break;
            case 't': ch = '\t'; break;
            case 'b': ch = '\b'; break;
            case 'f': ch = '\f'; break;
            case 'u':
            {
                unsigned v = 0;
                for (int i = 0; i < 4; i++)
                {
                    char h = **p;
                    if (!isxdigit((unsigned char)h)) { free(o); return NULL; }
                    v = v * 16 + (unsigned)(h <= '9' ? h - '0' : (h | 0x20) - 'a' + 10);
                    (*p)++;
                }
                ch = v;
                break;
            }
            default: break;
            }
        }
        if (n + 5 >= cap)
        {
            cap *= 2;
            char *nb = realloc(o, cap);
            if (!nb) { free(o); return NULL; }
            o = nb;
        }
        if (ch < 0x80) o[n++] = (char)ch;
        else if (ch < 0x800) { o[n++] = (char)(0xC0 | (ch >> 6)); o[n++] = (char)(0x80 | (ch & 0x3F)); }
        else { o[n++] = (char)(0xE0 | (ch >> 12)); o[n++] = (char)(0x80 | ((ch >> 6) & 0x3F)); o[n++] = (char)(0x80 | (ch & 0x3F)); }
    }
    if (**p != '"') { free(o); return NULL; }
    (*p)++;
    o[n] = 0;
    return o;
}

static BOOL cj_push(cm_j *j, cm_j *child, char *key)
{
    if (j->c == j->cap)
    {
        int cap = j->cap ? j->cap * 2 : 8;
        cm_j **nv = realloc(j->v, (size_t)cap * sizeof(*nv));
        if (!nv) return FALSE;
        j->v = nv;
        if (j->t == CJ_OBJ)
        {
            char **nk = realloc(j->k, (size_t)cap * sizeof(*nk));
            if (!nk) return FALSE;
            j->k = nk;
        }
        j->cap = cap;
    }
    j->v[j->c] = child;
    if (j->t == CJ_OBJ) j->k[j->c] = key;
    j->c++;
    return TRUE;
}

static cm_j *cj_value(const char **p, int depth)
{
    if (depth > 16) return NULL;
    cj_ws(p);
    cm_j *j = calloc(1, sizeof(*j));
    if (!j) return NULL;
    char c = **p;
    if (c == '"')
    {
        j->t = CJ_STR;
        j->s = cj_string(p);
        if (!j->s) { cj_free(j); return NULL; }
    }
    else if (c == '{' || c == '[')
    {
        j->t = c == '{' ? CJ_OBJ : CJ_ARR;
        char close = c == '{' ? '}' : ']';
        (*p)++;
        cj_ws(p);
        if (**p == close) { (*p)++; return j; }
        for (;;)
        {
            char *key = NULL;
            cj_ws(p);
            if (j->t == CJ_OBJ)
            {
                key = cj_string(p);
                cj_ws(p);
                if (!key || **p != ':') { free(key); cj_free(j); return NULL; }
                (*p)++;
            }
            cm_j *child = cj_value(p, depth + 1);
            if (!child || !cj_push(j, child, key)) { cj_free(child); free(key); cj_free(j); return NULL; }
            cj_ws(p);
            if (**p == ',') { (*p)++; continue; }
            if (**p == close) { (*p)++; return j; }
            cj_free(j);
            return NULL;
        }
    }
    else if (!strncmp(*p, "true", 4)) { j->t = CJ_BOOL; j->n = 1; *p += 4; }
    else if (!strncmp(*p, "false", 5)) { j->t = CJ_BOOL; *p += 5; }
    else if (!strncmp(*p, "null", 4)) { j->t = CJ_NULL; *p += 4; }
    else if (c == '-' || (c >= '0' && c <= '9'))
    {
        char *end;
        j->t = CJ_NUM;
        j->n = _strtoi64(*p, &end, 10);
        while (*end == '.' || *end == 'e' || *end == 'E' || *end == '+' || *end == '-' || (*end >= '0' && *end <= '9')) end++;
        *p = end;
    }
    else { cj_free(j); return NULL; }
    return j;
}

static cm_j *cj_parse(const char *text)
{
    if ((unsigned char)text[0] == 0xEF && (unsigned char)text[1] == 0xBB && (unsigned char)text[2] == 0xBF) text += 3;
    const char *p = text;
    cm_j *j = cj_value(&p, 0);
    if (j) { cj_ws(&p); if (*p) { cj_free(j); return NULL; } }
    return j;
}

static const cm_j *cj_get(const cm_j *o, const char *key)
{
    if (!o || o->t != CJ_OBJ) return NULL;
    for (int i = 0; i < o->c; i++)
        if (!strcmp(o->k[i], key)) return o->v[i];
    return NULL;
}

static const char *cj_str(const cm_j *o, const char *key)
{
    const cm_j *v = cj_get(o, key);
    return v && v->t == CJ_STR ? v->s : NULL;
}

static long long cj_num(const cm_j *o, const char *key, long long dflt)
{
    const cm_j *v = cj_get(o, key);
    return v && v->t == CJ_NUM ? v->n : dflt;
}

/* A JSON string for a Windows path or any text: quotes and backslashes escaped. */
static void cm_json_str(const wchar_t *w, char *dst, size_t cap)
{
    char u[CM_PATH * 3];
    if (!WideCharToMultiByte(CP_UTF8, 0, w, -1, u, sizeof(u), NULL, NULL)) u[0] = 0;
    size_t n = 0;
    for (const char *p = u; *p && n + 8 < cap; p++)
    {
        if (*p == '"' || *p == '\\') dst[n++] = '\\';
        if ((unsigned char)*p < 0x20) continue;
        dst[n++] = *p;
    }
    dst[n] = 0;
}

/* CM-INFLATE-BEGIN: RFC 1951, after Mark Adler's puff.c. Whole input and output in
 * memory; returns 0 only when the stream ends exactly at outlen bytes. */
typedef struct
{
    const BYTE *in;
    size_t inlen, inpos;
    long bitbuf;
    int bitcnt;
    BYTE *out;
    size_t outlen, outpos;
} cm_inf;

typedef struct { short count[16]; short symbol[288]; } cm_huff;

static int cm_bits(cm_inf *s, int need)
{
    long val = s->bitbuf;
    while (s->bitcnt < need)
    {
        if (s->inpos >= s->inlen) return -1;
        val |= (long)s->in[s->inpos++] << s->bitcnt;
        s->bitcnt += 8;
    }
    s->bitbuf = val >> need;
    s->bitcnt -= need;
    return (int)(val & ((1L << need) - 1));
}

static int cm_decode(cm_inf *s, const cm_huff *h)
{
    int code = 0, first = 0, index = 0;
    for (int len = 1; len <= 15; len++)
    {
        int b = cm_bits(s, 1);
        if (b < 0) return -1;
        code |= b;
        int count = h->count[len];
        if (code - count < first) return h->symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    return -2;
}

static int cm_construct(cm_huff *h, const short *length, int n)
{
    short offs[16];
    for (int len = 0; len <= 15; len++) h->count[len] = 0;
    for (int sym = 0; sym < n; sym++) h->count[length[sym]]++;
    if (h->count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len <= 15; len++)
    {
        left <<= 1;
        left -= h->count[len];
        if (left < 0) return left;
    }
    offs[1] = 0;
    for (int len = 1; len < 15; len++) offs[len + 1] = (short)(offs[len] + h->count[len]);
    for (int sym = 0; sym < n; sym++)
        if (length[sym] != 0) h->symbol[offs[length[sym]]++] = (short)sym;
    return left;
}

static int cm_codes(cm_inf *s, const cm_huff *lencode, const cm_huff *distcode)
{
    static const short lens[29] = { 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258 };
    static const short lext[29] = { 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0 };
    static const short dists[30] = { 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577 };
    static const short dext[30] = { 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13 };
    int symbol;
    do
    {
        symbol = cm_decode(s, lencode);
        if (symbol < 0) return symbol;
        if (symbol < 256)
        {
            if (s->outpos >= s->outlen) return 1;
            s->out[s->outpos++] = (BYTE)symbol;
        }
        else if (symbol > 256)
        {
            symbol -= 257;
            if (symbol >= 29) return -10;
            int extra = cm_bits(s, lext[symbol]);
            if (extra < 0) return -1;
            size_t len = (size_t)(lens[symbol] + extra);
            symbol = cm_decode(s, distcode);
            if (symbol < 0) return symbol;
            extra = cm_bits(s, dext[symbol]);
            if (extra < 0) return -1;
            size_t dist = (size_t)(dists[symbol] + extra);
            if (dist > s->outpos) return -11;
            if (s->outpos + len > s->outlen) return 1;
            BYTE *to = s->out + s->outpos;
            const BYTE *from = to - dist;
            s->outpos += len;
            while (len--) *to++ = *from++;
        }
    } while (symbol != 256);
    return 0;
}

static int cm_stored(cm_inf *s)
{
    s->bitbuf = 0;
    s->bitcnt = 0;
    if (s->inpos + 4 > s->inlen) return 2;
    unsigned len = s->in[s->inpos] | ((unsigned)s->in[s->inpos + 1] << 8);
    unsigned nlen = s->in[s->inpos + 2] | ((unsigned)s->in[s->inpos + 3] << 8);
    s->inpos += 4;
    if (len != (~nlen & 0xffffu)) return -2;
    if (s->inpos + len > s->inlen) return 2;
    if (s->outpos + len > s->outlen) return 1;
    memcpy(s->out + s->outpos, s->in + s->inpos, len);
    s->inpos += len;
    s->outpos += len;
    return 0;
}

static int cm_fixed(cm_inf *s)
{
    short lengths[288];
    cm_huff lencode, distcode;
    int sym;
    for (sym = 0; sym < 144; sym++) lengths[sym] = 8;
    for (; sym < 256; sym++) lengths[sym] = 9;
    for (; sym < 280; sym++) lengths[sym] = 7;
    for (; sym < 288; sym++) lengths[sym] = 8;
    cm_construct(&lencode, lengths, 288);
    for (sym = 0; sym < 30; sym++) lengths[sym] = 5;
    cm_construct(&distcode, lengths, 30);
    return cm_codes(s, &lencode, &distcode);
}

static int cm_dynamic(cm_inf *s)
{
    static const short order[19] = { 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15 };
    short lengths[320];
    cm_huff lencode, distcode;
    int nlen = cm_bits(s, 5), ndist = cm_bits(s, 5), ncode = cm_bits(s, 4);
    if (nlen < 0 || ndist < 0 || ncode < 0) return -1;
    nlen += 257;
    ndist += 1;
    ncode += 4;
    if (nlen > 286 || ndist > 30) return -3;
    int index;
    for (index = 0; index < ncode; index++)
    {
        int b = cm_bits(s, 3);
        if (b < 0) return -1;
        lengths[order[index]] = (short)b;
    }
    for (; index < 19; index++) lengths[order[index]] = 0;
    if (cm_construct(&lencode, lengths, 19) != 0) return -4;
    index = 0;
    while (index < nlen + ndist)
    {
        int symbol = cm_decode(s, &lencode);
        if (symbol < 0) return symbol;
        if (symbol < 16) lengths[index++] = (short)symbol;
        else
        {
            int len = 0, rep, b;
            if (symbol == 16)
            {
                if (index == 0) return -5;
                len = lengths[index - 1];
                b = cm_bits(s, 2);
                rep = 3 + b;
            }
            else if (symbol == 17) { b = cm_bits(s, 3); rep = 3 + b; }
            else { b = cm_bits(s, 7); rep = 11 + b; }
            if (b < 0) return -1;
            if (index + rep > nlen + ndist) return -6;
            while (rep--) lengths[index++] = (short)len;
        }
    }
    if (lengths[256] == 0) return -9;
    int err = cm_construct(&lencode, lengths, nlen);
    if (err && (err < 0 || nlen != lencode.count[0] + lencode.count[1])) return -7;
    err = cm_construct(&distcode, lengths + nlen, ndist);
    if (err && (err < 0 || ndist != distcode.count[0] + distcode.count[1])) return -8;
    return cm_codes(s, &lencode, &distcode);
}

static int cm_inflate(const BYTE *in, size_t inlen, BYTE *out, size_t outlen)
{
    cm_inf s;
    memset(&s, 0, sizeof(s));
    s.in = in;
    s.inlen = inlen;
    s.out = out;
    s.outlen = outlen;
    int last, type, err;
    do
    {
        last = cm_bits(&s, 1);
        type = cm_bits(&s, 2);
        if (last < 0 || type < 0) return -1;
        err = type == 0 ? cm_stored(&s) : type == 1 ? cm_fixed(&s) : type == 2 ? cm_dynamic(&s) : -1;
        if (err) return err;
    } while (!last);
    return s.outpos == outlen ? 0 : -20;
}
/* CM-INFLATE-END */

/* ------------------------------------------------------------------- zip */

typedef struct
{
    HANDLE f;
    ULONGLONG size;
    BYTE *cd;
    DWORD cdsize;
    int count;
} cm_zip;

static unsigned cm_u16(const BYTE *p) { return (unsigned)p[0] | ((unsigned)p[1] << 8); }
static unsigned cm_u32(const BYTE *p) { return cm_u16(p) | (cm_u16(p + 2) << 16); }

static BOOL cm_read_at(HANDLE f, ULONGLONG off, void *buf, DWORD n)
{
    LARGE_INTEGER li;
    li.QuadPart = (LONGLONG)off;
    DWORD rd = 0;
    return SetFilePointerEx(f, li, NULL, FILE_BEGIN) && ReadFile(f, buf, n, &rd, NULL) && rd == n;
}

static void cm_zip_close(cm_zip *z)
{
    if (z->f != INVALID_HANDLE_VALUE && z->f) CloseHandle(z->f);
    free(z->cd);
    memset(z, 0, sizeof(*z));
    z->f = INVALID_HANDLE_VALUE;
}

static BOOL cm_zip_open(cm_zip *z, const wchar_t *path)
{
    memset(z, 0, sizeof(*z));
    z->f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    LARGE_INTEGER sz;
    if (z->f == INVALID_HANDLE_VALUE || !GetFileSizeEx(z->f, &sz))
    {
        DWORD err = GetLastError();
        cm_zip_close(z);
        return cm_fail(L"The client mod patch could not be opened (Windows error %lu).", err);
    }
    z->size = (ULONGLONG)sz.QuadPart;
    DWORD tail = z->size < 65557 ? (DWORD)z->size : 65557;
    BYTE *buf = malloc(tail);
    if (!buf || !cm_read_at(z->f, z->size - tail, buf, tail))
    {
        free(buf);
        cm_zip_close(z);
        return cm_fail(L"The client mod patch could not be read.");
    }
    long at = -1;
    for (long i = (long)tail - 22; i >= 0; i--)
        if (cm_u32(buf + i) == 0x06054b50u) { at = i; break; }
    if (at < 0) { free(buf); cm_zip_close(z); return cm_fail(L"The client mod patch is not a zip file."); }
    unsigned total = cm_u16(buf + at + 10), cdsize = cm_u32(buf + at + 12), cdoff = cm_u32(buf + at + 16);
    free(buf);
    if (total == 0xFFFF || cdsize == 0xFFFFFFFFu || cdoff == 0xFFFFFFFFu || cdsize > (64u << 20) ||
        (ULONGLONG)cdoff + cdsize > z->size)
    {
        cm_zip_close(z);
        return cm_fail(L"The client mod patch is a zip file this installer does not read.");
    }
    z->cd = malloc(cdsize ? cdsize : 1);
    if (!z->cd || !cm_read_at(z->f, cdoff, z->cd, cdsize))
    {
        cm_zip_close(z);
        return cm_fail(L"The client mod patch's directory could not be read.");
    }
    z->cdsize = cdsize;
    z->count = (int)total;
    return TRUE;
}

/* The entry's method, sizes and local header offset. */
static BOOL cm_zip_find(const cm_zip *z, const char *name, unsigned *method, unsigned *csize,
                        unsigned *usize, unsigned *lho)
{
    size_t want = strlen(name);
    DWORD p = 0;
    for (int i = 0; i < z->count; i++)
    {
        if (p + 46 > z->cdsize || cm_u32(z->cd + p) != 0x02014b50u) return FALSE;
        unsigned nl = cm_u16(z->cd + p + 28), el = cm_u16(z->cd + p + 30), cl = cm_u16(z->cd + p + 32);
        if (p + 46 + nl + el + cl > z->cdsize) return FALSE;
        if (nl == want && !memcmp(z->cd + p + 46, name, nl))
        {
            *method = cm_u16(z->cd + p + 10);
            *csize = cm_u32(z->cd + p + 20);
            *usize = cm_u32(z->cd + p + 24);
            *lho = cm_u32(z->cd + p + 42);
            return TRUE;
        }
        p += 46 + nl + el + cl;
    }
    return FALSE;
}

/* The entry's bytes, NUL terminated (the NUL is not counted in *len). Free with free(). */
static BYTE *cm_zip_read(const cm_zip *z, const char *name, size_t *len)
{
    unsigned method, csize, usize, lho;
    wchar_t wname[160];
    cm_widen(name, wname, 160);
    if (!cm_zip_find(z, name, &method, &csize, &usize, &lho))
    {
        cm_fail(L"The client mod patch lacks %s.", wname);
        return NULL;
    }
    BYTE head[30];
    if (!cm_read_at(z->f, lho, head, 30) || cm_u32(head) != 0x04034b50u)
    {
        cm_fail(L"The client mod patch's %s has a bad header.", wname);
        return NULL;
    }
    ULONGLONG data = (ULONGLONG)lho + 30 + cm_u16(head + 26) + cm_u16(head + 28);
    if (data + csize > z->size || (method != 0 && method != 8) || (method == 0 && csize != usize))
    {
        cm_fail(L"The client mod patch's %s cannot be read.", wname);
        return NULL;
    }
    BYTE *packed = malloc(csize ? csize : 1);
    BYTE *plain = malloc((size_t)usize + 1);
    if (!packed || !plain || !cm_read_at(z->f, data, packed, csize))
    {
        free(packed);
        free(plain);
        cm_fail(L"The client mod patch's %s could not be read.", wname);
        return NULL;
    }
    int rc = method == 0 ? (memcpy(plain, packed, usize), 0) : cm_inflate(packed, csize, plain, usize);
    free(packed);
    if (rc != 0)
    {
        free(plain);
        cm_fail(L"The client mod patch's %s is damaged (inflate %d).", wname, rc);
        return NULL;
    }
    plain[usize] = 0;
    if (len) *len = usize;
    return plain;
}

/* ------------------------------------------------------------------ HTTPS */

static BOOL cm_wh_load(void)
{
    if (cm_wh.dll) return cm_wh.Open != NULL;
    cm_wh.dll = LoadLibraryW(L"winhttp.dll");
    if (!cm_wh.dll) return FALSE;
    cm_wh.Open = (void *)GetProcAddress(cm_wh.dll, "WinHttpOpen");
    cm_wh.Connect = (void *)GetProcAddress(cm_wh.dll, "WinHttpConnect");
    cm_wh.OpenRequest = (void *)GetProcAddress(cm_wh.dll, "WinHttpOpenRequest");
    cm_wh.SetTimeouts = (void *)GetProcAddress(cm_wh.dll, "WinHttpSetTimeouts");
    cm_wh.SendRequest = (void *)GetProcAddress(cm_wh.dll, "WinHttpSendRequest");
    cm_wh.ReceiveResponse = (void *)GetProcAddress(cm_wh.dll, "WinHttpReceiveResponse");
    cm_wh.QueryHeaders = (void *)GetProcAddress(cm_wh.dll, "WinHttpQueryHeaders");
    cm_wh.ReadData = (void *)GetProcAddress(cm_wh.dll, "WinHttpReadData");
    cm_wh.CloseHandle_ = (void *)GetProcAddress(cm_wh.dll, "WinHttpCloseHandle");
    if (!cm_wh.Connect || !cm_wh.OpenRequest || !cm_wh.SetTimeouts || !cm_wh.SendRequest ||
        !cm_wh.ReceiveResponse || !cm_wh.QueryHeaders || !cm_wh.ReadData || !cm_wh.CloseHandle_)
        cm_wh.Open = NULL;
    return cm_wh.Open != NULL;
}

/* One HTTPS request to one of the server's fronts; the certificate is checked as
 * usual. Returns the HTTP status, or 0 when none came (cm_err says why).
 * A body that arrives goes to `file` when that is a handle (positioned by the
 * caller; a ranged request the server answers in full starts the file again),
 * else into *mem, NUL terminated and at most CM_JSON_MAX long.
 * `expect` is the download's total size, for the progress lines. */
static int cm_http(const wchar_t *method, const wchar_t *host, const wchar_t *path,
                   const char *post, ULONGLONG range_from, HANDLE file, char **mem,
                   ULONGLONG expect)
{
    if (mem) *mem = NULL;
    if (!cm_wh_load()) { cm_fail(L"WinHTTP is not available."); return 0; }
    int status = 0;
    HINTERNET ses = NULL, con = NULL, req = NULL;
    BYTE *chunk = NULL;
    char *body = NULL;

    ses = cm_wh.Open(L"Aurora21-Client", WINHTTP_ACCESS_TYPE_NO_PROXY, NULL, NULL, 0);
    if (!ses) { cm_fail(L"WinHTTP could not start (Windows error %lu).", GetLastError()); goto end; }
    cm_wh.SetTimeouts(ses, 15000, 15000, 30000, 60000);
    con = cm_wh.Connect(ses, host, INTERNET_DEFAULT_HTTPS_PORT, 0);
    req = con ? cm_wh.OpenRequest(con, method, path, NULL, WINHTTP_NO_REFERER,
                                  WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE) : NULL;
    if (!req) { cm_fail(L"%s: no connection (Windows error %lu).", host, GetLastError()); goto end; }

    wchar_t headers[256] = L"";
    if (post) _snwprintf(headers, 255, L"Content-Type: application/json\r\n");
    if (range_from)
    {
        size_t n = wcslen(headers);
        _snwprintf(headers + n, 255 - n, L"Range: bytes=%llu-\r\n", range_from);
    }
    headers[255] = 0;
    DWORD plen = post ? (DWORD)strlen(post) : 0;
    if (!cm_wh.SendRequest(req, headers[0] ? headers : WINHTTP_NO_ADDITIONAL_HEADERS,
                           headers[0] ? (DWORD)-1 : 0, (LPVOID)post, plen, plen, 0) ||
        !cm_wh.ReceiveResponse(req, NULL))
    {
        cm_fail(L"%s: no answer (Windows error %lu).", host, GetLastError());
        goto end;
    }
    DWORD code = 0, csz = sizeof(code);
    if (!cm_wh.QueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &code, &csz, WINHTTP_NO_HEADER_INDEX))
    {
        cm_fail(L"%s: no status (Windows error %lu).", host, GetLastError());
        goto end;
    }
    status = (int)code;

    BOOL to_file = file != INVALID_HANDLE_VALUE;
    if (to_file && status != 200 && status != 206) goto end;
    ULONGLONG done = 0;
    if (to_file)
    {
        if (range_from && status != 206)
        {
            LARGE_INTEGER z0;
            z0.QuadPart = 0;
            SetFilePointerEx(file, z0, NULL, FILE_BEGIN);
            SetEndOfFile(file);
            range_from = 0;
        }
        done = range_from;
    }
    chunk = malloc(65536);
    size_t blen = 0, bcap = 4096;
    if (!to_file) body = malloc(bcap);
    if (!chunk || (!to_file && !body)) { cm_fail(L"Out of memory."); status = 0; goto end; }
    int shown = -1;
    for (;;)
    {
        DWORD rd = 0;
        if (!cm_wh.ReadData(req, chunk, 65536, &rd))
        {
            cm_fail(L"%s: the download broke off (Windows error %lu).", host, GetLastError());
            status = 0;
            goto end;
        }
        if (!rd) break;
        if (to_file)
        {
            DWORD wr = 0;
            if (!WriteFile(file, chunk, rd, &wr, NULL) || wr != rd)
            {
                cm_fail(L"The download could not be written (Windows error %lu); is the disk full?", GetLastError());
                status = 0;
                goto end;
            }
            done += rd;
            if (expect)
            {
                int pct = (int)(100 * done / expect);
                if (pct >= shown + 10)
                {
                    shown = pct - (pct % 10);
                    cm_say(L"Client mod: downloading %d%%", shown);
                }
            }
        }
        else
        {
            if (blen + rd >= CM_JSON_MAX) { cm_fail(L"%s: the answer is too long.", host); status = 0; goto end; }
            if (blen + rd + 1 > bcap)
            {
                while (blen + rd + 1 > bcap) bcap *= 2;
                char *nb = realloc(body, bcap);
                if (!nb) { cm_fail(L"Out of memory."); status = 0; goto end; }
                body = nb;
            }
            memcpy(body + blen, chunk, rd);
            blen += rd;
        }
    }
    if (body) { body[blen] = 0; if (mem) { *mem = body; body = NULL; } }

end:
    free(chunk);
    free(body);
    if (req) cm_wh.CloseHandle_(req);
    if (con) cm_wh.CloseHandle_(con);
    if (ses) cm_wh.CloseHandle_(ses);
    return status;
}

/* --------------------------------------------------------- the game's files */

typedef struct
{
    wchar_t *rel;
    ULONGLONG size;
    ULONGLONG ticks;   /* last write, in .NET ticks (the script's digest uses them) */
    BOOL cas;
} cm_file;

typedef struct { cm_file *v; size_t n, cap; } cm_files;

static void cm_files_free(cm_files *f)
{
    for (size_t i = 0; i < f->n; i++) free(f->v[i].rel);
    free(f->v);
    memset(f, 0, sizeof(*f));
}

/* Every file under root\sub, as a path relative to root. Reparse points are leaves. */
static BOOL cm_enum(const wchar_t *root, const wchar_t *sub, cm_files *out_list)
{
    wchar_t dir[CM_PATH], pat[CM_PATH];
    cm_path(dir, root, sub);
    cm_path(pat, dir, L"*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h == INVALID_HANDLE_VALUE)
        return cm_fail(L"%s could not be listed (Windows error %lu).", dir, GetLastError());
    BOOL ok = TRUE;
    do
    {
        if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
        wchar_t rel[CM_PATH];
        cm_path(rel, sub, fd.cFileName);
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
        {
            if (!cm_enum(root, rel, out_list)) { ok = FALSE; break; }
            continue;
        }
        if (out_list->n == out_list->cap)
        {
            size_t cap = out_list->cap ? out_list->cap * 2 : 2048;
            cm_file *nv = realloc(out_list->v, cap * sizeof(*nv));
            if (!nv) { ok = cm_fail(L"Out of memory."); break; }
            out_list->v = nv;
            out_list->cap = cap;
        }
        cm_file *f = &out_list->v[out_list->n];
        f->rel = _wcsdup(rel);
        if (!f->rel) { ok = cm_fail(L"Out of memory."); break; }
        f->size = ((ULONGLONG)fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
        f->ticks = (((ULONGLONG)fd.ftLastWriteTime.dwHighDateTime << 32) | fd.ftLastWriteTime.dwLowDateTime) +
                   504911232000000000ULL;
        size_t ln = wcslen(rel);
        f->cas = ln > 4 && !_wcsicmp(rel + ln - 4, L".cas");
        out_list->n++;
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return ok;
}

static BOOL cm_enum_game(const wchar_t *game_dir, cm_files *out_list)
{
    return cm_enum(game_dir, L"Data", out_list) && cm_enum(game_dir, L"Patch", out_list);
}

static int cm_cmp_lines(const void *a, const void *b)
{
    return wcscmp(*(wchar_t *const *)a, *(wchar_t *const *)b);
}

/* LinkedModData.Digest(): "relative path|size|last-write ticks\n" for each linked
 * archive (every .cas but the copied ones), sorted ordinally, SHA-256 of the UTF-8 text. */
static BOOL cm_link_digest(const cm_files *files, const cm_j *copied, char hex[65])
{
    wchar_t **lines = calloc(files->n ? files->n : 1, sizeof(*lines));
    size_t n = 0;
    BOOL ok = lines != NULL;
    for (size_t i = 0; ok && i < files->n; i++)
    {
        const cm_file *f = &files->v[i];
        if (!f->cas) continue;
        BOOL skip = FALSE;
        if (copied)
            for (int c = 0; c < copied->c && !skip; c++)
            {
                wchar_t w[CM_PATH];
                if (copied->v[c]->t != CJ_STR) continue;
                cm_widen(copied->v[c]->s, w, CM_PATH);
                for (wchar_t *q = w; *q; q++) if (*q == L'/') *q = L'\\';
                skip = !_wcsicmp(w, f->rel);
            }
        if (skip) continue;
        lines[n] = malloc((wcslen(f->rel) + 64) * sizeof(wchar_t));
        if (!lines[n]) { ok = FALSE; break; }
        _snwprintf(lines[n], wcslen(f->rel) + 63, L"%s|%llu|%llu\n", f->rel, f->size, f->ticks);
        n++;
    }
    if (ok)
    {
        qsort(lines, n, sizeof(*lines), cm_cmp_lines);
        cm_sha s;
        cm_sha_begin(&s);
        for (size_t i = 0; i < n; i++)
        {
            char u[CM_PATH * 3 + 64];
            int len = WideCharToMultiByte(CP_UTF8, 0, lines[i], -1, u, sizeof(u), NULL, NULL);
            if (len > 1) cm_sha_add(&s, u, (size_t)len - 1);
        }
        ok = cm_sha_end(&s, hex);
    }
    for (size_t i = 0; lines && i < n; i++) free(lines[i]);
    free(lines);
    return ok || cm_fail(L"The archive digest could not be computed.");
}

/* ------------------------------------------------------------ file helpers */

static BOOL cm_rmtree(const wchar_t *root_guard, const wchar_t *dir)
{
    /* Only ever inside the mod cache, and never through a link: a link, whatever it points at,
     * is deleted as the file it is. */
    size_t gl = wcslen(root_guard);
    if (_wcsnicmp(dir, root_guard, gl) != 0 || dir[gl] != L'\\') return FALSE;
    wchar_t pat[CM_PATH];
    cm_path(pat, dir, L"*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    BOOL ok = TRUE;
    if (h != INVALID_HANDLE_VALUE)
    {
        do
        {
            if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
            wchar_t p[CM_PATH];
            cm_path(p, dir, fd.cFileName);
            if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
                ok = cm_rmtree(root_guard, p) && ok;
            else
            {
                /* Only a read-only entry needs its attribute cleared: on a hard link that would change
                 * the game's own file too. */
                if (fd.dwFileAttributes & FILE_ATTRIBUTE_READONLY) SetFileAttributesW(p, FILE_ATTRIBUTE_NORMAL);
                if (!DeleteFileW(p)) ok = FALSE;
            }
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    return RemoveDirectoryW(dir) && ok;
}

static void cm_mkdirs(const wchar_t *p) { ensure_dir(p); }

static void cm_mkdirs_for(const wchar_t *file)
{
    wchar_t d[CM_PATH];
    wcsncpy(d, file, CM_PATH - 1);
    d[CM_PATH - 1] = 0;
    wchar_t *s = wcsrchr(d, L'\\');
    if (s) { *s = 0; cm_mkdirs(d); }
}

static ULONGLONG cm_free_bytes(const wchar_t *dir)
{
    ULARGE_INTEGER avail, total, freeb;
    return GetDiskFreeSpaceExW(dir, &avail, &total, &freeb) ? avail.QuadPart : ~0ULL;
}

static BOOL cm_write_new(const wchar_t *path, const BYTE *data, size_t len)
{
    HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    BOOL ok = TRUE;
    while (ok && len)
    {
        DWORD c = len > (1u << 24) ? (1u << 24) : (DWORD)len, wr = 0;
        ok = WriteFile(h, data, c, &wr, NULL) && wr == c;
        data += c;
        len -= c;
    }
    CloseHandle(h);
    return ok;
}

/* "Data/Win32/x.cas" as the patch spells it -> "Data\Win32\x.cas", or FALSE if it is not a
 * plain path under Data or Patch. */
static BOOL cm_patch_path(const char *s, wchar_t *rel)
{
    if (!s || strstr(s, "..")) return FALSE;
    if (strncmp(s, "Data/", 5) && strncmp(s, "Patch/", 6)) return FALSE;
    size_t n = strlen(s);
    if (n < 6 || n >= CM_PATH) return FALSE;
    for (size_t i = 0; i < n; i++)
    {
        char c = s[i];
        if (!(isalnum((unsigned char)c) || c == '_' || c == '.' || c == '/' || c == '-')) return FALSE;
        rel[i] = c == '/' ? L'\\' : (wchar_t)c;
    }
    rel[n] = 0;
    return TRUE;
}

/* ---------------------------------------------------------- the profile */

/* The FIFA21.exe copies of build 21.0.4750997.0 that Aurora's auth bridge accepts. They
 * ship the same game data, so a patch made on one installs on the other. */
static const char *CM_SAME_BUILD[2] = {
    "44d0acc62a214c6f4dab2b8a4f4bdd068869c636f15cc262035b4edc862a1494",
    "05cc56f897201a6ba74d608f971bcf157b1a46c10e9cda335e868c17004fbc71",
};

typedef struct { wchar_t rel[CM_PATH]; const cm_j *node; BOOL found; } cm_change;
typedef struct { wchar_t rel[CM_PATH]; const cm_j *node; } cm_added;

/* Test-ModDataFolder. */
static BOOL cm_moddata_ok(const wchar_t *folder)
{
    if (!folder[0] || wcschr(folder, L'"')) return FALSE;
    BOOL rooted = (folder[1] == L':' && folder[2] == L'\\') || (folder[0] == L'\\' && folder[1] == L'\\');
    if (!rooted) return FALSE;
    wchar_t a[CM_PATH], b[CM_PATH];
    cm_path(a, folder, L"Data\\layout.toc");
    cm_path(b, folder, L"Patch\\layout.toc");
    return file_exists(a) && file_exists(b);
}

/* Test-UltimateTeamModProfile: this revision's ModData for this game, or FALSE. */
static BOOL cm_profile_ok(const wchar_t *profile, const char *revision, const wchar_t *game_dir,
                          const char *exe_hex, const char *cards_hex, wchar_t *moddata)
{
    wchar_t marker[CM_PATH];
    cm_path(marker, profile, L"compiled-profile.json");
    char *text = read_all_utf8(marker, NULL);
    if (!text) return FALSE;
    cm_j *m = cj_parse(text);
    free(text);
    if (!m) return FALSE;
    BOOL ok = FALSE;
    const char *dir = cj_str(m, "gameDirectory");
    wchar_t wdir[CM_PATH];
    if (dir) cm_widen(dir, wdir, CM_PATH);
    if (cj_num(m, "schema", 0) == 1 && cj_str(m, "revision") && !strcmp(cj_str(m, "revision"), revision) &&
        dir && !_wcsicmp(wdir, game_dir) &&
        cj_str(m, "gameExecutableSha256") && !strcmp(cj_str(m, "gameExecutableSha256"), exe_hex) &&
        cj_str(m, "cardsLibrarySha256") && !strcmp(cj_str(m, "cardsLibrarySha256"), cards_hex) &&
        cj_str(m, "modDataRelativePath") && !strcmp(cj_str(m, "modDataRelativePath"), "compiler/ModData") &&
        cj_num(m, "verifiedLanguages", 0) == 21)
    {
        wchar_t md[CM_PATH];
        cm_path(md, profile, L"compiler\\ModData");
        ok = cm_moddata_ok(md);
        if (ok && cj_num(m, "linkedArchives", 0) > 0)
        {
            /* The archives it links to must be the ones it was built from: size and time. */
            cm_files files;
            memset(&files, 0, sizeof(files));
            char hex[65];
            ok = cm_enum_game(game_dir, &files) && cm_link_digest(&files, cj_get(m, "copiedArchives"), hex) &&
                 cj_str(m, "linkedArchiveDigest") && !strcmp(cj_str(m, "linkedArchiveDigest"), hex);
            cm_files_free(&files);
        }
        if (ok) wcscpy(moddata, md);
    }
    cj_free(m);
    return ok;
}

/* Hard link, else symbolic link, for one of the game's archives. The first hard-link failure
 * moves every later archive on to symbolic links. Never a copy, as in the script: that is
 * about 40 GB, longer than the launcher's readySeconds, and a build killed by the timeout is
 * removed and started again on the next Play. */
static BOOL cm_link_archive(const wchar_t *target, const wchar_t *source, BOOL *hard,
                            unsigned *linked, unsigned *symbolic)
{
    if (*hard)
    {
        if (CreateHardLinkW(target, source, NULL)) { (*linked)++; return TRUE; }
        cm_note(L"Hard link failed (Windows error %lu).", GetLastError());
        *hard = FALSE;
        cm_say(L"Client mod: archive hard-linking failed; linking the remaining archives symbolically.");
    }
    if (CreateSymbolicLinkW(target, source, 0)) { (*linked)++; (*symbolic)++; return TRUE; }
    return cm_fail(L"Windows would not link FIFA 21's game files for the client mod (Windows error %lu). "
                   L"Aurora links them instead of copying about 40 GB, so the client mod was not installed.",
                   GetLastError());
}

static BOOL cm_apply_edits(HANDLE h, const BYTE *e, size_t elen, ULONGLONG original_size, const wchar_t *rel)
{
    size_t at = 0;
    while (at < elen)
    {
        if (at + 12 > elen) return cm_fail(L"Invalid edit in the patch for %s.", rel);
        ULONGLONG off = (ULONGLONG)cm_u32(e + at) | ((ULONGLONG)cm_u32(e + at + 4) << 32);
        unsigned len = cm_u32(e + at + 8);
        at += 12;
        if (off + len > original_size || at + len > elen) return cm_fail(L"Invalid edit in the patch for %s.", rel);
        LARGE_INTEGER li;
        li.QuadPart = (LONGLONG)off;
        DWORD wr = 0;
        if (!SetFilePointerEx(h, li, NULL, FILE_BEGIN) || !WriteFile(h, e + at, len, &wr, NULL) || wr != len)
            return cm_fail(L"%s could not be written (Windows error %lu).", rel, GetLastError());
        at += len;
    }
    return TRUE;
}

/* Install-UltimateTeamModPatch. Builds <cache>\<revision>\compiler\ModData from the patch
 * and the installed game, leaving the game alone; fills moddata. */
static BOOL cm_install_patch(const wchar_t *game_dir, const wchar_t *cache, const wchar_t *patch_file,
                             const char *exe_hex, const char *cards_hex, const char *patch_hex,
                             wchar_t *moddata)
{
    cm_zip z;
    cm_zip_open(&z, patch_file);   /* a failure leaves z.f invalid; cm_err is set */
    BOOL ok = FALSE;
    BYTE *pj = NULL;
    cm_j *patch = NULL;
    cm_change *changes = NULL;
    cm_added *adds = NULL;
    int nchanges = 0, nadds = 0;
    cm_files files;
    memset(&files, 0, sizeof(files));
    HANDLE lock = INVALID_HANDLE_VALUE;
    wchar_t staging[CM_PATH] = L"", modroot[CM_PATH] = L"", profile[CM_PATH] = L"";
    wchar_t **copied_rel = NULL;
    size_t ncopied = 0;
    ULONGLONG started = GetTickCount64();

    if (z.f == INVALID_HANDLE_VALUE) goto end;
    pj = cm_zip_read(&z, "patch.json", NULL);
    if (!pj) goto end;
    patch = cj_parse((const char *)pj);
    if (!patch) { cm_fail(L"The client mod patch's patch.json is not valid."); goto end; }

    const cm_j *pfiles = cj_get(patch, "files"), *pnew = cj_get(patch, "newFiles");
    long long schema = cj_num(patch, "schema", 0);
    const char *kind = cj_str(patch, "kind"), *revision = cj_str(patch, "revision");
    if ((schema != 1 && schema != 2) || !kind || strcmp(kind, "aurora21-client-mod-patch") ||
        !cm_is_hex64(revision) || !pfiles || pfiles->t != CJ_ARR || pfiles->c == 0 ||
        (schema == 1 && pnew && pnew->t == CJ_ARR && pnew->c > 0))
    {
        cm_fail(L"Invalid client mod patch.");
        goto end;
    }
    {
        const char *pexe = cj_str(patch, "gameExecutableSha256"), *pcards = cj_str(patch, "cardsLibrarySha256");
        BOOL same = pexe && !strcmp(pexe, exe_hex);
        if (!same && pexe)
            same = (!strcmp(exe_hex, CM_SAME_BUILD[0]) || !strcmp(exe_hex, CM_SAME_BUILD[1])) &&
                   (!strcmp(pexe, CM_SAME_BUILD[0]) || !strcmp(pexe, CM_SAME_BUILD[1]));
        if (!same) { cm_fail(L"The client mod patch is for another game build: FIFA21.exe differs."); goto end; }
        if (!pcards || strcmp(pcards, cards_hex))
        {
            cm_fail(L"The client mod patch is for another game build: CardsDLL_Win64_retail.dll differs.");
            goto end;
        }
    }

    changes = calloc((size_t)pfiles->c, sizeof(*changes));
    adds = calloc(pnew && pnew->t == CJ_ARR ? (size_t)pnew->c + 1 : 1, sizeof(*adds));
    if (!changes || !adds) { cm_fail(L"Out of memory."); goto end; }
    for (int i = 0; i < pfiles->c; i++)
    {
        const cm_j *f = pfiles->v[i];
        if (!cm_patch_path(cj_str(f, "path"), changes[nchanges].rel))
        {
            wchar_t w[160];
            cm_widen(cj_str(f, "path") ? cj_str(f, "path") : "", w, 160);
            cm_fail(L"Invalid patch path: %s", w);
            goto end;
        }
        for (int k = 0; k < nchanges; k++)
            if (!_wcsicmp(changes[k].rel, changes[nchanges].rel)) { cm_fail(L"Invalid client mod patch."); goto end; }
        changes[nchanges++].node = f;
    }
    for (int i = 0; pnew && pnew->t == CJ_ARR && i < pnew->c; i++)
    {
        const cm_j *f = pnew->v[i];
        if (f->t == CJ_NULL) continue;
        const char *content = cj_str(f, "content");
        unsigned m, cs, us, lho;
        if (!cm_patch_path(cj_str(f, "path"), adds[nadds].rel) || !content || !cm_zip_find(&z, content, &m, &cs, &us, &lho))
        {
            cm_fail(L"Invalid new file in the patch.");
            goto end;
        }
        for (int k = 0; k < nchanges; k++)
            if (!_wcsicmp(changes[k].rel, adds[nadds].rel)) { cm_fail(L"Invalid new file in the patch."); goto end; }
        for (int k = 0; k < nadds; k++)
            if (!_wcsicmp(adds[k].rel, adds[nadds].rel)) { cm_fail(L"Invalid new file in the patch."); goto end; }
        wchar_t there[CM_PATH];
        cm_path(there, game_dir, adds[nadds].rel);
        if (GetFileAttributesW(there) != INVALID_FILE_ATTRIBUTES)
        {
            cm_fail(L"The installed game already has %s, which the client mod patch adds; it is not the game "
                    L"the patch was made for.", adds[nadds].rel);
            goto end;
        }
        adds[nadds++].node = f;
    }

    if (!cm_enum_game(game_dir, &files)) goto end;
    {
        ULONGLONG need = 256ULL << 20;
        for (size_t i = 0; i < files.n; i++) if (!files.v[i].cas) need += files.v[i].size;
        for (int i = 0; i < nadds; i++) need += (ULONGLONG)cj_num(cj_get(adds[i].node, "result"), "size", 0);
        for (int i = 0; i < nchanges; i++) need += (ULONGLONG)cj_num(cj_get(changes[i].node, "result"), "size", 0);
        cm_mkdirs(cache);
        if (cm_free_bytes(cache) < need)
        {
            cm_fail(L"There is not enough free disk space for the client mod (about %llu MB needed).", need >> 20);
            goto end;
        }
    }

    {
        wchar_t name[64];
        _snwprintf(name, 63, L".building-%08lx%08lx%08lx", (unsigned long)GetCurrentProcessId(),
                   (unsigned long)(GetTickCount64() & 0xffffffffu), (unsigned long)(GetTickCount64() >> 32) ^ 0x5a5a);
        name[63] = 0;
        cm_path(staging, cache, name);
        if (!CreateDirectoryW(staging, NULL)) { cm_fail(L"%s could not be created (Windows error %lu).", staging, GetLastError()); staging[0] = 0; goto end; }
        wchar_t lockfile[CM_PATH];
        cm_path(lockfile, staging, L".lock");
        /* Held open while this install runs: once it can be opened, the install was killed and the
         * next Play's cleanup removes the build. */
        lock = CreateFileW(lockfile, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        wchar_t md[CM_PATH];
        cm_path(md, staging, L"compiler\\ModData");
        wcsncpy(modroot, md, CM_PATH - 1);
        static const wchar_t *top[] = { L"Data", L"Patch", L"Update" };
        for (int i = 0; i < 3; i++) { wchar_t d[CM_PATH]; cm_path(d, modroot, top[i]); cm_mkdirs(d); }
    }

    BOOL hard = TRUE;
    unsigned linked = 0, symbolic = 0, copied = 0, linked_files = 0, rebuilt = 0;
    BOOL link_misc = TRUE;
    cm_say(L"Client mod %.8S: preparing the client mod, linked to the installed game data.", revision);
    {
        wchar_t t[CM_PATH], s[CM_PATH];
        cm_path(t, modroot, L"FIFA21.exe");
        cm_path(s, game_dir, L"FIFA21.exe");
        if (!CreateHardLinkW(t, s, NULL))
        {
            if (!CopyFileW(s, t, TRUE)) { cm_fail(L"FIFA21.exe could not be copied (Windows error %lu).", GetLastError()); goto end; }
            copied++;
        }
    }
    copied_rel = calloc(files.n ? files.n : 1, sizeof(*copied_rel));
    if (!copied_rel) { cm_fail(L"Out of memory."); goto end; }
    for (size_t i = 0; i < files.n; i++)
    {
        const cm_file *f = &files.v[i];
        wchar_t t[CM_PATH], s[CM_PATH];
        cm_path(t, modroot, f->rel);
        cm_path(s, game_dir, f->rel);
        cm_mkdirs_for(t);
        BOOL is_changed = FALSE;
        for (int k = 0; k < nchanges; k++)
            if (!_wcsicmp(changes[k].rel, f->rel)) { changes[k].found = TRUE; is_changed = TRUE; break; }
        if (is_changed)
        {
            /* A rebuilt archive is the profile's own copy: the script's copiedArchives, left out of
             * the linked-archive digest. */
            rebuilt++;
            if (f->cas) copied_rel[ncopied++] = f->rel;
            continue;
        }
        if (f->cas)
        {
            if (!cm_link_archive(t, s, &hard, &linked, &symbolic)) goto end;
        }
        else
        {
            /* Nothing writes to an unchanged toc or sb file either: a hard link saves copying them. */
            BOOL done = FALSE;
            if (link_misc)
            {
                if (CreateHardLinkW(t, s, NULL)) { linked_files++; done = TRUE; }
                else link_misc = FALSE;
            }
            if (!done)
            {
                if (!CopyFileW(s, t, TRUE)) { cm_fail(L"%s could not be copied (Windows error %lu).", s, GetLastError()); goto end; }
                copied++;
            }
        }
    }
    if ((int)rebuilt != nchanges)
    {
        cm_fail(L"The installed game lacks files the client mod patch changes.");
        goto end;
    }

    cm_say(L"Client mod %.8S: rebuilding %d changed files.", revision, nchanges);
    for (int i = 0; i < nchanges; i++)
    {
        const cm_j *f = changes[i].node;
        const cm_j *orig = cj_get(f, "original"), *res = cj_get(f, "result");
        wchar_t t[CM_PATH], s[CM_PATH];
        cm_path(t, modroot, changes[i].rel);
        cm_path(s, game_dir, changes[i].rel);
        WIN32_FILE_ATTRIBUTE_DATA fa;
        ULONGLONG have = 0;
        if (GetFileAttributesExW(s, GetFileExInfoStandard, &fa)) have = ((ULONGLONG)fa.nFileSizeHigh << 32) | fa.nFileSizeLow;
        if (have != (ULONGLONG)cj_num(orig, "size", -1))
        {
            cm_fail(L"The installed %s is not the file the patch was made from.", changes[i].rel);
            goto end;
        }
        if (!CopyFileW(s, t, TRUE)) { cm_fail(L"%s could not be copied (Windows error %lu).", s, GetLastError()); goto end; }
        SetFileAttributesW(t, FILE_ATTRIBUTE_NORMAL);
        HANDLE h = CreateFileW(t, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h == INVALID_HANDLE_VALUE) { cm_fail(L"%s could not be opened (Windows error %lu).", t, GetLastError()); goto end; }
        BOOL wrote = TRUE;
        const char *edits = cj_str(f, "edits"), *tail = cj_str(f, "tail");
        if (edits)
        {
            size_t elen = 0;
            BYTE *e = cm_zip_read(&z, edits, &elen);
            wrote = e && cm_apply_edits(h, e, elen, have, changes[i].rel);
            free(e);
        }
        if (wrote && tail)
        {
            size_t tlen = 0;
            BYTE *tb = cm_zip_read(&z, tail, &tlen);
            LARGE_INTEGER zero;
            zero.QuadPart = 0;
            DWORD wr = 0;
            wrote = tb && SetFilePointerEx(h, zero, NULL, FILE_END) && WriteFile(h, tb, (DWORD)tlen, &wr, NULL) && wr == tlen;
            if (!wrote && tb) cm_fail(L"%s could not be extended (Windows error %lu).", changes[i].rel, GetLastError());
            free(tb);
        }
        CloseHandle(h);
        if (!wrote) goto end;
        char hex[65];
        WIN32_FILE_ATTRIBUTE_DATA fb;
        ULONGLONG now = 0;
        if (GetFileAttributesExW(t, GetFileExInfoStandard, &fb)) now = ((ULONGLONG)fb.nFileSizeHigh << 32) | fb.nFileSizeLow;
        const char *want = cj_str(res, "sha256");
        if (now != (ULONGLONG)cj_num(res, "size", -1) || !cm_sha_file(t, hex) || !want || strcmp(hex, want))
        {
            cm_fail(L"The rebuilt %s does not match the patch; the installed file differs from the one it was made from.",
                    changes[i].rel);
            goto end;
        }
    }

    if (nadds) cm_say(L"Client mod %.8S: adding the mod's own %d archives.", revision, nadds);
    for (int i = 0; i < nadds; i++)
    {
        const cm_j *res = cj_get(adds[i].node, "result");
        wchar_t t[CM_PATH];
        cm_path(t, modroot, adds[i].rel);
        cm_mkdirs_for(t);
        size_t len = 0;
        BYTE *c = cm_zip_read(&z, cj_str(adds[i].node, "content"), &len);
        if (!c) goto end;
        cm_sha s;
        char hex[65];
        cm_sha_begin(&s);
        cm_sha_add(&s, c, len);
        const char *want = cj_str(res, "sha256");
        BOOL good = cm_sha_end(&s, hex) && want && !strcmp(hex, want) && (long long)len == cj_num(res, "size", -1);
        if (!good) { free(c); cm_fail(L"The client mod's new file %s does not match the patch.", adds[i].rel); goto end; }
        BOOL wrote = cm_write_new(t, c, len);
        DWORD werr = GetLastError();
        free(c);
        if (!wrote) { cm_fail(L"%s could not be written (Windows error %lu).", t, werr); goto end; }
    }

    {
        char digest[65] = "", gdir[CM_PATH * 2], rel_json[CM_PATH * 2];
        BOOL have_digest = FALSE;
        if (linked > 0)
        {
            /* A throwaway "copied" list: the archives this profile copied are not linked to the game. */
            cm_j *copied_list = calloc(1, sizeof(*copied_list));
            if (copied_list) copied_list->t = CJ_ARR;
            for (size_t i = 0; copied_list && i < ncopied; i++)
            {
                cm_j *e = calloc(1, sizeof(*e));
                char u[CM_PATH * 3];
                WideCharToMultiByte(CP_UTF8, 0, copied_rel[i], -1, u, sizeof(u), NULL, NULL);
                if (e) { e->t = CJ_STR; e->s = _strdup(u); }
                if (!e || !cj_push(copied_list, e, NULL)) { cj_free(e); break; }
            }
            have_digest = cm_link_digest(&files, copied_list, digest);
            cj_free(copied_list);
            if (!have_digest) goto end;
        }
        cm_json_str(game_dir, gdir, sizeof(gdir));
        size_t cap = 4096 + ncopied * (CM_PATH * 2 + 8);
        char *js = malloc(cap);
        if (!js) { cm_fail(L"Out of memory."); goto end; }
        int n = _snprintf(js, cap - 1,
            "{\n  \"schema\": 1,\n  \"revision\": \"%s\",\n  \"gameDirectory\": \"%s\",\n"
            "  \"gameExecutableSha256\": \"%s\",\n  \"cardsLibrarySha256\": \"%s\",\n"
            "  \"modDataRelativePath\": \"compiler/ModData\",\n  \"verifiedLanguages\": %lld,\n"
            "  \"verifiedArtworkAssets\": %lld,\n  \"verifiedTextures\": %lld,\n"
            "  \"linkedArchives\": %u,\n  \"symbolicArchives\": %u,\n  \"linkedArchiveDigest\": ",
            revision, gdir, exe_hex, cards_hex, cj_num(patch, "verifiedLanguages", 0),
            cj_num(patch, "verifiedArtworkAssets", 0), cj_num(patch, "verifiedTextures", 0), linked, symbolic);
        if (have_digest) n += _snprintf(js + n, cap - n - 1, "\"%s\"", digest);
        else n += _snprintf(js + n, cap - n - 1, "null");
        n += _snprintf(js + n, cap - n - 1, ",\n  \"copiedArchives\": [");
        for (size_t i = 0; i < ncopied; i++)
        {
            cm_json_str(copied_rel[i], rel_json, sizeof(rel_json));
            n += _snprintf(js + n, cap - n - 1, "%s\"%s\"", i ? ", " : "", rel_json);
        }
        n += _snprintf(js + n, cap - n - 1, "],\n  \"source\": \"patch\",\n  \"patchSha256\": \"%s\"\n}\n", patch_hex);
        wchar_t mk[CM_PATH];
        cm_path(mk, staging, L"compiled-profile.json");
        BOOL wrote = write_all_utf8(mk, js);
        free(js);
        if (!wrote) { cm_fail(L"The client mod's profile marker could not be written (Windows error %lu).", GetLastError()); goto end; }
    }
    cm_say(L"Client mod %.8S: linked %u archives (%u symbolically) and %u other files, copied %u files, "
           L"rebuilt %d and added %d from the prebuilt patch.",
           revision, linked, symbolic, linked_files, copied, nchanges, nadds);

    /* Done: the build becomes the profile. */
    if (lock != INVALID_HANDLE_VALUE) { CloseHandle(lock); lock = INVALID_HANDLE_VALUE; }
    {
        wchar_t lockfile[CM_PATH], rev[80];
        cm_path(lockfile, staging, L".lock");
        DeleteFileW(lockfile);
        cm_widen(revision, rev, 80);
        cm_path(profile, cache, rev);
        if (dir_exists(profile)) cm_rmtree(cache, profile);
        if (!MoveFileExW(staging, profile, 0))
        {
            cm_fail(L"The client mod profile could not be put in place (Windows error %lu).", GetLastError());
            goto end;
        }
        staging[0] = 0;
        cm_path(moddata, profile, L"compiler\\ModData");
    }
    cm_say(L"Client mod %.8S: installed in %.1f s.", revision, (double)(GetTickCount64() - started) / 1000.0);
    ok = TRUE;

end:
    if (lock != INVALID_HANDLE_VALUE) CloseHandle(lock);
    if (staging[0]) cm_rmtree(cache, staging);
    free(copied_rel);
    cm_files_free(&files);
    free(changes);
    free(adds);
    cj_free(patch);
    free(pj);
    cm_zip_close(&z);
    return ok;
}

/* ------------------------------------------------- cache and the server */

static void cm_cache_root(wchar_t *dst)
{
    wchar_t base[CM_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, CM_PATH);
    if (!n || n >= CM_PATH)
    {
        if (FAILED(SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, 0, base))) wcscpy(base, L"C:\\users\\crossover\\AppData\\Local");
    }
    _snwprintf(dst, CM_PATH - 1, L"%s\\Aurora21\\UltimateTeam\\client-mods\\leaderboards", base);
    dst[CM_PATH - 1] = 0;
}

/* Remove-UltimateTeamStaleModProfiles: earlier revisions, builds a closed window abandoned,
 * and profiles of a game that is gone. Never while FIFA runs (the caller checks). */
static void cm_clean_cache(const wchar_t *cache, const char *keep, const wchar_t *game_dir)
{
    wchar_t pat[CM_PATH];
    cm_path(pat, cache, L"*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do
    {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) continue;
        if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
        char name[CM_PATH];
        WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, name, sizeof(name), NULL, NULL);
        if (!strcmp(name, keep)) continue;
        wchar_t dir[CM_PATH];
        cm_path(dir, cache, fd.cFileName);
        if (cm_is_hex64(name))
        {
            wchar_t marker[CM_PATH];
            cm_path(marker, dir, L"compiled-profile.json");
            char *text = read_all_utf8(marker, NULL);
            cm_j *m = text ? cj_parse(text) : NULL;
            free(text);
            const char *other = m ? cj_str(m, "gameDirectory") : NULL;
            BOOL foreign = FALSE;
            if (other)
            {
                wchar_t wother[CM_PATH];
                cm_widen(other, wother, CM_PATH);
                if (_wcsicmp(wother, game_dir) != 0)
                {
                    /* Another installation's profile is not this build's to remove, unless that game is
                     * gone from a drive that is still there. */
                    wchar_t root[4] = { wother[0], L':', L'\\', 0 }, exe[CM_PATH];
                    cm_path(exe, wother, L"FIFA21.exe");
                    foreign = !(wother[1] == L':' && dir_exists(root) && !file_exists(exe));
                }
            }
            cj_free(m);
            if (foreign) continue;
        }
        else if (!wcsncmp(fd.cFileName, L".building-", 10))
        {
            wchar_t lockfile[CM_PATH];
            cm_path(lockfile, dir, L".lock");
            BOOL abandoned = FALSE;
            if (file_exists(lockfile))
            {
                HANDLE l = CreateFileW(lockfile, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
                if (l != INVALID_HANDLE_VALUE) { CloseHandle(l); abandoned = TRUE; }
            }
            FILETIME now;
            GetSystemTimeAsFileTime(&now);
            ULONGLONG n = ((ULONGLONG)now.dwHighDateTime << 32) | now.dwLowDateTime;
            ULONGLONG w = ((ULONGLONG)fd.ftLastWriteTime.dwHighDateTime << 32) | fd.ftLastWriteTime.dwLowDateTime;
            if (!abandoned && !(n > w && n - w > 864000000000ULL)) continue;
        }
        else continue;
        if (cm_rmtree(cache, dir)) cm_say(L"Removed an earlier client mod profile: %s", fd.cFileName);
        else cm_note(L"Could not remove an earlier client mod profile: %s", fd.cFileName);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

/* Downloads of other revisions, complete or partial. */
static void cm_clean_downloads(const wchar_t *dir, const char *keep)
{
    wchar_t pat[CM_PATH];
    cm_path(pat, dir, L"aurora21-mod-*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do
    {
        char name[CM_PATH];
        WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, name, sizeof(name), NULL, NULL);
        size_t kl = strlen(keep);
        if (!strncmp(name, keep, kl) && (!name[kl] || !strcmp(name + kl, ".partial"))) continue;
        wchar_t p[CM_PATH];
        cm_path(p, dir, fd.cFileName);
        if (DeleteFileW(p)) cm_say(L"Removed an earlier client mod download: %s", fd.cFileName);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

static ULONGLONG cm_file_size(const wchar_t *p)
{
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (!GetFileAttributesExW(p, GetFileExInfoStandard, &fa)) return 0;
    return ((ULONGLONG)fa.nFileSizeHigh << 32) | fa.nFileSizeLow;
}

/* Get-UltimateTeamClientModFromServer for one front. 1 = moddata filled, 0 = the server publishes
 * no mod, -1 = it does and this PC could not install it (cm_err says why). */
static int cm_from_server(const wchar_t *host, const wchar_t *game_dir, wchar_t *moddata)
{
    char *body = NULL;
    int st = cm_http(L"GET", host, L"/client/mods/manifest.json", NULL, 0, INVALID_HANDLE_VALUE, &body, 0);
    if (st != 200)
    {
        if (st) cm_say(L"Client mod: the server publishes no prebuilt mod (HTTP %d).", st);
        else cm_say(L"Client mod: the server publishes no prebuilt mod (%s)", cm_err);
        free(body);
        return 0;
    }
    cm_j *man = cj_parse(body);
    free(body);
    const cm_j *entry = NULL;
    const char *suffix = ".v2.patch";
    const cm_j *list = cj_get(man, "files");
    for (int pass = 0; pass < 2 && !entry; pass++)
    {
        const char *want = pass ? "aurora21-client-mod-patch" : "aurora21-client-mod-patch-v2";
        suffix = pass ? ".patch" : ".v2.patch";
        for (int i = 0; list && list->t == CJ_ARR && i < list->c; i++)
            if (cj_str(list->v[i], "kind") && !strcmp(cj_str(list->v[i], "kind"), want)) { entry = list->v[i]; break; }
    }
    const char *version = cj_str(man, "version"), *ename = entry ? cj_str(entry, "name") : NULL;
    const char *esha = entry ? cj_str(entry, "sha256") : NULL;
    long long esize = entry ? cj_num(entry, "size", 0) : 0;
    char want_name[160];
    if (version && strlen(version) == 64) _snprintf(want_name, sizeof(want_name) - 1, "aurora21-mod-%s%s", version, suffix);
    else want_name[0] = 0;
    want_name[sizeof(want_name) - 1] = 0;
    if (!man || cj_num(man, "schema", 0) != 1 || !cm_is_hex64(version) || !entry || !ename || strcmp(ename, want_name) ||
        !cm_is_hex64(esha) || esize <= 0)
    {
        cj_free(man);
        cm_fail(L"The server published an invalid client mod manifest.");
        return -1;
    }
    char revision[65], name[160], sha[65];
    strcpy(revision, version);
    strcpy(name, ename);
    strcpy(sha, esha);
    cj_free(man);
    ULONGLONG size = (ULONGLONG)esize;

    wchar_t exe[CM_PATH], cards[CM_PATH];
    char exe_hex[65], cards_hex[65];
    cm_path(exe, game_dir, L"FIFA21.exe");
    cm_path(cards, game_dir, L"CardsDLL_Win64_retail.dll");
    if (!_wcsicmp(exe, cm_exe_digest_path) && cm_exe_digest_hex[0]) strcpy(exe_hex, cm_exe_digest_hex);
    else if (!cm_sha_file(exe, exe_hex)) return -1;
    if (!cm_sha_file(cards, cards_hex)) return -1;

    wchar_t cache[CM_PATH], downloads[CM_PATH], wrev[80], profile[CM_PATH];
    cm_cache_root(cache);
    cm_mkdirs(cache);
    cm_say(L"Client mod: profile cache %s", cache);
    cm_widen(revision, wrev, 80);
    cm_clean_cache(cache, revision, game_dir);
    cm_path(downloads, cache, L"downloads");
    cm_mkdirs(downloads);
    cm_clean_downloads(downloads, name);
    cm_path(profile, cache, wrev);
    if (cm_profile_ok(profile, revision, game_dir, exe_hex, cards_hex, moddata))
    {
        cm_say(L"Client mod %.8S: reusing the installed profile.", revision);
        strcpy(cm_revision, revision);
        return 1;
    }

    wchar_t wname[160], file[CM_PATH], partial[CM_PATH], url[256];
    cm_widen(name, wname, 160);
    cm_path(file, downloads, wname);
    _snwprintf(partial, CM_PATH - 1, L"%s.partial", file);
    partial[CM_PATH - 1] = 0;
    _snwprintf(url, 255, L"/client/mods/%s", wname);
    url[255] = 0;
    if (cm_file_size(file) != size)
    {
        ULONGLONG have = cm_file_size(partial);
        if (have >= size) { DeleteFileW(partial); have = 0; }
        if (cm_free_bytes(downloads) < (size - have) + (1536ULL << 20))
        {
            cm_fail(L"There is not enough free disk space for the client mod (about %llu MB needed).",
                    ((size - have) + (1536ULL << 20)) >> 20);
            return -1;
        }
        HANDLE f = CreateFileW(partial, GENERIC_WRITE, 0, NULL, have ? OPEN_ALWAYS : CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (f == INVALID_HANDLE_VALUE)
        {
            cm_fail(L"%s could not be opened (Windows error %lu).", partial, GetLastError());
            return -1;
        }
        if (have)
        {
            LARGE_INTEGER end;
            end.QuadPart = (LONGLONG)have;
            SetFilePointerEx(f, end, NULL, FILE_BEGIN);
        }
        cm_say(L"Client mod %.8S: downloading %llu MB%s.", revision, size >> 20, have ? L" (resuming)" : L"");
        st = cm_http(L"GET", host, url, NULL, have, f, NULL, size);
        CloseHandle(f);
        if (st != 200 && st != 206)
        {
            if (st == 416) DeleteFileW(partial);
            if (st) cm_fail(L"The server answered the client mod download with HTTP %d.", st);
            return -1;
        }
        if (cm_file_size(partial) != size)
        {
            cm_fail(L"The client mod download is incomplete; it resumes on the next attempt.");
            return -1;
        }
        if (!MoveFileExW(partial, file, MOVEFILE_REPLACE_EXISTING))
        {
            cm_fail(L"The client mod download could not be kept (Windows error %lu).", GetLastError());
            return -1;
        }
    }
    char got[65];
    if (!cm_sha_file(file, got)) return -1;
    if (strcmp(got, sha))
    {
        DeleteFileW(file);
        cm_fail(L"The downloaded client mod does not match the server's hash; it was removed.");
        return -1;
    }
    if (!cm_install_patch(game_dir, cache, file, exe_hex, cards_hex, got, moddata)) return -1;
    DeleteFileW(file);
    cm_clean_cache(cache, revision, game_dir);
    strcpy(cm_revision, revision);
    return 1;
}

/* Install-ClientMod. Fills moddata with the folder FIFA takes as -dataPath, or leaves it empty
 * (FIFA then starts without the mod, as the script does). */
static void a21_client_mod(const wchar_t *game_path, const wchar_t *logs, wchar_t *moddata, size_t cap)
{
    moddata[0] = 0;
    cm_revision[0] = 0;
    cm_install_state = "unavailable";
    if (cm_logh == INVALID_HANDLE_VALUE)
    {
        wchar_t lp[CM_PATH];
        cm_path(lp, logs, L"client-mod.log");
        cm_logh = CreateFileW(lp, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    }
    wchar_t game_dir[CM_PATH];
    wcsncpy(game_dir, game_path, CM_PATH - 1);
    game_dir[CM_PATH - 1] = 0;
    wchar_t *slash = wcsrchr(game_dir, L'\\');
    if (slash) *slash = 0;

    wchar_t found[CM_PATH];
    found[0] = 0;
    for (size_t i = 0; i < sizeof(A21_MATH_REPORT_HOSTS) / sizeof(A21_MATH_REPORT_HOSTS[0]); i++)
    {
        int r = cm_from_server(A21_MATH_REPORT_HOSTS[i], game_dir, found);
        if (r == 1) break;
        if (r < 0)
        {
            cm_install_state = "failed";
            cm_say(L"Client mod from %s: %s", A21_MATH_REPORT_HOSTS[i], cm_err);
        }
        found[0] = 0;
    }
    if (!found[0]) return;
    /* -dataPath "<folder>" must not end in a backslash: it would escape the closing quote. */
    size_t n = wcslen(found);
    while (n > 3 && found[n - 1] == L'\\') found[--n] = 0;
    if (n >= cap || !cm_moddata_ok(found))
    {
        cm_say(L"Client mod: the installed folder is not a complete ModData folder.");
        cm_install_state = "failed";
        cm_revision[0] = 0;
        return;
    }
    cm_install_state = "prepared";
    wcsncpy(moddata, found, cap - 1);
    moddata[cap - 1] = 0;
}

/* Test-ClientModRequired: whether the server needs its current client mod to let FIFA into
 * Ultimate Team (GET /client/mods/policy). The first front that answers decides; none
 * answering counts as not required, as the script has it. */
static BOOL a21_client_mod_required(void)
{
    for (size_t i = 0; i < sizeof(A21_MATH_REPORT_HOSTS) / sizeof(A21_MATH_REPORT_HOSTS[0]); i++)
    {
        char *body = NULL;
        int st = cm_http(L"GET", A21_MATH_REPORT_HOSTS[i], L"/client/mods/policy", NULL, 0, INVALID_HANDLE_VALUE, &body, 0);
        if (st == 200 && body)
        {
            cm_j *j = cj_parse(body);
            const cm_j *r = cj_get(j, "required");
            BOOL required = r && r->t == CJ_BOOL && r->n;
            cj_free(j);
            free(body);
            cm_note(L"Policy from %s: required=%d", A21_MATH_REPORT_HOSTS[i], (int)required);
            return required;
        }
        free(body);
        if (st) cm_say(L"Client mod policy from %s: HTTP %d", A21_MATH_REPORT_HOSTS[i], st);
        else cm_say(L"Client mod policy from %s: %s", A21_MATH_REPORT_HOSTS[i], cm_err);
    }
    return FALSE;
}

/* Send-ClientModReport: tells the server which client mod this FIFA started with (POST
 * /client/launch/mods), so matchmaking pairs it only with players on the same mod. "" is no
 * mod. Best-effort: a failed report leaves the server's answer at no mod, never the launch. */
static void a21_client_mod_report(const char *code, BOOL have_mod)
{
    char body[512];
    _snprintf(body, sizeof(body) - 1,
              "{\"code\":\"%s\",\"mod\":\"%s\",\"launch\":\"direct\",\"install\":\"%s\",\"argument\":\"%s\"}",
              code, have_mod ? cm_revision : "", cm_install_state, have_mod ? "received" : "not-requested");
    body[sizeof(body) - 1] = 0;
    for (size_t i = 0; i < sizeof(A21_MATH_REPORT_HOSTS) / sizeof(A21_MATH_REPORT_HOSTS[0]); i++)
    {
        char *reply = NULL;
        int st = cm_http(L"POST", A21_MATH_REPORT_HOSTS[i], L"/client/launch/mods", body, 0, INVALID_HANDLE_VALUE, &reply, 0);
        if (st >= 200 && st < 300)
        {
            cm_j *j = reply ? cj_parse(reply) : NULL;
            const cm_j *cur = cj_get(j, "current");
            cm_say(L"Client mod reported (%.8S, current: %s)", have_mod ? cm_revision : "none",
                   cur && cur->t == CJ_BOOL ? (cur->n ? L"True" : L"False") : L"unknown");
            cj_free(j);
            free(reply);
            return;
        }
        free(reply);
        if (st) cm_say(L"Client mod report to %s: HTTP %d", A21_MATH_REPORT_HOSTS[i], st);
        else cm_say(L"Client mod report to %s: %s", A21_MATH_REPORT_HOSTS[i], cm_err);
    }
}

/* Invoke-TrustPatchUntilReady for the game this program started. */
static char *a21_trust_patch(const wchar_t *pack, const wchar_t *anchors, DWORD game_pid,
                             BOOL patch_origin)
{
    wchar_t server[MAX_PATH], root[MAX_PATH], cmd[2048];
    join(server, MAX_PATH, pack, L"trust\\Aurora21-UltimateTeam-Server.exe");
    join(root, MAX_PATH, pack, L"trust");
    SetEnvironmentVariableW(L"ULTIMATETEAM_CERTIFICATE_ROOT", root);
    _snwprintf(cmd, 2047, L"\"%s\" trust-patch --pid %lu%s --trust-anchors \"%s\"",
               server, game_pid, patch_origin ? L"" : L" --skip-origin", anchors);
    cmd[2047] = 0;

    DWORD deadline = GetTickCount() + A21_TRUST_TIMEOUT_MS;
    char *latest = NULL;
    for (;;)
    {
        free(latest);
        latest = a21_run_capture(cmd, pack, A21_TRUST_TIMEOUT_MS, NULL);
        if (a21_trust_patched(latest, patch_origin)) return latest;
        if ((LONG)(GetTickCount() - deadline) >= 0) return latest;
        Sleep(2000);
    }
}

/* Invoke-AuthBridge. Returns 0, or writes the script's reason to *error. */
static BOOL a21_auth_bridge(const wchar_t *pack, const wchar_t *game_path, DWORD game_pid,
                            const char *code, const wchar_t *bridge_log,
                            wchar_t *error, size_t cap)
{
    wchar_t helper[MAX_PATH], cmd[4096], stdio_log[MAX_PATH];
    join(helper, MAX_PATH, pack, L"Aurora21-LocalAuthBridge.exe");
    _snwprintf(cmd, 4095, L"\"%s\" --pid %lu --game \"%s\" --fut-code-stdin --hosted --log \"%s\"",
               helper, game_pid, game_path, bridge_log);
    cmd[4095] = 0;
    _snwprintf(stdio_log, MAX_PATH - 1, L"%s.stdio", bridge_log);
    stdio_log[MAX_PATH - 1] = 0;

    HANDLE child_in, parent_in;
    if (!a21_pipe(&child_in, &parent_in, TRUE))
    {
        _snwprintf(error, cap - 1, L"The auth bridge could not be started.");
        error[cap - 1] = 0;
        return FALSE;
    }
    HANDLE outh = a21_inheritable_file(stdio_log, TRUE);
    DWORD pid = 0;
    HANDLE p = a21_spawn(cmd, pack, child_in, outh, outh, &pid);
    CloseHandle(child_in);
    if (outh != INVALID_HANDLE_VALUE) CloseHandle(outh);
    if (!p)
    {
        CloseHandle(parent_in);
        _snwprintf(error, cap - 1, L"The auth bridge could not be started.");
        error[cap - 1] = 0;
        return FALSE;
    }
    char line[64];
    int n = _snprintf(line, sizeof(line), "%s\r\n", code);
    DWORD wr;
    if (n > 0) WriteFile(parent_in, line, (DWORD)n, &wr, NULL);
    SecureZeroMemory(line, sizeof(line));
    CloseHandle(parent_in);

    if (WaitForSingleObject(p, A21_BRIDGE_TIMEOUT_MS) != WAIT_OBJECT_0)
    {
        /* Never killed: it may be completing or rolling back its in-memory change. */
        CloseHandle(p);
        _snwprintf(error, cap - 1,
                   L"The auth bridge did not finish within 60 seconds (PID %lu left running). See %s",
                   pid, bridge_log);
        error[cap - 1] = 0;
        return FALSE;
    }
    DWORD exit_code = 1;
    GetExitCodeProcess(p, &exit_code);
    CloseHandle(p);
    char *text = read_all_utf8(bridge_log, NULL);
    BOOL ready = text && (a21_has_line(text, "[READY]") || a21_has_line(text, "[ALREADY]"));
    free(text);
    if (exit_code != 0 || !ready)
    {
        _snwprintf(error, cap - 1, L"The auth bridge did not confirm readiness (exit %lu). See %s",
                   exit_code, bridge_log);
        error[cap - 1] = 0;
        return FALSE;
    }
    return TRUE;
}

/* ------------------------------------------------------------------ script */

/* -LogPath, or %TEMP%\aurora21-client as the script has it. */
static void a21_logs_dir(const wchar_t *log_arg, wchar_t *logs)
{
    if (log_arg && *log_arg)
        wcsncpy(logs, log_arg, MAX_PATH - 1);
    else
    {
        wchar_t tmp[MAX_PATH];
        GetEnvironmentVariableW(L"TEMP", tmp, MAX_PATH);
        join(logs, MAX_PATH, tmp, L"aurora21-client");
    }
    logs[MAX_PATH - 1] = 0;
}

static int run_start_aurora21(const wchar_t *script_path, int argc, wchar_t **argv)
{
    const wchar_t *game_path = NULL, *server_address = NULL, *trust_anchors = NULL;
    const wchar_t *log_arg = NULL, *launch_arg = L"auto";
    BOOL no_game_launch = FALSE, detect_only = FALSE, cleanup = FALSE, client_mod_only = FALSE;
    DWORD watch_pid = 0;
    for (int i = 0; i < argc; i++)
    {
        const wchar_t *a = argv[i];
        BOOL more = i + 1 < argc;
        if (!_wcsicmp(a, L"-GamePath") && more) game_path = argv[++i];
        else if (!_wcsicmp(a, L"-ServerAddress") && more) server_address = argv[++i];
        else if (!_wcsicmp(a, L"-TrustAnchors") && more) trust_anchors = argv[++i];
        else if (!_wcsicmp(a, L"-LogPath") && more) log_arg = argv[++i];
        else if (!_wcsicmp(a, L"-EAAppLauncherPath") && more) ++i;
        else if (!_wcsicmp(a, L"-LaunchMethod") && more) launch_arg = argv[++i];
        else if (!_wcsicmp(a, L"-NoGameLaunch")) no_game_launch = TRUE;
        else if (!_wcsicmp(a, L"-DetectOnly")) detect_only = TRUE;
        else if (!_wcsicmp(a, L"-Cleanup")) cleanup = TRUE;
        else if (!_wcsicmp(a, L"-ClientModOnly")) client_mod_only = TRUE;   /* ours: install the mod, start nothing */
        else if (!_wcsicmp(a, L"-WatchFriendlies") && more) watch_pid = wcstoul(argv[++i], NULL, 10);
    }
    /* Ours, not the script's: see the friendlies parser above. */
    if (watch_pid) return a21_watch_friendlies(watch_pid);

    /* Everything the exit path below cleans up, set before the first way out. */
    a21_game game = {0};
    PROCESS_INFORMATION started;
    ZeroMemory(&started, sizeof(started));
    BOOL held = FALSE, mod_checked = FALSE, have_mod = FALSE;
    a21_math math;
    ZeroMemory(&math, sizeof(math));
    char code[128] = {0};

    /* Take-HostedDiscordUsername: read once, and kept from every child. */
    char discord_username[128] = {0};
    {
        wchar_t w[128];
        DWORD n = GetEnvironmentVariableW(L"AURORA21_DISCORD_USERNAME", w, 128);
        if (n > 0 && n < 128)
            WideCharToMultiByte(CP_UTF8, 0, w, -1, discord_username, sizeof(discord_username), NULL, NULL);
        SetEnvironmentVariableW(L"AURORA21_DISCORD_USERNAME", NULL);
    }

    wchar_t pack[MAX_PATH];
    a21_parent_dir(script_path, pack, MAX_PATH);

    BOOL game_named = game_path && (!_wcsicmp(a21_leaf(game_path), L"FIFA21.exe") ||
                                    !_wcsicmp(a21_leaf(game_path), L"FIFA21_Trial.exe"));
    wchar_t reason[256];
    const wchar_t *method = NULL;
    if (detect_only)
    {
        if (!game_named) return a21_fail(2, L"GamePath must be the FIFA21.exe of the installed game.");
        method = _wcsicmp(launch_arg, L"auto") ? launch_arg : a21_launch_method(game_path, reason, 256);
        if (_wcsicmp(launch_arg, L"auto")) wcscpy(reason, L"chosen with -LaunchMethod");
        out(L"[READY] launch method %s (%s)\n", method, reason);
        return 0;
    }
    /* Test-Administrator has nothing to test: a bottle has no UAC, and every
     * process in it may write the hosts file and FIFA's memory. */
    if (cleanup)
    {
        wchar_t error[1024];
        if (!a21_remove_hosts_entry(error, 1024)) return a21_fail(6, L"%s", error);
        out(L"[READY] hosts entry removed\n");
        return 0;
    }

    if (client_mod_only)
    {
        if (!game_named || !file_exists(game_path))
            return a21_fail(2, L"GamePath must be the FIFA21.exe of the installed game.");
        wchar_t lg[MAX_PATH], md[MAX_PATH];
        a21_logs_dir(log_arg, lg);
        ensure_dir(lg);
        int pre = a21_binary_preflight(game_path);
        if (pre != 0) return pre;
        /* The install removes earlier profiles, which a running FIFA may be using. */
        if (a21_newest_game(&game)) return a21_fail(3, L"FIFA 21 is already running: close it first.");
        out(L"[INFO] Checking the client mod...\n");
        a21_client_mod(game_path, lg, md, MAX_PATH);
        if (!md[0]) return a21_fail(3, L"The client mod was not installed; see %s\\client-mod.log", lg);
        out(L"[READY] client mod %s\n", md);
        return 0;
    }

    /* The one-time code arrives on standard input only. */
    {
        HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
        size_t n = 0;
        char c;
        DWORD rd;
        while (n < sizeof(code) - 1 && ReadFile(in, &c, 1, &rd, NULL) && rd == 1 && c != '\n')
            code[n++] = c;
        while (n && (code[n - 1] == '\r' || code[n - 1] == ' ')) code[--n] = 0;
        BOOL valid = n == 40;
        for (size_t i = 0; valid && i < n; i++)
            valid = (code[i] >= '0' && code[i] <= '9') || (code[i] >= 'a' && code[i] <= 'f');
        if (!valid)
        {
            SecureZeroMemory(code, sizeof(code));
            return a21_fail(2, L"No valid game code on standard input.");
        }
    }
    int rc = 0;
    IN_ADDR v4;
    wchar_t address[64] = L"";
    if (!server_address || InetPtonW(AF_INET, server_address, &v4) != 1)
    {
        rc = a21_fail(2, L"ServerAddress must be the server's IPv4 address (gameAddress from /client/health or /client/launch).");
        goto done;
    }
    InetNtopW(AF_INET, &v4, address, 64);
    if (!game_named || !file_exists(game_path))
    {
        rc = a21_fail(2, L"GamePath must be the FIFA21.exe of the installed game.");
        goto done;
    }
    {
        static const wchar_t *anchors[] = { L"local-gos2015-modulus.bin", L"local-gs2019-modulus.bin" };
        for (int i = 0; i < 2; i++)
        {
            wchar_t p[MAX_PATH];
            WIN32_FILE_ATTRIBUTE_DATA fa;
            join(p, MAX_PATH, trust_anchors ? trust_anchors : L"", anchors[i]);
            if (!GetFileAttributesExW(p, GetFileExInfoStandard, &fa) ||
                (fa.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
                fa.nFileSizeHigh != 0 || fa.nFileSizeLow != 256)
            {
                rc = a21_fail(2, L"TrustAnchors must hold this server's %s (GET /client/trust-anchors/manifest.json).",
                              anchors[i]);
                goto done;
            }
        }
    }
    wchar_t logs[MAX_PATH];
    a21_logs_dir(log_arg, logs);
    ensure_dir(logs);

    if ((rc = a21_binary_preflight(game_path)) != 0) goto done;

    if (_wcsicmp(launch_arg, L"auto"))
    {
        method = launch_arg;
        wcscpy(reason, L"chosen with -LaunchMethod");
    }
    else
        method = a21_launch_method(game_path, reason, 256);

    {
        const wchar_t *programs[] = { a21_leaf(game_path), L"Aurora21-MathBridge.exe" };
        for (int i = 0; i < 2; i++)
        {
            LSTATUS err;
            if (!a21_prefer_pinned_ucrt(programs[i], &err))
                out(L"[INFO] maths bridge: Wine could not be told to load the pinned ucrtbase for %s (error %ld)\n",
                    programs[i], (long)err);
        }
    }

    if (a21_newest_game(&game))
    {
        if (!no_game_launch)
        {
            rc = a21_fail(3, L"FIFA 21 is already running: close it and press Play again.");
            goto done;
        }
    }
    else if (!no_game_launch)
    {
        if (_wcsicmp(method, L"direct"))
        {
            /* The EA app and Steam do not run in a bottle, so a copy that has to go
             * through them cannot be started from here. */
            rc = a21_fail(3, L"This FIFA 21 is %s, which starts through %s, and neither runs in this "
                             L"CrossOver bottle. Choose a FIFA 21 folder that starts on its own "
                             L"(an anadius copy).",
                          reason, _wcsicmp(method, L"steam") ? L"the EA app" : L"Steam");
            goto done;
        }
        if (discord_username[0])
        {
            DWORD hr = 0;
            const wchar_t *category = a21_sync_username(game_path, discord_username, &hr);
            if (category)
            {
                out(L"[INFO] Direct-copy Username update failed (%s, 0x%08lX).\n", category, hr);
                rc = a21_fail(3, L"The direct copy local Username could not be updated safely; FIFA 21 was not started.");
                goto done;
            }
        }
        /* Install-ClientMod. The server requires its client mod now: a FIFA started without it
         * is refused at Ultimate Team's login, which the player sees as a connection error. */
        out(L"[INFO] Checking the client mod...\n");
        wchar_t moddata[MAX_PATH];
        a21_client_mod(game_path, logs, moddata, MAX_PATH);
        mod_checked = TRUE;
        have_mod = moddata[0] != 0;
        if (!have_mod)
        {
            if (a21_client_mod_required())
            {
                rc = a21_fail(3, L"Aurora's client mod could not be installed, and this server needs it to enter "
                                 L"Ultimate Team. Check that the disk has free space and FIFA 21's files are "
                                 L"complete, then press Play again. Details: %s\\client-mod.log", logs);
                goto done;
            }
            out(L"[INFO] Starting FIFA 21 without the client mod.\n");
        }
        out(L"[INFO] Starting FIFA21.exe directly (%s)\n", reason);
        wchar_t dir[MAX_PATH], cmdline[3 * MAX_PATH];
        a21_parent_dir(game_path, dir, MAX_PATH);
        if (have_mod)
            _snwprintf(cmdline, 3 * MAX_PATH - 1, L"\"%s\" -dataPath \"%s\"", game_path, moddata);
        else
            _snwprintf(cmdline, 3 * MAX_PATH - 1, L"\"%s\"", game_path);
        cmdline[3 * MAX_PATH - 1] = 0;
        STARTUPINFOW si;
        ZeroMemory(&si, sizeof(si));
        si.cb = sizeof(si);
        if (!CreateProcessW(game_path, cmdline, NULL, NULL, FALSE, 0, NULL, dir, &si, &started))
        {
            rc = a21_fail(3, L"FIFA21.exe could not be started: Windows error %lu", GetLastError());
            goto done;
        }
        CloseHandle(started.hThread);
        started.hThread = NULL;
        game.pid = started.dwProcessId;
        if ((rc = a21_wait_game_window(started.hProcess, game.pid)) != 0) goto done;
        if (!a21_suspend_process(started.hProcess, TRUE))
        {
            rc = a21_fail(3, L"FIFA21.exe could not be paused for patching: Windows error %lu",
                          GetLastError());
            goto done;
        }
        held = TRUE;
    }
    if (!game.pid)
    {
        DWORD deadline = GetTickCount() + A21_START_TIMEOUT_MS;
        while (!a21_newest_game(&game))
        {
            if ((LONG)(GetTickCount() - deadline) >= 0)
            {
                rc = a21_fail(3, L"FIFA21.exe did not start within 180 seconds.");
                goto done;
            }
            Sleep(200);
        }
    }

    /* The maths bridge starts before the trust patch, as in the script. It
     * switches both of FIFA's maths tables when FIFA has already copied one. */
    {
        wchar_t mlog[MAX_PATH], why[512];
        join(mlog, MAX_PATH, logs, L"math-bridge.log");
        if (!a21_start_math_bridge(pack, game_path, game.pid, mlog, &math, why, 512))
            out(L"[INFO] maths bridge: not started (%s); pairing uses the Windows build\n", why);
    }
    out(L"[INFO] FIFA 21 is running; patching its trust tables\n");

    {
        BOOL patch_origin = !_wcsicmp(method, L"direct");
        wchar_t tlog[MAX_PATH];
        join(tlog, MAX_PATH, logs, L"trust-patch.log");
        char *patch = a21_trust_patch(pack, trust_anchors, game.pid, patch_origin);
        if (patch) write_all_utf8(tlog, patch);
        BOOL ok = a21_trust_patched(patch, patch_origin);
        free(patch);
        if (!ok)
        {
            rc = a21_fail(4, L"The trust patch did not succeed; see %s. The hosts file was left unchanged.", tlog);
            goto done;
        }
    }
    out(L"[INFO] trust tables patched; starting the auth bridge\n");

    {
        wchar_t blog[MAX_PATH], error[1024];
        join(blog, MAX_PATH, logs, L"auth-bridge.log");
        if (!a21_auth_bridge(pack, game_path, game.pid, code, blog, error, 1024))
        {
            rc = a21_fail(5, L"%s", error);
            goto done;
        }
    }
    {
        wchar_t error[2048];
        if (!a21_set_hosts_entry(address, error, 2048))
        {
            rc = a21_fail(6, L"%s", error);
            goto done;
        }
    }

    if (held)
    {
        if (!a21_suspend_process(started.hProcess, FALSE))
        {
            rc = a21_fail(3, L"FIFA21.exe could not be resumed: Windows error %lu", GetLastError());
            goto done;
        }
        held = FALSE;
    }

    {
        wchar_t flog[MAX_PATH], why[512];
        join(flog, MAX_PATH, logs, L"friendlies-patch.log");
        if (a21_start_friendlies_watch(script_path, game.pid, flog, why, 512))
            out(L"[INFO] friendlies fix: waiting for Ultimate Team to load CardsDLL (see friendlies-patch.log)\n");
        else
            out(L"[INFO] friendlies fix: not started (%s); Online Friendlies may freeze\n", why);
    }

    /* Ready: the maths helper of the patched process gets the code for its
     * report (it sends it once its switch has held). */
    a21_submit_math_code(&math, game.pid, code);
    /* Complete-ClientModLaunch: which client mod this FIFA started with, for matchmaking. */
    if (mod_checked) a21_client_mod_report(code, have_mod);
    SecureZeroMemory(code, sizeof(code));
    a21_math_status(&math);
    out(L"[READY] FIFA 21 (PID %lu) is patched and routed to %s\n", game.pid, address);

done:
    /* A game this program started and could not get ready is not left behind:
     * unpatched or unrouted it would only reach EA, and the next PLAY would
     * stop at "FIFA 21 is already running". A helper that is never handed the
     * code reports nothing. */
    if (started.hProcess)
    {
        if (rc != 0) TerminateProcess(started.hProcess, 1);
        CloseHandle(started.hProcess);
    }
    a21_submit_math_code(&math, 0, NULL);
    if (math.process) CloseHandle(math.process);
    SecureZeroMemory(code, sizeof(code));
    return rc;
}

/* -------------------------------------------------------------------- main */

#include "fut12-link.c"

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
    /* Aurora 12 sends its secure-link steps as -EncodedCommand. */
    if (!script)
    {
        for (int i = 1; i + 1 < argc; i++)
            if (!_wcsicmp(argv[i], L"-EncodedCommand") || !_wcsicmp(argv[i], L"-enc"))
            {
                int code = fut12_encoded(argv[i + 1]);
                if (code >= 0) return code;
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
    else if (!_wcsicmp(name, L"launch_fifa.ps1"))
        rc = fut12_launch(script, argc - rest, argv + rest);
    else if (!_wcsicmp(name, L"Start-Aurora21.ps1"))
        rc = run_start_aurora21(script, argc - rest, argv + rest);
    else
        rc = fail_code(ERR_UNSUPPORTED_CMD, L"aurora-pwsh does not implement %s.", name);

    WSACleanup();
    return rc;
}
