#!/bin/zsh
# Double-click this to remove the FIFA 17 fixes.
# It deletes the CrossOver-FIFA copy; your own CrossOver was never changed.
cd "${0:A:h}" || exit 1
chmod +x ./uninstall.sh 2>/dev/null || true
clear
./uninstall.sh
rc=$?
print -r -- ""
print -r -- "  Press return to close this window."
read -r _
exit $rc
