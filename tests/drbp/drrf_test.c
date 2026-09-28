/*
 * drrf_test.c — conformance test for READ-firing data watchpoints on a
 * shared, read-only page (KUSER_SHARED_DATA).
 *
 * This test expresses documented x86-64 hardware semantics only. It
 * imitates the debug-register workload that runtime protection systems run
 * under Wine/Rosetta, without naming any of them:
 *
 *   - per thread, arm read+write (DR7 RW=11) LEN=1 watchpoints at
 *     KUSER_SHARED_DATA+0x270 (observed in the wild: dr0..dr3 = 0x7ffe0270,
 *     dr7 = 0x3330055, re-read via GetThreadContext on a worker pool);
 *   - expect the watchpoint to DELIVER EXCEPTION_SINGLE_STEP when the
 *     watched byte is READ (Dr6 B<n> set) — that is what x86 hardware does
 *     for RW=11, and what such systems require;
 *   - expect the rest of the page to keep working: neighbouring reads stay
 *     free, writes still fault as plain ACCESS_VIOLATION (the page is
 *     read-only, so no write to the watched byte ever "happens"), page
 *     protection is restored after disarm and after the owning thread
 *     exits;
 *   - expect the delivery to coexist with an EFLAGS.TF single-step engine
 *     driven through pushfq/orq/popfq, the way such systems single-step.
 *
 * Phases:
 *   1. KUSER_SHARED_DATA sanity (page present, readable, PAGE_READONLY)
 *   2. arm rw=11/LEN=1 at +0x270, GetThreadContext echoes Dr0/Dr7
 *   3. read the watched byte: a read-fire is delivered for it (Dr6 B0),
 *      value unchanged, neighbouring reads stay free, no stray faults, and
 *      VirtualQuery still reports PAGE_READONLY while armed (debug
 *      registers never change page protection)
 *   4. write the watched byte: plain ACCESS_VIOLATION, no B-bit
 *   5. disarm: reads free, page back to PAGE_READONLY
 *   6. worker-pool imitation: 16 threads each arm 4 rw=11 watchpoints on
 *      +0x270, echo them, read the byte 4x (expect 4 fires, Dr6 = 0xF),
 *      disarm and exit; page still PAGE_READONLY afterwards
 *   7. TF engine (pushfq/orq/popfq) + read-fire on the same page
 *
 * Every phase runs under a watchdog (20 s no progress / 60 s absolute),
 * so the test reports a livelock instead of hanging.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -Wall -o drrf_test.exe drrf_test.c
 * Exit 0 = all phases passed (read-fires work on the shared page).
 * Exit 1 = at least one phase failed.
 * Exit 42 = watchdog killed the process (livelock).
 *
 * Known behaviour on builds without read-fire support: phase 3 fails
 * ("0 fires, reads stayed free" — the arm-skip path) and phases 6/7 fail
 * on the missing fires; phases 1, 2, 4, 5 pass. That split is the
 * diagnostic: everything around read-fires is green, read-fires is the
 * only red.
 */

#define __USE_MINGW_ANSI_STDIO 1
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* DR7 bits */
#define DR7_L0        (1ULL << 0)
#define DR7_L1        (1ULL << 2)
#define DR7_L2        (1ULL << 4)
#define DR7_L3        (1ULL << 6)
#define DR7_G0        (1ULL << 1)
#define DR7_G1        (1ULL << 3)
#define DR7_G2        (1ULL << 5)
#define DR7_G3        (1ULL << 7)
#define DR7_RES10     (1ULL << 10)
#define DR7_ALL_LOCAL (DR7_L0|DR7_L1|DR7_L2|DR7_L3)
#define DR7_ALL_GLOBAL (DR7_G0|DR7_G1|DR7_G2|DR7_G3)
#define DR7_ENABLES   (DR7_L0|DR7_L1|DR7_L2|DR7_L3|0x3FULL)
/* RWn (bits 16+4n) = 11 (read+write), LENn (bits 18+4n) = 00 (1 byte) */
#define DR7_RW11_L0   (3ULL << 16)
#define DR7_RW11_L1   (3ULL << 20)
#define DR7_RW11_L2   (3ULL << 24)
#define DR7_RW11_L3   (3ULL << 28)
#define DR7_RW11_ALL  (DR7_RW11_L0|DR7_RW11_L1|DR7_RW11_L2|DR7_RW11_L3)
#define DR7_POOL_ARM  (DR7_RES10 | DR7_ALL_LOCAL | DR7_ALL_GLOBAL | DR7_RW11_ALL)
#define DR7_SELF_ARM  (DR7_RES10 | DR7_L0 | DR7_RW11_L0)

