/*
 * profile_probe.c -- what CrossOver-FIFA game profile did this process get?
 *
 * patches/crossover-26.3-game-profiles.patch makes the unix ntdll pick
 * CX_DR_TRAP, CX_TOPDOWN_LIMIT and CX_FIFA16_DSTFIX by the main exe's file
 * name. This program is copied under the names the table knows (fifa15.exe,
 * FIFA17.exe, ...) and under names it does not (Aurora.exe, game.exe), and
 * reports what each copy sees from the inside, using documented Win32
 * behaviour only:
 *
 *   topdown  address of a MEM_TOP_DOWN VirtualAlloc. 0x1FFxx0000 means
 *            CX_TOPDOWN_LIMIT=0x1ffffffff took; 0x7ff... means no limit.
 *   pae      IsProcessorFeaturePresent(PF_PAE_ENABLED). Session-wide: set by
 *            the process that booted the wineserver session (CX_PF_PAE=1 or a
 *            bare CX_DR_TRAP=3 in its environment).
 *   selfbp   SINGLE_STEP hits from an execute breakpoint this thread armed on
 *            itself. 1 only under CX_DR_TRAP=3.
 *   xbp      hits from an execute breakpoint armed on another thread. 1 under
 *            CX_DR_TRAP=2 or 3, 0 under 0. Together with selfbp this tells
 *            all three modes apart.
 *   dstfix   a byte store through the complement of a valid pointer (what
 *            FIFA 16's protector does). "fixed" = the access violation reached
 *            the handler with the register already rewritten to the real
 *            address (CX_FIFA16_DSTFIX on); "raw" = it did not.
 *
 *   profile_probe.exe                print one PROBE line
 *   profile_probe.exe --spawn <exe>  print one, then run <exe> (quoted, so a
 *                                    path with spaces works) and wait for it
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -Wall -municode -o profile_probe.exe profile_probe.c
 */

#define __USE_MINGW_ANSI_STDIO 1
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#ifndef PF_PAE_ENABLED
#define PF_PAE_ENABLED 9
#endif

#define DR7_L0     (1ULL << 0)
#define DR7_RES10  (1ULL << 10)

static volatile LONG g_phase;        /* 1 = self-armed, 2 = cross-thread */
static volatile LONG g_self_hits, g_x_hits, g_other_ss;
static volatile LONG g_av_seen, g_av_fixed;
static volatile ULONG_PTR g_av_real;
static HANDLE g_ev_ready, g_ev_go;

/* The breakpoint target is a lone "ret" on a page of its own. CX_DR_TRAP=2
 * takes execute access away from the whole page and consumes its one shot on
 * the first instruction run there, so nothing else may live on it. */
static void (*volatile g_bp_fp)(void);
#define bp_target ((void *)g_bp_fp)

