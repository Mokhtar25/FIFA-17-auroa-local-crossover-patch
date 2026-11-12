/* raceprotect.exe <exe> <addr-hex> <len-hex> <newprot> [interval-ms]
 *
 * Waits for <exe> to appear, then changes the protection of the range as soon
 * as possible and keeps it changed.  Prints every transition of the previous
 * protection, so a re-protect by the guest is visible.  Diagnostic only: this
 * changes what the guest's own code would otherwise see.
 *
 * i686-w64-mingw32-gcc -O1 -o raceprotect.exe raceprotect.c
 */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static DWORD find_process(const char *name)
{
    HANDLE snap;
    PROCESSENTRY32 pe;
    DWORD pid = 0;

    snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    pe.dwSize = sizeof(pe);
    if (Process32First(snap, &pe)) {
        do {
            if (!_stricmp(pe.szExeFile, name)) { pid = pe.th32ProcessID; break; }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

int main(int argc, char **argv)
{
    const char *exe;
    unsigned long addr, len;
    unsigned long prot;
    int interval = 2;
    DWORD pid = 0;
    HANDLE h = NULL;
    int reported = -1;
    long ticks = 0;

    if (argc < 5) {
        fprintf(stderr, "usage: %s <exe> <addr-hex> <len-hex> <prot> [interval-ms]\n", argv[0]);
        return 2;
    }
    exe  = argv[1];
    addr = strtoul(argv[2], NULL, 16);
    len  = strtoul(argv[3], NULL, 16);
    prot = strtoul(argv[4], NULL, 16);
    if (argc > 5) interval = atoi(argv[5]);
    if (!interval) interval = 1;

    for (;;) {
        DWORD cur;
        if (!pid || !h) {
            pid = find_process(exe);
            if (pid) {
                h = OpenProcess(PROCESS_VM_OPERATION | PROCESS_QUERY_INFORMATION, FALSE, pid);
                if (h) printf("pid=%lu opened\n", (unsigned long)pid);
                fflush(stdout);
            }
        }
        if (h) {
            MEMORY_BASIC_INFORMATION mbi;
            DWORD old = 0;
            if (!VirtualQueryEx(h, (void *)addr, &mbi, sizeof(mbi))) {
                printf("query failed err=%lu\n", (unsigned long)GetLastError());
                fflush(stdout);
                h = NULL; pid = 0;
            } else {
                if ((int)mbi.Protect != reported) {
                    printf("t=%ld protect=%#lx state=%#lx type=%#lx base=%p size=%#lx\n",
                           ticks, (unsigned long)mbi.Protect, (unsigned long)mbi.State,
                           (unsigned long)mbi.Type, mbi.BaseAddress, (unsigned long)mbi.RegionSize);
                    fflush(stdout);
                    reported = mbi.Protect;
                }
                if (mbi.Protect != prot && !(mbi.Protect & PAGE_GUARD)) {
                    if (VirtualProtectEx(h, (void *)addr, len, prot, &old)) {
                        printf("t=%ld set %#lx (was %#lx)\n", ticks, prot, (unsigned long)old);
                        fflush(stdout);
                    }
                }
            }
        }
        Sleep(interval);
        ticks++;
    }
}
