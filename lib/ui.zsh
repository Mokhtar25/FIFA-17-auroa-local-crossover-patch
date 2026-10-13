# Native dialogs shared by setup.sh and its double-click commands. All text
# travels as osascript arguments, never as generated AppleScript code.
ui_gui_ok() {
    [ "${CX_DIALOGS:-0}" = 1 ] && [ -z "${CX_NO_DIALOGS:-}" ] \
        && [ -z "${SSH_CONNECTION:-}" ] && [ -z "${SSH_TTY:-}" ] \
        && command -v osascript >/dev/null 2>&1 \
        && [ "$(launchctl managername 2>/dev/null)" = Aqua ]
}

ui_ask() {
    local title="$1" message="$2" yes="$3" no="$4" default="${5:-no}" answer
    if ! ui_gui_ok; then
        print -u2 -r -- "$title: $message"
        [ "$default" = yes ]; return
    fi
    # 2>/dev/null: the button that is not "yes" is the cancel button, and
    # osascript reports pressing it as "execution error: User canceled (-128)".
    answer="$(osascript - "$title" "$message" "$yes" "$no" "$default" 2>/dev/null <<'EOS'
on run argv
    set defaultButton to item 4 of argv
    if item 5 of argv is "yes" then set defaultButton to item 3 of argv
    set response to display dialog (item 2 of argv) with title (item 1 of argv) buttons {item 4 of argv, item 3 of argv} default button defaultButton cancel button (item 4 of argv) giving up after 300
    if gave up of response then return "timeout"
    return button returned of response
end run
EOS
)" || return 1
    [ "$answer" = "$yes" ]
}

ui_notify() {
    ui_gui_ok || return 0
    osascript - "$1" "$2" <<'EOS'
on run argv
    display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK"
end run
EOS
}

ui_choose_folder() {
    ui_gui_ok || return 1
    local location="${2:-/Volumes}" answer
    [ -d "$location" ] || location="$HOME"
    answer="$(osascript - "$1" "$location" 2>/dev/null <<'EOS'
on run argv
    set folderChosen to choose folder with prompt (item 1 of argv) default location (POSIX file (item 2 of argv))
    return POSIX path of folderChosen
end run
EOS
)" || return 1
    [ -n "$answer" ] || return 1
    print -r -- "$answer"
}

ui_pick_game() {
    ui_gui_ok || return 1
    local answer
    answer="$(osascript - "$1" "${2:-0}" <<'EOS'
on run argv
    set games to {"FIFA 15", "FIFA 16", "FIFA 17", "FIFA 21"}
    if item 2 of argv is "1" then set end of games to "Forget a choice…"
    set pickedGames to choose from list games with title (item 1 of argv) with prompt "Choose a game" without multiple selections allowed
    if pickedGames is false then return ""
    return item 1 of pickedGames
end run
EOS
)" || return 1
    [ -n "$answer" ] || return 1
    print -r -- "$answer"
}
