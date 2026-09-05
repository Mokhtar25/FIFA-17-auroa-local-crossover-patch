#!/bin/zsh
# Makes the game's own loader write a fresh EA licence file, and says whether
# the one that was there was different.
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --reseed-licence
