#!/bin/zsh
# Double-click this when FIFA 17 or the RebornFUT launcher stopped working after
# it once did, or when this folder is newer than what is installed on this Mac.
#
# It quits CrossOver cleanly, puts back any fix file that is missing or out of
# date in the CrossOver-FIFA copy and re-signs it, sets the Aurora17 bottle up
# again (settings, overrides, hosts, menu entries, and the WebView2 runtime the
# launcher's window needs), has the game's own loader write a fresh licence
# file, and checks the lot. CrossOver is not copied again. Your saves and the
# game's own files are not touched.
#
# It is the same as "diagnostics/15 Fix my installation.command"; it is here
# so it can be found without opening that folder. From Terminal: ./setup.sh --repair
cd "${0:A:h}" || exit 1
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x ./diagnostics/_action.zsh ./diagnostics/*.command 2>/dev/null || true
exec ./diagnostics/_action.zsh --repair
