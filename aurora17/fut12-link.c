/* fut12-link.c -- Aurora 12 (FIFA 12) under Wine. #included by aurora-pwsh.c.
 *
 * Aurora 12's helper, futlink.exe, drives Windows through PowerShell. Two kinds
 * of call reach this bottle's stand-in:
 *
 *   -EncodedCommand <script>   the secure-link steps. Scripts are recognised by
 *                              what they contain and answered with the same
 *                              marker lines real PowerShell would print.
 *   -File launch_fifa.ps1      the game launch, see fut12_launch.
 *
 * The link. On Windows the helper makes a non-exportable CNG key, has the
 * broker sign a request for it, dials an IKEv2 VPN with the certificate and
 * falls back to "the app link", one TLS connection, when the dial fails. Wine
 * has no CNG key store and no VPN stack, so the key is a file in the bottle
 * (%LOCALAPPDATA%\Aurora12\maclink) and the VPN steps report what makes the
 * helper try the dial: there is no rasdial.exe, the dial fails, and the helper
 * takes its own app-link fallback. Nothing here talks to any server.
 */
#include <bcrypt.h>

#define F12_RSA_BITS 2048
#define F12_HOSTS_MARK "# FUT12 Aurora 12 (CrossOver)"

typedef struct { BYTE *p; size_t n, cap; } f12buf;

static void bput(f12buf *b, const void *d, size_t n)
{
    if (b->n + n > b->cap)
    {
        size_t cap = b->cap ? b->cap * 2 : 256;
        while (cap < b->n + n) cap *= 2;
        b->p = (BYTE *)realloc(b->p, cap);
        b->cap = cap;
    }
    memcpy(b->p + b->n, d, n);
    b->n += n;
}

/* Tag, DER length, content. */
static void der(f12buf *out_, BYTE tag, const void *d, size_t n)
{
    BYTE h[6];
    size_t k = 0;
    h[k++] = tag;
    if (n < 0x80) h[k++] = (BYTE)n;
    else if (n < 0x100) { h[k++] = 0x81; h[k++] = (BYTE)n; }
    else if (n < 0x10000) { h[k++] = 0x82; h[k++] = (BYTE)(n >> 8); h[k++] = (BYTE)n; }
    else { h[k++] = 0x83; h[k++] = (BYTE)(n >> 16); h[k++] = (BYTE)(n >> 8); h[k++] = (BYTE)n; }
    bput(out_, h, k);
    bput(out_, d, n);
}

static void der_buf(f12buf *out_, BYTE tag, f12buf *in)
{
    der(out_, tag, in->p, in->n);
    free(in->p);
    memset(in, 0, sizeof(*in));
}

/* An unsigned big-endian INTEGER. */
static void der_uint(f12buf *out_, const BYTE *d, size_t n)
{
    f12buf t = {0};
    while (n > 1 && !*d) { d++; n--; }
    if (*d & 0x80) { BYTE z = 0; bput(&t, &z, 1); }
    bput(&t, d, n);
    der_buf(out_, 0x02, &t);
}

/* A BIT STRING with no unused bits. */
static void der_bits(f12buf *out_, const void *d, size_t n)
{
    f12buf t = {0};
    BYTE z = 0;
    bput(&t, &z, 1);
    bput(&t, d, n);
    der_buf(out_, 0x03, &t);
}

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *b64enc(const BYTE *d, size_t n)
{
    char *s = (char *)malloc((n + 2) / 3 * 4 + 1), *o = s;
    for (size_t i = 0; i < n; i += 3)
    {
        unsigned v = d[i] << 16 | (i + 1 < n ? d[i + 1] << 8 : 0) | (i + 2 < n ? d[i + 2] : 0);
        *o++ = B64[v >> 18];
        *o++ = B64[v >> 12 & 63];
        *o++ = i + 1 < n ? B64[v >> 6 & 63] : '=';
        *o++ = i + 2 < n ? B64[v & 63] : '=';
    }
    *o = 0;
    return s;
}

/* Decodes an ASCII string; other characters are skipped. Returns the length. */
static size_t b64dec(const char *s, BYTE **res)
{
    size_t cap = strlen(s) / 4 * 3 + 4, n = 0;
    BYTE *o = (BYTE *)malloc(cap);
    unsigned v = 0;
    int bits = 0;
    for (; *s; s++)
    {
        const char *c = *s == '=' ? NULL : strchr(B64, *s);
        if (!c || !*s) continue;
        v = v << 6 | (unsigned)(c - B64);
        bits += 6;
        if (bits >= 8) { bits -= 8; o[n++] = (BYTE)(v >> bits); v &= (1u << bits) - 1; }
    }
    *res = o;
    return n;
}

static char *f12_env(const char *name)
{
    DWORD n = GetEnvironmentVariableA(name, NULL, 0);
    char *v = (char *)calloc(n + 1, 1);
    if (n) GetEnvironmentVariableA(name, v, n + 1);
    return v;
}

static BOOL f12_dir(wchar_t *dir, size_t cap)
{
    wchar_t base[MAX_PATH];
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH)) return FALSE;
    _snwprintf(dir, cap, L"%s\\Aurora12", base);
    CreateDirectoryW(dir, NULL);
    _snwprintf(dir, cap, L"%s\\Aurora12\\maclink", base);
    CreateDirectoryW(dir, NULL);
    return TRUE;
}

