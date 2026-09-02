#!/bin/zsh
# Undoes what setup.sh did.
#
# It reads the receipt setup.sh wrote and undoes exactly what is recorded there,
# rather than searching the usual places. Searching is how an earlier version of
# this script deleted a file out of a folder nobody had named, and how a plain
# uninstall could reach into the real CrossOver.
#
# Bottle settings are left alone -- they are harmless without the fixes, and
# removing them by script risks damaging the file.

set -eu
HERE="${0:A:h}"

# Same override setup.sh takes, so the throwaway-tree test undoes the install
# it made rather than the real one.
RECEIPT="${AURORA_RECEIPT_DIR:-$HOME/Library/Application Support/Aurora17}/install-receipt.conf"

say()  { print -r -- "$@"; }
ok()   { print -r -- "  ok    $@"; }
note() { print -r -- "  note  $@"; }
fail() { print -r -- ""; print -r -- "STOPPED: $@"; exit 1; }

# ------------------------------------------------------------- the receipt
R_MODE=""; R_TARGET=""; R_BOTTLE_DIR=""; R_BOTTLE=""
R_AURORA_DIR=""; R_BOTTLE_PS=""
if [ -f "$RECEIPT" ]; then
    while IFS= read -r line; do
        case "$line" in
            \#*|"") continue ;;
            mode=*)              R_MODE="${line#*=}" ;;
            target=*)            R_TARGET="${line#*=}" ;;
            bottle_dir=*)        R_BOTTLE_DIR="${line#*=}" ;;
            bottle=*)            R_BOTTLE="${line#*=}" ;;
            aurora_dir=*)        R_AURORA_DIR="${line#*=}" ;;
            bottle_powershell=*) R_BOTTLE_PS="${line#*=}" ;;
        esac
    done < "$RECEIPT"
fi

# The environment still overrides, for the case where the receipt is gone. What
# it must never do is silently widen the scope: an explicitly named path that
# does not exist is an error, not a licence to go looking for another one.
if [ -n "${AURORA_IN_PLACE:-}" ]; then
    if [ "$AURORA_IN_PLACE" = "1" ]; then MODE=in-place; else MODE=copy; fi
else
    MODE="${R_MODE:-copy}"
fi

if [ -n "${AURORA_TARGET:-}" ]; then
    TARGET="${AURORA_TARGET:A}"; TARGET_EXPLICIT=1
elif [ -n "$R_TARGET" ]; then
    TARGET="$R_TARGET"; TARGET_EXPLICIT=1
else
    TARGET="/Applications/CrossOver-FIFA.app"; TARGET_EXPLICIT=0
fi

BOTTLE_DIR="${CX_BOTTLE_PATH:-${R_BOTTLE_DIR:-$HOME/Library/Application Support/CrossOver/Bottles}}"
BOTTLE="${AURORA_BOTTLE:-${R_BOTTLE:-Aurora17}}"

