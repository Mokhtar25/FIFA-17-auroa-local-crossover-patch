#!/bin/zsh
# Installs the FIFA 17 fixes.
#
# By default it does NOT touch your CrossOver. It makes a separate copy called
# CrossOver-FIFA and puts the fixes in that, so your normal CrossOver and every
# other bottle you run in it are left exactly as they are.
#
# Everything it does can be undone by running ./uninstall.sh.
# It never touches the game, and it never downloads anything.
#
#   ./setup.sh [/path/to/CrossOver.app]   install
#   ./setup.sh --resign                   repair the signature, no re-copy
#   ./setup.sh --verify                   check an install, change nothing
#   ./setup.sh --report                   one pasteable diagnosis, change nothing
#   ./setup.sh --unstick                  free bottles stuck loading (kills orphaned
#                                         Wine + wineservers, frees 47170-47173/3216)
#   ./setup.sh --shutdown                 quit CrossOver cleanly first, then --unstick:
#                                         use this instead of closing the window -
#                                         it stops Aurora/FIFA, shuts wineservers
#                                         down, then quits the GUI so no strays
#                                         or held ports are left behind
#   ./setup.sh --agent                    install the background cleanup (LaunchAgent):
#                                         clears strays + held ports by itself every
#                                         30 s, so no script ever needs running
#   ./setup.sh --bundle                   zip up everything a bug report needs
#   ./setup.sh --bottle                   set up a bottle only, no re-copy
#   ./setup.sh --smoke                    watch one PLAY and say pass or fail
#   ./setup.sh --play-offline             start FIFA 17 with no Aurora17 running
#   ./setup.sh --offline-menu             (re)add the FIFA 17 (offline) entry to the
#                                         bottle, e.g. after moving the game folder
#   ./setup.sh --offline                  install FIFA 17 with no Aurora17 at all:
#                                         the CrossOver copy, the fixes and the
#                                         bottle settings only. Kick-off, career
#                                         and the rest of single player; no online,
#                                         no FUT, no EA account. See SETUP.md.
#
# Exit codes:  0 verified   2 unsupported/usage   3 permission
#              4 corrupt payload or wrong CrossOver   5 incomplete install
#              1 is not a designed outcome: it means a stop nobody gave a code
#              to, and is worth reporting as a bug in this script.

set -eu
HERE="${0:A:h}"

E_UNSUPPORTED=2
E_PERMISSION=3
E_PAYLOAD=4
E_INCOMPLETE=5

MODE=install
# --offline: install everything the game itself needs and nothing Aurora17's.
NO_AURORA=0
case "${1:-}" in
    --resign) MODE=resign; shift ;;
    --verify) MODE=verify; shift ;;
    --report) MODE=report; shift ;;
    --unstick) MODE=unstick; shift ;;
    --shutdown) MODE=shutdown; shift ;;
    --agent) MODE=agent; shift ;;
    --bundle) MODE=bundle; shift ;;
    --bottle) MODE=bottle; shift ;;
    --smoke) MODE=smoke; shift ;;
    --offline) MODE=install; NO_AURORA=1; shift ;;
    --play-offline) MODE=play-offline; shift ;;
    --offline-menu) MODE=offline-menu; shift ;;
    --help|-h)
        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    -*) print -r -- "Unknown option: $1  (try: ./setup.sh --help)"; exit $E_UNSUPPORTED ;;
esac

# Colour, only when the output is a terminal. Piped or saved output -- the
# report file, the bundle -- stays plain. NO_COLOR=1 turns it off anywhere.
# Checked on every call, not once: --report runs these inside a pipe to tee.
_paint() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        C_RED=$'\e[1;31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_OFF=$'\e[0m'
    else
        C_RED='' C_GRN='' C_YEL='' C_OFF=''
    fi
}
say()  { print -r -- "$@"; }
ok()   { _paint; print -r -- "  ${C_GRN}ok${C_OFF}    $@"; }
note() { _paint; print -r -- "  ${C_YEL}note${C_OFF}  $@"; }
bad()  { _paint; print -r -- "  ${C_RED}BAD${C_OFF}   $@"; }
red()  { _paint; print -r -- "${C_RED}$@${C_OFF}"; }
green() { _paint; print -r -- "${C_GRN}$@${C_OFF}"; }
# A stop. The first line, in red, says what went wrong; the lines after it say
# what to do about it. Every designed stop goes through die() with one of the
# four codes above. A bare fail() means a path nobody assigned a code to, so
# exit 1 is reserved for exactly that -- an unplanned stop -- and never
# appears in the table.
fail() {
    local msg="$*" first rest
    first="${msg%%$'\n'*}"
    rest="${msg#*$'\n'}"
    _paint
    print -r -- ""
    print -r -- "${C_RED}STOPPED: ${first}${C_OFF}"
    [ "$rest" = "$msg" ] || print -r -- "$rest"
    print -r -- ""
    exit "${EXIT_AS:-1}"
}
die()  { EXIT_AS="$1"; shift; fail "$@"; }

# Two tools from Apple's command line tools are needed to fit the files in.
# Without them /usr/bin/otool and install_name_tool are stubs that fail, and
# the copy would be half made before anything said so.
require_clt() {
    if xcode-select -p >/dev/null 2>&1 && xcrun --find install_name_tool >/dev/null 2>&1; then
        ok "Apple's command line tools are installed"
        return 0
    fi
    die $E_UNSUPPORTED "Apple's command line tools are not installed.
         Two of them are needed to fit the files into CrossOver.
         To fix:
           1. Open Terminal and run:   xcode-select --install
           2. Press Install in the window that opens (a few minutes).
           3. Run this again.
         Nothing has been changed."
}

# One hint for every write that macOS itself can refuse. Since macOS 14 a
# signed app is guarded by App Management, a permission that belongs to the
# program running this script, so the folder looks writable and is not.
APP_MGMT_HINT='         Usually macOS refusing the write. To fix:
           1. System Settings > Privacy & Security > App Management
           2. Switch on Terminal (or whatever you ran this from).
              If it is not listed, use Full Disk Access instead.
           3. Quit that app completely, reopen it, and run this again.'

# The six Wine files the fixes replace.
FILES=(
  x86_64-unix/ntdll.so
  x86_64-unix/winecoreaudio.so
  x86_64-unix/crypt32.so
  x86_64-windows/version.dll
  x86_64-windows/crypt32.dll
  x86_64-windows/secur32.dll
)
# One more file, added rather than replaced, so it is not in FILES: the thing
# that makes name resolution work without touching /etc/hosts. See below.
RESOLVER=x86_64-unix/a17hosts.dylib

# The Mach-O files that have to be signed after we have touched them. The first
# three are ours; a17hosts.dylib is new; ws2_32.so is CrossOver's own, edited in
# place by step 4 and therefore no longer covered by CodeWeavers' signature.
MACHO=( ntdll.so winecoreaudio.so crypt32.so a17hosts.dylib ws2_32.so )

# FIFA 17 talks to EA's servers by name. Aurora17 answers those names locally, so
# they have to resolve to this machine -- otherwise the game reaches the real EA
# hosts, two of which are still up, and fails with a connection error.
#
# Aurora17's launcher already writes those names into the bottle's own hosts
# file, C:\windows\system32\drivers\etc\hosts, on every PLAY and every REPAIR
# SETUP. On Windows that is the file that decides. Under Wine it is not: Wine
# resolves names by calling macOS from lib/wine/x86_64-unix/ws2_32.so, so the
# launcher was writing a file nothing read, reporting success, and leaving
# /etc/hosts -- root-owned, system-wide, and needing a password -- as the only
# thing that actually decided.
#
# a17hosts.dylib closes that. Step 4 points ws2_32.so's libSystem dependency at
# it; it answers getaddrinfo() and gethostbyname() from the bottle's hosts file
# and falls through to the real resolver for every name that file does not
# mention. Per bottle, no password, nothing outside the copy touched, and the
# launcher's existing hosts work finally counts for something.
#
# DYLD_INSERT_LIBRARIES cannot do this job: wineloader is built with the
# hardened runtime and does not carry
# com.apple.security.cs.allow-dyld-environment-variables, so dyld strips it.
LIBSYSTEM=/usr/lib/libSystem.B.dylib
RESOLVER_PATH=@rpath/a17hosts.dylib
AURORA_HOSTS=(
  f17.aurora.test
  gosredirector.ea.com
  easw.easports.com
  content.lt.easfc.ea.com
  pal.gt.easfc.ea.com
  pg.fifa12.test.easportsworld.ea.com
)

# The hosts file inside the bottle -- the one a17hosts.dylib reads, and the one
# Aurora17's launcher maintains. AURORA_HOSTS_FILE overrides it, for testing
# against a throwaway file. (a17hosts.dylib reads AURORA17_HOSTS_FILE for the
# same purpose; the names are deliberately different, so setting one for a test
# here cannot silently redirect the other.)
bottle_hosts_file() {
    if [ -n "${AURORA_HOSTS_FILE:-}" ]; then
        print -r -- "$AURORA_HOSTS_FILE"
    else
        print -r -- "$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/drivers/etc/hosts"
    fi
}

# Which of the names above the bottle's hosts file does not point at this
# machine. Prints one per line.
hosts_missing() {
    local h f; f="$(bottle_hosts_file)"
    for h in $AURORA_HOSTS; do
        grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${h//./\\.}([[:space:]]|\$)" \
            "$f" 2>/dev/null || print -r -- "$h"
    done
}

# ---------------------------------------------- seeding the hosts mappings
# Aurora17's launcher writes the six mappings itself -- but on a bottle where
# they are not already there it does that through what it calls "the elevated
# setup step", a second, Administrator copy of itself. Wine has no UAC, that
# child exits 1, and the launcher stops with
#
#     Aurora17 could not finish: The elevated setup step exited with code 1
#
# before the server is ever started. The game then launches with no session,
# the shim asks the helper for an Origin auth code, is refused, and FIFA quits.
# That is the whole of "the game works but the server does not" on a fresh Mac.
#
# There is nothing to elevate for here: the file is inside the bottle and owned
# by the user. So write it ourselves, byte for byte as Aurora writes it, and
# leave Aurora's own recovery receipt beside it. The launcher then finds the
# mappings already present and receipt-owned, logs
#
#     Verified six receipt-owned hosts mappings 077E26292282.
#
# and never reaches the elevated path at all.
#
# The line format, the CRLF endings and the "# aurora17" tag are Aurora's, not
# ours; they were read back off a working install and must not be changed --
# the launcher matches on the tag when it replaces its own block later.
HOSTS_TAG_RE='[[:space:]]#[[:space:]]*aurora17[[:space:]]*$'

# Aurora keeps its receipts per Windows user. "crossover" is the account every
# CrossOver bottle has; anything else is a bottle somebody made by hand.
bottle_appdata() {
    local u b="$BOTTLE_DIR/$BOTTLE/drive_c/users"
    if [ -d "$b/crossover" ]; then
        print -r -- "$b/crossover/AppData/Local/Aurora17"; return 0
    fi
    for u in "$b"/*(N/); do
        case "${u:t}" in Public) continue ;; esac
        print -r -- "$u/AppData/Local/Aurora17"; return 0
    done
    return 1
}

hosts_receipt_file() {
    local a; a="$(bottle_appdata)" || return 1
    print -r -- "$a/ShimReceipts/hosts-mapping.json"
}

# Everything in the file that is not one of Aurora's tagged lines, with CRLF
# endings -- which is exactly what Aurora calls the preimage and what it puts
# back if its block is ever removed.
hosts_preimage() {
    local f="$1" line
    [ -f "$f" ] || return 0
    /usr/bin/sed -e 's/\r$//' "$f" | /usr/bin/grep -v -E "$HOSTS_TAG_RE" || true
}

# Writes the file and the receipt. Prints one ok/note line. Returns non-zero
# only if it could not write, which is a real failure: without these mappings
# the game reaches EA.
seed_bottle_hosts() {
    local f; f="$(bottle_hosts_file)"
    local dir="${f:h}"
    if [ ! -d "$BOTTLE_DIR/$BOTTLE" ]; then
        note "no bottle to seed the hosts file in"
        return 0
    fi
    mkdir -p "$dir" 2>/dev/null || { bad "could not create $dir"; return 1 }

    # Two files: what the hosts file will become, and the preimage the receipt
    # has to record. Both are built from the same read, so they cannot disagree.
    local tmp="$dir/.hosts.aurora17.$$"
    local pretmp="$dir/.hosts-pre.aurora17.$$"
    local pre line h
    pre="$(hosts_preimage "$f")"
    : > "$pretmp" || { bad "could not write in $dir"; return 1 }
    if [ -n "$pre" ]; then
        print -r -- "$pre" | while IFS= read -r line; do printf '%s\r\n' "$line" >> "$pretmp"; done
    fi
    cp "$pretmp" "$tmp"
    for h in $AURORA_HOSTS; do printf '127.0.0.1 %s # aurora17\r\n' "$h" >> "$tmp"; done

    if [ -f "$f" ] && cmp -s "$tmp" "$f"; then
        rm -f "$tmp"
        ok "the bottle's hosts file already has all ${#AURORA_HOSTS} mappings"
    else
        # Keep whatever was there once, so uninstall has something to put back.
        if [ -f "$f" ] && [ ! -f "$f.bak-aurora17" ]; then
            cp "$f" "$f.bak-aurora17" || true
        fi
        if ! mv "$tmp" "$f"; then
            rm -f "$tmp" "$pretmp"
            bad "could not write $f"
            return 1
        fi
        ok "wrote the ${#AURORA_HOSTS} EA mappings into the bottle's hosts file"
    fi

    # The receipt. Aurora writes one itself after its own run; writing it here
    # is what stops it wanting to elevate on the first PLAY. An Aurora-written
    # one is never touched -- it may record a preimage we never saw.
    local rcpt
    if ! rcpt="$(hosts_receipt_file)"; then
        rm -f "$pretmp"
        note "no Windows user folder in the bottle yet — receipt not written"
        return 0
    fi
    if [ -f "$rcpt" ]; then
        rm -f "$pretmp"
        ok "Aurora17 already has its own hosts receipt — left alone"
        return 0
    fi
    if ! mkdir -p "${rcpt:h}" 2>/dev/null; then
        rm -f "$pretmp"
        note "could not create ${rcpt:h}"
        return 0
    fi

    local plen clen psha csha pb64 i
    plen=$(wc -c < "$pretmp" | tr -d ' ')
    clen=$(wc -c < "$f" | tr -d ' ')
    psha=$(shasum -a 256 "$pretmp" | cut -d' ' -f1 | tr 'a-f' 'A-F')
    csha=$(shasum -a 256 "$f"      | cut -d' ' -f1 | tr 'a-f' 'A-F')
    pb64=$(base64 < "$pretmp" | tr -d '\n')
    rm -f "$pretmp"
    # Byte-for-byte in the shape Aurora writes it: CRLF, and no newline after
    # the closing brace. It parses either way; matching it costs nothing and
    # means a receipt of ours is indistinguishable from one of its own.
    local -a j
    j=(
        '{'
        '  "schemaVersion": 2,'
        '  "hostsPath": "C:\\windows\\system32\\drivers\\etc\\hosts",'
        '  "mapping": null,'
        '  "mappings": ['
    )
    i=1
    for h in $AURORA_HOSTS; do
        if [ "$i" -eq "${#AURORA_HOSTS}" ]; then
            j+=( "    \"127.0.0.1 $h # aurora17\"" )
        else
            j+=( "    \"127.0.0.1 $h # aurora17\"," )
        fi
        i=$((i+1))
    done
    j+=(
        '  ],'
        "  \"preimageLength\": $plen,"
        "  \"preimageSha256\": \"$psha\","
        "  \"preimageBase64\": \"$pb64\","
        "  \"currentLength\": $clen,"
        "  \"currentSha256\": \"$csha\","
        "  \"installedAtUtc\": \"$(date -u '+%Y-%m-%dT%H:%M:%S.000000+00:00')\""
    )
    {
        for line in $j; do printf '%s\r\n' "$line"; done
        printf '}'
    } > "$rcpt" || { note "could not write $rcpt"; return 0 }
    ok "wrote Aurora17's hosts receipt, so PLAY never asks to elevate"
    return 0
}

# Is ws2_32.so reading the bottle's hosts file, or still the system resolver?
ws2_32_is_patched() {
    otool -L "$1/x86_64-unix/ws2_32.so" 2>/dev/null | grep -q "$RESOLVER_PATH"
}

# Written after a successful install so uninstall knows exactly what to undo,
# rather than guessing from a list of default locations. Guessing is what made
# an earlier uninstaller delete a file out of a folder nobody had named.
# AURORA_RECEIPT_DIR exists so a test install against a throwaway tree can keep
# its own receipt. Without it such a test writes over the receipt for the real
# install, which then points uninstall.sh at a scratch directory that is about
# to be deleted.
RECEIPT_DIR="${AURORA_RECEIPT_DIR:-$HOME/Library/Application Support/Aurora17}"
RECEIPT="$RECEIPT_DIR/install-receipt.conf"

# ---------------------------------------------------------------- discovery
# An explicit path always wins; otherwise the two standard locations. Spotlight
# is deliberately not consulted: it happily returns the FIFA copy, a mounted
# disk image, or any other bundle carrying CrossOver's identifier, and this
# path ends up on the wrong side of a "rm -rf".
find_crossover() {
    [ -n "${1:-}" ] && { print -r -- "${1:A}"; return; }
    local d
    for d in /Applications/CrossOver.app "$HOME/Applications/CrossOver.app"; do
        [ -d "$d" ] && { print -r -- "$d"; return; }
    done
    print -r -- "/Applications/CrossOver.app"
}
SRC="$(find_crossover "${1:-}")"

IN_PLACE="${AURORA_IN_PLACE:-0}"

# Whether the caller named the target themselves matters: an explicit path that
# turns out to be wrong must stop, never quietly become a different path that
# then gets deleted.
if [ -n "${AURORA_TARGET:-}" ]; then
    TARGET="${AURORA_TARGET:A}"
    TARGET_EXPLICIT=1
else
    TARGET="/Applications/CrossOver-FIFA.app"
    TARGET_EXPLICIT=0
fi
[ "$IN_PLACE" = "1" ] && { TARGET="$SRC"; TARGET_EXPLICIT=1; }

BOTTLE_DIR="${CX_BOTTLE_PATH:-$HOME/Library/Application Support/CrossOver/Bottles}"
BOTTLE="${AURORA_BOTTLE:-Aurora17}"

# --------------------------------------------------------- safety guards
# Everything below eventually reaches "rm -rf $TARGET" or "ditto ... $TARGET".
# An unset variable falls back to the safe default, but an explicitly supplied
# one is taken at its word, so it has to be checked rather than trusted.
assert_safe_target() {
    local t="$1"
    case "$t" in
        /*) ;;
        *) die $E_UNSUPPORTED "Refusing a target that is not an absolute path: $t
         AURORA_TARGET must start with /, for example
         AURORA_TARGET=/Applications/CrossOver-FIFA.app" ;;
    esac
    case "$t" in
        *.app) ;;
        *) die $E_UNSUPPORTED "Refusing a target that is not an .app bundle: $t
         AURORA_TARGET must name the application to create, for example
         AURORA_TARGET=/Applications/CrossOver-FIFA.app" ;;
    esac
    case "${t:A}" in
        / | /Applications | /Users | /System | /Library | "$HOME" | "$HOME/Applications")
            die $E_UNSUPPORTED "Refusing to use $t as the target.
         AURORA_TARGET must name a new app inside a folder, for example
         AURORA_TARGET=/Applications/CrossOver-FIFA.app" ;;
    esac
    [ "${#t}" -gt 5 ] || die $E_UNSUPPORTED "Refusing a suspiciously short target: $t
         AURORA_TARGET must name a new app inside a folder, for example
         AURORA_TARGET=/Applications/CrossOver-FIFA.app"
}

# Deleting a directory only because it sits at the expected path is how you
# destroy somebody's unrelated application. Require it to be CrossOver.
is_crossover_bundle() {
    local id
    id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
             "$1/Contents/Info.plist" 2>/dev/null) || return 1
    [ "$id" = "com.codeweavers.CrossOver" ]
}

crossover_version() {
    /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
        "$1/Contents/Info.plist" 2>/dev/null || print -r -- "unknown"
}

# pgrep -f takes a regular expression, and a path can contain characters that
# mean something to one.
pgrep_quote() { print -r -- "$1" | sed 's/[][^$.*+?(){}|\\\/]/\\&/g'; }

app_is_running() {
    local pat
    pat=$(pgrep_quote "$1/Contents/MacOS")
    pgrep -f "$pat" >/dev/null 2>&1
}

# --------------------------------------------- who is holding the bottle
# Wine keeps the registry in memory and writes user.reg back out when the last
# process in a prefix exits. Editing that file while a bottle is live is
# therefore not a change at all: when CrossOver is finally quit it puts its own
# copy back, taking the version override with it, and the game says the servers
# have been shut down again -- with every check in --verify still saying ok,
# because they read the file that is about to be overwritten.
#
# The same question has a second answer. When a bottle's wineserver dies but
# its services.exe, explorer.exe and rpcss.exe do not, those stay behind
# reparented to init, still holding a lock directory under /tmp that nothing
# will ever release. The next attempt to open that bottle waits on a wineserver
# that is not there, forever, and CrossOver simply spins. That is what "the
# bottle is stuck loading" is, and it survives quitting and reopening CrossOver
# because the processes it is waiting on are no longer CrossOver's children.
#
# Both come down to: is anything in this prefix right now, and does anything
# own it. --unstick answers the second one.
prefix_holders() {
    local pfx="$BOTTLE_DIR/$BOTTLE"
    [ -d "$pfx" ] || return 0
    # Every Wine process in a bottle has its working directory inside it.
    /usr/sbin/lsof -a -d cwd -F pn 2>/dev/null | awk -v pfx="$pfx" '
        substr($0,1,1)=="p" { pid=substr($0,2); next }
        substr($0,1,1)=="n" {
            path=substr($0,2)
            if (path==pfx || index(path, pfx "/")==1) print pid
        }'
}

# Every open CrossOver application, one bundle path per line. Only the
# application itself counts, and its binary is the one under Contents/MacOS.
#
# Trimming at /Contents/ instead -- which is what this did until 2026-09-02 --
# also matched CrossOver's own wineserver and winewrapper.exe, which live under
# Contents/SharedSupport of the same bundle. Those are exactly the leftovers
# --unstick exists to remove, so once the application had quit and only they
# were left, --unstick answered "CrossOver is still open" and refused to run in
# the one state it is for. Trimming at /Contents/MacOS/ drops them, and every
# other match -- shells, editors, anything with the word on its command line --
# still fails to end in .app, which is the filter it always was.
#
# The bundle identifier decides, not the binary's name: a renamed copy such as
# CrossOver-FIFA.app is still found, and a menu shim in ~/Applications/CrossOver
# -- an .app whose path contains the word but which is not CrossOver -- is not
# mistaken for one.
crossovers_running() {
    local app
    ps -Ao command= 2>/dev/null | grep -i crossover | grep -v grep \
        | sed -n 's|/Contents/MacOS/.*||p' | grep -E '^/.*\.app$' | sort -u \
    | while IFS= read -r app; do
        is_crossover_bundle "$app" && print -r -- "$app"
    done
    # The loop's status is the last bundle test, which says nothing about
    # whether this worked. Callers assign it under set -e.
    return 0
}

# Wine names these directories after the prefix's device and inode, not after
# the bottle, so there is no reading the name to find out whose it is. The only
# safe test is whether any process still has one open.
stale_wine_sockets() {
    local d
    for d in /tmp/.wine-*/server-*(N/); do
        is_our_server_dir "$d" || continue
        [ -n "$(/usr/sbin/lsof +D "$d" -F p 2>/dev/null | grep '^p')" ] \
            || print -r -- "$d"
    done
}

# --unstick's view. The bottle named by AURORA_BOTTLE is not the only one that
# can be stuck: CrossOver's own window waits on every bottle it lists, so an
# orphan in *any* bottle leaves *every* bottle spinning -- and until 2026-09-02
# --unstick looked at one bottle, said "nothing was holding the bottle", and the
# spinner stayed. Two kinds of leftover, one rule:
#
#   * Wine processes whose working directory is inside any bottle under
#     BOTTLE_DIR (services.exe, explorer.exe, rpcss.exe and friends).
#   * Wine processes whose working directory is somewhere else entirely but
#     which still hold a server-* directory under /tmp -- the conhost.exe that
#     Aurora's server leaves behind sits in ~/Downloads, not in the bottle, and
#     stale_wine_sockets() cannot remove a directory it has open.
#
# Only Wine's own processes count: a Windows binary (its command line starts
# with a drive letter), wineserver, winewrapper.exe or a preloader. A Terminal
# tab that happens to be cd'ed into a bottle is not a holder and is never
# signalled. While a CrossOver GUI is running, anything attached to a
# server-* directory that a wineserver still holds is a live session and is
# left alone. Once every GUI has quit there is no live session left: an
# orphaned wineserver keeps its clients looking "live" forever, holding
# ports 47170-47173/3216 and the bottle lock, so --unstick shuts the
# wineservers down first and then treats the rest as orphans. A native Mac
# program on one of the ports is still never signalled.
is_wine_command() {
    case "$1" in
        [A-Za-z]:\\*) return 0 ;;
        *wineserver*|*winewrapper.exe*|*wine-preloader*|*wine64-preloader*) return 0 ;;
    esac
    return 1
}