static BOOL f12_write(const wchar_t *path, const void *d, size_t n)
{
    HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD w = 0;
    BOOL ok;
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    ok = WriteFile(h, d, (DWORD)n, &w, NULL) && w == n;
    CloseHandle(h);
    return ok;
}

static BYTE *f12_read(const wchar_t *path, size_t *n)
{
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    DWORD sz, r = 0;
    BYTE *d;
    if (h == INVALID_HANDLE_VALUE) return NULL;
    sz = GetFileSize(h, NULL);
    d = (BYTE *)malloc((size_t)sz + 2);
    if (!ReadFile(h, d, sz, &r, NULL)) { free(d); CloseHandle(h); return NULL; }
    d[r] = 0; d[r + 1] = 0;
    CloseHandle(h);
    *n = r;
    return d;
}

static int f12_err(const char *msg, long detail)
{
    printf("ERR:%s (0x%08lx)\r\n", msg, (unsigned long)detail);
    return 2;
}

/* The key file for a key name: one that can only be a file name. */
static void f12_key_path(const char *name, wchar_t *path, size_t cap)
{
    wchar_t dir[MAX_PATH], w[160];
    int i, n;
    f12_dir(dir, MAX_PATH);
    n = MultiByteToWideChar(CP_UTF8, 0, name, -1, w, 159);
    for (i = 0; i < n - 1; i++)
        if (!iswalnum(w[i]) && w[i] != L'-' && w[i] != L'_') w[i] = L'_';
    _snwprintf(path, cap, L"%s\\key_%s.bin", dir, w);
}

static NTSTATUS f12_rsa(BCRYPT_ALG_HANDLE *alg)
{
    return BCryptOpenAlgorithmProvider(alg, BCRYPT_RSA_ALGORITHM, NULL, 0);
}

static BOOL f12_key_open(const wchar_t *path, BCRYPT_ALG_HANDLE *alg, BCRYPT_KEY_HANDLE *key)
{
    size_t n = 0;
    BYTE *d = f12_read(path, &n);
    NTSTATUS st;
    if (!d) return FALSE;
    if (f12_rsa(alg)) { free(d); return FALSE; }
    st = BCryptImportKeyPair(*alg, NULL, BCRYPT_RSAFULLPRIVATE_BLOB, key, d, (ULONG)n, 0);
    SecureZeroMemory(d, n);
    free(d);
    if (st) { BCryptCloseAlgorithmProvider(*alg, 0); return FALSE; }
    return TRUE;
}

static BOOL f12_sha(LPCWSTR algid, const BYTE *d, size_t n, BYTE *dig, ULONG diglen)
{
    BCRYPT_ALG_HANDLE alg;
    BCRYPT_HASH_HANDLE h;
    BOOL ok = FALSE;
    if (BCryptOpenAlgorithmProvider(&alg, algid, NULL, 0)) return FALSE;
    if (!BCryptCreateHash(alg, &h, NULL, 0, NULL, 0, 0))
    {
        ok = !BCryptHashData(h, (BYTE *)d, (ULONG)n, 0) && !BCryptFinishHash(h, dig, diglen, 0);
        BCryptDestroyHash(h);
    }
    BCryptCloseAlgorithmProvider(alg, 0);
    return ok;
}

static BOOL f12_sign(BCRYPT_KEY_HANDLE key, const BYTE *d, size_t n, BYTE *sig, ULONG cap, ULONG *got)
{
    BYTE dig[32];
    BCRYPT_PKCS1_PADDING_INFO pad = { BCRYPT_SHA256_ALGORITHM };
    if (!f12_sha(BCRYPT_SHA256_ALGORITHM, d, n, dig, 32)) return FALSE;
    return !BCryptSignHash(key, &pad, dig, 32, sig, cap, got, BCRYPT_PAD_PKCS1);
}

static const BYTE OID_RSA[] = {0x06,0x09,0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01};
static const BYTE OID_SHA256RSA[] = {0x06,0x09,0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x0B};
static const BYTE OID_EXTREQ[] = {0x06,0x09,0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x09,0x0E};
static const BYTE OID_CN[] = {0x06,0x03,0x55,0x04,0x03};
static const BYTE OID_SAN[] = {0x06,0x03,0x55,0x1D,0x11};
static const BYTE OID_EKU[] = {0x06,0x03,0x55,0x1D,0x25};
static const BYTE OID_KU[] = {0x06,0x03,0x55,0x1D,0x0F};
static const BYTE OID_CLIENTAUTH[] = {0x06,0x08,0x2B,0x06,0x01,0x05,0x05,0x07,0x03,0x02};
static const BYTE DER_NULL[] = {0x05,0x00};
static const BYTE DER_TRUE[] = {0x01,0x01,0xFF};

static void der_alg(f12buf *o, const BYTE *oid, size_t n)
{
    f12buf t = {0};
    bput(&t, oid, n);
    bput(&t, DER_NULL, 2);
    der_buf(o, 0x30, &t);
}

static void der_ext(f12buf *exts, const BYTE *oid, size_t n, BOOL crit, f12buf *val)
{
    f12buf t = {0};
    bput(&t, oid, n);
    if (crit) bput(&t, DER_TRUE, 3);
    der_buf(&t, 0x04, val);
    der_buf(exts, 0x30, &t);
}

