/*
 * trapstorm.c — the exception-handler pattern that stalls, on its own.
 *
 * A protector can tap instructions without modifying them: arm four execute
 * breakpoints from its own exception handler, and on each trap run its own
 * bytecode interpreter.  The interpreter writes into data the compiler put in
 * a read-only section.  That write faults, and the fault is dispatched while
 * the trap handler is still on the stack, so it reaches the same handler again
 * with EXCEPTION_NESTED_CALL set.
 *
 * This builds exactly that, with nothing game-specific in it:
 *   - a read-only data page, as a linker makes .rdata;
 *   - four generated code stubs, as a packer relocates code;
 *   - a raw SEH handler that arms Dr0-Dr3 on them from the context of a UD2;
 *   - an interpreter that handler calls, which writes to the read-only page.
 *
 * Then it asserts the documented Windows behaviour of every step, with caps
 * and a watchdog, so a stall is a failed check with a reason rather than a
 * hung process.  Values asserted are Windows' own:
 *
 *   - one #DB per execution of a tapped address, before the instruction;
 *   - ExceptionAddress == EIP == the tapped address (a fault, not a trap);
 *   - Dr6 = 0xffff0ff0 | one B bit for the tapped register;
 *   - Dr7 keeps the enable bits the handler set (0x155);
 *   - EFLAGS.RF is clear in the delivered context, as Windows reports it.  A
 *     handler that returns it unchanged is handed the SAME #DB again (measured on
 *     Windows 11 build 26200, 2026-11-10: nine deliveries until the test capped
 *     it); a handler that wants the instruction to run sets RF itself, as a
 *     debugger does.  Both are asserted (phase 3b);
 *   - ContextFlags is 0x1007f (FULL|DEBUG|EXTENDED|FLOATING_POINT|XSTATE), the
 *     XSTATE area behind the context is zero beyond its header, and SSE state
 *     survives a continue through that context;
 *   - the other direction: a data write watchpoint and a trap-flag step are
 *     traps -- EIP is already past the instruction and RF is clear;
 *   - a fault raised inside a handler arrives with flags 0x10;
 *   - retrying it lands on the same EIP, ESP, EBP and fault address;
 *   - the write succeeds once the handler makes the page writable, and
 *     execution continues to the end of the stub.
 *
 * Build: i686-w64-mingw32-gcc -O1 -Wall -o trapstorm.exe trapstorm.c
 * Exit code 0 = every check passed.  2 = watchdog (something stalled).
 *
 * The debug-register emulation has to be on for the process: CX_DR_TRAP=3 in
 * the environment, or a DrTrap value of 3 in its AppDefaults key.  With it off
 * the breakpoints never fire and the watchdog fires instead.
 */

#define __USE_MINGW_ANSI_STDIO 1
#include <windows.h>
#include <stdio.h>
#include <string.h>

/* ---------------------------------------------------------------- results */

static int g_checks, g_pass, g_fail;
static const char *g_where = "start";

static void check(int cond, const char *what, const char *detail)
{
    g_checks++;
    if (cond) { g_pass++; printf("  ok    %s%s%s\n", what, detail && *detail ? "  " : "", detail ? detail : ""); }
    else      { g_fail++; printf("  FAIL  %s%s%s\n", what, detail && *detail ? "  " : "", detail ? detail : ""); }
}

static void where(const char *phase)
{
    g_where = phase;
    printf("\n%s\n", phase);
}

static int finish(void)
{
    printf("\nRESULT: %d/%d checks passed", g_pass, g_checks);
    if (g_fail) printf("  (%d FAILED)", g_fail);
    printf("\n");
    fflush(stdout);
    return g_fail ? 1 : 0;
}

/* --------------------------------------------------------------- watchdog */

static DWORD WINAPI watchdog(LPVOID arg)
{
    (void)arg;
    Sleep(20000);
    printf("\nTIMEOUT: still in \"%s\" after 20 s — the trap was never delivered,\n"
           "         was delivered forever, or the retry never completed.\n"
           "         If no trap ever arrived, the debug-register emulation is off for\n"
           "         this exe: it needs DrTrap=3 (see this folder's README).\n", g_where);
    fflush(stdout);
    ExitProcess(2);
}

