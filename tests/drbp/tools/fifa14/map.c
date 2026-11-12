/* map.exe <pid> — every committed region of another process, with state,
 * protect and type, so a manually mapped image shows up as what it is.
 *
 *   state 0x1000 = committed, 0x2000 = reserved, 0x10000 = free
 *   type  0x1000000 = MEM_IMAGE, 0x40000 = MEM_MAPPED, 0x20000 = MEM_PRIVATE
 *
 * i686-w64-mingw32-gcc -O1 -o map.exe map.c
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    DWORD pid;
    HANDLE h;
    unsigned char *p;
    int prev = -1;

    if (argc < 2) { fprintf(stderr, "usage: %s <pid>\n", argv[0]); return 2; }
    pid = (DWORD)strtoul(argv[1], NULL, 0);
    h = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!h) { fprintf(stderr, "OpenProcess failed %lu\n", (unsigned long)GetLastError()); return 1; }

    printf("     base        size  state   prot type\n");
    for (p = NULL; p < (unsigned char *)0x80000000; )
    {
        MEMORY_BASIC_INFORMATION mbi;
        if (!VirtualQueryEx(h, p, &mbi, sizeof(mbi))) break;
        if (mbi.State == MEM_FREE)
        {
            if (prev != 2) printf("             (free)\n");
            prev = 2;
        }
        else
        {
            printf("%10p %10lx %6lx %6lx %6lx\n", mbi.BaseAddress,
                   (unsigned long)mbi.RegionSize, (unsigned long)mbi.State,
                   (unsigned long)mbi.Protect, (unsigned long)mbi.Type);
            prev = 1;
        }
        p = (unsigned char *)mbi.BaseAddress + mbi.RegionSize;
    }
    CloseHandle(h);
    return 0;
}
