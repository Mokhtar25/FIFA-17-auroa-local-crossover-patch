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

set -eu

HERE="${0:A:h}"
OUT="${2:-$HERE/build-out}"

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
# A fifth, FIFA 15's, when this package ships it (the fifa15 branch does; main
# does not). See patches/README-fifa15-wine-fixes.md. It changes nothing unless
# the bottle sets CX_TOPDOWN_LIMIT, which only the FIFA 15 bottle profile does,
# so FIFA 17 bottles run the same code either way.
[ -f "$HERE/patches/crossover-26.3-topdown-alloc-limit.patch" ] \
    && PATCHES+=( crossover-26.3-topdown-alloc-limit.patch )

# What `make` is asked for, and where each artefact ends up in fixes/.
TARGETS=(
  dlls/ntdll/all
  dlls/version/all
  dlls/crypt32/all
  dlls/secur32/all
  dlls/winecoreaudio.drv/all
)

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
        --without-freetype --disable-tests "BISON=$BISON" >/dev/null ) \
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

# ------------------------------------------------------------ 5. the build
say ""
say "5. Building — this takes a while"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || print 8)"
( cd "$WINE/build64" && arch -x86_64 make -j"$JOBS" $TARGETS ) \
    || fail "The build failed. The error is above."
ok "built"

# ---------------------------------------------------------- 6. collect them
say ""
say "6. Collecting"
mkdir -p "$OUT/x86_64-unix" "$OUT/x86_64-windows"
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
    ok "$2"
}
collect dlls/ntdll/ntdll.so                     x86_64-unix/ntdll.so
collect dlls/crypt32/crypt32.so                 x86_64-unix/crypt32.so
collect dlls/winecoreaudio.drv/winecoreaudio.so x86_64-unix/winecoreaudio.so
collect dlls/version/version.dll                x86_64-windows/version.dll
collect dlls/crypt32/crypt32.dll                x86_64-windows/crypt32.dll
collect dlls/secur32/secur32.dll                x86_64-windows/secur32.dll

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
# * Only the *online* patch has ever been confirmed to rebuild byte-for-byte.
#   The others have not been checked. That is why this script compares and
#   reports rather than asserting.
#
# * crypt32.dll ships at about 4.4 MB against a stock 830 KB. That is debugging
#   information left in by the build settings, not extra code. Harmless, and
#   still worth stripping before anyone calls this finished.
#
# * The context-save tracer that used to run unconditionally in ntdll.so is now
#   behind CX_CTXLOG and is off unless you set it.
#
# * A rebuilt ntdll.so and crypt32.so lose their rpath. setup.sh puts it back
#   (`install_name_tool -add_rpath @loader_path/../../../lib64`); if you install
#   by hand, do not skip that step -- without it CrossOver silently drops to a
#   graphics path that does not work on macOS and the game hangs on the loading
#   screen with no clue why.
