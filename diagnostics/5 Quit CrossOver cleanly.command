#!/bin/zsh
# Quits CrossOver properly so no strays and no held ports are left.
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --shutdown