# Wine names a prefix's server directory after the prefix's device and inode
# in hex -- /tmp/.wine-<uid>/server-<dev>-<inode> -- so the bottles under
# BOTTLE_DIR can be turned into the exact set of directory names that belong
# to them. Everything else under /tmp/.wine-* is another Wine runtime's
# (Whisky, Wineskin, a plain wine), and "no CrossOver is open" says nothing
# about whether one of those is in the middle of a session. Those are never
# signalled and their directories are never removed.
our_server_dirs() {
    local b st
    for b in "$BOTTLE_DIR"/*(N/); do
        st="$(stat -f '%d %i' "$b" 2>/dev/null)" || continue
        [ -n "$st" ] || continue
        printf 'server-%x-%x\n' ${=st}
    done
    return 0
}
is_our_server_dir() {
    [ -n "${OUR_SERVER_DIRS:-}" ] || OUR_SERVER_DIRS="$(our_server_dirs)"
    print -r -- "$OUR_SERVER_DIRS" | grep -qx -- "${1:t}"
}

# A name match alone is not proof of ownership: a native Mac program with
# fifa17 or Aurora17Server on its command line -- a video open in QuickTime,
# an editor on a log -- must never be signalled, and the background cleanup
# signals these with nobody watching. A pid counts only if it is a Wine
# process, works inside a bottle, or holds one of our server directories.
wine_owned_pid() {
    local cmd cwd h
    cmd="$(ps -o command= -p "$1" 2>/dev/null)" || return 1
    [ -n "$cmd" ] || return 1
    is_wine_command "$cmd" && return 0
    cwd="$(/usr/sbin/lsof -a -d cwd -p "$1" -F n 2>/dev/null | sed -n 's/^n//p' | head -1)"
    [ "$cwd" = "$BOTTLE_DIR" ] || [ "${cwd#"$BOTTLE_DIR"/}" != "$cwd" ] && return 0
    for h in ${(f)"$(/usr/sbin/lsof -p "$1" -F n 2>/dev/null \
            | sed -n 's|^n.*/\.wine-[^/]*/\(server-[^/]*\)/.*|\1|p' | sort -u)"}; do
        [ -n "$h" ] && is_our_server_dir "$h" && return 0
    done
    return 1
}

live_server_dirs() {
    local d
    for d in /tmp/.wine-*/server-*(N/); do
        /usr/sbin/lsof +D "$d" -F c 2>/dev/null | grep -q '^cwineserver' \
            && print -r -- "${d%/}"
    done
    return 0
}

# Prints "pid<TAB>state<TAB>command" for every Wine process found anywhere, with
# state being "orphan" or "live".
wine_leftovers() {
    local live pid ppid cmd cwd held h state; local -a ours
    live="$(live_server_dirs)"
    ps -Ao pid=,ppid=,command= 2>/dev/null | while read -r pid ppid cmd; do
        is_wine_command "$cmd" || continue
        cwd="$(/usr/sbin/lsof -a -d cwd -p "$pid" -F n 2>/dev/null | sed -n 's/^n//p' | head -1)"
        # lsof reports /private/tmp where the glob above says /tmp, so the
        # server-* directory name is what gets compared, never the full path.
        held="$(/usr/sbin/lsof -p "$pid" -F n 2>/dev/null \
                | sed -n 's|^n.*/\.wine-[^/]*/\(server-[^/]*\)/.*|\1|p' | sort -u)"
        ours=()
        for h in ${(f)held}; do
            [ -n "$h" ] && is_our_server_dir "$h" && ours+=( "$h" )
        done
        held="${(F)ours}"
        # Inside a bottle, or holding a server directory -- otherwise not ours.
        if [ "$cwd" != "$BOTTLE_DIR" ] && [ "${cwd#"$BOTTLE_DIR"/}" = "$cwd" ] && [ -z "$held" ]; then
            continue
        fi
        state=orphan
        for h in ${(f)held}; do
            [ -n "$h" ] && [ "${live}" != "${live#*"/$h"}" ] && state=live
        done
        print -r -- "${pid}"$'\t'"${state}"$'\t'"${cmd}"
    done
    return 0
}

# The games and Aurora programs, by name: fifa17/15.exe,
# Aurora17/15 Connector/Client/Server/Launcher. A Wine process shows its
# Windows command line to ps, so the name is on it -- including the
# winewrapper.exe lines that start a connector from a .lnk (those contain no
# .exe, only "Aurora15Connector-2.lnk", so matching .exe alone misses the
# wrapper and leaves a PPID-1 stray behind).
game_leftovers() {
    local p
    for p in ${(f)"$(ps -Ao pid=,command= 2>/dev/null \
        | grep -Ei '(fifa1[57]|Aurora1[57](Connector|Client|Server|Launcher))' \
        | grep -v grep | grep -v 'setup\.sh' | awk '{print $1}')"}; do
        [ -n "$p" ] || continue
        wine_owned_pid "$p" && print -r -- "$p"
    done
    return 0
}

# Every wineserver process, by path. The binary lives at
# <app>/Contents/SharedSupport/CrossOver/bin/wineserver under every copy name
# (CrossOver, CrossOver-FIFA, CrossOver-FIFA15...), so match the path, not
# the copy name.
wineserver_pids() {
    ps -Ao pid=,command= 2>/dev/null \
        | grep -F 'SharedSupport/CrossOver' | grep -w 'wineserver' \
        | grep -v grep | awk '{print $1}'
    return 0
}

# Ask every GUI to quit via Apple Events, then wait for it to go. Returns 0
# when none is left, 1 when something is still alive (hung, needs Force Quit).
quit_crossovers_gui() {
    local waited=0 left
    [ -z "$(crossovers_running)" ] && return 0
    osascript -e 'tell application "System Events" to set cl to name of every process whose background only is false' 2>/dev/null | tr ',' '\n' \
        | grep -i '^ *crossover' | while IFS= read -r app; do
            app="$(print -r -- "$app" | sed 's/^ *//;s/ *$//')"
            [ -n "$app" ] && osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1 &
        done || true
    while [ "$waited" -lt 15 ]; do
        left="$(crossovers_running)"
        [ -z "$left" ] && return 0
        /bin/sleep 1
        waited=$((waited + 1))
    done
    [ -z "$(crossovers_running)" ]
}

# Clean per-bottle shutdown: ask each bottle's wineserver to exit (it ends its
# clients, flushes user.reg, releases its server-* dir and its ports), then
# fall back to signals for stragglers. Tries the TARGET copy's wineserver,
# the source copy's, and the binary of whatever wineserver is actually
# running, so it works whichever copy owns the session. Never touches a
# native Mac process.
shutdown_wineservers() {
    local app ws tried="" b waited; local -a left
    # -k against an idle bottle starts a wineserver just to kill it, leaving
    # a fresh stale server-* dir behind -- so do nothing when none runs.
    [ -n "$(wineserver_pids)" ] || [ -n "$(live_server_dirs)" ] || return 0
    for app in "$TARGET" "$SRC" /Applications/CrossOver-FIFA.app /Applications/CrossOver.app "$HOME/Applications/CrossOver-FIFA.app"; do
        [ -n "$app" ] || continue
        ws="$app/Contents/SharedSupport/CrossOver/bin/wineserver"
        case "$tried" in *"|$ws|"*) continue ;; esac
        tried="$tried|$ws|"
        [ -x "$ws" ] || continue
        for b in "$BOTTLE_DIR"/*/; do
            [ -d "$b" ] || continue
            WINEPREFIX="${b%/}" "$ws" -k 2>/dev/null || true
        done
    done
    waited=0
    # zsh does not split a scalar on whitespace, so the pid list has to be an
    # array: kill would otherwise be handed "111\n222" as one argument and
    # signal nothing at all, and the escalation below would never happen.
    while [ "$waited" -lt 10 ]; do
        left=( ${(f)"$(wineserver_pids)"} ); left=( ${left:#} )
        [ "${#left}" -eq 0 ] && return 0
        [ "$waited" -eq 3 ] && kill -TERM ${left} 2>/dev/null || true
        /bin/sleep 1
        waited=$((waited + 1))
    done
    left=( ${(f)"$(wineserver_pids)"} ); left=( ${left:#} )
    [ "${#left}" -eq 0 ] && return 0
    kill -KILL ${left} 2>/dev/null || true
    /bin/sleep 1
    return 0
}
# ------------------------------------------------------------- signing
# We can only sign ad-hoc -- we are not CodeWeavers and cannot use their
# certificate. That matters more than it sounds. CrossOver is built with the
# hardened runtime, which turns on *library validation*: every library the
# process loads must carry the same Team ID as the process itself. Sign the app
# ad-hoc and its Team ID becomes empty, while the frameworks inside it still
# carry CodeWeavers' -- so the app dies at launch before showing a window:
#
#   Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
#   Reason: mapping process and mapped file have different Team IDs
#
# Adding com.apple.security.cs.disable-library-validation is what allows the
# mixture. The alternative, --deep, would re-sign a gigabyte of nested code to
# fix a rule we can simply switch off.
LIBVAL_KEY="com.apple.security.cs.disable-library-validation"

# LC_UUID identifies a Mach-O file across an added rpath and a re-signing,
# both of which change its bytes.
#
# Match the "uuid" line itself. Matching LC_UUID and taking the next line reads
# "cmdsize 24" instead, which is 24 for every Mach-O ever built -- so every file
# compared equal to every other one and --verify said "ok" to a stock CrossOver.
macho_uuid() {
    otool -l "$1" 2>/dev/null | awk '$1 == "uuid" { print $2; exit }'
}

# Does this Mach-O already carry the lib64 rpath?
#
# Read from the LC_RPATH entries only. Grepping the whole otool dump for
# "lib64" also matches ordinary library paths, and -- worse -- an otool that
# cannot run at all answers "no" for a file that plainly has the rpath. Adding
# it a second time is what produces:
#
#   "would duplicate path, file already has LC_RPATH for: ..."
#   "changing install names or rpaths can't be redone ... must be relinked"
#
# So if otool produces nothing usable, fall back to searching the file itself
# rather than assuming the rpath is absent.
RPATH_LIB64='@loader_path/../../../lib64'
has_lib64_rpath() {
    local out
    out="$(otool -l "$1" 2>/dev/null)" || out=""
    if [ -n "$out" ]; then
        print -r -- "$out" \
            | awk '/^ *cmd LC_RPATH$/{r=1;next} r&&/^ *path /{print $2;r=0}' \
            | grep -Fqx "$RPATH_LIB64" && return 0
        # otool worked and the rpath is not there.
        print -r -- "$out" | grep -q 'cmd LC_' && return 1
    fi
    # otool is unusable on this machine. The rpath, if present, is still a
    # literal string inside the file.
    LC_ALL=C grep -Fq "$RPATH_LIB64" "$1"
}

# Reads a bundle's entitlements into $2 as an XML plist.
#   0  read them
#   2  the bundle is signed but genuinely carries none
#   1  codesign itself failed; the reason is left in CODESIGN_ERR
#
# Two spellings, because they are not the same on every macOS: older codesign
# writes the plist to the named file, newer builds only write it to stdout.
# Guessing wrong looks exactly like "this app has no permissions", which is the
# one answer that must never be assumed.
CODESIGN_ERR=""
read_entitlements() {
    local app="$1" out="$2"
    CODESIGN_ERR=""

    if CODESIGN_ERR="$(codesign -d --entitlements "$out" --xml "$app" 2>&1)" \
       && [ -s "$out" ]; then
        CODESIGN_ERR=""
        return 0
    fi

    rm -f "$out"
    if codesign -d --entitlements - --xml "$app" >"$out" 2>/dev/null \
       && [ -s "$out" ]; then
        CODESIGN_ERR=""
        return 0
    fi

    rm -f "$out"
    codesign -dv "$app" >/dev/null 2>&1 || {
        CODESIGN_ERR="${CODESIGN_ERR:-$app has no code signature at all.}"
        return 1
    }
    return 2
}

# The four permissions a genuine CrossOver 26.3 ships with. Kept here so a
# CrossOver whose own copy cannot be read -- because its signature was replaced
# by a patcher, a repack, or an earlier hand-signing -- can still be signed with
# the right set instead of silently losing microphone, camera and Apple Events.
# Read back and verified after signing exactly like a set we read off the app.
STOCK_ENTITLEMENTS=(
  com.apple.security.automation.apple-events
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.device.audio-input
  com.apple.security.device.camera
)

write_stock_entitlements() {
    local out="$1" k
    {
        print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
        print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        print -r -- '<plist version="1.0"><dict>'
        for k in $STOCK_ENTITLEMENTS; do
            print -r -- "<key>$k</key><true/>"
        done
        print -r -- '</dict></plist>'
    } > "$out" || return 1
    [ -s "$out" ]
}

# Why the app could not tell us, in one line, for the note that follows.
ent_reason() {
    case "$1" in
        2) print -r -- "it carries none of its own" ;;
        *) print -r -- "codesign said: ${CODESIGN_ERR:-nothing at all}" ;;
    esac
}

# ---------------------------------------------------- the version override
# Wine implements version.dll itself, and by default loads its own. Aurora's
# redirect shim IS a version.dll -- a proxy dropped next to FIFA17.exe that
# re-exports all 17 entries and forwards them on. With the default load order
# that file is never opened at all: no shim, no redirect, and the game reaches
# EA's real servers, which are dead. The only thing the player sees is "servers
# have been shut down", and every other check passes.
#
# The value is not a CrossOver default -- it is in no bottle template -- so
# nothing puts it there but this.
OVERRIDE_SECTION='[Software\\Wine\\DllOverrides]'
OVERRIDE_LINE='"version"="native,builtin"'

bottle_user_reg()   { print -r -- "$BOTTLE_DIR/$BOTTLE/user.reg"; }
bottle_system_reg() { print -r -- "$BOTTLE_DIR/$BOTTLE/system.reg"; }

# Is LINE there, exactly, under SECTION in the registry file REG?
# awk, not grep: the same value name turns up under other keys in the same file
# -- "version"= does, under application keys -- and setting one of those would
# do nothing while looking right. The section and line go in through the
# environment, not -v: awk -v unescapes backslashes, and every key in this file
# is full of them.
reg_line_is_set() {
    local reg="$1"
    [ -f "$reg" ] || return 1
    A17_SEC="$2" A17_LINE="$3" awk '
        substr($0,1,1)=="[" { insec = (index($0, ENVIRON["A17_SEC"])==1); next }
        insec && index($0, ENVIRON["A17_LINE"])==1 { found=1 }
        END { exit !found }
    ' "$reg"
}

# Writes LINE under SECTION in REG, in place of any other value of that NAME
# there, keeping a backup as <file>.bak-aurora17. NAME is the quoted value name,
# e.g. '"version"'. Returns non-zero if it could not be made to stick.
#
# A value Wine wrote itself can be wrapped over several lines -- fifteen bytes
# to a line, each continued one ending in a backslash -- so dropping the old
# value means dropping its continuation lines too. Leaving them behind would
# leave half a hex blob loose in the section.
set_reg_line() {
    local reg="$1" sec="$2" line="$3" name="$4" tmp
    [ -f "$reg" ] || return 1
    reg_line_is_set "$reg" "$sec" "$line" && return 0
    cp -X "$reg" "$reg.bak-aurora17" 2>/dev/null || cp "$reg" "$reg.bak-aurora17" || return 1
    tmp="$(mktemp -t a17reg)" || return 1
    if grep -qF "$sec" "$reg"; then
        A17_SEC="$sec" A17_LINE="$line" A17_NAME="$name=" awk '
            substr($0,1,1)=="[" {
                dropping = 0
                if (insec && !wrote) { print ENVIRON["A17_LINE"]; wrote=1 }
                insec = (index($0, ENVIRON["A17_SEC"])==1)
                print; next
            }
            dropping && substr($0,1,1)!="[" {
                if (substr($0, length($0), 1) != "\\") dropping = 0
                next
            }
            insec && index($0, ENVIRON["A17_NAME"])==1 {
                if (substr($0, length($0), 1) == "\\") dropping = 1
                next
            }
            { print }
            END { if (insec && !wrote) print ENVIRON["A17_LINE"] }
        ' "$reg" > "$tmp" || { rm -f "$tmp"; return 1 }
    else
        # No such section yet. Wine merges a repeated one, so appending is safe.
        { cat "$reg"
          print -r -- ""
          print -r -- "$sec 0"
          print -r -- "$line"
        } > "$tmp" || { rm -f "$tmp"; return 1 }
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1 }
    cat "$tmp" > "$reg" || { rm -f "$tmp"; return 1 }
    rm -f "$tmp"
    reg_line_is_set "$reg" "$sec" "$line"
}

version_override_is_set() { reg_line_is_set "$(bottle_user_reg)" "$OVERRIDE_SECTION" "$OVERRIDE_LINE"; }
set_version_override()    { set_reg_line "$(bottle_user_reg)" "$OVERRIDE_SECTION" "$OVERRIDE_LINE" '"version"'; }

# ------------------------------------------------- the controller (BUGS.md §20)
# On a Mac, CrossOver's winebus offers a game controller to the bottle two ways
# at once: raw, as the HID device itself ("hidraw"), and through SDL, which
# recognises the pad and presents it as an Xbox-style controller. FIFA 17 takes
# the raw one. A DualShock 4's raw report numbers its buttons in Sony's order
# and the game reads them in Microsoft's, so Cross registers as Circle and R1
# as R2: every button works, and most of them do the wrong thing. Turning the
# raw path off leaves the SDL pad, which the game reads correctly. The value is
# winebus's own (it is in the driver's strings), and a bottle on this machine
# that already carried it showed the same controller as an XInput pad
# (Enum\HID\VID_054C&PID_09CC&IG_00) where this bottle showed it raw. It lives
# in system.reg, not user.reg, and is not in the template a new bottle gets.
WINEBUS_SECTION='[System\\CurrentControlSet\\Services\\winebus]'
WINEBUS_LINE='"DisableHidraw"=dword:00000001'
hidraw_is_disabled() { reg_line_is_set "$(bottle_system_reg)" "$WINEBUS_SECTION" "$WINEBUS_LINE"; }
disable_hidraw()     { set_reg_line "$(bottle_system_reg)" "$WINEBUS_SECTION" "$WINEBUS_LINE" '"DisableHidraw"'; }

# ------------------------------------- proxy auto-detect (BUGS.md §21)
# Wine's winhttp tells every program in the bottle that "Automatically detect
# settings" is ticked whenever the bottle has no DefaultConnectionSettings value
# of its own -- and a new bottle never has one. .NET believes it, so the first
# web request a fresh .NET process makes goes looking for a proxy first, even
# for an address on this Mac. Wine looks one up by resolving wpad.<the bottle's
# DNS domain>, and gives that name five seconds. On a network where the lookup
# does not fail fast, every fresh .NET process loses those five seconds before
# it says anything at all.
#
# Aurora's helper is one of those processes, and the redirect shim gives it
# exactly five seconds to hand back an Origin auth code. So the shim gives up
# first, every time: origin-auth-code-refused, the helper exits, the socket the
# game thinks is Origin drops, and the game puts up a box saying "FIFA 17 is
# shutting down because the Origin client was terminated". Nothing else is
# wrong, and every other check passes.
#
# Everything Aurora talks to is on this Mac, at 127.0.0.1, so no proxy is ever
# wanted in this bottle. The value below is exactly what Windows writes when you
# untick that box: 56 bytes -- the magic 0x46, a zero, the flags (1, meaning go
# direct, with the auto-detect bit 0x08 clear), three empty strings for the
# proxy, the bypass list and the PAC url, and padding Wine never reads.
PROXY_SECTION='[Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\\Connections]'
PROXY_LINE='"DefaultConnectionSettings"=hex:46,00,00,00,00,00,00,00,01,00,00,00'
PROXY_LINE+=',00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00'
PROXY_LINE+=',00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00'
PROXY_LINE+=',00,00,00,00'

# Is auto-detect off? This cannot use reg_line_is_set: that matches one line, and
# once Wine has saved the registry itself the value comes back wrapped over four
# lines. So join the continuation lines first (a line ending in a backslash
# continues on the next one), then read the two bytes that decide it: the magic
# must be 0x46, and bit 0x08 of the flags -- auto-detect -- must be clear.
# Anything else at all, including no value and a magic we do not recognise,
# counts as not off.
proxy_autodetect_is_off() {
    local reg="$(bottle_user_reg)"
    [ -f "$reg" ] || return 1
    A17_SEC="$PROXY_SECTION" A17_NAME='"DefaultConnectionSettings"=hex:' awk '
        function hex(t,   i, c, d, v) {
            gsub(/[ \t\\]/, "", t)
            t = tolower(t)
            if (t == "") return -1
            v = 0
            for (i = 1; i <= length(t); i++) {
                d = index("0123456789abcdef", substr(t, i, 1)) - 1
                if (d < 0) return -1
                v = v * 16 + d
            }
            return v
        }
        BEGIN { name = ENVIRON["A17_NAME"]; nl = length(name) }
        substr($0,1,1)=="[" { insec = (index($0, ENVIRON["A17_SEC"])==1); cont = 0; next }
        cont {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (substr(line, length(line), 1) == "\\") line = substr(line, 1, length(line)-1)
            else { cont = 0; done = 1 }
            val = val line
            next
        }
        insec && !done && index($0, name)==1 {
            val = substr($0, nl+1)
            if (substr(val, length(val), 1) == "\\") { val = substr(val, 1, length(val)-1); cont = 1 }
            else done = 1
            next
        }
        END {
            if (!done) exit 1
            n = split(val, b, ",")
            if (n < 12) exit 1
            if (hex(b[1]) != 70) exit 1          # the magic, 0x46
            f = hex(b[9])                        # the low byte of the flags
            if (f < 0) exit 1
            if (int(f / 8) % 2 == 1) exit 1      # 0x08 = auto-detect, must be clear
            exit 0
        }
    ' "$reg"
}

# Written as one line. Wine reads either shape, and one line is the shape the
# rest of this script knows how to replace.
disable_proxy_autodetect() {
    proxy_autodetect_is_off && return 0
    set_reg_line "$(bottle_user_reg)" "$PROXY_SECTION" "$PROXY_LINE" \
        '"DefaultConnectionSettings"' || return 1
    proxy_autodetect_is_off
}

# --------------------------------------------- the bottle's own shortcuts
# CrossOver writes a small sh script per Start Menu entry and hardcodes the
# CrossOver that generated it. Aurora's installer runs under the normal
# CrossOver, so its shortcut launches the game through the UNPATCHED copy --
# and the shortcut is how a player actually starts the game. Everything then
# behaves as though none of this was ever installed: no shim, no redirect,
# "servers have been shut down". Launching the same bottle from inside
# CrossOver-FIFA works, which makes it look intermittent rather than wrong.
menu_shims() {
    local d="$BOTTLE_DIR/$BOTTLE/desktopdata"
    [ -d "$d" ] || return 0
    # The backups this makes are shims too, and still name the old CrossOver.
    grep -rl "/Contents/SharedSupport/CrossOver/bin/wine" "$d" 2>/dev/null \
        | grep -v '\.bak-aurora17$' || true
}

# Shims that name a CrossOver other than the one we installed into.
menu_shims_pointing_elsewhere() {
    local f
    for f in ${(f)"$(menu_shims)"}; do
        [ -n "$f" ] || continue
        grep -q "$1/Contents/SharedSupport/CrossOver/bin/wine" "$f" || print -r -- "$f"
    done
}

repoint_menu_shims() {
    local app="$1" f n=0
    for f in ${(f)"$(menu_shims_pointing_elsewhere "$app")"}; do
        [ -n "$f" ] || continue
        [ -f "$f.bak-aurora17" ] || cp -X "$f" "$f.bak-aurora17" 2>/dev/null || cp "$f" "$f.bak-aurora17" || return 1
        # Any .app path in front of the known suffix, replaced with ours.
        /usr/bin/sed -i '' \
            -e "s|\"[^\"]*/Contents/SharedSupport/CrossOver/bin/wine\"|\"$app/Contents/SharedSupport/CrossOver/bin/wine\"|g" \
            "$f" || return 1
        n=$((n+1))
    done
    print -r -- "$n"
}

