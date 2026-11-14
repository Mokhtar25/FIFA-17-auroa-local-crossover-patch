#!/bin/zsh
# usage: launcher-start.sh [--unstick]
# Start the Aurora launcher in the Aurora17 bottle, wait for its window, bring it to front.
HERE=${0:A:h}; REPO=${HERE:h:h}; source $HERE/lib.sh
[[ $1 == --unstick ]] && (cd $REPO && ./setup.sh --unstick 2>&1 | tail -3)
if launcher_pid >/dev/null; then
  echo "launcher already running (pid $(launcher_pid))"
else
  echo "starting launcher ..."
  nohup $WINE --bottle Aurora17 'C:\users\crossover\AppData\Local\Aurora15Connector\Aurora15Connector.exe' \
    >$OUT/launcher-wine.out 2>&1 </dev/null &
fi
for i in {1..90}; do
  P=$(launcher_pid) && [[ -n $(launcher_rect $P) ]] && break
  sleep 2
done
P=$(launcher_pid) || { echo "launcher process not found"; exit 1; }
R=$(launcher_rect $P); [[ -z $R ]] && { echo "launcher window not found (pid $P)"; exit 1; }
front_launcher
echo "launcher pid=$P window(x y w h)=$R"
