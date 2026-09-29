#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    DWORD pid = 0; unsigned lo = strtoul(argv[1], 0, 16);
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0); PROCESSENTRY32 pe = { sizeof pe };
    for (BOOL ok = Process32First(snap, &pe); ok; ok = Process32Next(snap, &pe)) if (!_stricmp(pe.szExeFile, "fifa16.exe")) pid = pe.th32ProcessID;
    HANDLE p = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
    MEMORY_BASIC_INFORMATION m; ULONG_PTR a = 0x10000; unsigned long long above4g = 0, below4g = 0, above2g_lo = 0;
    while (VirtualQueryEx(p, (void*)a, &m, sizeof m)) {
        ULONG_PTR b = (ULONG_PTR)m.BaseAddress, e = b + m.RegionSize;
        if (m.State == MEM_COMMIT) {
            if (b >= 0x100000000ULL) above4g += m.RegionSize; else below4g += m.RegionSize;
            if (b < 0x100000000ULL && e > 0x80000000ULL) above2g_lo += m.RegionSize;
            for (ULONG_PTR hi = b >> 32; hi <= (e - 1) >> 32; hi++) {
                ULONG_PTR c = (hi << 32) | lo;
                if (c >= b && c < e) printf("candidate %016llx in region %p-%p prot %lx type %lx alloc %p\n", (unsigned long long)c, (void*)b, (void*)e, m.Protect, m.Type, m.AllocationBase);
            }
        }
        a = e; if (a >= 0x7ffffffe0000ULL) break;
    }
    printf("committed: below 4G %llu MB (of which 2G-4G %llu MB), above 4G %llu MB\n", below4g >> 20, above2g_lo >> 20, above4g >> 20);
    return 0;
}
