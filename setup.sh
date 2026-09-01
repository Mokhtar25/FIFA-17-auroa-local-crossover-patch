#!/bin/zsh
# Installs the FIFA 17 fixes.
#
# By default it does NOT touch your CrossOver. It makes a separate copy called
# CrossOver-FIFA and puts the fixes in that, so your normal CrossOver and every
# other bottle you run in it are left exactly as they are.
#
# Everything it does can be undone by running ./uninstall.sh.
# It never touches the game, and it never downloads anything.
#
#   ./setup.sh [/path/to/CrossOver.app]   install
#   ./setup.sh --resign                   repair the signature, no re-copy
#   ./setup.sh --verify                   check an install, change nothing
#
# Exit codes:  0 verified   2 unsupported/usage   3 permission
#              4 corrupt payload or wrong CrossOver   5 incomplete install

set -eu
HERE="${0:A:h}"

E_UNSUPPORTED=2
E_PERMISSION=3
E_PAYLOAD=4
E_INCOMPLETE=5

MODE=install
case "${1:-}" in
    --resign) MODE=resign; shift ;;
    --verify) MODE=verify; shift ;;
    --help|-h)
        sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    -*) print -r -- "Unknown option: $1"; exit $E_UNSUPPORTED ;;
esac

say()  { print -r -- "$@"; }
ok()   { print -r -- "  ok    $@"; }
note() { print -r -- "  note  $@"; }
fail() { print -r -- ""; print -r -- "STOPPED: $@"; exit "${EXIT_AS:-1}"; }
die()  { EXIT_AS="$1"; shift; fail "$@"; }

# The six Wine files the fixes replace.
FILES=(
  x86_64-unix/ntdll.so
  x86_64-unix/winecoreaudio.so
  x86_64-unix/crypt32.so
  x86_64-windows/version.dll
  x86_64-windows/crypt32.dll
  x86_64-windows/secur32.dll
)
# The three that are Mach-O and therefore have to be signed.
MACHO=( ntdll.so winecoreaudio.so crypt32.so )

# Written after a successful install so uninstall knows exactly what to undo,
# rather than guessing from a list of default locations. Guessing is what made
# an earlier uninstaller delete a file out of a folder nobody had named.
RECEIPT_DIR="$HOME/Library/Application Support/Aurora17"
RECEIPT="$RECEIPT_DIR/install-receipt.conf"

# ---------------------------------------------------------------- discovery
# An explicit path always wins; otherwise the two standard locations. Spotlight
# is deliberately not consulted: it happily returns the FIFA copy, a mounted
# disk image, or any other bundle carrying CrossOver's identifier, and this
# path ends up on the wrong side of a "rm -rf".
find_crossover() {
    [ -n "${1:-}" ] && { print -r -- "${1:A}"; return; }
    local d
    for d in /Applications/CrossOver.app "$HOME/Applications/CrossOver.app"; do
        [ -d "$d" ] && { print -r -- "$d"; return; }
    done
    print -r -- "/Applications/CrossOver.app"
}
SRC="$(find_crossover "${1:-}")"

IN_PLACE="${AURORA_IN_PLACE:-0}"

# Whether the caller named the target themselves matters: an explicit path that
# turns out to be wrong must stop, never quietly become a different path that
# then gets deleted.
if [ -n "${AURORA_TARGET:-}" ]; then
    TARGET="${AURORA_TARGET:A}"
    TARGET_EXPLICIT=1
else
    TARGET="/Applications/CrossOver-FIFA.app"
    TARGET_EXPLICIT=0
fi
[ "$IN_PLACE" = "1" ] && { TARGET="$SRC"; TARGET_EXPLICIT=1; }

BOTTLE_DIR="${CX_BOTTLE_PATH:-$HOME/Library/Application Support/CrossOver/Bottles}"
BOTTLE="${AURORA_BOTTLE:-Aurora17}"

