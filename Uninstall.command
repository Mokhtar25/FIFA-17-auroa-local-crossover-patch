#!/bin/zsh
# Double-click this to put CrossOver back exactly as it was.
cd "${0:A:h}" || exit 1
chmod +x ./uninstall.sh 2>/dev/null || true
clear
./uninstall.sh
print -r -- ""
print -r -- "  Press return to close this window."
read -r _
