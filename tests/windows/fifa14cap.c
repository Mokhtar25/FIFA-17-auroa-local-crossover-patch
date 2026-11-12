/* fifa14cap -- the whole FIFA 14 Windows capture in one program.
 *
 *   fifa14cap.exe                 (normally started through RUN-ME.cmd)
 *   fifa14cap.exe --seconds 240 --va 0x3F4DB78 --skip-tests
 *
 * What it does, in order, with no input from the person at the keyboard
 * except starting the game:
 *
 *   1. system.txt        Windows version, elevation, WOW64, Wine or not
 *   2. tests-*.txt       the four reference programs in bin\ (no game needed)
 *   3. waits for fifa14.exe, opens it as soon as it exists (5 ms polling)
 *   4. reads the PE headers of the *running* exe from disk and works out, from
 *      the file, which section the watched address lies in and what the file
 *      holds there -- so a wrong address is reported instead of silently
 *      measuring another page
 *   5. watches that page and every section of the image (protection, type,
 *      bytes) and prints a line only when something changes
 *   6. full region maps and module lists at 0 / 2 / 10 / 30 s and at the end
 *   7. SHA-256 of the three game files
 *   8. summary.txt with a verdict, then a .zip of the whole folder
 *
 * kit v4 adds (all strictly read-only, see the table of addresses below):
 *   - snap-<t>-.data-full.bin   the whole VIRTUAL extent of .data (raw part plus
 *                               the demand-zero tail where the protector keeps its
 *                               VM state cells) at 0.3 1 2 3 5 8 15 s, with a
 *                               sidecar .unreadable.txt listing uncommitted pages
 *   - cells.txt                 timeline of a few watched cells, polled every loop
 *   - code-<t>-<va>.bin         the unpacked protector code pages at 2 5 15 s
 *   - threads.txt               every 250 ms the main thread's registers, via
 *                               SuspendThread / GetThreadContext / ResumeThread.
 *                               OFF with FIFA14CAP_NOTHREADS=1 or --nothreads.
 *
 * The watched address is an ABSOLUTE virtual address (the number the Mac trace
 * and every note in HANDOFF-fifa14.md use: 0x03F4DB78, inside .rdata at the
 * fixed image base 0x400000).  It is not an offset from the module base.
 *
 * Nothing here is a debugger, an injection or a driver, and nothing is written
 * to the game or its folder.  It only calls VirtualQueryEx / ReadProcessMemory
 * on the game, which is why the game behaves as when you play it.
 *
 * Build:  i686-w64-mingw32-gcc -O2 -Wall -Wno-format-truncation -o bin/fifa14cap.exe fifa14cap.c -lpsapi -lwinmm
 *         (-Wno-format-truncation: GCC 16 flags every MAX_PATH snprintf; all are bounded)
 */
#define __USE_MINGW_ANSI_STDIO 1
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <conio.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ---------------------------------------------------------------- facts */

#define KIT_VERSION  "kit v4"
#define DEFAULT_VA   0x03F4DB78u
#define GAME_EXE     "fifa14.exe"
#define LOADER_EXE   "fifa14-3dm.exe"

static const struct { const char *file; const char *sha; } KNOWN[] = {
    { "fifa14.exe",
      "034991bce371bb2d4e802184dc43e423b0fd7b6d06bf0e41ef12ca0dbc623916" },
    { "fifa14-3dm.exe",
      "546cf2e33bde55177d45b340b78a8c9eb2ccebb571a78b7c485389d83b7f79ca" },
    { "fifa14.3dm.dll",
      "8d50bbb06b59712f443d7e936e5229e003fcad2c1ecb9a224fff5d5ca250509d" },
};

/* ---------------------------------------------- the v4 address tables
 *
 * EVERY absolute virtual address that kit v4 touches is in these tables.  They
 * are numbers from the Mac trace (HANDOFF-fifa14.md, "2026-11-10 late"/"night 4").
 * validate_addrs() checks each one against the live PE headers and prints which
 * section it falls in, or a WARNING line if it is outside the image; a wrong
 * address is never fatal, the read just fails quietly and is retried. */

enum { CELL_BPTAB, CELL_VMCTX, CELL_VMAUX, CELL_VMLOCK, CELL_BUF, CELL_CONTROL, NCELLS };
typedef struct { const char *name; DWORD va, len; const char *what; } cell_t;
static const cell_t CELLS[NCELLS] = {
    { "bptab",   0x04D749FC, 0x20, "table of the four bp addresses fn 0x322D9C9 writes before its ud2" },
    { "vmctx",   0x04B697A0, 0x40, "VM context save area (cookie 0x26182aef, frame ptr, value from vmaux)" },
    { "vmaux",   0x04D74AE0, 0x20, "VM state cell around 0x04D74AEC" },
    { "vmlock",  0x04D74450, 0x10, "VM entry lock" },
    { "buf370",  0x04CEB370, 0x40, "buffer (esi) seen at the breakpoint" },
    { "control", 0x03F4DAC8, 0x10, "control, .rdata, should NEVER change" },
};
#define CELL_MAXLEN   0x40
#define CELL_LOG_CAP  20000            /* log lines per cell, then "capped" */

/* the four breakpoint addresses fn 0x322D9C9 writes into bptab on the Mac */
static const DWORD BP_ADDRS[4] = { 0x0322DA26, 0x0322DA3E, 0x0322DA5C, 0x0322DA74 };

typedef struct { const char *name; DWORD va, len; } codereg_t;
static const codereg_t CODEREGS[4] = {
    { "fn_322D9C9",   0x0322D000, 0x1000 },   /* the function with the ud2 at 0x322DA06 */
    { "handler_3233", 0x03233000, 0x1000 },   /* handler 0x32333D7 */
    { "vmentry_3402", 0x03402000, 0x1000 },   /* VM entry 0x3402A10 */
    { "gadgets_3413", 0x03413000, 0x1000 },   /* gadget table 0x3413A00 */
};

#define THREAD_PERIOD_S  0.25
#define THREAD_MAX_SAMPLES 2000
#define THREAD_MAX_TIDS  64

/* ------------------------------------------------------------- logging */

static FILE *g_log;
static LARGE_INTEGER g_freq, g_t0;
static char g_dir[MAX_PATH];        /* output folder */
static char g_bin[MAX_PATH];        /* folder holding the reference exes */

static double now_s(void)
{
    LARGE_INTEGER n;
    QueryPerformanceCounter(&n);
    return (double)(n.QuadPart - g_t0.QuadPart) / (double)g_freq.QuadPart;
}

static void say(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    if (g_log)
    {
        va_start(ap, fmt);
        vfprintf(g_log, fmt, ap);
        va_end(ap);
        fflush(g_log);
    }
    fflush(stdout);
}

static void path_in_dir(char *out, size_t n, const char *name)
{
    snprintf(out, n, "%s\\%s", g_dir, name);
}

static volatile LONG g_stop;

/* The thread sampler suspends a game thread for a few microseconds.  Whoever
 * gets the handle out of g_susp first (the sampler, or the Ctrl-C / console-close
 * handler below running on another thread) is the one that resumes it, exactly
 * once, so the thread can never be left suspended by this tool exiting. */
static HANDLE volatile g_susp;

static void release_suspended(void)
{
    HANDLE h = (HANDLE)InterlockedExchangePointer((PVOID volatile *)&g_susp, NULL);
    if (h) ResumeThread(h);
}

static BOOL WINAPI on_ctrl(DWORD t)
{
    (void)t;
    InterlockedExchange(&g_stop, 1);
    release_suspended();
    return TRUE;
}

/* -------------------------------------------------------------- SHA-256 */