/* ------------------------------------------------------- raw SEH handling */

typedef struct seh_frame
{
    struct seh_frame *prev;
    PEXCEPTION_HANDLER handler;
} seh_frame;

/* The frame has to live on the stack: the dispatcher validates every frame
 * against the thread's stack limits and refuses a chain that leaves it. */
static void seh_install(seh_frame *frame, PEXCEPTION_HANDLER h)
{
    __asm__ __volatile__( "movl %%fs:0, %0" : "=r"(frame->prev) );
    frame->handler = h;
    __asm__ __volatile__( "movl %0, %%fs:0" : : "r"(frame) );
}

/* ----------------------------------------------------------- the fixtures */

#define NBLOCKS     4
#define STUB_STRIDE 16

/* The tapped instructions, generated into one page: inc [counter]; ret */
static unsigned char *g_code;
static volatile LONG  g_mark[NBLOCKS];

/* The read-only data the interpreter writes into.  Content is a hex string,
 * the shape of the data such a patch routine goes after. */
static unsigned char *g_blob;
static const char g_blob_text[] = "48D74F78F0D38C2C684FCABC92CC22D6729B";
static unsigned int  g_blob_expect;

static void *g_stub[NBLOCKS];

#define DR7_ARM 0x155   /* L0..L3 + LE, the value a tap set uses */

static void build_stubs(void)
{
    int i;

    g_code = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!g_code) { printf("VirtualAlloc(code) failed %lu\n", GetLastError()); ExitProcess(1); }
    memset(g_code, 0xcc, 0x1000);
    for (i = 0; i < NBLOCKS; i++)
    {
        unsigned char *s = g_code + i * STUB_STRIDE;

        s[0] = 0xff; s[1] = 0x05;                                   /* inc dword ptr [imm32] */
        *(unsigned int *)(s + 2) = (unsigned int)(ULONG_PTR)&g_mark[i];
        s[6] = 0xc3;                                                /* ret */
        g_stub[i] = s;
    }
    FlushInstructionCache(GetCurrentProcess(), g_code, 0x1000);
}

static void build_blob(void)
{
    DWORD old;

    g_blob = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!g_blob) { printf("VirtualAlloc(blob) failed %lu\n", GetLastError()); ExitProcess(1); }
    memcpy(g_blob, g_blob_text, sizeof(g_blob_text));
    g_blob_expect = *(unsigned int *)g_blob ^ 0x1badbabe;   /* what the patch must leave */
    if (!VirtualProtect(g_blob, 0x1000, PAGE_READONLY, &old))
    {
        printf("VirtualProtect(blob, READONLY) failed %lu\n", GetLastError());
        ExitProcess(1);
    }
}

/* The interpreter's patch: one write, to memory that is not writable yet. */
static void __attribute__((noinline)) interp_patch(void)
{
    *(volatile unsigned int *)g_blob ^= 0x1badbabe;
}

/* ------------------------------------------------------------- the phases */

enum
{
    PH_ARM = 0,     /* UD2 taps the stubs, then each stub runs once */
    PH_INTERP,      /* a tap's handler runs the interpreter, which faults */
    PH_REARM,       /* the taps must still be armed after all that */
    PH_REDELIVER,   /* a handler that leaves RF clear is handed the same #DB again */
    PH_WATCH,       /* a data write watchpoint: a trap, no RF */
    PH_TF,          /* a trap-flag single-step: a trap, no RF */
    PH_DONE
};

/* Everything the handler reads or writes must be volatile: it runs
 * asynchronously, and a compiler that keeps one of these in a register across
 * the call that faults would hide the state change from it. */
static volatile LONG g_phase = PH_ARM;

/* what each trap delivered */
static volatile int g_hits[NBLOCKS];
static DWORD g_db_eip[NBLOCKS], g_db_addr[NBLOCKS], g_db_dr6[NBLOCKS];
static DWORD g_db_dr7[NBLOCKS], g_db_efl[NBLOCKS], g_db_ctxf[NBLOCKS];
static DWORD g_ud2_ctxf, g_ud2_efl;
static volatile int g_ud2;

