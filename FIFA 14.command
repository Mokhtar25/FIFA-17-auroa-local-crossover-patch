#!/bin/zsh
# Double-click this. It sets FIFA 14 up on the CrossOver-FIFA copy that
# "START HERE.command" makes (making or refreshing the copy first), gives
# fifa14.exe its one setting in the bottle (DrTrap=3), and starts the game.
# Offline only; experimental. There is no ./setup.sh --fifa14 yet.
#
# Environment: FIFA14_BOTTLE (default Aurora17), FIFA14_DIR (the folder with
# fifa14.exe in it; asked for when it cannot be found), FIFA14_SKIP_SETUP=1
# (do not run setup.sh, only the setting and the start).

cd "${0:A:h}" || exit 1
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x ./setup.sh ./uninstall.sh 2>/dev/null || true

[ -f ./lib/runlog.zsh ] && source ./lib/runlog.zsh && runlog_start fifa14 "$PWD/${0:t}" "$@"

if [ -t 1 ] || [ "${CX_COLOR:-}" = 1 ]; then RED=$'\e[1;31m' GRN=$'\e[32m' OFF=$'\e[0m'; else RED='' GRN='' OFF=''; fi
say()  { print -r -- "  $*"; }
fail() { print -r -- ""; print -r -- "  ${RED}Stopped.${OFF} $*"; print -r -- ""; print -r -- "  Press return to close this window."; read -r _; exit 2; }

clear
say ""
say "FIFA 14 on a Mac — offline (experimental)"
say "========================================="
say ""
say "This uses the CrossOver-FIFA copy (making it if it is not there, about"
say "1 GB, or bringing its fix files up to date), sets FIFA 14's one setting"
say "in the bottle, and starts the game. Your own CrossOver is not touched."
say "CrossOver must be closed while the setup part runs."
say ""

BOTTLE="${FIFA14_BOTTLE:-Aurora17}"
BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
APP=/Applications/CrossOver-FIFA.app
[ -d "$APP" ] || { [ -d "$HOME/Applications/CrossOver-FIFA.app" ] && APP="$HOME/Applications/CrossOver-FIFA.app"; }

# 1. The copy and its fix files (the new 32-bit kernelbase.dll among them).
if [ "${FIFA14_SKIP_SETUP:-0}" != 1 ]; then
    if [ -d "$APP" ]; then
        say "1. Bringing the fix files in ${APP:t} up to date (./setup.sh --repair)"
        CX_DIALOGS=1 AURORA_BOTTLE="$BOTTLE" ./setup.sh --repair
    else
        say "1. Making the CrossOver-FIFA copy (./setup.sh)"
        CX_DIALOGS=1 AURORA_BOTTLE="$BOTTLE" ./setup.sh
    fi
    rc=$?
    [ $rc = 130 ] && { say "Cancelled."; exit 0; }
    [ $rc = 0 ] || say "(setup ended with code $rc; FIFA 14 only needs the copy and its files, checking those)"
    [ -d "$APP" ] || APP="$HOME/Applications/CrossOver-FIFA.app"
fi
[ -d "$APP" ] || fail "No CrossOver-FIFA copy was found. Run \"START HERE.command\" first."

KB="$APP/Contents/SharedSupport/CrossOver/lib/wine/i386-windows/kernelbase.dll"
want="$(awk '$2=="i386-windows/kernelbase.dll"{print $1}' fixes/SHA256SUMS)"
have="$(shasum -a 256 "$KB" 2>/dev/null | awk '{print $1}')"
[ -n "$want" ] && [ "$have" = "$want" ] \
    || fail "${APP:t} does not have FIFA 14's kernelbase.dll. Run this again; if it repeats, send the window's text."
say "${GRN}ok${OFF}    ${APP:t} has FIFA 14's kernelbase.dll"

# 2. The bottle and the setting.
[ -d "$BOTTLES/$BOTTLE" ] || fail "There is no bottle named $BOTTLE. Bottles here: $(ls "$BOTTLES" 2>/dev/null | tr '\n' ' ')
         Run it again with:  FIFA14_BOTTLE=<name> ./'FIFA 14.command'"
W="$APP/Contents/SharedSupport/CrossOver/bin/wine"
"$W" --bottle "$BOTTLE" reg add 'HKCU\Software\Wine\AppDefaults\fifa14.exe\CrossOver-FIFA' \
    /v DrTrap /t REG_SZ /d 3 /f >/dev/null 2>&1 \
    || fail "Could not write the FIFA 14 setting into the $BOTTLE bottle."
say "${GRN}ok${OFF}    $BOTTLE: DrTrap=3 for fifa14.exe"

# 3. The game folder.
DIR="${FIFA14_DIR:-}"
if [ -z "$DIR" ]; then
    for root in "$HOME/Downloads" "$HOME/Games" "$HOME/Desktop" "$HOME/Documents" "$BOTTLES/$BOTTLE/drive_c"; do
        f="$(find "$root" -maxdepth 5 -iname fifa14.exe -type f 2>/dev/null | head -1)"
        [ -n "$f" ] && { DIR="${f:h}"; break; }
    done
fi
if [ -z "$DIR" ]; then
    DIR="$(osascript -e 'POSIX path of (choose folder with prompt "Choose the FIFA 14 folder (the one with fifa14.exe in it)")' 2>/dev/null)"
    DIR="${DIR%/}"
fi
[ -n "$DIR" ] && [ -n "$(ls "$DIR" 2>/dev/null | grep -i '^fifa14\.exe$')" ] \
    || fail "No fifa14.exe in '${DIR:-nothing chosen}'. Run it again with:  FIFA14_DIR='/path/to/Game' ./'FIFA 14.command'"
say "${GRN}ok${OFF}    game folder: $DIR"

# The 3DM launcher when there is one, else the game itself.
EXE="$(ls "$DIR" | grep -i '^fifa14-3dm\.exe$' | head -1)"
[ -n "$EXE" ] || EXE="$(ls "$DIR" | grep -i '^fifa14\.exe$' | head -1)"
WDIR="Z:${DIR//\//\\}"

say ""
say "Starting $EXE in the $BOTTLE bottle."
[[ "$EXE" == *3dm* ]] && say "When its window shows, click \"Launch Game\"."
say "The first start can sit on a small splash for up to a minute."
"$W" --bottle "$BOTTLE" --workdir "$WDIR" --cx-app "$WDIR\\$EXE" >/dev/null 2>&1 &!

say ""
say "${GRN}Done.${OFF} Next time you can start it the same way (this file), or with"
say "FIFA14_SKIP_SETUP=1 to skip the setup part. TESTER-NOTES.txt says what to report."
say ""
say "Press return to close this window."
read -r _
exit 0
