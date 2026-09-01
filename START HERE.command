#!/bin/zsh
# Double-click this. It installs the FIFA 17 fixes into a copy of your CrossOver.
# Everything it does can be undone with "Uninstall.command" beside it.

cd "${0:A:h}" || exit 1

# A folder that came out of a downloaded zip is quarantined by macOS. Clearing it
# here means the files we are about to install are not, which avoids a confusing
# "cannot be opened" later on. setup.sh also copies without the attribute, so
# running it straight from Terminal is just as safe.
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

print -r -- ""
case $rc in
    0)
        print -r -- "  Finished. Open CrossOver-FIFA (not your normal CrossOver),"
        print -r -- "  open the Aurora17 bottle, and press PLAY FIFA 17."
        ;;
    3)
        # setup.sh has already printed which permission is missing and how to
        # grant it. Retrying under sudo was tried and removed: App Management is
        # granted to the application running the script, so root does not bypass
        # it, and running as root leaves app files owned by root afterwards.
        print -r -- "  It stopped because macOS would not allow a change."
        print -r -- "  Follow the instructions above, then run this again."
        ;;
    4)
        print -r -- "  It stopped because something did not match what it expected."
        print -r -- "  The reason is above. If it mentions checksums, download and"
        print -r -- "  extract this package again — do not install what is here now."
        ;;
    5)
        print -r -- "  CrossOver is patched, but the game will not start yet."
        print -r -- "  The missing piece is listed above. Fix it and run this again."
        print -r -- "  To check at any time, run:  ./setup.sh --verify"
        ;;
    *)
        print -r -- "  It stopped early — the reason is printed above."
        print -r -- "  SETUP.md explains every step and what to do about each failure."
        ;;
esac
print -r -- ""
print -r -- "  Press return to close this window."
read -r _
exit $rc