/* the XSTATE area behind each delivered context, and the XMM registers in it */
struct xs_info
{
    int          have;         /* ContextFlags has CONTEXT_XSTATE and the descriptor is sane */
    DWORD        off, len;
    ULONGLONG    mask, cmask;
    unsigned int nonzero;      /* bytes beyond Mask/CompactionMask that are not zero */
    unsigned int first_nz;
};
static struct xs_info g_db_xs[NBLOCKS], g_ud2_xs;
static unsigned char  g_db_xmm[NBLOCKS][128];
static unsigned char  g_ud2_xmm[128];

/* the other direction: traps (data write watchpoint, trap flag) */
#define WATCH_DR7 0x000d0101    /* L0, LE, Dr0 = write (R/W 01), 4 bytes (LEN 11) */
static volatile DWORD g_watch __attribute__((aligned(4)));
static volatile int   g_wp_hits, g_tf_hits;
static DWORD g_wp_eip, g_wp_addr, g_wp_dr6, g_wp_dr7, g_wp_efl, g_wp_ctxf;
static DWORD g_tf_eip, g_tf_addr, g_tf_dr6, g_tf_efl, g_tf_ctxf;

/* what each nested fault delivered */
static volatile int g_av;
static DWORD g_blob_old;
static DWORD g_av_eip[8], g_av_esp[8], g_av_ebp[8], g_av_addr[8];
static DWORD g_av_flags[8], g_av_info0[8], g_av_info1[8];
static volatile int g_in_interp;
static volatile LONG g_db_loops;    /* same tap delivered twice for one hit */
static volatile LONG g_rd_hits;     /* phase 3b: deliveries of the one tapped stub */
static DWORD g_rd_efl[10];
static volatile LONG g_av_total;

static void arm_taps(CONTEXT *ctx)
{
    int i;
    for (i = 0; i < NBLOCKS; i++) ((DWORD *)&ctx->Dr0)[i] = (DWORD)(ULONG_PTR)g_stub[i];
    ctx->Dr7 = DR7_ARM;
}

/* Read the CONTEXT_EX the dispatcher put behind the context.  A 32-bit CONTEXT
 * is 0x2cc bytes and the descriptor follows it; the XSTATE area is wherever
 * XState.Offset says, XState.Length bytes long. */
static void probe_xstate(const CONTEXT *ctx, struct xs_info *x)
{
    const LONG *ex = (const LONG *)((const char *)ctx + sizeof(CONTEXT));
    LONG off = ex[4], len = ex[5];     /* CONTEXT_EX: All{o,l}, Legacy{o,l}, XState{o,l} */
    const unsigned char *xs;
    DWORD i;

    memset(x, 0, sizeof *x);
    if (!(ctx->ContextFlags & 0x40) || len < 64 || len > 8192 || off < 0 || off > 8192) return;
    xs = (const unsigned char *)ex + off;
    x->have = 1;
    x->off  = (DWORD)off;
    x->len  = (DWORD)len;
    x->mask  = *(const ULONGLONG *)xs;
    x->cmask = *(const ULONGLONG *)(xs + 8);
    for (i = 16; i < (DWORD)len; i++)
        if (xs[i]) { if (!x->nonzero++) x->first_nz = i; }
}

static void arm_watch(CONTEXT *ctx)
{
    ((DWORD *)&ctx->Dr0)[0] = (DWORD)(ULONG_PTR)&g_watch;
    ((DWORD *)&ctx->Dr0)[1] = ((DWORD *)&ctx->Dr0)[2] = ((DWORD *)&ctx->Dr0)[3] = 0;
    ctx->Dr7 = WATCH_DR7;
}

static int stub_index(DWORD eip)
{
    int i;
    for (i = 0; i < NBLOCKS; i++) if (eip == (DWORD)(ULONG_PTR)g_stub[i]) return i;
    return -1;
}