typedef struct { DWORD h[8]; unsigned char buf[64]; ULONGLONG len; DWORD fill; } sha_t;
static const DWORD K256[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };
#define ROR(x,n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha_block(sha_t *s, const unsigned char *p)
{
    DWORD w[64], a, b, c, d, e, f, g, h, t1, t2;
    int i;

    for (i = 0; i < 16; i++)
        w[i] = (DWORD)p[4*i] << 24 | (DWORD)p[4*i+1] << 16 | (DWORD)p[4*i+2] << 8 | p[4*i+3];
    for (; i < 64; i++)
        w[i] = (ROR(w[i-2],17) ^ ROR(w[i-2],19) ^ (w[i-2] >> 10)) + w[i-7] +
               (ROR(w[i-15],7) ^ ROR(w[i-15],18) ^ (w[i-15] >> 3)) + w[i-16];
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3];
    e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
    for (i = 0; i < 64; i++)
    {
        t1 = h + (ROR(e,6) ^ ROR(e,11) ^ ROR(e,25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        t2 = (ROR(a,2) ^ ROR(a,13) ^ ROR(a,22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d;
    s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}

static void sha_init(sha_t *s)
{
    static const DWORD iv[8] = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                                 0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 };
    memcpy(s->h, iv, sizeof iv);
    s->len = 0; s->fill = 0;
}

static void sha_add(sha_t *s, const unsigned char *p, size_t n)
{
    s->len += n;
    while (n)
    {
        size_t k = 64 - s->fill;
        if (k > n) k = n;
        memcpy(s->buf + s->fill, p, k);
        s->fill += (DWORD)k; p += k; n -= k;
        if (s->fill == 64) { sha_block(s, s->buf); s->fill = 0; }
    }
}

static void sha_hex(sha_t *s, char out[65])
{
    ULONGLONG bits = s->len * 8;
    unsigned char pad = 0x80, z = 0, lenb[8];
    int i;

    sha_add(s, &pad, 1);
    while (s->fill != 56) sha_add(s, &z, 1);
    for (i = 0; i < 8; i++) lenb[i] = (unsigned char)(bits >> (56 - 8 * i));
    sha_add(s, lenb, 8);
    for (i = 0; i < 8; i++) sprintf(out + 8 * i, "%08lx", (unsigned long)s->h[i]);
}

static int sha_file(const char *path, char out[65])
{
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    static unsigned char buf[1 << 20];
    sha_t s;
    DWORD n;

    if (h == INVALID_HANDLE_VALUE) return 0;
    sha_init(&s);
    while (ReadFile(h, buf, sizeof buf, &n, NULL) && n) sha_add(&s, buf, n);
    CloseHandle(h);
    sha_hex(&s, out);
    return 1;
}

/* ------------------------------------------------------- PE on disk */

typedef struct { char name[9]; DWORD va, vsize, rawptr, rawsize, chars; } sec_t;
typedef struct
{
    int ok;
    DWORD image_base, size_of_image, dll_chars, stamp, nsec;
    sec_t sec[24];
} pe_t;

static int pe_load(const char *path, pe_t *pe)
{
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    unsigned char hdr[4096];
    DWORD n, e, i;

    memset(pe, 0, sizeof *pe);
    if (h == INVALID_HANDLE_VALUE) return 0;
    if (!ReadFile(h, hdr, sizeof hdr, &n, NULL) || n < 0x200) { CloseHandle(h); return 0; }
    CloseHandle(h);
    e = *(DWORD *)(hdr + 0x3c);
    if (e + 0x108 > n || memcmp(hdr + e, "PE\0\0", 4)) return 0;
    pe->nsec = *(WORD *)(hdr + e + 6);
    if (pe->nsec > 24) pe->nsec = 24;
    pe->stamp = *(DWORD *)(hdr + e + 8);
    {
        DWORD opt = e + 24, optsz = *(WORD *)(hdr + e + 20);
        pe->image_base = *(DWORD *)(hdr + opt + 28);
        pe->size_of_image = *(DWORD *)(hdr + opt + 56);
        pe->dll_chars = *(WORD *)(hdr + opt + 70);
        for (i = 0; i < pe->nsec; i++)
        {
            const unsigned char *s = hdr + opt + optsz + 40 * i;
            if (opt + optsz + 40 * (i + 1) > n) { pe->nsec = i; break; }
            memcpy(pe->sec[i].name, s, 8);
            pe->sec[i].name[8] = 0;
            pe->sec[i].vsize   = *(DWORD *)(s + 8);
            pe->sec[i].va      = *(DWORD *)(s + 12);
            pe->sec[i].rawsize = *(DWORD *)(s + 16);
            pe->sec[i].rawptr  = *(DWORD *)(s + 20);
            pe->sec[i].chars   = *(DWORD *)(s + 36);
        }
    }
    pe->ok = 1;
    return 1;
}

static const sec_t *pe_section_of(const pe_t *pe, DWORD rva)
{
    DWORD i;
    for (i = 0; i < pe->nsec; i++)
    {
        DWORD sz = pe->sec[i].vsize > pe->sec[i].rawsize ? pe->sec[i].vsize : pe->sec[i].rawsize;
        if (rva >= pe->sec[i].va && rva < pe->sec[i].va + sz) return &pe->sec[i];
    }
    return NULL;
}

/* bytes the FILE holds at rva (zeros past the raw data: demand-zero) */
static int pe_file_bytes(const char *path, const pe_t *pe, DWORD rva, unsigned char *out, int n)
{
    const sec_t *s = pe_section_of(pe, rva);
    HANDLE h;
    DWORD got = 0, off;

    memset(out, 0, n);
    if (!s) return 0;
    off = rva - s->va;
    if (off >= s->rawsize) return 1;                   /* demand-zero */
    h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    SetFilePointer(h, (LONG)(s->rawptr + off), NULL, FILE_BEGIN);
    ReadFile(h, out, n, &got, NULL);
    CloseHandle(h);
    return 1;
}

/* ------------------------------------------------------- memory naming */

static const char *prot_name(DWORD p)
{
    switch (p & 0xff)
    {
    case 0x01: return "NA";   case 0x02: return "R";    case 0x04: return "RW";
    case 0x08: return "WC";   case 0x10: return "X";    case 0x20: return "RX";
    case 0x40: return "RWX";  case 0x80: return "WCX";  case 0: return "-";
    }
    return "?";
}
static int prot_writable(DWORD p) { return (p & 0xcc) != 0; }   /* RW, WC, RWX, WCX */

static const char *type_name(DWORD t)
{
    switch (t) { case 0x1000000: return "IMAGE"; case 0x40000: return "MAPPED";
                 case 0x20000: return "PRIVATE"; case 0: return "-"; }
    return "?";
}

static void describe(const MEMORY_BASIC_INFORMATION *m, char *out, size_t n)
{
    if (m->State == MEM_FREE) snprintf(out, n, "free");
    else if (m->State == MEM_RESERVE) snprintf(out, n, "reserved/%s", type_name(m->Type));
    else snprintf(out, n, "%s/%s", prot_name(m->Protect), type_name(m->Type));
}

/* ------------------------------------------------------ process helpers */

static DWORD find_pid(const char *name, DWORD *ppid)
{
    PROCESSENTRY32 pe;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    DWORD pid = 0;

    if (snap == INVALID_HANDLE_VALUE) return 0;
    pe.dwSize = sizeof pe;
    if (Process32First(snap, &pe))
        do
            if (!lstrcmpiA(pe.szExeFile, name)) { pid = pe.th32ProcessID; if (ppid) *ppid = pe.th32ParentProcessID; break; }
        while (Process32Next(snap, &pe));
    CloseHandle(snap);
    return pid;
}

static double cpu_seconds(HANDLE p)
{
    FILETIME c, e, k, u;
    if (!GetProcessTimes(p, &c, &e, &k, &u)) return -1;
    return (((ULONGLONG)k.dwHighDateTime << 32 | k.dwLowDateTime) +
            ((ULONGLONG)u.dwHighDateTime << 32 | u.dwLowDateTime)) / 1e7;
}

static double age_seconds(HANDLE p)           /* time since the process was created */
{
    FILETIME c, e, k, u, nowft;
    ULONGLONG a, b;
    if (!GetProcessTimes(p, &c, &e, &k, &u)) return -1;
    GetSystemTimeAsFileTime(&nowft);
    a = (ULONGLONG)c.dwHighDateTime << 32 | c.dwLowDateTime;
    b = (ULONGLONG)nowft.dwHighDateTime << 32 | nowft.dwLowDateTime;
    return b > a ? (b - a) / 1e7 : 0;
}

/* ------------------------------------------------------- 1. system info */

static int g_wine, g_admin;

static void system_info(void)
{
    typedef LONG (WINAPI *rtlver_t)(OSVERSIONINFOW *);
    HMODULE nt = GetModuleHandleA("ntdll.dll");
    rtlver_t rv = nt ? (rtlver_t)GetProcAddress(nt, "RtlGetVersion") : NULL;
    OSVERSIONINFOW v;
    BOOL wow = FALSE, member = FALSE;
    SID_IDENTIFIER_AUTHORITY nta = { SECURITY_NT_AUTHORITY };
    PSID admins = NULL;
    SYSTEM_INFO si;
    char comp[64] = "?";
    DWORD cn = sizeof comp;
    typedef BOOL (WINAPI *w64_t)(HANDLE, PBOOL);
    w64_t w64 = (w64_t)GetProcAddress(GetModuleHandleA("kernel32.dll"), "IsWow64Process");

    memset(&v, 0, sizeof v);
    v.dwOSVersionInfoSize = sizeof v;
    if (rv) rv(&v);
    if (w64) w64(GetCurrentProcess(), &wow);
    if (AllocateAndInitializeSid(&nta, 2, SECURITY_BUILTIN_DOMAIN_RID, DOMAIN_ALIAS_RID_ADMINS,
                                 0, 0, 0, 0, 0, 0, &admins))
    {
        CheckTokenMembership(NULL, admins, &member);
        FreeSid(admins);
    }
    g_admin = member;
    g_wine = nt && GetProcAddress(nt, "wine_get_version") != NULL;
    GetNativeSystemInfo(&si);
    GetComputerNameA(comp, &cn);

    say("== system ==\n");
    say("computer        %s\n", comp);
    say("windows         %lu.%lu build %lu%s\n", (unsigned long)v.dwMajorVersion,
        (unsigned long)v.dwMinorVersion, (unsigned long)v.dwBuildNumber, g_wine ? "  (this is WINE, not Windows)" : "");
    say("cpu             %s%s\n", si.wProcessorArchitecture == 9 ? "x64" :
        si.wProcessorArchitecture == 12 ? "ARM64" : si.wProcessorArchitecture == 0 ? "x86" : "other",
        wow ? ", this tool runs under WOW64" : "");
    say("administrator   %s\n", g_admin ? "yes" : "NO -- opening the game may be refused; use RUN-ME.cmd");
    say("\n");
}

/* ------------------------------------------------ 2. the reference tests */

static void run_test(const char *exe, const char *args)
{
    char cmd[MAX_PATH * 2], outp[MAX_PATH], name[64];
    SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    HANDLE out;
    DWORD code = 0, w;
    double t = now_s();
    char *dot;

    snprintf(name, sizeof name, "%s", exe);
    if ((dot = strrchr(name, '.'))) *dot = 0;
    snprintf(outp, sizeof outp, "%s\\tests-%s.txt", g_dir, name);
    snprintf(cmd, sizeof cmd, "\"%s\\%s\"%s%s", g_bin, exe, args ? " " : "", args ? args : "");

    out = CreateFileA(outp, GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = si.hStdError = out;
    say("  %-16s ", exe);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, g_dir, &si, &pi))
    {
        say("cannot start (error %lu) -- is bin\\%s there?\n", (unsigned long)GetLastError(), exe);
        CloseHandle(out);
        return;
    }
    w = WaitForSingleObject(pi.hProcess, 60000);
    if (w == WAIT_TIMEOUT) { TerminateProcess(pi.hProcess, 99); code = 99; }
    else GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(out);

    /* show the interesting last line */
    {
        FILE *f = fopen(outp, "r");
        char line[512], keep[512] = "", last[512] = "";
        while (f && fgets(line, sizeof line, f))
        {
            line[strcspn(line, "\r\n")] = 0;
            if (!line[0]) continue;
            snprintf(last, sizeof last, "%s", line);
            if (strstr(line, "RESULT") || strstr(line, "/64") || strstr(line, "PASS") ||
                strstr(line, "passed") || strstr(line, "wrote"))
                snprintf(keep, sizeof keep, "%s", line);
        }
        if (f) fclose(f);
        if (code >= 0xC0000000u)
            say("CRASHED 0x%08lx %5.1fs  (last good line: %s)\n", (unsigned long)code, now_s() - t,
                keep[0] ? keep : last);
        else
            say("exit %-3lu %5.1fs  %s%s\n", (unsigned long)code, now_s() - t,
                w == WAIT_TIMEOUT ? "(timed out after 60 s) " : "", keep[0] ? keep : last);
    }
}

static void run_reference_tests(void)
{
    char probe_src[MAX_PATH], probe_dst[MAX_PATH];

    say("== reference tests (no game needed) ==\n");
    run_test("trapstorm.exe", NULL);
    run_test("wow32_probe.exe", NULL);
    run_test("drbp_test.exe", NULL);
    run_test("drbp_test32.exe", NULL);

    /* wow32_probe writes wow32_probe.txt beside itself: bring it into the folder */
    snprintf(probe_src, sizeof probe_src, "%s\\wow32_probe.txt", g_bin);
    snprintf(probe_dst, sizeof probe_dst, "%s\\wow32_probe.txt", g_dir);
    if (MoveFileExA(probe_src, probe_dst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED))
        say("  wow32_probe.txt collected\n");
    say("\n");
}

/* ------------------------------------- full dumps of another process */

static void dump_map(HANDLE p, const char *label)
{
    char path[MAX_PATH];
    FILE *f;
    unsigned char *a = NULL;

    snprintf(path, sizeof path, "%s\\map-%s.txt", g_dir, label);
    f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "       base        size  state   prot type      (state 1000 commit, 2000 reserve; "
               "prot 2 R, 4 RW, 8 WC, 20 RX, 40 RWX; type 1000000 IMAGE, 20000 PRIVATE)\n");
    for (;;)
    {
        MEMORY_BASIC_INFORMATION m;
        if (!VirtualQueryEx(p, a, &m, sizeof m)) break;
        if (m.State != MEM_FREE)
            fprintf(f, "%10p %10lx %6lx %6lx %7lx  %s/%s\n", m.BaseAddress, (unsigned long)m.RegionSize,
                    (unsigned long)m.State, (unsigned long)m.Protect, (unsigned long)m.Type,
                    prot_name(m.Protect), type_name(m.Type));
        a = (unsigned char *)m.BaseAddress + m.RegionSize;
        if (a < (unsigned char *)m.BaseAddress) break;
    }
    fclose(f);
}

static void dump_mods(HANDLE p, const char *label)
{
    char path[MAX_PATH];
    FILE *f;
    HMODULE mods[1024];
    DWORD needed = 0, i;

    snprintf(path, sizeof path, "%s\\mods-%s.txt", g_dir, label);
    f = fopen(path, "w");
    if (!f) return;
    if (!EnumProcessModulesEx(p, mods, sizeof mods, &needed, LIST_MODULES_ALL))
        fprintf(f, "EnumProcessModulesEx failed, error %lu\n", (unsigned long)GetLastError());
    else
        for (i = 0; i < needed / sizeof mods[0] && i < 1024; i++)
        {
            char mp[MAX_PATH] = "";
            GetModuleFileNameExA(p, mods[i], mp, sizeof mp);
            fprintf(f, "%p  %s\n", (void *)mods[i], mp);
        }
    fclose(f);
}

static void dump_all(HANDLE p, const char *label)
{
    dump_map(p, label);
    dump_mods(p, label);
}

/* --------------------------------- per-section audit of the live image */

/* "name=R/IMAGE .data=WC/IMAGE(0xAB000)+RW/PRIVATE(..)" -- one token per run of
 * equal protection/type inside the section's address range */
static void audit(HANDLE p, const pe_t *pe, char *out, size_t n)
{
    DWORD i;
    out[0] = 0;
    for (i = 0; i < pe->nsec; i++)
    {
        const sec_t *s = &pe->sec[i];
        DWORD sz = s->vsize > s->rawsize ? s->vsize : s->rawsize;
        ULONG_PTR a = pe->image_base + s->va, end = a + ((sz + 0xfff) & ~0xfffu);
        char tok[512];
        size_t used = 0, len = strlen(out);
        DWORD runs = 0;
        DWORD lp = ~0u, lt = ~0u, ls = ~0u;
        ULONG_PTR runbase = 0;

        used += snprintf(tok, sizeof tok, " %s=", s->name);
        while (a < end)
        {
            MEMORY_BASIC_INFORMATION m;
            ULONG_PTR rend;
            if (!VirtualQueryEx(p, (void *)a, &m, sizeof m)) { used += snprintf(tok + used, sizeof tok - used, "?"); break; }
            rend = (ULONG_PTR)m.BaseAddress + m.RegionSize;
            if (rend > end) rend = end;
            if (m.Protect != lp || m.Type != lt || m.State != ls)
            {
                if (runs < 4 && used < sizeof tok - 40)
                    used += snprintf(tok + used, sizeof tok - used, "%s%s/%s@%lx", runs ? "," : "",
                                     m.State == MEM_COMMIT ? prot_name(m.Protect) : "resv", type_name(m.Type),
                                     (unsigned long)(a - pe->image_base - s->va));
                runs++;
                lp = m.Protect; lt = m.Type; ls = m.State; runbase = a;
            }
            a = rend;
        }
        (void)runbase;
        if (runs > 4 && used < sizeof tok - 20) snprintf(tok + used, sizeof tok - used, ",+%lu", (unsigned long)(runs - 4));
        if (len + strlen(tok) < n) strcat(out, tok);
    }
}

/* Raw copy of one section of the live image (only .data is used: the state the
 * protector reads, not code).  Read-only; compared offline between machines. */
static void snap_section(HANDLE p, const pe_t *pe, const char *secname, const char *label)
{
    DWORD i;
    for (i = 0; i < pe->nsec; i++)
        if (!strcmp(pe->sec[i].name, secname))
        {
            const sec_t *s = &pe->sec[i];
            DWORD n = s->rawsize < s->vsize ? s->rawsize : s->vsize, off = 0;
            unsigned char *buf = (unsigned char *)malloc(n);
            char path[MAX_PATH];
            FILE *f;
            SIZE_T got;
            double t0 = now_s();

            if (!buf) return;
            memset(buf, 0, n);
            while (off < n)
            {
                DWORD chunk = n - off > 0x10000 ? 0x10000 : n - off;
                if (!ReadProcessMemory(p, (void *)(ULONG_PTR)(pe->image_base + s->va + off), buf + off, chunk, &got))
                    got = 0;
                off += chunk;     /* an unreadable chunk stays zero */
            }
            snprintf(path, sizeof path, "%s\\snap-%s%s.bin", g_dir, label, secname);
            if ((f = fopen(path, "wb"))) { fwrite(buf, 1, n, f); fclose(f); }
            say("[%7.3f s] SNAP    %s %lu bytes -> %s (%.0f ms)\n", now_s(), secname,
                (unsigned long)n, path + strlen(g_dir) + 1, (now_s() - t0) * 1000);
            free(buf);
            return;
        }
}

static void unread_note(FILE *sf, ULONG_PTR *rs, DWORD *rl, ULONG_PTR addr, int bad)
{
    if (bad && *rl && *rs + *rl == addr) { *rl += 0x1000; return; }
    if (*rl && sf)
        fprintf(sf, "  0x%08lx - 0x%08lx  (%lu pages)\n", (unsigned long)*rs,
                (unsigned long)(*rs + *rl - 1), (unsigned long)(*rl / 0x1000));
    *rl = 0;
    if (bad) { *rs = addr; *rl = 0x1000; }
}

/* kit v4: the whole VIRTUAL extent of a section (SizeOfRawData part plus the
 * demand-zero tail), streamed 64 KB at a time.  A chunk that cannot be read as
 * a whole is retried page by page; an unreadable page stays zero and is listed
 * in the sidecar snap-<t>-<sec>-full.unreadable.txt.  Failed reads are silent. */
static void snap_section_full(HANDLE p, const pe_t *pe, const char *secname, const char *label)
{
    static unsigned char buf[0x10000];
    DWORD i;

    for (i = 0; i < pe->nsec; i++)
        if (!strcmp(pe->sec[i].name, secname))
        {
            const sec_t *s = &pe->sec[i];
            DWORD vs = s->vsize ? s->vsize : s->rawsize;
            DWORD n = (vs + 0xfff) & ~0xfffu, off, bad_pages = 0;
            ULONG_PTR base = pe->image_base + s->va, rs = 0;
            DWORD rl = 0;
            char path[MAX_PATH], side[MAX_PATH];
            FILE *f, *sf;
            double t0 = now_s();

            snprintf(path, sizeof path, "%s\\snap-%s%s-full.bin", g_dir, label, secname);
            snprintf(side, sizeof side, "%s\\snap-%s%s-full.unreadable.txt", g_dir, label, secname);
            f = fopen(path, "wb");
            if (!f) { say("[%7.3f s] SNAPFULL cannot create %s\n", now_s(), path); return; }
            sf = fopen(side, "w");
            if (sf)
                fprintf(sf, "%s snapshot %s%s: VA 0x%08lx .. 0x%08lx (%lu bytes; VirtualSize 0x%lx, SizeOfRawData 0x%lx)\n"
                            "pages that could not be read (left as zero in the .bin):\n",
                        KIT_VERSION, label, secname, (unsigned long)base, (unsigned long)(base + n - 1),
                        (unsigned long)n, (unsigned long)s->vsize, (unsigned long)s->rawsize);
            for (off = 0; off < n; off += 0x10000)
            {
                DWORD chunk = n - off > 0x10000 ? 0x10000 : n - off, pg;
                SIZE_T got = 0;
                if (ReadProcessMemory(p, (void *)(base + off), buf, chunk, &got) && got == chunk)
                    unread_note(sf, &rs, &rl, 0, 0);
                else
                {
                    memset(buf, 0, chunk);
                    for (pg = 0; pg < chunk; pg += 0x1000)
                    {
                        got = 0;
                        if (ReadProcessMemory(p, (void *)(base + off + pg), buf + pg, 0x1000, &got) && got == 0x1000)
                            unread_note(sf, &rs, &rl, 0, 0);
                        else
                        {
                            memset(buf + pg, 0, 0x1000);
                            bad_pages++;
                            unread_note(sf, &rs, &rl, base + off + pg, 1);
                        }
                    }
                }
                fwrite(buf, 1, chunk, f);
            }
            unread_note(sf, &rs, &rl, 0, 0);
            if (sf)
            {
                if (!bad_pages) fprintf(sf, "  none\n");
                fclose(sf);
            }
            fclose(f);
            say("[%7.3f s] SNAPFULL %s %lu bytes, %lu unreadable pages -> %s (%.0f ms)\n", now_s(), secname,
                (unsigned long)n, (unsigned long)bad_pages, path + strlen(g_dir) + 1, (now_s() - t0) * 1000);
            return;
        }
}

/* kit v4: the unpacked protector code pages, as bytes, for Mac-vs-Windows diffs */
static void dump_code(HANDLE p, const char *label)
{
    static unsigned char buf[0x10000];
    int r;

    for (r = 0; r < (int)(sizeof CODEREGS / sizeof CODEREGS[0]); r++)
    {
        DWORD len = CODEREGS[r].len > sizeof buf ? (DWORD)sizeof buf : CODEREGS[r].len, off, ok = 0;
        char path[MAX_PATH];
        FILE *f;

        memset(buf, 0, sizeof buf);
        for (off = 0; off < len; off += 0x1000)
        {
            SIZE_T got = 0;
            DWORD part = len - off > 0x1000 ? 0x1000 : len - off;
            if (ReadProcessMemory(p, (void *)(ULONG_PTR)(CODEREGS[r].va + off), buf + off, part, &got) && got == part)
                ok += part;
            else
                memset(buf + off, 0, part);
        }
        if (!ok)
        {
            say("[%7.3f s] CODE    %-13s %08lx not readable at %s\n", now_s(), CODEREGS[r].name,
                (unsigned long)CODEREGS[r].va, label);
            continue;
        }
        snprintf(path, sizeof path, "%s\\code-%s-%08lx.bin", g_dir, label, (unsigned long)CODEREGS[r].va);
        if ((f = fopen(path, "wb"))) { fwrite(buf, 1, len, f); fclose(f); }
        say("[%7.3f s] CODE    %-13s %08lx %lu/%lu bytes readable -> %s\n", now_s(), CODEREGS[r].name,
            (unsigned long)CODEREGS[r].va, (unsigned long)ok, (unsigned long)len, path + strlen(g_dir) + 1);
    }
}

/* ------------------------------------------------------ the watch */

typedef struct
{
    int have, capped;
    double t_first;
    DWORD changes, lines;
    unsigned char last[CELL_MAXLEN];
} cellst_t;

typedef struct
{
    int found, opened, exited_early;
    DWORD pid, ppid, loader_pid;
    double age_at_first;             /* seconds the process had existed at the first sample */
    double watched_s;
    char path[MAX_PATH];
    pe_t pe;
    DWORD va, rva;
    const sec_t *sec;
    unsigned char file_bytes[16], first_bytes[16];
    int first_state_seen, first_matches_file, bytes_ever_differ, ever_writable, ever_private;
    int never_mapped, first_prot_known;
    DWORD first_prot, first_type, first_state;
    double t_first_write, t_first_bytes, t_menu;
    int prot_changes, byte_changes;
    char first_desc[96];
    char final_desc[96];
    double cpu_total;
    int sec_changes;
    /* kit v4: cells */
    FILE *cells;
    cellst_t cs[NCELLS];
    int bp_seen[4];
    double t_bp_any, t_bp_all, t_bp_exact;     /* 0 = never */
    DWORD bp_any_val, bp_any_at;
    /* kit v4: thread samples */
    FILE *thr;
    int thr_mode;                  /* 0 off, 1 main thread only, 2 all threads */
    const char *thr_why_off;
    DWORD main_tid;
    int thr_samples, thr_fail, thr_fail_run, thr_capped;
    int dr7_hits;
    double t_dr7;
    DWORD dr7_tid, dr7_dr[4], dr7_val;
} watch_t;

static void print_pe(const watch_t *w)
{
    DWORD i;
    say("  image base %08lx size %08lx  DllCharacteristics %04lx (%s)  stamp %08lx\n",
        (unsigned long)w->pe.image_base, (unsigned long)w->pe.size_of_image,
        (unsigned long)w->pe.dll_chars, (w->pe.dll_chars & 0x40) ? "ASLR possible" : "fixed base, no ASLR",
        (unsigned long)w->pe.stamp);
    for (i = 0; i < w->pe.nsec; i++)
    {
        const sec_t *s = &w->pe.sec[i];
        say("  %-8s rva %08lx vsize %08lx raw %08lx  chars %08lx %s%s%s%s\n", s->name,
            (unsigned long)s->va, (unsigned long)s->vsize, (unsigned long)s->rawsize,
            (unsigned long)s->chars,
            (s->chars & 0x40000000) ? "R" : "-", (s->chars & 0x80000000) ? "W" : "-",
            (s->chars & 0x20000000) ? "X" : "-", s->rawsize < s->vsize ? "  (demand-zero tail)" : "");
    }
}

/* kit v4: check every address of the tables against the live PE headers */
static void validate_one(const watch_t *w, const char *kind, const char *name, DWORD va, DWORD len)
{
    DWORD last = va + (len ? len - 1 : 0);
    const sec_t *a, *b;

    a = va >= w->pe.image_base ? pe_section_of(&w->pe, va - w->pe.image_base) : NULL;
    b = last >= w->pe.image_base ? pe_section_of(&w->pe, last - w->pe.image_base) : NULL;
    if (a && b && a == b)
        say("  %-5s %-13s %08lx len %-4lx in %s\n", kind, name, (unsigned long)va, (unsigned long)len, a->name);
    else if (a && b)
        say("  %-5s %-13s %08lx len %-4lx spans %s..%s\n", kind, name, (unsigned long)va, (unsigned long)len, a->name, b->name);
    else
        say("  *** WARNING: %s %s %08lx len %lx is NOT inside any section of the image (base %08lx); "
            "reads will fail quietly and be retried ***\n", kind, name, (unsigned long)va, (unsigned long)len,
            (unsigned long)w->pe.image_base);
}

static void validate_addrs(const watch_t *w)
{
    int i;
    say("== v4 addresses checked against the image ==\n");
    for (i = 0; i < NCELLS; i++) validate_one(w, "cell", CELLS[i].name, CELLS[i].va, CELLS[i].len);
    for (i = 0; i < (int)(sizeof CODEREGS / sizeof CODEREGS[0]); i++)
        validate_one(w, "code", CODEREGS[i].name, CODEREGS[i].va, CODEREGS[i].len);
    for (i = 0; i < 4; i++) validate_one(w, "bpval", "bp-address", BP_ADDRS[i], 4);
    say("\n");
}

/* kit v4: poll the watch cells; log a line when the bytes change.  A read that
 * fails (not committed yet) is silent and simply retried on the next loop. */
static void cells_poll(HANDLE p, watch_t *w, double t)
{
    int k, j;

    for (k = 0; k < NCELLS; k++)
    {
        unsigned char buf[CELL_MAXLEN];
        cellst_t *c = &w->cs[k];
        DWORD len = CELLS[k].len, d[CELL_MAXLEN / 4];
        SIZE_T got = 0;
        int first = !c->have;

        if (!ReadProcessMemory(p, (void *)(ULONG_PTR)CELLS[k].va, buf, len, &got) || got != len) continue;
        if (!first && !memcmp(buf, c->last, len)) continue;
        if (first) c->t_first = t; else c->changes++;
        c->have = 1;
        memcpy(c->last, buf, len);
        memcpy(d, buf, len);

        if (c->lines < CELL_LOG_CAP && w->cells)
        {
            fprintf(w->cells, "[%7.3f s] %-7s %08lx %s", t, CELLS[k].name, (unsigned long)CELLS[k].va,
                    first ? "FIRST-READABLE" : "chg");
            for (j = 0; j < (int)(len / 4); j++) fprintf(w->cells, " %08lx", (unsigned long)d[j]);
            fputc('\n', w->cells);
            if (++c->lines == CELL_LOG_CAP)
            { fprintf(w->cells, "[%7.3f s] %-7s capped at %d lines, further changes only counted\n", t, CELLS[k].name, CELL_LOG_CAP); c->capped = 1; }
            fflush(w->cells);
        }
        if (first)
            say("[%7.3f s] CELL    %s (%08lx) readable\n", t, CELLS[k].name, (unsigned long)CELLS[k].va);

        if (k == CELL_BPTAB)
        {
            int b, all = 1;
            for (j = 0; j < (int)(len / 4); j++)
                for (b = 0; b < 4; b++)
                    if (d[j] == BP_ADDRS[b])
                    {
                        w->bp_seen[b] = 1;
                        if (w->t_bp_any == 0)
                        {
                            w->t_bp_any = t; w->bp_any_val = d[j]; w->bp_any_at = CELLS[k].va + 4 * j;
                            say("[%7.3f s] BPTAB   bp address %08lx appeared at %08lx -- fn 0x322D9C9 ran here\n", t,
                                (unsigned long)d[j], (unsigned long)(CELLS[k].va + 4 * j));
                        }
                    }
            for (b = 0; b < 4; b++) if (!w->bp_seen[b]) all = 0;
            if (all && w->t_bp_all == 0) w->t_bp_all = t;
            if (w->t_bp_exact == 0 && d[0] == BP_ADDRS[0] && d[1] == BP_ADDRS[1] &&
                d[2] == BP_ADDRS[2] && d[3] == BP_ADDRS[3])
                w->t_bp_exact = t;
        }
    }
}

/* ------------------------------------------- kit v4: thread samples */

static int enum_threads(DWORD pid, DWORD *tids, int max)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te;
    int n = 0;

    if (snap == INVALID_HANDLE_VALUE) return 0;
    te.dwSize = sizeof te;
    if (Thread32First(snap, &te))
        do
            if (te.th32OwnerProcessID == pid && n < max) tids[n++] = te.th32ThreadID;
        while (Thread32Next(snap, &te));
    CloseHandle(snap);
    return n;
}

