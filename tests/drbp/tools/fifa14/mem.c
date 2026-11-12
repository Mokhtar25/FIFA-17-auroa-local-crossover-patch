/* mem.exe <pid> <addr> <len> [out] — page state and bytes of another process.
 *
 * <addr> is hexadecimal with or without 0x, <len> is bytes (0x1000 works).
 * Prints the VirtualQuery result first (protect=2 is PAGE_READONLY, 4 is
 * PAGE_READWRITE, 8 PAGE_WRITECOPY, 0x20/0x40/0x80 the executable forms), so
 * a hex dump lands on the same line as the protection it was read under.
 * With [out], the bytes are also written there as raw binary: objdump and
 * ndisasm both want a file, and ndisasm needs -o <addr> to label it. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    DWORD pid;
    ULONG_PTR addr;
    SIZE_T len, i, got = 0;
    unsigned char *buf;
    HANDLE h;
    MEMORY_BASIC_INFORMATION mbi;

    if (argc < 4) { printf("usage: %s pid addr len [out]\n", argv[0]); return 2; }
    pid  = strtoul(argv[1], NULL, 0);
    addr = (ULONG_PTR)strtoull(argv[2], NULL, 16);
    len  = strtoul(argv[3], NULL, 0);

    h = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!h) { printf("OpenProcess failed %lu\n", GetLastError()); return 1; }
    if (VirtualQueryEx(h, (void *)addr, &mbi, sizeof mbi))
        printf("page %p state=%lx protect=%lx type=%lx base=%p size=%lx\n",
               (void *)addr, (unsigned long)mbi.State, (unsigned long)mbi.Protect,
               (unsigned long)mbi.Type, mbi.BaseAddress, (unsigned long)mbi.RegionSize);
    else printf("VirtualQueryEx failed %lu\n", GetLastError());

    buf = malloc(len);
    if (!buf) return 1;
    if (!ReadProcessMemory(h, (void *)addr, buf, len, &got))
        printf("ReadProcessMemory failed %lu got=%lu\n", GetLastError(), (unsigned long)got);
    else
    {
        for (i = 0; i < got; i++)
        {
            if (!(i % 16)) printf("\n%08lx ", (unsigned long)(addr + i));
            printf("%02x ", buf[i]);
        }
        printf("\n");
        if (argc > 4)
        {
            FILE *f = fopen(argv[4], "wb");
            if (f) { fwrite(buf, 1, got, f); fclose(f); printf("wrote %lu bytes to %s\n", (unsigned long)got, argv[4]); }
        }
    }
    return 0;
}
