/*
 * gate_probe.c -- did the FIFA 17 folder gate let this process run, and what
 * did starting one through it cost the parent?
 *
 * patches/crossover-26.3-fifa17-folder-gate.patch makes the unix ntdll run
 * cx-fifa17-gate before FIFA17.exe or Impulsum17Launcher.exe runs any code of
 * its own. This program is copied under those names and under names the gate
 * ignores (game.exe), and launches copies of itself:
 *
 *   gate_probe.exe                         print "GPROBE main ..." and exit 0
 *   gate_probe.exe [opts] --spawn <exe>    the same, then CreateProcess <exe>
 *                                          (quoted, so spaces work), wait for
 *                                          it and print one SPAWN line
 *   gate_probe.exe [opts] --cmd <line>     the same with a whole command line
 *                                          and no application name, for
 *                                          "C:\windows\system32\cmd.exe /c start ..."
 *
 *   --setenv NAME=VALUE   set it in this process first, so the child inherits it
 *   --repeat N            start the child N times and print the mean time
 *                         CreateProcess took (the gate runs inside that call)
 *
 * SPAWN ok exit=0x...         the child ran; its exit code
 * SPAWN failed err=N status=0x...   CreateProcess failed: GetLastError and
 *                             the NTSTATUS behind it (RtlGetLastNtStatus);
 *                             a refusal by the gate is status=0xc0f17a7e
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -Wall -municode -o gate_probe.exe gate_probe.c
 */

#define __USE_MINGW_ANSI_STDIO 1
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

typedef LONG (WINAPI *get_status_fn)(void);

static double now_ms( void )
{
    static LARGE_INTEGER freq;
    LARGE_INTEGER t;

    if (!freq.QuadPart) QueryPerformanceFrequency( &freq );
    QueryPerformanceCounter( &t );
    return (double)t.QuadPart * 1000.0 / (double)freq.QuadPart;
}

static int spawn( const WCHAR *app, WCHAR *cmd, double *ms )
{
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    get_status_fn get_status;
    DWORD code = 0, err;
    LONG status = 0;
    double t0 = now_ms();
    BOOL ok;

    ok = CreateProcessW( app, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi );
    *ms = now_ms() - t0;
    if (!ok)
    {
        err = GetLastError();
        get_status = (get_status_fn)GetProcAddress( GetModuleHandleW( L"ntdll.dll" ), "RtlGetLastNtStatus" );
        if (get_status) status = get_status();
        printf( "SPAWN failed err=%lu status=0x%08lx create_ms=%.1f\n", err, (unsigned long)status, *ms );
        fflush( stdout );
        return 0;
    }
    WaitForSingleObject( pi.hProcess, 120000 );
    GetExitCodeProcess( pi.hProcess, &code );
    printf( "SPAWN ok exit=0x%08lx create_ms=%.1f\n", code, *ms );
    fflush( stdout );
    CloseHandle( pi.hThread );
    CloseHandle( pi.hProcess );
    return 1;
}

int wmain( int argc, WCHAR **argv )
{
    WCHAR self[MAX_PATH], cmd[4096];
    const WCHAR *app = NULL;
    int i, n, repeat = 1, have_cmd = 0;
    double ms, total = 0;

    GetModuleFileNameW( NULL, self, MAX_PATH );
    printf( "GPROBE main exe=%ls pid=%lu\n", self, GetCurrentProcessId() );
    fflush( stdout );

    for (i = 1; i < argc; i++)
    {
        if (!wcscmp( argv[i], L"--setenv" ) && i + 1 < argc)
        {
            WCHAR *eq, buf[512];

            wcsncpy( buf, argv[++i], ARRAYSIZE(buf) - 1 );
            buf[ARRAYSIZE(buf) - 1] = 0;
            if ((eq = wcschr( buf, '=' )))
            {
                *eq = 0;
                SetEnvironmentVariableW( buf, eq + 1 );
            }
        }
        else if (!wcscmp( argv[i], L"--repeat" ) && i + 1 < argc) repeat = _wtoi( argv[++i] );
        else if (!wcscmp( argv[i], L"--spawn" ) && i + 1 < argc)
        {
            app = argv[++i];
            have_cmd = 1;
        }
        else if (!wcscmp( argv[i], L"--cmd" ) && i + 1 < argc)
        {
            app = NULL;
            swprintf( cmd, ARRAYSIZE(cmd), L"%ls", argv[++i] );
            have_cmd = 2;
        }
    }
    if (!have_cmd) return 0;
    for (n = 0; n < repeat; n++)
    {
        if (have_cmd == 1) swprintf( cmd, ARRAYSIZE(cmd), L"\"%ls\"", app );
        spawn( have_cmd == 1 ? app : NULL, cmd, &ms );
        total += ms;
    }
    if (repeat > 1) printf( "SPAWN mean_create_ms=%.1f n=%d\n", total / repeat, repeat );
    return 0;
}
