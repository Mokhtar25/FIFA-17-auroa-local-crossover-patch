/* mods.exe: lists every module of the running fifa16.exe with base and size. */
#include <windows.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <stdio.h>

int main(void)
{
    static HMODULE mods[1024];
    DWORD pid = 0, need, i;
    HANDLE snap, p;
    PROCESSENTRY32 pe = { sizeof pe };

    snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    for (BOOL ok = Process32First(snap, &pe); ok; ok = Process32Next(snap, &pe))
        if (!_stricmp(pe.szExeFile, "fifa16.exe")) pid = pe.th32ProcessID;
    if (!pid) { printf("no fifa16.exe\n"); return 1; }
    p = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!p || !EnumProcessModulesEx(p, mods, sizeof mods, &need, LIST_MODULES_ALL)) { printf("failed %lu\n", GetLastError()); return 1; }
    for (i = 0; i < need / sizeof(HMODULE); i++)
    {
        MODULEINFO mi; char name[MAX_PATH];
        GetModuleInformation(p, mods[i], &mi, sizeof mi);
        GetModuleFileNameExA(p, mods[i], name, MAX_PATH);
        printf("%p %08lx %s\n", mi.lpBaseOfDll, mi.SizeOfImage, name);
    }
    return 0;
}
