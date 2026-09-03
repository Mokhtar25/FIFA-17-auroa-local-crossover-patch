#!/bin/zsh
# Double-click this. It sets FIFA 15 up on the same CrossOver-FIFA copy that
# "START HERE.command" makes -- and makes the copy first if it is not there.
# Everything it does can be undone with "Uninstall.command" beside it.

cd "${0:A:h}" || exit 1
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x ./setup.sh ./uninstall.sh ./fifa15/fifa15-offline.sh 2>/dev/null || true

if [ -t 1 ]; then RED=$'\e[1;31m' GRN=$'\e[32m' OFF=$'\e[0m'; else RED='' GRN='' OFF=''; fi

clear
print -r -- ""
print -r -- "  FIFA 15 on a Mac — setup (experimental)"
print -r -- "  ======================================="
print -r -- ""
print -r -- "  This uses the CrossOver-FIFA copy (making it if it is not there,"
print -r -- "  about 1 GB), makes an Aurora15 bottle in it, and puts the settings"
print -r -- "  FIFA 15 needs in that bottle."
print -r -- ""
print -r -- "  Your own CrossOver is not touched, and neither is the Aurora17"
print -r -- "  bottle. The game is never modified. Nothing is downloaded."
print -r -- "  CrossOver must be closed while this runs."
print -r -- ""

./setup.sh --fifa15
rc=$?

print -r -- ""
case $rc in
    0)
        print -r -- "  ${GRN}Finished.${OFF} Open CrossOver-FIFA (not your normal CrossOver),"
        print -r -- "  open the Aurora15 bottle, and run Aurora15Connector -- or, without it,"
        print -r -- "  patch the game with  ./fifa15/fifa15-offline.sh apply  and run fifa15.exe."
        print -r -- "  SETUP.md, \"FIFA 15\", explains both."
        ;;
    3)
        print -r -- "  ${RED}Stopped: macOS would not allow a change, or CrossOver is open.${OFF}"
        print -r -- "  Follow the steps above, then run this again."
        ;;
    4)
        print -r -- "  ${RED}Stopped: something did not match what it expected.${OFF}"
        print -r -- "  The reason is above."
        ;;
    5)
        print -r -- "  ${RED}Not finished.${OFF} The missing piece is listed above. Fix it and run this again."
        print -r -- "  To check at any time, run:  ./setup.sh --fifa15 --verify"
        ;;
    *)
        print -r -- "  ${RED}Stopped early.${OFF} The reason is printed above."
        ;;
esac
print -r -- ""
print -r -- "  Press return to close this window."
read -r _
exit $rc