#ifndef THREAD_QUERY_LIMITED_INFORMATION
#define THREAD_QUERY_LIMITED_INFORMATION 0x0800
#endif

/* the thread with the earliest creation time = the main thread */
static DWORD first_created_thread(DWORD pid)
{
    DWORD tids[THREAD_MAX_TIDS], best = 0;
    ULONGLONG best_t = ~0ULL;
    int n = enum_threads(pid, tids, THREAD_MAX_TIDS), i;

    for (i = 0; i < n; i++)
    {
        HANDLE h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, tids[i]);
        FILETIME c, e, k, u;
        if (!h) continue;
        if (GetThreadTimes(h, &c, &e, &k, &u))
        {
            ULONGLONG ct = (ULONGLONG)c.dwHighDateTime << 32 | c.dwLowDateTime;
            if (ct < best_t) { best_t = ct; best = tids[i]; }
        }
        CloseHandle(h);
    }
    return best;
}

/* One sample of one thread.  Read-only: Suspend, GetThreadContext, Resume,
 * with the resume guaranteed on every path (g_susp, see on_ctrl).  Returns 1
 * if registers were read. */
static int thread_sample_one(watch_t *w, DWORD tid, double t)
{
    HANDLE th = OpenThread(THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION | THREAD_SUSPEND_RESUME, FALSE, tid);
    CONTEXT c;
    DWORD sc, err = 0;
    BOOL got;

    if (!th)
    {
        if (w->thr_fail++ < 10 && w->thr)
            fprintf(w->thr, "[%7.3f s] tid %lu OpenThread failed, error %lu\n", t, (unsigned long)tid, (unsigned long)GetLastError());
        return 0;
    }
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_FULL | CONTEXT_DEBUG_REGISTERS;
    sc = SuspendThread(th);
    if (sc == (DWORD)-1)
    {
        err = GetLastError();
        CloseHandle(th);
        if (w->thr_fail++ < 10 && w->thr)
            fprintf(w->thr, "[%7.3f s] tid %lu SuspendThread failed, error %lu\n", t, (unsigned long)tid, (unsigned long)err);
        return 0;
    }
    InterlockedExchangePointer((PVOID volatile *)&g_susp, th);   /* from here the handler can also resume it */
    got = GetThreadContext(th, &c);
    if (!got) err = GetLastError();
    release_suspended();                                         /* resume NOW, before any printing */
    CloseHandle(th);

    if (!got)
    {
        if (w->thr_fail++ < 10 && w->thr)
            fprintf(w->thr, "[%7.3f s] tid %lu GetThreadContext failed, error %lu\n", t, (unsigned long)tid, (unsigned long)err);
        return 0;
    }
    if (w->thr)
    {
        fprintf(w->thr, "[%7.3f s] tid %lu eip=%08lx esp=%08lx ebp=%08lx edi=%08lx esi=%08lx eax=%08lx efl=%08lx "
                        "dr0=%08lx dr1=%08lx dr2=%08lx dr3=%08lx dr6=%08lx dr7=%08lx\n",
                t, (unsigned long)tid, (unsigned long)c.Eip, (unsigned long)c.Esp, (unsigned long)c.Ebp,
                (unsigned long)c.Edi, (unsigned long)c.Esi, (unsigned long)c.Eax, (unsigned long)c.EFlags,
                (unsigned long)c.Dr0, (unsigned long)c.Dr1, (unsigned long)c.Dr2, (unsigned long)c.Dr3,
                (unsigned long)c.Dr6, (unsigned long)c.Dr7);
        fflush(w->thr);
    }
    if (c.Dr7)
    {
        if (!w->dr7_hits)
        {
            w->t_dr7 = t; w->dr7_tid = tid; w->dr7_val = c.Dr7;
            w->dr7_dr[0] = c.Dr0; w->dr7_dr[1] = c.Dr1; w->dr7_dr[2] = c.Dr2; w->dr7_dr[3] = c.Dr3;
            say("[%7.3f s] THREAD  tid %lu has DR7=%08lx (dr0-3 %08lx %08lx %08lx %08lx)\n", t, (unsigned long)tid,
                (unsigned long)c.Dr7, (unsigned long)c.Dr0, (unsigned long)c.Dr1, (unsigned long)c.Dr2, (unsigned long)c.Dr3);
        }
        w->dr7_hits++;
    }
    return 1;
}

