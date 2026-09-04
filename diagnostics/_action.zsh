#!/bin/zsh
# The shared body of every command in this folder. Each .command beside this is
# four lines: it names one action, and this decides what to print around it and
# runs ../setup.sh with the matching flag.
#
#   ./_action.zsh <flag>            e.g.  ./_action.zsh --bundle
#
# One place holds an action's title, its explanation and what its exit codes
# mean, so the .command files stay short enough to read at a glance.
#
# Started by a double-click, so it never assumes a working directory and never
# closes the window on its own: the window is the only place the person can
# read what happened.

if [ -z "${ZSH_VERSION:-}" ]; then
    exec /bin/zsh "$0" "$@"
fi

set -u
HERE="${0:A:h}"
RELEASE="${HERE:h}"

cd "$RELEASE" 2>/dev/null || {
    print -r -- "Cannot find the FIFA folder above $HERE. Keep the diagnostics"
    print -r -- "folder inside the folder that setup.sh is in."
    print -r -- "Press return to close this window."
    read -r _
    exit 2
}

[ -f ./setup.sh ] || {
    print -r -- "setup.sh is not in $RELEASE."
    print -r -- "Keep this folder inside the one setup.sh is in, and try again."
    print -r -- "Press return to close this window."
    read -r _
    exit 2
}

# A folder that came out of a downloaded zip is quarantined by macOS, which
# stops the scripts running with a message about an unidentified developer.
xattr -dr com.apple.quarantine "$RELEASE" 2>/dev/null || true
chmod +x ./setup.sh ./uninstall.sh 2>/dev/null || true
chmod +x "$HERE"/*.command "$HERE"/_action.zsh 2>/dev/null || true

FLAG="${1:-}"
[ -n "$FLAG" ] || { print -r -- "No action given."; exit 2 }

if [ -t 1 ]; then RED=$'\e[1;31m' GRN=$'\e[32m' YEL=$'\e[33m' OFF=$'\e[0m'
else RED='' GRN='' YEL='' OFF=''; fi

TITLE=''; typeset -a BLURB; BLURB=()
case "$FLAG" in
    --bundle)
        TITLE="Collect diagnostics"
        BLURB=(
          "This gathers everything a bug report needs into one zip and puts it"
          "in this diagnostics folder: the checks below, the newest Aurora17"
          "logs, the bottle's settings and the hashes of what is installed."
          ""
          "It changes nothing, and it sends nothing anywhere. It holds no"
          "account, no password and no session token."
        ) ;;
    --report)
        TITLE="Report"
        BLURB=(
          "This prints one page saying what is installed, what is running and"
          "what the newest log says, and saves it as report.txt in this folder."
          ""
          "It changes nothing. If you were asked for 'the report', this is it."
        ) ;;
    --verify)
        TITLE="Check the install"
        BLURB=(
          "This checks an install that is already there: the files, the"
          "signature, the bottle and its settings."
          ""
          "It changes nothing. It says ok, note or BAD for each thing it looks"
          "at, and the exit line below says whether anything is wrong."
        ) ;;
    --unstick)
        TITLE="Unstick"
        BLURB=(
          "Use this when a bottle sits on 'loading', or PLAY says a port is"
          "already in use."
          ""
          "It kills the leftover Wine processes and frees the ports Aurora17"
          "uses. It does not touch the game, the install or your saves."
        ) ;;
    --shutdown)
        TITLE="Quit CrossOver cleanly"
        BLURB=(
          "This stops the games and Aurora, shuts every bottle's wineserver"
          "down, quits CrossOver, then frees any held port."
          ""
          "Closing CrossOver's window is not quitting on a Mac, which is what"
          "leaves the strays behind that this clears."
        ) ;;
    --resign)
        TITLE="Repair the signature"
        BLURB=(
          "Use this when the CrossOver copy will not open, or macOS says it is"
          "damaged, after the files were already installed."
          ""
          "It re-signs the copy. Nothing is copied again and no setting"
          "changes, so it is quick."
        ) ;;
    --smoke)
        TITLE="Smoke test"
        BLURB=(
          "This watches one PLAY from start to finish and says pass or fail."
          ""
          "Start the game the way you normally would when it tells you to. It"
          "reads the logs while you play; it does not press anything for you."
        ) ;;
    --bottle)
        TITLE="Set the bottle up again"
        BLURB=(
          "Use this after making a fresh Aurora17 bottle, which is the cure for"
          "a bottle that has gone bad."
          ""
          "It puts the settings, the version override, the menu entries and the"
          "network mappings into the bottle. The CrossOver copy is not touched."
        ) ;;
    --agent)
        TITLE="Install the background cleanup"
        BLURB=(
          "This installs a small background job that clears orphaned Wine and"
          "Aurora processes, and the ports they hold, by itself every 30"
          "seconds after CrossOver quits."
          ""
          "With it installed no script has to be run to unstick anything."
        ) ;;
    --offline-menu)
        TITLE="Re-add the offline menu entry"
        BLURB=(
          "This puts the 'FIFA 17 (offline)' entry back in the bottle, e.g."
          "after moving the game folder."
        ) ;;
    *)
        TITLE="setup.sh $FLAG"
        BLURB=( "Runs:  ./setup.sh $FLAG" ) ;;
esac

underline=""
repeat ${#TITLE}; do underline="$underline="; done

clear
print -r -- ""
print -r -- "  $TITLE"
print -r -- "  $underline"
print -r -- ""
for line in "${BLURB[@]}"; do
    if [ -n "$line" ]; then print -r -- "  $line"; else print -r -- ""; fi
done
print -r -- ""

./setup.sh "$FLAG"
rc=$?

print -r -- ""
case $rc in
    0) print -r -- "  ${GRN}Finished.${OFF}" ;;
    2) print -r -- "  ${RED}Stopped: this Mac or this command is not supported here.${OFF}"
       print -r -- "  The reason is printed above." ;;
    3) print -r -- "  ${RED}Stopped: macOS would not allow a change.${OFF}"
       print -r -- "  Follow the steps printed above, then run this again." ;;
    4) print -r -- "  ${RED}Stopped: something did not match what it expected.${OFF}"
       print -r -- "  If it mentions checksums, download and extract the package again." ;;
    5) print -r -- "  ${YEL}Not finished: the install is incomplete.${OFF}"
       print -r -- "  The missing piece is named above. Fix it, then run the installer again." ;;
    *) print -r -- "  ${RED}Stopped early.${OFF} The reason is printed above."
       print -r -- "  If nothing above explains it, that is worth reporting:"
       print -r -- "  double-click '1 Collect diagnostics.command' and send the zip." ;;
esac

case "$FLAG" in
    --bundle|--report)
        print -r -- ""
        print -r -- "  The files are in this folder:"
        print -r -- "    $HERE"
        open "$HERE" 2>/dev/null || true ;;
esac

print -r -- ""
print -r -- "  Press return to close this window."
read -r _
exit $rc