static EXCEPTION_DISPOSITION handler(EXCEPTION_RECORD *rec, void *frame,
                                     CONTEXT *ctx, void *dispatch)
{
    (void)frame; (void)dispatch;

    if (rec->ExceptionCode == EXCEPTION_ILLEGAL_INSTRUCTION && g_ud2 == 0)
    {
        /* The tap point.  A protector takes the debug registers from the
         * context it is handed and resumes past the instruction. */
        g_ud2++;
        g_ud2_ctxf = ctx->ContextFlags;
        g_ud2_efl  = ctx->EFlags;
        probe_xstate(ctx, &g_ud2_xs);
        memcpy(g_ud2_xmm, ctx->ExtendedRegisters + 160, sizeof g_ud2_xmm);
        arm_taps(ctx);
        ctx->Eip += 2;                       /* 0f 0b */
        return ExceptionContinueExecution;
    }

    if (rec->ExceptionCode == EXCEPTION_ILLEGAL_INSTRUCTION && g_ud2 == 1 && g_phase == PH_WATCH)
    {
        /* swap the execute taps for one data write watchpoint */
        g_ud2++;
        arm_watch(ctx);
        ctx->Eip += 2;
        return ExceptionContinueExecution;
    }

    if (rec->ExceptionCode == EXCEPTION_SINGLE_STEP && g_phase == PH_WATCH)
    {
        g_wp_hits++;
        g_wp_eip  = ctx->Eip;
        g_wp_addr = (DWORD)(ULONG_PTR)rec->ExceptionAddress;
        g_wp_dr6  = ctx->Dr6;
        g_wp_dr7  = ctx->Dr7;
        g_wp_efl  = ctx->EFlags;
        g_wp_ctxf = ctx->ContextFlags;
        ctx->Dr7 = 0;                        /* one hit is enough */
        return ExceptionContinueExecution;
    }

    if (rec->ExceptionCode == EXCEPTION_SINGLE_STEP && g_phase == PH_TF)
    {
        g_tf_hits++;
        g_tf_eip  = ctx->Eip;
        g_tf_addr = (DWORD)(ULONG_PTR)rec->ExceptionAddress;
        g_tf_dr6  = ctx->Dr6;
        g_tf_efl  = ctx->EFlags;
        g_tf_ctxf = ctx->ContextFlags;
        ctx->EFlags &= ~0x100;               /* one step is enough */
        return ExceptionContinueExecution;
    }

    if (rec->ExceptionCode == EXCEPTION_SINGLE_STEP && g_phase == PH_REDELIVER && stub_index(ctx->Eip) == 0)
    {
        /* Return the context untouched for the first two deliveries; only
         * the third sets RF.  Hardware (and Windows) deliver the same fault
         * until RF is set, so three is the right number. */
        LONG n = g_rd_hits++;
        if (n < 10) g_rd_efl[n] = ctx->EFlags;
        if (n >= 2) ctx->EFlags |= 0x10000;
        if (n >= 8) ctx->Dr7 = 0;                /* cap: a delivery loop */
        return ExceptionContinueExecution;
    }

    if (rec->ExceptionCode == EXCEPTION_SINGLE_STEP)
    {
        int i = stub_index(ctx->Eip);

        if (i < 0 || g_hits[i] > 8)          /* not a tap, or a delivery loop */
        {
            if (i >= 0) InterlockedIncrement(&g_db_loops);
            ctx->Dr7 = 0;
            return ExceptionContinueExecution;
        }
        g_hits[i]++;
        g_db_eip[i]  = ctx->Eip;
        g_db_addr[i] = (DWORD)(ULONG_PTR)rec->ExceptionAddress;
        g_db_dr6[i]  = ctx->Dr6;
        g_db_dr7[i]  = ctx->Dr7;
        g_db_efl[i]  = ctx->EFlags;
        g_db_ctxf[i] = ctx->ContextFlags;
        probe_xstate(ctx, &g_db_xs[i]);
        memcpy(g_db_xmm[i], ctx->ExtendedRegisters + 160, sizeof g_db_xmm[i]);

        if (g_phase == PH_INTERP && i == 0 && g_hits[0] == 2)
        {
            /* The handler does its own work; the write faults inside it. */
            g_in_interp = 1;
            interp_patch();
            g_in_interp = 0;
        }
        /* The context was delivered with RF clear (Windows, wow32_probe.txt).
         * To run the tapped instruction the handler sets RF itself, exactly
         * as a debugger does; leaving it clear re-delivers the same #DB
         * (phase 3b).  An earlier version of this test assumed Windows runs
         * the instruction once without RF; Windows 11 does not. */
        ctx->EFlags |= 0x10000;
        return ExceptionContinueExecution;
    }

    if (rec->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && g_in_interp)
    {
        int n = g_av;

        if (n < 8)
        {
            g_av_eip[n]   = ctx->Eip;
            g_av_esp[n]   = ctx->Esp;
            g_av_ebp[n]   = ctx->Ebp;
            g_av_addr[n]  = (DWORD)(ULONG_PTR)rec->ExceptionAddress;
            g_av_flags[n] = rec->ExceptionFlags;
            g_av_info0[n] = rec->NumberParameters > 0 ? (DWORD)rec->ExceptionInformation[0] : 0xdead;
            g_av_info1[n] = rec->NumberParameters > 1 ? (DWORD)rec->ExceptionInformation[1] : 0xdead;
        }
        g_av++;

        /* Re-arm through this context, as the pattern's handler does after
         * every fault: the registers must survive the continuation. */
        arm_taps(ctx);

        if (n < 2) return ExceptionContinueExecution;   /* same fault again */

        /* Third time: make the page writable the way such a handler does
         * when it means the patch to land, then let the write run. */
        VirtualProtect(g_blob, 0x1000, PAGE_READWRITE, &g_blob_old);
        return ExceptionContinueExecution;
    }

    return ExceptionContinueSearch;
}

