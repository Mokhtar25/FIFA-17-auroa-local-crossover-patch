#!/bin/zsh
# Installs the FIFA 17 fixes.
#
# By default it does NOT touch your CrossOver. It makes a separate copy called
# CrossOver-FIFA and puts the fixes in that, so your normal CrossOver and every
# other bottle you run in it are left exactly as they are.
#
# Everything it does can be undone by running ./uninstall.sh.
# It never touches the game, and it never downloads anything.

set -eu
HERE="${0:A:h}"

# --resign repairs the signature on an existing CrossOver-FIFA without copying
# the whole app again. Use it after changing anything inside the copy by hand.
RESIGN=0
if [ "${1:-}" = "--resign" ]; then RESIGN=1; shift; fi

# Find CrossOver. An explicit path always wins; otherwise look in the usual
# places, then ask Spotlight. This is the only thing a person normally has to
# tell us, so it is worth not asking.
find_crossover() {
    [ -n "${1:-}" ] && { print -r -- "$1"; return; }
    local d
    for d in /Applications/CrossOver.app "$HOME/Applications/CrossOver.app" \
             "${CROSSOVER_APP:-}"; do
        [ -n "$d" ] && [ -d "$d" ] && { print -r -- "$d"; return; }
    done
    d=$(mdfind "kMDItemCFBundleIdentifier == 'com.codeweavers.CrossOver'" 2>/dev/null | head -1)
    [ -n "$d" ] && [ -d "$d" ] && { print -r -- "$d"; return; }
    print -r -- "/Applications/CrossOver.app"
}
SRC="$(find_crossover "${1:-}")"

# Copy by default. AURORA_IN_PLACE=1 patches your real CrossOver instead, which
# needs macOS's App Management permission and affects every bottle you have.
IN_PLACE="${AURORA_IN_PLACE:-0}"
TARGET="${AURORA_TARGET:-/Applications/CrossOver-FIFA.app}"
[ "$IN_PLACE" = "1" ] && TARGET="$SRC"

BOTTLE_DIR="${CX_BOTTLE_PATH:-$HOME/Library/Application Support/CrossOver/Bottles}"
BOTTLE="${AURORA_BOTTLE:-Aurora17}"

say()  { print -r -- "$@"; }
ok()   { print -r -- "  ok    $@"; }
fail() { print -r -- ""; print -r -- "STOPPED: $@"; exit 1; }

# Re-signs the app after we have changed files inside it.
#
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
resign_app() {
    local app="$1"
    local ent
    ent="$(mktemp -t cxent).plist"
    if codesign -d --entitlements "$ent" --xml "$app" 2>/dev/null && [ -s "$ent" ]; then
        local n
        n=$(/usr/libexec/PlistBuddy -c 'Print' "$ent" 2>/dev/null | grep -c ' = ' || true)
        ok "kept CrossOver's $n permissions"
    else
        # No entitlements to preserve; start from an empty dictionary so the one
        # key we must add below still has somewhere to go.
        /usr/libexec/PlistBuddy -c 'Save' "$ent" >/dev/null 2>&1 || :
        ok "this copy had no permissions to keep"
    fi

    local KEY=":com.apple.security.cs.disable-library-validation"
    /usr/libexec/PlistBuddy -c "Add $KEY bool true" "$ent" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Set $KEY true" "$ent" >/dev/null 2>&1 || :
    ok "allowed it to load its own frameworks"

    codesign --force --sign - -o runtime --entitlements "$ent" "$app" 2>/dev/null \
      && ok "signed $app" \
      || { rm -f "$ent"; fail "Could not sign $app.
         Nothing is broken, but it will not launch until it is signed.
         Try again, or run:  ./setup.sh --resign"; }
    rm -f "$ent"

    # If this is wrong the app dies at launch with a dyld error and no window,
    # which is a miserable thing to debug. Catch it here instead.
    if ! codesign --verify --deep --strict "$app" 2>/dev/null; then
        say "  note  the signature verifies loosely but not strictly."
        say "        That is usually fine; if the app will not open, tell us."
    fi
}

say ""
say "FIFA 17 fixes — setup"
say "====================="
say ""

# ------------------------------------------------------- --resign, and stop
# Repairs the signature on a CrossOver-FIFA that already exists. Signing is the
# one step that can leave the app unable to open at all, and re-copying a
# gigabyte to redo it would be absurd.
if [ "$RESIGN" = "1" ]; then
    [ -d "$TARGET" ] || TARGET="$HOME/Applications/${TARGET:t}"
    [ -d "$TARGET" ] || fail "No CrossOver-FIFA to re-sign. Looked in
         /Applications and ~/Applications. If yours is somewhere else:
             AURORA_TARGET=/path/to/CrossOver-FIFA.app ./setup.sh --resign"
    say "Re-signing $TARGET"
    say ""
    W="$TARGET/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix"
    if [ -d "$W" ]; then
        codesign --force --sign - "$W/ntdll.so" "$W/winecoreaudio.so" \
                                  "$W/crypt32.so" 2>/dev/null || :
        ok "the three Mac files"
    fi
    resign_app "$TARGET"
    say ""
    say "Done. Open ${TARGET:t:r} again."
    say ""
    exit 0
fi

# ---------------------------------------------------------------- 1. checks
say "1. Checking CrossOver"
[ -d "$SRC" ] || fail "No CrossOver at $SRC.
         If yours is somewhere else, run:  ./setup.sh /path/to/CrossOver.app"

VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Contents/Info.plist" 2>/dev/null || echo "unknown")
case "$VER" in
  26.3*) ok "CrossOver $VER at $SRC" ;;
  *) fail "These fixes are built for CrossOver 26.3. You have $VER.
         Installing them into a different version will not work.
         Rebuild from patches/ against your version, or install CrossOver 26.3." ;;
