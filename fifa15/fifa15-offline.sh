#!/bin/zsh
# FIFA 15 offline patch for the crack's Origin emulator (ItsAMe_Origin.dll).
#
#   ./fifa15-offline.sh check  [/path/to/FIFA 15]    say which version is installed
#   ./fifa15-offline.sh apply  [/path/to/FIFA 15]    patch it (keeps the original next to it)
#   ./fifa15-offline.sh revert [/path/to/FIFA 15]    put the original back
#
# Why: the CPY ItsAMe_Origin.dll tells the game's Origin SDK that Origin is
# installed and running, then makes the SDK's connection to it fail. The SDK
# retries for 30 s and returns an error the game does not treat as "no Origin",
# so the game calls it again, 30 s at a time, forever -- the language screen
# with the frozen flag. Three bytes make the emulator's two registry hooks pass
# through to the real registry: no Origin key, the SDK reports "not installed"
# at once, the game goes offline and carries on. The 60-second black screen at
# start-up goes away too.
#
# Do NOT use this together with Aurora15Connector. The connector installs its
# own ItsAMe_Origin.dll, checks the original's hash, and runs its own Origin
# stand-in for the SDK to connect to. Run  revert  before using it.
#
# Only a file with a known hash is ever changed. Exit codes: 0 done, 1 error,
# 2 usage, 3 the file is not a version this script knows.

set -eu
ORIG_SHA=4463ce725e2af8b858095511801901630355fe1eba66fbb8fc7a5ba3b0f0300b   # CPY original, 25088 bytes
PATCHED_SHA=e6b423c536823be4379681dad8bd9d7334e4db53a394025b86b7af7a8a9cda71 # the same with the three bytes changed

cmd="${1:-}"; dir="${2:-$HOME/Downloads/FIFA 15}"
case "$cmd" in check|apply|revert) ;; *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac
dll="$dir/ItsAMe_Origin.dll"; keep="$dir/ItsAMe_Origin.dll.offline-orig"
[ -f "$dll" ] || { print -r -- "No ItsAMe_Origin.dll in $dir"; exit 1 }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
cur="$(sha "$dll")"
state=other
[ "$cur" = "$ORIG_SHA" ] && state=original
[ "$cur" = "$PATCHED_SHA" ] && state=patched

case "$cmd" in
check)
    case "$state" in
        original) print -r -- "original CPY ItsAMe_Origin.dll -- the game will hang at the language screen; run: $0 apply" ;;
        patched)  print -r -- "offline-patched ItsAMe_Origin.dll -- fine without Aurora15Connector" ;;
        other)    print -r -- "unknown ItsAMe_Origin.dll ($cur) -- probably Aurora15Connector's own; leave it"; exit 3 ;;
    esac ;;
apply)
    case "$state" in
        patched) print -r -- "already patched"; exit 0 ;;
        other) print -r -- "not the CPY original ($cur); refusing to touch it"; exit 3 ;;
    esac
    [ -f "$keep" ] || cp -X "$dll" "$keep"
    tmp="$dll.tmp.$$"; cp -X "$dll" "$tmp"
    printf '\xeb'     | dd of="$tmp" bs=1 seek=$((0x9ed)) conv=notrunc 2>/dev/null   # fake RegOpenKeyExW: jnz -> jmp (always pass through)
    printf '\x90\x90' | dd of="$tmp" bs=1 seek=$((0xa6a)) conv=notrunc 2>/dev/null   # fake RegQueryValueExW: drop the jz (always pass through)
    [ "$(sha "$tmp")" = "$PATCHED_SHA" ] || { rm -f "$tmp"; print -r -- "patch result has the wrong hash; nothing changed"; exit 1 }
    mv -f "$tmp" "$dll"
    print -r -- "patched. Original kept as ${keep:t}" ;;
revert)
    if [ -f "$keep" ] && [ "$(sha "$keep")" = "$ORIG_SHA" ]; then
        cp -X "$keep" "$dll"; print -r -- "original restored from ${keep:t}"
    elif [ "$state" = original ]; then
        print -r -- "already the original"
    else
        print -r -- "no saved original next to it (${keep:t}); cannot revert"; exit 1
    fi ;;
esac
