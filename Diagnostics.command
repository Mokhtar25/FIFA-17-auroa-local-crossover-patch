#!/bin/zsh
# Double-click this when something goes wrong and you were asked for logs.
# It collects everything a bug report needs into one zip inside the
# "diagnostics" folder beside this file, and opens that folder for you.
#
# It changes nothing, and it sends nothing anywhere. The other checks and
# repairs are in that same folder, one .command file each.
cd "${0:A:h}" || exit 1
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x ./diagnostics/_action.zsh ./diagnostics/*.command 2>/dev/null || true
exec ./diagnostics/_action.zsh --bundle
