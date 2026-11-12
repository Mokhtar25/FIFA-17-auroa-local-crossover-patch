#!/bin/zsh
# race.sh <addr-hex> <len-hex> <prot-hex> [debug-channels]
#
# Diagnostic: starts raceprotect.exe (which waits for fifa14.exe and changes the
# protection of <addr> the moment it appears), then the 3DM launcher, clicks
# "Launch Game", and prints the game pid.  Unlike run.sh it starts the guard
# before the launcher, so nothing can race its own pkill.
#
# Environment: BOTTLE, GAME, LAUNCH_X/Y, LOG, RP_LOG as in run.sh.
set -u
HERE=${0:A:h}
BOTTLE=${BOTTLE:-Aurora17}
GAME=${GAME:-'C:\users\crossover\Downloads\FIFA14MW\Game'}
LAUNCH_X=${LAUNCH_X:-787}
LAUNCH_Y=${LAUNCH_Y:-543}
LOG=${LOG:-/tmp/fifa14-run.log}
RP_LOG=${RP_LOG:-/tmp/fifa14-raceprotect.log}
ADDR=$1
LEN=$2
PROT=$3
CHANNELS=${4:-'+seh'}
CX=/Applications/CrossOver-FIFA.app/Contents/SharedSupport/CrossOver
W=$CX/bin/wine

pkill -f fifa14.exe 2>/dev/null
pkill -f fifa14-3dm.exe 2>/dev/null
sleep 1

: > $RP_LOG
nohup $W --bottle "$BOTTLE" --workdir "Z:$HERE" \
    --cx-app "Z:$HERE\\raceprotect.exe" fifa14.exe $ADDR $LEN $PROT \
    > $RP_LOG 2>&1 < /dev/null &
print "guard started, log $RP_LOG"

sleep 1
"$W" --bottle "$BOTTLE" --debugmsg "$CHANNELS" --workdir "$GAME" \
    --cx-app "$GAME\\fifa14-3dm.exe" > "$LOG" 2>&1 &
print "waiting for the launcher"
for i in {1..40}; do
    pgrep -f fifa14-3dm.exe >/dev/null && break
    sleep 0.5
done
sleep 6

osascript -e 'tell application "System Events" to set frontmost of process "fifa14-3dm.exe" to true' 2>/dev/null
sleep 1
"$W" --bottle "$BOTTLE" --workdir "Z:$HERE" --cx-app "Z:$HERE\\click.exe" $LAUNCH_X $LAUNCH_Y

print "waiting for fifa14.exe"
for i in {1..60}; do
    pid=$("$W" --bottle "$BOTTLE" --workdir "Z:$HERE" --cx-app "Z:$HERE\\ps.exe" fifa14.exe 2>/dev/null | head -1)
    [[ -n $pid ]] && break
    sleep 0.5
done
print "winpid=$pid  (log $LOG guard $RP_LOG)"
