/*
 * cxlowport.dylib -- let Windows programs listen on 127.0.0.1 below port 1024.
 *
 * macOS (10.14 on) lets any user bind 0.0.0.0 to a port below 1024, but not a
 * specific address: bind(127.0.0.1:443) fails with EACCES unless the process
 * is root. Windows has no such rule, and REFUT's online bridge (FIFA 20)
 * relies on it: it listens on 127.0.0.1:443 and the game connects there.
 * Under Wine the bind gets WSAEACCES (10013) and the bridge gives up.
 *
 * In this CrossOver every socket bind() and connect() happens in wineserver
 * (server/sock.c: IOCTL_AFD_BIND, IOCTL_AFD_WINE_CONNECT), and so do the
 * getsockname()/getpeername() behind Winsock's. So this library is put in
 * wineserver's place for libSystem: setup points wineserver's LC_LOAD_DYLIB
 * for /usr/lib/libSystem.B.dylib at @rpath/cxlowport.dylib, which re-exports
 * libSystem whole and adds four functions.
 *
 *   bind()        When the real bind() of IPv4 127.0.0.1 to a port P below
 *                 1024 fails with EACCES, bind 127.0.0.1:(18000 + P) instead
 *                 and remember P as moved.
 *   connect()     IPv4 127.0.0.1:P, P moved, goes to 127.0.0.1:(18000 + P).
 *   getsockname()
 *   getpeername() 127.0.0.1:(18000 + P), P moved, reads back as 127.0.0.1:P,
 *                 so neither end ever sees the moved port.
 *
 * Each bottle has its own wineserver, which every program in that bottle
 * goes through, so a listener and whoever connects to it from the same bottle
 * meet here, with no pf rule and nothing that needs an administrator
 * password. A port is only rewritten after this wineserver moved a bind for
 * it, so a real service on 127.0.0.1:P (run as root) is reached as before
 * until then. Other addresses, other ports, other errors and every successful
 * bind() go through untouched.
 *
 * It does nothing unless CX_LOWPORT=1 is in wineserver's environment, which
 * it inherits from the bottle's cxbottle.conf: setup sets it in FIFA 20's
 * REFUT bottle only. Everywhere else a bind below 1024 is refused as before,
 * so a program that falls back to another port still does, and nothing on
 * the Mac side is left knocking on a port that was quietly moved.
 *
 * CX_LOWPORT_DEBUG=1 in wineserver's environment logs each move and redirect
 * to stderr.
 */
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <arpa/inet.h>

#define CX_LOWPORT_OFFSET 18000

/* The real functions, taken from libSystem directly -- RTLD_NEXT is not
 * usable here because this library re-exports libSystem, so it is ahead of
 * it. */
static int (*real_bind)( int, const struct sockaddr *, socklen_t );
static int (*real_connect)( int, const struct sockaddr *, socklen_t );
static int (*real_getsockname)( int, struct sockaddr *, socklen_t * );
static int (*real_getpeername)( int, struct sockaddr *, socklen_t * );
static pthread_once_t real_once = PTHREAD_ONCE_INIT;

/* Ports below 1024 this wineserver has moved. wineserver is single-threaded;
 * the atomics only keep this honest if that ever changes. */
static unsigned char moved_ports[1024];

