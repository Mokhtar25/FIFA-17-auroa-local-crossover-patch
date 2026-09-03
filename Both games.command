#!/bin/zsh
# Double-click this. It installs the FIFA 17 fixes into a copy of your CrossOver
# and then sets FIFA 15 up in the same copy. "Uninstall.command" undoes it.

cd "${0:A:h}" || exit 1
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x ./setup.sh ./setup-both.sh ./uninstall.sh ./fifa15/fifa15-offline.sh 2>/dev/null || true

if [ -t 1 ]; then RED=$'\e[1;31m' GRN=$'\e[32m' OFF=$'\e[0m'; else RED='' GRN='' OFF=''; fi

clear
print -r -- ""
print -r -- "  FIFA 17 + FIFA 15 on a Mac — installer"
print -r -- "  ======================================"
print -r -- ""
print -r -- "  This makes a separate copy of CrossOver called CrossOver-FIFA, puts"
print -r -- "  the FIFA 17 fixes in it, then makes an Aurora15 bottle for FIFA 15."
print -r -- "  Your own CrossOver is not touched. The copy needs about 1 GB."
print -r -- "  Neither game is modified. Nothing is downloaded."
print -r -- "  CrossOver must be closed while this runs."
print -r -- ""

./setup-both.sh
rc=$?

print -r -- ""
case $rc in
    0) print -r -- "  ${GRN}Finished.${OFF} Open CrossOver-FIFA: Aurora17 bottle for FIFA 17,"
       print -r -- "  Aurora15 bottle for FIFA 15 (SETUP.md, \"FIFA 15\", says how to play it)." ;;
    3) print -r -- "  ${RED}Stopped: macOS would not allow a change, or CrossOver is open.${OFF}"
       print -r -- "  Follow the steps above, then run this again." ;;
    4) print -r -- "  ${RED}Stopped: something did not match what it expected.${OFF} The reason is above." ;;
    5) print -r -- "  ${RED}Not finished.${OFF} The missing piece is listed above. Fix it and run this again."
       print -r -- "  To check at any time:  ./setup-both.sh --verify" ;;
    *) print -r -- "  ${RED}Stopped early.${OFF} The reason is printed above." ;;
esac
print -r -- ""
print -r -- "  Press return to close this window."
read -r _
exit $rc