# --------------------------------------------------------- safety guards
# Everything below eventually reaches "rm -rf $TARGET" or "ditto ... $TARGET".
# An unset variable falls back to the safe default, but an explicitly supplied
# one is taken at its word, so it has to be checked rather than trusted.
assert_safe_target() {
    local t="$1"
    case "$t" in
        /*) ;;
        *) die $E_UNSUPPORTED "Refusing a target that is not an absolute path: $t" ;;
    esac
    case "$t" in
        *.app) ;;
        *) die $E_UNSUPPORTED "Refusing a target that is not an .app bundle: $t
         AURORA_TARGET must name the application to create, for example
         AURORA_TARGET=/Applications/CrossOver-FIFA.app" ;;
    esac
    case "${t:A}" in
        / | /Applications | /Users | /System | /Library | "$HOME" | "$HOME/Applications")
            die $E_UNSUPPORTED "Refusing to use $t as the target." ;;
    esac
    [ "${#t}" -gt 5 ] || die $E_UNSUPPORTED "Refusing a suspiciously short target: $t"
}

# Deleting a directory only because it sits at the expected path is how you
# destroy somebody's unrelated application. Require it to be CrossOver.
is_crossover_bundle() {
    local id
    id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
             "$1/Contents/Info.plist" 2>/dev/null) || return 1
    [ "$id" = "com.codeweavers.CrossOver" ]
}

crossover_version() {
    /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
        "$1/Contents/Info.plist" 2>/dev/null || print -r -- "unknown"
}

# pgrep -f takes a regular expression, and a path can contain characters that
# mean something to one.
pgrep_quote() { print -r -- "$1" | sed 's/[][^$.*+?(){}|\\\/]/\\&/g'; }

app_is_running() {
    local pat
    pat=$(pgrep_quote "$1/Contents/MacOS")
    pgrep -f "$pat" >/dev/null 2>&1
}

# ------------------------------------------------------------- signing
# We can only sign ad-hoc -- we are not CodeWeavers and cannot use their
# certificate. That matters more than it sounds. CrossOver is built with the
# hardened runtime, which turns on *library validation*: every library the
# process loads must carry the same Team ID as the process itself. Sign the app
# ad-hoc and its Team ID becomes empty, while the frameworks inside it still
# carry CodeWeavers' -- so the app dies at launch before showing a window:
#
#   Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
#   Reason: mapping process and mapped file have different Team IDs
#
# Adding com.apple.security.cs.disable-library-validation is what allows the
# mixture. The alternative, --deep, would re-sign a gigabyte of nested code to
# fix a rule we can simply switch off.
LIBVAL_KEY="com.apple.security.cs.disable-library-validation"

# LC_UUID identifies a Mach-O file across an added rpath and a re-signing,
# both of which change its bytes.
macho_uuid() {
    otool -l "$1" 2>/dev/null | awk '/LC_UUID/{getline; print $2; exit}'
}

# The keys currently on a bundle, one per line.
entitlement_keys() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c 'Print' "$plist" 2>/dev/null \
        | sed -n 's/^ *\([A-Za-z0-9._-]*\) = .*/\1/p'
}

sign_payload() {
    local wine="$1" so
    for so in $MACHO; do
        [ -f "$wine/x86_64-unix/$so" ] \
            || fail "$so is missing from $wine/x86_64-unix."
        codesign --force --sign - "$wine/x86_64-unix/$so" 2>/dev/null \
            || fail "Could not sign $so.
         The copy is incomplete. Run ./uninstall.sh and try again."
    done
    ok "the three Mac files"
}