static void thread_round(watch_t *w, double t)
{
    DWORD tids[THREAD_MAX_TIDS];
    int n = 0, i, ok = 0;

    if (!w->thr_mode) return;
    if (w->thr_samples >= THREAD_MAX_SAMPLES)
    {
        if (!w->thr_capped && w->thr)
        { w->thr_capped = 1; fprintf(w->thr, "[%7.3f s] capped at %d samples\n", t, THREAD_MAX_SAMPLES); fflush(w->thr); }
        return;
    }
    if (w->thr_mode == 1)
    {
        if (!w->main_tid)
        {
            w->main_tid = first_created_thread(w->pid);
            if (w->main_tid && w->thr)
            { fprintf(w->thr, "[%7.3f s] main thread = tid %lu (earliest creation time)\n", t, (unsigned long)w->main_tid); fflush(w->thr); }
        }
        if (!w->main_tid) return;
        tids[n++] = w->main_tid;
    }
    else
        n = enum_threads(w->pid, tids, THREAD_MAX_TIDS);

    for (i = 0; i < n && w->thr_samples < THREAD_MAX_SAMPLES; i++)
    {
        w->thr_samples++;
        if (thread_sample_one(w, tids[i], t)) ok = 1;
    }
    if (w->thr_mode == 1)
    {
        /* the main thread vanished or cannot be opened for a long while: look it up again */
        if (ok) w->thr_fail_run = 0;
        else if (++w->thr_fail_run >= 40) { w->thr_fail_run = 0; w->main_tid = 0; }
    }
}

