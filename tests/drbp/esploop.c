/* esploop: is the guest stack the same on every one of N deliveries of the
 * same execute breakpoint from the same call site?
 *
 * A handler armed from a UD2 arms Dr0 on `tapped`.  `tapped` is then called
 * N times from one loop.  Each call delivers one #DB, and the handler records
 * the delivered Esp and returns the context exactly as it was handed to it.
 * If the delivery is faithful the Esp is identical every time; a drift means
 * the delivery itself is leaking guest stack.
 *
 * Nothing game-specific: this is the tap pattern on its own.
 *
 * i686-w64-mingw32-gcc -O1 -o esploop.exe esploop.c
 */
#include <windows.h>
#include <stdio.h>

#define N 40

extern char ud2_at[], tapped[], after_tapped[];
static DWORD esp_seen[N], ebp_seen[N], eip_seen[N];
static DWORD ud2_ctx_esp;
static volatile int hits, ud2;
static FILE *out;

__asm__(
    ".section .bpcode,\"xr\"\n"
    ".p2align 12\n"
    ".globl _ud2_at, _tapped, _after_tapped\n"
    "_ud2_at: ud2\n"
    "    nop\n"
    "_tapped: nop\n     nop\n     nop\n"
    "_after_tapped: ret\n"
    ".p2align 12\n"
    ".text\n");

static LONG CALLBACK handler(EXCEPTION_POINTERS *e)
{
    CONTEXT *c = e->ContextRecord;

    if (e->ExceptionRecord->ExceptionCode == EXCEPTION_ILLEGAL_INSTRUCTION && !ud2++)
    {
        c->Dr0 = (DWORD)(ULONG_PTR)tapped;
        c->Dr7 = 0x105;
        c->Eip += 2;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (e->ExceptionRecord->ExceptionCode == EXCEPTION_SINGLE_STEP)
    {
        if (hits < N)
        {
            esp_seen[hits] = c->Esp;
            ebp_seen[hits] = c->Ebp;
            eip_seen[hits] = c->Eip;
        }
        hits++;
        return EXCEPTION_CONTINUE_EXECUTION;   /* context as delivered */
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static void call_tapped(void)
{
    void (*f)(void) = (void (*)(void))tapped;
    f();
}

int main(void)
{
    char path[MAX_PATH], *slash;
    int i, drift = 0;

    GetModuleFileNameA(NULL, path, sizeof(path));
    slash = strrchr(path, '\\');
    strcpy(slash ? slash + 1 : path, "esploop.txt");
    if (!(out = fopen(path, "w"))) return 1;

    AddVectoredExceptionHandler(1, handler);
    ud2_ctx_esp = 0;
    __asm__ volatile ("ud2" ::: "memory");   /* arm from a handler context */
    (void)ud2_ctx_esp;

    for (i = 0; i < N; i++) call_tapped();

    for (i = 0; i < N; i++)
    {
        if (i) drift = (int)esp_seen[i] - (int)esp_seen[0];
        fprintf(out, "hit %2d eip=%08lx esp=%08lx ebp=%08lx  drift=%+d\n", i,
                (unsigned long)eip_seen[i], (unsigned long)esp_seen[i],
                (unsigned long)ebp_seen[i], drift);
    }
    fprintf(out, "hits=%d expected=%d\n", hits, N);
    fprintf(out, "RESULT: %s\n", (hits == N && (int)esp_seen[N-1] == (int)esp_seen[0]) ? "PASS" : "FAIL");
    fclose(out);
    printf("Results are in %s\n", path);
    return 0;
}