resign_app() {
    local app="$1"
    local ent after
    ent="$(mktemp -t cxent).plist"
    after="$(mktemp -t cxent).plist"

    # Failing to read the original entitlements is not the same as there being
    # none. Treating it as "none" is how the four CrossOver needs get silently
    # dropped, which breaks microphone, camera, and Apple Events afterwards.
    codesign -d --entitlements "$ent" --xml "$app" 2>/dev/null && [ -s "$ent" ] \
        || { rm -f "$ent" "$after"
             fail "Could not read CrossOver's own permissions from $app.
         Signing without them would take away microphone, camera and
         Apple Events access. Nothing has been signed." }

    local -a before_keys
    before_keys=( ${(f)"$(entitlement_keys "$ent")"} )
    [ "${#before_keys}" -gt 0 ] \
        || { rm -f "$ent" "$after"
             fail "CrossOver's permission list came back empty. Nothing signed." }
    ok "kept CrossOver's ${#before_keys} permissions"

    /usr/libexec/PlistBuddy -c "Add :$LIBVAL_KEY bool true" "$ent" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Set :$LIBVAL_KEY true" "$ent" >/dev/null 2>&1 \
        || { rm -f "$ent" "$after"
             fail "Could not add the permission that lets the copy load its own
         frameworks. Without it the app will not open at all. Nothing signed." }
    ok "allowed it to load its own frameworks"

    codesign --force --sign - -o runtime --entitlements "$ent" "$app" 2>/dev/null \
        || { rm -f "$ent" "$after"
             fail "Could not sign $app.
         It will not launch until it is signed. Try:  ./setup.sh --resign" }
    ok "signed $app"

    # Read back what actually landed. codesign can succeed and still not carry
    # what we handed it, and that failure is invisible until the app will not
    # open, which is a miserable thing to debug from the other end.
    codesign -d --entitlements "$after" --xml "$app" 2>/dev/null && [ -s "$after" ] \
        || { rm -f "$ent" "$after"
             fail "Signed $app but could not read its permissions back." }

    local -a now_keys
    now_keys=( ${(f)"$(entitlement_keys "$after")"} )
    local k missing=""
    for k in $before_keys; do
        [[ " ${now_keys[*]} " == *" $k "* ]] || missing="$missing $k"
    done
    [ -z "$missing" ] || { rm -f "$ent" "$after"
        fail "Signing lost these permissions:$missing
         Run ./uninstall.sh and install again." }
    [[ " ${now_keys[*]} " == *" $LIBVAL_KEY "* ]] || { rm -f "$ent" "$after"
        fail "The permission that lets the copy load its own frameworks did not
         stick. The app would not open. Run ./setup.sh --resign." }
    ok "all ${#now_keys} permissions verified on the signed app"
    rm -f "$ent" "$after"

    # If this is wrong the app dies at launch with a dyld error and no window.
    codesign --verify --deep --strict "$app" 2>/dev/null \
        || fail "The new signature on $app did not verify.
         The app would not open. Run:  ./setup.sh --resign
         If that does not help, run ./uninstall.sh and install again."
    ok "signature verifies"
}

# ------------------------------------------------------------- --verify
# Checks an install without changing anything. Every troubleshooting step in
# SETUP.md can point here instead of at a re-install.
verify_install() {
    local app="$1" problems=0
    say ""
    say "Checking $app"
    say ""

    [ -d "$app" ] || { say "  BAD   there is no app at $app"; return 1; }
    is_crossover_bundle "$app" \
        && ok "is a CrossOver bundle" \
        || { say "  BAD   $app is not a CrossOver bundle"; problems=$((problems+1)); }

    local wine="$app/Contents/SharedSupport/CrossOver/lib/wine" f
    if ! ( cd "$HERE/fixes" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1; then
        say "  BAD   fixes/ does not match its own checksums; cannot compare"
        return 1
    fi
    for f in $FILES; do
        if [ ! -f "$wine/$f" ]; then
            say "  BAD   ${f:t} is missing"; problems=$((problems+1)); continue
        fi
        case "$f" in
        *.dll)
            # Installed unchanged, so a byte comparison is the whole story.
            cmp -s "$HERE/fixes/$f" "$wine/$f" \
                && ok "${f:t}" \
                || { say "  BAD   ${f:t} is not the fixed version"; problems=$((problems+1)); }
            ;;
        *.so)
            # These three are modified after installation -- an rpath is added
            # and they are signed ad-hoc -- so their bytes no longer match the
            # shipped file. LC_UUID survives both, so it is what identifies them.
            if [ "$(macho_uuid "$wine/$f")" = "$(macho_uuid "$HERE/fixes/$f")" ]; then
                ok "${f:t}"
            else
                say "  BAD   ${f:t} is not the fixed version"; problems=$((problems+1))
            fi
            ;;
        esac
    done

    local so
    for so in ntdll.so crypt32.so; do
        otool -l "$wine/x86_64-unix/$so" 2>/dev/null | grep -q 'lib64' \
            && ok "$so search path" \
            || { say "  BAD   $so is missing its library search path"; problems=$((problems+1)); }
    done
    for so in $MACHO; do
        codesign --verify "$wine/x86_64-unix/$so" 2>/dev/null \
            || { say "  BAD   $so is not signed — run ./setup.sh --resign"; problems=$((problems+1)); }
    done

    local ent; ent="$(mktemp -t cxent).plist"
    if codesign -d --entitlements "$ent" --xml "$app" 2>/dev/null && [ -s "$ent" ]; then
        local -a keys; keys=( ${(f)"$(entitlement_keys "$ent")"} )
        [[ " ${keys[*]} " == *" $LIBVAL_KEY "* ]] \
            && ok "${#keys} permissions, including the framework one" \
            || { say "  BAD   the framework permission is missing — run ./setup.sh --resign"
                 problems=$((problems+1)); }
    else
        say "  BAD   cannot read the app's permissions — run ./setup.sh --resign"
        problems=$((problems+1))
    fi
    rm -f "$ent"

    codesign --verify --deep --strict "$app" 2>/dev/null \
        && ok "signature" \
        || { say "  BAD   signature does not verify — run ./setup.sh --resign"; problems=$((problems+1)); }

    local conf="$BOTTLE_DIR/$BOTTLE/cxbottle.conf" k v kv
    if [ -f "$conf" ]; then
        for kv in "CX_GRAPHICS_BACKEND=d3dmetal" "CX_DR_TRAP=2" "WINE_SIMULATE_WRITECOPY=1"; do
            k="${kv%%=*}"; v="${kv#*=}"
            grep -q "^\"$k\" = \"$v\"\$" "$conf" \
                && ok "$k" \
                || { say "  BAD   $k is not set to $v in the $BOTTLE bottle"; problems=$((problems+1)); }
        done
    else
        say "  BAD   no bottle called '$BOTTLE' at $BOTTLE_DIR"
        problems=$((problems+1))
    fi

    # PLAY only needs one of the two stand-in locations to be right.
    local psdir="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
    local found=0 d
    if cmp -s "$HERE/aurora17/powershell.exe" "$psdir/powershell.exe" 2>/dev/null; then
        ok "PowerShell stand-in in the bottle"; found=1
    fi
    for d in "${AURORA_DIR:-}" "$HOME/Downloads/Aurora17" "$HOME/Aurora17" "$HOME/Desktop/Aurora17"; do
        [ -n "$d" ] || continue
        if cmp -s "$HERE/aurora17/powershell.exe" "$d/powershell.exe" 2>/dev/null; then
            ok "PowerShell stand-in in $d"; found=1; break
        fi
    done
    [ "$found" = 1 ] || { say "  BAD   the PowerShell stand-in is in neither place — PLAY will do nothing"
                          problems=$((problems+1)); }

    say ""
    if [ "$problems" -eq 0 ]; then
        say "Everything checks out."
        return 0
    fi
    say "$problems problem(s) above. SETUP.md says what each one means."
    return 1
}

say ""
say "FIFA 17 fixes — setup"
say "====================="

if [ "$MODE" = verify ]; then
    if [ ! -d "$TARGET" ] && [ "$TARGET_EXPLICIT" = 0 ] \
       && [ -d "$HOME/Applications/${TARGET:t}" ]; then
        TARGET="$HOME/Applications/${TARGET:t}"
    fi
    verify_install "$TARGET" || exit $E_INCOMPLETE
    exit 0
fi

# ------------------------------------------------------- --resign, and stop
# Repairs the signature on a CrossOver-FIFA that already exists. Signing is the
# one step that can leave the app unable to open at all, and re-copying a
# gigabyte to redo it would be absurd.
if [ "$MODE" = resign ]; then
    if [ ! -d "$TARGET" ] && [ "$TARGET_EXPLICIT" = 0 ]; then
        TARGET="$HOME/Applications/${TARGET:t}"
    fi
    [ -d "$TARGET" ] || die $E_PAYLOAD "No CrossOver-FIFA to re-sign at $TARGET.
         If yours is somewhere else:
             AURORA_TARGET=/path/to/CrossOver-FIFA.app ./setup.sh --resign"
    is_crossover_bundle "$TARGET" \
        || die $E_PAYLOAD "$TARGET is not a CrossOver bundle. Refusing to sign it."
    say ""
    say "Re-signing $TARGET"
    say ""
    sign_payload "$TARGET/Contents/SharedSupport/CrossOver/lib/wine"
    resign_app "$TARGET"
    say ""
    say "Done. Open ${TARGET:t:r} again."
    say ""
    exit 0
fi

# =========================================================================
# Preflight. Everything that can say no has to say it before anything is
# deleted or copied -- a corrupt download must not be able to destroy a
# working install and then stop half way through.
# =========================================================================
say ""
say "1. Checking"

case "$(uname -s)" in
    Darwin) ;;
    *) die $E_UNSUPPORTED "These fixes are for macOS." ;;
esac
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ] \
    || die $E_UNSUPPORTED "These fixes are for Apple silicon Macs (M1 or newer).
         The six replacement files are built for that and nothing else."
