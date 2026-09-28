/*
 * drbp_test.c — conformance test for user-mode x86-64 hardware debug
 * registers under Wine/CrossOver.
 *
 * Scope: documented Windows semantics only, expressed generically.
 *   1. DR0 execute breakpoint, armed on the current thread via
 *      SetThreadContext, delivered in-process.
 *   2. DR1 data write watchpoint (1 byte), armed the same way.
 *   3. EFLAGS.TF single-step delivery.
 *   4. CONTEXT_DEBUG_REGISTERS round-trip through Get/SetThreadContext.
 *   5. KUSER_SHARED_DATA page readable at 0x7FFE0000 (informational only;
 *      prints stock fields, asserts nothing about values).
 *
 * The test knows nothing about any game or protection scheme. It exists to
 * verify that debug-register emulation (e.g. CrossOver's CX_DR_TRAP feature)
 * behaves the way Windows documents, on any bottle.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o drbp_test.exe drbp_test.c
 * Exit code 0 = every case passed.
 */

#define __USE_MINGW_ANSI_STDIO 1
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* DR7 bits */
#define DR7_L0        (1ULL << 0)
#define DR7_G0        (1ULL << 1)
#define DR7_L1        (1ULL << 2)
#define DR7_G1        (1ULL << 3)
#define DR7_L2        (1ULL << 4)
#define DR7_L3        (1ULL << 6)
#define DR7_G3        (1ULL << 7)
#define DR7_RES10     (1ULL << 10)          /* bit 10 reads back as 1 */
#define DR7_RW1_WRITE (1ULL << 20)          /* R/W1 = 01 (write) */
#define DR7_ENABLES   (DR7_L0|DR7_G0|DR7_L1|DR7_G1|DR7_L3|DR7_G3|0xFULL)

#define TF_FLAG 0x100ULL

static int set_drs(DWORD64 dr0, DWORD64 dr1, DWORD64 dr3, DWORD64 dr7);

static volatile LONG g_phase      = 0;   /* 1..8 = case in flight */
static volatile LONG g_bp0_hits   = 0;
static volatile LONG g_wp_hits    = 0;
static volatile LONG g_ss_hits    = 0;
static volatile LONG g_unexpected = 0;
static volatile BYTE g_watch      = 0;
static volatile LONG g_xrw_hits   = 0;   /* case 8: read+write watchpoint */

/* case 6: breakpoint armed on another thread; the fault handler must hand
 * the guest the arming thread's registers, not zeros */
static volatile LONG g_x_dr0_ok  = 0;
static volatile LONG g_x_dr7_ok  = 0;
static volatile DWORD64 g_x_seen_dr0;
static volatile DWORD64 g_x_seen_dr7;
static HANDLE g_ev_ready;
static HANDLE g_ev_go;

static void __attribute__((noinline)) bp0_target(void) { }

static void (*volatile g_bp0_fp)(void) = bp0_target;

static void disarm(PCONTEXT ctx)
{
    ctx->Dr7 = (ctx->Dr7 & ~DR7_ENABLES) | DR7_RES10;
    ctx->EFlags &= ~TF_FLAG;
}

