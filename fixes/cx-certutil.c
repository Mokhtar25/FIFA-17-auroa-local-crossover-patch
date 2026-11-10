/* cx-certutil.exe -- the two certutil verbs Aurora 12's setup needs, for a bottle.
 *
 * Wine's certutil.exe is a stub that does nothing, so `certutil -addstore -f
 * Root <file>` left the local certificate out of the store and Aurora 12's
 * setup reported NOT READY. This puts it in crypt32's real Root store, which
 * is what Wine's TLS and Python's ssl.enum_certificates() read.
 *
 *   certutil [-f] [-user] -addstore <store> <file>      PEM or DER
 *   certutil [-f] [-user] -delstore <store> <thumbprint or part of the name>
 *
 * Anything else exits 1, as the stub's callers already expect of a failure.
 */
#include <windows.h>
#include <wincrypt.h>
#include <stdio.h>
#include <wchar.h>

static HCERTSTORE open_store(const wchar_t *name, BOOL user)
{
    return CertOpenStore(CERT_STORE_PROV_SYSTEM_W, 0, 0,
                         (user ? CERT_SYSTEM_STORE_CURRENT_USER : CERT_SYSTEM_STORE_LOCAL_MACHINE),
                         name);
}

static BYTE *read_all(const wchar_t *path, DWORD *n)
{
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    DWORD sz;
    BYTE *d;
    if (h == INVALID_HANDLE_VALUE) return NULL;
    sz = GetFileSize(h, NULL);
    d = (BYTE *)HeapAlloc(GetProcessHeap(), 0, sz + 1);
    if (!ReadFile(h, d, sz, n, NULL)) *n = 0;
    CloseHandle(h);
    return d;
}

static int add(const wchar_t *store, const wchar_t *file, BOOL user)
{
    DWORD n = 0, der = 0;
    BYTE *d = read_all(file, &n), *bin = d;
    HCERTSTORE st;

    if (!d || !n) { printf("certutil: cannot read the file\n"); return 1; }
    if (CryptStringToBinaryA((char *)d, n, CRYPT_STRING_BASE64HEADER, NULL, &der, NULL, NULL))
    {
        bin = (BYTE *)HeapAlloc(GetProcessHeap(), 0, der);
        if (!CryptStringToBinaryA((char *)d, n, CRYPT_STRING_BASE64HEADER, bin, &der, NULL, NULL))
            return 1;
        n = der;
    }
    if (!(st = open_store(store, user))) { printf("certutil: cannot open the store (%lu)\n", GetLastError()); return 1; }
    if (!CertAddEncodedCertificateToStore(st, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, bin, n,
                                          CERT_STORE_ADD_REPLACE_EXISTING, NULL))
    {
        printf("certutil: cannot add the certificate (0x%08lx)\n", GetLastError());
        CertCloseStore(st, 0);
        return 1;
    }
    CertCloseStore(st, 0);
    printf("CertUtil: -addstore command completed successfully.\n");
    return 0;
}

static int del(const wchar_t *store, const wchar_t *what, BOOL user)
{
    HCERTSTORE st = open_store(store, user);
    PCCERT_CONTEXT c = NULL;
    int removed = 0;

    if (!st) return 1;
    while ((c = CertEnumCertificatesInStore(st, c)))
    {
        BYTE hash[20];
        DWORD hl = sizeof(hash), i;
        wchar_t hex[41], name[256] = L"";
        CertGetCertificateContextProperty(c, CERT_SHA1_HASH_PROP_ID, hash, &hl);
        for (i = 0; i < 20; i++) swprintf(hex + i * 2, 3, L"%02X", hash[i]);
        CertGetNameStringW(c, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, NULL, name, 256);
        if (!_wcsicmp(hex, what) || (name[0] && wcsstr(name, what)))
        {
            PCCERT_CONTEXT dup = CertDuplicateCertificateContext(c);
            if (CertDeleteCertificateFromStore(dup)) removed++;
        }
    }
    CertCloseStore(st, 0);
    printf(removed ? "CertUtil: -delstore command completed successfully.\n" : "CertUtil: nothing matched.\n");
    return removed ? 0 : 1;
}

int wmain(int argc, wchar_t **argv)
{
    BOOL user = FALSE;
    const wchar_t *rest[3] = {0};       /* verb, store, file or name */
    int i, n = 0;

    /* The flags can come before or after the verb: Aurora 12 writes -addstore -f. */
    for (i = 1; i < argc; i++)
    {
        if (!_wcsicmp(argv[i], L"-f")) continue;
        if (!_wcsicmp(argv[i], L"-user")) { user = TRUE; continue; }
        if (n < 3) rest[n++] = argv[i];
    }
    if (n == 3 && !_wcsicmp(rest[0], L"-addstore")) return add(rest[1], rest[2], user);
    if (n == 3 && !_wcsicmp(rest[0], L"-delstore")) return del(rest[1], rest[2], user);
    printf("certutil: this bottle only has -addstore and -delstore.\n");
    return 1;
}