OSVER="$(sw_vers -productVersion)"
case "$OSVER" in
    1[0-3].*|[0-9].*) die $E_UNSUPPORTED "These fixes need macOS 14 or newer. You have $OSVER." ;;
esac
ok "macOS $OSVER on Apple silicon"

[ -d "$SRC" ] || die $E_PAYLOAD "No CrossOver at $SRC.
         If yours is somewhere else, run:  ./setup.sh /path/to/CrossOver.app"
is_crossover_bundle "$SRC" \
    || die $E_PAYLOAD "$SRC is not a CrossOver application."

# 26.3* would also accept 26.30 and 26.3-beta, which are not what these files
# were built against.
VER="$(crossover_version "$SRC")"
[ "$VER" = "26.3" ] || die $E_PAYLOAD "These fixes are built for CrossOver 26.3 exactly. You have $VER.
         Installing them into a different version will not work.
         Install CrossOver 26.3."
ok "CrossOver $VER at $SRC"

SRCWINE="$SRC/Contents/SharedSupport/CrossOver/lib/wine"
for f in $FILES; do
    [ -f "$SRCWINE/$f" ] \
        || die $E_PAYLOAD "$f is missing from $SRC. That is not a complete CrossOver 26.3."
done
ok "all six files present in CrossOver"