/* PS: make the key, or reuse it, and print the certificate request. */
static int f12_make_csr(void)
{
    char *ident = f12_env("FUT12_LINK_IDENT"), *name = f12_env("FUT12_LINK_KEYNAME");
    char *fresh = f12_env("FUT12_LINK_FRESH");
    wchar_t path[MAX_PATH];
    BCRYPT_ALG_HANDLE alg;
    BCRYPT_KEY_HANDLE key;
    BYTE pub[2048], sigb[512];
    ULONG got = 0, sigl = 0;
    size_t idl = strlen(ident);
    BCRYPT_RSAKEY_BLOB *h = (BCRYPT_RSAKEY_BLOB *)pub;
    f12buf rsa = {0}, spki = {0}, tmp = {0}, nm = {0}, attr = {0}, exts = {0}, val = {0}, info = {0}, csr = {0};
    BYTE zero = 0;
    NTSTATUS st;
    char *b;

    if (!*ident || !*name) return f12_err("the link identity was not passed in", 0);
    f12_key_path(name, path, MAX_PATH);
    if (*fresh == '1') DeleteFileW(path);
    if (f12_key_open(path, &alg, &key))
        printf("RESULT:reused\r\n");
    else
    {
        BYTE *blob;
        ULONG blen = 0;
        if ((st = f12_rsa(&alg))) return f12_err("RSA is not available", st);
        if ((st = BCryptGenerateKeyPair(alg, &key, F12_RSA_BITS, 0))) return f12_err("could not generate the key", st);
        if ((st = BCryptFinalizeKeyPair(key, 0))) return f12_err("could not finish the key", st);
        if ((st = BCryptExportKey(key, NULL, BCRYPT_RSAFULLPRIVATE_BLOB, NULL, 0, &blen, 0)))
            return f12_err("could not size the key", st);
        blob = (BYTE *)malloc(blen);
        if ((st = BCryptExportKey(key, NULL, BCRYPT_RSAFULLPRIVATE_BLOB, blob, blen, &blen, 0)))
            return f12_err("could not export the key", st);
        if (!f12_write(path, blob, blen)) return f12_err("could not save the key", (long)GetLastError());
        SecureZeroMemory(blob, blen);
        free(blob);
        printf("RESULT:created\r\n");
    }

    if ((st = BCryptExportKey(key, NULL, BCRYPT_RSAPUBLIC_BLOB, pub, sizeof(pub), &got, 0)))
        return f12_err("could not read the public key", st);
    if (h->BitLength != F12_RSA_BITS) return f12_err("the key is not 2048 bits", (long)h->BitLength);

    der_uint(&rsa, pub + sizeof(*h) + h->cbPublicExp, h->cbModulus);
    der_uint(&rsa, pub + sizeof(*h), h->cbPublicExp);
    der_buf(&tmp, 0x30, &rsa);
    der_alg(&spki, OID_RSA, sizeof(OID_RSA));
    der_bits(&spki, tmp.p, tmp.n);
    free(tmp.p); memset(&tmp, 0, sizeof(tmp));

    /* CN=<ident> */
    bput(&tmp, OID_CN, sizeof(OID_CN));
    der(&tmp, 0x0C, ident, idl);
    {
        f12buf set = {0};
        der_buf(&set, 0x30, &tmp);
        der_buf(&nm, 0x31, &set);
    }

    /* subjectAltName email, clientAuth, digitalSignature + keyEncipherment */
    {
        f12buf gn = {0};
        der(&gn, 0x81, ident, idl);
        der_buf(&val, 0x30, &gn);
        der_ext(&exts, OID_SAN, sizeof(OID_SAN), FALSE, &val);
    }
    {
        f12buf seq = {0};
        bput(&seq, OID_CLIENTAUTH, sizeof(OID_CLIENTAUTH));
        der_buf(&val, 0x30, &seq);
        der_ext(&exts, OID_EKU, sizeof(OID_EKU), FALSE, &val);
    }
    {
        static const BYTE ku[] = {0x03,0x02,0x05,0xA0};
        bput(&val, ku, sizeof(ku));
        der_ext(&exts, OID_KU, sizeof(OID_KU), TRUE, &val);
    }
    {
        f12buf seq = {0}, set = {0}, a = {0};
        der_buf(&seq, 0x30, &exts);
        der_buf(&set, 0x31, &seq);
        bput(&a, OID_EXTREQ, sizeof(OID_EXTREQ));
        bput(&a, set.p, set.n);
        free(set.p);
        der_buf(&attr, 0x30, &a);
    }

    der(&info, 0x02, &zero, 1);
    der_buf(&info, 0x30, &nm);
    der_buf(&info, 0x30, &spki);
    der_buf(&info, 0xA0, &attr);
    der_buf(&tmp, 0x30, &info);

    if (!f12_sign(key, tmp.p, tmp.n, sigb, sizeof(sigb), &sigl))
        return f12_err("could not sign the request", 0);
    bput(&csr, tmp.p, tmp.n);
    der_alg(&csr, OID_SHA256RSA, sizeof(OID_SHA256RSA));
    der_bits(&csr, sigb, sigl);
    der_buf(&val, 0x30, &csr);

    b = b64enc(val.p, val.n);
    printf("CSR:%s\r\n", b);
    return 0;
}

