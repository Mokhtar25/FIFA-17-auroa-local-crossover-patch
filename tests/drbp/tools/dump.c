/* dump.exe <addr hex> <len hex> <out file>: copies raw bytes out of the
 * running fifa16.exe with ReadProcessMemory (winedbg kills the game; this
 * does not).  Unreadable pages are written as 0xcc and reported. */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    DWORD pid = 0;
    ULONG_PTR addr, len, off;
    HANDLE snap, p;
    PROCESSENTRY32 pe = { sizeof pe };
    unsigned char *buf;
    FILE *f;

    if (argc < 4) { printf("usage: dump <addr> <len> <out>\n"); return 2; }
    addr = strtoull(argv[1], 0, 16);
    len = strtoull(argv[2], 0, 16);
    snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    for (BOOL ok = Process32First(snap, &pe); ok; ok = Process32Next(snap, &pe))
        if (!_stricmp(pe.szExeFile, "fifa16.exe")) pid = pe.th32ProcessID;
    if (!pid) { printf("no fifa16.exe\n"); return 1; }
    p = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!p) { printf("OpenProcess failed %lu\n", GetLastError()); return 1; }
    buf = malloc(len);
    memset(buf, 0xcc, len);
    for (off = 0; off < len; )
    {
        ULONG_PTR a = addr + off, chunk = 0x1000 - (a & 0xfff);
        SIZE_T got = 0;
        if (chunk > len - off) chunk = len - off;
        if (!ReadProcessMemory(p, (void *)a, buf + off, chunk, &got) || got != chunk)
            printf("unreadable %p (+%lx) err %lu\n", (void *)a, (unsigned long)chunk, GetLastError());
        off += chunk;
    }
    if (!(f = fopen(argv[3], "wb"))) { printf("cannot write %s\n", argv[3]); return 1; }
    fwrite(buf, 1, len, f);
    fclose(f);
    printf("dumped %p len %lx to %s\n", (void *)addr, (unsigned long)len, argv[3]);
    return 0;
}