static LONG CALLBACK veh(PEXCEPTION_POINTERS ep)
{
    PCONTEXT ctx = ep->ContextRecord;

    if (ep->ExceptionRecord->ExceptionCode != EXCEPTION_SINGLE_STEP)
        return EXCEPTION_CONTINUE_SEARCH;

    switch (g_phase)
    {
    case 1:                              /* execute bp at bp0_target */
        if (ctx->Rip == (DWORD64)(uintptr_t)bp0_target)
        {
            g_bp0_hits++;
            ctx->Dr7 = (ctx->Dr7 & ~DR7_L0) | DR7_RES10;
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        break;

    case 2:                              /* write watchpoint on g_watch */
        if (++g_wp_hits > 10) break;     /* runaway guard */
        ctx->Dr7 = (ctx->Dr7 & ~DR7_L1) | DR7_RES10;
        return EXCEPTION_CONTINUE_EXECUTION;

    case 3:                              /* single step */
        g_ss_hits++;
        ctx->EFlags &= ~TF_FLAG;
        return EXCEPTION_CONTINUE_EXECUTION;

    case 6:                              /* bp armed by another thread */
        if (ctx->Rip == (DWORD64)(uintptr_t)bp0_target)
        {
            g_x_seen_dr0 = ctx->Dr0;
            g_x_seen_dr7 = ctx->Dr7;
            if (ctx->Dr0 == (DWORD64)(uintptr_t)bp0_target) g_x_dr0_ok++;
            if (ctx->Dr7 & DR7_L0) g_x_dr7_ok++;
            g_bp0_hits++;
            ctx->Dr7 = (ctx->Dr7 & ~DR7_L0) | DR7_RES10;
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        break;

    case 8:                              /* read+write watchpoint */
        if (++g_xrw_hits > 10) break;    /* runaway guard */
        ctx->Dr7 = (ctx->Dr7 & ~DR7_L3) | DR7_RES10;
        return EXCEPTION_CONTINUE_EXECUTION;

    default:
        break;
    }

    g_unexpected++;
    disarm(ctx);
    return EXCEPTION_CONTINUE_EXECUTION;
}

static DWORD WINAPI t6_proc(LPVOID arg)
{
    (void)arg;
    SetEvent(g_ev_ready);
    WaitForSingleObject(g_ev_go, 5000);
    g_phase = 6;
    g_bp0_fp();                      /* the breakpoint fires here */
    g_phase = 0;
    g_bp0_fp();                      /* disarmed: must run clean */
    return 0;
}

/* case 7: arms an execute breakpoint on itself, never executes it, exits. */
static DWORD WINAPI t7_proc(LPVOID arg)
{
    (void)arg;
    set_drs((DWORD64)(uintptr_t)bp0_target, 0, 0, DR7_RES10 | DR7_L0);
    SetEvent(g_ev_ready);
    WaitForSingleObject(g_ev_go, 5000);
    return 0;                        /* dies with the breakpoint armed */
}

static int set_drs(DWORD64 dr0, DWORD64 dr1, DWORD64 dr3, DWORD64 dr7)
{
    CONTEXT c;
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    c.Dr0 = dr0;
    c.Dr1 = dr1;
    c.Dr3 = dr3;
    c.Dr7 = dr7;
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

int main(void)
{
    CONTEXT c;
    int pass = 0, total = 0;
    DWORD64 dr7;

    AddVectoredExceptionHandler(1, (PVECTORED_EXCEPTION_HANDLER)veh);
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("drbp_test: user-mode debug-register conformance\n\n");

    /* ---- case 1: self-armed execute breakpoint ---- */
    total++;
    printf("[case 1] DR0 execute breakpoint, self-armed via SetThreadContext ... ");
    g_bp0_hits = 0;
    if (set_drs((DWORD64)(uintptr_t)bp0_target, 0, 0, DR7_RES10 | DR7_L0))
    {
        g_phase = 1;
        g_bp0_fp();
        g_phase = 0;
        dr7 = get_dr7();
        set_drs(0, 0, 0, (dr7 & ~DR7_ENABLES) | DR7_RES10);
        printf("%s (%ld hit%s, Dr7=%llx)\n",
               g_bp0_hits == 1 ? "PASS" : "FAIL",
               (long)g_bp0_hits, g_bp0_hits == 1 ? "" : "s", dr7);
        pass += (g_bp0_hits == 1);
    }
    else printf("FAIL (SetThreadContext refused)\n");

    /* ---- case 2: self-armed write watchpoint ---- */
    total++;
    printf("[case 2] DR1 write watchpoint (1 byte), self-armed ... ");
    g_wp_hits = 0;
    g_watch = 0;
    if (set_drs(0, (DWORD64)(uintptr_t)&g_watch, 0,
                DR7_RES10 | DR7_L1 | DR7_RW1_WRITE))
    {
        g_phase = 2;
        g_watch = 0x42;                  /* the watched write */
        g_phase = 0;
        dr7 = get_dr7();
        set_drs(0, 0, 0, (dr7 & ~DR7_ENABLES) | DR7_RES10);
        printf("%s (%ld hit%s, byte=0x%02x)\n",
               g_wp_hits >= 1 ? "PASS" : "FAIL",
               (long)g_wp_hits, g_wp_hits == 1 ? "" : "s", (unsigned)g_watch);
        pass += (g_wp_hits >= 1);
    }
    else printf("FAIL (SetThreadContext refused)\n");

    /* ---- case 3: single-step via trap flag ---- */
    total++;
    printf("[case 3] EFLAGS.TF single-step ... ");
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_CONTROL | CONTEXT_DEBUG_REGISTERS;
    if (GetThreadContext(GetCurrentThread(), &c))
    {
        c.EFlags |= TF_FLAG;
        c.ContextFlags = CONTEXT_CONTROL | CONTEXT_DEBUG_REGISTERS;
        g_ss_hits = 0;
        if (SetThreadContext(GetCurrentThread(), &c))
        {
            g_phase = 3;
            {
                volatile int spin = 0;   /* first instruction traps */
                spin++;
                (void)spin;
            }
            g_phase = 0;
            printf("%s (%ld hit%s)\n",
                   g_ss_hits == 1 ? "PASS" : "FAIL",
                   (long)g_ss_hits, g_ss_hits == 1 ? "" : "s");
            pass += (g_ss_hits == 1);
        }
        else printf("FAIL (SetThreadContext refused)\n");
    }
    else printf("FAIL (GetThreadContext refused)\n");

    /* ---- case 4: context round-trip ---- */
    total++;
    printf("[case 4] CONTEXT_DEBUG_REGISTERS round-trip (Dr3/Dr7) ... ");
    {
        DWORD64 probe = (DWORD64)(uintptr_t)main;
        int ok = set_drs(0, 0, probe, DR7_RES10 | DR7_L3);
        if (ok)
        {
            memset(&c, 0, sizeof c);
            c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
            ok = GetThreadContext(GetCurrentThread(), &c) &&
                 c.Dr3 == probe && (c.Dr7 & DR7_L3);
            dr7 = get_dr7();
            set_drs(0, 0, 0, (dr7 & ~DR7_ENABLES) | DR7_RES10);
            printf("%s (Dr3=%llx Dr7=%llx)\n",
                   ok ? "PASS" : "FAIL",
                   (unsigned long long)c.Dr3, (unsigned long long)c.Dr7);
            pass += ok;
        }
        else printf("FAIL (SetThreadContext refused)\n");
    }

    /* ---- case 5: KUSER_SHARED_DATA present (informational) ---- */
    total++;
    printf("[case 5] KUSER_SHARED_DATA readable at 0x7FFE0000 ... ");
    {
        const unsigned char *k = (const unsigned char *)(uintptr_t)0x7FFE0000ULL;
        DWORD major = *(const DWORD *)(k + 0x26C);
        DWORD minor = *(const DWORD *)(k + 0x270);
        unsigned char pf[4];
        memcpy(pf, k + 0x274, 4);
        printf("INFO (NtMajorVersion=%lu NtMinorVersion=%lu "
               "ProcessorFeatures[0..3]=%02x %02x %02x %02x)\n",
               (unsigned long)major, (unsigned long)minor,
               pf[0], pf[1], pf[2], pf[3]);
        pass++;                          /* reaching here is the assertion */
    }

    /* ---- case 6: execute breakpoint armed on ANOTHER thread ----
     * Windows delivers the breakpoint with Dr0/Dr7 as the arming context
     * wrote them, whatever thread ran the SetThreadContext. */
    total++;
    printf("[case 6] DR0 execute bp armed on another thread ... ");
    {
        HANDLE t;
        CONTEXT c;
        DWORD tid = 0;
        g_bp0_hits = 0; g_x_dr0_ok = 0; g_x_dr7_ok = 0;
        g_ev_ready = CreateEventA(NULL, FALSE, FALSE, NULL);
        g_ev_go    = CreateEventA(NULL, FALSE, FALSE, NULL);
        t = CreateThread(NULL, 0, t6_proc, NULL, 0, &tid);
        if (t)
        {
            int armed = 0;
            WaitForSingleObject(g_ev_ready, 5000);
            memset(&c, 0, sizeof c);
            c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
            c.Dr0 = (DWORD64)(uintptr_t)bp0_target;
            c.Dr7 = DR7_RES10 | DR7_L0;
            armed = SetThreadContext(t, &c) ? 1 : 0;
            SetEvent(g_ev_go);
            WaitForSingleObject(t, 10000);
            CloseHandle(t);
            if (armed)
            {
                int ok = (g_bp0_hits == 1 && g_x_dr0_ok == 1 && g_x_dr7_ok == 1);
                printf("%s (hits=%ld Dr0@hit=%llx Dr7@hit=%llx)\n",
                       ok ? "PASS" : "FAIL",
                       (long)g_bp0_hits,
                       (unsigned long long)g_x_seen_dr0,
                       (unsigned long long)g_x_seen_dr7);
                pass += ok;
            }
            else printf("FAIL (SetThreadContext refused)\n");
        }
        else printf("FAIL (CreateThread refused)\n");
        CloseHandle(g_ev_ready);
        CloseHandle(g_ev_go);
    }

    /* ---- case 7: bp page protection restored after the owning thread
     * exits without executing the breakpoint. Windows has no memory of a
     * dead thread's debug registers: the page keeps its original access. */
    total++;
    printf("[case 7] bp page access restored after owning thread exits ... ");
    {
        MEMORY_BASIC_INFORMATION m0, m1, m2;
        DWORD orig, after_arm, after_exit;
        int ok;
        VirtualQuery(bp0_target, &m0, sizeof m0);
        orig = m0.Protect;
        g_ev_ready = CreateEventA(NULL, FALSE, FALSE, NULL);
        g_ev_go    = CreateEventA(NULL, FALSE, FALSE, NULL);
        {
            HANDLE t = CreateThread(NULL, 0, t7_proc, NULL, 0, NULL);
            if (t)
            {
                WaitForSingleObject(g_ev_ready, 5000);
                VirtualQuery(bp0_target, &m1, sizeof m1);
                after_arm = m1.Protect;
                SetEvent(g_ev_go);
                WaitForSingleObject(t, 10000);
                CloseHandle(t);
            }
            else after_arm = 0;
        }
        VirtualQuery(bp0_target, &m2, sizeof m2);
        after_exit = m2.Protect;
        ok = (after_arm != 0) && (after_exit == orig);
        printf("%s (orig=%lx after_arm=%lx after_exit=%lx)\n",
               ok ? "PASS" : "FAIL",
               (unsigned long)orig, (unsigned long)after_arm,
               (unsigned long)after_exit);
        pass += ok;
        CloseHandle(g_ev_ready);
        CloseHandle(g_ev_go);
    }

    /* ---- case 8: read+write watchpoint (2 bytes) ---- */
    total++;
    printf("[case 8] DR3 read+write watchpoint (2 bytes), self-armed ... ");
    {
        int ok;
        g_xrw_hits = 0;
        if (set_drs(0, 0, (DWORD64)(uintptr_t)&g_watch,
                    DR7_RES10 | DR7_L3 | (3ULL << 28) | (1ULL << 30)))
        {
            g_phase = 8;
            g_watch = 0x99;              /* the watched write */
            g_phase = 0;
            dr7 = get_dr7();
            set_drs(0, 0, 0, (dr7 & ~DR7_ENABLES) | DR7_RES10);
            ok = (g_xrw_hits >= 1 && g_watch == 0x99);
            printf("%s (%ld hit%s)\n",
                   ok ? "PASS" : "FAIL",
                   (long)g_xrw_hits, g_xrw_hits == 1 ? "" : "s");
            pass += ok;
        }
        else printf("FAIL (SetThreadContext refused)\n");
    }

    printf("\nunexpected single-steps: %ld\n", (long)g_unexpected);
    printf("RESULT: %d/%d passed\n", pass, total);
    return pass == total ? 0 : 1;
}