/* The next DER element. Returns FALSE at the end or on nonsense. */
static BOOL f12_tlv(const BYTE **p, const BYTE *end, BYTE *tag, const BYTE **c, size_t *n)
{
    const BYTE *q = *p;
    size_t len;
    if (end - q < 2) return FALSE;
    *tag = *q++;
    len = *q++;
    if (len & 0x80)
    {
        int k = (int)(len & 0x7f);
        if (k < 1 || k > 3 || end - q < k) return FALSE;
        for (len = 0; k; k--) len = len << 8 | *q++;
    }
    if ((size_t)(end - q) < len) return FALSE;
    *c = q; *n = len; *p = q + len;
    return TRUE;
}

/* "YYYYMMDDHHMMSS" from a UTCTime or GeneralizedTime. */
static void f12_time(BYTE tag, const BYTE *c, size_t n, char *o)
{
    if (tag == 0x17 && n >= 12)
    {
        memcpy(o, c[0] < '5' ? "20" : "19", 2);
        memcpy(o + 2, c, 12);
    }
    else if (n >= 14) memcpy(o, c, 14);
    else memset(o, '0', 14);
    o[14] = 0;
}

static BOOL f12_validity(const BYTE *d, size_t n, char *nb, char *na)
{
    const BYTE *p = d, *end = d + n, *c, *tb;
    size_t l, tl;
    BYTE t;
    int i;
    if (!f12_tlv(&p, end, &t, &c, &l) || t != 0x30) return FALSE;
    p = c; end = c + l;
    if (!f12_tlv(&p, end, &t, &tb, &tl) || t != 0x30) return FALSE;
    p = tb; end = tb + tl;
    if (!f12_tlv(&p, end, &t, &c, &l)) return FALSE;
    if (t != 0xA0 && (p = tb, 0)) return FALSE;
    for (i = 0; i < 3; i++)             /* serial, signature, issuer */
        if (!f12_tlv(&p, end, &t, &c, &l)) return FALSE;
    if (!f12_tlv(&p, end, &t, &c, &l) || t != 0x30) return FALSE;
    p = c; end = c + l;
    if (!f12_tlv(&p, end, &t, &c, &l)) return FALSE;
    f12_time(t, c, l, nb);
    if (!f12_tlv(&p, end, &t, &c, &l)) return FALSE;
    f12_time(t, c, l, na);
    return TRUE;
}

static BOOL f12_has(const BYTE *d, size_t n, const char *s)
{
    size_t k = strlen(s);
    for (size_t i = 0; k && i + k <= n; i++)
        if (d[i] == (BYTE)s[0] && !memcmp(d + i, s, k)) return TRUE;
    return FALSE;
}

static void f12_thumb(const BYTE *d, size_t n, char *o)
{
    BYTE dig[20];
    int i;
    o[0] = 0;
    if (!f12_sha(BCRYPT_SHA1_ALGORITHM, d, n, dig, 20)) return;
    for (i = 0; i < 20; i++) sprintf(o + i * 2, "%02X", dig[i]);
}

/* PS: put the signed certificate beside its key. */
static int f12_install(void)
{
    char *ident = f12_env("FUT12_LINK_IDENT"), *name = f12_env("FUT12_LINK_KEYNAME");
    char *cert = f12_env("FUT12_LINK_CERT"), *ca = f12_env("FUT12_LINK_CA");
    BYTE *d = NULL, *cad = NULL;
    size_t n = b64dec(cert, &d), can = b64dec(ca, &cad);
    wchar_t dir[MAX_PATH], path[MAX_PATH], key[MAX_PATH];
    char thumb[41], cathumb[41], nb[15], na[15];

    if (!n || !f12_validity(d, n, nb, na)) return f12_err("the certificate could not be read", 0);
    if (!f12_has(d, n, ident)) return f12_err("the certificate is not for this account", 0);
    f12_key_path(name, key, MAX_PATH);
    if (GetFileAttributesW(key) == INVALID_FILE_ATTRIBUTES)
        return f12_err("this PC has no key for that certificate - set the link up again", 0);
    f12_dir(dir, MAX_PATH);
    f12_thumb(d, n, thumb);
    f12_thumb(cad, can, cathumb);
    _snwprintf(path, MAX_PATH, L"%s\\ca_%S.der", dir, cathumb);
    if (can) f12_write(path, cad, can);
    _snwprintf(path, MAX_PATH, L"%s\\my_%S.der", dir, thumb);
    if (!f12_write(path, d, n)) return f12_err("could not save the certificate", (long)GetLastError());
    _snwprintf(path, MAX_PATH, L"%s\\my_%S.key", dir, thumb);
    if (!f12_write(path, name, strlen(name))) return f12_err("could not save the certificate", (long)GetLastError());
    printf("THUMB:%s\r\n", thumb);
    return 0;
}

typedef struct
{
    char thumb[41], nb[15], na[15];
    BYTE *der;
    size_t n;
    char keyname[160];
} f12cert;

/* Every stored certificate. */
static int f12_certs(f12cert *list, int cap)
{
    wchar_t dir[MAX_PATH], pat[MAX_PATH], path[MAX_PATH];
    WIN32_FIND_DATAW fd;
    HANDLE h;
    int c = 0;
    if (!f12_dir(dir, MAX_PATH)) return 0;
    _snwprintf(pat, MAX_PATH, L"%s\\my_*.der", dir);
    if ((h = FindFirstFileW(pat, &fd)) == INVALID_HANDLE_VALUE) return 0;
    do
    {
        f12cert *e = &list[c];
        size_t kn = 0;
        BYTE *k;
        wchar_t *dot;
        _snwprintf(path, MAX_PATH, L"%s\\%s", dir, fd.cFileName);
        if (!(e->der = f12_read(path, &e->n))) continue;
        if (!f12_validity(e->der, e->n, e->nb, e->na)) continue;
        f12_thumb(e->der, e->n, e->thumb);
        dot = wcsrchr(path, L'.');
        wcscpy(dot, L".key");
        e->keyname[0] = 0;
        if ((k = f12_read(path, &kn)))
        {
            lstrcpynA(e->keyname, (char *)k, sizeof(e->keyname));
            free(k);
        }
        c++;
    } while (c < cap && FindNextFileW(h, &fd));
    FindClose(h);
    return c;
}

