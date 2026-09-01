#!/bin/zsh
# Undoes everything setup.sh did.
#
# If it made a separate CrossOver-FIFA, undoing is just deleting that. If it was
# run with AURORA_IN_PLACE=1, the .orig backups are put back instead.
#
# Bottle settings are left alone -- they are harmless, and removing them by
# script risks damaging the file.
set -eu

TARGET="${AURORA_TARGET:-/Applications/CrossOver-FIFA.app}"
[ -d "$TARGET" ] || [ ! -d "$HOME/Applications/${TARGET:t}" ] || TARGET="$HOME/Applications/${TARGET:t}"
BOTTLE_DIR="${CX_BOTTLE_PATH:-$HOME/Library/Application Support/CrossOver/Bottles}"
BOTTLE="${AURORA_BOTTLE:-Aurora17}"

print -r -- ""
print -r -- "Removing the FIFA 17 fixes"
print -r -- ""

restored=0

# ------------------------------------------------ the separate CrossOver-FIFA
if [ -d "$TARGET" ] && [ "${AURORA_IN_PLACE:-0}" != "1" ]; then
    if pgrep -f "$TARGET/Contents/MacOS" >/dev/null 2>&1; then
        print -r -- "  $TARGET is running. Quit it first, then run this again."
        exit 1
    fi
    rm -rf "$TARGET"
    print -r -- "  deleted $TARGET"
    print -r -- "  (your own CrossOver was never changed, so there is nothing to put back)"
    restored=1
fi

# ------------------------------------------------------- an in-place install
APP="${1:-}"
if [ -z "$APP" ]; then
    for d in /Applications/CrossOver.app "$HOME/Applications/CrossOver.app"; do
        [ -d "$d" ] && { APP="$d"; break; }
    done
fi
WINE="$APP/Contents/SharedSupport/CrossOver/lib/wine"

FILES=(
  x86_64-unix/ntdll.so
  x86_64-unix/winecoreaudio.so
  x86_64-unix/crypt32.so
  x86_64-windows/version.dll
  x86_64-windows/crypt32.dll
  x86_64-windows/secur32.dll
)

if [ -n "$APP" ] && [ -d "$WINE" ]; then
    put_back=0
    for f in $FILES; do
        if [ -f "$WINE/$f.orig" ]; then
            cp "$WINE/$f.orig" "$WINE/$f"
            print -r -- "  restored $(basename $f) in $APP"
            put_back=$((put_back+1))
        fi
    done
    if [ $put_back -gt 0 ]; then
        codesign --force --sign - "$WINE/x86_64-unix/ntdll.so" "$WINE/x86_64-unix/winecoreaudio.so" \
                                  "$WINE/x86_64-unix/crypt32.so" 2>/dev/null || true
        codesign --force --sign - "$APP" 2>/dev/null || true
        print -r -- "  signed"
        restored=$((restored+put_back))
    fi
fi

# ------------------------------------------------------ the PowerShell stand-in
PSDIR="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
if [ -f "$PSDIR/powershell.exe.wine-stub-orig" ]; then
    mv -f "$PSDIR/powershell.exe.wine-stub-orig" "$PSDIR/powershell.exe"
    print -r -- "  restored Wine's own powershell.exe in the bottle"
fi

# An explicit AURORA_DIR means that folder and no other. Without one, look in the
# usual places. Getting this wrong deletes a working file out of a folder the
# caller never named, so the two cases stay separate.
if [ -n "${AURORA_DIR:-}" ]; then
    ps_dirs=( "$AURORA_DIR" )
else
    ps_dirs=( "$HOME/Downloads/Aurora17" "$HOME/Aurora17" "$HOME/Desktop/Aurora17" )
fi
for d in $ps_dirs; do
    if [ -f "$d/powershell.exe" ] && [ -f "$d/Aurora17Connector.exe" ]; then
        rm -f "$d/powershell.exe"
        print -r -- "  removed the stand-in from $d"
    fi
done

print -r -- ""
if [ $restored -eq 0 ]; then
    print -r -- "Nothing to undo — no CrossOver-FIFA and no backups found."
else
    print -r -- "Done."
fi
print -r -- ""
print -r -- "The settings in your bottle were left in place. They do nothing harmful"
print -r -- "without the fixes. To remove them, open the bottle's cxbottle.conf and"
print -r -- "delete them from the [EnvironmentVariables] section."
print -r -- ""
