/* hookaudit.exe <pid> [out.txt]
 * hookaudit.exe --wait <exe-name> <delay_ms[,delay_ms...]> [out-prefix]
 *
 * Finds run-time code patches (inline hooks) in the loaded modules of another
 * 32-bit process by comparing each module's executable sections in memory with
 * the same sections in the module's file on disk.  Strictly read-only towards
 * the target: OpenProcess(QUERY_INFORMATION|VM_READ) + ReadProcessMemory only.
 *
 * i686-w64-mingw32-gcc -O1 -Wall -o hookaudit.exe hookaudit.c -lpsapi
 */
#include <windows.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_MODULES   1024
#define MAX_DELAYS      64
#define MAX_SECSIZE  (64UL * 1024 * 1024)
#define RANGE_CAP       64
#define PACKED_CAP       4
#define PAGEBYTES     4096
#define GAP              8

typedef long HA_NTSTATUS;

/* ProcessBasicInformation (32-bit layout). */
typedef struct {
    PVOID     Reserved1;
    PVOID     PebBaseAddress;
    PVOID     Reserved2[2];
    ULONG_PTR UniqueProcessId;
    PVOID     Reserved3;
} HA_PBI;

typedef HA_NTSTATUS (WINAPI *HA_NTQIP)(HANDLE, ULONG, PVOID, ULONG, PULONG);

typedef struct {
    char   name[9];
    DWORD  va;
    DWORD  size;
    unsigned char *exp;
    unsigned char *mem;
    unsigned char *ok;
    DWORD  diffbytes;
    DWORD  nrange;
    int    packed;
} HA_SEC;

typedef struct {
    DWORD rva;
    WORD  ord;
    int   named;
    char  name[64];
} HA_EXP;

typedef struct {
    HANDLE h;
    DWORD  base;
    HA_SEC *sec;
    DWORD  nsec;
    HA_EXP *exp;
    DWORD  nexports;
    DWORD  unreadable;
    DWORD  diffbytes;
    DWORD  nrange;
    int    packed;
    DWORD  hooks;
} HA_MOD;

