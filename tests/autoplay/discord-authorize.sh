#!/bin/zsh
# After "Sign in with Discord": if the browser shows Discord's OAuth "Authorize" page and you are
# already logged in, click Authorize. Never types anything; stops if it sees a login form.
HERE=${0:A:h}; source $HERE/lib.sh
APP=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
TITLE=$(osascript -e 'tell application "System Events" to get name of window 1 of (first process whose frontmost is true)' 2>/dev/null)
echo "front app: $APP / window: $TITLE"
if [[ $TITLE != *Authorize* ]]; then echo "front window is not Discord's Authorize page (a login form says 'Log in'): do it by hand."; exit 1; fi
R=(${=$(osascript -e 'tell application "System Events" to set p to first process whose frontmost is true
set {x, y} to position of window 1 of p
set {w, h} to size of window 1 of p
return (x as text) & " " & (y as text) & " " & (w as text) & " " & (h as text)' | tr -d ',')})
shot $OUT/before-authorize.png
# Authorize button: right button of the consent card; fractions of the browser window (Orion, full size)
X=$(( R[1] + 0.642*R[3] )); Y=$(( R[2] + 0.856*R[4] ))
echo "window=$R click Authorize at ($X, $Y)"
$CLICK $X $Y; sleep 6; shot $OUT/after-authorize.png
