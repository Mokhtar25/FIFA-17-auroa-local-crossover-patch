#!/bin/zsh
# Rebuilds every binary in fixes/ from source, so you never have to take ours on
# trust. This is also what the LGPL asks for: the files in fixes/x86_64-unix and
# fixes/x86_64-windows are built from CrossOver's published Wine sources, and the
# changes are in patches/. This script is how the two go back together.
#
#   ./build.sh /path/to/crossover-sources-26.3.0.tar.gz [outdir]
#   ./build.sh --deps        just check the tools, build nothing
#
# Output lands in outdir (default ./build-out), laid out exactly like fixes/, and
# the checksums are compared against fixes/SHA256SUMS at the end.
#
# READ THIS BEFORE BELIEVING THE COMPARISON. A Wine build is not bit-reproducible
# across machines: paths, timestamps, toolchain versions and link order all leak
# in. Files that differ are not necessarily wrong. What the comparison is good
# for is the opposite direction -- a file that matches proves that patch really
# does produce that binary. See "Honest status" at the bottom of this file.

# Run under zsh whatever it was started with. Every line below is zsh, and the
# very next one -- HERE="${0:A:h}" -- is the trap: bash and sh read ${0:A:h} as
# their own ${var:offset:length}, evaluate the offset "A" as arithmetic, and
# with set -u stop at "A: unbound variable". That names a variable this script
# does not have, on a line that looks innocent, so "bash setup.sh" or
# "sh setup.sh" failed with a message nobody could act on. Re-exec instead.
# This block is plain POSIX so bash and sh get here before parsing any zsh.
if [ -z "${ZSH_VERSION:-}" ]; then
    if [ -x /bin/zsh ]; then
        exec /bin/zsh "$0" "$@"
    fi
    printf '%s\n' "This needs zsh, which every Mac has at /bin/zsh, and it is missing." >&2
    printf '%s\n' "Nothing has been changed." >&2
    exit 2
fi

set -eu

HERE="${0:A:h}"
case "${1:-}" in
    --help|-h)
        print -r -- "Usage: ./build.sh /path/to/crossover-sources-26.3.0.tar.gz [outdir]"
        print -r -- "       ./build.sh --deps"
        exit 0 ;;
    --deps) [ "$#" -eq 1 ] || { print -r -- "--deps takes no arguments"; exit 2; } ;;
    -*) print -r -- "Unknown option: $1 (try: ./build.sh --help)"; exit 2 ;;
esac
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || {
    print -r -- "Expected a source tarball and optional output directory (try: ./build.sh --help)"
    exit 2
}
OUT="${2:-$HERE/build-out}"
# Later commands change directory; all build paths must retain their meaning.
OUT="${OUT:A}"

# Colour only when writing to a terminal; NO_COLOR=1 turns it off.
_paint() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        C_RED=$'\e[1;31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_OFF=$'\e[0m'
    else
        C_RED='' C_GRN='' C_YEL='' C_OFF=''
    fi
}
say()  { print -r -- "$@"; }
ok()   { _paint; print -r -- "  ${C_GRN}ok${C_OFF}    $@"; }
note() { _paint; print -r -- "  ${C_YEL}note${C_OFF}  $@"; }
bad()  { _paint; print -r -- "  ${C_RED}BAD${C_OFF}   $@"; }
red()  { _paint; print -r -- "${C_RED}$@${C_OFF}"; }
green() { _paint; print -r -- "${C_GRN}$@${C_OFF}"; }
# A stop: first line red says what went wrong, the rest says what to do.
fail() {
    local msg="$*" first rest
    first="${msg%%$'\n'*}"
    rest="${msg#*$'\n'}"
    _paint
    print -r -- ""
    print -r -- "${C_RED}STOPPED: ${first}${C_OFF}"
    [ "$rest" = "$msg" ] || print -r -- "$rest"
    print -r -- ""
    exit 1
}