/* ------------------------------------------------------------ SSE state */

/* Eight distinct 16-byte values, one per XMM register, seeded per use. */
static void xmm_fill(unsigned char v[128], unsigned seed)
{
    unsigned k;
    for (k = 0; k < 128; k++) v[k] = (unsigned char)(0x11 + seed * 0x29 + k * 7 + (k >> 4) * 0x35);
}

#define XMM_LOAD \
    "movdqu   0(%[in]),%%xmm0\n\t" "movdqu  16(%[in]),%%xmm1\n\t" \
    "movdqu  32(%[in]),%%xmm2\n\t" "movdqu  48(%[in]),%%xmm3\n\t" \
    "movdqu  64(%[in]),%%xmm4\n\t" "movdqu  80(%[in]),%%xmm5\n\t" \
    "movdqu  96(%[in]),%%xmm6\n\t" "movdqu 112(%[in]),%%xmm7\n\t"
#define XMM_STORE \
    "movdqu %%xmm0,  0(%[out])\n\t" "movdqu %%xmm1, 16(%[out])\n\t" \
    "movdqu %%xmm2, 32(%[out])\n\t" "movdqu %%xmm3, 48(%[out])\n\t" \
    "movdqu %%xmm4, 64(%[out])\n\t" "movdqu %%xmm5, 80(%[out])\n\t" \
    "movdqu %%xmm6, 96(%[out])\n\t" "movdqu %%xmm7,112(%[out])\n\t"
/* No xmm clobbers: this target has no SSE as far as the compiler knows, so it
 * never keeps anything in an XMM register and cannot be told one is changed. */
#define XMM_CLOBBER "memory", "cc", "eax", "ecx", "edx"

/* Load XMM0-7, run fn (a tapped stub), read XMM0-7 back. */
static void xmm_call(void *fn, const unsigned char in[128], unsigned char out[128])
{
    __asm__ __volatile__(XMM_LOAD "call *%[fn]\n\t" XMM_STORE
                         : : [fn] "r"(fn), [in] "r"(in), [out] "r"(out) : XMM_CLOBBER);
}

/* The same across a UD2 whose handler resumes past it. */
static void xmm_ud2(const unsigned char in[128], unsigned char out[128])
{
    __asm__ __volatile__(XMM_LOAD ".byte 0x0f, 0x0b\n\t" XMM_STORE
                         : : [in] "r"(in), [out] "r"(out) : XMM_CLOBBER);
}