# ------------------------------------------- the bottle's certificate store
# Reported by --report only, as an observation. A fresh bottle has an empty
# root store and a working one had 163 certificates, so the count is worth
# having in a diagnosis -- but it is NOT known to cause anything. The theory
# that an empty store was what stalled a fresh bottle was tested and is wrong:
# a full game session on a fresh 64-bit bottle left the count at 0. Treat
# it as an open question rather than acting on this number.
root_cert_count() {
    local reg="$BOTTLE_DIR/$BOTTLE/system.reg"
    [ -f "$reg" ] || { print -r -- 0; return 1 }
    grep -c 'SystemCertificates\\\\Root\\\\Certificates\\\\' "$reg" 2>/dev/null || print -r -- 0
}

# The keys currently on a bundle, one per line.
entitlement_keys() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c 'Print' "$plist" 2>/dev/null \
        | sed -n 's/^ *\([A-Za-z0-9._-]*\) = .*/\1/p'
}

sign_payload() {
    local wine="$1" so
    for so in $MACHO; do
        [ -f "$wine/x86_64-unix/$so" ] \
            || die $E_PAYLOAD "$so is missing from $wine/x86_64-unix.
         The copy is incomplete. Run ./setup.sh again to make a fresh one."
        codesign --force --sign - "$wine/x86_64-unix/$so" 2>/dev/null \
            || die $E_PERMISSION "Could not sign $so.
$APP_MGMT_HINT
         If that was already on, run ./uninstall.sh and install again."
    done
    ok "the ${#MACHO} Mac files"
}

