#!/bin/zsh
# End to end: start the Aurora launcher, sign in if needed, open the game's page, press Play, watch the
# game for a few minutes and print a verdict (graphics backend, still running, frozen-looking).
# usage: play-game.sh <12|15|16|17|21> [--unstick] [--watch SECONDS] [--authorize] [--no-play]
#   --helper     FIFA 12 only: run Aurora 12's helper (`futlink play`) directly; the launcher's Play button
#                only runs Repair (exit 22) on this Mac
#   --no-play    only open the game's page and print its Play state (FIFA 16)
#   --unstick    stop everything in the bottle first (./setup.sh --unstick)
#   --watch N    monitor the game for N seconds (default 180)
#   --authorize  after "Sign in with Discord", click "Authorize" in the browser if it is already logged in
HERE=${0:A:h}
GAME=$1; shift; [[ $GAME == (12|15|16|17|21) ]] || { grep "^# usage" $0; exit 2; }
source $HERE/lib.sh
WATCH=180; UNSTICK=; AUTH=; NOPLAY=; HELPER=
while (( $# )); do case $1 in
  --unstick) UNSTICK=--unstick;; --watch) WATCH=$2; shift;; --authorize) AUTH=1;; --no-play) NOPLAY=1;; --helper) HELPER=1;; esac; shift; done
say() { print -r -- "[$(date +%H:%M:%S)] $*"; }

# ---- 1. launcher up and in front
if [[ -n $HELPER && $GAME == 12 ]] && ! game_pid >/dev/null; then
  [[ -n $UNSTICK ]] && (cd ${HERE:h:h} && ./setup.sh --unstick 2>&1 | tail -1)
  MARK=$OUT/start-mark-12; touch $MARK
  nohup $WINE --bottle Aurora17 --cx-app 'C:\users\crossover\AppData\Local\Aurora12\FIFA12\tools\futlink.exe' \
    --root 'C:\users\crossover\AppData\Local\Aurora12\FIFA12' play >$OUT/futlink12.out 2>&1 </dev/null &
  for i in {1..45}; do game_pid >/dev/null && break; sleep 2; done
  game_pid >/dev/null || { say "fifa.exe never appeared"; tail -5 $OUT/futlink12.out | cut -c1-250; exit 4; }
fi
if ! game_pid >/dev/null; then
  $HERE/launcher-start.sh $UNSTICK || exit 1
  sleep 20   # the launcher checks for updates and a saved sign-in first
  MARK=$OUT/start-mark-$GAME; touch $MARK
  firewall_prompt_up && { say "firewall prompt up: Not now"; $HERE/launcher-click.sh fwnotnow; }
  $HERE/launcher-click.sh game$GAME; sleep 3
  say "Aurora $GAME Play state before: $(play_state)"; log_tail 40 | grep -a "Aurora $GAME Play" | tail -1
  [[ -n $NOPLAY ]] && { shot $OUT/page-$GAME.png; exit 0; }

  # ---- 2. sign in / press Play until the game's own start window or FIFA17.exe shows up
  clicked_signin=0; plays=0; fw_done=0
  for i in {1..90}; do
    game_pid >/dev/null && break
    if gate_pid >/dev/null; then
      G=$(gate_pid); front_of $G || { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $G) to true"; sleep 1; }
      R=(${=$(launcher_rect $G)})
      shot $OUT/before-gameplay-$GAME.png
      if [[ -n $R ]] && front_of $G; then
        say "game start window (_fifa$GAME.exe) is up: clicking its PLAY"
        $CLICK $(( R[1]+0.757*R[3] )) $(( R[2]+0.936*R[4] )); sleep 5
      fi
      continue
    fi
    S=$(play_state)
    case $S in
      SignIn)
        if (( ! clicked_signin )); then
          say "launcher wants Discord sign-in: pressing it (browser opens)"; $HERE/launcher-click.sh signin; clicked_signin=1; sleep 8
          if [[ -n $AUTH ]]; then $HERE/discord-authorize.sh || { say "STOP: sign in by hand, then re-run"; exit 3; }
          else say "authorize in the browser (or re-run with --authorize); waiting up to 2 min"; fi
        fi;;
      Ready|TryAgain|Unknown)
        if (( plays < 3 )) && launcher_pid >/dev/null; then
          front_launcher
          if firewall_prompt_up; then say "firewall prompt up: Not now"; $HERE/launcher-click.sh fwnotnow
          else say "state=$S: pressing Play"; $HERE/launcher-click.sh play; plays=$((plays+1)); fi
        fi;;
      *) say "state=$S";;
    esac
    if firewall_prompt_up 2>/dev/null; then say "firewall prompt up: Not now"; $HERE/launcher-click.sh fwnotnow; fi
    sleep 4
  done
  game_pid >/dev/null || { say "game process never appeared; last launcher state: $(play_state)"; log_tail 6; shot $OUT/no-game-$GAME.png; exit 4; }