static void f12_now(char *o, int add_minutes)
{
    FILETIME ft;
    SYSTEMTIME st;
    ULARGE_INTEGER u;
    GetSystemTimeAsFileTime(&ft);
    u.LowPart = ft.dwLowDateTime; u.HighPart = ft.dwHighDateTime;
    u.QuadPart += (ULONGLONG)add_minutes * 600000000ULL;
    ft.dwLowDateTime = u.LowPart; ft.dwHighDateTime = u.HighPart;
    FileTimeToSystemTime(&ft, &st);
    sprintf(o, "%04u%02u%02u%02u%02u%02u", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
}

static BOOL f12_usable(const f12cert *e, BCRYPT_ALG_HANDLE *alg, BCRYPT_KEY_HANDLE *key)
{
    wchar_t path[MAX_PATH];
    if (!e->keyname[0]) return FALSE;
    f12_key_path(e->keyname, path, MAX_PATH);
    return f12_key_open(path, alg, key);
}

/* PS: which certificates does this PC hold for this account? */
static int f12_find(void)
{
    static f12cert list[32];
    char *ident = f12_env("FUT12_LINK_IDENT"), soon[15];
    int c = f12_certs(list, 32), i;
    f12_now(soon, 24 * 60);
    for (i = 0; i < c; i++)
    {
        BCRYPT_ALG_HANDLE alg;
        BCRYPT_KEY_HANDLE key;
        if (!f12_has(list[i].der, list[i].n, ident) || strcmp(list[i].na, soon) <= 0) continue;
        if (f12_usable(&list[i], &alg, &key))
            printf("CERT:%s|%.4s-%.2s-%.2s\r\n", list[i].thumb, list[i].na, list[i].na + 4, list[i].na + 6);
        else
            printf("UNUSABLE:%s\r\n", list[i].thumb);
    }
    return 0;
}

/* PS: keep the newest usable certificate. Older ones stay: they are files. */
static int f12_sweep(void)
{
    static f12cert list[32];
    char *ident = f12_env("FUT12_LINK_IDENT"), soon[15];
    int c = f12_certs(list, 32), i, best = -1;
    f12_now(soon, 24 * 60);
    for (i = 0; i < c; i++)
    {
        BCRYPT_ALG_HANDLE alg;
        BCRYPT_KEY_HANDLE key;
        if (!f12_has(list[i].der, list[i].n, ident) || strcmp(list[i].na, soon) <= 0) continue;
        if (f12_usable(&list[i], &alg, &key) && (best < 0 || strcmp(list[i].nb, list[best].nb) > 0)) best = i;
    }
    if (best >= 0) printf("KEPT:%s\r\n", list[best].thumb);
    return 0;
}

/* PS: the certificates under this domain, for the helper's diagnostics. */
static int f12_report(void)
{
    static f12cert list[32];
    char *dom = f12_env("FUT12_LINK_DOMAIN");
    int c = f12_certs(list, 32), i;
    for (i = 0; i < c; i++)
        if (f12_has(list[i].der, list[i].n, dom))
            printf("CERT:CurrentUser|%s|%.4s-%.2s-%.2s|key=%s\r\n", list[i].thumb + 34,
                   list[i].na, list[i].na + 4, list[i].na + 6, list[i].keyname[0] ? "True" : "False");
    return 0;
}

/* PS: sign the app link's nonce with the newest usable certificate. */
static int f12_applink_sign(void)
{
    static f12cert list[32];
    char *data = f12_env("FUT12_APPLINK_DATA"), *want = f12_env("FUT12_LINK_IDENT"), soon[15];
    BYTE *nonce = NULL, sig[512];
    size_t nn = b64dec(data, &nonce);
    ULONG sl = 0;
    int c = f12_certs(list, 32), i, best = -1;
    BCRYPT_ALG_HANDLE alg;
    BCRYPT_KEY_HANDLE key;
    f12_now(soon, 10);
    for (i = 0; i < c; i++)
    {
        if (!f12_has(list[i].der, list[i].n, "@fut12.player")) continue;
        if (*want && !f12_has(list[i].der, list[i].n, want)) continue;
        if (!list[i].keyname[0] || strcmp(list[i].na, soon) < 0) continue;
        if (best < 0 || strcmp(list[i].nb, list[best].nb) > 0) best = i;
    }
    if (best < 0) return f12_err("no link certificate on this PC", 0);
    if (!f12_usable(&list[best], &alg, &key)) return f12_err("the link key could not be opened", 0);
    if (!f12_sign(key, nonce, nn, sig, sizeof(sig), &sl)) return f12_err("the link key would not sign", 0);
    printf("CERT:%s\r\nSIG:%s\r\n", b64enc(list[best].der, list[best].n), b64enc(sig, sl));
    return 0;
}

/* The forwarder will not start without a "server" in netconfig.json, even for
 * the app link. On Windows a VPN dial that worked has put it there by now; here
 * no dial ever works, so it comes from the route the helper asks the VPN for. */
static void f12_record_server(void)
{
    char *route = f12_env("FUT12_LINK_ROUTE"), *cut, line[96];
    wchar_t base[MAX_PATH], path[MAX_PATH];
    size_t n = 0;
    BYTE *d;
    f12buf o = {0};
    const char *open_;

    if ((cut = strchr(route, '/'))) *cut = 0;
    if (!*route || strlen(route) > 45 || !GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH)) return;
    _snwprintf(path, MAX_PATH, L"%s\\Aurora12\\FIFA12\\server\\netconfig.json", base);
    d = f12_read(path, &n);
    if (d && strstr((char *)d, "\"server\"")) return;
    open_ = d ? strchr((char *)d, '{') : NULL;
    if (open_)
    {
        const char *body = open_ + 1 + strspn(open_ + 1, " \t\r\n");
        sprintf(line, "{\"server\": \"%s\"%s", route, *body == '}' ? "" : ", ");
        bput(&o, line, strlen(line));
        bput(&o, body, strlen(body));
    }
    else
    {
        sprintf(line, "{\"server\": \"%s\"}", route);
        bput(&o, line, strlen(line));
    }
    f12_write(path, o.p, o.n);
}

