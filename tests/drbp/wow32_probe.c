/* wow32_probe: what a 32-bit exception handler sees of the debug registers.
 *
 * Runs the same steps on Windows and under Wine and writes one line per
 * exception to wow32_probe.txt beside the exe, so the two can be diffed:
 *
 *   1. An illegal instruction, whose handler arms four execute breakpoints
 *      through its CONTEXT (no SetThreadContext).
 *   2. Each breakpoint in turn: which Dr6 bits are set, whether Dr6 is sticky,
 *      and what clearing it in the CONTEXT does.
 *   3. A write to read-only data with the breakpoints still armed, continued
 *      once unchanged and then skipped.
 *
 * Contains nothing game- or protection-specific.
 *
 * Build: i686-w64-mingw32-gcc -O1 -Wall -static -o wow32_probe.exe wow32_probe.c
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

extern char ud2_at[], l0[], l1[], l2[], l3[], wr[], after_wr[];
void stub(void);

__asm__(
    /* A page of its own: the emulation takes execute away from the whole page
     * holding a breakpoint, and the handler must not share it. */
    ".section .bpcode,\"xr\"\n"
    ".p2align 12\n"
    ".globl _stub, _ud2_at, _l0, _l1, _l2, _l3, _wr, _after_wr\n"
    "_stub:\n"
    "_ud2_at: ud2\n"
    "    nop\n    nop\n"
    "_l0: nop\n    nop\n"
    "_l1: nop\n    nop\n"
    "_l2: nop\n    nop\n"
    "_l3: nop\n    nop\n"
    "_done: ret\n"
    "_wr: movl %eax,(%edi)\n"
    "_after_wr: jmp _done\n"
    ".p2align 12\n"
    ".text\n");

static const volatile char read_only[32] = "this lives in read-only data";
static FILE *out;
static int av_count, total;

static long off(DWORD a)
{
    return a ? (long)(a - (DWORD)(ULONG_PTR)l0) : 0;
}

static void dump(const char *what, const EXCEPTION_POINTERS *e)
{
    const CONTEXT *c = e->ContextRecord;
    const EXCEPTION_RECORD *r = e->ExceptionRecord;

    fprintf(out, "%-10s code=%08lx eip=l0%+ld flags=%08lx eflags=%08lx "
            "dr0=l0%+ld dr1=l0%+ld dr2=l0%+ld dr3=l0%+ld dr6=%08lx dr7=%08lx",
            what, r->ExceptionCode, off(c->Eip), c->ContextFlags, c->EFlags,
            off(c->Dr0), off(c->Dr1), off(c->Dr2), off(c->Dr3), c->Dr6, c->Dr7);
    if (r->ExceptionCode == EXCEPTION_ACCESS_VIOLATION)
        fprintf(out, " access=%lu", (unsigned long)r->ExceptionInformation[0]);
    fputc('\n', out);
    /* second line, so the first stays diffable against older captures: what
     * a handler sees beyond debug registers -- the segment selectors (Windows
     * wow64: cs=23 ss/ds/es=2b fs=53 gs=2b; macOS Rosetta differs) and the
     * exception record itself */
    fprintf(out, "           segs cs=%04lx ss=%04lx ds=%04lx es=%04lx fs=%04lx gs=%04lx"
            "  rec: addr=l0%+ld recflags=%lx nparams=%lu",
            c->SegCs, c->SegSs, c->SegDs, c->SegEs, c->SegFs, c->SegGs,
            off((DWORD)(ULONG_PTR)r->ExceptionAddress), r->ExceptionFlags,
            (unsigned long)r->NumberParameters);
    if (r->ExceptionCode == EXCEPTION_ACCESS_VIOLATION)
        fprintf(out, " info1=%08lx", (unsigned long)r->ExceptionInformation[1]);
    fputc('\n', out);
    fflush(out);
}