/* ---------------------------------------------------------------- phases */

static void phase_arm(void)
{
    int i;

    unsigned char xin[NBLOCKS + 1][128], xout[NBLOCKS + 1][128];

    where("phase 1: four execute breakpoints armed from a UD2 handler");
    xmm_fill(xin[NBLOCKS], 9);
    xmm_ud2(xin[NBLOCKS], xout[NBLOCKS]);        /* ud2, with XMM0-7 loaded */
    check(g_ud2 == 1, "the UD2 handler ran once", "");

    for (i = 0; i < NBLOCKS; i++)
    {
        xmm_fill(xin[i], i + 1);
        xmm_call(g_stub[i], xin[i], xout[i]);
    }

    check(g_hits[0] == 1 && g_hits[1] == 1 && g_hits[2] == 1 && g_hits[3] == 1,
          "one #DB per stub execution", "");
    check(g_db_loops == 0, "no stub was delivered twice", "");
    check(g_mark[0] == 1 && g_mark[1] == 1 && g_mark[2] == 1 && g_mark[3] == 1,
          "each stub's instruction ran exactly once", "");

    for (i = 0; i < NBLOCKS; i++)
    {
        char detail[256];
        char what[128];

        snprintf(what, sizeof what, "stub %d", i);
        snprintf(detail, sizeof detail,
                 "eip=%08lx addr=%08lx dr6=%08lx dr7=%03lx efl=%08lx ctxf=%08lx",
                 (unsigned long)g_db_eip[i], (unsigned long)g_db_addr[i],
                 (unsigned long)g_db_dr6[i], (unsigned long)g_db_dr7[i],
                 (unsigned long)g_db_efl[i], (unsigned long)g_db_ctxf[i]);
        check(g_db_addr[i] == (DWORD)(ULONG_PTR)g_stub[i], "ExceptionAddress is the tapped address", detail);
        check(g_db_eip[i] == (DWORD)(ULONG_PTR)g_stub[i], "the trap is a fault, not a trap", "");
        check((g_db_dr6[i] & 0xffff0ff0) == 0xffff0ff0 && (g_db_dr6[i] & 0xf) == (DWORD)(1u << i),
              "Dr6 has one B bit for the tapped register", what);
        check((g_db_dr7[i] & DR7_ARM) == DR7_ARM, "Dr7 keeps the enable bits", "");
        check((g_db_efl[i] & 0x10000) == 0, "EFLAGS.RF is clear in the delivered context", "");
    }
    check(g_db_ctxf[0] == 0x1007f, "ContextFlags is the Windows 32-bit value 0x1007f", "");
    check(g_ud2_ctxf == 0x1007f, "the UD2 context reports the same ContextFlags", "");

    /* The XSTATE area the context advertises must be fully defined. */
    for (i = 0; i < NBLOCKS + 1; i++)
    {
        const struct xs_info *x = i < NBLOCKS ? &g_db_xs[i] : &g_ud2_xs;
        char detail[160], what[64];

        snprintf(what, sizeof what, "the XSTATE descriptor is present (%s)", i < NBLOCKS ? "#DB" : "UD2");
        snprintf(detail, sizeof detail, "off=%lu len=%lu", (unsigned long)x->off, (unsigned long)x->len);
        check(x->have, what, detail);
        if (!x->have) continue;
        snprintf(what, sizeof what, "the XSTATE area is zero past its Mask fields (%s)", i < NBLOCKS ? "#DB" : "UD2");
        snprintf(detail, sizeof detail, "%u of %lu bytes not zero, first at +%u",
                 x->nonzero, (unsigned long)x->len, x->first_nz);
        check(x->nonzero == 0, what, detail);
    }
    if (g_db_xs[0].have)
        printf("  note  XSTATE Mask=%016llx CompactionMask=%016llx%s\n",
               (unsigned long long)g_db_xs[0].mask, (unsigned long long)g_db_xs[0].cmask,
               g_db_xs[0].mask ? "" :
               "  -- Mask 0: the area carries no state; Windows' carries the live AVX/SSE state");

    /* SSE state: continuing through the delivered context must not clobber it,
     * and the context must have reported what was live. */
    {
        int ok = 1, seen = 1;

        for (i = 0; i < NBLOCKS + 1; i++)
            if (memcmp(xin[i], xout[i], 128)) ok = 0;
        check(ok, "XMM0-7 survive a continue through the delivered context", "");
        for (i = 0; i < NBLOCKS; i++)
            if (memcmp(xin[i], g_db_xmm[i], 128)) seen = 0;
        if (memcmp(xin[NBLOCKS], g_ud2_xmm, 128)) seen = 0;
        check(seen, "the delivered context reports the live XMM0-7", "");
    }
}