# Apply order matters and is not alphabetical. cng sits on top of online -- both
# touch dlls/crypt32/pfx.c -- so applying them in directory order produces a
# reject. This is the order, and it is the only one that works.
PATCHES=(
  crossover-26.3-fifa17-rosetta.patch
  crossover-26.3-fifa17-online.patch
  crossover-26.3-fifa17-audio.patch
  crossover-26.3-fifa17-cng.patch
)
# A fifth, FIFA 15's. See patches/README-fifa15-wine-fixes.md. It changes nothing unless
# the bottle sets CX_TOPDOWN_LIMIT, which only the FIFA 15 bottle profile does,
# so FIFA 17 bottles run the same code either way.
[ -f "$HERE/patches/crossover-26.3-topdown-alloc-limit.patch" ] \
    && PATCHES+=( crossover-26.3-topdown-alloc-limit.patch )
# A sixth, also FIFA 15's: Aurora15Connector crashes at exit in Wine's gdiplus
# (GdipDeletePrivateFontCollection walks a freed collection). Ships with the
# shared package; it adds gdiplus.dll to the build and to fixes/.
[ -f "$HERE/patches/crossover-26.3-gdiplus-delete-font-collection.patch" ] \
    && PATCHES+=( crossover-26.3-gdiplus-delete-font-collection.patch )
[ -f "$HERE/patches/crossover-26.3-ole32-revoke-foreign-window.patch" ] \
    && PATCHES+=( crossover-26.3-ole32-revoke-foreign-window.patch )
# An eighth, also the RebornFUT launcher's. CrossOver's cross-process child
# window hack (CX HACK 23950, shm_surface_flush in win32u) sends a synchronous
# message to the parent process while the caller still holds the USER lock, and
# the WebView2 browser process aborts on "BUG: holding USER lock". The patch
# defers the flush instead. It touches only dlls/win32u, so it applies last and
# could equally apply first.
[ -f "$HERE/patches/crossover-26.3-win32u-shm-flush-under-user-lock.patch" ] \
    && PATCHES+=( crossover-26.3-win32u-shm-flush-under-user-lock.patch )
# Then FIFA 16's first three, in this order. The debug-register emulation and PF_PAE
# are what let the crack's protector run at all; the dst fix is what stops the
# endless loading after the language screen, and it was made against a tree
# that already has the other two, so it goes last. All three go into the shared
# ntdll and none changes anything for FIFA 15 or 17: the emulation and PF_PAE
# act only when the bottle sets CX_DR_TRAP=3, the dst fix only when it sets
# CX_FIFA16_DSTFIX, and only the FIFA 16 bottle profile sets either.
[ -f "$HERE/patches/crossover-26.3-debug-register-emulation.patch" ] \
    && PATCHES+=( crossover-26.3-debug-register-emulation.patch )
[ -f "$HERE/patches/crossover-26.3-pf-pae-enabled.patch" ] \
    && PATCHES+=( crossover-26.3-pf-pae-enabled.patch )
[ -f "$HERE/patches/crossover-26.3-fifa16-dst-complement.patch" ] \
    && PATCHES+=( crossover-26.3-fifa16-dst-complement.patch )
# And one on top of the emulation, also mode 3 only: syscall stubs stop taking
# a fault on every call while a watchpoint covers KUSER_SHARED_DATA, which is
# what made FIFA 16 stutter. Made against the tree with all three above.
[ -f "$HERE/patches/crossover-26.3-drtrap-syscall-stub.patch" ] \
    && PATCHES+=( crossover-26.3-drtrap-syscall-stub.patch )

# What `make` is asked for, and where each artefact ends up in fixes/.
TARGETS=(
  dlls/ntdll/all
  dlls/version/all
  dlls/crypt32/all
  dlls/secur32/all
  dlls/winecoreaudio.drv/all
)
[ -f "$HERE/patches/crossover-26.3-gdiplus-delete-font-collection.patch" ] \
    && TARGETS+=( dlls/gdiplus/all )
[ -f "$HERE/patches/crossover-26.3-ole32-revoke-foreign-window.patch" ] \
    && TARGETS+=( dlls/ole32/all )
[ -f "$HERE/patches/crossover-26.3-win32u-shm-flush-under-user-lock.patch" ] \
    && TARGETS+=( dlls/win32u/all )

