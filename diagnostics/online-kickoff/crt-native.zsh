#!/bin/zsh
# Make FIFA 17 use Microsoft's own C runtime DLLs (the copies shipped in the
# game folder) instead of Wine's built-in reimplementations.
#
# Why: the online match is a lockstep simulation. Both players compute the same
# frames and compare checksums; if the maths differ in the last bit, FIFA ends
# the match as a desync ("connection lost" at or just after kickoff). The game
# is a VS2013 build, so sinf/cosf/powf/atan2f come from msvcr120.dll. Wine's
# built-in msvcr120 is not bit-identical to Microsoft's, so a Mac client can
# never agree with a Windows opponent. The run on 2026-09-08 showed exactly
# that: healthy transport, then GDESYNCEND in the game report.
#
#   ./crt-native.zsh apply  [--bottle Aurora17]   set the overrides (records the old values)
#   ./crt-native.zsh revert [--bottle Aurora17]   put the old values back
#   ./crt-native.zsh status [--bottle Aurora17]   show what is set now
#
# Only the bottle registry changes (HKCU\Software\Wine\DllOverrides). No game
# file is touched; the native DLLs are the ones already beside FIFA17.exe.

if [ -z "${ZSH_VERSION:-}" ]; then
    exec /bin/zsh "$0" "$@"
fi
set -u
HERE="${0:A:h}"
WINE='/Applications/CrossOver-FIFA.app/Contents/SharedSupport/CrossOver/bin/wine'
KEY='HKCU\Software\Wine\DllOverrides'
# Only the VS2013 runtime the game's own code uses. Forcing the VS2015 set
# (vcruntime140/msvcp140/concrt140) as well made FIFA17.exe abort ~28 s after
# start on 2026-09-08 (native vcruntime140 on top of Wine's ucrtbase).
DLLS=( msvcr120 msvcp120 )
VALUE='native,builtin'

cmd="${1:-status}"; shift 2>/dev/null
BOTTLE=Aurora17
while (( $# )); do
    case "$1" in
        --bottle) BOTTLE="$2"; shift 2 ;;
        *) print -r -- "crt-native: unknown option $1" >&2; exit 2 ;;
    esac
done
STATE="$HERE/crt-native.$BOTTLE.previous"
[ -x "$WINE" ] || { print -r -- "crt-native: $WINE not found" >&2; exit 2; }

if pgrep -qf 'FIFA17.exe|fifa15.exe' 2>/dev/null; then
    print -r -- "crt-native: a game is running; close it first." >&2; exit 2
fi

query() {   # prints "<dll>=<value>" or "<dll>=(unset)" for each DLL
    local out; out=$("$WINE" --bottle "$BOTTLE" --wait-children reg query "$KEY" 2>/dev/null)
    local d v
    for d in "${DLLS[@]}"; do
        v=$(print -r -- "$out" | awk -v d="$d" 'tolower($1)==d {$1=""; $2=""; sub(/^ +/,""); print; exit}')
        print -r -- "$d=${v:-(unset)}"
    done
}

case "$cmd" in
    status)
        print -r -- "bottle: $BOTTLE"
        query
        ;;
    apply)
        print -r -- "bottle: $BOTTLE"
        if [ ! -f "$STATE" ]; then
            query > "$STATE"
            print -r -- "previous values saved to ${STATE:t}"
        else
            print -r -- "previous values already saved in ${STATE:t} (not overwritten)"
        fi
        for d in "${DLLS[@]}"; do
            "$WINE" --bottle "$BOTTLE" --wait-children reg add "$KEY" /v "$d" /t REG_SZ /d "$VALUE" /f >/dev/null 2>&1 \
                && print -r -- "  $d = $VALUE" || print -r -- "  $d: FAILED"
        done
        print -r -- "now:"; query | sed 's/^/  /'
        ;;
    revert)
        print -r -- "bottle: $BOTTLE"
        [ -f "$STATE" ] || { print -r -- "nothing recorded in ${STATE:t}; nothing to revert" >&2; exit 2; }
        while IFS='=' read -r d v; do
            if [ "$v" = "(unset)" ]; then
                "$WINE" --bottle "$BOTTLE" --wait-children reg delete "$KEY" /v "$d" /f >/dev/null 2>&1
                print -r -- "  $d removed"
            else
                "$WINE" --bottle "$BOTTLE" --wait-children reg add "$KEY" /v "$d" /t REG_SZ /d "$v" /f >/dev/null 2>&1
                print -r -- "  $d = $v"
            fi
        done < "$STATE"
        rm -f "$STATE"
        print -r -- "now:"; query | sed 's/^/  /'
        ;;
    *)
        sed -n '2,18p' "$0"; exit 1 ;;
esac