static void phase_interp(void)
{
    char detail[256];
    unsigned char xin[128], xout[128];

    where("phase 2: the handler writes to read-only data, off a tap");
    xmm_fill(xin, 7);
    xmm_call(g_stub[0], xin, xout);
    check(!memcmp(xin, xout, 128), "XMM0-7 survive the nested faults and the interpreter", "");
    check(g_mark[0] == 2, "the tapped instruction ran once more, not repeatedly", "");

    snprintf(detail, sizeof detail, "faults=%d", g_av);
    check(g_av == 3, "the write faulted, was retried, and was made writable", detail);

    if (g_av >= 3)
    {
        int i, same = 1;

        check((g_av_flags[0] & 0x10) != 0, "the fault arrives with EXCEPTION_NESTED_CALL (0x10)", "");
        check(g_av_info0[0] == 1, "it reports a write fault", "");
        check(g_av_info1[0] == (DWORD)(ULONG_PTR)g_blob, "it reports the data address", "");
        check(g_av_addr[0] == g_av_eip[0], "ExceptionAddress is the faulting instruction", "");
        for (i = 1; i < 3; i++)
        {
            if (g_av_eip[i] != g_av_eip[0] || g_av_esp[i] != g_av_esp[0] ||
                g_av_ebp[i] != g_av_ebp[0] || g_av_addr[i] != g_av_addr[0]) same = 0;
        }
        snprintf(detail, sizeof detail, "eip=%08lx esp=%08lx -> %08lx -> %08lx",
                 (unsigned long)g_av_eip[0], (unsigned long)g_av_esp[0],
                 (unsigned long)g_av_esp[1], (unsigned long)g_av_esp[2]);
        check(same, "every retry lands on the same EIP, ESP, EBP and address", detail);
        check(*(unsigned int *)g_blob == g_blob_expect, "the write landed, once", "");
        check(g_in_interp == 0, "the handler returned and its caller carried on", "");
    }
    snprintf(detail, sizeof detail, "hits[0]=%ld mark[0]=%ld", (long)g_hits[0], (long)g_mark[0]);
    check(g_hits[0] == 2, "the tapped stub trapped again for the interpreter run", detail);
}

static void phase_rearm(void)
{
    where("phase 3: the taps are still armed after the nested faults");
    ((void (*)(void))g_stub[1])();
    check(g_hits[1] == 2, "the second stub trapped again", "");
    check(g_mark[1] == 2 && g_db_loops == 0, "and ran once, not repeatedly", "");
    check(g_db_dr7[1] == g_db_dr7[0], "Dr7 is still what the handler armed", "");
}

/* Phase 3b.  The tapped stub runs once; its handler leaves RF clear twice and
 * sets it the third time, so a faithful delivery shows the same #DB three
 * times and the instruction runs once. */
static void phase_redeliver(void)
{
    LONG before = g_mark[0];
    char detail[256];

    where("phase 3b: RF clear on return means the same #DB again");
    g_rd_hits = 0;
    ((void (*)(void))g_stub[0])();
    snprintf(detail, sizeof detail, "deliveries=%ld (expected 3)  efl=%08lx %08lx %08lx",
             (long)g_rd_hits, (unsigned long)g_rd_efl[0], (unsigned long)g_rd_efl[1], (unsigned long)g_rd_efl[2]);
    check(g_rd_hits == 3, "a handler that leaves RF clear is handed the same #DB again", detail);
    check(g_mark[0] == before + 1, "and the instruction still ran exactly once", "");
}