static void wait_and_watch(watch_t *w, int seconds, int wait_seconds, const char *exe_name)
{
    HANDLE p = NULL;
    double t_wait0 = now_s(), t_open, t_next_alive = 0, t_loader_seen = -1;
    int dumped[4] = { 0, 0, 0, 0 }, snapped[4] = { 0, 0, 0, 0 };
    int snapped_full[7] = { 0 }, code_done[3] = { 0 };
    static const double full_at[7] = { 0.3, 1.0, 2.0, 3.0, 5.0, 8.0, 15.0 };
    static const char *full_label[7] = { "0.3s-", "1.0s-", "2.0s-", "3.0s-", "5.0s-", "8.0s-", "15.0s-" };
    static const double code_at[3] = { 2.0, 5.0, 15.0 };
    static const char *code_label[3] = { "2.0s", "5.0s", "15.0s" };
    double t_thr_next = 0;
    static const double snap_at[4] = { 0.3, 1.0, 3.0, 8.0 };
    static const char *snap_label[4] = { "0.3s-", "1.0s-", "3.0s-", "8.0s-" };
    static const double dump_at[4] = { 0, 2, 10, 30 };
    static const char *dump_label[4] = { "t0", "t2s", "t10s", "t30s" };
    char audit_now[2048], audit_prev[2048] = "", desc[96], desc_prev[96] = "";
    unsigned char bytes[16], prev[16];
    int have_prev = 0, kb_hint = 0;
    double last_cpu = 0, last_cpu_t = 0;
    DWORD ppid = 0;
    int polls = 0, sec_changes = 0;
    FILE *secfile = NULL;

    /* ---- wait for the process */
    say("== waiting for %s ==\n", exe_name);
    say("  Start the game NOW the normal way (3DM launcher -> Launch Game).\n");
    say("  When the game window is up and you see the menu, press ENTER in this window\n"
        "  (it only stamps the time).  Press Q to stop early.\n\n");
    while (!g_stop)
    {
        if (!w->loader_pid && (w->loader_pid = find_pid(LOADER_EXE, NULL)))
        {
            t_loader_seen = now_s();
            say("[%7.3f s] %s started, pid %lu\n", t_loader_seen, LOADER_EXE, (unsigned long)w->loader_pid);
        }
        if ((w->pid = find_pid(exe_name, &ppid))) break;
        if (_kbhit()) { int c = _getch(); if (c == 'q' || c == 'Q') g_stop = 1; }
        if (now_s() - t_wait0 > wait_seconds) break;
        if (now_s() - t_next_alive > 15) { t_next_alive = now_s(); say("[%7.3f s] still waiting for %s...\n", now_s(), exe_name); }
        Sleep(5);
    }
    if (!w->pid)
    {
        say("\nNo %s appeared. Nothing was measured.\n", exe_name);
        return;
    }
    w->found = 1;
    w->ppid = ppid;
    t_open = now_s();
    say("[%7.3f s] %s pid %lu appeared (parent pid %lu%s)\n", t_open, exe_name,
        (unsigned long)w->pid, (unsigned long)ppid,
        ppid == w->loader_pid && ppid ? " = the 3DM loader" : "");

    /* ---- open it (retry briefly: it may not be openable in the first instant) */
    {
        double t = now_s();
        while (!(p = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | SYNCHRONIZE, FALSE, w->pid)) &&
               now_s() - t < 20 && !g_stop)
        {
            if (GetLastError() == ERROR_ACCESS_DENIED && now_s() - t > 3) break;
            Sleep(2);
        }
    }
    if (!p)
    {
        say("CANNOT OPEN pid %lu (error %lu). Run RUN-ME.cmd again and accept the administrator\n"
            "prompt; EA's launcher can start the game with higher rights.\n",
            (unsigned long)w->pid, (unsigned long)GetLastError());
        return;
    }
    w->opened = 1;
    {
        DWORD n = sizeof w->path;
        typedef BOOL (WINAPI *qf_t)(HANDLE, DWORD, LPSTR, PDWORD);
        qf_t qf = (qf_t)GetProcAddress(GetModuleHandleA("kernel32.dll"), "QueryFullProcessImageNameA");
        if (!qf || !qf(p, 0, w->path, &n)) GetModuleFileNameExA(p, NULL, w->path, sizeof w->path);
    }
    say("  image path   %s\n", w->path);
    w->age_at_first = age_seconds(p);
    say("  process age  %.3f s at first look\n", w->age_at_first);

    if (!pe_load(w->path, &w->pe))
    {
        say("CANNOT READ the PE headers of %s\n", w->path);
        CloseHandle(p);
        return;
    }
    print_pe(w);
    validate_addrs(w);

    w->rva = w->va - w->pe.image_base;
    w->sec = pe_section_of(&w->pe, w->rva);
    pe_file_bytes(w->path, &w->pe, w->rva, w->file_bytes, 16);
    say("  watching     VA %08lx = image base + %08lx, in section %s\n", (unsigned long)w->va,
        (unsigned long)w->rva, w->sec ? w->sec->name : "(OUTSIDE THE IMAGE -- wrong address!)");
    if (w->sec && strcmp(w->sec->name, ".rdata"))
        say("  *** WARNING: the page the protector writes is in .rdata; this one is in %s ***\n", w->sec->name);
    say("  file holds   ");
    {
        int i;
        for (i = 0; i < 16; i++) say("%02x", w->file_bytes[i]);
        say("  (%.16s)\n\n", (char *)w->file_bytes);
    }

    /* ---- sample */
    say("== watching (a line appears only when something changes) ==\n");
    {
        char sp[MAX_PATH];
        path_in_dir(sp, sizeof sp, "sections.txt");
        secfile = fopen(sp, "w");
    }
    {
        char cp[MAX_PATH];
        path_in_dir(cp, sizeof cp, "cells.txt");
        w->cells = fopen(cp, "w");
        if (w->cells)
        {
            int k;
            fprintf(w->cells, "%s cells timeline (hex dwords, a line per change, first readable marked; cap %d lines per cell)\n",
                    KIT_VERSION, CELL_LOG_CAP);
            for (k = 0; k < NCELLS; k++)
                fprintf(w->cells, "# %-7s %08lx len %02lx  %s\n", CELLS[k].name, (unsigned long)CELLS[k].va,
                        (unsigned long)CELLS[k].len, CELLS[k].what);
            fflush(w->cells);
        }
        if (w->thr_mode)
        {
            path_in_dir(cp, sizeof cp, "threads.txt");
            w->thr = fopen(cp, "w");
            if (w->thr)
            {
                fprintf(w->thr, "%s thread samples every %.0f ms, %s, cap %d samples\n", KIT_VERSION,
                        THREAD_PERIOD_S * 1000, w->thr_mode == 1 ? "main (first-created) thread only" : "all threads",
                        THREAD_MAX_SAMPLES);
                fflush(w->thr);
            }
            say("  thread samples ON (%s, every %.0f ms; rerun with FIFA14CAP_NOTHREADS=1 or --nothreads to disable)\n\n",
                w->thr_mode == 1 ? "main thread" : "all threads", THREAD_PERIOD_S * 1000);
        }
        else
            say("  thread samples OFF (%s)\n\n", w->thr_why_off ? w->thr_why_off : "disabled");
    }
    t_open = now_s();
    for (;;)
    {
        MEMORY_BASIC_INFORMATION m;
        double t = now_s() - t_open, cpu, abs_t = now_s();
        int i;

        if (g_stop) { say("[%7.3f s] stopped by the user\n", t); break; }
        if (t > seconds) { say("[%7.3f s] watch time (%d s) used up\n", t, seconds); break; }
        if (WaitForSingleObject(p, 0) == WAIT_OBJECT_0)
        {
            DWORD code = 0;
            GetExitCodeProcess(p, &code);
            say("[%7.3f s] game process EXITED (code %lu)\n", t, (unsigned long)code);
            if (t < 5) w->exited_early = 1;
            break;
        }
        if (_kbhit())
        {
            int c = _getch();
            if (c == 'q' || c == 'Q') g_stop = 1;
            else if (c == '\r' || c == '\n')
            {
                w->t_menu = t;
                say("[%7.3f s] USER: pressed ENTER (= the menu is showing)\n", t);
            }
        }

        /* kit v4: cells (every loop) and the main thread's registers (every 250 ms) */
        cells_poll(p, w, t);
        if (w->thr_mode && t >= t_thr_next)
        {
            t_thr_next = t + THREAD_PERIOD_S;
            thread_round(w, t);
        }

        /* the watched page */
        memset(&m, 0, sizeof m);
        if (!VirtualQueryEx(p, (void *)(ULONG_PTR)w->va, &m, sizeof m)) snprintf(desc, sizeof desc, "unmapped");
        else describe(&m, desc, sizeof desc);
        memset(bytes, 0, sizeof bytes);
        if (m.State == MEM_COMMIT) ReadProcessMemory(p, (void *)(ULONG_PTR)w->va, bytes, sizeof bytes, NULL);
        polls++;

        if (!have_prev)
        {
            w->first_state = m.State; w->first_prot = m.Protect; w->first_type = m.Type;
            snprintf(w->first_desc, sizeof w->first_desc, "%s", desc);
            memcpy(w->first_bytes, bytes, 16);
            w->first_matches_file = !memcmp(bytes, w->file_bytes, 16);
            w->never_mapped = (m.State != MEM_COMMIT);
            say("[%7.3f s] FIRST   page %s  (state %lx protect %lx type %lx) bytes ", t, desc,
                (unsigned long)m.State, (unsigned long)m.Protect, (unsigned long)m.Type);
            for (i = 0; i < 16; i++) say("%02x", bytes[i]);
            say("  %s\n", m.State != MEM_COMMIT ? "" :
                w->first_matches_file ? "= the file" : "<> THE FILE (already changed)");
            w->prot_changes = 0;
        }
        else
        {
            if (strcmp(desc, desc_prev))
            {
                w->prot_changes++;
                say("[%7.3f s] PROT    page %s -> %s  (state %lx protect %lx type %lx)\n", t, desc_prev, desc,
                    (unsigned long)m.State, (unsigned long)m.Protect, (unsigned long)m.Type);
            }
            if (m.State == MEM_COMMIT && memcmp(bytes, prev, 16))
            {
                w->byte_changes++;
                if (w->t_first_bytes == 0) w->t_first_bytes = t;
                say("[%7.3f s] BYTES   ", t);
                for (i = 0; i < 16; i++) say("%02x", bytes[i]);
                say("   was ");
                for (i = 0; i < 16; i++) say("%02x", prev[i]);
                say("   %s\n", !memcmp(bytes, w->file_bytes, 16) ? "(= the file again)" : "(<> the file)");
            }
        }
        if (m.State == MEM_COMMIT && prot_writable(m.Protect) && !w->ever_writable)
        { w->ever_writable = 1; w->t_first_write = t; }
        if (m.State == MEM_COMMIT && m.Type == MEM_PRIVATE) w->ever_private = 1;
        if (m.State == MEM_COMMIT && memcmp(bytes, w->file_bytes, 16)) w->bytes_ever_differ = 1;
        snprintf(desc_prev, sizeof desc_prev, "%s", desc);
        snprintf(w->final_desc, sizeof w->final_desc, "%s", desc);
        memcpy(prev, bytes, 16);
        have_prev = 1;

        /* every section of the image */
        audit(p, &w->pe, audit_now, sizeof audit_now);
        if (strcmp(audit_now, audit_prev))
        {
            if (secfile) { fprintf(secfile, "[%7.3f s]%s\n", t, audit_now); fflush(secfile); }
            sec_changes++;
            if (sec_changes <= 12)
                say("[%7.3f s] SECTIONS%s\n", t, audit_now);
            else if (sec_changes == 13)
                say("[%7.3f s] SECTIONS keep changing (the game flips protections of its own pages);\n"
                    "             the screen stops listing them, every change is in sections.txt\n", t);
            snprintf(audit_prev, sizeof audit_prev, "%s", audit_now);
        }

        /* scheduled full dumps */
        for (i = 0; i < 4; i++)
            if (!dumped[i] && t >= dump_at[i]) { dumped[i] = 1; dump_all(p, dump_label[i]); }

        for (i = 0; i < 3; i++)
            if (!code_done[i] && t >= code_at[i]) { code_done[i] = 1; dump_code(p, code_label[i]); }

        for (i = 0; i < 4; i++)
            if (!snapped[i] && t >= snap_at[i]) { snapped[i] = 1; snap_section(p, &w->pe, ".data", snap_label[i]); }

        for (i = 0; i < 7; i++)
            if (!snapped_full[i] && t >= full_at[i]) { snapped_full[i] = 1; snap_section_full(p, &w->pe, ".data", full_label[i]); }

        /* heartbeat: is the game burning CPU (stuck) or idling (menu)? */
        if (abs_t - last_cpu_t >= 5)
        {
            PROCESS_MEMORY_COUNTERS pmc;
            cpu = cpu_seconds(p);
            memset(&pmc, 0, sizeof pmc);
            pmc.cb = sizeof pmc;
            GetProcessMemoryInfo(p, &pmc, sizeof pmc);
            say("[%7.3f s] alive   cpu %.0f%% of one core over the last %.0f s, %lu MB working set\n", t,
                last_cpu_t > 0 && cpu >= 0 ? 100.0 * (cpu - last_cpu) / (abs_t - last_cpu_t) : 0.0,
                last_cpu_t > 0 ? abs_t - last_cpu_t : 0.0, (unsigned long)(pmc.WorkingSetSize >> 20));
            last_cpu = cpu; last_cpu_t = abs_t;
            w->cpu_total = cpu;
            if (!kb_hint && t > 20) { kb_hint = 1; say("             (press ENTER when the menu shows, Q to finish)\n"); }
        }
        Sleep(2);
    }
    (void)last_cpu;
    w->watched_s = now_s() - t_open;
    w->sec_changes = sec_changes;
    if (secfile) fclose(secfile);
    release_suspended();                      /* no-op: a sample never spans a loop turn */
    if (w->cells) { fclose(w->cells); w->cells = NULL; }
    if (w->thr) { fclose(w->thr); w->thr = NULL; }
    say("  %d samples, %d protection changes, %d byte changes\n\n", polls, w->prot_changes, w->byte_changes);
    dump_all(p, "end");
    CloseHandle(p);
}

