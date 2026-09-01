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
        while (*p == ' ' || *p == '\r' || *p == '\n' || *p == '\t' || (unsigned char)*p == 0xEF) p++;
        char clean[128];
        int n = 0;
        while (*p && isxdigit((unsigned char)*p) && n < 127) clean[n++] = *p++;
        clean[n] = 0;
        free(existing);
        if (n == 64) { strncpy(key_out, clean, cap - 1); key_out[cap - 1] = 0; return TRUE; }
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

/* Mirrors Play.ps1's Get-AuthenticatedServerHealth: a 200 is not enough, the
 * identity fields have to match too, so a foreign server is never mistaken for ours. */
static BOOL server_healthy(const char *key)
{
    char *body = NULL;
    int st = http_request("GET", CONTROL_PORT, "/v1/health", key, NULL, NULL, 5000, &body);
    if (st != 200 || !body) { free(body); return FALSE; }

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

    free(product); free(id); free(version); free(build); free(nonce); free(schema); free(body);
    return ok;
}

/* ------------------------------------------------------------- head cache */

static int refresh_player_head_cache(const char *generation)
{
    procid list[8];
    if (find_processes(L"FIFA17.exe", list, 8) > 0)
        return fail(L"FIFA17 is running. Close it before refreshing the player-head cache.");

    wchar_t docs[MAX_PATH];
    if (FAILED(SHGetFolderPathW(NULL, CSIDL_PERSONAL, NULL, 0, docs)))
        return fail(L"Windows did not return a Documents directory.");

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
    if (dir_exists(quarantine))
        return fail(L"Refusing to overwrite an existing cache quarantine.");
    if (!MoveFileW(cache, quarantine))
        return fail(L"Could not quarantine the stale player-head cache (%lu).", GetLastError());
    ensure_dir(cache);
    if (generation && *generation) write_all_utf8(marker, generation);
    out(L"Quarantined the stale player-head cache and created an empty one.\n");
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
        return fail(L"The packaged Aurora17 server is missing: %s", server_exe);

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
    if (!h) return fail(L"Windows did not start the Aurora17 server (%lu).", GetLastError());

    ULONGLONG start_time = process_start(h);
    DWORD sp, lp; ULONGLONG ss, ls;
    state_read(&sp, &ss, &lp, &ls);
    state_write(pid, start_time, lp, ls);

    DWORD waited = 0;
    for (;;)
    {
        Sleep(2000);
        waited += 2000;
        if (WaitForSingleObject(h, 0) == WAIT_OBJECT_0)
        {
            DWORD code = 1;
            GetExitCodeProcess(h, &code);
            CloseHandle(h);
            return fail(L"The server exited during startup with code %lu. Log: %s", code, log);
        }
        char *text = read_all_utf8(log, NULL);
        if (text)
        {
            BOOL rejected = strstr(text, "Redirector listener not started:") != NULL;
            free(text);
            if (rejected)
            {
                CloseHandle(h);
                return fail(L"The redirector listener was rejected during startup. Log: %s", log);
            }
        }
        if (server_healthy(key)) break;
        if (waited >= SERVER_READY_TIMEOUT_MS)
        {
            CloseHandle(h);
            return fail(L"The server did not pass its authenticated readiness check. Log: %s", log);
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
    if (!dir_exists(root)) return fail(L"The Aurora17 installation could not be located: %s", root);

    wchar_t localappdata[MAX_PATH];
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", localappdata, MAX_PATH))
        return fail(L"The current Windows LocalAppData folder could not be resolved.");

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
    if (!held) return fail(L"Another Aurora17 launch operation is already in progress.");

    int rc = 0;
    char key[128] = {0};
    if (!load_control_key(localappdata, key, sizeof(key)))
    { rc = fail(L"The Aurora17 control key could not be created or read."); goto done; }

    wchar_t wkey[128];
    MultiByteToWideChar(CP_UTF8, 0, key, -1, wkey, 128);
    SetEnvironmentVariableW(L"AURORA17_Control__ControlKey", wkey);

    DWORD server_pid, launch_pid;
    ULONGLONG server_start, launch_start;
    state_read(&server_pid, &server_start, &launch_pid, &launch_start);

    if (port_is_listening(CONTROL_PORT))
    {
        if (server_healthy(key))
            out(L"Server already running - leaving it alone.\n");
        else if (server_pid && process_is(server_pid, L"Aurora17.Server.exe", server_start))
        {
            out(L"A server is running but was started with a different control key. Restarting it...\n");
            kill_pid(server_pid);
            Sleep(3000);
            if ((rc = start_server(root, localappdata, key))) goto done;
        }
        else
        {
            rc = fail(L"A server is already listening on %d that Aurora17 does not own. "
                      L"Close it and try again.", CONTROL_PORT);
            goto done;
        }
    }
    else
    {
        if (server_pid && process_is(server_pid, L"Aurora17.Server.exe", server_start))
        {
            out(L"Stopping the recorded server process that is no longer listening...\n");
            kill_pid(server_pid);
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
    { rc = fail(L"The live routing document does not identify the player-head archive generation."); goto done; }
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
    { rc = fail(L"The supplied Aurora17 connector does not exist: %s", connector); goto done; }

    wchar_t connector_dir[MAX_PATH];
    wcsncpy(connector_dir, connector, MAX_PATH - 1);
    connector_dir[MAX_PATH - 1] = 0;
    slash = wcsrchr(connector_dir, L'\\');
    if (slash) *slash = 0;

    out(L"Enrolling...\n");
    char *resp = NULL;
    int st = http_request("POST", CONTROL_PORT, "/v1/control/bootstrap-tickets", key,
                          "application/json",
                          "{\"AccountId\":\"1000000000001\",\"PersonaId\":\"2000000000001\","
                          "\"DisplayName\":\"Aurora17\",\"Audience\":\"fifa17\"}",
                          30000, &resp);
    if (st < 200 || st > 299 || !resp)
    { free(resp); rc = fail(L"The Aurora17 server refused to mint a bootstrap ticket (HTTP %d).", st); goto done; }
    char *ticket = json_string(resp, "bootstrapTicket");
    free(resp);
    if (!ticket || !*ticket)
    { free(ticket); rc = fail(L"The ticket response contained no bootstrapTicket."); goto done; }

    wchar_t temp_dir[MAX_PATH], ticket_file[MAX_PATH];
    GetTempPathW(MAX_PATH, temp_dir);
    _snwprintf(ticket_file, MAX_PATH - 1, L"%saurora17-ticket-%lu-%lu",
               temp_dir, (unsigned long)GetCurrentProcessId(), GetTickCount());
    BOOL wrote = write_all_utf8(ticket_file, ticket);
    SecureZeroMemory(ticket, strlen(ticket));
    free(ticket);
    if (!wrote) { rc = fail(L"The one-time ticket could not be staged."); goto done; }

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
    { rc = fail(L"The Aurora17 connector could not enroll the account (exit %lu).", ecode); goto done; }

    out(L"Launching FIFA 17...\n");
    out(L"If FIFA Configuration opens, click Play; Aurora17 keeps the session ready for four minutes.\n");
    _snwprintf(cmd, MAX_PATH + 31, L"\"%s\" launch", connector);
    DWORD lpid = 0;
    HANDLE lh = spawn(cmd, connector_dir, NULL, NULL, NULL, &lpid);
    if (!lh) { rc = fail(L"Windows did not start the Aurora17 launch connector (%lu).", GetLastError()); goto done; }

    ULONGLONG lstart = process_start(lh);
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
                rc = fail(L"The Aurora17 launch connector exited with code %lu (0x%08lx) "
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
            if (process_is(game_pid, L"FIFA17.exe", 0)) break;
            game_pid = 0;
        }
        if (waited >= FIFA_LAUNCH_TIMEOUT_MS)
        {
            CloseHandle(lh);
            rc = fail(L"FIFA 17 did not start before the five-minute launch deadline.");
            goto done;
        }
    }
    CloseHandle(lh);
    out(L"FIFA 17 is running (pid %lu). Go to Ultimate Team.\n", (unsigned long)game_pid);

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
        return fail(L"The current Windows LocalAppData folder could not be resolved.");

    char key[128] = {0};
    wchar_t keyfile[MAX_PATH];
    join(keyfile, MAX_PATH, localappdata, L"Aurora17\\control-key.txt");
    if (!file_exists(keyfile))
    {
        wchar_t env[128];
        if (GetEnvironmentVariableW(L"AURORA17_Control__ControlKey", env, 128))
            WideCharToMultiByte(CP_UTF8, 0, env, -1, key, sizeof(key), NULL, NULL);
        else
            return fail(L"No control key. Start Aurora17 with PLAY first.");
    }
    else if (!load_control_key(localappdata, key, sizeof(key)))
        return fail(L"The Aurora17 control key could not be read.");

    char *resp = NULL;
    int st = http_request("POST", CONTROL_PORT, "/v1/control/reset-fut-club", key,
                          "application/json", "", 120000, &resp);
    if (st < 200 || st > 299)
    {
        free(resp);
        return fail(L"The FUT club reset failed (HTTP %d). Make sure the Aurora17 server is running.", st);
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
    return fail(L"Creating a new redirector certificate needs Windows PowerShell's PKI module, "
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
        return 1;
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
        rc = fail(L"aurora-pwsh does not implement %s.", name);

    WSACleanup();
    return rc;
}