/* Which script is this? -1 means none of ours. */
static int f12_script(const char *s)
{
    if (strstr(s, "CreateSigningRequest")) return f12_make_csr();
    if (strstr(s, "CopyWithPrivateKey")) return f12_install();
    if (strstr(s, "FUT12_APPLINK_DATA")) return f12_applink_sign();
    if (strstr(s, "'UNUSABLE:'")) return f12_find();
    if (strstr(s, "'KEPT:'")) return f12_sweep();
    if (strstr(s, "FUT12_LINK_DOMAIN")) return f12_report();
    /* The VPN entry: reported as already right, so the helper goes on to dial.
     * There is no rasdial.exe to dial with, which is what leads to the app link. */
    if (strstr(s, "Add-VpnConnection") && strstr(s, "RESULT:unchanged"))
    {
        f12_record_server();
        printf("RESULT:unchanged\r\n");
        return 0;
    }
    if (strstr(s, "'STATUS:missing'"))
    {
        printf("STATUS:missing\r\n");
        return 0;
    }
    /* No other VPN to report, no all-users copy to remove, no phonebook. */
    if (strstr(s, "Hyper-V") || strstr(s, "Remove-VpnConnection") || strstr(s, "Find-Pbk"))
        return 0;
    return -1;
}

/* -EncodedCommand. Returns the exit code, or -1 if the script is not ours; an
 * unknown script is recorded so the next one to teach can be read off. */
static int fut12_encoded(const wchar_t *enc)
{
    char narrow[64 * 1024 * 2];
    BYTE *d = NULL;
    size_t n, i, k = 0;
    int rc;
    WideCharToMultiByte(CP_ACP, 0, enc, -1, narrow, sizeof(narrow), NULL, NULL);
    n = b64dec(narrow, &d);
    char *s = (char *)malloc(n / 2 + 1);
    for (i = 0; i + 1 < n; i += 2)
        if (!d[i + 1]) s[k++] = (char)d[i];
    s[k] = 0;
    if ((rc = f12_script(s)) >= 0) return rc;
    {
        wchar_t dir[MAX_PATH], path[MAX_PATH];
        if (f12_dir(dir, MAX_PATH))
        {
            _snwprintf(path, MAX_PATH, L"%s\\unknown-scripts.log", dir);
            HANDLE h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS, 0, NULL);
            if (h != INVALID_HANDLE_VALUE)
            {
                DWORD w;
                static const char sep[] = "\r\n----\r\n";
                WriteFile(h, s, (DWORD)(k > 1500 ? 1500 : k), &w, NULL);
                WriteFile(h, sep, sizeof(sep) - 1, &w, NULL);
                CloseHandle(h);
            }
        }
    }
    return -1;
}

/* ------------------------------------------------------------------ launch */

static void f12_hosts_path(wchar_t *o, size_t cap)
{
    wchar_t sys[MAX_PATH];
    GetSystemDirectoryW(sys, MAX_PATH);
    _snwprintf(o, cap, L"%s\\drivers\\etc\\hosts", sys);
}

/* Takes our block out of the hosts file. */
static void f12_hosts_clear(void)
{
    wchar_t path[MAX_PATH];
    size_t n = 0;
    BYTE *d;
    f12buf o = {0};
    char *line, *next;
    BOOL in = FALSE;
    f12_hosts_path(path, MAX_PATH);
    if (!(d = f12_read(path, &n))) return;
    for (line = (char *)d; line && *line; line = next)
    {
        size_t len;
        next = strchr(line, '\n');
        len = next ? (size_t)(++next - line) : strlen(line);
        if (!strncmp(line, F12_HOSTS_MARK, strlen(F12_HOSTS_MARK))) { in = !in; continue; }
        if (!in) bput(&o, line, len);
    }
    f12_write(path, o.p ? o.p : (BYTE *)"", o.n);
}

