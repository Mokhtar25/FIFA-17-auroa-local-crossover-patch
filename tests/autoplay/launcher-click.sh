#!/bin/zsh
# usage: launcher-click.sh <button> [--dry]
# Clicks a named button of the Aurora launcher window. Positions are fractions of the window
# rect (x y), measured from screenshots of launcher 1.2.190. Takes a screenshot first and
# refuses to click if the launcher window is not frontmost.
HERE=${0:A:h}; source $HERE/lib.sh
typeset -A BTN
BTN=(
  signin    "0.854 0.926"   # "Sign in with Discord", sign-in page, bottom right
  exit      "0.389 0.926"   # "Exit", sign-in page
  trouble   "0.480 0.926"   # "Troubleshoot", sign-in page
  play17    "0.152 0.457"   # big "Play" button on the Aurora 17 page
  fwnotnow  "0.595 0.676"   # "Not now" on the in-launcher Windows Firewall prompt
  game21    "0.272 0.932"   # pills of the game switcher at the bottom (measured on 1.2.190)
  game17    "0.352 0.932"
  game16    "0.431 0.932"
  game15    "0.511 0.932"
  game12    "0.589 0.932"
  play      "0.152 0.457"   # big "Play" button, same place on every game page
)
[[ -f $HERE/buttons.local ]] && source $HERE/buttons.local   # extra BTN entries discovered later
name=$1
[[ -z $name || -z ${BTN[$name]} ]] && { echo "usage: $0 <${(kj:|:)BTN}>"; exit 2; }
P=$(launcher_pid) || { echo "launcher not running"; exit 1; }
front_launcher
R=(${=$(launcher_rect $P)}); [[ -z $R ]] && { echo "no launcher window"; exit 1; }
shot $OUT/before-$name.png
is_front || { echo "REFUSING: launcher window is not frontmost"; exit 1; }
F=(${=BTN[$name]})
X=$(( R[1] + F[1]*R[3] )); Y=$(( R[2] + F[2]*R[4] ))
echo "window=$R  click '$name' at ($X, $Y)"
[[ $2 == --dry ]] && exit 0
$CLICK $X $Y
sleep 2; shot $OUT/after-$name.png
