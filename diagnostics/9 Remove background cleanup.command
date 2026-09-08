#!/bin/zsh
# Removes the 30-second LaunchAgent older versions installed.
# Nothing from this package runs in the background any more.
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --agent
