#!/bin/zsh
# usage: close-game.sh <12|15|16|17|21>
# Close the game like a user would: press the red button of its window (Cmd+Q and Esc do nothing in FIFA 21).
# Aurora then closes itself ("closing Aurora with it"). Prints whether the game process is gone.
GAME=$1; HERE=${0:A:h}; source $HERE/lib.sh
P=$(game_pid) || { echo "game $GAME not running"; exit 0; }
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $P) to true"; sleep 1
R=(${=$(launcher_rect $P)}); [[ -z $R ]] && { echo "no game window"; exit 1; }
shot $OUT/before-close-$GAME.png
$CLICK $(( R[1]+15 )) $(( R[2]+14 ))
for i in {1..20}; do game_pid >/dev/null || { echo "game $GAME closed after ~$((i*2)) s"; exit 0; }; sleep 2; done
echo "game $GAME still running 40 s after the close click"; exit 1