# Verify the payload we are about to install before touching anything, not
# after the working copy has already been deleted.
( cd "$HERE/fixes" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1 \
    || die $E_PAYLOAD "The files in fixes/ do not match their checksums.
         Do not install these. Download the package again and re-extract it."
( cd "$HERE/aurora17" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1 \
    || die $E_PAYLOAD "The files in aurora17/ do not match their checksums.
         Do not install these. Download the package again and re-extract it."
ok "the files to install match their checksums"

if [ "$IN_PLACE" != "1" ]; then
    assert_safe_target "$TARGET"
    [ "${SRC:A}" != "${TARGET:A}" ] \
        || die $E_UNSUPPORTED "The source and the copy are the same app:
             $SRC
         Pass the real CrossOver as the source, or set AURORA_TARGET to a
         different path."

    # /Applications is normal but is not writable on every Mac. Fall back to
    # ~/Applications only when the caller did not name the target themselves;
    # an explicit path that cannot be created is an error, not an invitation
    # to create a different one and later delete it.
    PROBE_DIR="$(mktemp -d "${TARGET:h}/.aurora17-probe.XXXXXX" 2>/dev/null || true)"
    if [ -z "$PROBE_DIR" ]; then
        if [ "$TARGET_EXPLICIT" = 1 ]; then
            die $E_PERMISSION "Cannot create anything in ${TARGET:h}, and AURORA_TARGET
         named it explicitly. Choose a folder you can write to."
        fi
        note "cannot create anything in ${TARGET:h}"
        mkdir -p "$HOME/Applications" \
            || die $E_PERMISSION "Cannot create $HOME/Applications either."
        TARGET="$HOME/Applications/${TARGET:t}"
        assert_safe_target "$TARGET"
        PROBE_DIR="$(mktemp -d "${TARGET:h}/.aurora17-probe.XXXXXX" 2>/dev/null || true)"
        [ -n "$PROBE_DIR" ] \
            || die $E_PERMISSION "Cannot create anything in ${TARGET:h}."
        say "        using $TARGET instead"
    fi
    rmdir "$PROBE_DIR" 2>/dev/null || true

    APPSIZE_K=$(du -sk "$SRC" | awk '{print $1}')
    FREE_K=$(df -Pk "${TARGET:h}" | tail -1 | awk '{print $4}')
    case "$APPSIZE_K$FREE_K" in
        ''|*[!0-9]*) die $E_UNSUPPORTED "Could not work out the disk space. Free about 2 GB and try again." ;;
    esac
    # The previous copy is deleted before the new one is made, so its space is
    # about to come back. Not counting it rejects reinstalls that would fit.
    RECLAIM_K=0
    if [ -d "$TARGET" ]; then
        RECLAIM_K=$(du -sk "$TARGET" 2>/dev/null | awk '{print $1}')
    fi
    case "$RECLAIM_K" in ''|*[!0-9]*) RECLAIM_K=0 ;; esac
    if [ $((FREE_K + RECLAIM_K)) -lt $((APPSIZE_K + 500000)) ]; then
        die $E_UNSUPPORTED "Not enough disk space. The copy needs about $((APPSIZE_K / 1024)) MB
         and there is $(( (FREE_K + RECLAIM_K) / 1024 )) MB free.
         Free up some space and run this again."
    fi
    ok "room for the $((APPSIZE_K / 1024)) MB copy"

    # An existing target has to be CrossOver before it can be deleted.
    if [ -e "$TARGET" ]; then
        [ -d "$TARGET" ] \
            || die $E_UNSUPPORTED "$TARGET exists and is not an application. Refusing to remove it."
        is_crossover_bundle "$TARGET" \
            || die $E_UNSUPPORTED "$TARGET is not a CrossOver bundle. Refusing to remove it.
         Move it out of the way, or set AURORA_TARGET to another path."
        if app_is_running "$TARGET"; then
            die $E_PERMISSION "$TARGET is running. Quit it first, then run this again."
        fi
    fi