# The compiler for the unix half. The architecture is named here, not left to
# "arch -x86_64" (see check_deps for why that stopped being enough).
UNIX_CC="clang -arch x86_64 -m64"
# The oldest macOS the unix-half files may load on. 15.0 is what the shipped
# files in fixes/ declare; a newer SDK otherwise stamps its own version in
# (26.5 with Xcode 26), and dyld refuses the file on anything older.
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

# ---------------------------------------------------------------- the tools
check_deps() {
    local missing=0 b g

    [ "$(uname -s)" = Darwin ] || fail "This builds on macOS only."
    arch -x86_64 /usr/bin/true 2>/dev/null \
        || fail "Cannot run x86_64 binaries. On Apple silicon, install Rosetta:
             softwareupdate --install-rosetta"
    ok "macOS, and x86_64 runs"

    xcrun --find clang >/dev/null 2>&1 \
        || { bad "no clang. Install the Xcode command line tools:"
             say "            xcode-select --install"; missing=1 }
    [ "$missing" = 1 ] || ok "clang"

    # The unix half must come out x86_64, and "arch -x86_64 make" no longer
    # guarantees that: Xcode 26's clang is an arm64-only binary, so it cannot
    # run under Rosetta, runs natively, and targets arm64 unless told otherwise.
    # The linker then skips every x86_64 object and writes a 16 KB arm64
    # ntdll.so with nothing in it. So the architecture is named explicitly.
    #
    # The SDK has to be one the active linker can read. The macOS 27 SDK lists
    # an architecture (arm64e.x1) that Xcode 26's linker rejects as "malformed
    # file ... unknown architecture", and xcrun can hand out that SDK even while
    # xcode-select points at Xcode 26. Prefer the SDK inside the active
    # developer directory, which always matches its own linker.
    #   BUILD_SDKROOT=/path/to/MacOSX.sdk   use that one instead
    if [ -n "${BUILD_SDKROOT:-}" ]; then
        SDK="$BUILD_SDKROOT"
    else
        SDK="$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        [ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
    fi
    if [ -n "$SDK" ] && [ -d "$SDK" ]; then
        ok "SDK $SDK"
    else
        bad "no macOS SDK found. Set BUILD_SDKROOT to one, for example"
        say "            BUILD_SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        missing=1
    fi

    # Prove the pair works before an hour of building says otherwise: link a
    # one-line x86_64 library with exactly the settings the build will use.
    if [ "$missing" = 0 ]; then
        local probe
        probe="$(mktemp -d -t f17probe)"
        print -r -- 'int probe(void) { return 1; }' > "$probe/probe.c"
        if SDKROOT="$SDK" MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
               $=UNIX_CC -dynamiclib -o "$probe/probe.dylib" "$probe/probe.c" >"$probe/log" 2>&1 \
           && [ "$(lipo -archs "$probe/probe.dylib" 2>/dev/null)" = x86_64 ]; then
            ok "clang links x86_64 against that SDK (macOS $MIN_MACOS and newer)"
        else
            bad "clang cannot link an x86_64 library against that SDK:"
            sed 's/^/            /' "$probe/log" | head -5
            say "        Point BUILD_SDKROOT at an SDK this linker can read -- the one"
            say "        inside the Xcode that xcode-select -p names is the usual answer."
            missing=1
        fi
        rm -rf "$probe"
    fi

    if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        ok "mingw-w64 (builds the .dll half)"
    else
        bad "no x86_64-w64-mingw32-gcc. Without it --with-mingw fails and"
        say "        you get no Windows-side DLLs at all:  brew install mingw-w64"
        missing=1
    fi

    # Wine needs a newer bison than the one macOS ships.
    BISON=""
    for b in "$(brew --prefix bison 2>/dev/null)/bin/bison" /opt/homebrew/opt/bison/bin/bison; do
        [ -x "$b" ] && { BISON="$b"; break }
    done
    if [ -n "$BISON" ]; then
        ok "bison at $BISON"
    else
        bad "no homebrew bison. macOS's own is too old for Wine:"
        say "            brew install bison"
        missing=1
    fi

    # Only the gnutls *headers* are needed. CrossOver already ships the library
    # itself in lib64, and crypt32 opens it by name at runtime.
    GNUTLS_INC=""
    for g in "$(brew --prefix gnutls 2>/dev/null)/include" /opt/homebrew/include; do
        [ -d "$g/gnutls" ] && { GNUTLS_INC="$g"; break }
    done
    if [ -n "$GNUTLS_INC" ]; then
        ok "gnutls headers in $GNUTLS_INC"
    else
        bad "no gnutls headers. Without them the whole unix half of crypt32"
        say "        builds to stubs that return \"call not implemented\", and it"
        say "        compiles cleanly while doing so:  brew install gnutls"
        missing=1
    fi

    [ "$missing" = 0 ] || fail "Install what is marked BAD above, then run this again."
}

