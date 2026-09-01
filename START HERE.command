#!/bin/zsh
# Double-click this. It installs the FIFA 17 fixes into your copy of CrossOver.
# Everything it does can be undone with "Uninstall.command" beside it.

cd "${0:A:h}" || exit 1

# A folder that came out of a downloaded zip is quarantined by macOS. Clearing it
# here means the files we are about to install are not, which avoids a confusing
# "cannot be opened" later on.
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x ./setup.sh ./uninstall.sh 2>/dev/null || true

clear
print -r -- ""
print -r -- "  FIFA 17 on a Mac — installer"
print -r -- "  ============================"
print -r -- ""
print -r -- "  This makes a separate copy of CrossOver called CrossOver-FIFA and"
print -r -- "  puts six small fixes in that, plus one file in your Aurora17 folder."
print -r -- ""
print -r -- "  Your own CrossOver is not touched, and neither is any other bottle"
print -r -- "  you run in it. The copy needs about 1 GB of disk."
print -r -- "  The game is never modified. Nothing is downloaded."
print -r -- ""

./setup.sh
rc=$?

if [ $rc -eq 3 ]; then
    # The reason and the real fix are printed by setup.sh above. Trying once as
    # root is still worth it: on some systems it gets through, and it costs one
    # password prompt. If it does not, the App Management instructions stand.
    print -r -- ""
    print -r -- "  Trying once more as an administrator, in case that is enough."
    print -r -- "  (Nothing leaves this Mac. You can read setup.sh first if you like.)"
    print -r -- "  Press control-C to skip this and follow the instructions above."
    print -r -- ""
    sudo ./setup.sh
    rc=$?
    if [ $rc -ne 0 ]; then
        print -r -- ""
        print -r -- "  That did not get through either. Grant App Management as described"
        print -r -- "  above, quit your Terminal completely, and run this again."
    fi
fi

print -r -- ""
if [ $rc -eq 0 ]; then
    print -r -- "  Finished. Open CrossOver-FIFA (not your normal CrossOver),"
    print -r -- "  open the Aurora17 bottle, and press PLAY FIFA 17."
else
    print -r -- "  It stopped early — the reason is printed above."
    print -r -- "  SETUP.md explains every step, and what to do about it."
fi
print -r -- ""
print -r -- "  Press return to close this window."
read -r _
