#!/bin/zsh
# Sets up FIFA 17 and FIFA 15 together, both in the one CrossOver-FIFA copy.
#
#   ./setup-both.sh [/path/to/CrossOver.app]   install FIFA 17, then set FIFA 15 up
#   ./setup-both.sh --verify                   check both, change nothing
#   ./setup-both.sh --offline [CrossOver.app]  FIFA 17 offline, plus FIFA 15
#   ./setup-both.sh --unstick                  free the bottles (same as setup.sh --unstick)
#   ./setup-both.sh --shutdown                 quit CrossOver cleanly, then free
#   ./setup-both.sh --agent                    remove the old background cleanup agent
#
# It is setup.sh twice: the FIFA 17 install first (the copy, the eight files,
# the Aurora17 bottle, the stand-in, the EA names, the licence), then
# setup.sh --fifa15 (the Aurora15 bottle, its settings, the game-folder check).
# The FIFA 15 half needs only the copy, so it runs when the FIFA 17 half
# finished (exit 0) and also when it stopped "not finished" (exit 5: the copy
# is patched, something in the Aurora17 bottle is missing). Any other stop
# means there may be no copy, and FIFA 15 is not attempted. Every option
# setup.sh takes is documented there; exit codes are setup.sh's, FIFA 17's
# first when both halves have one.

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

ACTION=install
OFFLINE=0
case "${1:-}" in
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --unstick|--shutdown|--agent|--verify) ACTION="${1#--}"; shift ;;
    --offline) OFFLINE=1; shift ;;
    -*) print -r -- "Unknown option: $1 (try: ./setup-both.sh --help)"; exit 2 ;;
esac
if [ "$#" -gt 1 ] || [[ "${1:-}" == -* ]] \
   || { [ "$ACTION" != install ] && [ "$#" -ne 0 ]; }; then
    print -r -- "Expected one CrossOver path for install, or one action with no extra arguments."
    exit 2
fi

# A legacy AURORA_BOTTLE override is ambiguous for two games. Require the
# per-game names rather than silently configuring that same bottle twice.
if [ -n "${AURORA_BOTTLE:-}" ]; then
    print -r -- "For both games, unset AURORA_BOTTLE and use FIFA17_BOTTLE and FIFA15_BOTTLE."
    exit 2
fi
F17="${FIFA17_BOTTLE:-Aurora17}"
F15="${FIFA15_BOTTLE:-Aurora15}"
BOTTLES="${CX_BOTTLE_PATH:-$HOME/Library/Application Support/CrossOver/Bottles}"
P17="$BOTTLES/$F17"; P15="$BOTTLES/$F15"
if [ "${(L)P17:A}" = "${(L)P15:A}" ]; then
    print -r -- "FIFA 17 and FIFA 15 need separate bottles. Choose different FIFA17_BOTTLE and FIFA15_BOTTLE names."
    exit 2
fi
run17() { env AURORA_GAME=fifa17 AURORA_BOTTLE="$F17" ./setup.sh "$@"; }
run15() { env AURORA_GAME=fifa15 AURORA_BOTTLE="$F15" ./setup.sh --fifa15 "$@"; }

case "$ACTION" in
    unstick|shutdown|agent) run17 "--$ACTION"; exit $? ;;
    verify)
        print -r -- ""
        print -r -- "==== FIFA 17 ===="
        run17 --verify; rc17=$?
        print -r -- ""
        print -r -- "==== FIFA 15 ===="
        run15 --verify; rc15=$?
        [ "$rc17" -ne 0 ] && exit $rc17
        exit $rc15 ;;
esac

print -r -- ""
print -r -- "==== 1 of 2: FIFA 17 ===="
if [ "$OFFLINE" = 1 ]; then run17 --offline "$@"; else run17 "$@"; fi
rc17=$?
if [ "$rc17" -ne 0 ] && [ "$rc17" -ne 5 ]; then
    print -r -- ""
    print -r -- "The FIFA 17 half stopped (exit $rc17), so FIFA 15 was not set up."
    print -r -- "Fix what it says above and run this again."
    exit $rc17
fi
if [ "$rc17" -eq 5 ]; then
    print -r -- ""
    print -r -- "The FIFA 17 half is not finished: the copy is patched, but something in"
    print -r -- "the $F17 bottle is missing (listed above). FIFA 15 needs only the copy,"
    print -r -- "so it is set up next. Then fix the FIFA 17 piece and run  ./setup.sh --bottle"
fi

print -r -- ""
print -r -- "==== 2 of 2: FIFA 15 ===="
run15 "$@"; rc15=$?
if [ "$rc15" -ne 0 ]; then
    print -r -- ""
    if [ "$rc17" -eq 0 ]; then
        print -r -- "FIFA 17 is set up. The FIFA 15 half stopped (exit $rc15); fix what it says"
        print -r -- "above and run  ./setup.sh --fifa15  to finish it."
        exit $rc15
    fi
    print -r -- "Neither half finished: FIFA 17 exit $rc17, FIFA 15 exit $rc15. Fix what each"
    print -r -- "says above, then  ./setup.sh --bottle  for FIFA 17 and  ./setup.sh --fifa15"
    print -r -- "for FIFA 15. To check both:  ./setup-both.sh --verify"
    exit $rc17
fi
if [ "$rc17" -eq 5 ]; then
    print -r -- ""
    print -r -- "FIFA 15 is set up. FIFA 17 is not finished: the missing piece is listed in"
    print -r -- "the '1 of 2' section above. Fix it, then run  ./setup.sh --bottle  (no"
    print -r -- "re-copy). To check both:  ./setup-both.sh --verify"
    exit 5
fi

print -r -- ""
print -r -- "Both games are set up in the same CrossOver-FIFA. Open it (not your normal"
print -r -- "CrossOver): $F17 bottle for FIFA 17, $F15 bottle for FIFA 15."
print -r -- "FIFA 15: launch through Aurora15Connector's PLAY button. For direct offline"
print -r -- "play, follow fifa15/README.md first; this installer does not apply that patch."
print -r -- "To check later:  ./setup-both.sh --verify"
exit 0