say ""
say "FIFA 17 fixes — build from source"
say "================================="
say ""
say "1. Checking the tools"
check_deps
# clang reads both from the environment, so configure, make and the
# a17hosts.dylib step below all get the same SDK and minimum macOS. The
# mingw compiler that builds the .dll half ignores them.
export SDKROOT="$SDK" MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

if [ "${1:-}" = "--deps" ]; then
    say ""
    say "Everything needed is here. Run again with the source tarball to build."
    say ""
    exit 0
fi

TARBALL="${1:-}"
[ -n "$TARBALL" ] || fail "Which source tarball?

         ./build.sh /path/to/crossover-sources-26.3.0.tar.gz

         CodeWeavers publish it with each release. These patches are against
         26.3.0 exactly -- a different version will not apply cleanly."
[ -f "$TARBALL" ] || fail "No such file: $TARBALL"
TARBALL="${TARBALL:A}"

# ------------------------------------------------------------ 2. the source
say ""
say "2. Unpacking the source"
WORK="$OUT/src"
if [ -d "$WORK/wine" ]; then
    note "reusing the tree already at $WORK/wine"
    say "        Delete $OUT to start from a pristine one -- and do that before"
    say "        trusting any checksum, because patches do not re-apply cleanly"
    say "        onto a tree that already carries them."
else
    mkdir -p "$WORK"
    tar xzf "$TARBALL" -C "$WORK" || fail "Could not unpack $TARBALL"
    # The tarball unpacks to sources/wine (and much else we do not build).
    [ -d "$WORK/sources/wine" ] && WINEDIR="$WORK/sources/wine" || WINEDIR="$WORK/wine"
    [ -d "$WINEDIR" ] || fail "No wine/ directory inside $TARBALL. Is that the right tarball?"
    [ "$WINEDIR" = "$WORK/wine" ] || { mv "$WINEDIR" "$WORK/wine"; }
    ok "unpacked to $WORK/wine"
fi
WINE="$WORK/wine"

# ----------------------------------------------------------- 3. the patches
say ""
say "3. Applying the patches, in the order that works"
for p in $PATCHES; do
    [ -f "$HERE/patches/$p" ] || fail "patches/$p is missing from this package."
    if ( cd "$WINE" && patch -p1 --dry-run --forward --silent < "$HERE/patches/$p" ) >/dev/null 2>&1; then
        ( cd "$WINE" && patch -p1 --forward --silent < "$HERE/patches/$p" ) \
            || fail "$p failed to apply."
        ok "$p"
    elif ( cd "$WINE" && patch -p1 --dry-run --reverse --silent < "$HERE/patches/$p" ) >/dev/null 2>&1; then
        ok "$p — already applied"
    else
        fail "$p will not apply to this tree.
         Either it is not crossover-sources-26.3.0, or the tree is half-patched.
         Delete $OUT and start again."
    fi
done

# ----------------------------------------------------------- 4. configuring
say ""
say "4. Configuring"
( cd "$WINE" && tools/make_requests >/dev/null ) || fail "tools/make_requests failed."
ok "make_requests"

if [ -f "$WINE/build64/Makefile" ]; then
    note "build64 is already configured — reusing it"
else
    mkdir -p "$WINE/build64"
    ( cd "$WINE/build64" && arch -x86_64 ../configure \
        --cache-file=/dev/null --enable-win64 --with-mingw \
        --without-freetype --disable-tests "BISON=$BISON" "CC=$UNIX_CC" >/dev/null ) \
        || fail "configure failed. Its output is in $WINE/build64/config.log."
    ok "configured"
