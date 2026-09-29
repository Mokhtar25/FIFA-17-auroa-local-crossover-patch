#include <windows.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
static HMODULE mods[1024]; static MODULEINFO mi[1024]; static char names[1024][MAX_PATH]; static DWORD nmods;
static void where(HANDLE p, ULONG_PTR a, char *out) {
    DWORD i; for (i = 0; i < nmods; i++) {
        ULONG_PTR b = (ULONG_PTR)mi[i].lpBaseOfDll;
        if (a >= b && a < b + mi[i].SizeOfImage) { char *n = strrchr(names[i], '\\'); sprintf(out, "%s+0x%llx", n ? n + 1 : names[i], (unsigned long long)(a - b)); return; }
    }
    MEMORY_BASIC_INFORMATION m; if (VirtualQueryEx(p, (void*)a, &m, sizeof m) && (m.Protect & 0xf0)) { sprintf(out, "exec-anon(base %p)", m.AllocationBase); return; }
    out[0] = 0;
}
int main(int argc, char **argv) {
    DWORD pid = 0; ULONG_PTR rsp = strtoull(argv[1], 0, 16); int n = argc > 2 ? atoi(argv[2]) : 256;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0); PROCESSENTRY32 pe = { sizeof pe };
    for (BOOL ok = Process32First(snap, &pe); ok; ok = Process32Next(snap, &pe)) if (!_stricmp(pe.szExeFile, "fifa16.exe")) pid = pe.th32ProcessID;
    if (!pid) { printf("no fifa16.exe\n"); return 1; }
    HANDLE p = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!p) { printf("OpenProcess failed %lu\n", GetLastError()); return 1; }
    DWORD need; EnumProcessModulesEx(p, mods, sizeof mods, &need, LIST_MODULES_ALL); nmods = need / sizeof(HMODULE);
    for (DWORD i = 0; i < nmods; i++) { GetModuleInformation(p, mods[i], &mi[i], sizeof mi[i]); GetModuleFileNameExA(p, mods[i], names[i], MAX_PATH); }
    printf("pid %lu, %lu modules\n", pid, nmods);
    for (DWORD i = 0; i < nmods; i++) if (strstr(names[i], "msvcr110") || strstr(names[i], "origin") || strstr(names[i], "fifa16")) printf("  %p %s\n", mi[i].lpBaseOfDll, names[i]);
    ULONG_PTR buf[4096]; SIZE_T got = 0;
    if (!ReadProcessMemory(p, (void*)rsp, buf, n * 8, &got)) { printf("read failed %lu\n", GetLastError()); }
    for (SIZE_T i = 0; i < got / 8; i++) { char w[400]; where(p, buf[i], w); if (w[0]) printf("[rsp+%03llx] %016llx %s\n", (unsigned long long)i * 8, (unsigned long long)buf[i], w); }
    return 0;
}
