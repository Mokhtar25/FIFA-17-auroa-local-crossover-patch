/*
 * dr_gate.c — go/no-go gate for debug-register emulation fidelity.
 *
 * Runs the exact DR workload a protected title runs under Wine/Rosetta and
 * prints one verdict: PASS means the emulation handled every pattern the
 * title leans on (self-armed and cross-thread execute breakpoints, per-thread
 * KUSER_SHARED_DATA watchpoints, TF single-stepping through popfq, TF-clobber
 * desync, thread-exit cleanup). A FAIL names the phase.
 *
 * Every phase is watched by a watchdog: a phase that makes no progress for
 * ~25 s is reported as a livelock and kills the process, so nothing hangs.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -Wall -o dr_gate.exe dr_gate.c
 * Exit 0 = gate open.
 */

#define __USE_MINGW_ANSI_STDIO 1
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#define DR7_RES10      (1ULL << 10)
#define DR7_L0         (1ULL << 0)
#define DR7_L2         (1ULL << 4)
#define DR7_ENABLES    (DR7_L0|DR7_L2|0x3FULL)
#define KUSER_BP       0x7FFE0270ULL

static volatile LONG g_phase        = 0;
static volatile LONG g_bp_hits      = 0;
static volatile LONG g_ss_hits      = 0;
static volatile LONG g_step_hits    = 0;
static volatile LONG g_unexpected   = 0;
static volatile LONG g_kuser_rd_flt = 0;
static volatile LONG g_kuser_wr_av  = 0;
static volatile DWORD64 g_hit_dr0, g_hit_dr7, g_step_rip;
static HANDLE g_ev_ready, g_ev_go;

static void __attribute__((noinline)) bp_target(void) { }
static void (*volatile g_bp_fp)(void) = bp_target;

static DWORD WINAPI watchdog(LPVOID arg)
{
    LONG last = -1;
    int stable = 0;
    for (;;)
    {
        Sleep(1000);
        LONG p = g_phase;
        if (p == last && p != 0)
        {
            if (++stable >= 25)
            {
                printf("GATE: FAIL — livelock, no progress in phase %ld for ~25 s\n", (long)p);
                fflush(stdout);
                TerminateProcess(GetCurrentProcess(), 42);
            }
        }
        else { last = p; stable = 0; }
    }
    return 0;
}

static int __attribute__((noinline)) tf_seq(void);

