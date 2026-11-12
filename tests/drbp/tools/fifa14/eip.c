/* eip.exe <pid> — print the guest EIP of every thread in another process.
 *
 * The only way to tell a spin from real work when a 32-bit guest is stuck:
 * macOS sampling sees Rosetta's translation of the host thread, not the guest
 * instruction pointer.  Sample a few times; a value that never moves is a
 * spin, a set of addresses that all change is code running. */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    DWORD pid;
    THREADENTRY32 te;
    HANDLE snap;

    if (argc < 2) { printf("usage: %s pid\n", argv[0]); return 2; }
    pid = strtoul(argv[1], NULL, 0);
    snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE) { printf("snapshot failed %lu\n", GetLastError()); return 1; }
    te.dwSize = sizeof te;
    if (Thread32First(snap, &te))
        do
        {
            HANDLE th;
            CONTEXT c;

            if (te.th32OwnerProcessID != pid) continue;
            th = OpenThread(THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, te.th32ThreadID);
            if (!th) { printf("tid %lu open failed %lu\n", (unsigned long)te.th32ThreadID, GetLastError()); continue; }
            memset(&c, 0, sizeof c);
            c.ContextFlags = CONTEXT_CONTROL;
            if (GetThreadContext(th, &c))
                printf("tid %lu eip=%08lx esp=%08lx ebp=%08lx eflags=%08lx\n",
                       (unsigned long)te.th32ThreadID, (unsigned long)c.Eip,
                       (unsigned long)c.Esp, (unsigned long)c.Ebp, (unsigned long)c.EFlags);
            else
                printf("tid %lu context failed %lu\n", (unsigned long)te.th32ThreadID, GetLastError());
            CloseHandle(th);
        }
        while (Thread32Next(snap, &te));
    CloseHandle(snap);
    return 0;
}
