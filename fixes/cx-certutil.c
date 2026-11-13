/* cx-certutil.exe -- the certutil verbs installers use on a certificate store,
 * for a bottle.
 *
 * Wine's certutil.exe is a stub that does nothing, so `certutil -addstore -f
 * Root <file>` left the local certificate out of the store and Aurora 12's
 * setup reported NOT READY. This puts it in crypt32's real Root store, which
 * is what Wine's TLS and Python's ssl.enum_certificates() read.
 *
 *   certutil [-f] [-user] -addstore <store> <file>      PEM or DER
 *   certutil [-f] [-user] -delstore <store> <id>
 *   certutil [-user] -store [<store> [<id>]]            list (default store: My)
 *   certutil [-user] -verifystore <store> [<id>]        the same, as a check
 *
 * <id> is a SHA-1 thumbprint (spaces and colons allowed, any case), a serial
 * number in hex, or the certificate's whole name. Never part of a name: with
 * a substring, `-delstore Root ""` would empty the store.
 *
 * Nothing here is believed until it has been read back. Wine writes a store to
 * the registry only when it is closed, and writes every certificate it holds
 * when it does, so a second process with the same store open can put a deleted
 * certificate back, and a failed write says nothing. -addstore and -delstore
 * therefore open the store again and look, -delstore removes the registry key
 * itself if the certificate is still there, and the exit code is 0 only when
 * the store really is as asked. A verb or flag this does not know exits 1, as
 * the stub's callers already expect of a failure.
 */
#include <windows.h>
#include <wincrypt.h>
#include <stdio.h>
#include <wchar.h>
#include <wctype.h>

#define ENC (X509_ASN_ENCODING | PKCS_7_ASN_ENCODING)
#define MAX_IDS 64

static void say(const wchar_t *fmt, ...)
{
    wchar_t w[2048];
    char a[4096];
    va_list ap;
    int n;
    va_start(ap, fmt);
    _vsnwprintf(w, 2047, fmt, ap);
    va_end(ap);
    w[2047] = 0;
    n = WideCharToMultiByte(CP_UTF8, 0, w, -1, a, sizeof(a), NULL, NULL);
    if (n > 0) fputs(a, stdout);
}

static HCERTSTORE open_store(const wchar_t *name, BOOL user, BOOL readonly)
{
    return CertOpenStore(CERT_STORE_PROV_SYSTEM_W, 0, 0,
                         (user ? CERT_SYSTEM_STORE_CURRENT_USER : CERT_SYSTEM_STORE_LOCAL_MACHINE)
                         | (readonly ? CERT_STORE_READONLY_FLAG : 0),
                         name);
}

static BYTE *read_all(const wchar_t *path, DWORD *n)
{
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    DWORD sz;
    BYTE *d = NULL;
    *n = 0;
    if (h == INVALID_HANDLE_VALUE) return NULL;
    sz = GetFileSize(h, NULL);
    if (sz != INVALID_FILE_SIZE && (d = (BYTE *)HeapAlloc(GetProcessHeap(), 0, sz + 1)))
    {
        if (!ReadFile(h, d, sz, n, NULL)) *n = 0;
    }
    CloseHandle(h);
    return d;
}

static void hex_of(const BYTE *b, DWORD n, BOOL reversed, wchar_t *out)
{
    DWORD i;
    for (i = 0; i < n; i++) swprintf(out + i * 2, 3, L"%02X", b[reversed ? n - 1 - i : i]);
    out[n * 2] = 0;
}

static BOOL sha1_of(PCCERT_CONTEXT c, BYTE hash[20])
{
    DWORD hl = 20;
    return CertGetCertificateContextProperty(c, CERT_SHA1_HASH_PROP_ID, hash, &hl) && hl == 20;
}