static LONG CALLBACK handler(EXCEPTION_POINTERS *e)
{
    CONTEXT *c = e->ContextRecord;
    DWORD code = e->ExceptionRecord->ExceptionCode;
    char *ip = (char *)(ULONG_PTR)c->Eip;

    if (++total > 40) { c->Dr7 = 0; c->Eip = (DWORD)(ULONG_PTR)after_wr; return EXCEPTION_CONTINUE_EXECUTION; }

    if (code == EXCEPTION_ILLEGAL_INSTRUCTION && ip == ud2_at)
    {
        dump("ud2", e);
        c->Dr0 = (DWORD)(ULONG_PTR)l0;
        c->Dr1 = (DWORD)(ULONG_PTR)l1;
        c->Dr2 = (DWORD)(ULONG_PTR)l2;
        c->Dr3 = (DWORD)(ULONG_PTR)l3;
        c->Dr7 = 0x555;
        c->Eip += 2;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (code == EXCEPTION_SINGLE_STEP && ip == l0)
    {
        dump("hit-l0", e);          /* then straight onto the next one, Dr6 left alone */
        c->Eip = (DWORD)(ULONG_PTR)l1;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (code == EXCEPTION_SINGLE_STEP && ip == l1)
    {
        dump("hit-l1", e);          /* sticky Dr6 would show B0 here too */
        c->Dr6 = 0;
        c->Eip = (DWORD)(ULONG_PTR)l2;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (code == EXCEPTION_SINGLE_STEP && ip == l2)
    {
        dump("hit-l2", e);          /* after clearing Dr6 in the CONTEXT */
        c->EFlags |= 0x10000;       /* RF: run the instruction, fall through to l3 */
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (code == EXCEPTION_SINGLE_STEP && ip == l3)
    {
        dump("hit-l3", e);
        c->Edi = (DWORD)(ULONG_PTR)read_only;
        c->Eip = (DWORD)(ULONG_PTR)wr;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (code == EXCEPTION_ACCESS_VIOLATION && ip == wr)
    {
        dump(av_count ? "av-again" : "av-first", e);
        if (av_count++ == 0)
            return EXCEPTION_CONTINUE_EXECUTION;    /* unchanged: must fault again */
        c->Dr0 = c->Dr1 = c->Dr2 = c->Dr3 = 0;
        c->Dr7 = 0;
        c->Eip = (DWORD)(ULONG_PTR)after_wr;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    dump("other", e);
    return EXCEPTION_CONTINUE_SEARCH;
}

static void read_back(const char *what)
{
    CONTEXT c;

    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    if (!GetThreadContext(GetCurrentThread(), &c))
    {
        fprintf(out, "%-10s GetThreadContext failed %lu\n", what, GetLastError());
        return;
    }
    fprintf(out, "%-10s flags=%08lx dr0=l0%+ld dr1=l0%+ld dr2=l0%+ld dr3=l0%+ld dr6=%08lx dr7=%08lx\n",
            what, c.ContextFlags, off(c.Dr0), off(c.Dr1), off(c.Dr2), off(c.Dr3), c.Dr6, c.Dr7);
    fflush(out);
}

int main(void)
{
    char path[MAX_PATH], *slash;
    BOOL wow64 = FALSE;
    OSVERSIONINFOA v;

    GetModuleFileNameA(NULL, path, sizeof(path));
    slash = strrchr(path, '\\');
    strcpy(slash ? slash + 1 : path, "wow32_probe.txt");
    if (!(out = fopen(path, "w"))) return 1;

    IsWow64Process(GetCurrentProcess(), &wow64);
    v.dwOSVersionInfoSize = sizeof(v);
    GetVersionExA(&v);
    fprintf(out, "wow32_probe 1  windows %lu.%lu build %lu  wow64=%d  wine=%d\n",
            v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber, wow64,
            GetProcAddress(GetModuleHandleA("ntdll.dll"), "wine_get_version") != NULL);

    AddVectoredExceptionHandler(1, handler);
    read_back("before");
    stub();
    read_back("after");
    fprintf(out, "done exceptions=%d av=%d\n", total, av_count);
    fclose(out);
    printf("Results are in %s\n", path);
    return 0;
}
