/*
 * kuser_perf.c — cost of KUSER_SHARED_DATA reads while a read+write
 * watchpoint is armed on that page by some other thread.
 *
 * Hardware debug registers cost nothing for addresses they do not watch.
 * An emulation by page protection makes the whole 4 KB page fault instead,
 * so every time query that reads KUSER (QueryPerformanceCounter,
 * GetTickCount, GetSystemTimeAsFileTime, a direct read) pays for a fault.
 *
 * A parked worker thread arms dr0..dr3 = 0x7ffe0270, dr7 = 0x3330055
 * (rw=11, LEN=1 -- the pattern runtime protection systems use). The main
 * thread, which has nothing armed, times each query unarmed and armed.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -Wall -o kuser_perf.exe kuser_perf.c
 * Output: ns per call for each query, unarmed / armed, and the ratio.
 * Exit 1 = armed is more than 5x slower than unarmed for a query that goes
 * through a syscall stub (QueryPerformanceCounter, GetSystemTimeAsFileTime):
 * those stubs read 0x7ffe0308, and crossover-26.3-drtrap-syscall-stub.patch
 * stops them faulting.  GetTickCount and the direct read load the time field
 * off the page itself; they still fault and are reported, not judged.
 */

#define __USE_MINGW_ANSI_STDIO 1
#include <windows.h>
#include <stdio.h>
#include <stdint.h>

#define WATCH 0x7ffe0270ULL
#define N     200000

static HANDLE armed_evt, done_evt;

static DWORD WINAPI worker( void *arg )
{
    CONTEXT c = { .ContextFlags = CONTEXT_DEBUG_REGISTERS };
    c.Dr0 = c.Dr1 = c.Dr2 = c.Dr3 = WATCH;
    c.Dr7 = 0x3330055;
    if (arg && !SetThreadContext( GetCurrentThread(), &c ))
        printf( "SetThreadContext failed: %lu\n", GetLastError() );
    SetEvent( armed_evt );
    WaitForSingleObject( done_evt, INFINITE );
    c.Dr7 = 0;
    if (arg) SetThreadContext( GetCurrentThread(), &c );
    return 0;
}

static LONG CALLBACK veh( EXCEPTION_POINTERS *ep )
{
    /* no watched byte is read, so nothing should arrive; count if it does */
    if (ep->ExceptionRecord->ExceptionCode == EXCEPTION_SINGLE_STEP)
    {
        static volatile LONG stray;
        InterlockedIncrement( &stray );
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static volatile uint64_t sink;

static double ns_per( int which )
{
    LARGE_INTEGER f, t0, t1, q;
    FILETIME ft;
    int i;

    QueryPerformanceFrequency( &f );
    QueryPerformanceCounter( &t0 );
    for (i = 0; i < N; i++)
    {
        switch (which)
        {
        case 0: QueryPerformanceCounter( &q ); sink += q.QuadPart; break;
        case 1: sink += GetTickCount(); break;
        case 2: GetSystemTimeAsFileTime( &ft ); sink += ft.dwLowDateTime; break;
        case 3: sink += *(volatile ULONG *)0x7ffe0320; break; /* TickCountLow */
        }
    }
    QueryPerformanceCounter( &t1 );
    return (double)(t1.QuadPart - t0.QuadPart) * 1e9 / f.QuadPart / N;
}

static void run( int armed, double out[4] )
{
    HANDLE t;
    int w;

    armed_evt = CreateEventW( NULL, TRUE, FALSE, NULL );
    done_evt = CreateEventW( NULL, TRUE, FALSE, NULL );
    t = CreateThread( NULL, 0, worker, (void *)(intptr_t)armed, 0, NULL );
    WaitForSingleObject( armed_evt, INFINITE );
    for (w = 0; w < 4; w++) out[w] = ns_per( w );
    SetEvent( done_evt );
    WaitForSingleObject( t, INFINITE );
    CloseHandle( t ); CloseHandle( armed_evt ); CloseHandle( done_evt );
}

int main( void )
{
    static const char *name[4] = { "QueryPerformanceCounter", "GetTickCount",
                                   "GetSystemTimeAsFileTime", "direct read 0x7ffe0320" };
    double off[4], on[4];
    int w, bad = 0;

    setvbuf( stdout, NULL, _IONBF, 0 );
    AddVectoredExceptionHandler( 1, veh );
    run( 0, off );
    run( 1, on );
    printf( "%-26s %12s %12s %8s\n", "query", "unarmed ns", "armed ns", "ratio" );
    for (w = 0; w < 4; w++)
    {
        double r = on[w] / (off[w] > 0 ? off[w] : 1);
        printf( "%-26s %12.1f %12.1f %7.1fx\n", name[w], off[w], on[w], r );
        if ((w == 0 || w == 2) && r > 5) bad = 1;
    }
    printf( "%s\n", bad ? "RED: syscalls fault while a KUSER watchpoint is armed" : "GREEN" );
    return bad;
}