/* <id> with spaces and colons taken out, upper case, when what is left is hex. */
static BOOL id_as_hex(const wchar_t *id, wchar_t *out, size_t n)
{
    size_t k = 0;
    for (; *id; id++)
    {
        if (*id == L' ' || *id == L':' || *id == L'\t') continue;
        if (!iswxdigit(*id) || k + 1 >= n) return FALSE;
        out[k++] = towupper(*id);
    }
    out[k] = 0;
    return k >= 2 && !(k & 1);
}

static BOOL cert_is(PCCERT_CONTEXT c, const wchar_t *id)
{
    wchar_t want[130], have[130], name[512];
    BYTE hash[20];
    DWORD types[] = { CERT_NAME_SIMPLE_DISPLAY_TYPE, CERT_NAME_ATTR_TYPE, CERT_NAME_FRIENDLY_DISPLAY_TYPE };
    DWORD i;

    if (!id || !*id) return FALSE;
    if (id_as_hex(id, want, 130))
    {
        if (wcslen(want) == 40 && sha1_of(c, hash))
        {
            hex_of(hash, 20, FALSE, have);
            if (!wcscmp(have, want)) return TRUE;
        }
        if (c->pCertInfo->SerialNumber.cbData && c->pCertInfo->SerialNumber.cbData <= 64)
        {
            hex_of(c->pCertInfo->SerialNumber.pbData, c->pCertInfo->SerialNumber.cbData, TRUE, have);
            if (!wcscmp(have, want)) return TRUE;
        }
    }
    for (i = 0; i < sizeof(types) / sizeof(types[0]); i++)
    {
        name[0] = 0;
        CertGetNameStringW(c, types[i], 0, types[i] == CERT_NAME_ATTR_TYPE ? (void *)szOID_COMMON_NAME : NULL,
                           name, 512);
        if (name[0] && !_wcsicmp(name, id)) return TRUE;
    }
    return FALSE;
}

/* Whether the certificate with this SHA-1 is in the store, asked of a store
 * opened afresh: what another program would now see. */
static BOOL in_store(const wchar_t *store, BOOL user, const BYTE hash[20])
{
    HCERTSTORE st = open_store(store, user, TRUE);
    CRYPT_HASH_BLOB blob;
    PCCERT_CONTEXT c;
    if (!st) return FALSE;
    blob.cbData = 20; blob.pbData = (BYTE *)hash;
    c = CertFindCertificateInStore(st, ENC, 0, CERT_FIND_SHA1_HASH, &blob, NULL);
    if (c) CertFreeCertificateContext(c);
    CertCloseStore(st, 0);
    return c != NULL;
}

static int add(const wchar_t *store, const wchar_t *file, BOOL user)
{
    DWORD n = 0, der = 0;
    BYTE *d = read_all(file, &n), *bin = d, hash[20];
    HCERTSTORE st;
    PCCERT_CONTEXT c = NULL;

    if (!d || !n) { say(L"certutil: cannot read the file\n"); return 1; }
    if (CryptStringToBinaryA((char *)d, n, CRYPT_STRING_BASE64HEADER, NULL, &der, NULL, NULL))
    {
        bin = (BYTE *)HeapAlloc(GetProcessHeap(), 0, der);
        if (!bin || !CryptStringToBinaryA((char *)d, n, CRYPT_STRING_BASE64HEADER, bin, &der, NULL, NULL))
        {
            say(L"certutil: cannot read the certificate in the file\n");
            return 1;
        }
        n = der;
    }
    if (!(st = open_store(store, user, FALSE)))
    {
        say(L"certutil: cannot open the store (%lu)\n", GetLastError());
        return 1;
    }
    if (!CertAddEncodedCertificateToStore(st, ENC, bin, n, CERT_STORE_ADD_REPLACE_EXISTING, &c))
    {
        say(L"certutil: cannot add the certificate (0x%08lx)\n", GetLastError());
        CertCloseStore(st, 0);
        return 1;
    }
    if (!sha1_of(c, hash)) memset(hash, 0, 20);
    CertFreeCertificateContext(c);
    CertControlStore(st, 0, CERT_STORE_CTRL_COMMIT, NULL);
    CertCloseStore(st, 0);
    if (!in_store(store, user, hash))
    {
        say(L"certutil: the certificate was added, but it is not in the %ls store now.\n"
            L"CertUtil: -addstore command FAILED: 0x80092004\n", store);
        return 1;
    }
    say(L"CertUtil: -addstore command completed successfully.\n");
    return 0;
}

