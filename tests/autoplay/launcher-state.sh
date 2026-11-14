#!/bin/zsh
# Print the launcher state (from launcher.log), the processes, and take a screenshot.
HERE=${0:A:h}; source $HERE/lib.sh
P=$(launcher_pid) || { echo "launcher: not running"; exit 1; }
echo "launcher pid=$P window=$(launcher_rect $P) frontmost=$(front_of $P && echo yes || echo no)"
echo "Aurora 17 Play button: $(play_state)   (SignIn = needs Discord sign-in, Ready/TryAgain = press Play)"
echo "game: FIFA17.exe pid=$(game_pid || echo none)  game start window pid=$(gate_pid || echo none)"
echo "--- launcher.log (no Discord presence) ---"; log_tail ${1:-6}
shot $OUT/state-$(date +%H%M%S).png