/* ------------------------------------------------ 7/8. hashes, verdict */

static void hash_game_files(const watch_t *w, FILE *sum)
{
    char dir[MAX_PATH], full[MAX_PATH], hex[65];
    size_t i;
    char *slash;
    int all_ok = 1;

    snprintf(dir, sizeof dir, "%s", w->path);
    slash = strrchr(dir, '\\');
    if (slash) *slash = 0;
    say("== game files (%s) ==\n", dir);
    if (sum) fprintf(sum, "game files in %s\n", dir);
    for (i = 0; i < sizeof KNOWN / sizeof KNOWN[0]; i++)
    {
        snprintf(full, sizeof full, "%s\\%s", dir, KNOWN[i].file);
        if (!sha_file(full, hex)) { say("  %-16s MISSING\n", KNOWN[i].file); all_ok = 0; continue; }
        say("  %-16s %s  %s\n", KNOWN[i].file, hex, strcmp(hex, KNOWN[i].sha) ? "DIFFERENT from the Mac files" : "identical to the Mac files");
        if (sum) fprintf(sum, "  %-16s %s  %s\n", KNOWN[i].file, hex, strcmp(hex, KNOWN[i].sha) ? "DIFFERENT" : "identical");
        if (strcmp(hex, KNOWN[i].sha)) all_ok = 0;
    }
    say("  %s\n\n", all_ok ? "all identical" : "NOT ALL IDENTICAL -- the conclusion 'same files' needs re-checking");
}