fi

# ---- 3. monitor
P=$(game_pid); T0=$SECONDS; say "game pid=$P ($(ps -o command= -p $P | cut -c1-80)), watching $WATCH s"
backend=""; maxcpu=0; samples=(); shots=(10 30 90 170); gone=
while (( SECONDS-T0 < WATCH )); do
  t=$((SECONDS-T0))
  if ! kill -0 $P 2>/dev/null; then gone=$t; break; fi
  st=$(ps -o %cpu=,rss= -p $P 2>/dev/null); cpu=${${=st}[1]}; rss=${${=st}[2]}
  # lsof only reads the process' mapped files; vmmap (used once at the end) briefly suspends it
  libs=$(lsof -p $P 2>/dev/null | grep -i -o -E 'D3DMetal\.framework|wined3d\.dll' | sort -u | tr '\n' ' ')
  [[ -n $libs ]] && backend=$libs
  say "t=${t}s cpu=${cpu}% rss=$((rss/1024))MB libs=${libs:-?}"
  samples+=($cpu); (( cpu > maxcpu )) && maxcpu=$cpu
  for s in $shots; do (( t >= s && t < s+6 )) && shot $OUT/g$GAME-t$s.png; done
  screencapture -x $OUT/g$GAME-last.png   # overwritten each sample: what the screen showed just before an exit
  sleep $(( t < 60 ? 3 : 6 ))
done

# ---- 4. verdict
echo; echo "================ VERDICT ================"
if [[ -z $gone ]]; then
  vm=$(vmmap $P 2>/dev/null | grep -i -o -E 'D3DMetal\.framework|wined3d\.dll' | sort -u | tr '\n' ' '); [[ -n $vm ]] && backend=$vm
fi
echo "graphics backend of game : ${backend:-unknown (process gone before it could be read)}"
case $backend in *wined3d*) echo "  -> BAD: game loaded wined3d";; *D3DMetal*) echo "  -> OK: D3DMetal, no wined3d";; esac
if [[ -n $gone ]]; then
  echo "game state                     : EXITED/CRASHED after ${gone}s (pid $P gone)"
else
  echo "game state                     : still running after $WATCH s"
fi
echo "cpu samples (%)                : ${samples[*]}   (max $maxcpu)"
if [[ $GAME == 17 ]]; then echo "fut17shim CRASH lines          : $(grep -c 'CRASH' $SHIM 2>/dev/null) total; recent:"; grep 'CRASH' $SHIM 2>/dev/null | tail -3; fi
if [[ -z $gone ]]; then
  # frozen-looking = CPU pinned above 200% in the last samples and the game window not changing
  last=(${samples[-3,-1]}); pinned=1; for c in $last; do (( c > 200 )) || pinned=0; done
  W=(${=$(launcher_rect $P)}); same=unknown
  if [[ -n $W ]]; then
    screencapture -x -R"${W[1]},${W[2]},${W[3]},${W[4]}" $OUT/win-a.png; sleep 4
    screencapture -x -R"${W[1]},${W[2]},${W[3]},${W[4]}" $OUT/win-b.png
    cmp -s $OUT/win-a.png $OUT/win-b.png && same=yes || same=no
  fi
  echo "cpu pinned >200% (last 3)      : $([[ $pinned == 1 ]] && echo yes || echo no)"
  echo "game window static over 4 s    : $same"
  [[ $pinned == 1 && $same == yes ]] && echo "  -> FROZEN-LOOKING" || echo "  -> not frozen-looking"
fi
echo "launcher.log (no Discord presence):"; log_tail 6
echo "per-game launcher logs ($GAMELOGS), last lines:"; for f in $GAMELOGS/*.log(N); do echo "-- $f"; tail -5 $f | cut -c1-220; done
echo "files changed in the game folder during this run:"; [[ -n $MARK ]] && find $GAMEDIR[$GAME] -maxdepth 2 -newer $MARK -type f 2>/dev/null | head -20
echo "screenshots in $OUT"
