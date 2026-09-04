#!/bin/zsh
# Prints one page of diagnosis and saves it as report.txt in this folder.
# Double-click it. Everything it prints stays on screen until you press return.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --report