fi
if [ "$IN_PLACE" = "1" ] && app_is_running "$SRC"; then
    die $E_PERMISSION "$SRC is running. Quit it first, then run this again."
fi

# =========================================================================
# From here on things change on disk.
# =========================================================================
say ""
if [ "$IN_PLACE" = "1" ]; then
    say "2. Using your real CrossOver (AURORA_IN_PLACE=1)"
    say "        This changes every bottle you run in CrossOver, not just FIFA."
    say "        ./uninstall.sh puts the six files back, but it cannot restore"
    say "        CodeWeavers' own signature -- only reinstalling CrossOver does."
else
    say "2. Making a separate CrossOver for FIFA"
    if [ -d "$TARGET" ]; then
        rm -rf "$TARGET"
        ok "removed the previous copy"
    fi
    ok "copying $((APPSIZE_K / 1024)) MB — this takes a moment"
    ditto "$SRC" "$TARGET" \
        || die $E_PERMISSION "Could not copy CrossOver to $TARGET.
         Check the disk space and that you can write to ${TARGET:h}."
    ok "made $TARGET"
    say "        your own CrossOver at $SRC is untouched"
fi

APP="$TARGET"
WINE="$APP/Contents/SharedSupport/CrossOver/lib/wine"
[ -d "$WINE/x86_64-unix" ] || die $E_PAYLOAD "$APP does not look like CrossOver 26.3 inside."

# Since macOS 14, a signed app bundle is protected by a permission called "App
# Management" that belongs to the program running this script, not to you. The
# folder can be owned by you, with write permission, and still refuse writes --
# so [ -w ] says yes and the first cp then fails with "Operation not permitted".
# Probe with a real write, up front, so macOS asks now rather than half way in.
PROBE="$(mktemp "$WINE/x86_64-unix/.aurora17-probe.XXXXXX" 2>/dev/null || true)"
if [ -z "$PROBE" ]; then
    print -r -- ""
    print -r -- "STOPPED: macOS will not let this change $APP."
    print -r -- ""
    print -r -- "         It is a signed app, and since macOS 14 changing one needs a"
    print -r -- "         permission called App Management. It belongs to the program"
    print -r -- "         running this installer -- your Terminal -- not to you, which is"
    print -r -- "         why the folder looks writable but is not."
    print -r -- ""
    print -r -- "         Turn it on:"
    print -r -- "           System Settings -> Privacy & Security -> App Management"
    print -r -- "           switch on Terminal (or iTerm, or whatever you ran this from)"
    print -r -- "           QUIT that app completely, reopen it, and run this again"
    print -r -- ""
    print -r -- "         If it is not listed there, use Full Disk Access instead,"
    print -r -- "         in the same Privacy & Security list. That covers it too."
    print -r -- ""
    print -r -- "         Nothing has been changed inside CrossOver."
    exit $E_PERMISSION
fi
rm -f "$PROBE"

# ------------------------------------------------------------- 3. backup
# Only in-place installs can ever use these. The default install is undone by
# deleting the whole copy, so writing .orig files into it would be six pointless
# writes and six more things to go wrong.
say ""
if [ "$IN_PLACE" = "1" ]; then
    say "3. Backing up the files we replace"
    for f in $FILES; do
        if [ -f "$WINE/$f.orig" ]; then
            ok "${f:t} — backup already exists, keeping it"
        else
            cp "$WINE/$f" "$WINE/$f.orig" \
                || die $E_PERMISSION "Could not back up $f."
            ok "${f:t} → ${f:t}.orig"
        fi
    done
else
    say "3. No backups needed — undoing this deletes the copy"
fi

# ------------------------------------------------------------- 4. install
say ""
say "4. Installing the fixes"
for f in $FILES; do
    # -X copies without extended attributes, so com.apple.quarantine -- which
    # every file that arrived inside a downloaded zip carries -- never reaches
    # the installed copy. Left on, Gatekeeper can refuse to load it and the
    # failure is obscure.
    cp -X "$HERE/fixes/$f" "$WINE/$f" \
        || die $E_PERMISSION "Could not install $f into $APP."
    ok "${f:t}"
done