static void f12_hosts_add(void)
{
    static const char *const names[] = {
        "gosredirector.ea.com", "gosredirector.online.ea.com", "gosredirector.scert.ea.com",
        "gosredirector.stest.ea.com", "proxy.novafusion.ea.com", "easw.easports.com",
        "xmlns.easw.easports.com", "eac-fifapow02.eac.ad.ea.com", "content.lt.easfc.ea.com",
    };
    wchar_t path[MAX_PATH];
    size_t n = 0, i;
    BYTE *d;
    f12buf o = {0};
    char line[128];
    f12_hosts_clear();
    f12_hosts_path(path, MAX_PATH);
    if ((d = f12_read(path, &n))) bput(&o, d, n);
    if (o.n && o.p[o.n - 1] != '\n') bput(&o, "\r\n", 2);
    sprintf(line, "%s\r\n", F12_HOSTS_MARK);
    bput(&o, line, strlen(line));
    for (i = 0; i < sizeof(names) / sizeof(names[0]); i++)
    {
        sprintf(line, "127.0.0.1 %s\r\n", names[i]);
        bput(&o, line, strlen(line));
    }
    sprintf(line, "%s\r\n", F12_HOSTS_MARK);
    bput(&o, line, strlen(line));
    f12_write(path, o.p, o.n);
}

/* FIFA 12's default is 800x600, which a Mac display usually cannot switch to,
 * and the game then stops with E0001. Only an absent file is written. */
static void f12_setup_ini(void)
{
    wchar_t home[MAX_PATH], dir[MAX_PATH], path[MAX_PATH];
    char body[256];
    int w = GetSystemMetrics(SM_CXSCREEN), h = GetSystemMetrics(SM_CYSCREEN), i;
    if (!GetEnvironmentVariableW(L"USERPROFILE", home, MAX_PATH)) return;
    _snwprintf(dir, MAX_PATH, L"%s\\Documents\\FIFA 12", home);
    CreateDirectoryW(dir, NULL);
    _snwprintf(path, MAX_PATH, L"%s\\fifasetup.ini", dir);
    if (GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES || w < 640 || h < 480) return;
    i = sprintf(body, "RESOLUTIONWIDTH = %d\r\nRESOLUTIONHEIGHT = %d\r\nASPECTRATIO = %.5f\r\n"
                      "RENDERINGQUALITY = 1\r\nWAITFORVSYNC = 1\r\nVOICECHAT = 1\r\n", w, h, (double)w / h);
    f12_write(path, body, (size_t)i);
}

static char *f12_replace(char *s, const char *tok, const char *with)
{
    f12buf o = {0};
    size_t tl = strlen(tok);
    char *p = s, *q;
    while ((q = strstr(p, tok)))
    {
        bput(&o, p, (size_t)(q - p));
        bput(&o, with, strlen(with));
        p = q + tl;
    }
    bput(&o, p, strlen(p) + 1);
    return (char *)o.p;
}

/* launch_fifa.ps1 -PatchScript <file> -Display <mode> -TunnelServer <addr>
 * The parts of it that mean anything in a bottle: hosts, the resolution, the
 * tokens in the debugger script, EALaunchCode, the game under cdb, and the wait.
 * The firewall and EA App steps have nothing to act on here. */