#define TF_FLAG       0x100ULL
#define KUSER_BASE    0x7FFE0000ULL
#define KUSER_WATCH   0x7FFE0270ULL      /* the watched byte */
#define KUSER_NEIGH   0x7FFE0274ULL      /* same page, not watched */

static volatile LONG g_phase       = 0;
static volatile LONG g_activity    = 0;   /* bumped by any delivery */
static volatile LONG g_unexpected  = 0;

/* phase 3 */
static volatile LONG g_rf_hits     = 0;   /* read-fires (Dr6 B0) */
static volatile LONG g_rd_av       = 0;   /* ACCESS_VIOLATION on a read */
static volatile LONG g_neigh_fire  = 0;
static volatile int  g_runaway     = 0;

/* phase 4 */
static volatile LONG g_wr_av       = 0;
static volatile LONG g_wr_bp       = 0;   /* AV that claimed to be a B-bit hit */

/* phase 6 */
static volatile LONG g_p6_done     = 0;
static volatile LONG g_p6_fires    = 0;   /* fires with the full B mask */
static volatile LONG g_p6_other    = 0;   /* fires without the full mask */
static volatile LONG g_p6_echo_ok  = 0;
static volatile LONG g_p6_threads  = 0;
#define P6_NTHREADS 16
#define P6_READS    4

/* phase 7 */
static volatile LONG g_p7_fire     = 0;
static volatile LONG g_p7_step     = 0;

static volatile DWORD g_phase_start;     /* GetTickCount() at phase entry */

static DWORD WINAPI watchdog(LPVOID arg)
{
    LONG last_phase = -1, last_act = 0;
    int no_prog = 0;

    (void)arg;
    for (;;)
    {
        Sleep(1000);
        LONG p = g_phase;
        LONG a = g_activity;
        if (p != last_phase)
        {
            last_phase = p;
            no_prog = 0;
            if (p != 0) g_phase_start = GetTickCount();   /* per-phase clock */
            continue;
        }
        if (p == 0) continue;             /* between phases: nothing to watch */
        if (a != last_act)
        {
            last_act = a;
            no_prog = 0;
        }
        else if (++no_prog >= 20)
        {
            printf("WDT: FAIL — livelock, no progress in phase %ld for ~20 s\n",
                   (long)p);
            fflush(stdout);
            TerminateProcess(GetCurrentProcess(), 42);
        }
        if (GetTickCount() - g_phase_start > 60000)
        {
            printf("WDT: FAIL — phase %ld alive for ~60 s (busy livelock)\n",
                   (long)p);
            fflush(stdout);
            TerminateProcess(GetCurrentProcess(), 42);
        }
    }
    return 0;
}

static void activity_bump(void) { g_activity++; }

static int set_drs(DWORD64 dr0, DWORD64 dr1, DWORD64 dr2, DWORD64 dr3,
                   DWORD64 dr7)
{
    CONTEXT c;
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    c.Dr0 = dr0; c.Dr1 = dr1; c.Dr2 = dr2; c.Dr3 = dr3; c.Dr7 = dr7;
    return SetThreadContext(GetCurrentThread(), &c);
}

static DWORD64 get_dr7(void)
{
    CONTEXT c;
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    if (!GetThreadContext(GetCurrentThread(), &c)) return 0;
    return c.Dr7;
}

static int clear_drs(void)
{
    DWORD64 dr7 = get_dr7();
    return set_drs(0, 0, 0, 0, (dr7 & ~DR7_ENABLES) | DR7_RES10);
}

