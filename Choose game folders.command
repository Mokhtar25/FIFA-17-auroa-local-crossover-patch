#!/bin/zsh
# Double-click to remember game folders, including games on external drives.
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi
set -u
HERE="${0:A:h}"
cd "$HERE" || exit 2
source "$HERE/lib/ui.zsh"
export CX_DIALOGS=1
# The whole run is also saved in ~/Library/Logs/FIFA-CrossOver, for
# "1 Collect diagnostics" to send (lib/runlog.zsh).
[ -f "$HERE/lib/runlog.zsh" ] && source "$HERE/lib/runlog.zsh" && runlog_start choose-folders "${0:A}" "$@"

if ! ui_gui_ok; then
    print -r -- "Use Terminal to save or forget a game folder:"
    print -r -- "  ./setup.sh --choose-folder fifa15 '/path/to/FIFA 15'"
    print -r -- "  ./setup.sh --forget-folder fifa15"
    exit 2
fi

selected="$(ui_pick_game 'Choose game folders' 1)" || exit 0
forget=0
if [ "$selected" = 'Forget a choice…' ]; then
    forget=1
    selected="$(ui_pick_game 'Forget a folder choice' 0)" || exit 0
fi
case "$selected" in
    'FIFA 15') game=fifa15; exe=fifa15.exe ;;
    'FIFA 16') game=fifa16; exe=fifa16.exe ;;
    'FIFA 17') game=fifa17; exe=FIFA17.exe ;;
    'FIFA 21') game=fifa21; exe=FIFA21.exe ;;
    *) exit 2 ;;
esac

if [ "$forget" = 1 ]; then
    if /bin/zsh "$HERE/setup.sh" --forget-folder "$game"; then
        ui_notify 'Folder choice forgotten' "$selected will use Aurora's record or automatic folder discovery."
        exit 0
    else
        rc=$?
        ui_notify 'Could not forget the choice' 'The Terminal window shows the reason. Your previous choices were kept.'
        exit "$rc"
    fi
fi

location=/Volumes
choices="$HOME/Library/Application Support/FIFA-CrossOver/choices.conf"
if [ -f "$choices" ]; then
    saved="$(sed -n "s/^$game\.folder=//p" "$choices" | tr -d '\r' | tail -1)"
    [ -d "$saved" ] && location="$saved"
fi
while true; do
    folder="$(ui_choose_folder "Select $selected game files. Select the folder containing $exe." "$location")" || exit 0
    if /bin/zsh "$HERE/setup.sh" --choose-folder "$game" "$folder"; then
        break
    else
        rc=$?
        if [ "$rc" != 2 ]; then
            ui_notify 'Could not save the choice' 'The Terminal window shows the reason. Your previous choices were kept.'
            exit "$rc"
        fi
        ui_ask "Select $selected game files" "That folder does not identify one $selected game. Select the folder containing $exe, or its parent if it contains only one copy." 'Choose again' 'Cancel' no || exit 0
        location="$folder"
    fi
done

ui_ask 'Folder saved' "Apply $selected settings now? This quits CrossOver and any running game before setup. Choose Later to keep the folder choice without applying settings." 'Apply and quit CrossOver' 'Later' no || exit 0
/bin/zsh "$HERE/setup.sh" --shutdown || exit $?
case "$game" in
    fifa17) AURORA_GAME=fifa17 /bin/zsh "$HERE/setup.sh" ;;
    *) /bin/zsh "$HERE/setup.sh" "--$game" ;;
esac
rc=$?
if [ "$rc" = 0 ]; then
    ui_notify 'Setup finished' "$selected settings were applied. The Terminal window shows the checks and how to play."
else
    ui_notify 'Setup did not finish' 'The Terminal window shows the reason and the next step. Your folder choice is still saved.'
fi
exit "$rc"
