#!/bin/zsh
# Sets up FIFA 17 and FIFA 15 together, both in the one CrossOver-FIFA copy.
#
#   ./setup-both.sh [/path/to/CrossOver.app]   install FIFA 17, then set FIFA 15 up
#   ./setup-both.sh --verify                   check both, change nothing
#   ./setup-both.sh --unstick                  free the bottles (same as setup.sh --unstick)
#   ./setup-both.sh --shutdown                 quit CrossOver cleanly, then free
#   ./setup-both.sh --agent                    install the background cleanup timer
#
# It is setup.sh twice: the FIFA 17 install first (the copy, the seven files,
# the Aurora17 bottle, the stand-in, the EA names, the licence), then
# setup.sh --fifa15 (the Aurora15 bottle, its settings, the game-folder check).
# The FIFA 15 half only runs when the FIFA 17 half finished, since it needs the
# copy that half makes. Every option setup.sh takes is documented there; exit
# codes are setup.sh's, from whichever half stopped.

set -u
# Run under zsh whatever it was started with. Every line below is zsh, and the
# very next one -- HERE="${0:A:h}" -- is the trap: bash and sh read ${0:A:h} as
# their own ${var:offset:length}, evaluate the offset "A" as arithmetic, and
# with set -u stop at "A: unbound variable". That names a variable this script
# does not have, on a line that looks innocent, so "bash setup.sh" or
# "sh setup.sh" failed with a message nobody could act on. Re-exec instead.
# This block is plain POSIX so bash and sh get here before parsing any zsh.
if [ -z "${ZSH_VERSION:-}" ]; then
    if [ -x /bin/zsh ]; then
        exec /bin/zsh "$0" "$@"
    fi
    printf '%s\n' "This needs zsh, which every Mac has at /bin/zsh, and it is missing." >&2
    printf '%s\n' "Nothing has been changed." >&2
    exit 2
fi

HERE="${0:A:h}"
cd "$HERE" || exit 1

case "${1:-}" in
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --unstick) exec ./setup.sh --unstick ;;
    --shutdown) exec ./setup.sh --shutdown ;;
    --agent) exec ./setup.sh --agent ;;
    --verify)
        print -r -- ""
        print -r -- "==== FIFA 17 ===="
        ./setup.sh --verify; rc17=$?
        print -r -- ""
        print -r -- "==== FIFA 15 ===="
        ./setup.sh --fifa15 --verify; rc15=$?
        [ "$rc17" -ne 0 ] && exit $rc17
        exit $rc15 ;;
    -*) print -r -- "setup-both.sh takes a CrossOver path, --verify, --unstick, --shutdown, --agent or --help."
        print -r -- "For anything else use ./setup.sh (see ./setup.sh --help)."; exit 2 ;;
esac

print -r -- ""
print -r -- "==== 1 of 2: FIFA 17 ===="
./setup.sh "$@"; rc=$?
if [ "$rc" -ne 0 ]; then
    print -r -- ""
    print -r -- "The FIFA 17 half stopped (exit $rc), so FIFA 15 was not set up."
    print -r -- "Fix what it says above and run this again."
    exit $rc
fi

print -r -- ""
print -r -- "==== 2 of 2: FIFA 15 ===="
./setup.sh --fifa15; rc=$?
if [ "$rc" -ne 0 ]; then
    print -r -- ""
    print -r -- "FIFA 17 is set up. The FIFA 15 half stopped (exit $rc); fix what it says"
    print -r -- "above and run  ./setup.sh --fifa15  to finish it."
    exit $rc
fi

print -r -- ""
print -r -- "Both games are set up in the same CrossOver-FIFA. Open it (not your normal"
print -r -- "CrossOver): Aurora17 bottle for FIFA 17, Aurora15 bottle for FIFA 15."
print -r -- "To check later:  ./setup-both.sh --verify"
exit 0
