#!/bin/zsh
# Re-signs the CrossOver copy when macOS says it is damaged.
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --resign
