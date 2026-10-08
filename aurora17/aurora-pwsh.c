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

static const wchar_t *A21_MATH_REPORT_HOSTS[] = {
    L"21.aurorafut.com", L"21.onlyonemzy.com", L"21.aurcdn.com",
};

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

static int run_start_aurora21(const wchar_t *script_path, int argc, wchar_t **argv)
{
    const wchar_t *game_path = NULL, *server_address = NULL, *trust_anchors = NULL;
    const wchar_t *log_arg = NULL, *launch_arg = L"auto";
    BOOL no_game_launch = FALSE, detect_only = FALSE, cleanup = FALSE;
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
    }

    /* Everything the exit path below cleans up, set before the first way out. */
    a21_game game = {0};
    PROCESS_INFORMATION started;
    ZeroMemory(&started, sizeof(started));
    BOOL held = FALSE;
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
    if (log_arg && *log_arg)
        wcsncpy(logs, log_arg, MAX_PATH - 1);
    else
    {
        wchar_t tmp[MAX_PATH];
        GetEnvironmentVariableW(L"TEMP", tmp, MAX_PATH);
        join(logs, MAX_PATH, tmp, L"aurora21-client");
    }
    logs[MAX_PATH - 1] = 0;
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
        out(L"[INFO] Starting FIFA21.exe directly (%s)\n", reason);
        wchar_t dir[MAX_PATH], cmdline[MAX_PATH + 4];
        a21_parent_dir(game_path, dir, MAX_PATH);
        _snwprintf(cmdline, MAX_PATH + 3, L"\"%s\"", game_path);
        cmdline[MAX_PATH + 3] = 0;
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

    /* Ready: the maths helper of the patched process gets the code for its
     * report (it sends it once its switch has held). */
    a21_submit_math_code(&math, game.pid, code);
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
    else if (!_wcsicmp(name, L"Start-Aurora21.ps1"))
        rc = run_start_aurora21(script, argc - rest, argv + rest);
    else
        rc = fail_code(ERR_UNSUPPORTED_CMD, L"aurora-pwsh does not implement %s.", name);

    WSACleanup();
    return rc;
}
