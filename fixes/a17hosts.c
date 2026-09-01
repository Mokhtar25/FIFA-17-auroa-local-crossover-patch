/*
 * a17hosts.dylib -- make the bottle's own hosts file the one that decides.
 *
 * Wine resolves names by calling the macOS resolver from
 * lib/wine/x86_64-unix/ws2_32.so, so C:\windows\system32\drivers\etc\hosts
 * inside the bottle is written by Aurora's launcher and then read by nobody.
 * The only file that decides today is /etc/hosts, which is root:wheel.
 *
 * This library overrides getaddrinfo() and gethostbyname() and answers from
 * $WINEPREFIX/drive_c/windows/system32/drivers/etc/hosts first, falling
 * through to the real resolver for everything it does not name.  It is
 * reached because ws2_32.so's LC_LOAD_DYLIB entry for libSystem is rewritten
 * to point here (see patch-ws2_32.sh); everything else libSystem exports is
 * re-exported unchanged, so this is the only behaviour that differs.
 *
 * Scope: the CrossOver copy this is installed into, and only the bottle named
 * by WINEPREFIX.  No root, no effect on any other application on the Mac.
 */

#include <arpa/inet.h>
#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define A17_MAX_ENTRIES 64
#define A17_MAX_NAME    255
#define A17_MAX_ADDR    45   /* INET6_ADDRSTRLEN */
#define A17_MAX_FILE    (256 * 1024)

struct a17_entry
{
    char name[A17_MAX_NAME + 1];
    char addr[A17_MAX_ADDR + 1];
    int  family;                  /* AF_INET or AF_INET6 */
};

static pthread_mutex_t a17_lock = PTHREAD_MUTEX_INITIALIZER;

static struct a17_entry a17_entries[A17_MAX_ENTRIES];
static int              a17_count;
static int              a17_loaded;
static char             a17_path[PATH_MAX];
static struct timespec  a17_mtime;
static off_t            a17_size;

/* real resolver, taken from libSystem directly -- RTLD_NEXT is not usable
 * here because this library re-exports libSystem, so it is ahead of it. */
static int (*real_getaddrinfo)( const char *, const char *,
                                const struct addrinfo *, struct addrinfo ** );
static struct hostent *(*real_gethostbyname)( const char * );
static pthread_once_t a17_real_once = PTHREAD_ONCE_INIT;

static int a17_debug( void )
{
    static int cached = -1;
    if (cached < 0)
    {
        const char *v = getenv( "AURORA17_HOSTS_DEBUG" );
        cached = (v && *v && strcmp( v, "0" )) ? 1 : 0;
    }
    return cached;
}

static void a17_log( const char *fmt, ... )
{
    va_list ap;
    if (!a17_debug()) return;
    fprintf( stderr, "a17hosts: " );
    va_start( ap, fmt );
    vfprintf( stderr, fmt, ap );
    va_end( ap );
    fprintf( stderr, "\n" );
}