# ------------------------------------------------- 5. the search path fix
# Both rebuilt .so files lose it, and both need it: ntdll.so to find its sibling
# libraries, crypt32.so to find the gnutls CrossOver already ships in lib64.
# Without it CrossOver silently falls back to a graphics path that does not work
# on macOS, and the game hangs on the loading screen forever.
say ""
say "5. Repairing the library search path"
for so in ntdll.so crypt32.so; do
    if otool -l "$WINE/x86_64-unix/$so" | grep -q 'lib64'; then
        ok "$so — already present"
    else
        install_name_tool -add_rpath '@loader_path/../../../lib64' "$WINE/x86_64-unix/$so" \
            || die $E_PERMISSION "Could not repair the search path in $so."
        ok "$so — added"
    fi
done

# ------------------------------------------------------------- 6. re-sign
say ""
say "6. Signing"
sign_payload "$WINE"
resign_app "$APP"

# --------------------------------------------------- 7. the bottle settings
# These settings are what the game needs. Putting them in the bottle means you
# can launch normally from CrossOver instead of needing a Terminal script.
# Bottles are shared between CrossOver and the copy, so this is set once.
say ""
say "7. Adding the settings to your bottle"
BOTTLE_OK=0
CONF="$BOTTLE_DIR/$BOTTLE/cxbottle.conf"
if [ ! -f "$CONF" ]; then
    note "no bottle called '$BOTTLE' found at"
    say "        $BOTTLE_DIR"
    say "        FIFA will not start without these settings. Once the bottle"
    say "        exists, run:   AURORA_BOTTLE='name' ./setup.sh --resign"
    say "        or re-run this installer."
else
    add_setting() {
        # A key that is present with the wrong value is not "already set". Left
        # alone it silently keeps the wrong graphics backend and the game hangs.
        if grep -q "^\"$1\" = \"$2\"\$" "$CONF"; then
            ok "$1 — already set"
        elif grep -q "^\"$1\" = " "$CONF"; then
            fail "$1 is set to something else in
             $CONF
         It must be \"$2\". Edit that line, or delete it and run this again."
        else
            printf '"%s" = "%s"\n' "$1" "$2" >> "$CONF"
            ok "$1 = $2"
        fi
    }
    grep -q '^\[EnvironmentVariables\]' "$CONF" || printf '\n[EnvironmentVariables]\n' >> "$CONF"
    add_setting CX_GRAPHICS_BACKEND d3dmetal
    add_setting CX_DR_TRAP 2
    add_setting WINE_SIMULATE_WRITECOPY 1

    # The sound fix. A Microsoft Teams audio driver, if you have one, stops
    # answering and freezes any program that asks it anything -- including the
    # game, before it reaches the menu. This is not CrossOver's fault and not
    # the game's; the same thing happens to ordinary Mac programs. We skip that
    # one device by name. If you do not have the driver, you do not need this.
    if [ -d "/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver" ]; then
        add_setting WINE_COREAUDIO_EXCLUDE "Microsoft Teams Audio"
        say "        (found the Teams audio driver — added the sound fix)"
    else
        ok "no Teams audio driver here, sound fix not needed"
    fi
    BOTTLE_OK=1
fi

# ------------------------------------------------ 8. the PowerShell stand-in
# Aurora17's PLAY button does its real work by running scripts/Play.ps1 through
# powershell.exe. Wine ships a powershell.exe that is a stub: it prints a FIXME
# and returns 0 without executing anything. Aurora only checks the exit code, so
# the stub's silent success made PLAY do nothing at all, with no error. This
# installs a small native stand-in that performs the same work.
say ""
say "8. Installing the PowerShell stand-in Aurora17 needs"
PS_OK=0
PS_AURORA_DIR=""
PS_BOTTLE_ACTION=""

# Where is the extracted Aurora17 folder? CreateProcess looks in the calling
# program's own directory first, so a copy there always wins.
# An explicit AURORA_DIR means that folder and no other.
if [ -n "${AURORA_DIR:-}" ]; then
    AURORA_CANDIDATES=( "${AURORA_DIR:A}" )
else
    AURORA_CANDIDATES=(
      "$HOME/Downloads/Aurora17"
      "$HOME/Aurora17"
      "$HOME/Desktop/Aurora17"
    )
fi
AURORA_FOUND=""
for d in $AURORA_CANDIDATES; do
    [ -n "$d" ] || continue
    if [ -f "$d/Aurora17Connector.exe" ]; then AURORA_FOUND="$d"; break; fi
