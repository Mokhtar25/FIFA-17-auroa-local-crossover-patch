# shared helpers for the autoplay scripts (source this file)
HERE=${HERE:-${0:A:h}}
WINE=/Applications/CrossOver-FIFA.app/Contents/SharedSupport/CrossOver/bin/wine
BOTTLE=~/"Library/Application Support/CrossOver/Bottles/Aurora17"
LOG=$BOTTLE/drive_c/users/crossover/AppData/Local/Aurora15Connector/logs/launcher.log
SHIM="/Volumes/Untitled/FIFA 17a/fut17shim.log"; [[ -f $SHIM ]] || SHIM=~/"Downloads/FIFA 17 a/fut17shim.log"
OUT=${AUTOPLAY_OUT:-$HERE/out}; mkdir -p $OUT
CLICK=$HERE/click
[[ -x $CLICK ]] || swiftc -O $HERE/click.swift -o $CLICK

# the launcher is the Wine process whose command line is the bare Windows path of Aurora15Connector.exe
launcher_pid() { pgrep -f '^C:.*Aurora15Connector\.exe' | head -1 | grep .; }
# prints "x y w h" (screen points) of the launcher window, empty if none
launcher_rect() {
  osascript -e "tell application \"System Events\"
    set p to first process whose unix id is $1
    if (count of windows of p) is 0 then return \"\"
    set w to window 1 of p
    set {x, y} to position of w
    set {a, b} to size of w
    return (x as text) & \" \" & (y as text) & \" \" & (a as text) & \" \" & (b as text)
  end tell" 2>/dev/null | tr -d ','
}
front_launcher() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $(launcher_pid)) to true" 2>/dev/null
  sleep 1
}
is_front() { [[ $(osascript -e "tell application \"System Events\" to get frontmost of (first process whose unix id is $(launcher_pid))" 2>/dev/null) == true ]]; }
shot() { screencapture -x "$1"; echo "screenshot: $1"; }
# launcher log without the Discord presence chatter
log_tail() { grep -v -i 'discord presence' "$LOG" | tail -${1:-15} | cut -c1-260; }

[[ -x $HERE/pixel ]] || swiftc -O $HERE/pixel.swift -o $HERE/pixel
SCREEN_W=1512
# pid(s) of the game: FIFA17.exe is the game, _fifa17.exe is the game's own start window (Steampunks "PLAY")
# GAME (12|15|16|17|21, default 17) picks the process names; game_pid matches the game's command line
GAME=${GAME:-17}
typeset -A PROC GAMEDIR
PROC=(12 '^Z:.*[\\]fifa\.exe' 15 '[\\]fifa15\.exe' 16 '[\\]fifa16\.exe' 17 '^FIFA17\.exe' 21 '[\\]FIFA21\.exe')
GAMEDIR=(12 "/Volumes/Untitled/FIFA 12" 15 "/Volumes/Untitled/FIFA 15" 16 "/Volumes/Untitled/FIFA 16" 17 "/Volumes/Untitled/FIFA 17a" 21 "/Volumes/Untitled/FIFA-21/FIFA 21")
GAMELOGS=$(dirname $LOG)/fifa$GAME
game_pid() { pgrep -if $PROC[$GAME] | head -1 | grep .; }
gate_pid() { pgrep -f "_fifa${GAME}\.exe" | head -1 | grep .; }
front_of() { [[ $(osascript -e "tell application \"System Events\" to get frontmost of (first process whose unix id is $1)" 2>/dev/null) == true ]]; }
# Play button state of the launcher from its log: SignIn / Ready / TryAgain / SettingUp / Starting / Running / ...
play_state() {
  local l=$(grep -a -E "Aurora $GAME Play (shows|is available)" "$LOG" | tail -1)
  if [[ $l == *"is available again"* ]]; then echo Ready
  elif [[ $l =~ '\(([A-Za-z]+)' ]]; then echo $match[1]
  else echo Unknown; fi
}
# is the launcher's own "Allow your games through Windows Firewall?" prompt up? (white Allow button)
firewall_prompt_up() {
  local R=(${=$(launcher_rect $(launcher_pid))}) f=$OUT/fwcheck.png
  screencapture -x $f
  local rgb=(${=$($HERE/pixel $f $(( R[1]+0.663*R[3] )) $(( R[2]+0.656*R[4] )) $SCREEN_W)})
  (( rgb[1] > 235 && rgb[2] > 235 && rgb[3] > 235 ))
}
# send one key to the frontmost app through System Events: press_key <key code>  (49 space, 36 return, 53 esc)
press_key() { osascript -e "tell application \"System Events\" to key code $1"; }
