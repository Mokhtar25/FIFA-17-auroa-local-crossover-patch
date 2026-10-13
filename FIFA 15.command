#!/bin/zsh
# Double-click this. It sets FIFA 15 up on the same CrossOver-FIFA copy that
# "START HERE.command" makes -- and makes the copy first if it is not there.
# Everything it does can be undone with "Uninstall.command" beside it.

cd "${0:A:h}" || exit 1
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x ./setup.sh ./uninstall.sh ./fifa15/fifa15-offline.sh 2>/dev/null || true

# The whole run is also saved in ~/Library/Logs/FIFA-CrossOver, for
# "1 Collect diagnostics" to send (lib/runlog.zsh).
[ -f ./lib/runlog.zsh ] && source ./lib/runlog.zsh && runlog_start fifa15 "$PWD/${0:t}" "$@"

if [ -t 1 ] || [ "${CX_COLOR:-}" = 1 ]; then RED=$'\e[1;31m' GRN=$'\e[32m' OFF=$'\e[0m'; else RED='' GRN='' OFF=''; fi

clear
print -r -- ""
print -r -- "  FIFA 15 on a Mac — setup (experimental)"
print -r -- "  ======================================="
print -r -- ""
print -r -- "  This uses the CrossOver-FIFA copy (making it if it is not there,"
print -r -- "  about 1 GB), and puts FIFA 15's settings in Aurora's existing bottle."
print -r -- "  An installed old FIFA 15 connector keeps its Aurora15 bottle;"
print -r -- "  otherwise the common bottle is Aurora17."
print -r -- ""
print -r -- "  Your own CrossOver is not touched. Setup prints the bottle it uses."
print -r -- "  The game executable and Origin DLL are never modified by setup."
print -r -- "  CrossOver must be closed while this runs."
print -r -- ""

CX_DIALOGS=1 ./setup.sh --fifa15
rc=$?

print -r -- ""
case $rc in
    130)
        print -r -- "  Cancelled. No app or bottle was changed."
        rc=0
        ;;
    0)
        print -r -- "  ${GRN}Finished.${OFF} Open CrossOver-FIFA (not your normal CrossOver),"
        print -r -- "  use the bottle named above, and play FIFA 15 from its Aurora launcher."
        print -r -- "  For direct offline play, follow the steps in SETUP.md."
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
