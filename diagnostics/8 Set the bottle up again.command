#!/bin/zsh
# Puts the settings and menu entries into a freshly made bottle.
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --bottle