static void load_real( void )
{
    void *h = dlopen( "/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_LOCAL );
    if (!h) return;
    real_bind = dlsym( h, "bind" );
    real_connect = dlsym( h, "connect" );
    real_getsockname = dlsym( h, "getsockname" );
    real_getpeername = dlsym( h, "getpeername" );
}

/* CX_LOWPORT=1 switches the whole library on; read once, wineserver's
 * environment does not change. */
static int enabled( void )
{
    static int on = -1;
    if (on < 0)
    {
        const char *val = getenv( "CX_LOWPORT" );
        on = val && val[0] == '1';
    }
    return on;
}

static int debug_on( void )
{
    const char *dbg = getenv( "CX_LOWPORT_DEBUG" );
    return dbg && *dbg && strcmp( dbg, "0" );
}

/* The port P of an IPv4 127.0.0.1:P address with 0 < P < 1024, else 0. */
static unsigned loopback_low_port( const struct sockaddr *addr, socklen_t len )
{
    const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
    unsigned port;

    if (!addr || len < (socklen_t)sizeof(struct sockaddr_in) || addr->sa_family != AF_INET)
        return 0;
    if (in->sin_addr.s_addr != htonl( INADDR_LOOPBACK )) return 0;
    port = ntohs( in->sin_port );
    return port < 1024 ? port : 0;
}

static int is_moved( unsigned port )
{
    return port && __atomic_load_n( &moved_ports[port], __ATOMIC_ACQUIRE );
}

int bind( int fd, const struct sockaddr *addr, socklen_t len )
{
    pthread_once( &real_once, load_real );
    if (!real_bind) { errno = ENOSYS; return -1; }

    int rc = real_bind( fd, addr, len );
    if (rc == 0 || errno != EACCES || !enabled()) return rc;

    unsigned port = loopback_low_port( addr, len );
    if (!port)
    {
        errno = EACCES;
        return rc;
    }

    struct sockaddr_in moved = *(const struct sockaddr_in *)addr;
    moved.sin_port = htons( CX_LOWPORT_OFFSET + port );
    int rc2 = real_bind( fd, (const struct sockaddr *)&moved, sizeof moved );
    int saved = errno;
    if (debug_on())
        fprintf( stderr, "cxlowport: bind 127.0.0.1:%u refused by macOS; 127.0.0.1:%u %s\n",
                 port, CX_LOWPORT_OFFSET + port, rc2 ? strerror( saved ) : "bound instead" );
    if (rc2)
    {
        errno = EACCES;   /* report the original refusal */
        return rc2;
    }
    __atomic_store_n( &moved_ports[port], 1, __ATOMIC_RELEASE );
    return 0;
}

int connect( int fd, const struct sockaddr *addr, socklen_t len )
{
    pthread_once( &real_once, load_real );
    if (!real_connect) { errno = ENOSYS; return -1; }

    unsigned port = loopback_low_port( addr, len );
    if (!is_moved( port )) return real_connect( fd, addr, len );

    struct sockaddr_in moved = *(const struct sockaddr_in *)addr;
    moved.sin_port = htons( CX_LOWPORT_OFFSET + port );
    if (debug_on())
        fprintf( stderr, "cxlowport: connect 127.0.0.1:%u -> 127.0.0.1:%u\n",
                 port, CX_LOWPORT_OFFSET + port );
    return real_connect( fd, (const struct sockaddr *)&moved, sizeof moved );
}

/* A moved port read back from the kernel becomes the one asked for. */
static void unmove( struct sockaddr *addr, socklen_t *len )
{
    struct sockaddr_in *in = (struct sockaddr_in *)addr;
    unsigned port;

    if (!addr || !len || *len < (socklen_t)sizeof(struct sockaddr_in) || addr->sa_family != AF_INET)
        return;
    if (in->sin_addr.s_addr != htonl( INADDR_LOOPBACK )) return;
    port = ntohs( in->sin_port );
    if (port <= CX_LOWPORT_OFFSET || port >= CX_LOWPORT_OFFSET + 1024) return;
    if (is_moved( port - CX_LOWPORT_OFFSET ))
        in->sin_port = htons( port - CX_LOWPORT_OFFSET );
}

int getsockname( int fd, struct sockaddr *addr, socklen_t *len )
{
    pthread_once( &real_once, load_real );
    if (!real_getsockname) { errno = ENOSYS; return -1; }

    int rc = real_getsockname( fd, addr, len );
    if (rc == 0) unmove( addr, len );
    return rc;
}

int getpeername( int fd, struct sockaddr *addr, socklen_t *len )
{
    pthread_once( &real_once, load_real );
    if (!real_getpeername) { errno = ENOSYS; return -1; }

    int rc = real_getpeername( fd, addr, len );
    if (rc == 0) unmove( addr, len );
    return rc;
}