esac

# ------------------------------------------------------ 2. the working copy
say ""
if [ "$IN_PLACE" = "1" ]; then
    say "2. Using your real CrossOver (AURORA_IN_PLACE=1)"
    say "        This changes every bottle you run in CrossOver, not just FIFA."
else
    say "2. Making a separate CrossOver for FIFA"

    APPSIZE_K=$(du -sk "$SRC" | awk '{print $1}')
    # Pick somewhere we can actually create it. /Applications is normal, but it
    # is not writable on every Mac, and ~/Applications always is.
    if [ ! -d "${TARGET:h}" ] || ! ( mkdir -p "${TARGET:h}/.aurora17-probe" ) 2>/dev/null; then
        say "  note  cannot create anything in ${TARGET:h}"
        TARGET="$HOME/Applications/${TARGET:t}"
        mkdir -p "$HOME/Applications"
        say "        using $TARGET instead"
    else
        rmdir "${TARGET:h}/.aurora17-probe" 2>/dev/null || true
    fi

    FREE_K=$(df -k "${TARGET:h}" | tail -1 | awk '{print $4}')
    if [ "$FREE_K" -lt $((APPSIZE_K + 500000)) ]; then
        fail "Not enough disk space. The copy needs about $((APPSIZE_K / 1024)) MB
         and there is $((FREE_K / 1024)) MB free."
    fi

    if [ -e "$TARGET" ]; then
        if pgrep -f "$TARGET/Contents/MacOS" >/dev/null 2>&1; then
            fail "$TARGET is running. Quit it first, then run this again."
        fi
        rm -rf "$TARGET"
        ok "removed the previous copy"
    fi
    ok "copying $((APPSIZE_K / 1024)) MB — this takes a moment"
    ditto "$SRC" "$TARGET"
    ok "made $TARGET"
    say "        your own CrossOver at $SRC is untouched"
fi

APP="$TARGET"
CX="$APP/Contents/SharedSupport/CrossOver"
WINE="$CX/lib/wine"
[ -d "$WINE/x86_64-unix" ] || fail "$APP does not look like CrossOver 26.3 inside."

# Since macOS 14, a signed app bundle is protected by a permission called "App
# Management" that belongs to the program running this script, not to you. The
# folder can be owned by you, with write permission, and still refuse writes --
# so [ -w ] says yes and the first cp then fails with "Operation not permitted".
# Probe with a real write, up front, so macOS asks now rather than half way in.
PROBE="$WINE/x86_64-unix/.aurora17-write-probe"
if ! ( : > "$PROBE" ) 2>/dev/null; then
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
    exit 3
fi
rm -f "$PROBE"

# ------------------------------------------------------------- 4. backup
say ""
say "3. Backing up the files we replace"
FILES=(
  x86_64-unix/ntdll.so
  x86_64-unix/winecoreaudio.so
  x86_64-unix/crypt32.so
  x86_64-windows/version.dll
  x86_64-windows/crypt32.dll
  x86_64-windows/secur32.dll
)
for f in $FILES; do
    [ -f "$WINE/$f" ] || fail "$f is missing from CrossOver. Is this really 26.3?"
    if [ -f "$WINE/$f.orig" ]; then
        ok "$(basename $f) — backup already exists, keeping it"
    else
        cp "$WINE/$f" "$WINE/$f.orig"
        ok "$(basename $f) → $(basename $f).orig"
    fi
