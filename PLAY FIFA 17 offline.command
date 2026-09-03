#!/bin/zsh
# Double-click this to play FIFA 17 with no Aurora17 running. It starts the
# game's own loader inside the Aurora17 bottle, through the patched CrossOver
# copy. Single player only — nothing here talks to EA.
#
# Leave this window open while you play: it is what tells the background
# cleanup that the game is running on purpose. Closing it stops the game.

cd "${0:A:h}" || exit 1
chmod +x ./setup.sh 2>/dev/null || true

if [ -t 1 ]; then RED=$'\e[1;31m' GRN=$'\e[32m' OFF=$'\e[0m'; else RED='' GRN='' OFF=''; fi

clear
print -r -- ""
print -r -- "  FIFA 17 — offline"
print -r -- "  ================="
print -r -- ""
print -r -- "  Keep this window open while you play. Quitting FIFA ends it."
print -r -- ""

./setup.sh --play-offline
rc=$?

print -r -- ""
case $rc in
    0) print -r -- "  ${GRN}FIFA 17 closed.${OFF}" ;;
    5) print -r -- "  ${RED}Could not start it.${OFF} The reason is above."
       print -r -- "  If nothing is installed yet, double-click  START HERE offline.command" ;;
    *) print -r -- "  ${RED}Stopped.${OFF} The reason is printed above." ;;
esac
print -r -- ""
print -r -- "  Press return to close this window."
read -r _
exit $rc