fi

# This is a configure *result*, not source, so it cannot travel in a patch --
# and without it the entire unix half of crypt32 compiles to stubs that return
# STATUS_DLL_NOT_FOUND, which the PE side reports as "call not implemented".
# It builds cleanly and does nothing, which is the worst kind of failure.
if grep -q '^#define SONAME_LIBGNUTLS' "$WINE/build64/include/config.h" 2>/dev/null; then
    ok "SONAME_LIBGNUTLS already defined"
else
    sed -i '' 's|/\* #undef SONAME_LIBGNUTLS \*/|#define SONAME_LIBGNUTLS "libgnutls.30.dylib"|' \
        "$WINE/build64/include/config.h" \
        || fail "Could not define SONAME_LIBGNUTLS in build64/include/config.h."
    grep -q '^#define SONAME_LIBGNUTLS' "$WINE/build64/include/config.h" \
        || fail "SONAME_LIBGNUTLS did not take. crypt32 would build to stubs silently."
    ok "SONAME_LIBGNUTLS defined"
fi
[ -e "$WINE/build64/include/gnutls" ] \
    || ln -s "$GNUTLS_INC/gnutls" "$WINE/build64/include/gnutls"
ok "gnutls headers linked"

# Three more configure results, for exactly the same reason, and only when the
# win32u patch is here. configure above runs --without-freetype, so config.h
# leaves all three undefined -- and win32u then builds with no font code and no
# Vulkan loader, dlopens neither library, and CrossOver drops to a graphics path
# that does not work on macOS. The two SONAMEs are dylibs CrossOver already
# ships in lib64 and win32u opens by name at runtime, so only the freetype
# *headers* are needed, and the tarball carries those beside wine/.
FREETYPE_INC=""
if [ -f "$HERE/patches/crossover-26.3-win32u-shm-flush-under-user-lock.patch" ]; then
    define_config() {  # <name> <the text that follows it in the #define>
        local name="$1" value="$2" cfg="$WINE/build64/include/config.h"
        if grep -q "^#define $name" "$cfg" 2>/dev/null; then
            ok "$name already defined"
            return 0
        fi
        sed -i '' "s|/\* #undef $name \*/|#define $name $value|" "$cfg" \
            || fail "Could not define $name in build64/include/config.h."
        grep -q "^#define $name" "$cfg" \
            || fail "$name did not take. win32u would build without freetype or
         Vulkan and do it without a single warning."
        ok "$name defined"
    }
    define_config HAVE_FT2BUILD_H 1
    define_config SONAME_LIBFREETYPE '"libfreetype.dylib"'
    define_config SONAME_LIBVULKAN  '"libMoltenVK.dylib"'

    # The headers themselves. They are in the same tarball, one directory up
    # from wine/ -- sources/freetype/include -- and step 2 may or may not have
    # moved wine/ out of sources/, so look in both places.
    for d in "${WINE:h}/freetype/include" "${WINE:h}/sources/freetype/include"; do
        [ -d "$d" ] && { FREETYPE_INC="$d"; break }
    done
    [ -n "$FREETYPE_INC" ] \
        || fail "No freetype/include beside wine/ in the unpacked tarball.
         win32u cannot compile without ft2build.h. Delete $OUT and unpack the
         full crossover-sources-26.3.0.tar.gz again."
    ok "freetype headers in $FREETYPE_INC"
fi

# ------------------------------------------------------------ 5. the build
say ""
say "5. Building — this takes a while"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || print 8)"
# win32u needs the freetype headers on the command line: configure was told
# --without-freetype, so the generated Makefile has no -I for them, and the
# #define above only makes win32u try to include a header it cannot find.
# Take the flags configure actually chose out of the Makefile rather than
# hardcoding them -- overriding CFLAGS on the make line replaces them wholesale,
# and a guessed value silently changes how everything else is compiled.
# CC on the make line as well: a build64 configured before this script named
# the architecture has "CC = gcc -m64" baked into its Makefile.
MAKE_ARGS=( "CC=$UNIX_CC" )
if [ -n "$FREETYPE_INC" ]; then
    MAKE_CFLAGS="$(sed -n 's/^CFLAGS *= *//p' "$WINE/build64/Makefile" | head -1)"
    [ -n "$MAKE_CFLAGS" ] \
        || fail "No CFLAGS line in $WINE/build64/Makefile. Delete $OUT and configure again."
    MAKE_ARGS+=( "CFLAGS=$MAKE_CFLAGS -I$FREETYPE_INC" )
    ok "CFLAGS = $MAKE_CFLAGS -I$FREETYPE_INC"