done

# ------------------------------------------------------------- 5. install
say ""
say "4. Installing the fixes"
if ! ( cd "$HERE/fixes" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1; then
    fail "The files in fixes/ do not match their checksums. Do not install these."
fi
ok "checksums match"
for f in $FILES; do
    cp "$HERE/fixes/$f" "$WINE/$f"
    # A file that arrived inside a downloaded zip carries com.apple.quarantine.
    # Left on, Gatekeeper can refuse to load it and the failure is obscure.
    xattr -d com.apple.quarantine "$WINE/$f" 2>/dev/null || true
    ok "$(basename $f)"
done

# ------------------------------------------------- 6. the search path fix
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
        install_name_tool -add_rpath '@loader_path/../../../lib64' "$WINE/x86_64-unix/$so"
        ok "$so — added"
    fi
done

# ------------------------------------------------------------- 7. re-sign
say ""
say "6. Signing"
codesign --force --sign - "$WINE/x86_64-unix/ntdll.so" "$WINE/x86_64-unix/winecoreaudio.so" \
                          "$WINE/x86_64-unix/crypt32.so" 2>/dev/null
ok "the three Mac files"
resign_app "$APP"

# --------------------------------------------------- 8. the bottle settings
# These four settings are what the game needs. Putting them in the bottle means
# you can launch normally from CrossOver instead of needing a Terminal script.
# Bottles are shared between CrossOver and the copy, so this is set once.
say ""
say "7. Adding the settings to your bottle"
CONF="$BOTTLE_DIR/$BOTTLE/cxbottle.conf"
if [ ! -f "$CONF" ]; then
    say "  note  no bottle called '$BOTTLE' found at"
    say "        $BOTTLE_DIR"
    say "        Skipping. Set it up later with:  AURORA_BOTTLE=name ./setup.sh"
else
    add_setting() {
        grep -q "\"$1\"" "$CONF" && { ok "$1 — already set"; return; }
        printf '"%s" = "%s"\n' "$1" "$2" >> "$CONF"
        ok "$1 = $2"
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
fi

# ------------------------------------------------ 9. the PowerShell stand-in
# Aurora17's PLAY button does its real work by running scripts/Play.ps1 through
# powershell.exe. Wine ships a powershell.exe that is a stub: it prints a FIXME
# and returns 0 without executing anything. Aurora only checks the exit code, so
# the stub's silent success made PLAY do nothing at all, with no error. This
# installs a small native stand-in that performs the same work.
say ""
say "8. Installing the PowerShell stand-in Aurora17 needs"
if ! ( cd "$HERE/aurora17" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1; then
    fail "The files in aurora17/ do not match their checksums. Do not install these."
fi
ok "checksums match"

# Where is the extracted Aurora17 folder? CreateProcess looks in the calling
# program's own directory first, so a copy there always wins.
# An explicit AURORA_DIR means that folder and no other.
if [ -n "${AURORA_DIR:-}" ]; then
    AURORA_CANDIDATES=( "$AURORA_DIR" )
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
    cp "$HERE/aurora17/powershell.exe" "$AURORA_FOUND/powershell.exe"
    xattr -d com.apple.quarantine "$AURORA_FOUND/powershell.exe" 2>/dev/null || true
    ok "into $AURORA_FOUND"
else
    say "  note  no Aurora17 folder found. If yours is elsewhere, run:"
    say "        AURORA_DIR=/path/to/Aurora17 ./setup.sh"
fi

# Also install it inside the bottle, so it is found no matter where Aurora17
# lives. The file being replaced is Wine's stub; we keep a copy of it.
PSDIR="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
if [ -d "$PSDIR" ]; then
    [ -f "$PSDIR/powershell.exe" ] && [ ! -f "$PSDIR/powershell.exe.wine-stub-orig" ] \
        && cp "$PSDIR/powershell.exe" "$PSDIR/powershell.exe.wine-stub-orig"
    cp "$HERE/aurora17/powershell.exe" "$PSDIR/powershell.exe"
    ok "into the $BOTTLE bottle"
elif [ -d "$BOTTLE_DIR/$BOTTLE" ]; then
    mkdir -p "$PSDIR"
    cp "$HERE/aurora17/powershell.exe" "$PSDIR/powershell.exe"
    ok "into the $BOTTLE bottle"
fi

say ""
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
say "Read SETUP.md if that does not work. To undo everything: ./uninstall.sh"
say ""