/* A data write watchpoint is a trap: the CPU reports it after the write, so
 * EIP is the next instruction and RF is not pushed. */
static void phase_watch(void)
{
    char detail[256];
    DWORD after;

    where("phase 4: a data write watchpoint is a trap, not a fault");
    __asm__ __volatile__(".byte 0x0f, 0x0b" ::: "memory");     /* ud2: arm Dr0 on g_watch */
    __asm__ __volatile__("movl $1, %[w]\n\t"
                         "1:\n\t"
                         "movl $1b, %[after]"
                         : [w] "=m"(g_watch), [after] "=r"(after) : : "memory");

    snprintf(detail, sizeof detail, "eip=%08lx addr=%08lx dr6=%08lx dr7=%03lx efl=%08lx ctxf=%08lx",
             (unsigned long)g_wp_eip, (unsigned long)g_wp_addr, (unsigned long)g_wp_dr6,
             (unsigned long)g_wp_dr7, (unsigned long)g_wp_efl, (unsigned long)g_wp_ctxf);
    check(g_wp_hits == 1, "the write raised exactly one #DB", detail);
    check(g_watch == 1, "the write itself completed", "");
    check(g_wp_eip == after, "the trap is delivered past the writing instruction", "");
    check(g_wp_addr == g_wp_eip, "ExceptionAddress is the next instruction", "");
    check((g_wp_dr6 & 0xffff0ff0) == 0xffff0ff0 && (g_wp_dr6 & 0xf) == 1,
          "Dr6 has the B bit of Dr0", "");
    check((g_wp_efl & 0x10000) == 0, "EFLAGS.RF is clear in the delivered context", "");
    check(g_wp_ctxf == 0x1007f, "ContextFlags is 0x1007f", "");
}

/* The trap flag: one instruction runs, then a #DB past it, with no RF. */
static void phase_tf(void)
{
    char detail[256];
    DWORD after;

    where("phase 5: a trap-flag single-step is a trap, not a fault");
    __asm__ __volatile__("pushfl\n\t"
                         "orl $0x100, (%%esp)\n\t"
                         "popfl\n\t"                /* TF takes effect after the next instruction */
                         "nop\n\t"
                         "1:\n\t"
                         "movl $1b, %[after]"
                         : [after] "=r"(after) : : "memory", "cc");

    snprintf(detail, sizeof detail, "eip=%08lx addr=%08lx dr6=%08lx efl=%08lx ctxf=%08lx",
             (unsigned long)g_tf_eip, (unsigned long)g_tf_addr, (unsigned long)g_tf_dr6,
             (unsigned long)g_tf_efl, (unsigned long)g_tf_ctxf);
    check(g_tf_hits == 1, "the step raised exactly one #DB", detail);
    check(g_tf_eip == after, "the trap is delivered past the stepped instruction", "");
    check(g_tf_addr == g_tf_eip, "ExceptionAddress is the next instruction", "");
    check((g_tf_efl & 0x10000) == 0, "EFLAGS.RF is clear in the delivered context", "");
    check(g_tf_ctxf == 0x1007f, "ContextFlags is 0x1007f", "");
    printf("  note  Dr6 after a trap-flag step is %08lx (Windows sets BS, 0x4000)\n", (unsigned long)g_tf_dr6);
}

int main(void)
{
    seh_frame frame;

    setvbuf(stdout, NULL, _IONBF, 0);
    CreateThread(NULL, 0, watchdog, NULL, 0, NULL);

    printf("trapstorm: a self-armed tap whose handler faults on read-only data\n");
    build_stubs();
    build_blob();
    seh_install(&frame, handler);

    phase_arm();
    g_phase = PH_INTERP;
    phase_interp();
    g_phase = PH_REARM;
    phase_rearm();
    g_phase = PH_REDELIVER;
    phase_redeliver();
    g_phase = PH_WATCH;
    phase_watch();
    g_phase = PH_TF;
    phase_tf();

    g_phase = PH_DONE;
    return finish();
}
