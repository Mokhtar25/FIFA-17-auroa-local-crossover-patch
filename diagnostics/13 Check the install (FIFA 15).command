#!/bin/zsh
# Checks the FIFA 15 setup. Changes nothing.
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec env AURORA_GAME=fifa15 ./_action.zsh --verify