static void a17_load_real( void )
{
    void *h = dlopen( "/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_LOCAL );
    if (!h) return;
    real_getaddrinfo   = dlsym( h, "getaddrinfo" );
    real_gethostbyname = dlsym( h, "gethostbyname" );
}

/* Path of the bottle hosts file.  Empty when there is no bottle, which is the
 * case for CrossOver's own helper processes -- those then behave normally. */
static const char *a17_hosts_path( void )
{
    static char path[PATH_MAX];
    static int  done;
    const char *prefix;

    if (done) return path;
    done = 1;

    prefix = getenv( "AURORA17_HOSTS_FILE" );
    if (prefix && *prefix)
    {
        snprintf( path, sizeof(path), "%s", prefix );
        return path;
    }
    prefix = getenv( "WINEPREFIX" );
    if (!prefix || !*prefix) return path;
    snprintf( path, sizeof(path),
              "%s/drive_c/windows/system32/drivers/etc/hosts", prefix );
    return path;
}

static void a17_add( const char *addr, int family, const char *name )
{
    size_t nlen = strlen( name );

    if (a17_count >= A17_MAX_ENTRIES) return;
    if (!nlen || nlen > A17_MAX_NAME) return;

    snprintf( a17_entries[a17_count].addr, sizeof(a17_entries[0].addr), "%s", addr );
    snprintf( a17_entries[a17_count].name, sizeof(a17_entries[0].name), "%s", name );
    a17_entries[a17_count].family = family;
    a17_count++;
}

static void a17_parse( char *text )
{
    char *line, *saveline = NULL;

    a17_count = 0;
    for (line = strtok_r( text, "\r\n", &saveline ); line;
         line = strtok_r( NULL, "\r\n", &saveline ))
    {
        char *hash = strchr( line, '#' );
        char *tok, *savetok = NULL;
        char addr[A17_MAX_ADDR + 1];
        struct in_addr v4;
        struct in6_addr v6;
        int family;

        if (hash) *hash = 0;

        tok = strtok_r( line, " \t", &savetok );
        if (!tok) continue;
        if (strlen( tok ) > A17_MAX_ADDR) continue;
        snprintf( addr, sizeof(addr), "%s", tok );

        if (inet_pton( AF_INET, addr, &v4 ) == 1) family = AF_INET;
        else if (inet_pton( AF_INET6, addr, &v6 ) == 1) family = AF_INET6;
        else continue;

        while ((tok = strtok_r( NULL, " \t", &savetok )))
            a17_add( addr, family, tok );
    }
}

/* Re-read when the file changed.  The launcher rewrites it on every PLAY and
 * every REPAIR SETUP, so this cannot be a one-shot load. */
static void a17_refresh_locked( void )
{
    const char *path = a17_hosts_path();
    struct stat st;
    char *text;
    int fd;
    ssize_t got, off = 0;

    if (!*path)
    {
        a17_count = 0;
        a17_loaded = 1;
        return;
    }

    if (stat( path, &st ) != 0)
    {
        if (a17_loaded && !*a17_path) return;   /* still absent, nothing to do */
        a17_count = 0;
        a17_loaded = 1;
        a17_path[0] = 0;
        return;
    }

    if (a17_loaded && !strcmp( a17_path, path ) &&
        st.st_size == a17_size &&
        st.st_mtimespec.tv_sec == a17_mtime.tv_sec &&
        st.st_mtimespec.tv_nsec == a17_mtime.tv_nsec)
        return;

    if (st.st_size < 0 || st.st_size > A17_MAX_FILE) return;

    if ((fd = open( path, O_RDONLY | O_CLOEXEC )) < 0) return;
    if (!(text = malloc( (size_t)st.st_size + 1 )))
    {
        close( fd );
        return;
    }
    while (off < st.st_size)
    {
        got = read( fd, text + off, (size_t)(st.st_size - off) );
        if (got <= 0) break;
        off += got;
    }
    close( fd );
    text[off] = 0;

    a17_parse( text );
    free( text );

    snprintf( a17_path, sizeof(a17_path), "%s", path );
    a17_mtime  = st.st_mtimespec;
    a17_size   = st.st_size;
    a17_loaded = 1;

    a17_log( "loaded %d mapping(s) from %s", a17_count, path );
}

static int a17_name_eq( const char *a, const char *b )
{
    while (*a && *b)
    {
        if (tolower( (unsigned char)*a ) != tolower( (unsigned char)*b )) return 0;
        a++; b++;
    }
    return !*a && !*b;
}

/* Copy the mapped address for `name` into `out`.  Returns the family, or 0
 * when the bottle hosts file does not name it. */
static int a17_lookup( const char *name, int want_family, char *out, size_t outlen )
{
    int i, family = 0;

    if (!name || !*name) return 0;

    pthread_mutex_lock( &a17_lock );
    a17_refresh_locked();
    for (i = 0; i < a17_count; i++)
    {
        if (!a17_name_eq( a17_entries[i].name, name )) continue;
        if (want_family != AF_UNSPEC && want_family != a17_entries[i].family) continue;
        snprintf( out, outlen, "%s", a17_entries[i].addr );
        family = a17_entries[i].family;
        break;
    }
    pthread_mutex_unlock( &a17_lock );
    return family;
}

int getaddrinfo( const char *node, const char *service,
                 const struct addrinfo *hints, struct addrinfo **res )
{
    char addr[A17_MAX_ADDR + 1];
    struct addrinfo local;
    int want = hints ? hints->ai_family : AF_UNSPEC;

    pthread_once( &a17_real_once, a17_load_real );
    if (!real_getaddrinfo) return EAI_FAIL;

    if (!a17_lookup( node, want, addr, sizeof(addr) ))
        return real_getaddrinfo( node, service, hints, res );

    /* Hand the literal to the real resolver so the addrinfo chain it returns
     * is one freeaddrinfo() can free, and so service/socktype/protocol are
     * filled in exactly as they would have been. */
    if (hints) local = *hints;
    else memset( &local, 0, sizeof(local) );
    local.ai_flags |= AI_NUMERICHOST;
    local.ai_flags &= ~AI_CANONNAME;

    a17_log( "getaddrinfo(%s) -> %s", node, addr );
    return real_getaddrinfo( addr, service, &local, res );
}

struct hostent *gethostbyname( const char *name )
{
    /* Static, like the real one: gethostbyname is not reentrant by contract
     * and Wine's ws2_32 copies out of the result before returning. */
    static struct hostent ent;
    static struct in_addr v4;
    static struct in6_addr v6;
    static char *addr_list[2];
    static char *alias_list[1];
    static char namebuf[A17_MAX_NAME + 1];
    char addr[A17_MAX_ADDR + 1];
    int family;

    pthread_once( &a17_real_once, a17_load_real );

    family = a17_lookup( name, AF_UNSPEC, addr, sizeof(addr) );
    if (!family)
    {
        if (!real_gethostbyname)
        {
            h_errno = NO_RECOVERY;
            return NULL;
        }
        return real_gethostbyname( name );
    }

    pthread_mutex_lock( &a17_lock );
    snprintf( namebuf, sizeof(namebuf), "%s", name );
    if (family == AF_INET)
    {
        inet_pton( AF_INET, addr, &v4 );
        addr_list[0] = (char *)&v4;
        ent.h_length = sizeof(v4);
    }
    else
    {
        inet_pton( AF_INET6, addr, &v6 );
        addr_list[0] = (char *)&v6;
        ent.h_length = sizeof(v6);
    }
    addr_list[1]  = NULL;
    alias_list[0] = NULL;
    ent.h_name      = namebuf;
    ent.h_aliases   = alias_list;
    ent.h_addrtype  = family;
    ent.h_addr_list = addr_list;
    pthread_mutex_unlock( &a17_lock );

    a17_log( "gethostbyname(%s) -> %s", name, addr );
    return &ent;
}