static void verdict(const watch_t *w, FILE *sum)
{
    char line[1024];
    const char *v;

    say("== verdict%s ==\n", g_wine ? " (this is WINE: a test of the tool)" : "");
    if (!w->found)
        v = "NOT MEASURED: fifa14.exe never appeared.";
    else if (!w->opened)
        v = "NOT MEASURED: the game process could not be opened (run as administrator).";
    else if (!w->sec)
        v = "NOT MEASURED: the watched address is outside the image of the running exe.";
    else if (w->never_mapped && !w->ever_writable)
        v = "INCONCLUSIVE: the page was never committed in the process during the watch.";
    else if (w->exited_early || w->watched_s < 5)
        v = "INCONCLUSIVE: the game ran for less than 5 s while watched.";
    else if (w->ever_private)
        v = "A: the page is MEM_PRIVATE here -- the image is not file-mapped on this machine.\n"
            "   The Wine side then needs how the image gets mapped: send map-t0.txt/mods-t0.txt.";
    else if (w->ever_writable || w->bytes_ever_differ)
        v = "B: the page IS made writable / the dword IS changed on this machine (see PROT/BYTES lines).\n"
            "   The time of the PROT line tells Process Monitor where to look; the before/after\n"
            "   dwords are new information.";
    else
        v = "C: the page stays READ-ONLY file-mapped IMAGE and its bytes never differ from the file.\n"
            "   On a machine that reaches the menu this means NO write lands there: the Mac loop is then\n"
            "   not 'Wine fails to make a page writable' -- either the protector reaches that write\n"
            "   only on the Mac (it took a different path earlier), or the access violation is an\n"
            "   intended trap whose handler moves on. Next: compare the exception record/context of that\n"
            "   fault (tests-trapstorm.txt is the Windows reference), not memory protections.\n"
            "   (On a machine that does NOT reach the menu this is simply the stuck state.)";

    snprintf(line, sizeof line, "%s", v);
    say("%s\n\n", line);
    if (sum) fprintf(sum, "VERDICT: %s\n", line);
}

