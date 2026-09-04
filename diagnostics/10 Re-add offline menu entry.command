#!/bin/zsh
# Puts the 'FIFA 17 (offline)' entry back in the bottle.
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --offline-menu