/* The key Wine keeps one certificate under. Used when the store's own delete
 * did not last. */
static void reg_delete(HKEY root, const wchar_t *store, const BYTE hash[20])
{
    wchar_t path[400], hex[41];
    hex_of(hash, 20, FALSE, hex);
    _snwprintf(path, 399, L"Software\\Microsoft\\SystemCertificates\\%ls\\Certificates\\%ls", store, hex);
    path[399] = 0;
    RegDeleteKeyW(root, path);
}

static int del(const wchar_t *store, const wchar_t *what, BOOL user)
{
    HCERTSTORE st;
    PCCERT_CONTEXT c = NULL;
    BYTE ids[MAX_IDS][20];
    CRYPT_HASH_BLOB blob;
    int n = 0, i, left = 0, tries;

    if (!what || !*what)
    {
        say(L"certutil: -delstore needs a thumbprint, a serial number or a whole name.\n");
        return 1;
    }
    if (!(st = open_store(store, user, FALSE)))
    {
        say(L"certutil: cannot open the store (%lu)\n", GetLastError());
        return 1;
    }
    /* Which ones first, then the deleting: nothing is removed mid-walk. */
    while ((c = CertEnumCertificatesInStore(st, c)))
        if (n < MAX_IDS && cert_is(c, what) && sha1_of(c, ids[n])) n++;
    if (!n)
    {
        CertCloseStore(st, 0);
        say(L"CertUtil: nothing matched.\n");
        return 1;
    }
    for (i = 0; i < n; i++)
    {
        blob.cbData = 20; blob.pbData = ids[i];
        /* More than once: -user's view holds the machine's copy as well. */
        for (tries = 0; tries < 4; tries++)
        {
            if (!(c = CertFindCertificateInStore(st, ENC, 0, CERT_FIND_SHA1_HASH, &blob, NULL))) break;
            if (!CertDeleteCertificateFromStore(c)) break;      /* frees c either way */
        }
    }
    CertControlStore(st, 0, CERT_STORE_CTRL_COMMIT, NULL);
    CertCloseStore(st, 0);

    for (i = 0; i < n; i++)
    {
        if (!in_store(store, user, ids[i])) continue;
        if (user) reg_delete(HKEY_CURRENT_USER, store, ids[i]);
        reg_delete(HKEY_LOCAL_MACHINE, store, ids[i]);
        if (in_store(store, user, ids[i])) left++;
    }
    if (left)
    {
        say(L"certutil: %d certificate(s) matched, and %d could not be removed from the %ls store.\n"
            L"CertUtil: -delstore command FAILED: 0x80070005\n", n, left, store);
        return 1;
    }
    say(L"CertUtil: -delstore command completed successfully.\n");
    return 0;
}

static void say_date(const wchar_t *label, const FILETIME *ft)
{
    SYSTEMTIME t;
    if (!FileTimeToSystemTime(ft, &t)) return;
    say(L" %ls: %u/%u/%u %u:%02u %ls\n", label, t.wMonth, t.wDay, t.wYear,
        t.wHour % 12 ? t.wHour % 12 : 12, t.wMinute, t.wHour < 12 ? L"AM" : L"PM");
}

/* -store and -verifystore: the certificates, in the shape Windows prints them
 * closely enough for a caller that looks for a name or a thumbprint. With an
 * <id>, finding none is the failure Windows reports. */