static DWORD find_process(const char *name)
{
    HANDLE snap;
    PROCESSENTRY32 pe;
    DWORD pid = 0;

    snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    pe.dwSize = sizeof(pe);
    if (Process32First(snap, &pe)) {
        do {
            if (!_stricmp(pe.szExeFile, name)) {
                /* a process that has exited can stay in the list: skip it */
                DWORD code = 0;
                HANDLE p = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pe.th32ProcessID);
                if (!p) continue;
                if (GetExitCodeProcess(p, &code) && code == STILL_ACTIVE) pid = pe.th32ProcessID;
                CloseHandle(p);
                if (pid) break;
            }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

static int sec_diff(const HA_SEC *s, DWORD i)
{
    return s->ok[i] && s->exp[i] != s->mem[i];
}

static int sec_bytes_ok(const HA_SEC *s, DWORD off, DWORD n)
{
    DWORD i;

    if (off > s->size || n > s->size - off) return 0;
    for (i = 0; i < n; i++) if (!s->ok[off + i]) return 0;
    return 1;
}

static void add_delta(unsigned char *p, DWORD delta)
{
    DWORD v;

    memcpy(&v, p, 4);
    v += delta;
    memcpy(p, &v, 4);
}

/* RVA -> file offset through the section table, fully bounds checked. */
static int rva_to_off(const IMAGE_SECTION_HEADER *sh, DWORD nsh, DWORD rva,
                      DWORD fsz, DWORD *off)
{
    DWORD i;

    for (i = 0; i < nsh; i++) {
        DWORD vs = sh[i].Misc.VirtualSize;
        DWORD rs = sh[i].SizeOfRawData;
        DWORD span = vs > rs ? vs : rs;
        DWORD d, po;

        if (rva < sh[i].VirtualAddress) continue;
        d = rva - sh[i].VirtualAddress;
        if (d >= span) continue;
        if (d >= rs) return 0;
        po = sh[i].PointerToRawData;
        if (po > fsz || d > fsz - po) return 0;
        *off = po + d;
        return 1;
    }
    return 0;
}

static DWORD nearest_export(const HA_MOD *m, DWORD rva)
{
    DWORD i, best = 0xffffffffu;

    for (i = 0; i < m->nexports; i++) {
        DWORD r = m->exp[i].rva;
        if (r > rva) continue;
        if (best == 0xffffffffu || r > best) best = r;
    }
    return best;
}

static void print_range(FILE *f, HA_MOD *m, HA_SEC *s, DWORD off, DWORD len)
{
    DWORD rva = s->va + off;
    DWORD best, i, n;
    int exact = 0;

    fprintf(f, "  %-8s rva=%08lx va=%08lx len=%lu ", s->name,
            (unsigned long)rva, (unsigned long)(m->base + rva), (unsigned long)len);

    best = nearest_export(m, rva);
    if (best != 0xffffffffu) {
        const HA_EXP *pick = 0;
        for (i = 0; i < m->nexports; i++) {
            const HA_EXP *e = &m->exp[i];
            if (e->rva != best) continue;
            if (!pick || (e->named && !pick->named)) pick = e;
        }
        if (pick) {
            if (pick->named) fprintf(f, "%s+%lx", pick->name, (unsigned long)(rva - best));
            else fprintf(f, "#%lu+%lx", (unsigned long)pick->ord, (unsigned long)(rva - best));
            exact = (best == rva);
        } else fprintf(f, "-");
    } else fprintf(f, "-");

    n = len < 16 ? len : 16;
    fprintf(f, "  file:");
    for (i = 0; i < n; i++) fprintf(f, " %02x", s->exp[off + i]);
    fprintf(f, "  mem:");
    for (i = 0; i < n; i++) {
        if (s->ok[off + i]) fprintf(f, " %02x", s->mem[off + i]);
        else fprintf(f, " ??");
    }

    if (exact) {
        DWORD tgt = 0;
        int have = 0;

        if (sec_bytes_ok(s, off, 5) && s->mem[off] == 0xE9) {
            DWORD rel;
            memcpy(&rel, s->mem + off + 1, 4);
            tgt = m->base + rva + 5 + rel;
            have = 1;
        } else if (sec_bytes_ok(s, off, 6) && s->mem[off] == 0x68 &&
                   s->mem[off + 5] == 0xC3) {
            memcpy(&tgt, s->mem + off + 1, 4);
            have = 1;
        } else if (sec_bytes_ok(s, off, 6) && s->mem[off] == 0xFF &&
                   s->mem[off + 1] == 0x25) {
            memcpy(&tgt, s->mem + off + 2, 4);
            have = 1;
        }
        if (have) {
            fprintf(f, " HOOK-> %08lx", (unsigned long)tgt);
            m->hooks++;
        }
    }
    fprintf(f, "\n");
}

/* Walk one section's differences.  emithit prints up to cap ranges; the
 * function always returns the number of ranges in the section. */
static DWORD walk_ranges(HA_SEC *s, HA_MOD *m, FILE *f, int emit, DWORD cap,
                         DWORD *printed)
{
    DWORD i = 0, cnt = 0, diff = 0;

    while (i < s->size) {
        DWORD start, last, j, k;

        if (!sec_diff(s, i)) { i++; continue; }
        start = i;
        last = i;
        i++;
        while (i < s->size) {
            j = i;
            while (j < s->size && !sec_diff(s, j)) j++;
            if (j < s->size && (j - last) <= GAP) { last = j; i = j + 1; }
            else { i = j; break; }
        }
        for (k = start; k <= last; k++) if (sec_diff(s, k)) diff++;
        cnt++;
        if (emit && *printed < cap) {
            print_range(f, m, s, start, last - start + 1);
            *printed = *printed + 1;
        }
    }
    s->diffbytes = diff;
    s->nrange = cnt;
    return cnt;
}

/* Build the export list of the module from its file image. */
static void build_exports(unsigned char *fb, DWORD fsz, DWORD secoff,
                          const IMAGE_SECTION_HEADER *shs, DWORD nsh,
                          IMAGE_OPTIONAL_HEADER32 *oh, HA_MOD *m)
{
    IMAGE_DATA_DIRECTORY dd = oh->DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    DWORD doff = 0, noff = 0, ooff = 0, nfun, nnam, b, i;
    IMAGE_EXPORT_DIRECTORY *ed;

    (void)secoff;
    if (!dd.VirtualAddress || !dd.Size) return;
    if (!rva_to_off(shs, nsh, dd.VirtualAddress, fsz, &doff)) return;
    if (doff > fsz || fsz - doff < sizeof(IMAGE_EXPORT_DIRECTORY)) return;
    ed = (IMAGE_EXPORT_DIRECTORY *)(fb + doff);
    nfun = ed->NumberOfFunctions;
    nnam = ed->NumberOfNames;
    if (!nfun) return;
    if (nfun > 65536u) nfun = 65536u;
    if (nnam > 65536u) nnam = 65536u;
    if (!rva_to_off(shs, nsh, ed->AddressOfFunctions, fsz, &noff)) return;
    if (noff > fsz || nfun > (fsz - noff) / 4) return;
    if (nnam) {
        if (!rva_to_off(shs, nsh, ed->AddressOfNames, fsz, &b)) return;
        if (b > fsz || nnam > (fsz - b) / 4) return;
        if (!rva_to_off(shs, nsh, ed->AddressOfNameOrdinals, fsz, &ooff)) return;
        if (ooff > fsz || nnam > (fsz - ooff) / 2) return;
    } else if (!nnam) {
        ooff = 0;
        b = 0;
    }

    m->exp = (HA_EXP *)calloc(nfun ? nfun : 1, sizeof(HA_EXP));
    if (!m->exp) return;
    m->nexports = 0;

    for (i = 0; i < nfun; i++) {
        DWORD frva, off;
        HA_EXP *e;

        memcpy(&frva, fb + noff + i * 4, 4);
        if (!frva) continue;
        /* skip forwarded exports: RVA inside the export directory */
        if (frva >= dd.VirtualAddress &&
            frva - dd.VirtualAddress < dd.Size) continue;
        (void)off;
        e = &m->exp[m->nexports];
        memset(e, 0, sizeof(*e));
        e->rva = frva;
        e->ord = (WORD)(ed->Base + i);
        m->nexports++;
    }

    for (i = 0; i < nnam; i++) {
        DWORD nrva, noff2, fo, k;
        const char *nm;
        DWORD frva;

        memcpy(&nrva, fb + b + i * 4, 4);
        if (!rva_to_off(shs, nsh, nrva, fsz, &noff2)) continue;
        nm = (const char *)(fb + noff2);
        /* bounded string */
        for (fo = 0; fo < 63 && noff2 + fo < fsz && nm[fo]; fo++) ;
        if (noff2 + fo >= fsz) continue;
        {
            WORD ordv;
            memcpy(&ordv, fb + ooff + i * 2, 2);
            if (ordv >= nfun) continue;
            memcpy(&frva, fb + noff + (DWORD)ordv * 4, 4);
            if (!frva) continue;
            if (frva >= dd.VirtualAddress &&
                frva - dd.VirtualAddress < dd.Size) continue;
            for (k = 0; k < m->nexports; k++) {
                if (m->exp[k].rva == frva && !m->exp[k].named) {
                    memcpy(m->exp[k].name, nm, fo);
                    m->exp[k].name[fo] = 0;
                    m->exp[k].named = 1;
                    break;
                }
            }
        }
    }
}

static void apply_relocs(unsigned char *fb, DWORD fsz, DWORD secoff,
                         const IMAGE_SECTION_HEADER *shs, DWORD nsh,
                         IMAGE_OPTIONAL_HEADER32 *oh, HA_MOD *m, DWORD delta)
{
    IMAGE_DATA_DIRECTORY dd = oh->DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC];
    DWORD off = 0, pos, end, k;

    (void)secoff;
    if (!delta) return;
    if (!dd.VirtualAddress || !dd.Size) return;
    if (!rva_to_off(shs, nsh, dd.VirtualAddress, fsz, &off)) return;
    if (off >= fsz) return;
    end = (dd.Size > fsz - off) ? fsz : off + dd.Size;

    pos = off;
    while (pos + 8 <= end) {
        DWORD page, bsz, e;

        memcpy(&page, fb + pos, 4);
        memcpy(&bsz, fb + pos + 4, 4);
        if (bsz < 8 || bsz > end - pos) break;
        for (e = pos + 8; e + 2 <= pos + bsz; e += 2) {
            WORD ent;

            memcpy(&ent, fb + e, 2);
            if ((ent >> 12) != IMAGE_REL_BASED_HIGHLOW) continue;
            {
                DWORD trva = page + (DWORD)(ent & 0x0fff);
                for (k = 0; k < m->nsec; k++) {
                    HA_SEC *s = &m->sec[k];
                    DWORD d;
                    if (trva < s->va) continue;
                    d = trva - s->va;
                    if (d > s->size || s->size - d < 4) continue;
                    add_delta(s->exp + d, delta);
                    break;
                }
            }
        }
        pos += bsz;
    }
}

static int audit_module(HANDLE h, HMODULE hm, FILE *f, DWORD *out_hooks)
{
    char path[MAX_PATH], bname[MAX_PATH];
    MODULEINFO mi;
    HANDLE fh;
    unsigned char *fb = 0;
    DWORD fsz = 0, got = 0, lfan, secoff, i, k;
    IMAGE_FILE_HEADER *fhd;
    IMAGE_OPTIONAL_HEADER32 *oh;
    IMAGE_SECTION_HEADER *shs;
    HA_MOD m;
    DWORD delta, printed, cap;
    int ok = 0;

    *out_hooks = 0;
    memset(&m, 0, sizeof(m));
    memset(&mi, 0, sizeof(mi));
    path[0] = 0;
    bname[0] = 0;

    if (!GetModuleFileNameExA(h, hm, path, sizeof(path))) return 0;
    if (!GetModuleInformation(h, hm, &mi, sizeof(mi))) return 0;
    if (!GetModuleBaseNameA(h, hm, bname, sizeof(bname))) {
        const char *p = strrchr(path, '\\');
        if (!p) p = strrchr(path, '/');
        p = p ? p + 1 : path;
        strncpy(bname, p, sizeof(bname) - 1);
        bname[sizeof(bname) - 1] = 0;
    }
    m.h = h;
    m.base = (DWORD)(ULONG_PTR)mi.lpBaseOfDll;
    if (!m.base) { fprintf(f, "  cannot open file %lu\n", (unsigned long)GetLastError()); return 0; }

    fh = CreateFileA(path, GENERIC_READ,
                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                     NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (fh == INVALID_HANDLE_VALUE) {
        fprintf(f, "  cannot open file %lu\n", (unsigned long)GetLastError());
        return 0;
    }
    fsz = GetFileSize(fh, NULL);
    if (fsz == INVALID_FILE_SIZE || fsz == 0) {
        fprintf(f, "  cannot open file %lu\n", (unsigned long)GetLastError());
        CloseHandle(fh);
        return 0;
    }
    fb = (unsigned char *)malloc(fsz);
    if (!fb) {
        fprintf(f, "  cannot open file %lu\n", (unsigned long)ERROR_NOT_ENOUGH_MEMORY);
        CloseHandle(fh);
        return 0;
    }
    if (!ReadFile(fh, fb, fsz, &got, NULL) || got != fsz) {
        fprintf(f, "  cannot open file %lu\n", (unsigned long)GetLastError());
        CloseHandle(fh);
        free(fb);
        return 0;
    }
    CloseHandle(fh);

    if (fsz < sizeof(IMAGE_DOS_HEADER)) goto done;
    if (((IMAGE_DOS_HEADER *)fb)->e_magic != IMAGE_DOS_SIGNATURE) goto done;
    if (((IMAGE_DOS_HEADER *)fb)->e_lfanew < 0) goto done;
    lfan = (DWORD)((IMAGE_DOS_HEADER *)fb)->e_lfanew;
    if (lfan > fsz || fsz - lfan < 4 + sizeof(IMAGE_FILE_HEADER)) goto done;
    {
        DWORD sig;
        memcpy(&sig, fb + lfan, 4);
        if (sig != IMAGE_NT_SIGNATURE) goto done;
    }
    fhd = (IMAGE_FILE_HEADER *)(fb + lfan + 4);
    if (fhd->SizeOfOptionalHeader < sizeof(IMAGE_OPTIONAL_HEADER32)) goto done;
    if (fsz - lfan - 4 - sizeof(IMAGE_FILE_HEADER) < sizeof(IMAGE_OPTIONAL_HEADER32)) goto done;
    oh = (IMAGE_OPTIONAL_HEADER32 *)(fb + lfan + 4 + sizeof(IMAGE_FILE_HEADER));
    if (oh->Magic != 0x10b) goto done;
    secoff = lfan + 4 + sizeof(IMAGE_FILE_HEADER) + fhd->SizeOfOptionalHeader;
    if (secoff > fsz) goto done;
    if ((DWORD)fhd->NumberOfSections > (fsz - secoff) / sizeof(IMAGE_SECTION_HEADER)) goto done;
    shs = (IMAGE_SECTION_HEADER *)(fb + secoff);

    m.sec = (HA_SEC *)calloc((size_t)fhd->NumberOfSections + 1, sizeof(HA_SEC));
    if (!m.sec) goto done;

    for (i = 0; i < fhd->NumberOfSections; i++) {
        IMAGE_SECTION_HEADER *sh = &shs[i];
        DWORD vsize, rawsize, roff, copylen, off;
        HA_SEC *s;

        if (!(sh->Characteristics & (IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_CNT_CODE))) continue;
        vsize = sh->Misc.VirtualSize;
        rawsize = sh->SizeOfRawData;
        if (vsize == 0) vsize = rawsize;
        if (vsize == 0 || vsize > MAX_SECSIZE) continue;

        s = &m.sec[m.nsec];
        memcpy(s->name, sh->Name, 8);
        s->name[8] = 0;
        s->va = sh->VirtualAddress;
        s->size = vsize;
        s->exp = (unsigned char *)calloc(1, vsize);
        s->mem = (unsigned char *)calloc(1, vsize);
        s->ok  = (unsigned char *)calloc(1, vsize);
        if (!s->exp || !s->mem || !s->ok) {
            free(s->exp); free(s->mem); free(s->ok);
            s->exp = s->mem = s->ok = 0;
            s->size = 0;
            continue;
        }
        roff = sh->PointerToRawData;
        copylen = rawsize < vsize ? rawsize : vsize;
        if (roff > fsz) copylen = 0;
        else if (copylen > fsz - roff) copylen = fsz - roff;
        if (copylen) memcpy(s->exp, fb + roff, copylen);

        for (off = 0; off < vsize; off += PAGEBYTES) {
            DWORD chunk = vsize - off;
            SIZE_T g = 0;

            if (chunk > PAGEBYTES) chunk = PAGEBYTES;
            if (ReadProcessMemory(h, (LPCVOID)(ULONG_PTR)(m.base + s->va + off),
                                  s->mem + off, chunk, &g) && g == chunk) {
                memset(s->ok + off, 1, chunk);
            } else {
                m.unreadable++;
                if (g > 0 && g <= chunk) memset(s->ok + off, 1, (size_t)g);
            }
        }
        m.nsec++;
    }

    delta = m.base - oh->ImageBase;
    build_exports(fb, fsz, secoff, shs, fhd->NumberOfSections, oh, &m);
    apply_relocs(fb, fsz, secoff, shs, fhd->NumberOfSections, oh, &m, delta);

    for (k = 0; k < m.nsec; k++) {
        walk_ranges(&m.sec[k], &m, f, 0, 0, &printed);
        m.diffbytes += m.sec[k].diffbytes;
        m.nrange += m.sec[k].nrange;
        if (m.sec[k].size && m.sec[k].diffbytes > m.sec[k].size / 2) m.packed = 1;
    }

    fprintf(f, "%08lx %08lx %-24s %s : sections=%lu diffbytes=%lu ranges=%lu unreadable_pages=%lu delta=",
            (unsigned long)m.base, (unsigned long)mi.SizeOfImage, bname, path,
            (unsigned long)m.nsec, (unsigned long)m.diffbytes,
            (unsigned long)m.nrange, (unsigned long)m.unreadable);
    if (delta & 0x80000000u) fprintf(f, "-%lx", (unsigned long)(0u - delta));
    else fprintf(f, "%lx", (unsigned long)delta);
    if (m.packed) fprintf(f, " PACKED?");
    fprintf(f, "\n");

    ok = m.nrange > 0;
    if (ok) {
        cap = m.packed ? PACKED_CAP : RANGE_CAP;
        printed = 0;
        for (k = 0; k < m.nsec && printed < cap; k++)
            walk_ranges(&m.sec[k], &m, f, 1, cap, &printed);
        if (m.nrange > printed)
            fprintf(f, "  ... %lu more ranges\n", (unsigned long)(m.nrange - printed));
    }
    *out_hooks = m.hooks;

done:
    if (m.sec) {
        for (k = 0; k < m.nsec; k++) {
            free(m.sec[k].exp);
            free(m.sec[k].mem);
            free(m.sec[k].ok);
        }
        free(m.sec);
    }
    free(m.exp);
    free(fb);
    return ok;
}

static void print_peb(HANDLE h, FILE *f)
{
    HMODULE ntdll;
    HA_NTQIP fn;
    HA_PBI pbi;
    ULONG ret = 0;
    unsigned char dbg = 0;
    DWORD flags = 0;
    SIZE_T got = 0;
    int gdbg = 0, gflag = 0;

    memset(&pbi, 0, sizeof(pbi));
    ntdll = GetModuleHandleA("ntdll.dll");
    if (!ntdll) { fprintf(f, "peb=? BeingDebugged=? NtGlobalFlag=?\n"); return; }
    fn = (HA_NTQIP)(void *)GetProcAddress(ntdll, "NtQueryInformationProcess");
    if (!fn) { fprintf(f, "peb=? BeingDebugged=? NtGlobalFlag=?\n"); return; }
    if (fn(h, 0, &pbi, sizeof(pbi), &ret) < 0 || !pbi.PebBaseAddress) {
        fprintf(f, "peb=? BeingDebugged=? NtGlobalFlag=?\n");
        return;
    }
    gdbg = ReadProcessMemory(h, (LPCVOID)((unsigned char *)pbi.PebBaseAddress + 2),
                             &dbg, 1, &got) && got == 1;
    gflag = ReadProcessMemory(h, (LPCVOID)((unsigned char *)pbi.PebBaseAddress + 0x68),
                              &flags, 4, &got) && got == 4;
    fprintf(f, "peb=%08lx BeingDebugged=%s%02x NtGlobalFlag=%s%08lx\n",
            (unsigned long)(ULONG_PTR)pbi.PebBaseAddress,
            gdbg ? "" : "?", (unsigned int)dbg,
            gflag ? "" : "?", (unsigned long)flags);
}

static void audit_process(HANDLE h, DWORD pid, FILE *f, int waitmode, long rel)
{
    HMODULE mods[MAX_MODULES];
    DWORD needed = 0, i, nmods, with_diffs = 0, hooks = 0, hk;

    fprintf(f, "pid=%lu\n", (unsigned long)pid);
    print_peb(h, f);

    if (!EnumProcessModulesEx(h, mods, sizeof(mods), &needed, LIST_MODULES_ALL)) {
        fprintf(f, "EnumProcessModulesEx failed %lu\n", (unsigned long)GetLastError());
        return;
    }
    nmods = needed / sizeof(mods[0]);
    if (nmods > MAX_MODULES) nmods = MAX_MODULES;
    for (i = 0; i < nmods; i++) {
        hk = 0;
        if (audit_module(h, mods[i], f, &hk)) with_diffs++;
        hooks += hk;
    }
    fprintf(f, "modules=%lu with_diffs=%lu hooks=%lu", (unsigned long)nmods,
            (unsigned long)with_diffs, (unsigned long)hooks);
    if (waitmode) fprintf(f, " t=%ldms", rel);
    fprintf(f, "\n");
    fflush(f);
}

int main(int argc, char **argv)
{
    HANDLE h;
    DWORD pid;

    if (argc < 2) {
        fprintf(stderr, "usage: %s <pid> [out.txt]\n", argv[0]);
        fprintf(stderr, "       %s --wait <exe-name> <delay_ms[,delay_ms...]> [out-prefix]\n", argv[0]);
        return 2;
    }

    if (!strcmp(argv[1], "--wait") || !strcmp(argv[1], "wait")) { /* "wait": CrossOver's wine wrapper swallows --wait */
        const char *exe, *prefix = "hookaudit";
        DWORD delays[MAX_DELAYS];
        int ndelays = 0, i;
        DWORD disc, waited = 0;
        FILE *f;

        if (argc < 4) {
            fprintf(stderr, "usage: %s --wait <exe-name> <delay_ms[,delay_ms...]> [out-prefix]\n", argv[0]);
            return 2;
        }
        exe = argv[2];
        if (argc > 4) prefix = argv[4];
        {
            const char *p = argv[3];
            char *end;
            while (*p && ndelays < MAX_DELAYS) {
                delays[ndelays++] = (DWORD)strtoul(p, &end, 10);
                if (*end != ',') break;
                p = end + 1;
            }
        }
        if (!ndelays) { fprintf(stderr, "no delays given\n"); return 2; }

        pid = 0;
        while (!pid && waited < 60000) {
            pid = find_process(exe);
            if (!pid) { Sleep(10); waited++; }
        }
        if (!pid) {
            fprintf(stderr, "process %s not found within 10 min\n", exe);
            return 1;
        }
        disc = GetTickCount();
        h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
        if (!h) {
            fprintf(stderr, "OpenProcess failed %lu\n", (unsigned long)GetLastError());
            return 1;
        }
        printf("pid=%lu discovered t=%lu\n", (unsigned long)pid, (unsigned long)disc);
        fflush(stdout);

        for (i = 0; i < ndelays; i++) {
            char name[512];
            long rel;
            DWORD code = 0;
            size_t plen = strlen(prefix);

            while ((rel = (long)(GetTickCount() - (disc + delays[i]))) < 0) Sleep(1);
            if (!GetExitCodeProcess(h, &code) || code != STILL_ACTIVE) {
                printf("process gone at delay %lums\n", (unsigned long)delays[i]);
                fflush(stdout);
                break;
            }
            if (plen > 400) plen = 400;
            sprintf(name, "%.400s-%lums.txt", prefix, (unsigned long)delays[i]);
            f = fopen(name, "w");
            if (!f) {
                fprintf(stderr, "cannot create %s\n", name);
                continue;
            }
            audit_process(h, pid, f, 1, rel);
            fclose(f);
            printf("wrote %s\n", name);
            fflush(stdout);
        }
        CloseHandle(h);
        return 0;
    }

    pid = (DWORD)strtoul(argv[1], NULL, 0);
    h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
    if (!h) {
        fprintf(stderr, "OpenProcess failed %lu\n", (unsigned long)GetLastError());
        return 1;
    }
    if (argc > 2) {
        FILE *f = fopen(argv[2], "w");
        if (!f) {
            fprintf(stderr, "cannot create %s\n", argv[2]);
            CloseHandle(h);
            return 1;
        }
        audit_process(h, pid, f, 0, 0);
        fclose(f);
    } else {
        audit_process(h, pid, stdout, 0, 0);
    }
    CloseHandle(h);
    return 0;
}
