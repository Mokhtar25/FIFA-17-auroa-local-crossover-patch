#!/bin/zsh
# Starts Aurora17's launcher with CrossOver's own log turned on, and says
# which module the game died in once it has gone. For a crash that comes back
# on every PLAY (exit code 0xC0000005).
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --play-log
