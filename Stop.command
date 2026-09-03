#!/bin/zsh
# Double-click this instead of closing CrossOver's window. It stops the games
# and Aurora first, shuts every bottle's wineserver down (flushing the
# registry), quits CrossOver, then frees any held ports -- so no stray
# winewrapper/Aurora processes and no "port in use" next time.

cd "${0:A:h}" || exit 1
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x ./setup.sh ./uninstall.sh 2>/dev/null || true

if [ -t 1 ]; then RED=$'\e[1;31m' GRN=$'\e[32m' OFF=$'\e[0m'; else RED='' GRN='' OFF=''; fi

clear
print -r -- ""
print -r -- "  FIFA on a Mac — clean quit"
print -r -- "  =========================="
print -r -- ""
print -r -- "  This quits CrossOver properly: games and Aurora first, then the"
print -r -- "  wineservers, then CrossOver itself. Closing the window (red dot)"
print -r -- "  leaves strays behind holding ports 47170-47173 and 3216."
print -r -- ""

./setup.sh --shutdown
rc=$?

print -r -- ""
case $rc in
    0) print -r -- "  ${GRN}Finished.${OFF} CrossOver has quit and the ports are free."
       print -r -- "  Next PLAY will not say 'already listening' / 'port in use'." ;;
    3) print -r -- "  ${RED}Stopped: CrossOver would not quit.${OFF}"
       print -r -- "  Force Quit it (Apple menu > Force Quit), then run:"
       print -r -- "    ./setup.sh --unstick" ;;
    *) print -r -- "  ${RED}Stopped early.${OFF} The reason is printed above."
       print -r -- "  Try:  ./setup.sh --unstick" ;;
esac
print -r -- ""
print -r -- "  Press return to close this window."
read -r _
exit $rc