static LONG CALLBACK veh( PEXCEPTION_POINTERS ep )
{
    PCONTEXT ctx = ep->ContextRecord;
    DWORD code = ep->ExceptionRecord->ExceptionCode;

    if (code == EXCEPTION_SINGLE_STEP)
    {
        if (ctx->Rip == (DWORD64)(uintptr_t)bp_target && g_phase == 1) g_self_hits++;
        else if (ctx->Rip == (DWORD64)(uintptr_t)bp_target && g_phase == 2) g_x_hits++;
        else g_other_ss++;
        ctx->Dr7 = (ctx->Dr7 & ~DR7_L0) | DR7_RES10;
        ctx->EFlags &= ~0x100;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (code == EXCEPTION_ACCESS_VIOLATION && g_av_real)
    {
        g_av_seen++;
        if (ctx->Rdi == g_av_real) g_av_fixed++;   /* ntdll rewrote it */
        else ctx->Rdi = g_av_real;                 /* do it ourselves */
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static BOOL set_dr0( HANDLE thread, DWORD64 dr0, DWORD64 dr7 )
{
    CONTEXT c;

    memset( &c, 0, sizeof(c) );
    c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    c.Dr0 = dr0;
    c.Dr7 = dr7;
    return SetThreadContext( thread, &c );
}

static DWORD WINAPI xbp_thread( LPVOID arg )
{
    (void)arg;
    SetEvent( g_ev_ready );
    WaitForSingleObject( g_ev_go, 5000 );
    g_phase = 2;
    g_bp_fp();
    g_phase = 0;
    return 0;
}

static const char *test_dstfix(void)
{
    volatile BYTE *buf = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
    ULONG_PTR bad;

    if (!buf) return "noalloc";
    g_av_real = (ULONG_PTR)buf;
    bad = ~(ULONG_PTR)buf;
    __asm__ volatile( "movq %0, %%rdi\n\tmovb $0x5a, (%%rdi)" :: "r" (bad) : "rdi", "memory" );
    g_av_real = 0;
    if (!g_av_seen) return "nofault";
    if (buf[0] != 0x5a) return "lost";
    return g_av_fixed ? "fixed" : "raw";
}

int wmain( int argc, WCHAR **argv )
{
    WCHAR path[MAX_PATH], *name;
    void *top;
    HANDLE t;

    setvbuf( stdout, NULL, _IONBF, 0 );
    AddVectoredExceptionHandler( 1, veh );

    GetModuleFileNameW( NULL, path, MAX_PATH );
    name = wcsrchr( path, '\\' ) ? wcsrchr( path, '\\' ) + 1 : path;

    top = VirtualAlloc( NULL, 0x10000, MEM_RESERVE | MEM_COMMIT | MEM_TOP_DOWN, PAGE_READWRITE );

    {
        DWORD old;
        BYTE *page = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );

        if (!page) return 3;
        page[0] = 0xc3;   /* ret */
        VirtualProtect( page, 0x1000, PAGE_EXECUTE_READ, &old );
        FlushInstructionCache( GetCurrentProcess(), page, 0x1000 );
        g_bp_fp = (void (*)(void))page;
    }

    /* execute breakpoint armed on this very thread */
    if (set_dr0( GetCurrentThread(), (DWORD64)(uintptr_t)bp_target, DR7_RES10 | DR7_L0 ))
    {
        g_phase = 1;
        g_bp_fp();
        g_phase = 0;
        set_dr0( GetCurrentThread(), 0, DR7_RES10 );
    }

    /* execute breakpoint armed on another thread */
    g_ev_ready = CreateEventW( NULL, FALSE, FALSE, NULL );
    g_ev_go = CreateEventW( NULL, FALSE, FALSE, NULL );
    if ((t = CreateThread( NULL, 0, xbp_thread, NULL, 0, NULL )))
    {
        WaitForSingleObject( g_ev_ready, 5000 );
        set_dr0( t, (DWORD64)(uintptr_t)bp_target, DR7_RES10 | DR7_L0 );
        SetEvent( g_ev_go );
        WaitForSingleObject( t, 10000 );
        CloseHandle( t );
    }

    printf( "PROBE exe=%ls topdown=%p pae=%d selfbp=%ld xbp=%ld stray_ss=%ld dstfix=%s\n",
            name, top, IsProcessorFeaturePresent( PF_PAE_ENABLED ) ? 1 : 0,
            (long)g_self_hits, (long)g_x_hits, (long)g_other_ss, test_dstfix() );

    if (argc == 3 && !wcscmp( argv[1], L"--spawn" ))
    {
        WCHAR cmd[2 * MAX_PATH];
        STARTUPINFOW si = { sizeof(si) };
        PROCESS_INFORMATION pi;
        DWORD code = 0;

        swprintf( cmd, ARRAYSIZE(cmd), L"\"%ls\"", argv[2] );
        if (!CreateProcessW( argv[2], cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi ))
        {
            printf( "SPAWN failed, error %lu\n", GetLastError() );
            return 2;
        }
        WaitForSingleObject( pi.hProcess, 60000 );
        GetExitCodeProcess( pi.hProcess, &code );
        printf( "SPAWN exit=%lu\n", code );
        CloseHandle( pi.hThread );
        CloseHandle( pi.hProcess );
    }
    return 0;
}
