#!/bin/zsh
# run.sh [debug channels] — start FIFA 14 the way the 3DM launcher does, click
# "Launch Game", and print the game's Wine pid.
#
# The launcher's window is transparent and ignores macOS synthetic input, so
# the click goes through click.exe, which uses Wine's own input stack.  The
# launcher's window has to be frontmost first or the click lands on whatever
# is behind it.
#
# Environment: BOTTLE (default Aurora17), GAME (default the ModdingWay folder
# under Drive C), LAUNCH_X / LAUNCH_Y (default the "Launch Game" button).
# Pass +seh / +virtual / +timestamp as the argument to trace; the trace goes to
# the file named by $LOG (default /tmp/fifa14-run.log).
#
# The wrapper can exit while the game keeps running: this prints the pid it
# found and leaves the game up.  Kill it with pkill -f fifa14.exe.
set -u
HERE=${0:A:h}
BOTTLE=${BOTTLE:-Aurora17}
GAME=${GAME:-'C:\users\crossover\Downloads\FIFA14MW\Game'}
LAUNCH_X=${LAUNCH_X:-787}
LAUNCH_Y=${LAUNCH_Y:-543}
LOG=${LOG:-/tmp/fifa14-run.log}
CX=/Applications/CrossOver-FIFA.app/Contents/SharedSupport/CrossOver
W=$CX/bin/wine
CC=i686-w64-mingw32-gcc

for t in ps eip mem protect win click; do
    [[ -x $HERE/$t.exe ]] || $CC -O1 -o $HERE/$t.exe $HERE/$t.c || exit 1
done

# A leftover launcher or game would take the click or the profile.
pkill -f fifa14.exe 2>/dev/null
pkill -f fifa14-3dm.exe 2>/dev/null
sleep 1

if [[ -n ${1:-} ]]; then
    "$W" --bottle "$BOTTLE" --debugmsg "$1" --workdir "$GAME" \
        --cx-app "$GAME\\fifa14-3dm.exe" > "$LOG" 2>&1 &
else
    "$W" --bottle "$BOTTLE" --debugmsg '-all' --workdir "$GAME" \
        --cx-app "$GAME\\fifa14-3dm.exe" > "$LOG" 2>&1 &
fi
print "waiting for the launcher"
for i in {1..40}; do
    pgrep -f fifa14-3dm.exe >/dev/null && break
    sleep 0.5
done
sleep 6   # the window appears before it can be clicked; it is empty until then

osascript -e 'tell application "System Events" to set frontmost of process "fifa14-3dm.exe" to true' 2>/dev/null
sleep 1
"$W" --bottle "$BOTTLE" --workdir "Z:$HERE" --cx-app "Z:$HERE\\click.exe" $LAUNCH_X $LAUNCH_Y

print "waiting for fifa14.exe"
for i in {1..60}; do
    pid=$("$W" --bottle "$BOTTLE" --workdir "Z:$HERE" --cx-app "Z:$HERE\\ps.exe" fifa14.exe 2>/dev/null | head -1)
    [[ -n $pid ]] && break
    sleep 0.5
done
print "winpid=$pid  (log $LOG)"