resign_app() {
    local app="$1"
    local ent after
    ent="$(mktemp -t cxent).plist"
    after="$(mktemp -t cxent).plist"

    # Failing to read the original entitlements is not the same as there being
    # none. Treating it as "none" is how the four CrossOver needs get silently
    # dropped, which breaks microphone, camera, and Apple Events afterwards.
    local rc
    read_entitlements "$app" "$ent" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        # Signing with an empty list is what takes microphone, camera and Apple
        # Events away for good, so put the known CrossOver 26.3 set in instead.
        note "could not read the permissions on $app -- $(ent_reason "$rc")"
        write_stock_entitlements "$ent" \
            || { rm -f "$ent" "$after"
                 die $E_PERMISSION "Could not write the replacement permission list.
         Nothing has been signed. Check there is free disk space, then
         run:  ./setup.sh --resign" }
        note "using the four CrossOver 26.3 ships with instead"
    fi

    local -a before_keys
    before_keys=( ${(f)"$(entitlement_keys "$ent")"} )
    [ "${#before_keys}" -gt 0 ] \
        || { rm -f "$ent" "$after"
             die $E_PAYLOAD "CrossOver's permission list came back empty. Nothing signed.
         Reinstall CrossOver 26.3 from codeweavers.com, then run this again." }
    ok "kept CrossOver's ${#before_keys} permissions"

    /usr/libexec/PlistBuddy -c "Add :$LIBVAL_KEY bool true" "$ent" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Set :$LIBVAL_KEY true" "$ent" >/dev/null 2>&1 \
        || { rm -f "$ent" "$after"
             die $E_PERMISSION "Could not add the permission that lets the copy load its own
         frameworks. Without it the app will not open at all. Nothing signed.
         Check there is free disk space, then run:  ./setup.sh --resign" }
    ok "allowed it to load its own frameworks"

    codesign --force --sign - -o runtime --entitlements "$ent" "$app" 2>/dev/null \
        || { rm -f "$ent" "$after"
             die $E_PERMISSION "Could not sign $app.
         It will not open until it is signed.
$APP_MGMT_HINT
         Then run:  ./setup.sh --resign" }
    ok "signed $app"

    # Read back what actually landed. codesign can succeed and still not carry
    # what we handed it, and that failure is invisible until the app will not
    # open, which is a miserable thing to debug from the other end.
    codesign -d --entitlements "$after" --xml "$app" 2>/dev/null && [ -s "$after" ] \
        || { rm -f "$ent" "$after"
             die $E_PERMISSION "Signed $app but could not read its permissions back.
         Run:  ./setup.sh --resign
         If it happens again, run ./uninstall.sh and install again." }

    local -a now_keys
    now_keys=( ${(f)"$(entitlement_keys "$after")"} )
    local k missing=""
    for k in $before_keys; do
        [[ " ${now_keys[*]} " == *" $k "* ]] || missing="$missing $k"
    done
    [ -z "$missing" ] || { rm -f "$ent" "$after"
        die $E_PERMISSION "Signing lost these permissions:$missing
         Run ./setup.sh --resign. If it happens again, run ./uninstall.sh
         and install again." }
    [[ " ${now_keys[*]} " == *" $LIBVAL_KEY "* ]] || { rm -f "$ent" "$after"
        die $E_PERMISSION "The permission that lets the copy load its own frameworks did not
         stick. The app would not open. Run ./setup.sh --resign." }
    ok "all ${#now_keys} permissions verified on the signed app"
    rm -f "$ent" "$after"

    # If this is wrong the app dies at launch with a dyld error and no window.
    codesign --verify --deep --strict "$app" 2>/dev/null \
        || die $E_PERMISSION "The new signature on $app did not verify.
         The app would not open. Run:  ./setup.sh --resign
         If that does not help, run ./uninstall.sh and install again."
    ok "signature verifies"
}

# ------------------------------------------------------------- --verify
# Checks an install without changing anything. Every troubleshooting step in
# SETUP.md can point here instead of at a re-install.
# ------------------------------------------------- where the game actually is
# Aurora's connector records the folder it launches from, and that is the folder
# whose version.dll matters -- not necessarily the one someone installed into.
# --report and --verify both need it, and had two copies of this parsing until
# 2026-09-02; one copy is enough.
connector_game_dir() {
    local conn
    conn="$BOTTLE_DIR/$BOTTLE/drive_c/users/crossover/AppData/Local/Aurora17/Connector/connector.json"
    [ -f "$conn" ] || return 1
    sed -n 's/.*"gameDirectory": *"\([^"]*\)".*/\1/p' "$conn" | head -1
}

# Y:\Downloads\FIFA 17 -> the real path, through the bottle's own mapping. The
# separators arrive doubled, having been through JSON, so a run of backslashes
# of any length collapses to one slash.
win_path_to_unix() {
    local gamedir="$1" drive rest
    [ -n "$gamedir" ] || return 1
    drive="${gamedir%%:*}"
    rest="$(print -r -- "$gamedir" | sed -e 's|^[A-Za-z]:||' -e 's|\\\\*|/|g')"
    print -r -- "$BOTTLE_DIR/$BOTTLE/dosdevices/${(L)drive}:$rest"
}

# ------------------------------------------- the EA licence file (BUGS.md §18)
# FIFA 17 only takes its normal start-up path when EA's licence file is in the
# bottle. Without it the game goes into Origin activation, relaunches itself,
# and the first process -- the one Aurora's connector is bound to -- exits
# 0xFFFFFFFA about twenty seconds in, which reads from outside as "PLAY does
# nothing". The game's own loader writes the file in about four seconds, and
# the bytes are the same in every bottle that has ever worked, so one loader
# run per bottle is the whole fix. Nothing here ships the file: it is made
# from the user's own copy of the game.
bottle_licence_file() {
    print -r -- "$BOTTLE_DIR/$BOTTLE/drive_c/ProgramData/Electronic Arts/EA Services/License/1027460.dlf"
}

# Where FIFA 17 is, in macOS terms. The connector records it, but only once
# Aurora has run in the bottle -- and the licence is missing exactly when
# nothing has run yet -- so fall back to AURORA_GAME_DIR and the usual places.
game_dir_find() {
    local gd u d
    gd="$(connector_game_dir 2>/dev/null || true)"
    if [ -n "$gd" ]; then
        u="$(win_path_to_unix "$gd" 2>/dev/null || true)"
        if [ -n "$u" ] && [ -f "$u/_fifa17.exe" ]; then print -r -- "$u"; return 0; fi
    fi
    for d in "${AURORA_GAME_DIR:-}" "$HOME/Downloads/FIFA 17" "$HOME/FIFA 17" "$HOME/Desktop/FIFA 17"; do
        [ -n "$d" ] || continue
        if [ -f "$d/_fifa17.exe" ]; then print -r -- "$d"; return 0; fi
    done
    return 1
}

# /Users/me/Downloads/FIFA 17 -> Y:\Downloads\FIFA 17, through the bottle's own
# dosdevices links, longest match first so y: beats z:. The loader is started by
# drive letter because that is how CrossOver starts it, and how the run that
# proved this worked.
unix_path_to_win() {
    local p="${1%/}" link target dl best_drive="" best_target="" rest
    for link in "$BOTTLE_DIR/$BOTTLE"/dosdevices/?:(N@); do
        target="$(readlink "$link" 2>/dev/null || true)"
        [ -n "$target" ] || continue
        case "$target" in
            ../drive_c) target="$BOTTLE_DIR/$BOTTLE/drive_c" ;;
        esac
        target="${target%/}"
        [ "$p" = "$target" ] || [ "${p#$target/}" != "$p" ] || continue
        if [ -z "$best_drive" ] || [ "${#target}" -gt "${#best_target}" ]; then
            best_target="$target"; best_drive="${link:t}"
        fi
    done
    [ -n "$best_drive" ] || return 1
    rest="${p#$best_target}"
    dl="${(U)best_drive%:}"
    print -r -- "${dl}:${rest//\//\\}"
}

# The game and its loader in THIS bottle, and no other.
#
# Neither of the obvious tests works on the game itself. FIFA17.exe runs with
# its working directory in the game folder, which is outside the prefix, so
# prefix_holders -- the cwd test --unstick uses -- never sees it; and its ps
# line is the bare image name, with no prefix anywhere in the command line or
# the environment. What it does have is the prefix open: the registry, its own
# drive_c files, the wineserver socket. So ask lsof, and only about the few
# pids whose image name matches, because lsof per pid is not free.
bottle_game_pids() {
    local pfx="$BOTTLE_DIR/$BOTTLE" pid rest
    ps -Ao pid=,command= 2>/dev/null | while read -r pid rest; do
        case "$rest" in (*FIFA17.exe*|*_fifa17.exe*) ;; (*) continue ;; esac
        /usr/sbin/lsof -p "$pid" -Fn 2>/dev/null | grep -qF -- "$pfx" \
            && print -r -- "$pid"
    done | sort -u
    return 0
}

# Stops them, politely then not. Only ever the pids above.
stop_bottle_game() {
    local -a victims left
    local waited=0
    victims=( ${(f)"$(bottle_game_pids)"} )
    victims=( ${victims:#} )
    [ "${#victims}" -gt 0 ] || return 0
    kill -TERM ${victims} 2>/dev/null || true
    while [ "$waited" -lt 15 ]; do
        left=( ${(f)"$(bottle_game_pids)"} )
        left=( ${left:#} )
        [ "${#left}" -eq 0 ] && return 0
        /bin/sleep 1
        waited=$((waited + 1))
    done
    left=( ${(f)"$(bottle_game_pids)"} )
    left=( ${left:#} )
    [ "${#left}" -eq 0 ] || kill -KILL ${left} 2>/dev/null || true
    return 0
}

# Runs the loader once, waits for the file, then stops what it started.
seed_bottle_licence() {
    local app="$1" lic gdu gwin wine waited=0 wpid
    lic="$(bottle_licence_file)"
    if [ -f "$lic" ]; then
        ok "the licence file is already there ($(stat -f%z "$lic") bytes)"
        return 0
    fi
    if [ ! -d "$BOTTLE_DIR/$BOTTLE" ]; then
        note "no bottle to seed the licence file in"
        return 1
    fi
    gdu="$(game_dir_find 2>/dev/null || true)"
    if [ -z "$gdu" ]; then
        note "no FIFA 17 folder with _fifa17.exe in it was found, so the licence"
        say "        file cannot be made here. The launcher makes it on the first"
        say "        PLAY instead. For a game kept elsewhere:"
        say "        AURORA_GAME_DIR='/path/to/FIFA 17' ./setup.sh --bottle"
        return 1
    fi
    wine="$app/Contents/SharedSupport/CrossOver/bin/wine"
    gwin="$(unix_path_to_win "$gdu" 2>/dev/null || true)"
    if [ ! -x "$wine" ] || [ -z "$gwin" ]; then
        note "cannot start the loader (no wine at $wine, or the bottle has no"
        say "        drive letter for $gdu). The launcher will do it on PLAY."
        return 1
    fi
    say "        running _fifa17.exe once in $gdu"
    "$wine" --bottle "$BOTTLE" --workdir "$gdu" --cx-app "$gwin\\_fifa17.exe" \
        >/dev/null 2>&1 &
    wpid=$!
    while [ "$waited" -lt 60 ]; do
        [ -f "$lic" ] && break
        /bin/sleep 1
        waited=$((waited + 1))
    done
    kill -TERM "$wpid" 2>/dev/null || true
    stop_bottle_game
    wait "$wpid" 2>/dev/null || true
    if [ -f "$lic" ]; then
        ok "wrote the licence file after ${waited}s ($(stat -f%z "$lic") bytes)"
        return 0
    fi
    note "the loader ran for ${waited}s and wrote no licence file:"
    say "        $lic"
    say "        Start FIFA 17 once from CrossOver and let it reach its menu."
    return 1
}

# The bottle menu entry an offline install adds, so the game can be started the
# way everything else in CrossOver is: open the copy, click the entry. The GUI
# is what an offline session otherwise lacks -- started this way there is a
# CrossOver window running, so the background cleanup stands down on its own
# and no session-hold file is involved.
#
# It is a "raw" menu, not a Windows .lnk: the game folder is outside the bottle
# and _fifa17.exe has no shortcut of its own, so there is nothing to point a
# .lnk at. The command is the same one --play-offline runs, plus
# --wait-children so CrossOver sees the session end when the game closes.
MENU_OFFLINE="StartMenu/FIFA 17 (offline)"

install_offline_menu() {
    local app="$1" cxm="$1/Contents/SharedSupport/CrossOver/bin/cxmenu" gdir gwin cmd
    say ""
    say "10. Adding a FIFA 17 (offline) entry to the $BOTTLE bottle"
    if [ ! -x "$cxm" ]; then
        note "$app has no cxmenu tool, so the entry cannot be added."
        say "        Play with  PLAY FIFA 17 offline.command  instead."
        return 1
    fi
    gdir="$(game_dir_find 2>/dev/null || true)"
    # game_dir_find can answer through the bottle's own dosdevices link
    # (.../Bottles/Aurora17/dosdevices/y:/Downloads/FIFA 17). Wine resolves
    # that, but mapping it back to a drive letter gives a path that walks
    # through the bottle to get outside it. Resolve the links first.
    [ -n "$gdir" ] && gdir="${gdir:A}"
    if [ -z "$gdir" ]; then
        note "no FIFA 17 folder with _fifa17.exe in it was found, so there is"
        say "        nothing to point the entry at. For a game kept elsewhere:"
        say "        AURORA_GAME_DIR='/path/to/FIFA 17' ./setup.sh --offline"
        return 1
    fi
    gwin="$(unix_path_to_win "$gdir" 2>/dev/null || true)"
    if [ -z "$gwin" ]; then
        note "the $BOTTLE bottle has no drive letter for $gdir,"
        say "        so the entry cannot be made. Play with"
        say "        PLAY FIFA 17 offline.command  instead."
        return 1
    fi
    cmd="\"$app/Contents/SharedSupport/CrossOver/bin/wine\" --bottle \"$BOTTLE\" --wait-children --workdir \"$gdir\" --cx-app \"$gwin\\_fifa17.exe\""
    # Replace any entry from a previous run: the game folder may have moved,
    # and an entry pointing at where it used to be fails with nothing on screen.
    "$cxm" --bottle "$BOTTLE" --uninstall --uninstall-filter "$MENU_OFFLINE" \
           --delete --delete-filter "$MENU_OFFLINE" >/dev/null 2>&1 || true
    if "$cxm" --bottle "$BOTTLE" --create "$MENU_OFFLINE" --type raw \
              --description "FIFA 17 single player, no Aurora17" \
              --command "$cmd" --install >/dev/null 2>&1; then
        ok "FIFA 17 (offline) — open ${app:t:r}, pick the $BOTTLE bottle, click it"
        say "        it runs _fifa17.exe in $gdir"
        return 0
    fi
    note "cxmenu would not add the entry. Play with"
    say "        PLAY FIFA 17 offline.command  instead."
    return 1
}

# The Aurora17 folder, by override or by the three places it is normally put.
aurora_dir_find() {
    local d
    for d in "${AURORA_DIR:-}" "$HOME/Downloads/Aurora17" "$HOME/Aurora17" "$HOME/Desktop/Aurora17"; do
        [ -n "$d" ] || continue
        if [ -f "$d/Aurora17Connector.exe" ]; then print -r -- "$d"; return 0; fi
    done
    return 1
}

verify_install() {
    local app="$1" problems=0
    # An offline install (./setup.sh --offline) has no Aurora17 by design, so
    # the checks for Aurora's stand-in, its EA names and its certificate would
    # all report BAD on a perfectly good install. The receipt says which kind
    # this was; the flag says so during the install itself.
    local offline=0
    [ "${NO_AURORA:-0}" = 1 ] && offline=1
    [ -f "$RECEIPT" ] && grep -q '^offline=1$' "$RECEIPT" && offline=1
    say ""
    say "Checking $app"
    say ""

    [ -d "$app" ] || { bad "there is no app at $app"; return 1; }
    is_crossover_bundle "$app" \
        && ok "is a CrossOver bundle" \
        || { bad "$app is not a CrossOver bundle"; problems=$((problems+1)); }

    local wine="$app/Contents/SharedSupport/CrossOver/lib/wine" f
    if ! ( cd "$HERE/fixes" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1; then
        bad "fixes/ does not match its own checksums; cannot compare"
        return 1
    fi
    for f in $FILES; do
        if [ ! -f "$wine/$f" ]; then
            bad "${f:t} is missing"; problems=$((problems+1)); continue
        fi
        case "$f" in
        *.dll)
            # Installed unchanged, so a byte comparison is the whole story.
            cmp -s "$HERE/fixes/$f" "$wine/$f" \
                && ok "${f:t}" \
                || { bad "${f:t} is not the fixed version"; problems=$((problems+1)); }
            ;;
        *.so)
            # These three are modified after installation -- an rpath is added
            # and they are signed ad-hoc -- so their bytes no longer match the
            # shipped file. LC_UUID survives both, so it is what identifies them.
            if [ "$(macho_uuid "$wine/$f")" = "$(macho_uuid "$HERE/fixes/$f")" ]; then
                ok "${f:t}"
            else
                bad "${f:t} is not the fixed version"; problems=$((problems+1))
            fi
            ;;
        esac
    done

    local so
    for so in ntdll.so crypt32.so; do
        has_lib64_rpath "$wine/x86_64-unix/$so" \
            && ok "$so search path" \
            || { bad "$so is missing its library search path"; problems=$((problems+1)); }
    done
    for so in $MACHO; do
        # A file that is not there is reported as missing by the checks that own
        # it, further down. Saying "not signed" about it as well is two problems
        # for one fault, and names the wrong repair.
        [ -f "$wine/x86_64-unix/$so" ] || continue
        codesign --verify "$wine/x86_64-unix/$so" 2>/dev/null \
            || { bad "$so is not signed — run ./setup.sh --resign"; problems=$((problems+1)); }
    done

    local ent; ent="$(mktemp -t cxent).plist"
    if codesign -d --entitlements "$ent" --xml "$app" 2>/dev/null && [ -s "$ent" ]; then
        local -a keys; keys=( ${(f)"$(entitlement_keys "$ent")"} )
        [[ " ${keys[*]} " == *" $LIBVAL_KEY "* ]] \
            && ok "${#keys} permissions, including the framework one" \
            || { bad "the framework permission is missing — run ./setup.sh --resign"
                 problems=$((problems+1)); }
    else
        bad "cannot read the app's permissions — run ./setup.sh --resign"
        problems=$((problems+1))
    fi
    rm -f "$ent"

    codesign --verify --deep --strict "$app" 2>/dev/null \
        && ok "signature" \
        || { bad "signature does not verify — run ./setup.sh --resign"; problems=$((problems+1)); }

    local conf="$BOTTLE_DIR/$BOTTLE/cxbottle.conf" k v kv
    if [ -f "$conf" ]; then
        for kv in "CX_GRAPHICS_BACKEND=d3dmetal" "CX_DR_TRAP=2" "WINE_SIMULATE_WRITECOPY=1"; do
            k="${kv%%=*}"; v="${kv#*=}"
            grep -q "^\"$k\" = \"$v\"\$" "$conf" \
                && ok "$k" \
                || { bad "$k is not set to $v in the $BOTTLE bottle"; problems=$((problems+1)); }
        done
    else
        bad "no bottle called '$BOTTLE' at $BOTTLE_DIR"
        problems=$((problems+1))
    fi

    # A live session means everything below is being read from a file Wine is
    # about to overwrite from its own memory; a session with no CrossOver
    # behind it means the bottle will not open at all. See prefix_holders.
    local -a holding
    holding=( ${(f)"$(prefix_holders)"} )
    holding=( ${holding:#} )
    if [ "${#holding}" -eq 0 ]; then
        ok "nothing is holding the $BOTTLE bottle"
    elif hold_pid_alive; then
        note "FIFA 17 is playing right now, started by --play-offline (${#holding} processes)."
        say "        That is a running session, not a stuck bottle. Quit the game and"
        say "        check again if you want the settings below re-read."
    elif [ -n "$(crossovers_running)" ]; then
        note "the $BOTTLE bottle is open in CrossOver right now (${#holding} processes)."
        say "        Quit CrossOver and check again — Wine writes its own copy of"
        say "        user.reg out as it goes, which can undo the version override"
        say "        below after this has already said ok."
    else
        bad "${#holding} process(es) are still inside the $BOTTLE bottle with"
        say "        no CrossOver running. The bottle will hang on loading until"
        say "        they are gone. Run:  ./setup.sh --unstick"
        problems=$((problems+1))
    fi

    # Check whether any Aurora ports (47170-47173) are held by orphaned processes
    local port_pids
    port_pids="$(/usr/sbin/lsof -nP -iTCP:47170,47171,47172,47173 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | tr '\n' ' ')"
    port_pids="${port_pids% }"
    if [ -z "$port_pids" ]; then
        ok "all Aurora ports (47170-47173) are free"
    elif [ -n "$(crossovers_running)" ]; then
        note "Aurora service is active on port(s) 47170-47173 (PID: $port_pids)"
    else
        bad "orphaned process(es) holding Aurora port(s) (PID: $port_pids) with CrossOver closed."
        say "        The launcher will fail with 'A server is already listening'. Run:  ./setup.sh --unstick"
        problems=$((problems+1))
    fi

    # Without this the redirect shim is never loaded and the only symptom is
    # "servers have been shut down" -- with every other check here passing.
    if [ -f "$(bottle_user_reg)" ]; then
        version_override_is_set \
            && ok "version = native,builtin in the $BOTTLE bottle" \
            || { bad "the $BOTTLE bottle loads Wine's own version.dll, so"
                 say "        Aurora's redirect shim never loads and the game will"
                 say "        say the servers are shut down. Quit CrossOver fully,"
                 say "        then re-run ./setup.sh"
                 problems=$((problems+1)); }
    fi

    # Without this Aurora's helper spends five seconds looking for a proxy before
    # its first request, and the shim's five-second deadline for the Origin auth
    # code runs out first. See BUGS.md §21.
    if [ -f "$(bottle_user_reg)" ]; then
        proxy_autodetect_is_off \
            && ok "proxy auto-detect off in the $BOTTLE bottle" \
            || { bad "proxy auto-detect is on in the $BOTTLE bottle, so Aurora's"
                 say "        helper spends five seconds looking for a proxy and misses"
                 say "        the deadline for the Origin auth code. The game will quit"
                 say "        saying the Origin client was terminated. Quit CrossOver"
                 say "        fully, then re-run ./setup.sh"
                 problems=$((problems+1)); }
    fi

    # A PlayStation controller with its buttons in the wrong places. A note, not
    # a BAD: the game runs and a keyboard is unaffected -- but it is the first
    # thing a player with a pad will hit.
    if [ -f "$(bottle_system_reg)" ]; then
        hidraw_is_disabled \
            && ok "DisableHidraw = 1 in the $BOTTLE bottle (controller buttons in the right places)" \
            || { note "DisableHidraw is not set in the $BOTTLE bottle, so a PlayStation"
                 say "        controller's buttons land in the wrong places (Cross acts as"
                 say "        Circle). Quit CrossOver fully, then re-run ./setup.sh"; }
    fi

    # A shortcut that starts the game through the unpatched CrossOver undoes
    # every other thing on this list, while all of them still report ok.
    local -a stray
    stray=( ${(f)"$(menu_shims_pointing_elsewhere "$app")"} )
    stray=( ${stray:#} )
    if [ "${#stray}" -eq 0 ]; then
        ok "the bottle's shortcuts start ${app:t}"
    else
        bad "${#stray} shortcut(s) in the $BOTTLE bottle start a different"
        say "        CrossOver, so the game runs unpatched and will say the"
        say "        servers are shut down. Re-run ./setup.sh"
        for f in $stray; do say "        ${f:t}"; done
        problems=$((problems+1))
    fi

    # An offline install has no Aurora17, so its stand-in is not checked. The
    # checks below are Aurora17's and are skipped for it (not re-indented).
    if [ "$offline" = 1 ]; then
        ok "offline install: no Aurora17 stand-in to check"
    else
    # PLAY only needs one of the two stand-in locations to be right. "Wrong
    # build" and "not there at all" are different faults and had been reported
    # as the same one -- an older stand-in sitting in both places was described
    # as being in neither, which sends you looking for a missing file that is
    # not missing.
    local psdir="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
    local found=0 stale=0 d
    local -a stale_at
    if cmp -s "$HERE/aurora17/powershell.exe" "$psdir/powershell.exe" 2>/dev/null; then
        ok "PowerShell stand-in in the bottle"; found=1
    elif [ -f "$psdir/powershell.exe" ]; then
        stale=1; stale_at+=( "the $BOTTLE bottle" )
    fi
    for d in "${AURORA_DIR:-}" "$HOME/Downloads/Aurora17" "$HOME/Aurora17" "$HOME/Desktop/Aurora17"; do
        [ -n "$d" ] || continue
        if cmp -s "$HERE/aurora17/powershell.exe" "$d/powershell.exe" 2>/dev/null; then
            ok "PowerShell stand-in in $d"; found=1; break
        elif [ -f "$d/powershell.exe" ]; then
            stale=1; stale_at+=( "$d" )
        fi
    done
    if [ "$found" != 1 ] && [ "$stale" = 1 ]; then
        bad "a powershell.exe is there but is not the shipped stand-in:"
        for d in $stale_at; do say "        $d"; done
        say "        An older stand-in reports every failure as a bare exit 1"
        say "        instead of a numbered code. Re-run ./setup.sh"
        problems=$((problems+1))
    elif [ "$found" != 1 ]; then
        bad "the PowerShell stand-in is in neither place — PLAY will do nothing"
        problems=$((problems+1))
    fi
    fi

    # Name resolution. Two halves: the reader has to be installed and wired in,
    # and the file it reads has to say something. The second half is Aurora17's
    # to maintain -- its launcher rewrites that file on every PLAY -- so an
    # empty one on a bottle that has never played is normal, not a fault.
    if [ ! -f "$wine/$RESOLVER" ]; then
        bad "${RESOLVER:t} is missing — the game will not reach Aurora17"
        problems=$((problems+1))
    elif [ "$(macho_uuid "$wine/$RESOLVER")" = "$(macho_uuid "$HERE/fixes/$RESOLVER")" ]; then
        ok "${RESOLVER:t}"
    else
        bad "${RESOLVER:t} is not the shipped version"
        problems=$((problems+1))
    fi

    if ws2_32_is_patched "$wine"; then
        ok "ws2_32.so reads the bottle's hosts file"
    else
        bad "ws2_32.so still asks macOS to resolve names, so the hosts"
        say "        file inside the bottle is ignored and the game will not"
        say "        connect. Re-run ./setup.sh"
        problems=$((problems+1))
    fi

    # EA names, hosts receipt, redirect shim and certificate are all Aurora17's,
    # and an offline install has none of them. The licence file is the game's
    # own, so it is checked either way.
    if [ "$offline" = 1 ]; then
        ok "offline install: Aurora17's EA names, redirect and certificate do not apply"
        # The licence file is the game's own and is checked either way.
        local olic; olic="$(bottle_licence_file)"
        if [ -f "$olic" ]; then
            ok "licence file present ($(stat -f%z "$olic") bytes)"
        else
            bad "no licence file, so FIFA 17 will quit a few seconds after it starts:"
            say "        $olic"
            say "        Run  ./setup.sh --offline  again, or start the game once from"
            say "        CrossOver and let it reach the menu."
            problems=$((problems+1))
        fi
    else
    local -a miss; local bh; bh="$(bottle_hosts_file)"
    miss=( ${(f)"$(hosts_missing)"} )
    if [ "${#miss}" -eq 0 ]; then
        ok "all ${#AURORA_HOSTS} EA host redirections in the bottle's hosts file"
    elif [ "${#miss}" -eq "${#AURORA_HOSTS}" ]; then
        note "the bottle's hosts file names none of the ${#AURORA_HOSTS} EA hosts yet"
        say "        $bh"
        say "        Aurora17's launcher writes them itself, on every PLAY and"
        say "        every REPAIR SETUP. If it has not been run in this bottle,"
        say "        this is expected — press PLAY once and check again."
    else
        bad "the bottle's hosts file names only $((${#AURORA_HOSTS} - ${#miss}))"
        say "        of the ${#AURORA_HOSTS} EA hosts, so something rewrote it wrongly:"
        say "        $bh"
        say "        Missing: ${miss[*]}"
        say "        Use Aurora17's REPAIR SETUP to put them back."
        problems=$((problems+1))
    fi

    # No receipt means Aurora17 believes it still has to install the mappings,
    # and installing them is the step it tries to elevate for. See
    # seed_bottle_hosts: that elevation is what fails under Wine.
    local rc; rc="$(hosts_receipt_file 2>/dev/null || true)"
    if [ -z "$rc" ]; then
        note "no Windows user folder in the bottle yet — open it in CrossOver once"
    elif [ -f "$rc" ]; then
        ok "Aurora17 owns those mappings (no elevated step on PLAY)"
    else
        bad "Aurora17 has no hosts receipt, so its first PLAY will try to"
        say "        elevate and stop with 'The elevated setup step exited with"
        say "        code 1'. Re-run ./setup.sh"
        problems=$((problems+1))
    fi

    # ---- three checks that used to be in --report only -------------------
    # Each of these could be wrong while --verify still said "everything checks
    # out", which is the worst thing a check can do. --report has always shown
    # them; showing them only there meant nobody looked until after a failure.

    # The redirect shim in the game folder. Without it the game never reaches
    # Aurora at all and says "the servers for this title have been shut down"
    # -- with a clean --verify behind it.
    local gd gdu
    gd="$(connector_game_dir 2>/dev/null || true)"
    if [ -z "$gd" ]; then
        note "Aurora has not run in this bottle yet, so the game folder is not"
        say "        recorded — press PLAY once, then check again"
    else
        gdu="$(win_path_to_unix "$gd" 2>/dev/null || true)"
        if [ -z "$gdu" ] || [ ! -d "$gdu" ]; then
            bad "the game folder Aurora recorded does not exist:"
            say "        $gd"
            say "        Aurora is pointed at a folder that is not there. Set the"
            say "        game location again in Aurora17 and press PLAY once."
            problems=$((problems+1))
        else
            local gf missing_shim=0
            for gf in version.dll aurora17-redirect.ini; do
                [ -f "$gdu/$gf" ] || missing_shim=1
            done
            if [ "$missing_shim" -eq 0 ]; then
                ok "the redirect shim is in the game folder"
            else
                bad "the game folder is missing part of Aurora's redirect shim:"
                say "        $gdu"
                for gf in version.dll aurora17-redirect.ini; do
                    [ -f "$gdu/$gf" ] || say "        missing: $gf"
                done
                say "        Without both, the game never reaches Aurora and reports"
                say "        'the servers for this title have been shut down'."
                say "        Use Aurora17's REPAIR SETUP to put them back."
                problems=$((problems+1))
            fi
        fi
    fi

    # BUGS.md §18: the one file whose absence made a fully verified bottle die
    # twenty seconds into every launch, with nothing static wrong anywhere.
    local lic; lic="$(bottle_licence_file)"
    if [ -f "$lic" ]; then
        ok "licence file present ($(stat -f%z "$lic") bytes)"
    else
        bad "no licence file (step 9a):"
        say "        $lic"
        say "        Without it FIFA 17 takes its Origin activation path, relaunches"
        say "        itself, and the process Aurora watches exits 0xFFFFFFFA about"
        say "        twenty seconds in. PLAY now seeds the file itself; to do it"
        say "        first:  AURORA_BOTTLE='$BOTTLE' ./setup.sh --bottle"
        problems=$((problems+1))
    fi

    # The certificate the launcher cannot mint inside a bottle: there is no PKI
    # module here, so a missing pfx is a dead stop at PLAY, not a slow path.
    local adir; adir="$(aurora_dir_find 2>/dev/null || true)"
    if [ -z "$adir" ]; then
        note "no Aurora17 folder found — if yours is elsewhere:"
        say "        AURORA_DIR=/path/to/Aurora17 ./setup.sh --verify"
    elif [ -f "$adir/server/Aurora17Server/redirector-dev.pfx" ]; then
        ok "the redirector certificate is in place"
    else
        bad "redirector-dev.pfx is missing from"
        say "        $adir/server/Aurora17Server/"
        say "        The launcher will try to mint one and stop: minting needs"
        say "        Windows PowerShell's PKI module, which a bottle does not"
        say "        have. Re-run ./setup.sh — it copies the shipped one."
        problems=$((problems+1))
    fi
    fi

    # Which CrossOver is open. Three copies share one bundle identifier, so the
    # Dock, Spotlight and a stale menu shim can all hand someone the unpatched
    # one -- and every check above still passes, because they all look at the
    # app this script was told about, not the app that is running.
    local -a others; local r
    others=()
    for r in ${(f)"$(crossovers_running)"}; do
        [ -n "$r" ] || continue
        [ "${r:A}" = "${app:A}" ] || others+=( "$r" )
    done
    if [ "${#others}" -eq 0 ]; then
        : # either nothing is running, or the right one is -- both fine
    else
        bad "a different CrossOver is open than the one checked here."
        say "        checked:  $app"
        for r in $others; do say "        running:  $r" ; done
        say "        All CrossOver copies share one bundle identifier, so the"
        say "        Dock and Spotlight cannot tell them apart. Everything above"
        say "        passed for the copy this script was given — the one you are"
        say "        using is a different app and is not patched."
        say "        Quit it and open $app directly."
        problems=$((problems+1))
    fi

    say ""
    if [ "$problems" -eq 0 ]; then
        # Everything here is static -- files, UUIDs, signatures, registry keys.
        # A bottle can pass every one of them and still die twenty-four seconds
        # into the first PLAY (2026-09-02: a bottle made at 15:40 verified clean
        # and its launch exited 0xFFFFFFFA at 15:42:43). So this is deliberately
        # not phrased as "it will work", and it names the one thing that can
        # actually answer that.
        green "Everything checks out -- every static check passed."
        say ""
        say "That is not the same as \"the game will play\": these checks cannot"
        say "see a launch. To find out, run this and press PLAY when it asks:"
        say ""
        say "    AURORA_BOTTLE='$BOTTLE' ./setup.sh --smoke"
        say ""
        return 0
    fi
    red "$problems problem(s) above. SETUP.md says what each one means."
    return 1
}

say ""
say "FIFA 17 fixes — setup"
say "====================="

# Everything a diagnosis needs, in one output, so a broken install on somebody
# else's Mac is one paste instead of a dozen rounds of "now run this". The rule
# for what belongs here: anything that has ever been the answer. It changes
# nothing, and it prints no key, token or path outside the game and the bottle.
report_mode() {
    local app="$1"
    local out="${TMPDIR:-/tmp}/aurora17-report.txt"

    {
        print -r -- "==== aurora17 report ===================================="
        print -r -- "when      $(date '+%Y-%m-%d %H:%M:%S %z')"
        print -r -- "macOS     $(sw_vers -productVersion) ($(uname -m))"
        print -r -- "app       $app"
        print -r -- "version   $(crossover_version "$app")"
        print -r -- "bottle    $BOTTLE_DIR/$BOTTLE"
        print -r -- ""

        print -r -- "---- which CrossOver is actually running ----------------"
        local running
        running="$(crossovers_running)"
        print -r -- "${running:-(no CrossOver running)}"
        print -r -- ""

        print -r -- "---- what is holding the bottle ------------------------"
        local -a hold
        hold=( ${(f)"$(prefix_holders)"} )
        hold=( ${hold:#} )
        if [ "${#hold}" -eq 0 ]; then
            print -r -- "(nothing)"
        else
            ps -o pid=,etime=,command= -p "${(j:,:)hold}" 2>/dev/null || true
        fi
        print -r -- ""

        print -r -- "---- wineserver directories nobody owns ----------------"
        local orphaned
        orphaned="$(stale_wine_sockets)"
        print -r -- "${orphaned:-(none)}"
        print -r -- ""

        print -r -- "---- aurora port status (47170-47173) ------------------"
        local ports_out
        # lsof exits 1 when it finds nothing, which under set -e ended the
        # report here -- on exactly the machines where the ports were fine.
        ports_out="$(/usr/sbin/lsof -nP -iTCP:47170,47171,47172,47173 -sTCP:LISTEN 2>/dev/null || true)"
        print -r -- "${ports_out:-(all ports free)}"
        print -r -- ""

        print -r -- "---- checks --------------------------------------------"
        verify_install "$app" 2>&1 || true
        print -r -- ""

        print -r -- "---- bottle settings -----------------------------------"
        sed -n '/^\[EnvironmentVariables\]/,$p' "$BOTTLE_DIR/$BOTTLE/cxbottle.conf" 2>/dev/null \
            || print -r -- "(no cxbottle.conf)"
        print -r -- ""

        print -r -- "---- version DLL override ------------------------------"
        if version_override_is_set; then
            print -r -- "version = native,builtin  OK"
        else
            print -r -- "NOT SET -- Aurora's redirect shim cannot load"
        fi
        print -r -- ""

        print -r -- "---- proxy auto-detect ---------------------------------"
        if proxy_autodetect_is_off; then
            print -r -- "proxy auto-detect  off  OK"
        else
            print -r -- "proxy auto-detect  ON  (see SETUP.md: The Origin client was terminated)"
        fi
        print -r -- ""

        print -r -- "---- controller (winebus) ------------------------------"
        if hidraw_is_disabled; then
            print -r -- "DisableHidraw = 1  OK"
        else
            print -r -- "NOT SET -- a PlayStation controller's buttons land in the wrong places"
        fi
        print -r -- ""

        print -r -- "---- what the bottle's shortcuts start -----------------"
        local sh
        for sh in ${(f)"$(menu_shims)"}; do
            [ -n "$sh" ] || continue
            print -r -- "${sh:t}"
            sed -n 's|.*exec "\([^"]*\)/Contents/SharedSupport.*|  -> \1|p' "$sh"
        done
        print -r -- ""

        print -r -- "---- certificate store ---------------------------------"
        print -r -- "root certificates: $(root_cert_count)  (observation only, cause unknown)"
        print -r -- ""

        print -r -- "---- the shim in the game folder -----------------------"
        # The connector records where the game is; that is the folder whose
        # version.dll matters, and it is not always the one that was installed.
        local gamedir="" unixdir=""
        gamedir="$(connector_game_dir 2>/dev/null || true)"
        if [ -n "$gamedir" ]; then
            print -r -- "connector says: $gamedir"
            unixdir="$(win_path_to_unix "$gamedir" 2>/dev/null || true)"
            if [ -d "$unixdir" ]; then
                print -r -- "which is:       $unixdir"
                local f
                for f in version.dll aurora17-redirect.ini; do
                    if [ -f "$unixdir/$f" ]; then
                        print -r -- "  $f  $(shasum -a 256 "$unixdir/$f" | cut -c1-16)  $(stat -f%z "$unixdir/$f") bytes"
                    else
                        print -r -- "  $f  MISSING"
                    fi
                done
            else
                print -r -- "which does not resolve to a folder -- the game dir is wrong"
            fi
        else
            print -r -- "(no connector.json -- Aurora has not run in this bottle)"
        fi
        print -r -- ""

        print -r -- "---- the EA licence file (SETUP.md step 9a) ------------"
        local lic; lic="$(bottle_licence_file)"
        if [ -f "$lic" ]; then
            print -r -- "$lic"
            print -r -- "  $(shasum -a 256 "$lic" | cut -c1-16)  $(stat -f%z "$lic") bytes"
        else
            print -r -- "MISSING: $lic"
            print -r -- "  FIFA exits 0xFFFFFFFA about twenty seconds in without it."
        fi
        print -r -- ""

        print -r -- "---- did the shim load? --------------------------------"
        # This is the single most useful line in the whole report. The shim
        # writes this file the moment it loads, so its absence after a launch
        # means it never loaded at all -- which no other check reveals.
        local logs="$BOTTLE_DIR/$BOTTLE/drive_c/users/crossover/AppData/Local/Aurora17/Logs"
        if [ -f "$logs/redirect-shim.log" ]; then
            print -r -- "redirect-shim.log exists, last 25 lines:"
            tail -25 "$logs/redirect-shim.log"
        else
            print -r -- "NO redirect-shim.log -- the shim has never loaded."
            print -r -- "That is the version DLL override, above, nine times in ten."
        fi
        print -r -- ""

        print -r -- "---- the six network mappings --------------------------"
        # The launcher will not start the server until it is satisfied about
        # these, and the step it uses to fix them cannot run under Wine. See
        # seed_bottle_hosts.
        local bh rc
        bh="$(bottle_hosts_file)"
        if [ -f "$bh" ]; then
            print -r -- "$bh"
            print -r -- "  $(shasum -a 256 "$bh" | cut -c1-16)  $(wc -c < "$bh" | tr -d ' ') bytes"
            local m; m="$(hosts_missing)"
            print -r -- "  missing: ${m:-(none — all ${#AURORA_HOSTS} present)}"
        else
            print -r -- "NO hosts file in the bottle at all"
        fi
        rc="$(hosts_receipt_file 2>/dev/null || true)"
        if [ -n "$rc" ] && [ -f "$rc" ]; then
            print -r -- "receipt: $rc"
            grep -E '"(preimageLength|preimageSha256|currentLength|currentSha256|installedAtUtc)"' "$rc" || true
        else
            print -r -- "receipt: NONE — PLAY will try to elevate and exit 1"
        fi
        print -r -- ""

        print -r -- "---- the Aurora17 folder -------------------------------"
        # Two files decide whether the launcher can get past its own checks:
        # the PowerShell stand-in, and the certificate it cannot mint here.
        local ad="${AURORA_DIR:-}" d
        if [ -z "$ad" ]; then
            for d in "$HOME/Downloads/Aurora17" "$HOME/Aurora17" "$HOME/Desktop/Aurora17"; do
                if [ -f "$d/Aurora17Connector.exe" ]; then ad="$d"; break; fi
            done
        fi
        if [ -n "$ad" ]; then
            print -r -- "$ad"
            if [ -f "$ad/powershell.exe" ]; then
                if cmp -s "$ad/powershell.exe" "$HERE/aurora17/powershell.exe"; then
                    print -r -- "  powershell.exe        the shipped stand-in  OK"
                else
                    print -r -- "  powershell.exe        NOT the shipped stand-in — re-run ./setup.sh"
                fi
            else
                print -r -- "  powershell.exe        MISSING — PLAY does nothing"
            fi
            if [ -f "$ad/server/Aurora17Server/redirector-dev.pfx" ]; then
                print -r -- "  redirector-dev.pfx    present  OK"
            else
                print -r -- "  redirector-dev.pfx    MISSING — the launcher will try to mint one"
                print -r -- "                        and stop: no PKI module in this bottle"
            fi
        else
            print -r -- "(no Aurora17 folder found — run  AURORA_DIR=... ./setup.sh --report)"
        fi
        print -r -- ""

        print -r -- "---- newest connector log ------------------------------"
        local newest
        newest="$(ls -t "$logs"/connector-*.log 2>/dev/null | head -1)"
        if [ -n "$newest" ]; then
            print -r -- "${newest:t}"
            tail -30 "$newest"
        else
            print -r -- "(none)"
        fi
        print -r -- ""

        print -r -- "---- newest server log ---------------------------------"
        # "The server does not work with the game" is usually visible here as a
        # redirector handshake that never completes.
        local srv
        srv="$(ls -t "$logs"/server-*.log 2>/dev/null | head -1)"
        if [ -n "$srv" ]; then
            print -r -- "${srv:t}"
            tail -30 "$srv"
        else
            print -r -- "(none — the server has never started in this bottle)"
        fi
        print -r -- "==== end ==============================================="
    } 2>&1 | tee "$out"

    print -r -- ""
    print -r -- "Saved to $out — send that file, or paste everything above."
}

# Everything --report prints, plus the log files themselves, in one zip. A
# tester's first run is the only cheap chance to collect this: by the time they
# have been asked three questions they have already deleted the bottle.
#
# Nothing here leaves the machine on its own. It writes a file and says where.
bundle_mode() {
    setopt localoptions nullglob
    local app="$1"
    local stamp; stamp="$(date '+%Y%m%d-%H%M%S')"
    local dest="$HOME/Desktop"
    [ -d "$dest" ] || dest="${TMPDIR:-/tmp}"
    local work="${TMPDIR:-/tmp}/aurora17-bundle-$stamp"
    local zipf="$dest/aurora17-bundle-$stamp.zip"

    rm -rf "$work"
    mkdir -p "$work/logs"

    say "Collecting..."
    report_mode "$app" > "$work/report.txt" 2>&1 || true

    local logs="$BOTTLE_DIR/$BOTTLE/drive_c/users/crossover/AppData/Local/Aurora17/Logs"
    local f kind
    # The newest of each kind, not all of them: a bottle that has been played in
    # for a week holds hundreds, and the old ones answer nothing.
    for kind in connector server client; do
        for f in ${(f)"$(/bin/ls -t -- "$logs"/$kind-*.log(N) 2>/dev/null | head -3)"}; do
            [ -n "$f" ] && cp "$f" "$work/logs/" 2>/dev/null || true
        done
    done
    for f in redirect-shim.log wire-transcript.log; do
        [ -f "$logs/$f" ] && cp "$logs/$f" "$work/logs/" 2>/dev/null || true
    done

    local bh; bh="$(bottle_hosts_file)"
    [ -f "$bh" ] && cp "$bh" "$work/bottle-hosts.txt" 2>/dev/null || true
    local rc; rc="$(hosts_receipt_file 2>/dev/null || true)"
    [ -n "$rc" ] && [ -f "$rc" ] && cp "$rc" "$work/hosts-mapping.json" 2>/dev/null || true
    [ -f "$BOTTLE_DIR/$BOTTLE/cxbottle.conf" ] \
        && sed -n '/^\[EnvironmentVariables\]/,$p' "$BOTTLE_DIR/$BOTTLE/cxbottle.conf" \
           > "$work/bottle-environment.txt" 2>/dev/null || true
    [ -f "$RECEIPT" ] && cp "$RECEIPT" "$work/install-receipt.conf" 2>/dev/null || true

    # What is actually installed, so a mismatched or half-copied payload shows
    # up without another round trip.
    {
        print -r -- "shipped:"
        ( cd "$HERE/fixes" && shasum -a 256 -c SHA256SUMS 2>&1 ) || true
        ( cd "$HERE/aurora17" && shasum -a 256 -c SHA256SUMS 2>&1 ) || true
        print -r -- ""
        print -r -- "installed in $app: (the .so hashes differ from the shipped"
        print -r -- "ones by design -- they are re-signed on install. --verify"
        print -r -- "compares Mach-O UUIDs, which signing does not change.)"
        local w="$app/Contents/SharedSupport/CrossOver/lib/wine"
        for f in $FILES $RESOLVER x86_64-unix/ws2_32.so; do
            if [ -f "$w/$f" ]; then
                print -r -- "  $(shasum -a 256 "$w/$f" | cut -c1-16)  $f"
            else
                print -r -- "  MISSING                    $f"
            fi
        done
    } > "$work/payload.txt" 2>&1

    rm -f "$zipf"
    ( cd "${work:h}" && zip -qr "$zipf" "${work:t}" ) \
        || { say "Could not write $zipf"; rm -rf "$work"; return 1 }
    rm -rf "$work"

    say ""
    say "Wrote $zipf"
    say ""
    say "Send that file. It contains the checks above, the Aurora17 logs, the"
    say "bottle's hosts file and its settings, and the hashes of what is"
    say "installed. It contains no account, password or session token."
    say ""
    return 0
}

# ------------------------------------------- the bottle, on its own
# Steps 7 to 9 are everything that lives in the bottle rather than in the
# CrossOver copy: the settings, the version override, the shortcuts, the
# PowerShell stand-in and the six network mappings.
#
# They are a function because a bottle is not necessarily made before the
# fixes are installed. A bottle created afterwards -- and after a bad session
# the cure is a fresh bottle, see SETUP.md -- has none of this, and its
# Aurora17 shortcut points at whichever CrossOver made it. Re-running the whole
# installer to fix that would re-copy a gigabyte to change five files, so
# --bottle does these three steps and nothing else.
configure_bottle() {
    local APP="$1"

    # --------------------------------------------------- 7. the bottle settings
    # These settings are what the game needs. Putting them in the bottle means you
    # can launch normally from CrossOver instead of needing a Terminal script.
    # Bottles are shared between CrossOver and the copy, so this is set once.
    say ""
    say "7. Adding the settings to your bottle"
    BOTTLE_OK=0
    CONF="$BOTTLE_DIR/$BOTTLE/cxbottle.conf"
    if [ ! -f "$CONF" ]; then
        note "no bottle called '$BOTTLE' found at"
        say "        $BOTTLE_DIR"
        say "        FIFA will not start without these settings. Once the bottle"
        say "        exists, run:   AURORA_BOTTLE='name' ./setup.sh --resign"
        say "        or re-run this installer."
    else
        add_setting() {
            # A key that is present with the wrong value is not "already set". Left
            # alone it silently keeps the wrong graphics backend and the game hangs.
            if grep -q "^\"$1\" = \"$2\"\$" "$CONF"; then
                ok "$1 — already set"
            elif grep -q "^\"$1\" = " "$CONF"; then
                die $E_INCOMPLETE "$1 is set to something else in
                 $CONF
             It must be \"$2\". To fix:
               1. Open that file in TextEdit.
               2. Find the line starting \"$1\" and delete it.
               3. Save, then run this again."
            else
                printf '"%s" = "%s"\n' "$1" "$2" >> "$CONF"
                ok "$1 = $2"
            fi
        }
        grep -q '^\[EnvironmentVariables\]' "$CONF" || printf '\n[EnvironmentVariables]\n' >> "$CONF"
        add_setting CX_GRAPHICS_BACKEND d3dmetal
        add_setting CX_DR_TRAP 2
        add_setting WINE_SIMULATE_WRITECOPY 1

        # The sound fix. A Microsoft Teams audio driver, if you have one, stops
        # answering and freezes any program that asks it anything -- including the
        # game, before it reaches the menu. This is not CrossOver's fault and not
        # the game's; the same thing happens to ordinary Mac programs. We skip that
        # one device by name. If you do not have the driver, you do not need this.
        if [ -d "/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver" ]; then
            add_setting WINE_COREAUDIO_EXCLUDE "Microsoft Teams Audio"
            say "        (found the Teams audio driver — added the sound fix)"
        else
            ok "no Teams audio driver here, sound fix not needed"
        fi
        # See the comment on set_version_override. Nothing else puts this there,
        # and without it every other part of the install is wasted.
        if [ -f "$(bottle_user_reg)" ]; then
            if version_override_is_set; then
                ok "version = native,builtin — already set"
            elif set_version_override; then
                ok "version = native,builtin (kept the old user.reg as user.reg.bak-aurora17)"
                say "        this is what lets Aurora's redirect shim load at all"
            else
                die $E_PERMISSION "Could not set the version DLL override in
                 $(bottle_user_reg)
             Without it the game will say the servers have been shut down.
             Quit CrossOver completely and run this again."
            fi
            # See disable_proxy_autodetect. Same file, so it is done here rather
            # than in a block of its own. Not a stop: without it the game still
            # launches, and on a network where the wpad lookup fails fast it
            # still plays.
            if proxy_autodetect_is_off; then
                ok "proxy auto-detect off — already set"
            elif disable_proxy_autodetect; then
                ok "proxy auto-detect off (kept the old user.reg as user.reg.bak-aurora17)"
                say "        this is what keeps Aurora's helper inside its five-second limit"
            else
                note "could not turn proxy auto-detect off in $(bottle_user_reg)"
                say "        the game may quit saying the Origin client was terminated."
                say "        Quit CrossOver completely and run this again."
            fi
        else
            note "no user.reg in the $BOTTLE bottle yet — open it in CrossOver once,"
            say "        then run ./setup.sh again so the version override and the"
            say "        proxy setting can be set"
        fi

        # See disable_hidraw. Without it a PlayStation controller's buttons land
        # in the wrong places. Not a stop: the game plays, wrongly, and a
        # keyboard is unaffected.
        if [ -f "$(bottle_system_reg)" ]; then
            if hidraw_is_disabled; then
                ok "DisableHidraw = 1 — already set"
            elif disable_hidraw; then
                ok "DisableHidraw = 1 (kept the old system.reg as system.reg.bak-aurora17)"
                say "        this is what puts a PlayStation controller's buttons in the right places"
            else
                note "could not set DisableHidraw in $(bottle_system_reg)"
                say "        a PlayStation controller's buttons will be in the wrong places."
                say "        Quit CrossOver completely and run this again."
            fi
        fi

        # See repoint_menu_shims. Done last in this step so it also catches a
        # shortcut Aurora created earlier under the normal CrossOver.
        REPOINTED="$(repoint_menu_shims "$APP" 2>/dev/null || print -r -- fail)"
        case "$REPOINTED" in
            fail) note "could not repoint the bottle's shortcuts — start the game from"
                  say "        inside ${APP:t} rather than from its shortcut" ;;
            0)    ok "the bottle's shortcuts already start ${APP:t}" ;;
            *)    ok "$REPOINTED shortcut(s) now start ${APP:t}, not your normal CrossOver"
                  say "        (the originals are kept alongside as .bak-aurora17)" ;;
        esac

        BOTTLE_OK=1
    fi

    # --offline. Step 8 puts the PowerShell stand-in where Aurora17's PLAY
    # button looks for it and step 9 points EA's six names at the redirect
    # Aurora listens on: with no Aurora17 installed both are dead weight.
    #
    # 9a stays, and is the one thing here that is not Aurora's. 1027460.dlf is
    # FIFA 17's own licence file, written by the game's loader on a first run;
    # a bottle without it loses its first launch to 0xFFFFFFFA (BUGS.md §18).
    # Aurora's launcher normally seeds it on PLAY, so skipping it as "Aurora
    # stuff" would leave an offline install that quits a few seconds in with
    # nothing left to write the file.
    if [ "$NO_AURORA" = 1 ]; then
        say ""
        say "8-9. Skipped — Aurora17's stand-in and its EA name mappings (offline install)"
        say "        Nothing here talks to EA, so there is nothing to redirect."
        PS_OK=1; PS_AURORA_DIR=""; PS_BOTTLE_ACTION=""; HOSTS_OK=1
        say ""
        say "9a. Making sure FIFA 17's licence file is in the bottle"
        LICENCE_OK=0
        if seed_bottle_licence "$APP"; then
            LICENCE_OK=1
        else
            note "without it FIFA 17 quits on its own a few seconds after it starts,"
            say "        and an offline install has no Aurora launcher to write it"
            say "        for you. Start FIFA 17 once from CrossOver, let it reach the"
            say "        menu, then run this again to check."
        fi
        install_offline_menu "$APP" || true
        return 0
    fi

    # ------------------------------------------------ 8. the PowerShell stand-in
    # Aurora17's PLAY button does its real work by running scripts/Play.ps1 through
    # powershell.exe. Wine ships a powershell.exe that is a stub: it prints a FIXME
    # and returns 0 without executing anything. Aurora only checks the exit code, so
    # the stub's silent success made PLAY do nothing at all, with no error. This
    # installs a small native stand-in that performs the same work.
    say ""
    say "8. Installing the PowerShell stand-in Aurora17 needs"
    PS_OK=0
    PS_AURORA_DIR=""
    PS_BOTTLE_ACTION=""

    # Where is the extracted Aurora17 folder? CreateProcess looks in the calling
    # program's own directory first, so a copy there always wins.
    # An explicit AURORA_DIR means that folder and no other.
    if [ -n "${AURORA_DIR:-}" ]; then
        AURORA_CANDIDATES=( "${AURORA_DIR:A}" )
    else
        AURORA_CANDIDATES=(
          "$HOME/Downloads/Aurora17"
          "$HOME/Aurora17"
          "$HOME/Desktop/Aurora17"
        )
    fi
    AURORA_FOUND=""
    for d in $AURORA_CANDIDATES; do
        [ -n "$d" ] || continue
        if [ -f "$d/Aurora17Connector.exe" ]; then AURORA_FOUND="$d"; break; fi
    done
    if [ -n "$AURORA_FOUND" ]; then
        # Never overwrite somebody's real powershell.exe without keeping it.
        if [ -f "$AURORA_FOUND/powershell.exe" ] \
           && ! cmp -s "$HERE/aurora17/powershell.exe" "$AURORA_FOUND/powershell.exe" \
           && [ ! -f "$AURORA_FOUND/powershell.exe.aurora-orig" ]; then
            cp -X "$AURORA_FOUND/powershell.exe" "$AURORA_FOUND/powershell.exe.aurora-orig" \
                || die $E_PERMISSION "Could not back up the powershell.exe already in $AURORA_FOUND.
         That folder is not writable. In Finder, Get Info on it and check
         you have Read & Write, then run this again."
            note "kept the powershell.exe already there as powershell.exe.aurora-orig"
        fi
        cp -X "$HERE/aurora17/powershell.exe" "$AURORA_FOUND/powershell.exe" \
            || die $E_PERMISSION "Could not write into $AURORA_FOUND.
         That folder is not writable. In Finder, Get Info on it and check
         you have Read & Write, then run this again."
        ok "into $AURORA_FOUND"

        # Aurora17 does not ship redirector-dev.pfx by default and relies on Windows
        # PowerShell PKI cmdlets to mint it. On macOS Wine, supply our ready-made
        # redirector-dev.pfx if missing so certificate minting is never attempted.
        local pfx_dest="$AURORA_FOUND/server/Aurora17Server/redirector-dev.pfx"
        if [ -d "$AURORA_FOUND/server/Aurora17Server" ] && [ ! -f "$pfx_dest" ] && [ -f "$HERE/aurora17/redirector-dev.pfx" ]; then
            cp -X "$HERE/aurora17/redirector-dev.pfx" "$pfx_dest" 2>/dev/null || true
            [ -f "$pfx_dest" ] && ok "supplied redirector-dev.pfx into $AURORA_FOUND/server/Aurora17Server"
        fi

        PS_AURORA_DIR="$AURORA_FOUND"
        PS_OK=1
    else
        note "no Aurora17 folder found. If yours is elsewhere, run:"
        say "        AURORA_DIR=/path/to/Aurora17 ./setup.sh"
    fi

    # Also install it inside the bottle, so it is found no matter where Aurora17
    # lives. The file being replaced is Wine's own stub; we keep a copy of it.
    PSDIR="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
    if [ -d "$BOTTLE_DIR/$BOTTLE" ]; then
        if [ -f "$PSDIR/powershell.exe" ] \
           && ! cmp -s "$HERE/aurora17/powershell.exe" "$PSDIR/powershell.exe"; then
            # Somebody else's file. Keep it once; never overwrite that copy.
            [ -f "$PSDIR/powershell.exe.wine-stub-orig" ] \
                || cp -X "$PSDIR/powershell.exe" "$PSDIR/powershell.exe.wine-stub-orig"
            PS_BOTTLE_ACTION=replaced
        elif [ -f "$PSDIR/powershell.exe.wine-stub-orig" ]; then
            # Ours is already in and the original is safe beside it. A second
            # run must not back up our own file as if it were Wine's.
            PS_BOTTLE_ACTION=replaced
        else
            mkdir -p "$PSDIR"
            PS_BOTTLE_ACTION=created
        fi
        cp -X "$HERE/aurora17/powershell.exe" "$PSDIR/powershell.exe" \
            || die $E_PERMISSION "Could not write the stand-in into the $BOTTLE bottle.
         Quit CrossOver completely and run this again. If it repeats, check
         there is free disk space."
        ok "into the $BOTTLE bottle ($PS_BOTTLE_ACTION)"
        PS_OK=1
    fi

    # ------------------------------------------- 9. the six network mappings
    # See seed_bottle_hosts. Without this the launcher's first PLAY on a fresh
    # bottle stops at "The elevated setup step exited with code 1" and the server
    # is never started -- which reads, from the outside, as "the game runs but
    # nothing connects".
    say ""
    say "9. Putting the six EA name mappings in the bottle"
    HOSTS_OK=0
    if seed_bottle_hosts; then
        HOSTS_OK=1
    else
        note "the game will not reach Aurora17 until this file can be written"
    fi

    # ------------------------------------------------ 9a. the EA licence file
    # BUGS.md §18. Doing it here means the first PLAY in a new bottle is a
    # normal launch instead of the 0xFFFFFFFA one. It is not required -- the
    # launcher's stand-in seeds the file itself when PLAY finds it missing --
    # so a failure here is a note, not a stop.
    say ""
    say "9a. Making sure FIFA 17's licence file is in the bottle"
    LICENCE_OK=0
    if seed_bottle_licence "$APP"; then
        LICENCE_OK=1
    else
        note "without it the first PLAY seeds it, which takes a few seconds longer"
    fi
}

# ------------------------------------------------- the launch that is watched
# Why this exists: --verify checks files, UUIDs, signatures and registry keys,
# and every one of them passed on a bottle that could not play. On 2026-09-02 a
# bottle made at 15:40 was verified clean and its first PLAY died at 15:42:43
# with 0xFFFFFFFA, twenty-four seconds in. Static checks cannot see that,
# because nothing static is wrong.
#
# So this mode does not check anything. It watches one real launch and reports
# what happened, using the two markers that separate a working launch from a
# partial one:
#
#   pass   redirect-shim.log gains   origin-auth-code-issued
#   fail   the connector log gains   exited with code 0x...  (non-zero)
#   fail   redirect-shim.log gains   origin-auth-code-refused
#          (helper-declined, five seconds after origin-auth-code-pipe-request
#          begin, is proxy auto-detect -- BUGS.md §21; run --verify)
#          or repeated              origin-auth-code-sync-bridge-failed
#
# and one marker that decides nothing by itself but tells the two shapes of
# failure apart:
#
#   the client log gains  Accepted the LSX connection owned by FIFA17 pid N
#
# A launch that never logs it died without sending a single request -- the
# 2 KB wire transcript rather than the 62 KB one. A launch that logs it and
# then fails got as far as talking to Aurora, which is a different fault
# with a different cause. Every failing verdict below says which it was.
#
# Both logs are read from the marks taken before PLAY, so a previous run's
# success can never be mistaken for this one's.
smoke_mode() {
    local logs="$BOTTLE_DIR/$BOTTLE/drive_c/users/crossover/AppData/Local/Aurora17/Logs"
    local waited=0 limit="${AURORA_SMOKE_SECONDS:-120}"
    local shim="$logs/redirect-shim.log"
    local shim_mark=0 conn_before="" conn="" line=""
    local client_before="" client="" lsx=0
    # (N) so no match is empty rather than a zsh error -- "ls ... 2>/dev/null"
    # could not suppress it, because zsh fails the glob before ls ever runs --
    # and (om[1]) for the newest, which is what "ls -t | head -1" was for.
    local -a newest

    # A bottle Aurora has never run in has no Logs directory yet, and that is
    # precisely the launch worth watching -- the first one. Refusing here made
    # --smoke unusable on exactly the fresh bottle the docs tell people to make.
    # Aurora creates the directory as it starts, so wait for it instead.
    if [ ! -d "$logs" ]; then
        note "the $BOTTLE bottle has no Aurora17 logs yet -- nothing has run in it."
        say "        That is normal for a new bottle. Aurora makes them as it starts."
    fi

    # The mark. A missing shim log is a legitimate starting state -- it means
    # the shim has never loaded -- and counts as zero lines rather than an error.
    [ -f "$shim" ] && shim_mark="$(wc -l < "$shim" | tr -d ' ')" || shim_mark=0
    newest=( "$logs"/connector-*.log(Nom[1]) )
    conn_before="${newest[1]:-}"
    newest=( "$logs"/client-*.log(Nom[1]) )
    client_before="${newest[1]:-}"

    say ""
    say "Watching the $BOTTLE bottle for one launch."
    say ""
    say "    Press PLAY FIFA 17 in the Aurora17Connector now."
    say ""
    say "Waiting up to ${limit}s. Ctrl-C stops watching; it does not stop the game."
    say ""

    while [ "$waited" -lt "$limit" ]; do
        /bin/sleep 2
        waited=$((waited + 2))

        # The connector writes a new log per launch, so the newest file being a
        # different one is how we know PLAY was actually pressed.
        newest=( "$logs"/connector-*.log(Nom[1]) )
        conn="${newest[1]:-}"

        # Aurora's own client log is where the LSX handover is recorded. Only a
        # log newer than the mark counts, so a previous launch cannot lend this
        # one its success.
        newest=( "$logs"/client-*.log(Nom[1]) )
        client="${newest[1]:-}"
        if [ "$lsx" -eq 0 ] && [ -n "$client" ] && [ "$client" != "$client_before" ] \
           && [ -f "$client" ]; then
            if grep -q 'Accepted the LSX connection' "$client" 2>/dev/null; then
                lsx=1
                ok "the LSX connection was accepted -- the game is talking to Aurora"
            fi
        fi

        if [ -f "$shim" ]; then
            local now="$(wc -l < "$shim" | tr -d ' ')"
            if [ "$now" -gt "$shim_mark" ]; then
                local fresh="$(tail -n "$((now - shim_mark))" "$shim")"

                line="$(print -r -- "$fresh" | grep 'origin-auth-code-issued' | tail -1 || true)"
                if [ -n "$line" ]; then
                    say ""
                    ok "origin-auth-code-issued"
                    say "        $line"
                    say ""
                    green "PASS. The session was issued. Ultimate Team should load."
                    say ""
                    return 0
                fi

                line="$(print -r -- "$fresh" | grep 'origin-auth-code-refused' | tail -1 || true)"
                if [ -n "$line" ]; then
                    smoke_failed "the shim was refused an auth code" "$line" "$conn" "$lsx"
                    return 1
                fi

                # One of these is a launch that is still settling. Several in a
                # row is the ~19s retry loop, and it never recovers on its own.
                local n_failed="$(print -r -- "$fresh" | grep -c 'origin-auth-code-sync-bridge-failed' || true)"
                if [ "${n_failed:-0}" -ge 2 ]; then
                    line="$(print -r -- "$fresh" | grep 'origin-auth-code-sync-bridge-failed' | tail -1)"
                    smoke_failed "the auth-code bridge kept failing (${n_failed} times)" "$line" "$conn" "$lsx"
                    return 1
                fi
            fi
        fi

        # A non-zero exit from the game is decisive on its own: 0xFFFFFFFA is
        # the protector relaunching, and the connector has already given up.
        if [ -n "$conn" ] && [ "$conn" != "$conn_before" ] && [ -f "$conn" ]; then
            line="$(grep 'exited with code 0x' "$conn" | grep -v '0x00000000' | tail -1 || true)"
            if [ -n "$line" ]; then
                if [ ! -f "$(bottle_licence_file)" ]; then
                    smoke_failed "FIFA exited on its own, and this bottle has no licence file" \
                                 "$line" "$conn" "$lsx"
                else
                    smoke_failed "FIFA exited on its own" "$line" "$conn" "$lsx"
                fi
                return 1
            fi
            # A clean exit is not a pass. The game can load, patch its gate and
            # resolve a user without ever asking for an auth code -- measured on
            # 2026-09-02 16:13, where the run reached origin-default-user-result
            # and quit 0x00000000 with no pipe request in the whole session.
            # Waiting the full two minutes after the game has already gone is
            # the one outcome worse than either verdict, so end it and say how
            # far the launch actually got.
            line="$(grep 'exited with code 0x00000000' "$conn" | tail -1 || true)"
            if [ -n "$line" ]; then
                say ""
                red "INCONCLUSIVE: FIFA exited cleanly without a session being issued."
                if [ "$lsx" -eq 0 ]; then
                    say "        The LSX connection was never accepted, so the game quit"
                    say "        before reaching Aurora at all."
                fi
                say "        $line"
                say ""
                say "That is what a launch looks like when the game is closed before"
                say "Ultimate Team loads -- if you quit it yourself, this is expected"
                say "and not a fault. The last thing the shim reported was:"
                say ""
                if [ -f "$shim" ]; then
                    tail -3 "$shim" | sed 's/^/        /'
                else
                    say "        (no redirect-shim.log -- the shim never loaded)"
                fi
                say ""
                say "Run this again and let the game reach Ultimate Team before"
                say "closing it, or collect everything with:"
                say ""
                say "    AURORA_BOTTLE='$BOTTLE' ./setup.sh --bundle"
                say ""
                return 1
            fi
        fi
    done

    say ""
    if [ -z "$conn" ] || [ "$conn" = "$conn_before" ]; then
        note "nothing launched in ${limit}s -- no new connector log appeared."
        say "        PLAY was probably never pressed, or the connector did not open."
        say "        Nothing was tested. Run this again and press PLAY."
        return 1
    fi
    note "no verdict in ${limit}s. The game neither issued a session nor exited."
    if [ "$lsx" -eq 1 ]; then
        say "        The LSX connection was accepted, so the game did reach Aurora"
        say "        and is still running. It may simply be slow."
    else
        say "        The LSX connection was never accepted in that time, so the"
        say "        game has not talked to Aurora at all."
    fi
    say "        Collect everything with:  AURORA_BOTTLE='$BOTTLE' ./setup.sh --bundle"
    return 1
}

# The shared ending for every failing verdict: say which one it was, quote the
# deciding line, and point at the one command that collects the evidence.
smoke_failed() {
    local why="$1" line="$2" conn="$3" lsx="${4:-0}"
    say ""
    red "FAIL: $why."
    say "        $line"
    [ -n "$conn" ] && say "        connector log: ${conn:t}"
    say ""
    # BUGS.md §18. Said before anything else, because when it is true it is the
    # whole answer and every other line below is a distraction.
    if [ ! -f "$(bottle_licence_file)" ]; then
        say "This bottle has no EA licence file:"
        say "    $(bottle_licence_file)"
        say ""
        say "That alone explains an exit of 0xFFFFFFFA about twenty seconds in:"
        say "FIFA takes its Origin activation path, relaunches itself, and the"
        say "process the connector is watching dies. Press PLAY again -- the"
        say "launcher now makes the file first -- or seed it here with:"
        say ""
        say "    AURORA_BOTTLE='$BOTTLE' ./setup.sh --bottle"
        say ""
    fi
    # BUGS.md §21, and the same shape as the licence file above: when it is
    # true it is the whole answer. The shim waits five seconds for the auth
    # code, and a bottle with proxy auto-detect on costs the helper five
    # seconds before it makes its first request.
    case "$why" in
        *"refused an auth code"*)
            if [ -f "$(bottle_user_reg)" ] && ! proxy_autodetect_is_off; then
                say "Proxy auto-detect is on in this bottle. That alone explains a"
                say "helper-declined refusal about five seconds after"
                say "origin-auth-code-pipe-request begin: Aurora's helper spends"
                say "those five seconds looking for a proxy it does not need, and"
                say "the shim's deadline runs out first. Quit CrossOver fully and:"
                say ""
                say "    ./setup.sh"
                say ""
                say "Then check it with:  AURORA_BOTTLE='$BOTTLE' ./setup.sh --verify"
                say ""
            fi ;;
    esac
    # Which side of the handover it died on. This is sharper than the exit code
    # and it is the first thing to say, because it decides where to look next.
    if [ "$lsx" -eq 1 ]; then
        say "The LSX connection WAS accepted, so the game reached Aurora and the"
        say "fault is after the handover -- in the session, not in the launch."
    else
        say "The LSX connection was NEVER accepted: the game exited without"
        say "sending a single request. Nothing after the handover is implicated,"
        say "and the connector's own error is downstream of this, not its cause."
    fi
    say ""
    say "Everything static can still be correct here -- --verify has passed on a"
    say "bottle in exactly this state. Collect the evidence and say which step"
    say "you were on:"
    say ""
    say "    AURORA_BOTTLE='$BOTTLE' ./setup.sh --bundle"
    say ""
}

# ------------------------------------------------------ --unstick, and stop
# --------------------------------------- background cleanup (LaunchAgent)
# A 30-second safety net so the user never runs a script: while any CrossOver
# GUI runs it only records the time and exits; 45 s after the last GUI quits
# it TERM/KILLs leftover Wine + Aurora processes, frees 47170-47173/3216 and
# removes unopened server dirs. Native Mac processes are never signalled.
# Installed under ~/Library (a stable path, not this checkout) by --agent and
# by every successful full install; removed by ./uninstall.sh.
CLEANUP_LABEL=com.fifa-crossover-cleanup
CLEANUP_BASE="$HOME/Library/Application Support/FIFA-CrossOver"
CLEANUP_HELPER="$CLEANUP_BASE/cleanup"
# A session started outside CrossOver's window -- ./setup.sh --play-offline --
# has no GUI to prove it is alive, and every rule here calls a Wine process
# with no GUI behind it an orphan. So the launcher writes its own pid here for
# as long as it runs, and both the timer and --unstick leave everything alone
# while that pid is alive. A crashed launcher leaves a pid that is gone, which
# reads as no hold at all.
CLEANUP_HOLD="$CLEANUP_BASE/session-hold"
CLEANUP_PLIST="$HOME/Library/LaunchAgents/$CLEANUP_LABEL.plist"

write_cleanup_helper() {
    cat > "$CLEANUP_HELPER" <<'CLEANUP_EOF'
#!/bin/zsh
# FIFA CrossOver auto-cleanup, run by launchd every 30 s. Fail-closed: exits
# without touching anything while any CrossOver GUI runs, during the grace
# period after it quits, or when anything looks ambiguous.
set -u
BASE="$HOME/Library/Application Support/FIFA-CrossOver"
STATE="$BASE/last-gui-seen"
REPORT="$BASE/last-report"
LOG="$BASE/cleanup.log"
LOCKD="$BASE/cleanup.lock"
GRACE=45
BOTTLE_DIR="${CX_BOTTLE_PATH:-$HOME/Library/Application Support/CrossOver/Bottles}"
ALL_PORTS=47170,47171,47172,47173,3216

mkdir -p "$BASE" 2>/dev/null || exit 0
if ! mkdir "$LOCKD" 2>/dev/null; then
    age=$(($(date +%s) - $(stat -f %m "$LOCKD" 2>/dev/null || echo 0)))
    [ "$age" -gt 120 ] || exit 0
    rmdir "$LOCKD" 2>/dev/null || exit 0
    mkdir "$LOCKD" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCKD" 2>/dev/null' EXIT INT TERM

log() {
    print -r -- "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null
    tail -n 300 "$LOG" >"$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || true
}
report_throttled() {
    local now last=0
    now=$(date +%s)
    [ -f "$REPORT" ] && last="$(cat "$REPORT" 2>/dev/null || echo 0)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -gt 3600 ] || return 1
    print -r -- "$now" >"$REPORT" 2>/dev/null || true
    log "$@"
}

is_crossover_bundle() {
    local id
    id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null) || return 1
    [ "$id" = "com.codeweavers.CrossOver" ]
}
crossovers_running() {
    local app
    ps -Ao command= 2>/dev/null | grep -i crossover | grep -v grep \
        | sed -n 's|/Contents/MacOS/.*||p' | grep -E '^/.*\.app$' | sort -u \
    | while IFS= read -r app; do
        is_crossover_bundle "$app" && print -r -- "$app"
    done
    return 0
}
is_wine_command() {
    case "$1" in
        [A-Za-z]:\\*) return 0 ;;
        *wineserver*|*winewrapper.exe*|*wine-preloader*|*wine64-preloader*) return 0 ;;
    esac
    return 1
}

# Wine names a prefix's server directory after the prefix's device and inode
# in hex -- /tmp/.wine-<uid>/server-<dev>-<inode> -- so the bottles under
# BOTTLE_DIR can be turned into the exact set of directory names that belong
# to them. Everything else under /tmp/.wine-* is another Wine runtime's
# (Whisky, Wineskin, a plain wine), and "no CrossOver is open" says nothing
# about whether one of those is in the middle of a session. Those are never
# signalled and their directories are never removed.
our_server_dirs() {
    local b st
    for b in "$BOTTLE_DIR"/*(N/); do
        st="$(stat -f '%d %i' "$b" 2>/dev/null)" || continue
        [ -n "$st" ] || continue
        printf 'server-%x-%x\n' ${=st}
    done
    return 0
}
is_our_server_dir() {
    [ -n "${OUR_SERVER_DIRS:-}" ] || OUR_SERVER_DIRS="$(our_server_dirs)"
    print -r -- "$OUR_SERVER_DIRS" | grep -qx -- "${1:t}"
}

# A name match alone is not proof of ownership: a native Mac program with
# fifa17 or Aurora17Server on its command line -- a video open in QuickTime,
# an editor on a log -- must never be signalled, and the background cleanup
# signals these with nobody watching. A pid counts only if it is a Wine
# process, works inside a bottle, or holds one of our server directories.
wine_owned_pid() {
    local cmd cwd h
    cmd="$(ps -o command= -p "$1" 2>/dev/null)" || return 1
    [ -n "$cmd" ] || return 1
    is_wine_command "$cmd" && return 0
    cwd="$(/usr/sbin/lsof -a -d cwd -p "$1" -F n 2>/dev/null | sed -n 's/^n//p' | head -1)"
    [ "$cwd" = "$BOTTLE_DIR" ] || [ "${cwd#"$BOTTLE_DIR"/}" != "$cwd" ] && return 0
    for h in ${(f)"$(/usr/sbin/lsof -p "$1" -F n 2>/dev/null \
            | sed -n 's|^n.*/\.wine-[^/]*/\(server-[^/]*\)/.*|\1|p' | sort -u)"}; do
        [ -n "$h" ] && is_our_server_dir "$h" && return 0
    done
    return 1
}
live_server_dirs() {
    local d
    for d in /tmp/.wine-*/server-*(N/); do
        /usr/sbin/lsof +D "$d" -F c 2>/dev/null | grep -q '^cwineserver' \
            && print -r -- "${d%/}"
    done
    return 0
}
wine_pids() {
    local live pid ppid cmd cwd held h; local -a ours
    live="$(live_server_dirs)"
    ps -Ao pid=,ppid=,command= 2>/dev/null | while read -r pid ppid cmd; do
        is_wine_command "$cmd" || continue
        cwd="$(/usr/sbin/lsof -a -d cwd -p "$pid" -F n 2>/dev/null | sed -n 's/^n//p' | head -1)"
        held="$(/usr/sbin/lsof -p "$pid" -F n 2>/dev/null \
                | sed -n 's|^n.*/\.wine-[^/]*/\(server-[^/]*\)/.*|\1|p' | sort -u)"
        ours=()
        for h in ${(f)held}; do
            [ -n "$h" ] && is_our_server_dir "$h" && ours+=( "$h" )
        done
        held="${(F)ours}"
        if [ "$cwd" != "$BOTTLE_DIR" ] && [ "${cwd#"$BOTTLE_DIR"/}" = "$cwd" ] && [ -z "$held" ]; then
            case "$cmd" in *wineserver*) ;; (*) continue ;; esac
        fi
        print -r -- "$pid"
    done
    return 0
}
game_pids() {
    local p
    for p in ${(f)"$(ps -Ao pid=,command= 2>/dev/null \
        | grep -Ei '(fifa1[57]|Aurora1[57](Connector|Client|Server|Launcher))' \
        | grep -v grep | grep -v 'setup\.sh' | awk '{print $1}')"}; do
        [ -n "$p" ] || continue
        wine_owned_pid "$p" && print -r -- "$p"
    done
    return 0
}
wineserver_pids() {
    ps -Ao pid=,command= 2>/dev/null \
        | grep -F 'SharedSupport/CrossOver' | grep -w 'wineserver' \
        | grep -v grep | awk '{print $1}'
    return 0
}
stale_wine_sockets() {
    local d
    for d in /tmp/.wine-*/server-*(N/); do
        is_our_server_dir "$d" || continue
        [ -n "$(/usr/sbin/lsof +D "$d" -F p 2>/dev/null | grep '^p')" ] \
            || print -r -- "$d"
    done
}
require_quiet() {
    local hp
    if [ -f "$BASE/session-hold" ]; then
        hp="$(cat "$BASE/session-hold" 2>/dev/null || true)"
        case "$hp" in ''|*[!0-9]*) ;; *) kill -0 "$hp" 2>/dev/null && return 1 ;; esac
    fi
    [ -z "$(crossovers_running)" ]
}
kill_pids() {
    local sig="$1"; shift
    local waited=0 P; local -a left
    kill "-$sig" "$@" 2>/dev/null || true
    while [ "$waited" -lt 10 ]; do
        left=()
        for P in "$@"; do kill -0 "$P" 2>/dev/null && left+=( "$P" ); done
        [ "${#left}" -eq 0 ] && return 0
        /bin/sleep 1
        waited=$((waited + 1))
    done
    left=()
    for P in "$@"; do kill -0 "$P" 2>/dev/null && left+=( "$P" ); done
    [ "${#left}" -eq 0 ]
}

# A game started outside the GUI holds this file for as long as its launcher
# runs. It is the one thing that makes a GUI-less Wine session legitimate, so
# it is checked before anything else and treated exactly like a running GUI.
HOLD="$BASE/session-hold"
if [ -f "$HOLD" ]; then
    HP="$(cat "$HOLD" 2>/dev/null || true)"
    case "$HP" in
        ''|*[!0-9]*) rm -f "$HOLD" 2>/dev/null || true ;;
        *) if kill -0 "$HP" 2>/dev/null; then
               print -r -- "$(date +%s)" >"$STATE" 2>/dev/null || true
               exit 0
           else
               rm -f "$HOLD" 2>/dev/null || true
           fi ;;
    esac
fi

now=$(date +%s)
if [ -n "$(crossovers_running)" ]; then
    print -r -- "$now" >"$STATE" 2>/dev/null || true
    exit 0
fi
last=0
[ -f "$STATE" ] && last="$(cat "$STATE" 2>/dev/null || echo 0)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ $((now - last)) -ge "$GRACE" ] || exit 0

ALL=( ${(f)"$(wine_pids)"} ${(f)"$(game_pids)"} )
ALL=( ${(u)ALL:#} )
WS=( ${(f)"$(wineserver_pids)"} )
WS=( ${WS:#} )
CLIENTS=()
for P in ${ALL}; do
    [ -n "$P" ] || continue
    [ "${WS[(I)$P]}" -gt 0 ] || CLIENTS+=( "$P" )
done
STALE=( ${(f)"$(stale_wine_sockets)"} )
STALE=( ${STALE:#} )
PORTS="$(/usr/sbin/lsof -nP -iTCP:$ALL_PORTS -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | tr '\n' ' ')"
PORTS="${PORTS% }"
[ "${#CLIENTS}" -gt 0 ] || [ "${#WS}" -gt 0 ] || [ "${#STALE}" -gt 0 ] || [ -n "$PORTS" ] || exit 0

log "cleanup: ${#CLIENTS} client(s), ${#WS} wineserver(s), ${#STALE} stale dir(s), port holder pid(s): ${PORTS:-none}"
if [ "${#CLIENTS}" -gt 0 ]; then
    require_quiet || exit 0
    kill_pids TERM ${CLIENTS} || { require_quiet || exit 0; kill_pids KILL ${CLIENTS} || log "client(s) would not close: ${CLIENTS}"; }
fi
if [ "${#WS}" -gt 0 ]; then
    require_quiet || exit 0
    kill_pids TERM ${WS} || { require_quiet || exit 0; kill_pids KILL ${WS} || log "wineserver(s) would not close: ${WS}"; }
fi
require_quiet || exit 0
STALE=( ${(f)"$(stale_wine_sockets)"} )
STALE=( ${STALE:#} )
for D in ${STALE}; do rm -rf "$D" 2>/dev/null || true; done
[ "${#STALE}" -gt 0 ] && log "removed ${#STALE} stale wineserver director$([ ${#STALE} -eq 1 ] && print -n y || print -n ies)"
LEFTPORTS="$(/usr/sbin/lsof -nP -iTCP:$ALL_PORTS -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | tr '\n' ' ')"
LEFTPORTS="${LEFTPORTS% }"
if [ -n "$LEFTPORTS" ]; then
    for P in ${(f)"$(print -r -- "$LEFTPORTS" | tr ' ' '\n')"}; do
        [ -n "$P" ] || continue
        require_quiet || exit 0
        C="$(ps -o command= -p "$P" 2>/dev/null)"
        if is_wine_command "$C"; then
            kill -9 "$P" 2>/dev/null || true
            log "freed port holder $P (${C[1,80]})"
        else
            report_throttled "native holder on Aurora ports left alone: $P ${C[1,80]}" || true
        fi
    done
fi
DONE_PORTS="$(/usr/sbin/lsof -nP -iTCP:$ALL_PORTS -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | tr '\n' ' ')"
[ -z "${DONE_PORTS% }" ] && log "ports free: $ALL_PORTS"
exit 0
CLEANUP_EOF
    chmod +x "$CLEANUP_HELPER" 2>/dev/null || return 1
    zsh -n "$CLEANUP_HELPER" 2>/dev/null || return 1
}

write_cleanup_plist() {
    {
        print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
        print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        print -r -- '<plist version="1.0"><dict>'
        print -r -- "<key>Label</key><string>$CLEANUP_LABEL</string>"
        print -r -- '<key>ProgramArguments</key><array>'
        print -r -- '<string>/bin/zsh</string>'
        print -r -- "<string>$CLEANUP_HELPER</string>"
        print -r -- '</array>'
        print -r -- '<key>StartInterval</key><integer>30</integer>'
        print -r -- '<key>ProcessType</key><string>Background</string>'
        print -r -- '<key>LimitLoadToSessionType</key><string>Aqua</string>'
        print -r -- '</dict></plist>'
    } > "$CLEANUP_PLIST" || return 1
    plutil -lint "$CLEANUP_PLIST" >/dev/null 2>&1 || return 1
}

install_cleanup_agent() {
    mkdir -p "$CLEANUP_BASE" "$CLEANUP_PLIST:h" 2>/dev/null || {
        note "could not create the background-cleanup folders; skipping it"
        return 1
    }
    write_cleanup_helper || {
        note "could not write the background-cleanup helper; skipping it"
        return 1
    }
    write_cleanup_plist || {
        note "could not write the background-cleanup timer; skipping it"
        return 1
    }
    launchctl bootout "gui/$UID/$CLEANUP_LABEL" 2>/dev/null || true
    if launchctl bootstrap "gui/$UID" "$CLEANUP_PLIST" 2>/dev/null; then
        ok "background cleanup on: strays + held ports clear by themselves"
        say "        log at ${CLEANUP_BASE:t}/cleanup.log; remove with ./uninstall.sh"
    else
        note "could not start the background cleanup; run ./setup.sh --agent again"
        return 1
    fi
}

if [ "$MODE" = agent ]; then
    say ""
    say "Installing the background cleanup"
    say ""
    install_cleanup_agent || exit $E_PERMISSION
    say ""
    exit 0
fi

# Frees a bottle whose Wine session outlived its wineserver -- see the comment
# on prefix_holders for what that state is and how it looks from outside. One
# rule makes this safe to do bluntly: with every CrossOver quit, anything still
# inside the prefix is by definition an orphan, because nothing is left that
# could legitimately be using it.
hold_pid_alive() {
    local hp
    [ -f "$CLEANUP_HOLD" ] || return 1
    hp="$(cat "$CLEANUP_HOLD" 2>/dev/null || true)"
    case "$hp" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$hp" 2>/dev/null
}

if [ "$MODE" = unstick ] || [ "$MODE" = shutdown ]; then
if hold_pid_alive; then
    say ""
    note "a game started by ./setup.sh --play-offline is still running"
    say "        (pid $(cat "$CLEANUP_HOLD" 2>/dev/null)). Quit FIFA first, or close"
    say "        the terminal window it is running in, then run this again."
    say "        Nothing has been touched."
    exit $E_PERMISSION
fi
if [ "$MODE" = shutdown ]; then
    say ""
    say "Quitting CrossOver cleanly (games first, then wineservers, then the GUI)"
    say ""
    GAMESHUT=( ${(f)"$(game_leftovers)"} )
    GAMESHUT=( ${GAMESHUT:#} )
    if [ "${#GAMESHUT}" -gt 0 ]; then
        say "  stopping ${#GAMESHUT} game/Aurora process(es) first:"
        ps -o pid=,etime=,command= -p "${(j:,:)GAMESHUT}" 2>/dev/null | sed 's/^/        /' || true
        kill -TERM ${GAMESHUT} 2>/dev/null || true
        WAITED=0
        while [ "$WAITED" -lt 10 ]; do
            LEFT=()
            for P in ${GAMESHUT}; do kill -0 "$P" 2>/dev/null && LEFT+=( "$P" ); done
            [ "${#LEFT}" -eq 0 ] && break
            /bin/sleep 1
            WAITED=$((WAITED + 1))
        done
    fi
    say "  asking each bottle's wineserver to exit (flushes the registry):"
    shutdown_wineservers
    if ! quit_crossovers_gui; then
        RUNNING="$(crossovers_running)"
        say "  CrossOver is still open:"
        print -r -- "$RUNNING" | sed 's/^/        /'
        die $E_PERMISSION "CrossOver would not quit. Force Quit it: Apple menu >
         Force Quit, or hold Option and right-click its Dock icon -- then run
         ./setup.sh --unstick. Nothing has been killed yet."
    fi
    ok "CrossOver has quit"
    say ""
    say "Freeing every CrossOver bottle"
    say ""
    ok "no CrossOver is running"
else
    say ""
    say "Freeing every CrossOver bottle"
    say ""
    RUNNING="$(crossovers_running)"
    if [ -n "$RUNNING" ]; then
        say "  CrossOver is still open:"
        print -r -- "$RUNNING" | sed 's/^/        /'
        die $E_PERMISSION "Quit CrossOver completely -- Command-Q, not just closing the
         window -- and run this again. If it is not responding (a bottle that
         spins and a window that will not close), Force Quit it: Apple menu >
         Force Quit, or hold Option and right-click its Dock icon. Or run
         ./setup.sh --shutdown and this quits it for you.
         Nothing has been touched."
    fi
    ok "no CrossOver is running"
    # No GUI owns any session now, but an orphaned wineserver still holds its
    # server-* dir, which keeps every client looking "live" (and holding
    # 47170-47173/3216) forever. Shut the wineservers down first so the scan
    # below sees the truth. Registry is flushed by the -k request itself.
    shutdown_wineservers
fi

    FOUND=( ${(f)"$(wine_leftovers)"} )
    FOUND=( ${FOUND:#} )
    HOLDING=()
    LIVE=()
    for L in ${FOUND}; do
        case "${${(s:	:)L}[2]}" in
            orphan) HOLDING+=( "${${(s:	:)L}[1]}" ) ;;
            live)   LIVE+=( "$L" ) ;;
        esac
    done
    if [ "${#LIVE}" -gt 0 ]; then
        say "  ${#LIVE} process(es) were attached to a wineserver -- shutting those down below:"
        for L in ${LIVE}; do
            print -r -- "        ${${(s:	:)L}[1]}  ${${(s:	:)L}[3]}"
        done
    fi
    if [ "${#HOLDING}" -eq 0 ]; then
        ok "nothing was holding any bottle"
    else
        say "  ${#HOLDING} leftover process(es) with no wineserver behind them:"
        ps -o pid=,etime=,command= -p "${(j:,:)HOLDING}" 2>/dev/null \
            | sed 's/^/        /' || true
        # Ask first. A wineserver that is somehow still alive flushes the
        # registry on the way out, and losing that is the whole point of this.
        kill -TERM ${HOLDING} 2>/dev/null || true
        WAITED=0
        while [ "$WAITED" -lt 10 ]; do
            LEFT=()
            for P in ${HOLDING}; do kill -0 "$P" 2>/dev/null && LEFT+=( "$P" ); done
            [ "${#LEFT}" -eq 0 ] && break
            /bin/sleep 1
            WAITED=$((WAITED + 1))
        done
        [ "${#LEFT}" -eq 0 ] || kill -KILL ${LEFT} 2>/dev/null || true
        /bin/sleep 1
        LEFT=()
        for P in ${HOLDING}; do kill -0 "$P" 2>/dev/null && LEFT+=( "$P" ); done
        [ "${#LEFT}" -eq 0 ] \
            && ok "cleared ${#HOLDING} process(es)" \
            || die $E_PERMISSION "${#LEFT} process(es) would not close. Restart the Mac and
         run this again -- nothing else here can free the bottle."
    fi

    # The lock these leave behind outlives them, and CrossOver waits on it just
    # the same. Only ever the ones nobody has open.
    STALE=( ${(f)"$(stale_wine_sockets)"} )
    STALE=( ${STALE:#} )
    if [ "${#STALE}" -eq 0 ]; then
        ok "no abandoned wineserver directories"
    else
        for D in ${STALE}; do rm -rf "$D" 2>/dev/null || true; done
        ok "removed ${#STALE} abandoned wineserver director$([ ${#STALE} -eq 1 ] && print -n y || print -n ies)"
    fi

    # Free any lingering network ports (47170-47173)
    local port_pids
    port_pids="$(/usr/sbin/lsof -nP -iTCP:47170,47171,47172,47173 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | tr '\n' ' ')"
    port_pids="${port_pids% }"
    if [ -n "$port_pids" ]; then
        kill -9 ${(z)port_pids} 2>/dev/null || true
        ok "freed Aurora ports 47170-47173 (terminated PID: $port_pids)"
    else
        ok "no lingering processes on Aurora ports 47170-47173"
    fi

    # Second pass: whatever the graceful shutdown left -- a wineserver that
    # ignored -k, clients that outlived it, a game that lost its server dir
    # (FIFA frozen at the flag) still sitting on 3216. No GUI is running, so
    # by the rule above every remaining Wine process is an orphan, live or
    # not. Native Mac processes on the ports are still never touched.
    REMAIN=( ${(f)"$(wine_leftovers)"} )
    REMAIN=( ${REMAIN:#} )
    for P in ${(f)"$(game_leftovers)"}; do
        [ -n "$P" ] || continue
        print -r -- "${(F)REMAIN}" | grep -q "^${P}[[:space:]]" && continue
        REMAIN+=( "${P}"$'\t'"orphan"$'\t'"$(ps -o command= -p "$P" 2>/dev/null)" )
    done
    for P in ${(f)"$(wineserver_pids)"}; do
        [ -n "$P" ] || continue
        print -r -- "${(F)REMAIN}" | grep -q "^${P}[[:space:]]" && continue
        REMAIN+=( "${P}"$'\t'"orphan"$'\t'"$(ps -o command= -p "$P" 2>/dev/null)" )
    done
    if [ "${#REMAIN}" -gt 0 ]; then
        RMPIDS=()
        for L in ${REMAIN}; do RMPIDS+=( "${${(s:	:)L}[1]}" ); done
        say "  ${#RMPIDS} leftover process(es) after the clean shutdown:"
        ps -o pid=,etime=,command= -p "${(j:,:)RMPIDS}" 2>/dev/null | sed 's/^/        /' || true
        kill -TERM ${RMPIDS} 2>/dev/null || true
        WAITED=0
        while [ "$WAITED" -lt 10 ]; do
            LEFT=()
            for P in ${RMPIDS}; do kill -0 "$P" 2>/dev/null && LEFT+=( "$P" ); done
            [ "${#LEFT}" -eq 0 ] && break
            /bin/sleep 1
            WAITED=$((WAITED + 1))
        done
        [ "${#LEFT}" -eq 0 ] || kill -KILL ${LEFT} 2>/dev/null || true
        /bin/sleep 1
        LEFT=()
        for P in ${RMPIDS}; do kill -0 "$P" 2>/dev/null && LEFT+=( "$P" ); done
        [ "${#LEFT}" -eq 0 ] \
            && ok "cleared ${#RMPIDS} process(es)" \
            || die $E_PERMISSION "${#LEFT} process(es) would not close. Restart the Mac and
         run this again -- nothing else here can free the bottle."
        STALE2=( ${(f)"$(stale_wine_sockets)"} )
        STALE2=( ${STALE2:#} )
        for D in ${STALE2}; do rm -rf "$D" 2>/dev/null || true; done
        [ "${#STALE2}" -gt 0 ] && ok "removed ${#STALE2} abandoned wineserver director$([ ${#STALE2} -eq 1 ] && print -n y || print -n ies) freed by the second pass"
    fi
    FINALPORTS="$(/usr/sbin/lsof -nP -iTCP:$ALL_PORTS -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | tr '\n' ' ')"
    FINALPORTS="${FINALPORTS% }"
    if [ -n "$FINALPORTS" ]; then
        STILLWINE=(); STILLOTHER=()
        for P in ${(f)"$(print -r -- "$FINALPORTS" | tr ' ' '\n')"}; do
            [ -n "$P" ] || continue
            C="$(ps -o command= -p "$P" 2>/dev/null)"
            if is_wine_command "$C"; then STILLWINE+=( "$P" ); else STILLOTHER+=( "$P  ${C[1,70]}" ); fi
        done
        [ "${#STILLWINE}" -gt 0 ] && kill -9 ${STILLWINE} 2>/dev/null || true
        LEFT2="$(/usr/sbin/lsof -nP -iTCP:$ALL_PORTS -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | tr '\n' ' ')"
        if [ -z "${LEFT2% }" ]; then
            ok "all Aurora ports ($ALL_PORTS) are free"
        else
            say "  still held after everything Wine was killed: $LEFT2"
            for C in ${STILLOTHER}; do print -r -- "        $C"; done
            say "        A native Mac program holds it -- quit that program itself."
        fi
    else
        ok "all Aurora ports ($ALL_PORTS) are free"
    fi

    say ""
    say "The bottles are free. Open CrossOver again."
    say ""
    exit 0
fi

if [ "$MODE" = report ]; then
    if [ ! -d "$TARGET" ] && [ "$TARGET_EXPLICIT" = 0 ] \
       && [ -d "$HOME/Applications/${TARGET:t}" ]; then
        TARGET="$HOME/Applications/${TARGET:t}"
    fi
    [ -d "$TARGET" ] || die $E_PAYLOAD "Nothing to report on at $TARGET.
         Run ./setup.sh first. If the copy is somewhere else:
             AURORA_TARGET=/path/to/CrossOver-FIFA.app ./setup.sh --report"
    report_mode "$TARGET"
    exit 0
fi

if [ "$MODE" = bundle ]; then
    if [ ! -d "$TARGET" ] && [ "$TARGET_EXPLICIT" = 0 ] \
       && [ -d "$HOME/Applications/${TARGET:t}" ]; then
        TARGET="$HOME/Applications/${TARGET:t}"
    fi
    [ -d "$TARGET" ] || die $E_PAYLOAD "Nothing to report on at $TARGET.
         Run ./setup.sh first. If the copy is somewhere else:
             AURORA_TARGET=/path/to/CrossOver-FIFA.app ./setup.sh --bundle"
    bundle_mode "$TARGET" || exit $E_PERMISSION
    exit 0
fi

# A bottle made after the fixes were installed has none of the bottle-side
# work, and its shortcuts start whichever CrossOver created it. That is the
# normal state after making a fresh bottle, which is the cure for a prefix
# that has gone bad -- so it needs to be one command, not a re-install.
if [ "$MODE" = bottle ]; then
    if [ ! -d "$TARGET" ] && [ "$TARGET_EXPLICIT" = 0 ] \
       && [ -d "$HOME/Applications/${TARGET:t}" ]; then
        TARGET="$HOME/Applications/${TARGET:t}"
    fi
    [ -d "$TARGET" ] \
        || die $E_PAYLOAD "No patched CrossOver at $TARGET.
         Run ./setup.sh first. If the copy is somewhere else:
             AURORA_TARGET=/path/to/CrossOver-FIFA.app ./setup.sh --bottle"
    [ -d "$BOTTLE_DIR/$BOTTLE" ] \
        || die $E_UNSUPPORTED "There is no bottle called '$BOTTLE' at
         $BOTTLE_DIR
         Make it in CrossOver first, then run this again. For another
         name:   AURORA_BOTTLE='name' ./setup.sh --bottle"
    say ""
    say "Setting up the $BOTTLE bottle for ${TARGET:t}"
    configure_bottle "$TARGET"
    say ""
    if [ "$BOTTLE_OK" = 1 ] && [ "$PS_OK" = 1 ] && [ "$HOSTS_OK" = 1 ]; then
        green "Done. Open ${TARGET:t:r}, then Aurora17Connector in the $BOTTLE bottle."
        say ""
        say "To check:  AURORA_BOTTLE='$BOTTLE' ./setup.sh --verify"
        say ""
        exit 0
    fi
    red "NOT FINISHED — see the lines above."
    say ""
    exit $E_INCOMPLETE
fi

# Starts FIFA 17 the way an offline install has to: the game's own loader,
# _fifa17.exe, run in the bottle through the patched copy. That is exactly what
# seed_bottle_licence does to write the licence file, and what Aurora's PLAY
# ends up doing after its own work. Nothing here listens on a port or talks to
# EA, so single player is all of it.
if [ "$MODE" = offline-menu ]; then
    [ -d "$TARGET" ] || die $E_INCOMPLETE "There is no $TARGET yet.
         Run  ./setup.sh --offline  first."
    install_offline_menu "$TARGET" || exit $E_INCOMPLETE
    say ""
    exit 0
fi

if [ "$MODE" = play-offline ]; then
    say ""
    say "Starting FIFA 17 (offline)"
    say ""
    [ -d "$TARGET" ] || die $E_INCOMPLETE "There is no $TARGET yet.
         Run  ./setup.sh --offline  first (or double-click START HERE offline)."
    [ -d "$BOTTLE_DIR/$BOTTLE" ] \
        || die $E_UNSUPPORTED "There is no bottle called '$BOTTLE' at
         $BOTTLE_DIR
         For another name:  AURORA_BOTTLE='name' ./setup.sh --play-offline"
    GDIR="$(game_dir_find 2>/dev/null || true)"
    # See install_offline_menu: resolve the bottle's dosdevices links first.
    [ -n "$GDIR" ] && GDIR="${GDIR:A}"
    [ -n "$GDIR" ] || die $E_INCOMPLETE "No FIFA 17 folder with _fifa17.exe in it was found.
         For a game kept elsewhere:
           AURORA_GAME_DIR='/path/to/FIFA 17' ./setup.sh --play-offline"
    GWIN="$(unix_path_to_win "$GDIR" 2>/dev/null || true)"
    [ -n "$GWIN" ] || die $E_INCOMPLETE "The $BOTTLE bottle has no drive letter for
         $GDIR
         Add one in CrossOver (Bottle > Control Panel > Drives), then try again."
    PWINE="$TARGET/Contents/SharedSupport/CrossOver/bin/wine"
    [ -x "$PWINE" ] || die $E_PAYLOAD "$TARGET is incomplete (no wine inside it).
         Run ./setup.sh --offline again."
    mkdir -p "$CLEANUP_BASE" 2>/dev/null || true
    print -r -- "$$" > "$CLEANUP_HOLD" 2>/dev/null || true
    # Closing the window (or Control-C) stops the game this started, which is
    # what the launcher's text promises. On a normal end the game has already
    # gone and stop_bottle_game does nothing. Only pids inside this bottle
    # running FIFA 17 are ever signalled -- see bottle_game_pids.
    trap 'rm -f "$CLEANUP_HOLD" 2>/dev/null; stop_bottle_game >/dev/null 2>&1' EXIT INT TERM
    ok "game folder: $GDIR"
    ok "bottle:      $BOTTLE"
    say ""
    say "The game window takes a moment. This terminal stays open while it runs;"
    say "quitting FIFA closes it. Online, FUT and anything needing an EA account"
    say "are not available in an offline install."
    say ""
    "$PWINE" --bottle "$BOTTLE" --workdir "$GDIR" --cx-app "$GWIN\\_fifa17.exe" &
    WPID=$!
    # CrossOver's wine wrapper returns as soon as it has started the program --
    # it forwards --wait-children only when asked -- so waiting on that pid is
    # not waiting for the game. Watch the bottle instead. This matters for more
    # than a tidy exit code: the hold file below is what tells the background
    # cleanup that a Wine session with no CrossOver window is deliberate, and
    # letting this script exit while the game is up would hand the game to the
    # cleanup as a stray 45 seconds later.
    WAITED=0
    while [ "$WAITED" -lt 90 ] && [ -z "$(game_leftovers)" ]; do
        /bin/sleep 1
        WAITED=$((WAITED + 1))
    done
    if [ -z "$(game_leftovers)" ]; then
        wait "$WPID" 2>/dev/null || true
        say ""
        note "FIFA 17 did not appear within ${WAITED}s."
        say "        If it started and closed again, the bottle is probably missing"
        say "        its licence file: run  ./setup.sh --verify , which says so."
        exit $E_INCOMPLETE
    fi
    ok "FIFA 17 is running — leave this window open while you play"
    while [ -n "$(game_leftovers)" ]; do
        # Touching the hold keeps it obviously current for anyone reading it.
        print -r -- "$$" > "$CLEANUP_HOLD" 2>/dev/null || true
        /bin/sleep 5
    done
    wait "$WPID" 2>/dev/null || true
    say ""
    ok "FIFA 17 closed"
    exit 0
fi

if [ "$MODE" = smoke ]; then
    [ -d "$BOTTLE_DIR/$BOTTLE" ] \
        || die $E_UNSUPPORTED "There is no bottle called '$BOTTLE' at
         $BOTTLE_DIR
         For another name:  AURORA_BOTTLE='name' ./setup.sh --smoke"
    smoke_mode || exit $E_INCOMPLETE
    exit 0
fi

if [ "$MODE" = verify ]; then
    if [ ! -d "$TARGET" ] && [ "$TARGET_EXPLICIT" = 0 ] \
       && [ -d "$HOME/Applications/${TARGET:t}" ]; then
        TARGET="$HOME/Applications/${TARGET:t}"
    fi
    verify_install "$TARGET" || exit $E_INCOMPLETE
    exit 0
fi

# ------------------------------------------------------- --resign, and stop
# Repairs the signature on a CrossOver-FIFA that already exists. Signing is the
# one step that can leave the app unable to open at all, and re-copying a
# gigabyte to redo it would be absurd.
if [ "$MODE" = resign ]; then
    if [ ! -d "$TARGET" ] && [ "$TARGET_EXPLICIT" = 0 ]; then
        TARGET="$HOME/Applications/${TARGET:t}"
    fi
    [ -d "$TARGET" ] || die $E_PAYLOAD "No CrossOver-FIFA to re-sign at $TARGET.
         If yours is somewhere else:
             AURORA_TARGET=/path/to/CrossOver-FIFA.app ./setup.sh --resign"
    is_crossover_bundle "$TARGET" \
        || die $E_PAYLOAD "$TARGET is not a CrossOver bundle. Refusing to sign it.
         If the copy is somewhere else:
             AURORA_TARGET=/path/to/CrossOver-FIFA.app ./setup.sh --resign"
    say ""
    say "Re-signing $TARGET"
    say ""
    require_clt
    # An install made by an older copy of this package has no resolver in it,
    # and signing a file that is not there would stop with "the copy is
    # incomplete". Put it in first: it is two small operations, and --resign is
    # what SETUP.md sends people to when something is missing.
    RESIGN_WINE="$TARGET/Contents/SharedSupport/CrossOver/lib/wine"
    if [ ! -f "$RESIGN_WINE/$RESOLVER" ]; then
        cp -X "$HERE/fixes/$RESOLVER" "$RESIGN_WINE/$RESOLVER" \
            || die $E_PERMISSION "Could not install ${RESOLVER:t} into $TARGET.
$APP_MGMT_HINT"
        ok "added ${RESOLVER:t}"
    fi
    if ! ws2_32_is_patched "$RESIGN_WINE"; then
        install_name_tool -change "$LIBSYSTEM" "$RESOLVER_PATH" \
            "$RESIGN_WINE/x86_64-unix/ws2_32.so" 2>/dev/null \
            || die $E_PERMISSION "Could not point ws2_32.so at ${RESOLVER:t}.
$APP_MGMT_HINT"
        ok "pointed ws2_32.so at the bottle's hosts file"
    fi
    # Re-signing changes the signature, and nothing else. It cannot turn a
    # stock or dev-tree file into the fixed one -- it will happily sign the
    # wrong file and report "Done.", which is how a morning went in September
    # 2026: the same app "repaired" three times and broken every time. So the
    # payload has to be the payload before anything is signed. The .dll files
    # are installed unchanged and compare byte for byte; the .so files are
    # rpath-edited and signed after installation, so LC_UUID identifies them
    # and a checksum never can.
    local rf; local -a wrongfiles
    wrongfiles=()
    if ! ( cd "$HERE/fixes" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1; then
        die $E_PAYLOAD "fixes/ does not match its own checksums.
         This copy of the package is damaged, so there is nothing safe to
         compare against. Download it again."
    fi
    for rf in $FILES; do
        if [ ! -f "$RESIGN_WINE/$rf" ]; then
            wrongfiles+=( "${rf:t} (missing)" ); continue
        fi
        case "$rf" in
        *.dll) cmp -s "$HERE/fixes/$rf" "$RESIGN_WINE/$rf"                    || wrongfiles+=( "${rf:t}" ) ;;
        *.so)  [ "$(macho_uuid "$RESIGN_WINE/$rf")" = "$(macho_uuid "$HERE/fixes/$rf")" ]                    || wrongfiles+=( "${rf:t}" ) ;;
        esac
    done
    if [ "${#wrongfiles}" -ne 0 ]; then
        say ""
        die $E_PAYLOAD "these files in $TARGET are not the fixed versions:
             ${(j:, :)wrongfiles}
         --resign only replaces a signature. Signing these would leave the
         app broken in exactly the same way and tell you it was repaired,
         so nothing has been signed.
         Run  ./setup.sh  to install the right files first, then --resign
         only if the signature is still the problem."
    fi
    ok "the installed files are the fixed versions"

    sign_payload "$RESIGN_WINE"
    resign_app "$TARGET"
    say ""
    green "Done. Open ${TARGET:t:r} again."
    say ""
    exit 0
fi

# =========================================================================
# Preflight. Everything that can say no has to say it before anything is
# deleted or copied -- a corrupt download must not be able to destroy a
# working install and then stop half way through.
# =========================================================================
say ""
say "1. Checking"

case "$(uname -s)" in
    Darwin) ;;
    *) die $E_UNSUPPORTED "These fixes are for macOS. There is nothing to run here." ;;
esac
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ] \
    || die $E_UNSUPPORTED "These fixes are for Apple silicon Macs (M1 or newer).
         The replacement files are built for that and nothing else, so there
         is nothing to do on this Mac."
OSVER="$(sw_vers -productVersion)"
case "$OSVER" in
    1[0-3].*|[0-9].*) die $E_UNSUPPORTED "These fixes need macOS 14 or newer. You have $OSVER.
         Update macOS (System Settings > General > Software Update), then
         run this again." ;;
esac
ok "macOS $OSVER on Apple silicon"
require_clt

[ -d "$SRC" ] || die $E_PAYLOAD "No CrossOver at $SRC.
         Install CrossOver 26.3, or if yours is somewhere else, run:
             ./setup.sh /path/to/CrossOver.app"
is_crossover_bundle "$SRC" \
    || die $E_PAYLOAD "$SRC is not a CrossOver application.
         Point this at the real one:  ./setup.sh /path/to/CrossOver.app"

# 26.3* would also accept 26.30 and 26.3-beta, which are not what these files
# were built against.
VER="$(crossover_version "$SRC")"
[ "$VER" = "26.3" ] || die $E_PAYLOAD "These fixes are built for CrossOver 26.3 exactly. You have $VER.
         Installing them into a different version will not work.
         Either install CrossOver 26.3, or rebuild these files against the
         version you have: patches/README lists the four patches, and
         ./build.sh /path/to/crossover-sources-<version>.tar.gz applies them.
         Both ship alongside this script."
ok "CrossOver $VER at $SRC"

SRCWINE="$SRC/Contents/SharedSupport/CrossOver/lib/wine"
for f in $FILES; do
    [ -f "$SRCWINE/$f" ] \
        || die $E_PAYLOAD "$f is missing from $SRC. That is not a complete CrossOver 26.3.
         Reinstall CrossOver 26.3 from codeweavers.com, then run this again."
done
[ -f "$SRCWINE/x86_64-unix/ws2_32.so" ] \
    || die $E_PAYLOAD "ws2_32.so is missing from $SRC. That is not a complete CrossOver 26.3.
         Reinstall CrossOver 26.3 from codeweavers.com, then run this again."
ok "all six files present in CrossOver, and the ws2_32.so we edit"

# Keeping CrossOver's own permissions is the one step with nothing to fall back
# on, and it runs at the very end -- after 2 GB has been copied and six files
# replaced. Read them from the original now, while nothing has happened yet, so
# a CrossOver that cannot supply them stops here instead of there.
PRE_ENT="$(mktemp -t cxpre).plist"
read_entitlements "$SRC" "$PRE_ENT" && PRE_RC=0 || PRE_RC=$?
if [ "$PRE_RC" -eq 0 ]; then
    ok "CrossOver's own permissions can be read and kept"
else
    note "cannot read the permissions on $SRC -- $(ent_reason "$PRE_RC")"
    write_stock_entitlements "$PRE_ENT" \
        || die $E_UNSUPPORTED "Cannot read $SRC's permissions and cannot write a
         replacement list either. Nothing has been changed.
         Check there is free disk space, then run this again."
    note "the four CrossOver 26.3 ships with will be used instead"
    say "        microphone, camera and Apple Events will still work"
fi
rm -f "$PRE_ENT"

# Verify the payload we are about to install before touching anything, not
# after the working copy has already been deleted.
( cd "$HERE/fixes" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1 \
    || die $E_PAYLOAD "The files in fixes/ do not match their checksums.
         Do not install these. Download the package again and re-extract it."
( cd "$HERE/aurora17" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1 \
    || die $E_PAYLOAD "The files in aurora17/ do not match their checksums.
         Do not install these. Download the package again and re-extract it."
ok "the files to install match their checksums"

if [ "$IN_PLACE" != "1" ]; then
    assert_safe_target "$TARGET"
    [ "${SRC:A}" != "${TARGET:A}" ] \
        || die $E_UNSUPPORTED "The source and the copy are the same app:
             $SRC
         Pass the real CrossOver as the source, or set AURORA_TARGET to a
         different path."

    # /Applications is normal but is not writable on every Mac. Fall back to
    # ~/Applications only when the caller did not name the target themselves;
    # an explicit path that cannot be created is an error, not an invitation
    # to create a different one and later delete it.
    PROBE_DIR="$(mktemp -d "${TARGET:h}/.aurora17-probe.XXXXXX" 2>/dev/null || true)"
    if [ -z "$PROBE_DIR" ]; then
        if [ "$TARGET_EXPLICIT" = 1 ]; then
            die $E_PERMISSION "Cannot create anything in ${TARGET:h}, and AURORA_TARGET
         named it explicitly. Choose a folder you can write to."
        fi
        note "cannot create anything in ${TARGET:h}"
        mkdir -p "$HOME/Applications" \
            || die $E_PERMISSION "Cannot create $HOME/Applications either.
         Choose a folder you can write to:
             AURORA_TARGET=/some/folder/CrossOver-FIFA.app ./setup.sh"
        TARGET="$HOME/Applications/${TARGET:t}"
        assert_safe_target "$TARGET"
        PROBE_DIR="$(mktemp -d "${TARGET:h}/.aurora17-probe.XXXXXX" 2>/dev/null || true)"
        [ -n "$PROBE_DIR" ] \
            || die $E_PERMISSION "Cannot create anything in ${TARGET:h}.
         Choose a folder you can write to:
             AURORA_TARGET=/some/folder/CrossOver-FIFA.app ./setup.sh"
        say "        using $TARGET instead"
    fi
    rmdir "$PROBE_DIR" 2>/dev/null || true

    APPSIZE_K=$(du -sk "$SRC" | awk '{print $1}')
    FREE_K=$(df -Pk "${TARGET:h}" | tail -1 | awk '{print $4}')
    case "$APPSIZE_K$FREE_K" in
        ''|*[!0-9]*) die $E_UNSUPPORTED "Could not work out the disk space. Free about 2 GB and try again." ;;
    esac
    # The previous copy is deleted before the new one is made, so its space is
    # about to come back. Not counting it rejects reinstalls that would fit.
    RECLAIM_K=0
    if [ -d "$TARGET" ]; then
        RECLAIM_K=$(du -sk "$TARGET" 2>/dev/null | awk '{print $1}')
    fi
    case "$RECLAIM_K" in ''|*[!0-9]*) RECLAIM_K=0 ;; esac
    if [ $((FREE_K + RECLAIM_K)) -lt $((APPSIZE_K + 500000)) ]; then
        die $E_UNSUPPORTED "Not enough disk space. The copy needs about $((APPSIZE_K / 1024)) MB
         and there is $(( (FREE_K + RECLAIM_K) / 1024 )) MB free.
         Free up some space and run this again."
    fi
    ok "room for the $((APPSIZE_K / 1024)) MB copy"

    # An existing target has to be CrossOver before it can be deleted.
    if [ -e "$TARGET" ]; then
        [ -d "$TARGET" ] \
            || die $E_UNSUPPORTED "$TARGET exists and is not an application. Refusing to remove it.
         Move it out of the way, or set AURORA_TARGET to another path."
        is_crossover_bundle "$TARGET" \
            || die $E_UNSUPPORTED "$TARGET is not a CrossOver bundle. Refusing to remove it.
         Move it out of the way, or set AURORA_TARGET to another path."
        if app_is_running "$TARGET"; then
            die $E_PERMISSION "$TARGET is running.
         Quit it completely (Command-Q, not just closing the window), then
         run this again."
        fi
    fi
fi
if [ "$IN_PLACE" = "1" ] && app_is_running "$SRC"; then
    die $E_PERMISSION "$SRC is running.
         Quit it completely (Command-Q, not just closing the window), then
         run this again."
fi

# Step 7 edits the bottle's user.reg and system.reg: the version override and
# the proxy setting in one, the controller setting in the other. A live Wine
# session keeps the registry in memory and writes it back out when it exits, so
# the values added here would be thrown away silently the next time CrossOver
# quits -- and the game would say the servers have been shut down with every
# check in --verify saying ok. See prefix_holders.
HOLDING=( ${(f)"$(prefix_holders)"} )
HOLDING=( ${HOLDING:#} )
if [ "${#HOLDING}" -gt 0 ]; then
    if [ -n "$(crossovers_running)" ]; then
        die $E_PERMISSION "The $BOTTLE bottle is open in CrossOver.
         Quit CrossOver completely -- Command-Q, not just closing the window --
         and run this again. Installing now would leave the bottle's settings to
         be overwritten when it does quit, and the game would say the servers
         have been shut down. Nothing has been changed."
    fi
    if hold_pid_alive; then
        die $E_PERMISSION "FIFA 17 is playing right now (started by --play-offline).
         Quit the game first, then run this again. Nothing has been changed."
    fi
    die $E_PERMISSION "${#HOLDING} leftover process(es) are still inside the $BOTTLE bottle
         with no CrossOver running. They will overwrite whatever is written
         here, and the bottle will hang on loading. Free it first:
             ./setup.sh --unstick
         Nothing has been changed."
fi

# =========================================================================
# From here on things change on disk.
# =========================================================================
say ""
if [ "$IN_PLACE" = "1" ]; then
    say "2. Using your real CrossOver (AURORA_IN_PLACE=1)"
    say "        This changes every bottle you run in CrossOver, not just FIFA."
    say "        ./uninstall.sh puts the six files back, but it cannot restore"
    say "        CodeWeavers' own signature -- only reinstalling CrossOver does."
else
    say "2. Making a separate CrossOver for FIFA"
    if [ -d "$TARGET" ]; then
        rm -rf "$TARGET"
        ok "removed the previous copy"
    fi
    ok "copying $((APPSIZE_K / 1024)) MB — this takes a moment"
    ditto "$SRC" "$TARGET" \
        || die $E_PERMISSION "Could not copy CrossOver to $TARGET.
         Check the disk space and that you can write to ${TARGET:h}."
    ok "made $TARGET"
    say "        your own CrossOver at $SRC is untouched"
fi

APP="$TARGET"
WINE="$APP/Contents/SharedSupport/CrossOver/lib/wine"
[ -d "$WINE/x86_64-unix" ] || die $E_PAYLOAD "$APP does not look like CrossOver 26.3 inside.
         The copy went wrong. Run ./uninstall.sh, then run this again."

# Since macOS 14, a signed app bundle is protected by a permission called "App
# Management" that belongs to the program running this script, not to you. The
# folder can be owned by you, with write permission, and still refuse writes --
# so [ -w ] says yes and the first cp then fails with "Operation not permitted".
# Probe with a real write, up front, so macOS asks now rather than half way in.
PROBE="$(mktemp "$WINE/x86_64-unix/.aurora17-probe.XXXXXX" 2>/dev/null || true)"
if [ -z "$PROBE" ]; then
    die $E_PERMISSION "macOS will not let this change $APP.
         It is a signed app, and since macOS 14 changing one needs a
         permission called App Management. It belongs to the program
         running this installer, not to you, so the folder looks
         writable but is not.
         To fix:
           1. System Settings > Privacy & Security > App Management
           2. Switch on Terminal (or iTerm, or whatever you ran this from).
              If it is not listed there, use Full Disk Access instead.
           3. Quit that app completely, reopen it, and run this again.
         Nothing has been changed inside CrossOver."
fi
rm -f "$PROBE"

# ------------------------------------------------------------- 3. backup
# Only in-place installs can ever use these. The default install is undone by
# deleting the whole copy, so writing .orig files into it would be six pointless
# writes and six more things to go wrong.
say ""
if [ "$IN_PLACE" = "1" ]; then
    say "3. Backing up the files we replace"
    for f in $FILES; do
        if [ -f "$WINE/$f.orig" ]; then
            ok "${f:t} — backup already exists, keeping it"
        else
            cp "$WINE/$f" "$WINE/$f.orig" \
                || die $E_PERMISSION "Could not back up $f.
$APP_MGMT_HINT"
            ok "${f:t} → ${f:t}.orig"
        fi
    done
else
    say "3. No backups needed — undoing this deletes the copy"
fi

# ------------------------------------------------------------- 4. install
say ""
say "4. Installing the fixes"
for f in $FILES; do
    # -X copies without extended attributes, so com.apple.quarantine -- which
    # every file that arrived inside a downloaded zip carries -- never reaches
    # the installed copy. Left on, Gatekeeper can refuse to load it and the
    # failure is obscure.
    cp -X "$HERE/fixes/$f" "$WINE/$f" \
        || die $E_PERMISSION "Could not install $f into $APP.
$APP_MGMT_HINT"
    ok "${f:t}"
done

# The name resolution fix. a17hosts.dylib re-exports the whole of libSystem and
# overrides two functions out of it, so redirecting ws2_32.so's libSystem
# dependency to it changes name resolution and nothing else. The edit is one
# string inside an existing load command -- reversible with the same tool, which
# is how uninstall.sh puts it back.
cp -X "$HERE/fixes/$RESOLVER" "$WINE/$RESOLVER" \
    || die $E_PERMISSION "Could not install ${RESOLVER:t} into $APP.
$APP_MGMT_HINT"
ok "${RESOLVER:t}"
if ws2_32_is_patched "$WINE"; then
    ok "ws2_32.so — already reading the bottle's hosts file"
else
    install_name_tool -change "$LIBSYSTEM" "$RESOLVER_PATH" "$WINE/x86_64-unix/ws2_32.so" 2>/dev/null \
        || die $E_PERMISSION "Could not point ws2_32.so at ${RESOLVER:t}.
$APP_MGMT_HINT"
    ws2_32_is_patched "$WINE" \
        || die $E_PAYLOAD "ws2_32.so did not take the change. Nothing will
         resolve to Aurora17 and the game will not connect.
         Run ./uninstall.sh, then run this again."
    ok "ws2_32.so — now reads the bottle's hosts file"
fi

# ------------------------------------------------- 5. the search path fix
# Both rebuilt .so files lose it, and both need it: ntdll.so to find its sibling
# libraries, crypt32.so to find the gnutls CrossOver already ships in lib64.
# Without it CrossOver silently falls back to a graphics path that does not work
# on macOS, and the game hangs on the loading screen forever.
say ""
say "5. Repairing the library search path"
for so in ntdll.so crypt32.so; do
    if has_lib64_rpath "$WINE/x86_64-unix/$so"; then
        ok "$so — already present"
    else
        # Keep the error: "would duplicate path" means the rpath was there all
        # along and only the check was wrong, which is nothing to stop for. Any
        # other failure is real.
        # "if VAR=$(...)": under set -e a failing substitution in a bare
        # assignment ends the script before any "if" after it is reached.
        if RPATH_ERR="$(install_name_tool -add_rpath "$RPATH_LIB64" "$WINE/x86_64-unix/$so" 2>&1)"; then
            ok "$so — added"
        elif print -r -- "$RPATH_ERR" | grep -q 'would duplicate path'; then
            ok "$so — already present"
        else
            print -r -- "$RPATH_ERR"
            die $E_PERMISSION "Could not repair the search path in $so.
$APP_MGMT_HINT"
        fi
    fi
done

# ------------------------------------------------------------- 6. re-sign
say ""
say "6. Signing"
sign_payload "$WINE"
resign_app "$APP"

configure_bottle "$APP"

# ------------------------------------------------------------- the receipt
# Uninstall reads this instead of guessing at default locations.
mkdir -p "$RECEIPT_DIR"
{
    print -r -- "# Written by setup.sh. Delete this only if you have already uninstalled."
    print -r -- "mode=$([ "$IN_PLACE" = "1" ] && print in-place || print copy)"
    print -r -- "target=$TARGET"
    print -r -- "source=$SRC"
    print -r -- "bottle_dir=$BOTTLE_DIR"
    print -r -- "bottle=$BOTTLE"
    print -r -- "aurora_dir=$PS_AURORA_DIR"
    print -r -- "offline=$NO_AURORA"
    print -r -- "bottle_powershell=$PS_BOTTLE_ACTION"
    print -r -- "version=$VER"
    print -r -- "installed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$RECEIPT"

# ------------------------------------------------------------- the verdict
# "Done" has to mean the game will start. A missing bottle or a missing
# stand-in means PLAY does nothing, and saying Done to that wastes an evening.
say ""
if [ "$BOTTLE_OK" = 1 ] && [ "$PS_OK" = 1 ] && [ "$HOSTS_OK" = 1 ]; then
    green "Done."
    say ""
    if [ "$NO_AURORA" = 1 ]; then
        say "To play:  open ${TARGET:t:r}  (not your normal CrossOver), pick the"
        say "          $BOTTLE bottle and click  FIFA 17 (offline)."
        say ""
        say "          Or, without opening CrossOver at all, double-click"
        say "          PLAY FIFA 17 offline.command  (./setup.sh --play-offline)."
        say ""
        say "          Both run the game's own loader, _fifa17.exe. Kick-off,"
        say "          career, tournaments and skill games all work. Online, FUT"
        say "          and anything that needs an EA account do not: nothing here"
        say "          talks to EA. Adding Aurora17 later is just  ./setup.sh"
        say "          with no flag."
    elif [ "$IN_PLACE" = "1" ]; then
        say "To play:  open CrossOver, then open Aurora17 in the $BOTTLE bottle"
        say "          and press PLAY FIFA 17."
    else
        say "To play:  open ${TARGET:t:r}  (not your normal CrossOver)"
        say "          then open Aurora17 in the $BOTTLE bottle and press PLAY FIFA 17."
        say ""
        say "          It is at $TARGET"
        say "          Your normal CrossOver is unchanged, and so is every other"
        say "          bottle you run in it. Both share the same bottles, so do not"
        say "          run the same bottle in both at once."
    fi
    say ""
    install_cleanup_agent || note "continuing without the background cleanup (./setup.sh --agent retries it)"
    say ""
    say "To quit when you stop playing:    double-click Stop.command"
    say "                                  (or ./setup.sh --shutdown -- closing"
    say "                                  CrossOver's window leaves FIFA and Aurora"
    say "                                  running and the ports held)"
    say "To check an install at any time:  ./setup.sh --verify"
    say "If anything goes wrong:           ./setup.sh --bundle   (then send the zip)"
    say "To undo everything:               ./uninstall.sh"
    say ""
    exit 0
fi

red "NOT FINISHED — CrossOver is patched, but the game will not start yet."
say ""
if [ "$BOTTLE_OK" != 1 ]; then
    say "  * the '$BOTTLE' bottle has none of the settings FIFA needs"
fi
if [ "$PS_OK" != 1 ]; then
    say "  * the PowerShell stand-in is nowhere Aurora17 will find it, so PLAY"
    say "    will appear to work and do nothing at all"
fi
if [ "$HOSTS_OK" != 1 ]; then
    say "  * the six EA name mappings are not in the bottle's hosts file, so the"
    say "    launcher will try to elevate on PLAY and stop with"
    say "    'The elevated setup step exited with code 1'"
fi
say ""
say "Fix whichever is listed above, then run this again. ./setup.sh --verify"
say "will tell you when everything is in place."
say ""
exit $E_INCOMPLETE
