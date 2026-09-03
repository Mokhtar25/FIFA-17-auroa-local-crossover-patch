#!/bin/zsh
# Double-click this to install FIFA 17 with no Aurora17 at all: the CrossOver
# copy, the fixes and the bottle settings, and nothing that talks to EA.
# Single player only. "START HERE.command" beside it is the full install, and
# running it later adds Aurora17 to the same copy. Undo with "Uninstall.command".

cd "${0:A:h}" || exit 1

# A folder that came out of a downloaded zip is quarantined by macOS. Clearing it
# here means the files we are about to install are not, which avoids a confusing
# "cannot be opened" later on.
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x ./setup.sh ./uninstall.sh 2>/dev/null || true

if [ -t 1 ]; then RED=$'\e[1;31m' GRN=$'\e[32m' OFF=$'\e[0m'; else RED='' GRN='' OFF=''; fi

clear
print -r -- ""
print -r -- "  FIFA 17 on a Mac — offline installer"
print -r -- "  ===================================="
print -r -- ""
print -r -- "  This makes a separate copy of CrossOver called CrossOver-FIFA and"
print -r -- "  puts the fixes in it. No Aurora17, no PowerShell stand-in, no EA"
print -r -- "  name redirects — nothing here talks to EA at all."
print -r -- ""
print -r -- "  ${GRN}You get:${OFF}     kick-off, career, tournaments, skill games — all of"
print -r -- "               single player, with a controller."
print -r -- "  ${RED}You do not:${OFF}  online, FUT, or anything needing an EA account."
print -r -- ""
print -r -- "  Your own CrossOver is not touched, and neither is any other bottle"
print -r -- "  you run in it. The copy needs about 1 GB of disk."
print -r -- "  The game is never modified. Nothing is downloaded."
print -r -- ""
print -r -- "  You still need FIFA 17 itself, and a bottle called Aurora17 for it"
print -r -- "  to live in (SETUP.md shows how to make one)."
print -r -- ""

./setup.sh --offline
rc=$?

print -r -- ""
case $rc in
    0)
        print -r -- "  ${GRN}Finished.${OFF} To play, double-click  PLAY FIFA 17 offline.command"
        print -r -- ""
        print -r -- "  Want online and FUT later? Install Aurora17, then double-click"
        print -r -- "  START HERE.command. It adds the rest to the same copy."
        ;;
    3)
        print -r -- "  ${RED}Stopped: macOS would not allow a change.${OFF}"
        print -r -- "  Follow the steps above, then run this again."
        ;;
    4)
        print -r -- "  ${RED}Stopped: something did not match what it expected.${OFF}"
        print -r -- "  The reason is above. If it mentions checksums, download and"
        print -r -- "  extract this package again — do not install what is here now."
        ;;
    5)
        print -r -- "  ${RED}Not finished: CrossOver is patched, but the game will not start yet.${OFF}"
        print -r -- "  The missing piece is listed above. Fix it and run this again."
        print -r -- "  To check at any time, run:  ./setup.sh --verify"
        ;;
    *)
        print -r -- "  ${RED}Stopped early.${OFF} The reason is printed above."
        print -r -- "  SETUP.md explains every step and what to do about each failure."
        ;;
esac
print -r -- ""
print -r -- "  Press return to close this window."
read -r _
exit $rc
