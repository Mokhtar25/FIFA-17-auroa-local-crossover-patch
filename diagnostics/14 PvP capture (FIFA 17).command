#!/bin/zsh
# Starts Reborn 17 with CrossOver's log, a socket sampler and a packet capture,
# then waits while you play ONE match against another player. Type a note and
# press Return at any moment ("kickoff", "popup: ..."); press Return on an
# empty line when the match is over. Everything lands in one run folder.
cd "${0:A:h}/online-kickoff" || exit 1
./pvp-run.zsh session --game fifa17 "$@"
print -n -- "Press return to close this window. "; read -r _
