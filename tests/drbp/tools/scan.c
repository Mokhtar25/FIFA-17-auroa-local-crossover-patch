/* scan.exe <dword hex> [max]: finds every 4-aligned occurrence of a dword in
 * the committed, readable memory of the running fifa16.exe and prints the
 * address, the region it is in, and the qwords around it. */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    DWORD pid = 0, want, found = 0, max;
    HANDLE snap, p;
    PROCESSENTRY32 pe = { sizeof pe };
    MEMORY_BASIC_INFORMATION m;
    unsigned char *a = 0;
    static unsigned char buf[1 << 20];

    if (argc < 2) { printf("usage: scan <dword> [max]\n"); return 2; }
    want = strtoul(argv[1], 0, 16);
    max = argc > 2 ? atoi(argv[2]) : 200;
    snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    for (BOOL ok = Process32First(snap, &pe); ok; ok = Process32Next(snap, &pe))
        if (!_stricmp(pe.szExeFile, "fifa16.exe")) pid = pe.th32ProcessID;
    if (!pid) { printf("no fifa16.exe\n"); return 1; }
    p = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!p) { printf("OpenProcess failed %lu\n", GetLastError()); return 1; }
    while (VirtualQueryEx(p, a, &m, sizeof m) == sizeof m)
    {
        if (m.State == MEM_COMMIT && !(m.Protect & (PAGE_NOACCESS | PAGE_GUARD)) && m.Protect)
        {
            SIZE_T off;
            for (off = 0; off < m.RegionSize; off += sizeof(buf))
            {
                SIZE_T len = m.RegionSize - off < sizeof(buf) ? m.RegionSize - off : sizeof(buf), got = 0, i;
                if (!ReadProcessMemory(p, (char *)m.BaseAddress + off, buf, len, &got)) continue;
                for (i = 0; i + 4 <= got; i += 4)
                {
                    ULONG_PTR at = (ULONG_PTR)m.BaseAddress + off + i;
                    if (*(DWORD *)(buf + i) != want) continue;
                    printf("%p region %p+%llx prot %lx type %lx:", (void *)at, m.AllocationBase,
                           (unsigned long long)(at - (ULONG_PTR)m.AllocationBase), m.Protect, m.Type);
                    for (SIZE_T j = (i >= 16 ? i - 16 : 0) & ~7; j < i + 24 && j + 8 <= got; j += 8)
                        printf(" %016llx", *(unsigned long long *)(buf + j));
                    printf("\n");
                    if (++found >= max) return 0;
                }
            }
        }
        a = (unsigned char *)m.BaseAddress + m.RegionSize;
    }
    printf("%lu matches\n", found);
    return 0;
}
