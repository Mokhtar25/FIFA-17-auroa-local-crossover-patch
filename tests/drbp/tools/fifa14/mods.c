/* mods.exe <pid> — the loaded modules of another process, from its PEB list. */
#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    DWORD pid;
    HANDLE h;
    HMODULE mods[512];
    DWORD needed, i;

    if (argc < 2) { fprintf(stderr, "usage: %s <pid>\n", argv[0]); return 2; }
    pid = (DWORD)strtoul(argv[1], NULL, 0);
    h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
    if (!h) { fprintf(stderr, "OpenProcess failed %lu\n", (unsigned long)GetLastError()); return 1; }
    if (!EnumProcessModulesEx(h, mods, sizeof(mods), &needed, LIST_MODULES_ALL))
    { fprintf(stderr, "EnumProcessModules failed %lu\n", (unsigned long)GetLastError()); return 1; }
    for (i = 0; i < needed / sizeof(mods[0]); i++)
    {
        char path[MAX_PATH] = "", base[MAX_PATH] = "";
        GetModuleFileNameExA(h, mods[i], path, sizeof(path));
        GetModuleBaseNameA(h, mods[i], base, sizeof(base));
        printf("%p  %-28s %s\n", (void *)mods[i], base, path);
    }
    CloseHandle(h);
    return 0;
}
