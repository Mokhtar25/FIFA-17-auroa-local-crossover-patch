#!/bin/zsh
# Fix an install that once worked, without copying CrossOver again. See
# "Fix my installation.command" one folder up, which is the same thing.
cd "${0:A:h}" || exit 1
exec ./_action.zsh --repair
