/* protect.exe <pid> <addr> <len> <prot> — VirtualProtectEx another process.
 *
 * Used to test what a protector would do if a page it writes to were
 * writable: PAGE_READWRITE is 4, PAGE_EXECUTE_READWRITE is 0x40.  Called on
 * a faulting page *before* the protector reaches the write, this is a
 * diagnostic, not a fix — it changes the protection the guest's own code
 * would otherwise see. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    DWORD pid, prot, old = 0;
    void *addr;
    SIZE_T size;
    HANDLE h;

    if (argc < 5) { printf("usage: %s pid addr len prot\n", argv[0]); return 2; }
    pid  = strtoul(argv[1], NULL, 0);
    addr = (void *)(ULONG_PTR)strtoull(argv[2], NULL, 16);
    size = strtoul(argv[3], NULL, 0);
    prot = strtoul(argv[4], NULL, 0);

    h = OpenProcess(PROCESS_VM_OPERATION | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!h) { printf("OpenProcess failed %lu\n", GetLastError()); return 1; }
    if (!VirtualProtectEx(h, addr, size, prot, &old))
    {
        printf("protect failed %lu\n", GetLastError());
        return 1;
    }
    printf("protected %p+%#lx prot %#lx (old %#lx)\n",
           addr, (unsigned long)size, (unsigned long)prot, (unsigned long)old);
    return 0;
}
