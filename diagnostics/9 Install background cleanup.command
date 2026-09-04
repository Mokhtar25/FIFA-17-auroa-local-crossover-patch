#!/bin/zsh
# Installs the background job that clears strays and ports by itself.
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --agent
