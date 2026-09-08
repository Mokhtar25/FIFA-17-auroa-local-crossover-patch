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
# Only a verified original is patched. If Aurora replaced the installed DLL,
# use its verified .aurora15.bak (or our .offline-orig) as the source and keep
# the installed DLL separately before replacing it. Exit codes: 0 done, 1 error,
# 2 usage, 3 the file is not a version this script knows.

if [ -z "${ZSH_VERSION:-}" ]; then
    exec /bin/zsh "$0" "$@"
fi
set -eu
ORIG_SHA=4463ce725e2af8b858095511801901630355fe1eba66fbb8fc7a5ba3b0f0300b   # CPY original, 25088 bytes
PATCHED_SHA=e6b423c536823be4379681dad8bd9d7334e4db53a394025b86b7af7a8a9cda71 # the same with the three bytes changed

cmd="${1:-}"; dir="${2:-${FIFA15_DIR:-$HOME/Downloads/FIFA 15}}"
[ "$#" -le 2 ] || { print -r -- "Expected an action and optional game folder."; exit 2; }
case "$cmd" in check|apply|revert) ;; *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac
dll="$dir/ItsAMe_Origin.dll"; keep="$dir/ItsAMe_Origin.dll.offline-orig"
[ -f "$dll" ] || { print -r -- "No ItsAMe_Origin.dll in $dir"; exit 1 }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
cur="$(sha "$dll")"
state=other
[ "$cur" = "$ORIG_SHA" ] && state=original
[ "$cur" = "$PATCHED_SHA" ] && state=patched

# A different installed hash alone cannot identify the DLL. Trust the backup
# only when it matches the exact original this patch was tested against.
source_original=""
for candidate in "$keep" "$dir/ItsAMe_Origin.dll.aurora15.bak"; do
    if [ -f "$candidate" ] && [ "$(sha "$candidate")" = "$ORIG_SHA" ]; then
        source_original="$candidate"
        break
    fi
done
[ "$state" = original ] && source_original="$dll"

require_closed() {
    local rc
    pgrep -if '[f]ifa15[.]exe|[A]urora15Connector|[A]urora15Client' >/dev/null 2>&1 && rc=0 || rc=$?
    case "$rc" in
        1) return 0 ;;
        0) print -r -- "Close FIFA 15 and Aurora15Connector before changing the DLL. Nothing changed." ;;
        *) print -r -- "Cannot check running processes. Close the game and retry from Terminal. Nothing changed." ;;
    esac
    exit 1
}

preserve_installed() {
    local saved="$dll.before-offline-$cur"
    if [ -e "$saved" ]; then
        [ -f "$saved" ] && [ "$(sha "$saved")" = "$cur" ] || {
            print -r -- "Existing backup differs: $saved. Nothing changed."; exit 1
        }
    else
        cp -X "$dll" "$saved"
        [ "$(sha "$saved")" = "$cur" ] || { print -r -- "Backup verification failed. Nothing changed."; exit 1; }
    fi
    print -r -- "Previous DLL kept as ${saved:t}"
}

tmp=""
trap '[ -z "$tmp" ] || rm -f "$tmp"' EXIT

case "$cmd" in
check)
    case "$state" in
        original) print -r -- "original CPY ItsAMe_Origin.dll -- what Aurora15Connector needs; without the connector the game hangs at the language screen (run: $0 apply)" ;;
        patched)
            print -r -- "offline-patched ItsAMe_Origin.dll -- fine without Aurora15Connector"
            if [ -n "$source_original" ]; then
                print -r -- "Verified original backup: ${source_original:t} (revert is available)."
            else
                print -r -- "No verified original backup found; revert is not available."
            fi ;;
        other)
            print -r -- "unrecognized installed ItsAMe_Origin.dll ($cur)"
            if [ -n "$source_original" ]; then
                print -r -- "Verified original found in ${source_original:t}. For direct offline play, run: $0 apply \"$dir\""
            else
                print -r -- "No verified original backup found. This offline patch cannot handle this version."
            fi
            exit 3 ;;
    esac ;;
apply)
    case "$state" in
        patched) print -r -- "already patched"; exit 0 ;;
        other)
            [ -n "$source_original" ] || {
                print -r -- "not the CPY original ($cur), and no verified original backup; refusing to touch it"
                exit 3
            } ;;
    esac
    require_closed
    if [ -e "$keep" ] && { [ ! -f "$keep" ] || [ "$(sha "$keep")" != "$ORIG_SHA" ]; }; then
        print -r -- "Existing ${keep:t} is not the verified original. Nothing changed."
        exit 1
    fi
    tmp="$(mktemp "$dir/.fifa15-offline.XXXXXX")"
    cp -X "$source_original" "$tmp"
    printf '\xeb'     | dd of="$tmp" bs=1 seek=$((0x9ed)) conv=notrunc 2>/dev/null   # fake RegOpenKeyExW: jnz -> jmp (always pass through)
    printf '\x90\x90' | dd of="$tmp" bs=1 seek=$((0xa6a)) conv=notrunc 2>/dev/null   # fake RegQueryValueExW: drop the jz (always pass through)
    [ "$(sha "$tmp")" = "$PATCHED_SHA" ] || { rm -f "$tmp"; print -r -- "patch result has the wrong hash; nothing changed"; exit 1 }
    [ "$(sha "$dll")" = "$cur" ] || { print -r -- "Installed DLL changed while preparing the patch. Retry with the game closed."; exit 1; }
    [ "$state" = original ] || preserve_installed
    [ -f "$keep" ] || cp -X "$source_original" "$keep"
    [ "$(sha "$keep")" = "$ORIG_SHA" ] || { print -r -- "Original backup verification failed; installed DLL unchanged."; exit 1; }
    mv -f "$tmp" "$dll"
    tmp=""
    print -r -- "patched. Original kept as ${keep:t}" ;;
revert)
    if [ "$state" = original ]; then
        print -r -- "already the original"
    elif [ -n "$source_original" ]; then
        require_closed
        preserve_installed
        tmp="$(mktemp "$dir/.fifa15-offline.XXXXXX")"
        cp -X "$source_original" "$tmp"
        [ "$(sha "$tmp")" = "$ORIG_SHA" ] || { print -r -- "Original backup verification failed; installed DLL unchanged."; exit 1; }
        mv -f "$tmp" "$dll"; tmp=""
        print -r -- "original restored from ${source_original:t}"
    else
        print -r -- "no saved original next to it (${keep:t}); cannot revert"; exit 1
    fi ;;
esac
