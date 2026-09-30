/* End-to-end check for the generic FIFA 16 dstfix in ntdll.
 *
 * The game's protector hands memmove the 64-bit complement of a real buffer
 * pointer.  This writes through such a value on purpose: the write faults,
 * ntdll (CX_FIFA16_DSTFIX set) must rewrite the register holding the bad
 * value to ~target before the guest VEH runs, and the retried instruction
 * must land in the real buffer.
 *
 *   exit 0  repaired (register rewritten and buffer written)
 *   exit 1  the handler still saw the bad value
 *   exit 2  allocation failed
 */
#include <windows.h>
#include <stdio.h>

static int fixed;

static LONG CALLBACK veh( EXCEPTION_POINTERS *ep )
{
    CONTEXT *c = ep->ContextRecord;
    ULONG_PTR target;

    if (ep->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION ||
        ep->ExceptionRecord->NumberParameters < 2)
        return EXCEPTION_CONTINUE_SEARCH;

    target = ep->ExceptionRecord->ExceptionInformation[1];
    printf( "av write=%llu target=%016llx rax=%016llx rcx=%016llx rsi=%016llx rdi=%016llx\n",
            (unsigned long long)ep->ExceptionRecord->ExceptionInformation[0],
            (unsigned long long)target,
            (unsigned long long)c->Rax, (unsigned long long)c->Rcx,
            (unsigned long long)c->Rsi, (unsigned long long)c->Rdi );
    fflush( stdout );

    if (c->Rax == ~target || c->Rbx == ~target || c->Rcx == ~target ||
        c->Rdx == ~target || c->Rsi == ~target || c->Rdi == ~target ||
        c->Rbp == ~target || c->R8 == ~target || c->R9 == ~target ||
        c->R10 == ~target || c->R11 == ~target || c->R12 == ~target ||
        c->R13 == ~target || c->R14 == ~target || c->R15 == ~target) fixed = 1;
    return EXCEPTION_CONTINUE_EXECUTION;
}

int main( void )
{
    char *buf = VirtualAlloc( NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE );
    ULONG_PTR bad;
    int rc;

    if (!buf) { printf( "VirtualAlloc failed\n" ); return 2; }
    bad = ~(ULONG_PTR)buf;
    printf( "buf=%p bad=%p\n", buf, (void *)bad );
    fflush( stdout );

    AddVectoredExceptionHandler( 1, veh );
    __asm__ volatile ( "movb $0x5a, (%0)" : : "r" (bad) : "memory" );

    rc = (fixed && buf[0] == 0x5a) ? 0 : 1;
    printf( "after: buf[0]=%02x fixed=%d rc=%d\n", (unsigned char)buf[0], fixed, rc );
    return rc;
}