fi
( cd "$WINE/build64" && arch -x86_64 make -j"$JOBS" $MAKE_ARGS $TARGETS ) \
    || fail "The build failed. The error is above."
ok "built"

# ---------------------------------------------------------- 6. collect them
say ""
say "6. Collecting"
mkdir -p "$OUT/x86_64-unix" "$OUT/x86_64-windows"
autoload -Uz is-at-least
# A unix-half file that exists is not yet a file that works. An arm64 one (the
# linker quietly dropped every x86_64 object) or one stamped with a newer
# minimum macOS than the package supports would both have passed as "ok".
check_macho() {  # <file under OUT>
    local f="$OUT/$1" archs minos
    archs="$(lipo -archs "$f" 2>/dev/null || true)"
    [ "$archs" = x86_64 ] || fail "$1 came out as '${archs:-not a Mac library}', not x86_64.
         The linker left the x86_64 objects out. Check the SDK and compiler
         lines in step 1, delete $OUT, and build again."
    minos="$(otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/ { b = 1 } b && $1 == "minos" { print $2; exit }')"
    [ -n "$minos" ] || fail "$1 carries no minimum macOS version. Build it again from a clean $OUT."
    is-at-least "$minos" "$MIN_MACOS" || fail "$1 needs macOS $minos or newer; the package supports $MIN_MACOS.
         The deployment target did not reach the build. Delete $OUT and build again."
}
collect() {  # <built path> <destination under OUT>
    # The PE half lands in dlls/<name>/x86_64-windows/<file> in this tree (the
    # unix .so files stay in dlls/<name>/); accept either layout.
    local src
    for src in "$WINE/build64/$1" "$WINE/build64/${1:h}/x86_64-windows/${1:t}"; do
        [ -f "$src" ] && break
        src=""
    done
    [ -n "$src" ] || fail "$1 was not built. Look for it above."
    cp "$src" "$OUT/$2"
    case "$2" in x86_64-unix/*) check_macho "$2" ;; esac
    ok "$2"
}
collect dlls/ntdll/ntdll.so                     x86_64-unix/ntdll.so
collect dlls/crypt32/crypt32.so                 x86_64-unix/crypt32.so
collect dlls/winecoreaudio.drv/winecoreaudio.so x86_64-unix/winecoreaudio.so
collect dlls/version/version.dll                x86_64-windows/version.dll
collect dlls/crypt32/crypt32.dll                x86_64-windows/crypt32.dll
collect dlls/secur32/secur32.dll                x86_64-windows/secur32.dll
[ -f "$HERE/patches/crossover-26.3-gdiplus-delete-font-collection.patch" ] \
    && collect dlls/gdiplus/gdiplus.dll             x86_64-windows/gdiplus.dll
[ -f "$HERE/patches/crossover-26.3-ole32-revoke-foreign-window.patch" ] \
    && collect dlls/ole32/ole32.dll                 x86_64-windows/ole32.dll
[ -f "$HERE/patches/crossover-26.3-win32u-shm-flush-under-user-lock.patch" ] \
    && collect dlls/win32u/win32u.so                x86_64-unix/win32u.so

# a17hosts.dylib is ours outright, not a patched Wine component, so it needs
# none of the above -- just clang. -arch x86_64 matches ws2_32.so, which is the
# library that loads it. The reexport is the whole trick: it makes this library
# *be* libSystem as far as ws2_32.so can tell, plus two functions of our own, so
# redirecting one load command to it changes name resolution and nothing else.
say ""
say "7. Building a17hosts.dylib"
[ -f "$HERE/fixes/a17hosts.c" ] || fail "fixes/a17hosts.c is missing from this package."
clang -arch x86_64 -O2 -Wall -Wextra -Wno-unused-parameter \
      -dynamiclib -nodefaultlibs -Wl,-reexport-lSystem \
      -install_name @rpath/a17hosts.dylib \
      -o "$OUT/x86_64-unix/a17hosts.dylib" "$HERE/fixes/a17hosts.c" \
    || fail "a17hosts.dylib did not build."
codesign --remove-signature "$OUT/x86_64-unix/a17hosts.dylib" 2>/dev/null || true
otool -L "$OUT/x86_64-unix/a17hosts.dylib" | grep -q 'reexport' \
    || fail "a17hosts.dylib built without the libSystem re-export. It would take
         malloc, strlen and dyld_stub_binder away from ws2_32.so, and nothing
         in the bottle would start."
check_macho x86_64-unix/a17hosts.dylib
ok "a17hosts.dylib"

# --------------------------------------------------------- 8. the comparison
say ""
say "8. Comparing with the files this package ships"
say ""
( cd "$OUT" && shasum -a 256 x86_64-unix/*.so x86_64-unix/*.dylib x86_64-windows/*.dll ) \
    > "$OUT/SHA256SUMS.built"

same=0; differ=0
while IFS= read -r line; do
    f="${line##* }"
    case "$f" in *.c) continue ;; esac
    want="${line%% *}"
    got="$(cd "$OUT" && shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1)"
    if [ "$want" = "$got" ]; then
        ok "$f — identical to the shipped file"
        same=$((same+1))
    else
        note "$f — differs from the shipped file"
        differ=$((differ+1))
    fi
done < "$HERE/fixes/SHA256SUMS"

say ""
say "  $same identical, $differ different."
say ""
say "  A difference is not proof of anything wrong. Wine does not build"
say "  bit-for-bit reproducibly across machines -- build paths, timestamps and"
say "  toolchain versions all end up inside the binaries. A file that *matches*"
say "  proves that patch produces that binary; one that differs needs comparing"
say "  some other way, and 'otool -l' plus a symbol diff is the usual route."
say ""
say "  Your build is in $OUT, laid out exactly like fixes/."
say "  To use it instead of ours, copy it over fixes/ and run ./setup.sh."
say ""

# ------------------------------------------------------------ Honest status
#
# What is known about these binaries, so nobody has to discover it the hard way:
#
# * Only the *online* and *win32u* patches have ever been confirmed to rebuild
#   byte-for-byte. The others have not been checked. That is why this script
#   compares and reports rather than asserting.
#
# * crypt32.dll ships at about 4.4 MB against a stock 830 KB. That is debugging
#   information left in by the build settings, not extra code. Harmless, and
#   still worth stripping before anyone calls this finished.
#
# * The context-save tracer that used to run unconditionally in ntdll.so is now
#   behind CX_CTXLOG and is off unless you set it.
#
# * win32u.so was built exactly the way this script now builds it: the three
#   config.h defines above (HAVE_FT2BUILD_H, SONAME_LIBFREETYPE,
#   SONAME_LIBVULKAN) plus the freetype headers from the tarball on CFLAGS. The
#   shipped fixes/x86_64-unix/win32u.so matched a build from this tree on
#   2026-09-15, which is as close to proof as this comparison gets.
#
# * A rebuilt ntdll.so, crypt32.so and win32u.so lose their rpath. setup.sh
#   puts it back
#   (`install_name_tool -add_rpath @loader_path/../../../lib64`); if you install
#   by hand, do not skip that step -- without it CrossOver silently drops to a
#   graphics path that does not work on macOS and the game hangs on the loading
#   screen with no clue why.
#
# * FIFA 16's four patches were applied by this script on 2026-09-29, in
#   order, on top of a tree that already carried the other eight -- not yet
#   starting from a pristine tarball. The fixes/x86_64-unix/ntdll.so that
#   ships is that build. Rerunning on that same tree fails at the rosetta
#   patch: once the emulation patch has edited its lines, the "already
#   applied" test cannot recognise it. Reverse the four (last first) or start
#   from a fresh tree.