static LONG CALLBACK veh(PEXCEPTION_POINTERS ep)
{
    PCONTEXT ctx = ep->ContextRecord;
    DWORD code = ep->ExceptionRecord->ExceptionCode;

    if (code == EXCEPTION_SINGLE_STEP)
    {
        switch (g_phase)
        {
        case 1:
            if (ctx->Rip == (DWORD64)(uintptr_t)bp_target)
            {
                g_hit_dr0 = ctx->Dr0;
                g_hit_dr7 = ctx->Dr7;
                g_bp_hits++;
                ctx->Dr7 = (ctx->Dr7 & ~DR7_L0) | DR7_RES10;
                return EXCEPTION_CONTINUE_EXECUTION;
            }
            break;
        case 2:
            if (ctx->Rip == (DWORD64)(uintptr_t)bp_target)
            {
                g_hit_dr0 = ctx->Dr0;
                g_hit_dr7 = ctx->Dr7;
                g_bp_hits++;
                ctx->Dr7 = (ctx->Dr7 & ~DR7_L0) | DR7_RES10;
                return EXCEPTION_CONTINUE_EXECUTION;
            }
            break;
        case 4:                              /* TF sequence: expect the step */
            g_ss_hits++;
            g_step_rip = ctx->Rip;
            ctx->EFlags &= ~0x100ULL;
            return EXCEPTION_CONTINUE_EXECUTION;
        case 5:                              /* exec bp + popfq/TF collision */
            if (ctx->Rip == (DWORD64)(uintptr_t)tf_seq)
            {
                g_bp_hits++;
                ctx->Dr7 = (ctx->Dr7 & ~DR7_L0) | DR7_RES10;
                return EXCEPTION_CONTINUE_EXECUTION;
            }
            g_ss_hits++;
            g_step_rip = ctx->Rip;
            ctx->EFlags &= ~0x100ULL;
            return EXCEPTION_CONTINUE_EXECUTION;
        default:
            break;
        }
        g_unexpected++;
        ctx->Dr7 = (ctx->Dr7 & ~DR7_ENABLES) | DR7_RES10;
        ctx->EFlags &= ~0x100ULL;
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    if (code == EXCEPTION_ACCESS_VIOLATION && g_phase == 3)
    {
        /* writes to KUSER fault on the read-only page; the hardware watchpoint
         * cannot fire on a write that never happened */
        DWORD wr = ep->ExceptionRecord->ExceptionInformation[0];
        DWORD64 addr = ep->ExceptionRecord->ExceptionInformation[1];
        if (wr == 1 && addr == KUSER_BP)
        {
            g_kuser_wr_av++;
            ctx->Rip += 8;                   /* past the fixed-size store */
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        if (wr == 0 && (addr & ~0xfffULL) == (KUSER_BP & ~0xfffULL))
            g_kuser_rd_flt++;
        return EXCEPTION_CONTINUE_SEARCH;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static int set_drs(DWORD64 dr0, DWORD64 dr1, DWORD64 dr3, DWORD64 dr7)
{
    CONTEXT c;
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    c.Dr0 = dr0; c.Dr1 = dr1; c.Dr3 = dr3; c.Dr7 = dr7;
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
    return set_drs(0, 0, 0, (dr7 & ~DR7_ENABLES) | DR7_RES10);
}

static DWORD WINAPI t2_proc(LPVOID arg)
{
    (void)arg;
    SetEvent(g_ev_ready);
    WaitForSingleObject(g_ev_go, 5000);
    g_phase = 2;
    g_bp_fp();
    g_phase = 0;
    g_bp_fp();
    return 0;
}

static DWORD WINAPI t6_proc(LPVOID arg)
{
    (void)arg;
    set_drs((DWORD64)(uintptr_t)bp_target, 0, 0, DR7_RES10 | DR7_L0);
    SetEvent(g_ev_ready);
    WaitForSingleObject(g_ev_go, 5000);
    return 0;
}

static int __attribute__((noinline)) tf_seq(void)
{
    volatile int x = 0;
    __asm__ volatile (
        "pushfq\n\t"
        "orq $0x100, (%rsp)\n\t"
        "popfq\n\t"
        "nop\n\t"
        "nop\n\t"
    );
    return x;
}

int main(void)
{
    int pass = 0, total = 0;

    AddVectoredExceptionHandler(1, (PVECTORED_EXCEPTION_HANDLER)veh);
    setvbuf(stdout, NULL, _IONBF, 0);
    CloseHandle(CreateThread(NULL, 0, watchdog, NULL, 0, NULL));

    printf("dr_gate: debug-register emulation gate\n\n");

    /* ---- phase 1: self-armed execute bp ---- */
    total++;
    g_phase = 1; g_bp_hits = 0;
    if (set_drs((DWORD64)(uintptr_t)bp_target, 0, 0, DR7_RES10 | DR7_L0))
    {
        g_bp_fp();
        clear_drs();
        if (g_bp_hits == 1 && g_hit_dr0 == (DWORD64)(uintptr_t)bp_target &&
            (g_hit_dr7 & DR7_L0))
        {
            printf("[1] self-armed exec bp, registers correct ... PASS\n");
            pass++;
        }
        else printf("[1] self-armed exec bp ... FAIL (hits=%ld Dr0=%llx Dr7=%llx)\n",
                    (long)g_bp_hits, (unsigned long long)g_hit_dr0,
                    (unsigned long long)g_hit_dr7);
    }
    else printf("[1] FAIL (SetThreadContext refused)\n");
    g_phase = 0;

    /* ---- phase 2: cross-thread arm ---- */
    total++;
    g_bp_hits = 0; g_hit_dr0 = 0; g_hit_dr7 = 0;
    g_ev_ready = CreateEventA(NULL, FALSE, FALSE, NULL);
    g_ev_go    = CreateEventA(NULL, FALSE, FALSE, NULL);
    {
        HANDLE t = CreateThread(NULL, 0, t2_proc, NULL, 0, NULL);
        CONTEXT c;
        WaitForSingleObject(g_ev_ready, 5000);
        memset(&c, 0, sizeof c);
        c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
        c.Dr0 = (DWORD64)(uintptr_t)bp_target;
        c.Dr7 = DR7_RES10 | DR7_L0;
        if (t && SetThreadContext(t, &c))
        {
            SetEvent(g_ev_go);
            WaitForSingleObject(t, 10000);
            CloseHandle(t);
            if (g_bp_hits == 1 && g_hit_dr0 == (DWORD64)(uintptr_t)bp_target &&
                (g_hit_dr7 & DR7_L0))
            {
                printf("[2] cross-thread arm, registers correct ... PASS\n");
                pass++;
            }
            else printf("[2] cross-thread arm ... FAIL (hits=%ld Dr0=%llx Dr7=%llx)\n",
                        (long)g_bp_hits, (unsigned long long)g_hit_dr0,
                        (unsigned long long)g_hit_dr7);
        }
        else { printf("[2] FAIL (arm refused)\n"); if (t) { TerminateThread(t, 0); CloseHandle(t); } }
    }
    CloseHandle(g_ev_ready); CloseHandle(g_ev_go);
    g_phase = 0;

    /* ---- phase 3: KUSER_SHARED_DATA watchpoint lifecycle ---- */
    total++;
    g_phase = 3;
    {
        volatile unsigned char *k = (volatile unsigned char *)(uintptr_t)KUSER_BP;
        MEMORY_BASIC_INFORMATION mbi;
        CONTEXT c;
        int echo_ok, read_ok, write_ok, restore_ok, i;

        memset(&c, 0, sizeof c);
        c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
        c.Dr2 = KUSER_BP;
        c.Dr7 = DR7_RES10 | DR7_L2 | (3ULL << 24);   /* rw=11, LEN=1 */
        i = SetThreadContext(GetCurrentThread(), &c);
        memset(&c, 0, sizeof c);
        c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
        echo_ok = i && GetThreadContext(GetCurrentThread(), &c) &&
                  c.Dr2 == KUSER_BP && ((c.Dr7 >> 24) & 3) == 3 && (c.Dr7 & DR7_L2);

        read_ok = 0;
        {
            unsigned char v = *k;                    /* must not fault */
            (void)v;
            read_ok = 1;
        }
        write_ok = 0;
        /* fixed 8-byte store the VEH can step over: movb $0, 0x7ffe0270 */
        __asm__ volatile (".byte 0xC6,0x04,0x25,0x70,0x02,0xFE,0x7F,0x00" ::: "memory");
        write_ok = (g_kuser_wr_av == 1);
        clear_drs();
        VirtualQuery((LPCVOID)(uintptr_t)KUSER_BP, &mbi, sizeof mbi);
        restore_ok = (mbi.Protect == PAGE_READONLY);
        if (echo_ok && read_ok && write_ok && restore_ok && g_kuser_rd_flt == 0)
        {
            printf("[3] KUSER watchpoint lifecycle ... PASS\n");
            pass++;
        }
        else printf("[3] KUSER watchpoint ... FAIL (echo=%d read=%d write_av=%d "
                    "prot=%lx stray_rd=%ld)\n",
                    echo_ok, read_ok, (int)g_kuser_wr_av,
                    (unsigned long)mbi.Protect, (long)g_kuser_rd_flt);
    }
    g_phase = 0;

    /* ---- phase 4: TF single-step via pushfq/popfq ---- */
    total++;
    g_phase = 4; g_ss_hits = 0;
    tf_seq();
    if (g_ss_hits == 1)
    {
        printf("[4] TF step after popfq ... PASS\n");
        pass++;
    }
    else printf("[4] TF step after popfq ... FAIL (steps=%ld rip=%llx)\n",
                (long)g_ss_hits, (unsigned long long)g_step_rip);
    g_phase = 0;

    /* ---- phase 5: exec bp + the title's own popfq/TF engine on one page ---- */
    total++;
    g_phase = 5; g_bp_hits = 0; g_ss_hits = 0; g_step_hits = 0;
    if (set_drs((DWORD64)(uintptr_t)tf_seq, 0, 0, DR7_RES10 | DR7_L0))
    {
        tf_seq();
        clear_drs();
        if (g_bp_hits == 1 && g_ss_hits == 1 && g_unexpected == 0)
        {
            printf("[5] bp + popfq/TF on the same page ... PASS\n");
            pass++;
        }
        else printf("[5] bp + popfq/TF ... FAIL (bp=%ld steps=%ld unexpected=%ld "
                    "step_rip=%llx)\n",
                    (long)g_bp_hits, (long)g_ss_hits, (long)g_unexpected,
                    (unsigned long long)g_step_rip);
    }
    else printf("[5] FAIL (SetThreadContext refused)\n");
    g_phase = 0;

    /* ---- phase 6: page access restored after the arming thread exits ---- */
    total++;
    g_phase = 6;
    {
        MEMORY_BASIC_INFORMATION m0, m1, m2;
        DWORD orig, after_arm, after_exit;
        int ok;
        VirtualQuery(bp_target, &m0, sizeof m0);
        orig = m0.Protect;
        g_ev_ready = CreateEventA(NULL, FALSE, FALSE, NULL);
        g_ev_go    = CreateEventA(NULL, FALSE, FALSE, NULL);
        {
            HANDLE t = CreateThread(NULL, 0, t6_proc, NULL, 0, NULL);
            if (t)
            {
                WaitForSingleObject(g_ev_ready, 5000);
                VirtualQuery(bp_target, &m1, sizeof m1);
                after_arm = m1.Protect;
                SetEvent(g_ev_go);
                WaitForSingleObject(t, 10000);
                CloseHandle(t);
            }
            else after_arm = 0;
        }
        VirtualQuery(bp_target, &m2, sizeof m2);
        after_exit = m2.Protect;
        ok = (after_arm != 0) && (after_exit == orig);
        printf("[6] page restored after thread exit ... %s "
               "(orig=%lx arm=%lx exit=%lx)\n",
               ok ? "PASS" : "FAIL",
               (unsigned long)orig, (unsigned long)after_arm,
               (unsigned long)after_exit);
        pass += ok;
        CloseHandle(g_ev_ready); CloseHandle(g_ev_go);
    }
    g_phase = 0;

    printf("\nunexpected single-steps: %ld\n", (long)g_unexpected);
    printf("GATE: %d/%d — %s\n", pass, total,
           pass == total ? "the emulated DR workload is complete" : "blocked");
    return pass == total ? 0 : 1;
}
