/* wow32_arm: arming an execute breakpoint from a 32-bit guest, self and
 * cross-thread, with the tapped code on a page of its own.
 *
 * `drbp_test` case 4 (arm Dr3 on `main`, read it back) and case 6 (arm Dr0 on
 * another thread) both die on this build, and both arm an execute breakpoint
 * on an address that shares its page with code that is about to run.  The
 * emulation takes execute away from the whole page, so the question is
 * whether the arming itself is wrong or living on a stripped page is.
 *
 * phase A  self-arm Dr0 = stub, read Dr0/Dr7 back, disarm
 * phase B  self-arm Dr0 = a function that shares its page with the running
 *          code, check the page still reports its own protection, call it
 * phase C  arm Dr0 = stub on another thread that then calls it: the #DB must
 *          arrive there with the arming context's Dr0/Dr7
 *
 * Nothing game- or protection-specific.
 *
 * Build: i686-w64-mingw32-gcc -O1 -Wall -o wow32_arm.exe wow32_arm.c
 */
#define __USE_MINGW_ANSI_STDIO 1
#include <windows.h>
#include <stdio.h>
#include <string.h>

extern char stub_page[], stub_ret[];
void stub(void);

__asm__(
    /* own page: arm on it without touching the page holding the rest */
    ".section .bs,\"xr\"\n"
    ".p2align 12\n"
    ".globl _stub, _stub_page, _stub_ret\n"
    "_stub_page:\n"
    "_stub: nop\n    nop\n    nop\n"
    "_stub_ret: ret\n"
    ".p2align 12\n"
    ".text\n");

static volatile LONG shared_calls;
/* shares its page with main(): the caller is running on the page that gets
 * its execute taken away.  Calls out (E8) on purpose: a single-stepped
 * 32-bit "call rel32" pushes 8 bytes under Rosetta, which used to leave the
 * caller's stack 4 bytes off for good. */
static void __attribute__((noinline)) shared_fn(void) { InterlockedIncrement(&shared_calls); }

static HANDLE ev_ready, ev_go;
static volatile LONG hits_a, hits_b, hits_c;
static volatile LONG verbose;
static int phase;

static int set_drs(DWORD dr0, DWORD dr7)
{
    CONTEXT c;
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    c.Dr0 = dr0;
    c.Dr7 = dr7;
    return SetThreadContext(GetCurrentThread(), &c) != 0;
}

static void read_drs(DWORD *dr0, DWORD *dr7)
{
    CONTEXT c;
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    *dr0 = *dr7 = 0;
    if (GetThreadContext(GetCurrentThread(), &c)) { *dr0 = c.Dr0; *dr7 = c.Dr7; }
}

static LONG CALLBACK veh(EXCEPTION_POINTERS *e)
{
    CONTEXT *c = e->ContextRecord;
    DWORD ip = c->Eip;

    if (e->ExceptionRecord->ExceptionCode != EXCEPTION_SINGLE_STEP)
        return EXCEPTION_CONTINUE_SEARCH;
    if (phase == 1 && ip == (DWORD)(ULONG_PTR)stub)  { hits_a++; c->Dr7 &= ~1u; return EXCEPTION_CONTINUE_EXECUTION; }
    if (phase == 2 && ip == (DWORD)(ULONG_PTR)shared_fn) { hits_b++; c->Dr7 &= ~1u; return EXCEPTION_CONTINUE_EXECUTION; }
    if (phase == 3)
    {
        hits_c++;
        if (verbose) printf("    [#DB on the other thread Dr0=%08lx Dr7=%08lx Eip=%08lx]\n",
                            (unsigned long)c->Dr0, (unsigned long)c->Dr7, (unsigned long)ip);
        c->Dr7 &= ~1u;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_EXECUTION;
}

static DWORD WINAPI worker(LPVOID arg)
{
    (void)arg;
    SetEvent(ev_ready);
    WaitForSingleObject(ev_go, 5000);
    ((void (*)(void))stub)();
    return 0;
}

int main(void)
{
    DWORD dr0, dr7;

    setvbuf(stdout, NULL, _IONBF, 0);
    AddVectoredExceptionHandler(1, veh);

    phase = 1;
    printf("[A] self-arm Dr0=stub (its own page) ... set=%d ", set_drs((DWORD)(ULONG_PTR)stub, 0x401));
    read_drs(&dr0, &dr7);
    printf("read back Dr0=%08lx Dr7=%08lx ", (unsigned long)dr0, (unsigned long)dr7);
    ((void (*)(void))stub)();
    printf("hits=%ld -> %s\n", (long)hits_a,
           (dr0 == (DWORD)(ULONG_PTR)stub && hits_a == 1) ? "OK" : "MISMATCH");
    set_drs(0, 0x400);
    phase = 0;

    phase = 2;
    {
        MEMORY_BASIC_INFORMATION m0, m1;
        int set;

        VirtualQuery((void *)shared_fn, &m0, sizeof m0);
        printf("[B] self-arm Dr0=shared_fn (shares %08lx with main, prot %02lx) ... ",
               (unsigned long)((DWORD)(ULONG_PTR)shared_fn & ~0xfffu), (unsigned long)m0.Protect);
        set = set_drs((DWORD)(ULONG_PTR)shared_fn, 0x401);
        VirtualQuery((void *)shared_fn, &m1, sizeof m1);
        printf("set=%d ", set);
        read_drs(&dr0, &dr7);
        printf("read back Dr0=%08lx Dr7=%08lx prot now %02lx ", (unsigned long)dr0, (unsigned long)dr7,
               (unsigned long)m1.Protect);
        shared_fn();
        printf("hits=%ld calls=%ld -> %s\n", (long)hits_b, (long)shared_calls,
               (dr0 == (DWORD)(ULONG_PTR)shared_fn && hits_b == 1 && shared_calls == 1 &&
                m1.Protect == m0.Protect) ? "OK" : "MISMATCH");
        set_drs(0, 0x400);
        phase = 0;
    }

    /* C: another thread, armed by this one, then it calls the stub */
    phase = 3;
    verbose = 1;
    ev_ready = CreateEventA(NULL, FALSE, FALSE, NULL);
    ev_go    = CreateEventA(NULL, FALSE, FALSE, NULL);
    {
        CONTEXT c;
        HANDLE t;
        DWORD tid = 0;
        int armed;

        memset(&c, 0, sizeof c);
        c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
        c.Dr0 = (DWORD)(ULONG_PTR)stub;
        c.Dr7 = 0x401;
        t = CreateThread(NULL, 0, worker, NULL, 0, &tid);
        WaitForSingleObject(ev_ready, 5000);
        armed = SetThreadContext(t, &c) ? 1 : 0;
        printf("[C] arm Dr0=stub on thread %04lx ... set=%d ", (unsigned long)tid, armed);
        memset(&c, 0, sizeof c);
        c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
        if (GetThreadContext(t, &c)) printf("read back Dr0=%08lx Dr7=%08lx\n",
                                            (unsigned long)c.Dr0, (unsigned long)c.Dr7);
        else printf("read back failed\n");
        SetEvent(ev_go);
        WaitForSingleObject(t, 10000);
        CloseHandle(t);
        printf("hits=%ld -> %s\n", (long)hits_c, hits_c == 1 ? "OK" : "MISMATCH");
    }
    return 0;
}
