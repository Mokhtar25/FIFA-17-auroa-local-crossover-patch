/* wow32_ctx: a 32-bit guest's view of its own CONTEXT through
 * GetThreadContext/SetThreadContext, byte for byte.
 *
 * `drbp_test` case 4 reads back something that is not what it wrote through
 * these two calls, and case 6 (arming another thread) takes the process down.
 * Both are easier to reason about with the raw struct than with one printed
 * field, so this dumps the first 0x40 bytes as dwords, before and after.
 *
 * Nothing game- or protection-specific.
 *
 * Build: i686-w64-mingw32-gcc -O1 -Wall -o wow32_ctx.exe wow32_ctx.c
 */
#define __USE_MINGW_ANSI_STDIO 1
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>

static void __attribute__((noinline)) target_stub(void) { }

static void dump(const char *tag, const CONTEXT *c)
{
    const unsigned char *p = (const unsigned char *)c;
    int i;

    printf("%s ContextFlags=%08lx\n", tag, (unsigned long)c->ContextFlags);
    for (i = 0; i < 0x40; i += 4)
    {
        DWORD v;
        memcpy(&v, p + i, 4);
        printf("  [%02x] %08lx%s\n", i, (unsigned long)v,
               i == 0x00 ? "  (ContextFlags)" : i == 0x04 ? "  (Dr0)" :
               i == 0x08 ? "  (Dr1)" : i == 0x0c ? "  (Dr2)" :
               i == 0x10 ? "  (Dr3)" : i == 0x14 ? "  (Dr6)" :
               i == 0x18 ? "  (Dr7)" : "");
    }
}

int main(void)
{
    CONTEXT c;
    DWORD st;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("wow32_ctx: sizeof(CONTEXT)=%lu\n", (unsigned long)sizeof(CONTEXT));
    printf("offsets: Dr0=%lu Dr1=%lu Dr2=%lu Dr3=%lu Dr6=%lu Dr7=%lu Eip=%lu\n",
           (unsigned long)offsetof(CONTEXT, Dr0),
           (unsigned long)offsetof(CONTEXT, Dr1),
           (unsigned long)offsetof(CONTEXT, Dr2),
           (unsigned long)offsetof(CONTEXT, Dr3),
           (unsigned long)offsetof(CONTEXT, Dr6),
           (unsigned long)offsetof(CONTEXT, Dr7),
           (unsigned long)offsetof(CONTEXT, Eip));

    /* 1. plain read of the debug registers, struct prefilled with a pattern */
    memset(&c, 0xC5, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    st = GetThreadContext(GetCurrentThread(), &c);
    printf("\n-- GetThreadContext(CONTEXT_DEBUG_REGISTERS) -> %lu\n",
           (unsigned long)st);
    dump("get", &c);

    /* 2. write a known pattern, then read it back */
    memset(&c, 0xC5, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    c.Dr0 = 0x11111111;
    c.Dr1 = 0x22222222;
    c.Dr2 = 0x33333333;
    c.Dr3 = 0x44444444;
    c.Dr6 = 0x66666666;
    c.Dr7 = 0x00000555;              /* legal bits + the reserved bit 10 */
    st = SetThreadContext(GetCurrentThread(), &c);
    printf("\n-- SetThreadContext(Dr0..Dr3,Dr6,Dr7) -> %lu\n", (unsigned long)st);

    memset(&c, 0xA5, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    st = GetThreadContext(GetCurrentThread(), &c);
    printf("-- GetThreadContext after that write -> %lu\n", (unsigned long)st);
    dump("get", &c);
    printf("  named: Dr0=%08lx Dr1=%08lx Dr2=%08lx Dr3=%08lx Dr6=%08lx Dr7=%08lx\n",
           (unsigned long)c.Dr0, (unsigned long)c.Dr1, (unsigned long)c.Dr2,
           (unsigned long)c.Dr3, (unsigned long)c.Dr6, (unsigned long)c.Dr7);

    /* 3. arm a *code* address (execute breakpoint) and read it back: this is
     * the shape drbp_test case 4 uses, and the one that comes back wrong */
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    c.Dr3 = (DWORD)(ULONG_PTR)target_stub;
    c.Dr7 = 0x440;                   /* L3 + reserved bit 10 */
    st = SetThreadContext(GetCurrentThread(), &c);
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    GetThreadContext(GetCurrentThread(), &c);
    printf("\n-- arm Dr3=%08lx (execute) Dr7=0x440 -> set %lu, read back"
           " Dr0=%08lx Dr3=%08lx Dr7=%08lx\n",
           (unsigned long)(DWORD)(ULONG_PTR)target_stub, (unsigned long)st,
           (unsigned long)c.Dr0, (unsigned long)c.Dr3, (unsigned long)c.Dr7);
    memset(&c, 0, sizeof c);
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    SetThreadContext(GetCurrentThread(), &c);

    /* 4. a control-only read, for comparison: this path is known good */
    memset(&c, 0xC5, sizeof c);
    c.ContextFlags = CONTEXT_CONTROL;
    st = GetThreadContext(GetCurrentThread(), &c);
    printf("\n-- GetThreadContext(CONTEXT_CONTROL) -> %lu Eip=%08lx Esp=%08lx"
           " Ebp=%08lx EFlags=%08lx SegCs=%04lx\n",
           (unsigned long)st, (unsigned long)c.Eip, (unsigned long)c.Esp,
           (unsigned long)c.Ebp, (unsigned long)c.EFlags,
           (unsigned long)c.SegCs);
    return 0;
}
