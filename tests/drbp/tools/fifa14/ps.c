/* ps.exe [name] — list Wine processes, or print the pid(s) whose image name
 * matches <name> (case-insensitive substring).  CrossOver's wrapper can exit
 * while the game keeps running, so the pid is looked up, not remembered. */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    PROCESSENTRY32 pe;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    int hits = 0;

    if (snap == INVALID_HANDLE_VALUE) { printf("snapshot failed %lu\n", GetLastError()); return 1; }
    pe.dwSize = sizeof pe;
    if (Process32First(snap, &pe))
        do
        {
            if (argc < 2) printf("%6lu  %s\n", (unsigned long)pe.th32ProcessID, pe.szExeFile);
            else if (strstr(pe.szExeFile, argv[1]))
            {
                printf("%lu\n", (unsigned long)pe.th32ProcessID);
                hits++;
            }
        }
        while (Process32Next(snap, &pe));
    CloseHandle(snap);
    return hits ? 0 : 1;
}