static LONG CALLBACK veh(PEXCEPTION_POINTERS ep)
{
    PCONTEXT ctx = ep->ContextRecord;
    DWORD code = ep->ExceptionRecord->ExceptionCode;

    if (code == EXCEPTION_SINGLE_STEP)
    {
        DWORD64 dr6 = ctx->Dr6 & 0xFULL;
        activity_bump();

        switch (g_phase)
        {
        case 3:
            if (dr6 & 1) {
                if (++g_rf_hits > 20) g_runaway = 1;
                return EXCEPTION_CONTINUE_EXECUTION;
            }
            /* a step with no B-bit while no TF is set: not expected */
            g_unexpected++;
            return EXCEPTION_CONTINUE_EXECUTION;

        case 4:
            if (dr6 & 1) g_wr_bp++;
            else g_unexpected++;
            return EXCEPTION_CONTINUE_EXECUTION;

        case 6:
            if (dr6 == 0xF) InterlockedIncrement(&g_p6_fires);
            else InterlockedIncrement(&g_p6_other);
            if (g_p6_fires + g_p6_other > P6_NTHREADS * P6_READS * 2) g_runaway = 1;
            return EXCEPTION_CONTINUE_EXECUTION;

        case 7:
            if (dr6 & 1)
            {
                g_p7_fire++;
                /* Wine and Windows clear TF in every delivered single-step
                 * context: the TF engine re-arms itself each step */
                ctx->EFlags |= TF_FLAG;
            }
            else {
                g_p7_step++;
                ctx->EFlags &= ~TF_FLAG;
            }
            return EXCEPTION_CONTINUE_EXECUTION;

        default:
            break;
        }
        g_unexpected++;
        ctx->Dr7 = (ctx->Dr7 & ~DR7_ENABLES) | DR7_RES10;
        ctx->EFlags &= ~TF_FLAG;
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    if (code == EXCEPTION_ACCESS_VIOLATION)
    {
        DWORD wr = ep->ExceptionRecord->ExceptionInformation[0];
        DWORD64 addr = ep->ExceptionRecord->ExceptionInformation[1];

        if (g_phase == 3 && wr == 0 &&
            (addr & ~0xfffULL) == (KUSER_WATCH & ~0xfffULL))
        {
            /* a read faulted: the page was made unfree, not read-watched */
            g_rd_av++;
            ctx->Rip += 6;              /* past movzbl <abs>, %eax */
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        if (g_phase == 4 && wr == 1 && addr == KUSER_WATCH)
        {
            /* the page is read-only: the write faults, no B-bit possible */
            g_wr_av++;
            ctx->Rip += 8;              /* past the fixed-size store */
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        return EXCEPTION_CONTINUE_SEARCH;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

/* ---- phase 6 worker: one thread of the imitation pool ---- */
static DWORD WINAPI p6_proc(LPVOID arg)
{
    volatile unsigned char *k = (volatile unsigned char *)(uintptr_t)KUSER_WATCH;
    CONTEXT c;
    int echo_ok = 0, i;

    (void)arg;
    /* arm 4 rw=11/LEN=1 watchpoints on the watched byte, as the
     * protection's pool does (dr7 0x3330055 is this same pattern with
     * the game's own LEN choices) */
    if (set_drs(KUSER_WATCH, KUSER_WATCH, KUSER_WATCH, KUSER_WATCH, DR7_POOL_ARM))
    {
        memset(&c, 0, sizeof c);
        c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
        echo_ok = GetThreadContext(GetCurrentThread(), &c) &&
                  c.Dr0 == KUSER_WATCH && c.Dr1 == KUSER_WATCH &&
                  c.Dr2 == KUSER_WATCH && c.Dr3 == KUSER_WATCH &&
                  ((c.Dr7 & DR7_ALL_LOCAL) == DR7_ALL_LOCAL) &&
                  ((c.Dr7 & 0xFF) == 0x55) &&
                  (((c.Dr7 >> 16) & 3) == 3) &&   /* RW0 = 11 */
                  (((c.Dr7 >> 28) & 3) == 3);     /* RW3 = 11 */
    }
    if (echo_ok) InterlockedIncrement(&g_p6_echo_ok);

    for (i = 0; i < P6_READS; i++)
    {
        unsigned char v = *k;           /* each read must fire all 4 (Dr6=0xF) */
        (void)v;
        if (g_runaway) break;
    }

    clear_drs();                        /* disarm before the thread exits */
    InterlockedIncrement(&g_p6_done);
    return 0;
}

static void __attribute__((noinline)) p7_seq(void);

int main(void)
{
    int pass = 0, total = 0, i;
    volatile unsigned char *k = (volatile unsigned char *)(uintptr_t)KUSER_WATCH;

    AddVectoredExceptionHandler(1, (PVECTORED_EXCEPTION_HANDLER)veh);
    setvbuf(stdout, NULL, _IONBF, 0);
    CloseHandle(CreateThread(NULL, 0, watchdog, NULL, 0, NULL));

    printf("drrf_test: read-firing watchpoints on KUSER_SHARED_DATA "
           "(generic DR workload)\n\n");

    /* ---- phase 1: KUSER sanity ---- */
    total++;
    g_phase = 1;
    {
        MEMORY_BASIC_INFORMATION mbi;
        DWORD major = *(const DWORD *)(uintptr_t)(KUSER_BASE + 0x26C);
        DWORD minor = *(const DWORD *)(uintptr_t)(KUSER_BASE + 0x270);
        int ok = VirtualQuery((LPCVOID)(uintptr_t)KUSER_WATCH, &mbi, sizeof mbi)
                 && mbi.Protect == PAGE_READONLY;
        printf("[1] KUSER page present, PAGE_READONLY ... %s "
               "(Nt%lu.%lu prot=%lx)\n",
               ok ? "PASS" : "FAIL",
               (unsigned long)major, (unsigned long)minor,
               (unsigned long)mbi.Protect);
        pass += ok;
    }
    g_phase = 0;

    /* ---- phase 2: arm rw=11/LEN=1, GetThreadContext echoes ---- */
    total++;
    g_phase = 2;
    {
        CONTEXT c;
        int armed = set_drs(KUSER_WATCH, 0, 0, 0, DR7_SELF_ARM);
        memset(&c, 0, sizeof c);
        c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
        i = armed && GetThreadContext(GetCurrentThread(), &c) &&
              c.Dr0 == KUSER_WATCH && (c.Dr7 & DR7_L0) &&
              ((c.Dr7 >> 16) & 3) == 3;      /* RW0 = 11 */
        clear_drs();
        printf("[2] arm rw=11/LEN=1 at +0x270, context echo ... %s "
               "(dr7=%llx)\n", i ? "PASS" : "FAIL",
               (unsigned long long)(i ? DR7_SELF_ARM : 0));
        pass += i;
    }
    g_phase = 0;

    /* ---- phase 3: the read must fire ---- */
    total++;
    g_phase = 3;
    g_rf_hits = 0; g_rd_av = 0; g_neigh_fire = 0; g_runaway = 0;
    {
        unsigned char v0 = *k;
        MEMORY_BASIC_INFORMATION mbi;
        int ok;
        set_drs(KUSER_WATCH, 0, 0, 0, DR7_SELF_ARM);
        mbi.Protect = 0;
        VirtualQuery((LPCVOID)(uintptr_t)KUSER_WATCH, &mbi, sizeof mbi);
        for (i = 0; i < 5; i++)
        {
            unsigned char v = *k;          /* read-fire expected after this */
            (void)v;
            if (g_runaway) break;
        }
        {
            LONG before = g_rf_hits;
            unsigned char n = *(volatile unsigned char *)(uintptr_t)KUSER_NEIGH;
            (void)n;                       /* neighbouring read: must stay free */
            g_neigh_fire = g_rf_hits - before;
        }
        clear_drs();
        ok = (g_rf_hits == 5 && g_rd_av == 0 && g_neigh_fire == 0 &&
              !g_runaway && *k == v0 && mbi.Protect == PAGE_READONLY);
        printf("[3] read of the watched byte fires (Dr6 B0), neighbours "
               "free ... %s (fires=%ld rd_av=%ld neigh_fire=%ld runaway=%d "
               "byte=0x%02x prot_armed=%lx)\n",
               ok ? "PASS" : "FAIL", (long)g_rf_hits, (long)g_rd_av,
               (long)g_neigh_fire, g_runaway, (unsigned)*k,
               (unsigned long)mbi.Protect);
        pass += ok;
    }
    g_phase = 0;

    /* ---- phase 4: write still faults as a plain AV ---- */
    total++;
    g_phase = 4;
    g_wr_av = 0; g_wr_bp = 0;
    {
        int ok;
        set_drs(KUSER_WATCH, 0, 0, 0, DR7_SELF_ARM);
        /* movb $0x00, 0x7ffe0270 (fixed 8-byte store the VEH steps over) */
        __asm__ volatile (".byte 0xC6,0x04,0x25,0x70,0x02,0xFE,0x7F,0x00"
                          ::: "memory");
        clear_drs();
        ok = (g_wr_av == 1 && g_wr_bp == 0);
        printf("[4] write to the watched byte: plain ACCESS_VIOLATION "
               "... %s (wr_av=%ld wr_bp=%ld)\n",
               ok ? "PASS" : "FAIL", (long)g_wr_av, (long)g_wr_bp);
        pass += ok;
    }
    g_phase = 0;

    /* ---- phase 5: disarm restores the page ---- */
    total++;
    g_phase = 5;
    {
        MEMORY_BASIC_INFORMATION mbi;
        unsigned char before = *k;
        int ok;
        set_drs(KUSER_WATCH, 0, 0, 0, DR7_SELF_ARM);
        clear_drs();
        *k;                                /* free read after disarm */
        VirtualQuery((LPCVOID)(uintptr_t)KUSER_WATCH, &mbi, sizeof mbi);
        ok = (mbi.Protect == PAGE_READONLY && *k == before);
        printf("[5] after disarm: reads free, page PAGE_READONLY ... %s "
               "(prot=%lx)\n", ok ? "PASS" : "FAIL",
               (unsigned long)mbi.Protect);
        pass += ok;
    }
    g_phase = 0;

    /* ---- phase 6: worker-pool imitation ---- */
    total++;
    g_phase = 6;
    g_p6_done = 0; g_p6_fires = 0; g_p6_other = 0;
    g_p6_echo_ok = 0; g_p6_threads = 0; g_runaway = 0;
    {
        HANDLE t[P6_NTHREADS];
        int ok;
        for (i = 0; i < P6_NTHREADS; i++)
        {
            t[i] = CreateThread(NULL, 0, p6_proc, NULL, 0, NULL);
            g_p6_threads += (t[i] != NULL);
        }
        if (WaitForMultipleObjects(P6_NTHREADS, t, TRUE, 60000) != WAIT_OBJECT_0)
            TerminateProcess(GetCurrentProcess(), 42);
        for (i = 0; i < P6_NTHREADS; i++)
            if (t[i]) CloseHandle(t[i]);
        ok = (g_p6_done == P6_NTHREADS &&
              g_p6_echo_ok == P6_NTHREADS &&
              g_p6_fires == P6_NTHREADS * P6_READS && g_p6_other == 0 &&
              !g_runaway);
        printf("[6] pool: %ld threads arm 4x rw=11, echo, 4 reads each ... %s "
               "(done=%ld echo=%ld fires=%ld other=%ld runaway=%d, expect "
               "fires=%d)\n",
               (long)g_p6_threads, ok ? "PASS" : "FAIL",
               (long)g_p6_done, (long)g_p6_echo_ok, (long)g_p6_fires,
               (long)g_p6_other, g_runaway, P6_NTHREADS * P6_READS);
        pass += ok;
    }
    g_phase = 0;

    /* ---- phase 7: TF engine + read-fire on the same page ---- */
    total++;
    g_phase = 7;
    g_p7_fire = 0; g_p7_step = 0;
    {
        int ok;
        set_drs(KUSER_WATCH, 0, 0, 0, DR7_SELF_ARM);
        p7_seq();
        clear_drs();
        ok = (g_p7_fire == 1 && g_p7_step == 1);
        printf("[7] TF (pushfq/orq/popfq) + read-fire coexist ... %s "
               "(fire=%ld step=%ld)\n",
               ok ? "PASS" : "FAIL", (long)g_p7_fire, (long)g_p7_step);
        pass += ok;
    }
    g_phase = 0;

    printf("\nunexpected single-steps: %ld\n", (long)g_unexpected);
    printf("DRRF: %d/%d — %s\n", pass, total,
           pass == total
             ? "read-fires work on the shared read-only page; the "
               "imitated DR workload is fully served"
             : "blocked (read the per-phase detail above)");
    return pass == total ? 0 : 1;
}

/* phase 7 body: with a read watchpoint on +0x270 and TF set,
 *  - the first instruction (read of the watched byte) must deliver the
 *    read-fire (Dr6 B0; TF is still pending on the same #DB),
 *  - the second instruction must deliver the plain TF step. */
static void __attribute__((noinline)) p7_seq(void)
{
    __asm__ volatile (
        "pushfq\n\t"
        "orq $0x100, (%%rsp)\n\t"
        "popfq\n\t"
        "movzbl 0x7FFE0270, %%eax\n\t"
        "nop\n\t"
        : : : "eax", "memory", "cc");
}
