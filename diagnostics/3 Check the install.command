#!/bin/zsh
# Checks an install that is already there. Changes nothing.
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --verify