static void write_summary(const watch_t *w, int menu_answer)
{
    char p[MAX_PATH];
    FILE *s;

    path_in_dir(p, sizeof p, "summary.txt");
    s = fopen(p, "w");
    if (!s) return;
    int k;

    fprintf(s, "%s -- FIFA 14 Windows capture -- summary (full transcript: capture.txt)\n\n", KIT_VERSION);
    fprintf(s, "watched VA          0x%08lx (image base + 0x%lx) in section %s\n", (unsigned long)w->va,
            (unsigned long)w->rva, w->sec ? w->sec->name : "OUTSIDE");
    fprintf(s, "game pid / parent   %lu / %lu%s\n", (unsigned long)w->pid, (unsigned long)w->ppid,
            w->ppid && w->ppid == w->loader_pid ? " (the 3DM loader)" : "");
    fprintf(s, "first look          %.3f s after the process was created\n", w->age_at_first);
    fprintf(s, "first state         %s\n", w->first_desc);
    fprintf(s, "final state         %s\n", w->final_desc);
    fprintf(s, "bytes vs file       first %s, ever different: %s\n",
            w->first_matches_file ? "equal" : "DIFFERENT", w->bytes_ever_differ ? "YES" : "no");
    fprintf(s, "ever writable       %s%s\n", w->ever_writable ? "YES at " : "no", "");
    if (w->ever_writable) fprintf(s, "                    t=%.3f s into the watch\n", w->t_first_write);
    fprintf(s, "ever MEM_PRIVATE    %s\n", w->ever_private ? "YES" : "no");
    fprintf(s, "reached the menu    %s\n", menu_answer ? "user pressed ENTER (menu showing)" : "not reported");
    fprintf(s, "section changes     %d (all in sections.txt)\n", w->sec_changes);
    fprintf(s, "watched for         %.1f s, cpu total %.1f s\n", w->watched_s, w->cpu_total);
    fprintf(s, "ran on              %s\n\n", g_wine ? "WINE (a test of this tool, not the Windows capture)" : "Windows");

    fprintf(s, "-- %s: cells (details in cells.txt) --\n", KIT_VERSION);
    for (k = 0; k < NCELLS; k++)
    {
        const cellst_t *c = &w->cs[k];
        if (c->have)
            fprintf(s, "cell %-7s %08lx first readable at %.3f s, %lu changes%s\n", CELLS[k].name,
                    (unsigned long)CELLS[k].va, c->t_first, (unsigned long)c->changes, c->capped ? " (log CAPPED)" : "");
        else
            fprintf(s, "cell %-7s %08lx NEVER readable (not committed or outside the image)\n", CELLS[k].name,
                    (unsigned long)CELLS[k].va);
    }
    if (w->cs[CELL_CONTROL].have && w->cs[CELL_CONTROL].changes)
        fprintf(s, "*** the control cell changed %lu times: the cell timeline is not trustworthy\n",
                (unsigned long)w->cs[CELL_CONTROL].changes);
    if (w->t_bp_any)
        fprintf(s, "bp-address table    SEEN: %08lx at %08lx, first at %.3f s; all four present %s; exact order %s\n"
                   "                    (fn 0x322D9C9 ran on this machine)\n",
                (unsigned long)w->bp_any_val, (unsigned long)w->bp_any_at, w->t_bp_any,
                w->t_bp_all ? "yes" : "NO", w->t_bp_exact ? "yes" : "NO");
    else
        fprintf(s, "bp-address table    never seen at %08lx (0x322DA26 0x322DA3E 0x322DA5C 0x322DA74)%s\n",
                (unsigned long)CELLS[CELL_BPTAB].va,
                w->cs[CELL_BPTAB].have ? "" : "  (the range was never readable either)");
    if (!w->thr_mode)
        fprintf(s, "thread samples     OFF (%s)\n", w->thr_why_off ? w->thr_why_off : "disabled");
    else
    {
        fprintf(s, "thread samples     %d taken (%s), %d failed attempts%s\n", w->thr_samples,
                w->thr_mode == 1 ? "main thread" : "all threads", w->thr_fail, w->thr_capped ? ", CAPPED" : "");
        if (w->dr7_hits)
            fprintf(s, "debug registers    DR7 nonzero in %d samples; first at %.3f s tid %lu: dr7=%08lx dr0=%08lx dr1=%08lx dr2=%08lx dr3=%08lx\n",
                    w->dr7_hits, w->t_dr7, (unsigned long)w->dr7_tid, (unsigned long)w->dr7_val,
                    (unsigned long)w->dr7_dr[0], (unsigned long)w->dr7_dr[1], (unsigned long)w->dr7_dr[2],
                    (unsigned long)w->dr7_dr[3]);
        else
            fprintf(s, "debug registers    DR7 was zero in every sample (no hardware breakpoints seen)\n");
    }
    fprintf(s, "\n");
    verdict(w, s);
    hash_game_files(w, s);
    fclose(s);
}

/* ------------------------------------------------------------ main */

static void make_dir(void)
{
    char exe[MAX_PATH], comp[64] = "pc";
    DWORD cn = sizeof comp;
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    char *slash;

    GetModuleFileNameA(NULL, exe, sizeof exe);
    slash = strrchr(exe, '\\');
    if (slash) *slash = 0;
    /* exe lives in bin\ ; results go next to RUN-ME.cmd */
    snprintf(g_bin, sizeof g_bin, "%s", exe);
    slash = strrchr(exe, '\\');
    if (slash && !lstrcmpiA(slash + 1, "bin")) *slash = 0;
    GetComputerNameA(comp, &cn);
    snprintf(g_dir, sizeof g_dir, "%s\\capture-%s-%04d%02d%02d-%02d%02d%02d", exe, comp,
             tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday, tm->tm_hour, tm->tm_min, tm->tm_sec);
    CreateDirectoryA(g_dir, NULL);
}

int main(int argc, char **argv)
{
    watch_t w;
    int seconds = 180, wait_seconds = 1200, skip_tests = 0, tests_only = 0, i;
    const char *exe_name = GAME_EXE;
    char logp[MAX_PATH];

    memset(&w, 0, sizeof w);
    w.va = DEFAULT_VA;
    w.thr_mode = 1;                                  /* default: main thread only */
    {
        const char *e = getenv("FIFA14CAP_NOTHREADS"), *a = getenv("FIFA14CAP_THREADS");
        if (e && *e && strcmp(e, "0")) { w.thr_mode = 0; w.thr_why_off = "FIFA14CAP_NOTHREADS is set"; }
        else if (a && !strcmp(a, "all")) w.thr_mode = 2;
    }
    for (i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--wait") && i + 1 < argc) wait_seconds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--va") && i + 1 < argc) w.va = (DWORD)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--exe") && i + 1 < argc) exe_name = argv[++i];
        else if (!strcmp(argv[i], "--skip-tests")) skip_tests = 1;
        else if (!strcmp(argv[i], "--tests-only")) tests_only = 1;
        else if (!strcmp(argv[i], "--nothreads")) { w.thr_mode = 0; w.thr_why_off = "--nothreads"; }
        else if (!strcmp(argv[i], "--threads-all") && w.thr_mode) w.thr_mode = 2;
        else { printf("usage: fifa14cap [--seconds N] [--wait N] [--va 0xADDR] [--exe name] [--skip-tests] [--tests-only] [--nothreads] [--threads-all]\n"); return 2; }
    }
    if (seconds < 10) seconds = 10;

    QueryPerformanceFrequency(&g_freq);
    QueryPerformanceCounter(&g_t0);
    timeBeginPeriod(1);
    SetConsoleCtrlHandler(on_ctrl, TRUE);
    make_dir();
    path_in_dir(logp, sizeof logp, "capture.txt");
    g_log = fopen(logp, "w");

    say("%s -- FIFA 14 Windows capture  (results go to %s)\n\n", KIT_VERSION, g_dir);
    system_info();
    if (!skip_tests) run_reference_tests();
    if (!tests_only)
    {
        wait_and_watch(&w, seconds, wait_seconds, exe_name);
        write_summary(&w, w.t_menu > 0);
    }
    if (g_log) { fclose(g_log); g_log = NULL; }

    /* zip the folder with the tar that ships with Windows 10+ */
    {
        char cmd[MAX_PATH * 3], parent[MAX_PATH], leaf[MAX_PATH], zip[MAX_PATH];
        char *slash;
        snprintf(parent, sizeof parent, "%s", g_dir);
        slash = strrchr(parent, '\\');
        snprintf(leaf, sizeof leaf, "%s", slash ? slash + 1 : g_dir);
        if (slash) *slash = 0;
        snprintf(zip, sizeof zip, "%s\\%s.zip", parent, leaf);
        snprintf(cmd, sizeof cmd, "cd /d \"%s\" && tar -a -c -f \"%s\" \"%s\" >nul 2>&1", parent, zip, leaf);
        system(cmd);
        if (GetFileAttributesA(zip) != INVALID_FILE_ATTRIBUTES)
            printf("\nDONE.  Send this one file:\n   %s\n", zip);
        else
            printf("\nDONE.  Zip this folder and send it:\n   %s\n", g_dir);
    }
    timeEndPeriod(1);
    return 0;
}