static int list(const wchar_t *verb, const wchar_t *store, const wchar_t *what, BOOL user)
{
    HCERTSTORE st = open_store(store, user, TRUE);
    PCCERT_CONTEXT c = NULL;
    wchar_t text[1024], hex[130];
    BYTE hash[20];
    int shown = 0;

    if (!st)
    {
        say(L"CertUtil: %ls command FAILED: 0x80070002\n", verb);
        return 1;
    }
    say(L"%ls\n", store);
    while ((c = CertEnumCertificatesInStore(st, c)))
    {
        if (what && !cert_is(c, what)) continue;
        say(L"================ Certificate %d ================\n", shown++);
        if (c->pCertInfo->SerialNumber.cbData <= 64)
        {
            hex_of(c->pCertInfo->SerialNumber.pbData, c->pCertInfo->SerialNumber.cbData, TRUE, hex);
            say(L"Serial Number: %ls\n", _wcslwr(hex));
        }
        text[0] = 0;
        CertNameToStrW(X509_ASN_ENCODING, &c->pCertInfo->Issuer, CERT_X500_NAME_STR, text, 1024);
        say(L"Issuer: %ls\n", text);
        say_date(L"NotBefore", &c->pCertInfo->NotBefore);
        say_date(L"NotAfter", &c->pCertInfo->NotAfter);
        text[0] = 0;
        CertNameToStrW(X509_ASN_ENCODING, &c->pCertInfo->Subject, CERT_X500_NAME_STR, text, 1024);
        say(L"Subject: %ls\n", text);
        if (CertCompareCertificateName(X509_ASN_ENCODING, &c->pCertInfo->Subject, &c->pCertInfo->Issuer))
            say(L"Root Certificate: Subject matches Issuer\n");
        if (sha1_of(c, hash))
        {
            hex_of(hash, 20, FALSE, hex);
            say(L"Cert Hash(sha1): %ls\n", _wcslwr(hex));
        }
        if (!_wcsicmp(verb, L"-verifystore")) say(L"Certificate is valid\n");
        say(L"\n");
    }
    CertCloseStore(st, 0);
    if (what && !shown)
    {
        say(L"CertUtil: %ls command FAILED: 0x80090011 (-2146893807 NTE_NOT_FOUND)\n"
            L"CertUtil: Object was not found.\n", verb);
        return 1;
    }
    say(L"CertUtil: %ls command completed successfully.\n", verb);
    return 0;
}

static BOOL is_opt(const wchar_t *a, const wchar_t *name)
{
    return (a[0] == L'-' || a[0] == L'/') && !_wcsicmp(a + 1, name);
}

int wmain(int argc, wchar_t **argv)
{
    /* Flags that change nothing here. -f: an existing certificate is always
     * replaced. The others only change how Windows prints. */
    static const wchar_t *const quiet[] = { L"f", L"gmt", L"seconds", L"v", L"silent", L"enterprise" };
    BOOL user = FALSE;
    const wchar_t *rest[4] = {0};       /* verb, store, file or id */
    int i, n = 0;
    size_t q;

    /* The flags can come before or after the verb: Aurora 12 writes -addstore -f. */
    for (i = 1; i < argc; i++)
    {
        if (is_opt(argv[i], L"user")) { user = TRUE; continue; }
        for (q = 0; q < sizeof(quiet) / sizeof(quiet[0]); q++)
            if (is_opt(argv[i], quiet[q])) break;
        if (q < sizeof(quiet) / sizeof(quiet[0])) continue;
        if (n < 4) rest[n] = argv[i];
        n++;
    }
    if (n == 3 && is_opt(rest[0], L"addstore")) return add(rest[1], rest[2], user);
    if (n == 3 && is_opt(rest[0], L"delstore")) return del(rest[1], rest[2], user);
    if (n >= 1 && n <= 3 && (is_opt(rest[0], L"store") || is_opt(rest[0], L"viewstore")))
        return list(L"-store", n > 1 ? rest[1] : L"My", n > 2 ? rest[2] : NULL, user);
    if (n >= 2 && n <= 3 && is_opt(rest[0], L"verifystore"))
        return list(L"-verifystore", rest[1], n > 2 ? rest[2] : NULL, user);
    say(L"certutil: this bottle has -addstore, -delstore, -store and -verifystore only.\n");
    return 1;
}