# Same guards as setup.sh. Everything below reaches an rm -rf.
assert_safe_target() {
    local t="$1"
    case "$t" in /*) ;; *) fail "Refusing a target that is not an absolute path: $t" ;; esac
    case "$t" in *.app) ;; *) fail "Refusing a target that is not an .app bundle: $t" ;; esac
    case "${t:A}" in
        / | /Applications | /Users | /System | /Library | "$HOME" | "$HOME/Applications")
            fail "Refusing to remove $t." ;;
    esac
    [ "${#t}" -gt 5 ] || fail "Refusing a suspiciously short target: $t"
}

is_crossover_bundle() {
    local id
    id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
             "$1/Contents/Info.plist" 2>/dev/null) || return 1
    [ "$id" = "com.codeweavers.CrossOver" ]
}

pgrep_quote() { print -r -- "$1" | sed 's/[][^$.*+?(){}|\\\/]/\\&/g'; }
app_is_running() {
    local pat; pat=$(pgrep_quote "$1/Contents/MacOS")
    pgrep -f "$pat" >/dev/null 2>&1
}

FILES=(
  x86_64-unix/ntdll.so
  x86_64-unix/winecoreaudio.so
  x86_64-unix/crypt32.so
  x86_64-windows/version.dll
  x86_64-windows/crypt32.dll
  x86_64-windows/secur32.dll
)

say ""
say "Removing the FIFA 17 fixes"
say ""
[ -f "$RECEIPT" ] && ok "using the record written when it was installed" \
                  || note "no install record found; undoing the default install only"
say ""

undone=0

# ======================================================================
# Exactly one of these two runs. Which one is decided by the recorded
# install mode, never by what happens to be lying around on disk.
# ======================================================================
if [ "$MODE" = "in-place" ]; then
    # ------------------------------------------------- an in-place install
    APP="${1:-$TARGET}"
    [ -d "$APP" ] || fail "The recorded CrossOver is not at
             $APP
         Nothing has been changed."
    is_crossover_bundle "$APP" || fail "$APP is not a CrossOver bundle. Nothing changed."
    if app_is_running "$APP"; then
        fail "$APP is running. Quit it first, then run this again."
    fi

    WINE="$APP/Contents/SharedSupport/CrossOver/lib/wine"
    put_back=0
    for f in $FILES; do
        if [ -f "$WINE/$f.orig" ]; then
            cp -X "$WINE/$f.orig" "$WINE/$f" || fail "Could not restore $f in $APP."
            rm -f "$WINE/$f.orig"
            ok "restored ${f:t}"
            put_back=$((put_back+1))
        fi
    done

    # The resolver. ws2_32.so was not backed up because it did not need to be:
    # setup.sh changed one string inside one of its load commands, and the same
    # tool changes it back exactly. Removing a17hosts.dylib without doing this
    # first would leave ws2_32.so pointing at a library that is gone, and every
    # Windows program in the bottle would fail to start.
    if otool -L "$WINE/x86_64-unix/ws2_32.so" 2>/dev/null | grep -q '@rpath/a17hosts.dylib'; then
        install_name_tool -change @rpath/a17hosts.dylib /usr/lib/libSystem.B.dylib \
            "$WINE/x86_64-unix/ws2_32.so" 2>/dev/null \
            || fail "Could not put ws2_32.so back on the system resolver in
             $APP
         Nothing else has been removed. a17hosts.dylib is still in place,
         so the app still works; try again once it is not running."
        ok "put ws2_32.so back on the system resolver"
        put_back=$((put_back+1))
    fi
    if [ -f "$WINE/x86_64-unix/a17hosts.dylib" ]; then
        rm -f "$WINE/x86_64-unix/a17hosts.dylib"
        ok "removed a17hosts.dylib"
    fi

    if [ "$put_back" -gt 0 ]; then
        # This re-signs ad-hoc. It does NOT restore CodeWeavers' signature,
        # their Team ID, or the original hardened-runtime flags, because those
        # cannot be reconstructed from six replaced files. Say so rather than
        # printing "signed" and letting the user believe otherwise.
        signed=1
        for so in ntdll.so winecoreaudio.so crypt32.so ws2_32.so; do
            codesign --force --sign - "$WINE/x86_64-unix/$so" 2>/dev/null || signed=0
        done
        # Sign the app back with the entitlements it currently carries. Signing
        # without them would take away microphone, camera and Apple Events
        # access and leave no sign that it happened.
        ent="$(mktemp -t cxent).plist"
        if codesign -d --entitlements "$ent" --xml "$APP" 2>/dev/null && [ -s "$ent" ]; then
            codesign --force --sign - -o runtime --entitlements "$ent" "$APP" 2>/dev/null || signed=0
        else
            note "could not read this app's permissions; signing without them"
            codesign --force --sign - "$APP" 2>/dev/null || signed=0
        fi
        rm -f "$ent"
        if [ "$signed" = 1 ]; then
            ok "re-signed $APP ad-hoc"
        else
            note "could not re-sign $APP. It may not open."
            say "        Reinstall CrossOver to put it back properly."
        fi
        undone=$((undone+put_back))
        say ""
        note "everything we changed is back, but this app now carries our ad-hoc"
        say "        signature, not CodeWeavers'. To have CrossOver exactly as it"
        say "        shipped, reinstall it from CodeWeavers."
    else
        note "no backups found in $APP — nothing to put back"
    fi
else
    # ------------------------------------------------- the separate copy
    if [ -d "$TARGET" ]; then
        assert_safe_target "$TARGET"
        is_crossover_bundle "$TARGET" \
            || fail "$TARGET is not a CrossOver bundle. Refusing to remove it."
        if app_is_running "$TARGET"; then
            fail "$TARGET is running. Quit it first, then run this again."
        fi
        rm -rf "$TARGET"
        ok "deleted $TARGET"
        say "        (your own CrossOver was never changed, so there is nothing"
        say "         to put back)"
        undone=$((undone+1))
    elif [ "$TARGET_EXPLICIT" = 1 ]; then
        note "nothing at $TARGET — it may already be gone"
    else
        note "no CrossOver-FIFA at $TARGET"
    fi
fi

# ------------------------------------------------ the PowerShell stand-in
say ""
PSDIR="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
if [ -f "$PSDIR/powershell.exe.wine-stub-orig" ]; then
    mv -f "$PSDIR/powershell.exe.wine-stub-orig" "$PSDIR/powershell.exe"
    ok "put Wine's own powershell.exe back in the $BOTTLE bottle"
    undone=$((undone+1))
elif [ "$R_BOTTLE_PS" = "created" ] && [ -f "$PSDIR/powershell.exe" ]; then
    # setup.sh created this file where the bottle had none. Removing it is only
    # safe if it is still the file we put there.
    if cmp -s "$HERE/aurora17/powershell.exe" "$PSDIR/powershell.exe"; then
        rm -f "$PSDIR/powershell.exe"
        rmdir "$PSDIR" 2>/dev/null || true
        ok "removed the stand-in from the $BOTTLE bottle"
        undone=$((undone+1))
    else
        note "the powershell.exe in the $BOTTLE bottle is not the one we"
        say "        installed. Leaving it alone."
    fi
fi

# An explicit AURORA_DIR, or the folder recorded at install time, means that
# folder and no other. Only fall back to searching when we have neither.
if [ -n "${AURORA_DIR:-}" ]; then
    ps_dirs=( "${AURORA_DIR:A}" )
elif [ -n "$R_AURORA_DIR" ]; then
    ps_dirs=( "$R_AURORA_DIR" )
else
    ps_dirs=( "$HOME/Downloads/Aurora17" "$HOME/Aurora17" "$HOME/Desktop/Aurora17" )
fi
for d in $ps_dirs; do
    [ -n "$d" ] || continue
    [ -f "$d/powershell.exe" ] || continue
    # Only remove our own stand-in. Anything else in that name belongs to
    # somebody else and is not ours to delete.
    if ! cmp -s "$HERE/aurora17/powershell.exe" "$d/powershell.exe"; then
        note "the powershell.exe in $d is not the one we installed."
        say "        Leaving it alone."
        continue
    fi
    rm -f "$d/powershell.exe"
    ok "removed the stand-in from $d"
    undone=$((undone+1))
    if [ -f "$d/powershell.exe.aurora-orig" ]; then
        mv -f "$d/powershell.exe.aurora-orig" "$d/powershell.exe"
        ok "put back the powershell.exe that was there before"
    fi
done

# --------------------------------------------- the bottle's hosts file
# setup.sh writes the six EA mappings there so Aurora17's launcher never tries
# to elevate for them. The backup is only made the first time it writes, so it
# holds whatever the bottle had before we ever touched it.
#
# Aurora17's own receipt is deliberately left alone: if the launcher has run
# since, that receipt is its record, not ours, and Aurora17 is the thing that
# should undo it -- `Aurora17Connector.exe uninstall-hosts`.
say ""
BHOSTS="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/drivers/etc/hosts"
if [ -f "$BHOSTS.bak-aurora17" ]; then
    mv -f "$BHOSTS.bak-aurora17" "$BHOSTS"
    ok "put the $BOTTLE bottle's hosts file back as it was"
    undone=$((undone+1))
fi

# ------------------------------------------------------------- the receipt
if [ -f "$RECEIPT" ]; then
    rm -f "$RECEIPT"
    ok "removed the install record"
fi

say ""
if [ "$undone" -eq 0 ]; then
    say "Nothing to undo — no CrossOver-FIFA and no install record found."
else
    say "Done."
fi
say ""
say "Left in place, on purpose:"
say "  * the settings in your '$BOTTLE' bottle. They do nothing without the"
say "    fixes. To remove them, open that bottle's cxbottle.conf and delete"
say "    them from the [EnvironmentVariables] section."
say "  * Aurora17's own hosts receipt, if its launcher has run since. That is"
say "    Aurora17's record, not ours. To clear it, run in the Aurora17 folder:"
say "        .\\Aurora17Connector.exe uninstall-hosts"
say "  * the game, your bottles, and everything in them."
say ""