done
if [ -n "$AURORA_FOUND" ]; then
    # Never overwrite somebody's real powershell.exe without keeping it.
    if [ -f "$AURORA_FOUND/powershell.exe" ] \
       && ! cmp -s "$HERE/aurora17/powershell.exe" "$AURORA_FOUND/powershell.exe" \
       && [ ! -f "$AURORA_FOUND/powershell.exe.aurora-orig" ]; then
        cp -X "$AURORA_FOUND/powershell.exe" "$AURORA_FOUND/powershell.exe.aurora-orig" \
            || die $E_PERMISSION "Could not back up the powershell.exe already in $AURORA_FOUND."
        note "kept the powershell.exe already there as powershell.exe.aurora-orig"
    fi
    cp -X "$HERE/aurora17/powershell.exe" "$AURORA_FOUND/powershell.exe" \
        || die $E_PERMISSION "Could not write into $AURORA_FOUND."
    ok "into $AURORA_FOUND"
    PS_AURORA_DIR="$AURORA_FOUND"
    PS_OK=1
else
    note "no Aurora17 folder found. If yours is elsewhere, run:"
    say "        AURORA_DIR=/path/to/Aurora17 ./setup.sh"
fi

# Also install it inside the bottle, so it is found no matter where Aurora17
# lives. The file being replaced is Wine's own stub; we keep a copy of it.
PSDIR="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
if [ -d "$BOTTLE_DIR/$BOTTLE" ]; then
    if [ -d "$PSDIR" ] && [ -f "$PSDIR/powershell.exe" ]; then
        [ -f "$PSDIR/powershell.exe.wine-stub-orig" ] \
            || cp -X "$PSDIR/powershell.exe" "$PSDIR/powershell.exe.wine-stub-orig"
        PS_BOTTLE_ACTION=replaced
    else
        mkdir -p "$PSDIR"
        PS_BOTTLE_ACTION=created
    fi
    cp -X "$HERE/aurora17/powershell.exe" "$PSDIR/powershell.exe" \
        || die $E_PERMISSION "Could not write the stand-in into the $BOTTLE bottle."
    ok "into the $BOTTLE bottle ($PS_BOTTLE_ACTION)"
    PS_OK=1
fi

# ------------------------------------------------------------- the receipt
# Uninstall reads this instead of guessing at default locations.
mkdir -p "$RECEIPT_DIR"
{
    print -r -- "# Written by setup.sh. Delete this only if you have already uninstalled."
    print -r -- "mode=$([ "$IN_PLACE" = "1" ] && print in-place || print copy)"
    print -r -- "target=$TARGET"
    print -r -- "source=$SRC"
    print -r -- "bottle_dir=$BOTTLE_DIR"
    print -r -- "bottle=$BOTTLE"
    print -r -- "aurora_dir=$PS_AURORA_DIR"
    print -r -- "bottle_powershell=$PS_BOTTLE_ACTION"
    print -r -- "version=$VER"
    print -r -- "installed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$RECEIPT"

# ------------------------------------------------------------- the verdict
# "Done" has to mean the game will start. A missing bottle or a missing
# stand-in means PLAY does nothing, and saying Done to that wastes an evening.
say ""
if [ "$BOTTLE_OK" = 1 ] && [ "$PS_OK" = 1 ]; then
    say "Done."
    say ""
    if [ "$IN_PLACE" = "1" ]; then
        say "To play:  open CrossOver, then open Aurora17 in the $BOTTLE bottle"
        say "          and press PLAY FIFA 17."
    else
        say "To play:  open ${TARGET:t:r}  (not your normal CrossOver)"
        say "          then open Aurora17 in the $BOTTLE bottle and press PLAY FIFA 17."
        say ""
        say "          It is at $TARGET"
        say "          Your normal CrossOver is unchanged, and so is every other"
        say "          bottle you run in it. Both share the same bottles, so do not"
        say "          run the same bottle in both at once."
    fi
    say ""
    say "To check an install at any time:  ./setup.sh --verify"
    say "To undo everything:               ./uninstall.sh"
    say ""
    exit 0
fi

say "NOT FINISHED — CrossOver is patched, but the game will not start yet."
say ""
if [ "$BOTTLE_OK" != 1 ]; then
    say "  * the '$BOTTLE' bottle has none of the settings FIFA needs"
fi
if [ "$PS_OK" != 1 ]; then
    say "  * the PowerShell stand-in is nowhere Aurora17 will find it, so PLAY"
    say "    will appear to work and do nothing at all"
fi
say ""
say "Fix whichever is listed above, then run this again. ./setup.sh --verify"
say "will tell you when everything is in place."
say ""
exit $E_INCOMPLETE