static int fut12_launch(const wchar_t *script, int argc, wchar_t **argv)
{
    wchar_t here[MAX_PATH], gpath[MAX_PATH], game[MAX_PATH], exe[MAX_PATH], patch[MAX_PATH] = L"";
    wchar_t run[MAX_PATH], logs[MAX_PATH], clog[MAX_PATH], cmd[2048], pidf[MAX_PATH], cdb[MAX_PATH], envcdb[MAX_PATH];
    char hereu[MAX_PATH * 2], *p, *raw;
    size_t n = 0;
    BYTE *d;
    int i, k;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    SYSTEMTIME st;
    DWORD code = 0;
    static const struct { const char *tok, *file; } files[] = {
        {"%F11ART_BIN%", "f11art_table.bin"}, {"%SWF_BIN%", "swf_table.bin"},
        {"%STATOVER_BIN%", "statover_table.bin"}, {"%HEADART_BIN%", "headart_table.bin"},
        {"%POINTS_BIN%", "points_balance.bin"},
    };

    for (i = 0; i + 1 < argc; i++)
        if (!_wcsicmp(argv[i], L"-PatchScript")) lstrcpynW(patch, argv[i + 1], MAX_PATH);

    lstrcpynW(here, script, MAX_PATH);
    if (!wcsrchr(here, L'\\')) return fail_code(1, L"launch_fifa: no script folder in %s", script);
    *wcsrchr(here, L'\\') = 0;

    _snwprintf(gpath, MAX_PATH, L"%s\\gamepath.txt", here);
    if (!(d = f12_read(gpath, &n))) return fail_code(1, L"launch_fifa: no gamepath.txt in %s", here);
    p = (char *)d;
    if (n >= 3 && (BYTE)p[0] == 0xEF) p += 3;
    p[strcspn(p, "\r\n")] = 0;
    MultiByteToWideChar(CP_UTF8, 0, p, -1, game, MAX_PATH);
    _snwprintf(exe, MAX_PATH, L"%s\\fifa.exe", game);
    if (GetFileAttributesW(exe) == INVALID_FILE_ATTRIBUTES)
        return fail_code(1, L"launch_fifa: %s is not there.", exe);

    if (!GetEnvironmentVariableW(L"FUT12_CDB", envcdb, MAX_PATH)) envcdb[0] = 0;
    lstrcpynW(cdb, envcdb[0] ? envcdb : L"C:\\Program Files (x86)\\Windows Kits\\10\\Debuggers\\x86\\cdb.exe", MAX_PATH);
    if (GetFileAttributesW(cdb) == INVALID_FILE_ATTRIBUTES)
        return fail_code(1, L"launch_fifa: the debugger is missing: %s", cdb);
    if (GetFileAttributesW(patch) == INVALID_FILE_ATTRIBUTES)
        return fail_code(1, L"launch_fifa: the patch script is missing: %s", patch);

    _snwprintf(logs, MAX_PATH, L"%s\\logs", here);
    CreateDirectoryW(logs, NULL);

    /* The tokens the debugger script carries, with forward slashes. */
    WideCharToMultiByte(CP_UTF8, 0, here, -1, hereu, sizeof(hereu), NULL, NULL);
    for (p = hereu; *p; p++) if (*p == '\\') *p = '/';
    if (!(d = f12_read(patch, &n))) return fail_code(1, L"launch_fifa: could not read %s", patch);
    raw = (char *)d;
    {
        char val[MAX_PATH * 2 + 64];
        sprintf(val, "%s/logs/fut12_crash.dmp", hereu);
        raw = f12_replace(raw, "%CRASH_DMP%", val);
        for (k = 0; k < (int)(sizeof(files) / sizeof(files[0])); k++)
        {
            sprintf(val, "%s/%s", hereu, files[k].file);
            raw = f12_replace(raw, files[k].tok, val);
        }
    }
    _snwprintf(run, MAX_PATH, L"%s\\cdb_run.txt", here);
    if (!f12_write(run, raw, strlen(raw))) return fail_code(1, L"launch_fifa: could not write %s", run);

    /* The FIFA Points figure comes from the server before the game starts. */
    {
        wchar_t py[MAX_PATH], rep[MAX_PATH], line[MAX_PATH * 3];
        _snwprintf(py, MAX_PATH, L"%s\\..\\python\\python.exe", here);
        _snwprintf(rep, MAX_PATH, L"%s\\client_report.py", here);
        if (GetFileAttributesW(py) != INVALID_FILE_ATTRIBUTES && GetFileAttributesW(rep) != INVALID_FILE_ATTRIBUTES)
        {
            _snwprintf(line, MAX_PATH * 3, L"\"%s\" \"%s\" --prime", py, rep);
            memset(&si, 0, sizeof(si)); si.cb = sizeof(si);
            if (CreateProcessW(NULL, line, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, here, &si, &pi))
            {
                WaitForSingleObject(pi.hProcess, 10000);
                CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
            }
        }
    }

    /* The game stops with "not running from installed location" unless this
     * names the folder above the exe, spelled the way it is being started. */
    {
        wchar_t root[MAX_PATH];
        static const REGSAM views[] = { KEY_WOW64_32KEY, KEY_WOW64_64KEY };
        lstrcpynW(root, game, MAX_PATH);
        if (wcsrchr(root, L'\\')) wcsrchr(root, L'\\')[1] = 0;
        for (k = 0; k < 2; k++)
        {
            HKEY key;
            if (!RegCreateKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\EA Sports\\FIFA 12", 0, NULL, 0,
                                 KEY_SET_VALUE | views[k], NULL, &key, NULL))
            {
                RegSetValueExW(key, L"Install Dir", 0, REG_SZ, (const BYTE *)root,
                               (DWORD)((wcslen(root) + 1) * sizeof(wchar_t)));
                RegCloseKey(key);
            }
        }
    }

    f12_setup_ini();
    f12_hosts_add();
    SetEnvironmentVariableW(L"EALaunchCode", L"1");

    GetLocalTime(&st);
    _snwprintf(clog, MAX_PATH, L"%s\\cdb_%04u%02u%02u_%02u%02u%02u.log", logs,
               st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    _snwprintf(cmd, 2048, L"\"%s\" -G -cf \"%s\" -logo \"%s\" \"%s\"", cdb, run, clog, exe);
    memset(&si, 0, sizeof(si)); si.cb = sizeof(si);
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, game, &si, &pi))
    {
        DWORD e = GetLastError();
        f12_hosts_clear();
        return fail_code(1, L"launch_fifa: the debugger could not be started: Windows error %lu", e);
    }
    {
        char pid[32];
        int l = sprintf(pid, "%lu", pi.dwProcessId);
        _snwprintf(pidf, MAX_PATH, L"%s\\debugger.pid", logs);
        f12_write(pidf, pid, (size_t)l);
    }
    printf("  started pid %lu\r\n[LIVE] Game is running...\r\n", pi.dwProcessId);
    /* Under Wine cdb does not always end when the game does: it stays behind
     * failing to remove its breakpoints, and everything waiting on it (Aurora,
     * the forwarder, the hosts block) would stay too. So the game decides. */
    {
        procid list[8];
        BOOL seen = FALSE;
        int gone = 0, waited = 0;
        while (WaitForSingleObject(pi.hProcess, 1000) == WAIT_TIMEOUT)
        {
            if (find_processes(L"fifa.exe", list, 8) > 0) { seen = TRUE; gone = 0; }
            else if (seen ? ++gone >= 3 : ++waited >= 180)
            {
                TerminateProcess(pi.hProcess, 0);
                break;
            }
        }
    }
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    f12_hosts_clear();
    printf("game exited\r\n");
    return 0;
}
