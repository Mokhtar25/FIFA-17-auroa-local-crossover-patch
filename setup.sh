#!/bin/zsh
# Installs the FIFA 17 fixes.
#
# By default it does NOT touch your CrossOver. It makes a separate copy called
# CrossOver-FIFA and puts the fixes in that, so your normal CrossOver and every
# other bottle you run in it are left exactly as they are.
#
# Everything it does can be undone by running ./uninstall.sh.
# It never changes a file of the game's own. In the FIFA 17 folder it adds one
# hidden folder, .crossover-fifa: copies of the files launchers replace (about
# 75 MB, only once CAS is used), which the folder gate in the patched Wine uses
# to give each launcher the game the way it needs it. The one thing it downloads is
# Microsoft's fixed-version Edge WebView2 runtime 99.0.1150.52 (165 MB, once,
# FIFA 17 only), which is what makes the RebornFUT launcher's window draw;
# WEBVIEW2_CAB=/path/to/the.cab uses a copy you already have and
# WEBVIEW2_RUNTIME=skip leaves it out.
# (For FIFA 17 it also makes the CAS launcher work: a powershell.exe in the
# bottle that answers CAS's device check, and a small app in ~/Applications,
# "CAS Link (CrossOver)", that brings CAS's cas:// sign-in link back from the
# browser to the bottle. CAS_SUPPORT=skip leaves both out.)
# (For FIFA 15 it does add Microsoft's msvcr110/msvcp110 next to fifa15.exe,
# copied from your FIFA 17 folder or out of the game's own _Redist installer:
# without them an online match desyncs at kick-off.)
# (For FIFA 16 it changes nothing in the game folder; if the bottle has no
# drive letter that reaches the folder, it gives the bottle one.)
#
#   ./setup.sh [/path/to/CrossOver.app]   install
#   ./setup.sh --resign                   repair the signature, no re-copy
#   ./setup.sh --verify                   check an install, change nothing. Starts
#                                         with a table of every game (FIFA 13-21)
#                                         and launcher in the bottle, then FIFA 17
#   ./setup.sh --report                   one pasteable diagnosis, change nothing
#   ./setup.sh --unstick                  free bottles stuck loading (kills orphaned
#                                         Wine + wineservers, frees 47170-47173/3216)
#   ./setup.sh --shutdown                 quit CrossOver cleanly first, then --unstick:
#                                         use this instead of closing the window -
#                                         it stops Aurora/FIFA, shuts wineservers
#                                         down, then quits the GUI so no strays
#                                         or held ports are left behind
#   ./setup.sh --agent                    remove the background cleanup LaunchAgent
#                                         that older versions installed. Nothing of
#                                         this package runs in the background now
#   ./setup.sh --bundle                   zip up everything a bug report needs,
#                                         into the diagnostics folder beside this
#   ./setup.sh --bottle                   set up a bottle only, no re-copy
#   ./setup.sh --smoke                    watch one PLAY and say pass or fail
#   ./setup.sh --play-offline             start FIFA 17 with no Aurora17 running
#   ./setup.sh --play-log                 start Aurora17's launcher with CrossOver's
#                                         own log turned on, and after the game has
#                                         gone say which module it died in. For a
#                                         0xC0000005 that comes back on every PLAY
#   ./setup.sh --reseed-licence           make the game's own loader write a fresh
#                                         EA licence file, replacing whatever is
#                                         there. Every other check only asks whether
#                                         that file exists, so a wrong one looks fine
#   ./setup.sh --repair                   put an install that once worked right again
#                                         without copying CrossOver: quit CrossOver
#                                         cleanly, replace any fix file that is missing
#                                         or stale in the copy and re-sign it, set the
#                                         bottle up again (settings, overrides, hosts,
#                                         menu entries, the WebView2 runtime, the CAS
#                                         launcher's two pieces), have the game's loader
#                                         write a fresh licence file, then --verify.
#                                         "Fix my installation.command" is this
#   ./setup.sh --offline-menu             (re)add the FIFA 17 (offline) entry to the
#                                         bottle, e.g. after moving the game folder
#   ./setup.sh --fix-folder               keep the copies the FIFA 17 folder gate
#                                         puts back (the game's own data files once
#                                         CAS is used, Impulsum17's version.dll) in
#                                         each FIFA 17 folder's .crossover-fifa.
#                                         Never changes the game's files. --repair
#                                         and the installer do this too
#   ./setup.sh --offline                  install FIFA 17 with no Aurora17 at all:
#                                         the CrossOver copy, the fixes and the
#                                         bottle settings only (the Aurora17 bottle
#                                         is made if it is missing). Kick-off, career
#                                         and the rest of single player; no online,
#                                         no FUT, no EA account. See SETUP.md.
#
#   ./setup.sh --fifa15                   set FIFA 15 up: the copy if it is missing,
#                                         Aurora's bottle, its settings and files
#   ./setup.sh --fifa15 --verify          check the FIFA 15 setup, change nothing
#                                         (experimental; see SETUP.md "FIFA 15")
#   ./setup.sh --fifa16                   set FIFA 16 up: the copy if it is missing,
#                                         the FIFA16 bottle, its settings, and a
#                                         drive letter for the game folder
#   ./setup.sh --fifa16 --verify          check the FIFA 16 setup, change nothing
#                                         (experimental; see SETUP.md "FIFA 16")
#   ./setup.sh --fifa21                   set the bottle up for FIFA 21 from the
#                                         Aurora launcher (Aurora.exe): the copy if
#                                         it is missing, then the settings, the
#                                         PowerShell and DNS Client stand-ins. The
#                                         bottle (Aurora17 by default) must exist
#   ./setup.sh --fifa21 --verify          check the FIFA 21 setup, change nothing
#   ./setup.sh --choose-folder fifa15 [path]   remember a game's folder
#   ./setup.sh --forget-folder fifa15          forget only that folder choice
#   AURORA_BOTTLE=Aurora17 ./setup.sh --fifa15   (or --fifa16, --fifa21) add the game to
#                                         another game's bottle. Needs a copy whose
#                                         ntdll.so gives each game its own settings;
#                                         see SETUP.md "Several games in one bottle"
#
# Exit codes:  0 verified   2 unsupported/usage   3 permission
#              4 corrupt payload or wrong CrossOver   5 incomplete install
#              1 is not a designed outcome: it means a stop nobody gave a code
#              to, and is worth reporting as a bug in this script.

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

set -eu
HERE="${0:A:h}"
# This script's own path, taken here and not where it is used: inside a zsh
# function $0 is the function's name, so ${0:A} read from one names the
# function rather than the file. guard_menu_shims writes this into the
# bottle's shortcuts, where getting it wrong is silent.
SELF="${0:A}"

E_UNSUPPORTED=2
E_PERMISSION=3
E_PAYLOAD=4
E_INCOMPLETE=5

CHOICES_FILE="$HOME/Library/Application Support/FIFA-CrossOver/choices.conf"
game_exe_of() {
    case "$1" in
        fifa13) print -r -- fifa13.exe ;; fifa15) print -r -- fifa15.exe ;;
        fifa16) print -r -- fifa16.exe ;; fifa17) print -r -- FIFA17.exe ;;
        fifa21) print -r -- FIFA21.exe ;;
        *) return 1 ;;
    esac
}

MODE=install
CHOICE_GAME=""; CHOICE_PATH=""; CHOICE_PATH_SET=0
# --offline: install everything the game itself needs and nothing Aurora17's.
NO_AURORA=0
case "${1:-}" in
    --choose-folder|--forget-folder)
        MODE="${1#--}"; shift
        if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] \
           || { [ "$MODE" = forget-folder ] && [ "$#" -ne 1 ]; } \
           || ! game_exe_of "${1:-}" >/dev/null; then
            print -r -- "Use --choose-folder <fifa13|fifa15|fifa16|fifa17|fifa21> [path]"
            print -r -- " or --forget-folder <game>"
            exit $E_UNSUPPORTED
        fi
        CHOICE_GAME="$1"
        if [ "$#" -eq 2 ]; then CHOICE_PATH="$2"; CHOICE_PATH_SET=1; fi
        shift "$#" ;;
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
    --play-log) MODE=play-log; shift ;;
    --reseed-licence|--reseed-license) MODE=reseed-licence; shift ;;
    --offline-menu) MODE=offline-menu; shift ;;
    --fix-folder) MODE=fix-folder; shift ;;
    --repair) MODE=repair; shift ;;
    --ensure-licence|--ensure-license) MODE=ensure-licence; shift ;;
    --fifa15)
        # One command for FIFA 15. The same as AURORA_GAME=fifa15 with the
        # mode picked below from what is already there; a mode after it
        # (--verify, --bottle, --unstick, --shutdown) is taken as given.
        AURORA_GAME=fifa15; MODE=fifa15; shift
        case "${1:-}" in
            --verify) MODE=verify; shift ;;
            --bottle) MODE=bottle; shift ;;
            --unstick) MODE=unstick; shift ;;
            --shutdown) MODE=shutdown; shift ;;
            --resign) MODE=resign; shift ;;
            -*) print -r -- "Unknown option after --fifa15: $1  (try: ./setup.sh --help)"; exit $E_UNSUPPORTED ;;
        esac ;;
    --fifa16)
        # The same for FIFA 16: AURORA_GAME=fifa16, with the mode picked below
        # from what is already there, and a mode after it taken as given.
        AURORA_GAME=fifa16; MODE=fifa16; shift
        case "${1:-}" in
            --verify) MODE=verify; shift ;;
            --bottle) MODE=bottle; shift ;;
            --unstick) MODE=unstick; shift ;;
            --shutdown) MODE=shutdown; shift ;;
            --resign) MODE=resign; shift ;;
            -*) print -r -- "Unknown option after --fifa16: $1  (try: ./setup.sh --help)"; exit $E_UNSUPPORTED ;;
        esac ;;
    --fifa21)
        # And for FIFA 21: AURORA_GAME=fifa21, the same way.
        AURORA_GAME=fifa21; MODE=fifa21; shift
        case "${1:-}" in
            --verify) MODE=verify; shift ;;
            --bottle) MODE=bottle; shift ;;
            --unstick) MODE=unstick; shift ;;
            --shutdown) MODE=shutdown; shift ;;
            --resign) MODE=resign; shift ;;
            -*) print -r -- "Unknown option after --fifa21: $1  (try: ./setup.sh --help)"; exit $E_UNSUPPORTED ;;
        esac ;;
    --help|-h)
        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    -*) print -r -- "Unknown option: $1  (try: ./setup.sh --help)"; exit $E_UNSUPPORTED ;;
esac

# A second flag must never become a source path or be silently ignored.
if [ "$#" -gt 1 ] || [[ "${1:-}" == -* ]]; then
    print -r -- "Expected at most one CrossOver app path (try: ./setup.sh --help)"
    exit $E_UNSUPPORTED
fi

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

# The chooser changes only choices.conf: no CrossOver, bottle or payload is
# needed. Keep it before all install discovery and platform checks.
choice_folder_validated() {
    local g="$1" d="$2" exe child
    local -a matches
    exe="$(game_exe_of "$g")" || return $E_UNSUPPORTED
    if [ -d "$d" ] && [ ! -f "$d/$exe" ]; then
        matches=()
        for child in "$d"/*(N/); do
            [ -f "$child/$exe" ] && matches+=( "$child" )
        done
        if (( ${#matches} > 1 )); then
            print -u2 -r -- "That folder contains more than one $exe. Choose the game folder itself."
            return $E_UNSUPPORTED
        fi
        (( ${#matches} == 1 )) && d="$matches[1]"
    fi
    if [ ! -d "$d" ] || [ ! -f "$d/$exe" ]; then
        print -u2 -r -- "That folder has no $exe. Choose the folder that contains it."
        return $E_UNSUPPORTED
    fi
    d="${d:A}"
    if [[ "$d" == *$'\t'* || "$d" == *$'\r'* || "$d" == *$'\n'* ]]; then
        print -u2 -r -- "The folder name contains a tab or line break. Rename it before saving the choice."
        return $E_UNSUPPORTED
    fi
    print -r -- "$d"
}

choice_write() {
    local game="$1" folder="${2:-}" dir="${CHOICES_FILE:h}" tmp
    if [ -e "$CHOICES_FILE" ] && [ ! -f "$CHOICES_FILE" ]; then
        die $E_PERMISSION "$CHOICES_FILE is not a file. Move it aside and try again."
    fi
    [ -n "$folder" ] || [ -f "$CHOICES_FILE" ] || return 0
    mkdir -p "$dir" || die $E_PERMISSION "Could not create $dir. Check its permissions."
    tmp="$(mktemp "$dir/.choices-XXXXXX")" \
        || die $E_PERMISSION "Could not save a choice in $dir. Check permissions and free disk space."
    if [ -f "$CHOICES_FILE" ]; then
        if ! LC_ALL=C awk -v key="$game.folder=" 'index($0,key)!=1' "$CHOICES_FILE" > "$tmp"; then
            rm -f "$tmp"
            die $E_PERMISSION "Could not read $CHOICES_FILE. The previous choices were kept."
        fi
    else
        print -r -- "# Your choices for the FIFA CrossOver fixes. Delete a line to forget it." > "$tmp"
    fi
    if [ -n "$folder" ]; then print -r -- "$game.folder=$folder" >> "$tmp"; fi
    if cmp -s "$tmp" "$CHOICES_FILE"; then
        rm -f "$tmp"
    elif ! mv -f "$tmp" "$CHOICES_FILE"; then
        rm -f "$tmp"
        die $E_PERMISSION "Could not save $CHOICES_FILE. The previous choices were kept.
         Check permissions and free disk space, then try again."
    fi
}

if [ "$MODE" = choose-folder ] || [ "$MODE" = forget-folder ]; then
    if [ "$MODE" = choose-folder ]; then
        if [ "$CHOICE_PATH_SET" != 1 ]; then
            source "$HERE/lib/ui.zsh"
            CX_DIALOGS=1
            ui_gui_ok || die $E_UNSUPPORTED "No desktop dialog is available. Give the folder path:
         ./setup.sh --choose-folder $CHOICE_GAME '/path/to/FIFA ${CHOICE_GAME#fifa}'"
            CHOICE_EXE="$(game_exe_of "$CHOICE_GAME")"
            if ! CHOICE_PATH="$(ui_choose_folder "Choose your FIFA ${CHOICE_GAME#fifa} folder (the one with $CHOICE_EXE in it)" /Volumes)"; then
                say "No folder chosen. Your previous choice was kept."
                exit 0
            fi
        fi
        CHOICE_PATH="$(choice_folder_validated "$CHOICE_GAME" "$CHOICE_PATH")" || exit $E_UNSUPPORTED
        choice_write "$CHOICE_GAME" "$CHOICE_PATH"
        ok "saved FIFA ${CHOICE_GAME#fifa}: $CHOICE_PATH"
    else
        choice_write "$CHOICE_GAME"
        ok "forgot FIFA ${CHOICE_GAME#fifa}'s folder choice"
    fi
    exit 0
fi

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

# Both profiles install the complete shared Wine payload, so reinstalling
# FIFA 17 cannot remove the gdiplus fix needed by Aurora15Connector.
# ole32.dll is for the RebornFUT launcher (3.1.45 and later, a WebView2 app):
# it revokes drag-and-drop on a window the browser process owns, and Wine's
# RevokeDragDrop dereferenced that process's pointer. See patches/README.
FILES=(
  x86_64-unix/ntdll.so
  x86_64-unix/winecoreaudio.so
  x86_64-unix/crypt32.so
  # The RebornFUT launcher's second crash: CrossOver flushes a cross-process
  # child window's surface while holding the USER lock, and the WebView2
  # browser process aborts on "BUG: holding USER lock". See patches/README.
  x86_64-unix/win32u.so
  x86_64-windows/version.dll
  x86_64-windows/crypt32.dll
  x86_64-windows/secur32.dll
  x86_64-windows/gdiplus.dll
  x86_64-windows/ole32.dll
)
# One more file, added rather than replaced, so it is not in FILES: the thing
# that makes name resolution work without touching /etc/hosts. See below.
RESOLVER=x86_64-unix/a17hosts.dylib
# And one more, added beside ntdll.so the same way: the FIFA 17 folder gate.
# Several launchers share one FIFA 17 folder and leave it each their own way
# (CAS's mod data kills the game under every other launcher; Impulsum17's
# version.dll is overwritten by whoever played last). ntdll.so runs this
# script when FIFA17.exe or Impulsum17Launcher.exe starts, before the
# program's own code, and it puts the folder the way the starting launcher
# needs it. All the policy is in the script, so it ships through --repair
# with no rebuild; ntdll.so only says "run it". An ntdll.so that does has
# GATE_MARKER in it. CX_FIFA_GATE=0 in a bottle turns it off there.
GATE=x86_64-unix/cx-fifa17-gate
GATE_MARKER=CX_FOLDER_GATE_V1
# The script is also where the path mapping, the table of the game's own
# files and the way a version.dll is recognised live, so this script reads
# them from there rather than keeping a second copy (functions named cxg_*).
# Sourced, it defines things and runs nothing.
if [ -f "$HERE/fixes/$GATE" ]; then
    source "$HERE/fixes/$GATE"
fi

# The Mach-O files that have to be signed after we have touched them. The first
# four are ours; a17hosts.dylib is new; ws2_32.so is CrossOver's own, edited in
# place by step 4 and therefore no longer covered by CodeWeavers' signature.
MACHO=( ntdll.so winecoreaudio.so crypt32.so win32u.so a17hosts.dylib ws2_32.so )

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
# Which game the bottle is for. FIFA 17 is the default and the only one every
# mode supports. FIFA 15 (AURORA_GAME=fifa15) shares the same patched CrossOver
# -- its one Wine patch is inert until CX_TOPDOWN_LIMIT is set, which is what
# its bottle profile does -- and differs only in the bottle settings and in
# skipping the Aurora17-only steps. See SETUP.md, "FIFA 15". FIFA 16
# (AURORA_GAME=fifa16) shares it too: its three Wine patches act only under
# CX_DR_TRAP=3 and CX_FIFA16_DSTFIX, which only its bottle profile sets, and it
# skips the same steps. See SETUP.md, "FIFA 16". FIFA 21 (AURORA_GAME=fifa21)
# needs FIFA 17's Wine settings and only the Aurora launcher's part of the
# bottle steps. A copy whose ntdll.so has the
# per-game table applies all of these by program name instead, and then any
# game can go into any bottle: see "one bottle, every game" below.
GAME="${AURORA_GAME:-fifa17}"

# ------------------------------- the browser runtime the RebornFUT launcher needs
# RebornFUT 3.1.45 and later are Tauri apps: the launcher's window is Microsoft
# Edge WebView2. Every WebView2 runtime from version 100 on presents its frames
# through a DirectX/DirectComposition path Wine cannot drive, so the window
# opened and stayed blank. Runtimes up to 99 draw through plain GDI, which
# CrossOver's cross-process window hack handles, and the launcher then renders
# completely.
#
# So the bottle gets its own copy of Microsoft's fixed-version runtime
# 99.0.1150.52, and WEBVIEW2_BROWSER_EXECUTABLE_FOLDER -- a variable the
# official WebView2 loader honours -- points the launcher at it. The evergreen
# runtime the launcher installs for itself is left exactly where it is and is
# simply not used.
#
# The cabinet comes from a community archive of Microsoft's own fixed-version
# cabinets, because Microsoft keeps only the last two versions on its own page.
# It is checked against the hash below before anything is done with it.
#   WEBVIEW2_CAB=/path/to/file.cab   use a copy already on this Mac
#   WEBVIEW2_RUNTIME=skip            leave the runtime and the variable out
WEBVIEW2_VERSION=99.0.1150.52
WEBVIEW2_CAB_NAME="Microsoft.WebView2.FixedVersionRuntime.$WEBVIEW2_VERSION.x64"
WEBVIEW2_URL="https://github.com/westinyang/WebView2RuntimeArchive/releases/download/$WEBVIEW2_VERSION/$WEBVIEW2_CAB_NAME.cab"
WEBVIEW2_SHA256=b43a87ae6a039daaf96a8a3766a11c317a90c1ffe973bb19087374528d611544
# Single quotes: this is a Windows path, and the backslashes are the path's own.
WEBVIEW2_WIN_DIR='C:\webview2-fixed\99.0.1150.52'

# ------------------------------------------------ what the CAS launcher needs
# CAS is a second FIFA 17 launcher, a Tauri app like RebornFUT, so the
# WebView2 runtime above is what makes its window draw too. It then stopped
# twice, and neither stop says what it is:
#
# * Its device check runs Windows PowerShell to read the machine's UUID, and
#   Wine's powershell.exe is a stub that prints nothing. CAS takes the empty
#   answer to mean an old CAS and says "Install the latest CAS launcher to
#   verify this device.", and sign-in never starts. fixes/cas-powershell.c
#   answers that one script with what real PowerShell would print.
# * Discord sign-in ends with the browser opening a cas:// link, and that
#   scheme is registered only inside the bottle, so the Mac browser has
#   nowhere to send it. fixes/cas-link.applescript, compiled into a small app
#   in ~/Applications, takes the link and starts cas.exe in the bottle with
#   it; CAS's single-instance plugin hands it to the window already open.
#
# Both are FIFA 17's only, and CAS is optional: nothing here is ever a stop.
#   CAS_SUPPORT=skip   leave both out
CAS_PS="$HERE/fixes/x86_64-windows/cas-powershell.exe"
# The name Aurora17's stand-in takes in the bottle once CAS's has its place:
# cas-powershell.exe hands it every command line that is not CAS's.
CAS_HANDOFF=aurora17-powershell.exe
CAS_LINK_SRC="$HERE/fixes/cas-link.applescript"
CAS_LINK_APP="$HOME/Applications/CAS Link (CrossOver).app"
CAS_LINK_ID=com.fifa17-crossover.cas-link
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

case "$GAME" in
    fifa17|fifa15|fifa16|fifa21) ;;
    *) print -r -- "Unknown AURORA_GAME: $GAME  (fifa17, fifa15, fifa16 or fifa21)"; exit $E_UNSUPPORTED ;;
esac
# Whether the game was named (--fifa15, --fifa16, --fifa21 or AURORA_GAME) or
# plain FIFA 17 was assumed. A plain --verify also prints the table of every
# game in the bottle (verify_games_table); a named one checks that game only.
GAME_EXPLICIT=0
[ -n "${AURORA_GAME:-}" ] && GAME_EXPLICIT=1
# Aurora.exe installs under the old connector's name too. Its multi-game
# keys, in the ini or executable metadata, distinguish it from the standalone
# FIFA 15 connector. A leftover ini without a program is never an install.
aurora_bottle_kind() {
    local d exe ini legacy=0
    [ -f "$BOTTLE_DIR/$1/cxbottle.conf" ] || return 1
    for d in "$BOTTLE_DIR/$1/drive_c/users"/*/AppData/Local/Aurora15Connector(N/); do
        [ -f "$d/Aurora.exe" ] && { print -r -- modern; return 0; }
        exe="$d/Aurora15Connector.exe"; ini="$d/Aurora15Connector.ini"
        [ -f "$exe" ] || continue
        if LC_ALL=C grep -aqE 'Fifa(13|16|17|21)Path' "$exe" \
           || LC_ALL=C grep -qE '^Fifa(13|16|17|21)Path=' "$ini" 2>/dev/null; then
            print -r -- modern; return 0
        fi
        legacy=1
    done
    [ "$legacy" = 1 ] || return 1
    print -r -- legacy
}

f15_default_bottle() {
    local common="${FIFA17_BOTTLE:-Aurora17}" d name
    local -a other
    if [ -n "${AURORA_BOTTLE:-}" ]; then print -r -- "$AURORA_BOTTLE"; return 0; fi
    if [ -n "${FIFA15_BOTTLE:-}" ]; then print -r -- "$FIFA15_BOTTLE"; return 0; fi
    for name in "$common" Aurora15; do
        if [ "$(aurora_bottle_kind "$name" 2>/dev/null || true)" = modern ]; then
            print -r -- "$name"; return 0
        fi
    done
    # Other bottles require an explicit choice until discovery's consent
    # ledger is implemented. Do not silently make a different bottle instead.
    other=()
    for d in "$BOTTLE_DIR"/*(N/); do
        name="${d:t}"
        [ "$name" != "$common" ] && [ "$name" != Aurora15 ] || continue
        [ "$(aurora_bottle_kind "$name" 2>/dev/null || true)" = modern ] && other+=( "$name" )
    done
    if (( ${#other} )); then
        print -u2 -r -- "Aurora is installed in another bottle. Choose the one you play FIFA 15 in:"
        for name in "${(@)other[1,5]}"; do
            print -u2 -r -- "    AURORA_BOTTLE=${(qq)name} ./setup.sh --fifa15"
        done
        print -u2 -r -- "Nothing has been changed."
        return 1
    fi
    if [ "$(aurora_bottle_kind Aurora15 2>/dev/null || true)" = legacy ]; then
        print -r -- Aurora15
    else
        print -r -- "$common"
    fi
}

# FIFA 21 uses FIFA 17's common bottle unless AURORA_BOTTLE names another.
case "$GAME" in
    fifa15) BOTTLE="$(f15_default_bottle)" || exit $E_UNSUPPORTED ;;
    fifa16) BOTTLE="${AURORA_BOTTLE:-${FIFA16_BOTTLE:-FIFA16}}" ;;
    *)      BOTTLE="${AURORA_BOTTLE:-${FIFA17_BOTTLE:-Aurora17}}" ;;
esac

# ------------------------------------------------ one bottle, every game
# Each game's Wine workaround used to be a bottle-wide setting: FIFA 15's
# CX_TOPDOWN_LIMIT, FIFA 16's CX_DR_TRAP=3 and CX_FIFA16_DSTFIX, FIFA 17's
# CX_DR_TRAP=2. That made a bottle one game's, and the launchers that start
# several games from one bottle (Aurora.exe plays FIFA 13, 15, 16, 17 and 21)
# handed every game the settings of whichever game the bottle was made for:
# FIFA 15 started from Aurora.exe in Aurora17 died with 0x80000004.
#
# The patched ntdll.so now carries a table of its own, keyed on the program's
# name: fifa15.exe, fifa16.exe, FIFA17.exe/_fifa17.exe and FIFA21.exe get their
# game's settings whatever the bottle says, and ignore the bare variables. A
# build that has the table has the word CX_GAME_PROFILES in it (the variable
# that turns it off), so that is the marker, as add_game_ntdll does for each
# game's own patch. With it, a bottle needs only what every game shares, and
# any game can be added to any bottle. Without it the old rule stands: one
# game, one bottle. Per program, a bottle can still say otherwise, under
# HKCU\Software\Wine\AppDefaults\<exe>\CrossOver-FIFA (Profile, DrTrap,
# TopdownLimit, Fifa16DstFix); --verify shows which applies.
PROFILE_MARKER=CX_GAME_PROFILES
ntdll_has_profiles() { [ -f "$1" ] && LC_ALL=C grep -aqF "$PROFILE_MARKER" "$1"; }
# The copy the bottle runs on, found the way the modes below find it.
COPY_APP="$TARGET"
if [ ! -d "$COPY_APP" ] && [ "$TARGET_EXPLICIT" = 0 ] && [ -d "$HOME/Applications/${TARGET:t}" ]; then
    COPY_APP="$HOME/Applications/${TARGET:t}"
fi
COPY_NTDLL="$COPY_APP/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/ntdll.so"
SHIPPED_NTDLL="$HERE/fixes/x86_64-unix/ntdll.so"
# Which ntdll.so the bottle will run on once this run is over. An install
# makes the copy afresh from fixes/, --repair refreshes it from there, and
# --fifa15 and --fifa16 either install or bring the copy's ntdll.so up to
# the shipped one (add_game_ntdll). --fifa21 installs when there is no copy
# and otherwise leaves it as it is, like every other mode.
case "$MODE" in
    install|repair|fifa15|fifa16) PROFILE_NTDLL="$SHIPPED_NTDLL" ;;
    fifa21)
        if [ -d "$COPY_APP" ]; then PROFILE_NTDLL="$COPY_NTDLL"; else PROFILE_NTDLL="$SHIPPED_NTDLL"; fi ;;
    *) PROFILE_NTDLL="$COPY_NTDLL" ;;
esac
# PROFILES=1: games can share this bottle. PROFILES_WHY says why not.
PROFILES=0; PROFILES_WHY=""
if ! ntdll_has_profiles "$PROFILE_NTDLL"; then
    if [ "$PROFILE_NTDLL" = "$SHIPPED_NTDLL" ] || ! ntdll_has_profiles "$SHIPPED_NTDLL"; then
        PROFILES_WHY=package
    elif [ ! -f "$COPY_NTDLL" ]; then
        PROFILES_WHY=no-copy
    else
        PROFILES_WHY=copy
    fi
elif grep -Eq '^"CX_GAME_PROFILES"[[:space:]]*=[[:space:]]*"0"' "$BOTTLE_DIR/$BOTTLE/cxbottle.conf" 2>/dev/null; then
    # The bottle turned the table off for every program in it.
    PROFILES_WHY=off
else
    PROFILES=1
fi
# Settings a game in a shared bottle wants but must not insist on: another
# game set up in the bottle first may have its own value there, and with the
# table that value no longer reaches any game the table lists. add_setting
# notes these instead of stopping.
SOFT_SETTINGS=()
[ "$PROFILES" = 1 ] && SOFT_SETTINGS=( CX_DR_TRAP )

# One variable out of the bottle's cxbottle.conf, empty when it is not there.
conf_value() {
    sed -n "s/^\"$1\" = \"\(.*\)\"\$/\1/p" "$BOTTLE_DIR/$BOTTLE/cxbottle.conf" 2>/dev/null | tail -1
}
# Whether the bottle turns PF_PAE_ENABLED on, decided as ntdll.so decides it
# (cx_pf_pae): CX_PF_PAE=1, or a bare CX_DR_TRAP=3 -- which every FIFA 16
# bottle made before the per-game table has, and which still does it.
bottle_pae_on() {
    [[ "$(conf_value CX_PF_PAE)" == 1* ]] && return 0
    [[ "$(conf_value CX_DR_TRAP)" == 3* ]]
}

# The ntdll.so a game cannot run without, known by the name of the bottle
# variable its patch reads (see add_game_ntdll). FIFA 17's needs nothing the
# full payload does not already carry, so it has none.
NTDLL_MARKER=""; NTDLL_OLD=""; NTDLL_WHY=""
if [ "$GAME" = fifa15 ]; then
    # No CX_DR_TRAP: the FIFA 15 protector was never seen to need it, and the
    # bottle this was proven in did not have it. CX_TOPDOWN_LIMIT is the fix
    # for its start-up crash (patches/README-fifa15-wine-fixes.md). With the
    # table, fifa15.exe gets it from ntdll.so and the bottle gets nothing of
    # FIFA 15's own: a bare CX_TOPDOWN_LIMIT would reach every program the
    # table does not list, launchers included.
    if [ "$PROFILES" = 1 ]; then
        BOTTLE_SETTINGS=( "CX_GRAPHICS_BACKEND=d3dmetal" "WINE_SIMULATE_WRITECOPY=1" )
    else
        BOTTLE_SETTINGS=( "CX_GRAPHICS_BACKEND=d3dmetal" "WINE_SIMULATE_WRITECOPY=1" "CX_TOPDOWN_LIMIT=0x1ffffffff" )
    fi
    GAME_LABEL="FIFA 15"
    NTDLL_MARKER=CX_TOPDOWN_LIMIT
    NTDLL_OLD="the FIFA 17-only"
    NTDLL_WHY="FIFA 15 dies seven seconds in with it"
elif [ "$GAME" = fifa16 ]; then
    # CX_DR_TRAP=3, not FIFA 17's 2: the crack's protector arms debug
    # registers on itself and on other threads and reads through them, and
    # only mode 3 emulates all of that under Rosetta (it also reports PAE, which
    # the protector hashes). See patches/README-debug-register-emulation.md.
    # CX_FIFA16_DSTFIX=0 is the fix for the endless loading after the
    # language pick and for the same freeze when a match loads: 0 means
    # "invert whatever negative address the protector faults on"
    # (FIX-fifa16-loading-loop.md). FIFA 15's CX_TOPDOWN_LIMIT and FIFA 17's
    # WebView2 folder are not FIFA 16's and stay out.
    #
    # With the table, fifa16.exe gets mode 3 and the DSTFIX from ntdll.so, and
    # the bottle keeps them out, so the launchers and any other game in it are
    # not run under FIFA 16's emulation. What the table cannot do is PAE: it
    # is reported once for the whole Wine session, not per program, so
    # CX_PF_PAE=1 is the one FIFA 16 setting a shared bottle carries -- unless
    # the bottle already has a bare CX_DR_TRAP=3 (a FIFA 16 bottle from before
    # the table), which turns PAE on just the same (bottle_pae_on).
    if [ "$PROFILES" = 1 ]; then
        BOTTLE_SETTINGS=( "CX_GRAPHICS_BACKEND=d3dmetal" "WINE_SIMULATE_WRITECOPY=1" )
        # Asked for unless only the bare CX_DR_TRAP=3 is what turns PAE on.
        [[ "$(conf_value CX_PF_PAE)" != 1* && "$(conf_value CX_DR_TRAP)" == 3* ]] \
            || BOTTLE_SETTINGS+=( "CX_PF_PAE=1" )
    else
        BOTTLE_SETTINGS=( "CX_GRAPHICS_BACKEND=d3dmetal" "WINE_SIMULATE_WRITECOPY=1"
                          "CX_DR_TRAP=3" "CX_FIFA16_DSTFIX=0" )
    fi
    GAME_LABEL="FIFA 16"
    # The marker is the syscall-stub fix's log line in its second form. The
    # build before it has the generic loop fix but patches only ntdll's stubs,
    # and every win32u call still faults on the watched page: the stutter in
    # play. Every build that has this line has the generic loop fix too.
    NTDLL_MARKER="in a Wine builtin now reads SystemCall"
    NTDLL_OLD="an older"
    NTDLL_WHY="FIFA 16 stops before its start screen, loops after the language pick, or stutters, with it"
elif [ "$GAME" = fifa21 ]; then
    # FIFA 21 was proven in Aurora17 under FIFA 17's CX_DR_TRAP=2, and the
    # table gives FIFA21.exe the same mode. With the table the bottle keeps it
    # out, as it does FIFA 15's and 16's, so every other program in a bottle
    # FIFA 21 is added to runs as it did before. FIFA 17's WebView2 folder is
    # for its own launchers and stays out. No ntdll.so marker: the patches
    # FIFA 21 needs are FIFA 17's, which every copy has.
    if [ "$PROFILES" = 1 ]; then
        BOTTLE_SETTINGS=( "CX_GRAPHICS_BACKEND=d3dmetal" "WINE_SIMULATE_WRITECOPY=1" )
    else
        BOTTLE_SETTINGS=( "CX_GRAPHICS_BACKEND=d3dmetal" "CX_DR_TRAP=2" "WINE_SIMULATE_WRITECOPY=1" )
    fi
    GAME_LABEL="FIFA 21"
else
    # CX_DR_TRAP=2 stays bare even with the table, which gives FIFA17.exe and
    # _fifa17.exe mode 2 itself: every FIFA 17 bottle has had it, and the
    # launchers that start FIFA 17 were proven with it on. It is one of
    # SOFT_SETTINGS, so a bottle FIFA 16 was set up in first keeps its 3.
    BOTTLE_SETTINGS=( "CX_GRAPHICS_BACKEND=d3dmetal" "CX_DR_TRAP=2" "WINE_SIMULATE_WRITECOPY=1" )
    # FIFA 17 only -- FIFA 15 has no RebornFUT. Left out entirely when the
    # runtime is skipped: a variable pointing at a folder that is not there
    # leaves the launcher worse off than no variable at all.
    [ "${WEBVIEW2_RUNTIME:-}" = skip ] \
        || BOTTLE_SETTINGS+=( "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER=$WEBVIEW2_WIN_DIR" )
    GAME_LABEL="FIFA 17"
fi
# FIFA 15, 16 and 21 have no Aurora17, so every mode built around its
# launcher, its logs or its licence has nothing to do for them.
if [ "$GAME" != fifa17 ]; then
    case "$MODE" in
        smoke|report|bundle|play-log|play-offline|offline-menu|ensure-licence|reseed-licence|repair|fix-folder) print -r -- "--$MODE knows only FIFA 17's launcher and logs; it has nothing to watch for $GAME_LABEL yet."
                      print -r -- "Use  ./setup.sh --$GAME --verify  instead."
                      exit $E_UNSUPPORTED ;;
    esac
    [ "$NO_AURORA" = 0 ] || die $E_UNSUPPORTED "--offline is for FIFA 17. Use ./setup.sh --$GAME for $GAME_LABEL."
fi

# Reject reused bottles before any profile can change their settings. Each
# game's bottle carries one setting no other profile writes, so a bottle that
# has another game's is that game's: Aurora17 has CX_DR_TRAP=2, Aurora15 has
# CX_TOPDOWN_LIMIT, FIFA16 has CX_FIFA16_DSTFIX. FIFA 16 sets CX_DR_TRAP too,
# to 3, so FIFA 17's marker is the whole line, value and all.
# Resolve symlinks and compare without case, since the usual Mac filesystem
# treats Aurora15 and aurora15 as the same directory.
#
# With the profile table (PROFILES=1) a second game is simply added: each
# listed game takes its own settings from ntdll.so and ignores the other
# game's bare ones, and configure_bottle writes only what they share. Without
# it the two games would run on one set of settings, and one of them would
# fail in a way nothing names (FIFA 15 under FIFA 17's dies 0x80000004), so
# this stops and says what would let them share. FIFA 21 and FIFA 17 run on
# the same settings, so those two share a bottle with or without the table:
# FIFA 21 was first played from Aurora17, before there was one. FIFA 21's
# bottle has no setting of its own, so nothing here takes a bottle for it.
BOTTLE_PATH="$BOTTLE_DIR/$BOTTLE"
SHARED_WITH=()
for OTHER_GAME in fifa17 fifa15 fifa16; do
    [ "$OTHER_GAME" != "$GAME" ] || continue
    case "$OTHER_GAME" in
        fifa17) OTHER_BOTTLE="${FIFA17_BOTTLE:-Aurora17}"; OTHER_LABEL="FIFA 17"
                OTHER_SETTING='"CX_DR_TRAP"[[:space:]]*=[[:space:]]*"2"' ;;
        fifa15) OTHER_BOTTLE="${FIFA15_BOTTLE:-Aurora15}"; OTHER_LABEL="FIFA 15"
                OTHER_SETTING='"CX_TOPDOWN_LIMIT"[[:space:]]*=' ;;
        fifa16) OTHER_BOTTLE="${FIFA16_BOTTLE:-FIFA16}"; OTHER_LABEL="FIFA 16"
                OTHER_SETTING='"CX_FIFA16_DSTFIX"[[:space:]]*=' ;;
    esac
    OTHER_BOTTLE_PATH="$BOTTLE_DIR/$OTHER_BOTTLE"
    if [ "${(L)BOTTLE_PATH:A}" = "${(L)OTHER_BOTTLE_PATH:A}" ] \
       || grep -Eq "^$OTHER_SETTING" "$BOTTLE_PATH/cxbottle.conf" 2>/dev/null; then
        if [ "$PROFILES" = 1 ] || [ "$GAME:$OTHER_GAME" = fifa21:fifa17 ]; then
            SHARED_WITH+=( "$OTHER_LABEL" )
            continue
        fi
        case "$PROFILES_WHY" in
            off) SHARE_WHY="the '$BOTTLE' bottle turns that table off: its cxbottle.conf
         has \"CX_GAME_PROFILES\" = \"0\". Delete that line (CrossOver closed),
         then run this again." ;;
            no-copy) SHARE_WHY="there is no CrossOver-FIFA at $COPY_APP to check yet.
         Install it first (./setup.sh, or ./setup.sh --$GAME), then run this again." ;;
            copy) SHARE_WHY="the ntdll.so in $COPY_APP is from before that table.
         Bring the copy up to date first, without copying CrossOver again:
             ./setup.sh --repair
         then run this again." ;;
            *) SHARE_WHY="this package's fixes/ntdll.so is from before that table, so no
         copy made from it has one. Download the current package, then
         run this again." ;;
        esac
        die $E_UNSUPPORTED "$GAME_LABEL needs its own bottle here; '$BOTTLE' is assigned to $OTHER_LABEL.
         Two games can share a bottle only when CrossOver-FIFA's ntdll.so gives
         each game its own settings (the per-game profile table), and
         $SHARE_WHY
         Or keep them apart: separate FIFA17_BOTTLE, FIFA15_BOTTLE and
         FIFA16_BOTTLE names (for example: Aurora17, Aurora15 and FIFA16).
         Nothing has been changed."
    fi
done

# --fifa15 is the whole FIFA 15 setup in one command, and what that means
# depends on what is there. No patched CrossOver copy yet: the full install,
# with the FIFA 15 profile (gdiplus.dll added, the Aurora17 steps skipped). A
# copy already there, made by either profile: the bottle only -- the Aurora15
# bottle is made if it is missing, and the copy gets gdiplus.dll if plain
# ./setup.sh made it without. Either way it ends with the game folder checked.
#
# --fifa16 is the same for FIFA 16. No copy yet: the full install with the
# FIFA 16 profile. A copy there: the bottle only -- the FIFA16 bottle made if
# it is missing, and the copy's ntdll.so replaced if it is a build without the
# FIFA 16 fix, which every copy made before that build is. Either way it ends
# with the game folder found and reachable from the bottle.
#
# --fifa21 is the same for FIFA 21, except that it never makes the bottle:
# FIFA 21 plays only from the Aurora launcher, which has to be installed in
# the bottle first, and a bottle made here would not have it.
F15_ONE=0
F16_ONE=0
if [ "$MODE" = fifa15 ] || [ "$MODE" = fifa16 ] || [ "$MODE" = fifa21 ]; then
    if [ "$MODE" = fifa15 ]; then F15_ONE=1; elif [ "$MODE" = fifa16 ]; then F16_ONE=1; fi
    if [ ! -d "$TARGET" ] && [ "$TARGET_EXPLICIT" = 0 ] \
       && [ -d "$HOME/Applications/${TARGET:t}" ]; then
        TARGET="$HOME/Applications/${TARGET:t}"
    fi
    if [ -d "$TARGET" ]; then MODE=bottle; else MODE=install; fi
fi
# The ports each game's Aurora holds: --verify checks its own game's,
# --unstick frees both, since it frees every bottle.
ALL_PORTS=47170,47171,47172,47173,3216
if [ "$GAME" = fifa15 ]; then
    GAME_PORTS=3216; GAME_PORTS_LABEL=3216
elif [ "$GAME" = fifa16 ] || [ "$GAME" = fifa21 ]; then
    # FIFA 16 runs on its own: no Aurora, no port. FIFA 21's Aurora launcher
    # holds none this script knows of.
    GAME_PORTS=""; GAME_PORTS_LABEL=""
else
    GAME_PORTS=47170,47171,47172,47173; GAME_PORTS_LABEL=47170-47173
fi

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
# an editor on a log -- must never be signalled. A pid counts only if it is a
# Wine process, works inside a bottle, or holds one of our server directories.
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

# The games and Aurora programs, by name: fifa17/16/15.exe,
# Aurora17/15 Connector/Client/Server/Launcher. A Wine process shows its
# Windows command line to ps, so the name is on it -- including the
# winewrapper.exe lines that start a connector from a .lnk (those contain no
# .exe, only "Aurora15Connector-2.lnk", so matching .exe alone misses the
# wrapper and leaves a PPID-1 stray behind).
#
# Every game by default; "game_leftovers fifa17", "fifa15" or "fifa16"
# narrows it to one. --play-log needs FIFA 17's only: an Aurora15Connector
# left listening on 3216 is a normal state, not a reason to refuse to start
# Aurora17's launcher. FIFA 16 has no Aurora, so its name is the game's alone.
game_leftovers() {
    local p pat='fifa1[567]|Aurora1[57](Connector|Client|Server|Launcher)'
    case "${1:-}" in
        fifa17) pat='fifa17|Aurora17(Connector|Client|Server|Launcher)' ;;
        fifa15) pat='fifa15|Aurora15(Connector|Client|Server|Launcher)' ;;
        fifa16) pat='fifa16' ;;
    esac
    for p in ${(f)"$(ps -Ao pid=,command= 2>/dev/null \
        | grep -Ei "($pat)" \
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
#
# By bundle path, never by name. Every copy is called "CrossOver" and shares
# one bundle identifier, so 'tell application "CrossOver" to quit' reaches
# whichever one Launch Services picks first -- and with CrossOver and
# CrossOver-FIFA both open, the other stayed up and this reported "would not
# quit". AppleScript takes a POSIX path as an application specifier, and
# crossovers_running prints exactly those, one per open copy.
quit_crossovers_gui() {
    local waited=0 left app
    [ -z "$(crossovers_running)" ] && return 0
    for app in ${(f)"$(crossovers_running)"}; do
        [ -n "$app" ] || continue
        osascript -e "tell application \"${app//\"/\\\"}\" to quit" >/dev/null 2>&1 &
    done
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

# ------------------------------------------------ FIFA 15/16 one-command
# Makes the bottle with CrossOver's own tool, so --fifa15, --fifa16 and
# --offline do not send anyone to the New Bottle dialog. The copy's cxbottle is
# used, so the bottle is born pointing at the patched CrossOver. It runs
# wineboot, which takes about twenty seconds and leaves user.reg and system.reg
# behind -- the two files configure_bottle needs, and the reason a bottle
# CrossOver has never opened is not enough.
make_bottle() {
    local app="$1" cxb="$1/Contents/SharedSupport/CrossOver/bin/cxbottle" running out
    say ""
    say "Making the $BOTTLE bottle (Windows 10, 64-bit) with ${app:t}"
    [ -x "$cxb" ] || die $E_PAYLOAD "$app has no cxbottle tool inside it.
         The copy is incomplete. Run ./setup.sh again to make a fresh one."
    # A CrossOver that is open lists the bottles it found when it started and
    # would put the new one's registry back its own way on quit.
    running="$(crossovers_running)"
    if [ -n "$running" ]; then
        say "  CrossOver is still open:"
        print -r -- "$running" | sed 's/^/        /'
        die $E_PERMISSION "Quit CrossOver completely -- Command-Q, not just closing the
         window; Force Quit if it is not responding -- and run this again.
         Nothing has been touched."
    fi
    ok "making it -- this takes about twenty seconds"
    if ! out="$("$cxb" --bottle "$BOTTLE" --create --template win10_64 --description "$GAME_LABEL" 2>&1)"; then
        print -r -- "$out" | tail -5 | sed 's/^/        /'
        die $E_PERMISSION "CrossOver could not make the bottle.
         Make it yourself instead: open ${app:t}, Bottle > New Bottle,
         Windows 10 64-bit, called $BOTTLE. Then run this again."
    fi
    [ -f "$BOTTLE_DIR/$BOTTLE/user.reg" ] \
        || die $E_PAYLOAD "cxbottle said it made the bottle, but there is no user.reg in
         $BOTTLE_DIR/$BOTTLE
         Delete that folder, then run this again."
    ok "made the $BOTTLE bottle in $BOTTLE_DIR"
}

# The one file the FIFA 15 profile installs that the FIFA 17 one does not. A
# copy made by plain ./setup.sh lacks it, and re-copying a gigabyte to add one
# DLL is what --fifa15 exists to avoid. The DLL itself carries no Mac
# signature, but the bundle's seal covers every file in it, so the app has to
# be signed again afterwards -- exactly as the full install does -- or macOS
# refuses to open it. Not installing it is not a stop: the game still runs and
# the connector merely shows a crash dialog on its way out.
f15_add_gdiplus() {
    local app="$1" wine="$1/Contents/SharedSupport/CrossOver/lib/wine" f=x86_64-windows/gdiplus.dll
    if [ ! -f "$HERE/fixes/$f" ]; then
        note "fixes/${f:t} is not in this package -- Aurora15Connector will show a"
        say "        crash dialog when it closes, which is harmless"
        return 0
    fi
    if cmp -s "$HERE/fixes/$f" "$wine/$f"; then
        ok "${f:t} -- already installed"
        # A seal broken by an earlier attempt that stopped before signing.
        if ! codesign --verify --deep --strict "$app" 2>/dev/null; then
            note "the signature on ${app:t} does not verify -- signing it again"
            resign_app "$app"
        fi
        return 0
    fi
    require_app_closed "$app"
    [ -f "$wine/$f.orig" ] || cp -X "$wine/$f" "$wine/$f.orig" 2>/dev/null || true
    if cp -X "$HERE/fixes/$f" "$wine/$f" 2>/dev/null; then
        ok "${f:t} -- installed (Wine's own kept as ${f:t}.orig)"
    else
        note "could not install ${f:t} into ${app:t}"
        say "        Aurora15Connector will show a crash dialog when it closes, which"
        say "        is harmless. If you want it gone:"
        print -r -- "$APP_MGMT_HINT"
        return 0
    fi
    resign_app "$app"
}

require_app_closed() {
    app_is_running "$1" || return 0
    die $E_PERMISSION "${1:t} is open, and the $GAME_LABEL files cannot go in while it is.
         Quit it completely (Command-Q, not just closing the window), then
         run this again. Nothing has been changed."
}

# FIFA 16's win32u.so: the half of the syscall-stub fix that stops the message
# queue reading the tick count off the watched KUSER page, three faults on
# every PeekMessage and GetAsyncKeyState. A copy made before it has the older
# file and FIFA 16 stutters in play. win32u.so carries no marker, so it is
# compared by LC_UUID with the shipped one, as refresh_fixes does: installing
# rewrites the rpath and the signature, which change the bytes, not the UUID.
f16_add_win32u() {
    local app="$1" wine="$1/Contents/SharedSupport/CrossOver/lib/wine" f=x86_64-unix/win32u.so
    local want RPATH_ERR
    [ -f "$HERE/fixes/$f" ] \
        || die $E_PAYLOAD "fixes/${f:t} is missing from this package. Download it again."
    want="$(macho_uuid "$HERE/fixes/$f")"
    if [ -z "$want" ]; then
        note "could not read the build of ${f:t} (Apple's command line tools are missing),"
        say "        so it was left as it is. If FIFA 16 stutters in play, install them"
        say "        (xcode-select --install) and run this again."
        return 0
    fi
    if [ -f "$wine/$f" ] && [ "$(macho_uuid "$wine/$f")" = "$want" ]; then
        ok "${f:t} -- already the shipped build"
        return 0
    fi
    say "        ${app:t} has an older ${f:t}; FIFA 16 stutters in play with it"
    require_app_closed "$app"
    require_clt
    if [ -f "$wine/$f" ] && [ ! -f "$wine/$f.orig" ]; then
        cp -X "$wine/$f" "$wine/$f.orig" 2>/dev/null \
            || die $E_PERMISSION "Could not back up ${f:t} in ${app:t}.
$APP_MGMT_HINT"
    fi
    cp -X "$HERE/fixes/$f" "$wine/$f" \
        || die $E_PERMISSION "Could not install ${f:t} into ${app:t}.
$APP_MGMT_HINT"
    ok "${f:t} -- installed"
    if has_lib64_rpath "$wine/$f"; then
        ok "${f:t} search path -- already present"
    elif RPATH_ERR="$(install_name_tool -add_rpath "$RPATH_LIB64" "$wine/$f" 2>&1)"; then
        ok "${f:t} search path -- added"
    elif print -r -- "$RPATH_ERR" | grep -q 'would duplicate path'; then
        ok "${f:t} search path -- already present"
    else
        print -r -- "$RPATH_ERR"
        die $E_PERMISSION "Could not repair the search path in ${f:t}.
$APP_MGMT_HINT"
    fi
    sign_payload "$wine"
    resign_app "$app"
}

# The ntdll.so that fixes/ ships carries FIFA 17's five patches plus the
# top-down allocation limit FIFA 15 needs (inert until CX_TOPDOWN_LIMIT is set,
# which only the FIFA 15 bottle does). A copy made before that build has the
# older ntdll.so, and FIFA 15 in it dies seven seconds in with 0x80000004 --
# every bottle setting right, nothing in any log. The build's marker is the
# environment variable's name in the file, so that is what is looked for.
# FIFA 16 is the same story two builds later: its four patches (the
# debug-register emulation, PF_PAE, the loading-loop fix and the syscall-stub
# fix) came after, and its marker is the syscall-stub fix's log line as it
# reads since that fix covers win32u too; the builds before it loop whenever
# the heap buffer lands elsewhere, or stutter. Without the patches the
# crack's protector exits before the start screen, and without the loop fix
# the game loops forever after the language pick. NTDLL_MARKER says which one
# this game needs; f16_add_win32u above brings the win32u half.
# Installing it is the full install's steps 4 to 6 for one file: copy, the
# lib64 search path, sign the file, sign the app. This one IS a stop when it
# fails: the bottle is useless without it.
add_game_ntdll() {
    local app="$1" wine="$1/Contents/SharedSupport/CrossOver/lib/wine" f=x86_64-unix/ntdll.so
    say ""
    say "Checking ${app:t} for the $GAME_LABEL files"
    if [ ! -f "$HERE/fixes/$f" ]; then
        die $E_PAYLOAD "fixes/${f:t} is missing from this package. Download it again."
    fi
    if ! strings -a "$HERE/fixes/$f" 2>/dev/null | grep -q "$NTDLL_MARKER"; then
        die $E_PAYLOAD "fixes/${f:t} is a build without the $GAME_LABEL patch.
         Download the complete main-branch package again. $GAME_LABEL cannot run with this file."
    fi
    if strings -a "$wine/$f" 2>/dev/null | grep -q "$NTDLL_MARKER"; then
        # The game's own patch is there. A copy from before the per-game
        # profile table still gets the shipped file when this package has
        # the table: without it the game could not share a bottle, and the
        # guard near the top has already let it in on the strength of this.
        if ntdll_has_profiles "$wine/$f" || ! ntdll_has_profiles "$HERE/fixes/$f"; then
            ok "${f:t} -- already the build with the $GAME_LABEL patch"
            return 0
        fi
        say "        ${app:t} has an ${f:t} from before the per-game profile table;"
        say "        games that share a bottle get each other's settings with it"
    else
        say "        ${app:t} has $NTDLL_OLD ${f:t}; $NTDLL_WHY"
    fi
    require_app_closed "$app"
    require_clt
    if [ -f "$wine/$f.orig" ]; then
        ok "${f:t}.orig backup already there, keeping it"
    else
        cp -X "$wine/$f" "$wine/$f.orig" 2>/dev/null \
            || die $E_PERMISSION "Could not back up ${f:t} in ${app:t}.
$APP_MGMT_HINT"
    fi
    cp -X "$HERE/fixes/$f" "$wine/$f" \
        || die $E_PERMISSION "Could not install ${f:t} into ${app:t}.
$APP_MGMT_HINT"
    ok "${f:t} -- installed (the previous one kept as ${f:t}.orig)"
    if has_lib64_rpath "$wine/$f"; then
        ok "${f:t} search path -- already present"
    else
        if RPATH_ERR="$(install_name_tool -add_rpath "$RPATH_LIB64" "$wine/$f" 2>&1)"; then
            ok "${f:t} search path -- added"
        elif print -r -- "$RPATH_ERR" | grep -q 'would duplicate path'; then
            ok "${f:t} search path -- already present"
        else
            print -r -- "$RPATH_ERR"
            die $E_PERMISSION "Could not repair the search path in ${f:t}.
$APP_MGMT_HINT"
        fi
    fi
    sign_payload "$wine"
    resign_app "$app"
}

# Where the game is (game_dir_candidates: FIFA15_DIR, the player's choice,
# Aurora.exe's FifaPath, then the usual places). Aurora15Connector is pointed
# at the folder from its own window; this only needs it to say which
# ItsAMe_Origin.dll is in there.
f15_game_dir() {
    game_dir_of fifa15
}

# The crack's Origin emulator decides how the game starts, and it comes in
# three states: the CPY original (what Aurora15Connector checks for and
# replaces), the offline-patched one from fifa15/fifa15-offline.sh (the game
# runs on its own, the connector refuses it), and the connector's own. None of
# them is wrong; this says which one is there so PLAY is not a surprise.
f15_check_game() {
    local d l off="$HERE/fifa15/fifa15-offline.sh" out rc
    say ""
    say "The FIFA 15 game folder"
    if d="$(game_dir_choice_lost fifa15)"; then
        note "your choice $d is not reachable (drive not connected?)"
    fi
    if ! l="$(game_dir_line fifa15)"; then
        note "no FIFA 15 folder found (looked at Aurora.exe's record in the $BOTTLE bottle,"
        say "        ~/Downloads, ~/Desktop, ~/Games, ~/Documents, ~, /Applications and"
        say "        each drive in /Volumes). Nothing to do: the game is never modified."
        say "        If it is elsewhere and you want this check:"
        say "            FIFA15_DIR='/path/to/FIFA 15' ./setup.sh --fifa15"
        return 0
    fi
    d="${l#*$'\t'}"
    ok "fifa15.exe in $d  ($(game_dir_source_says "$l"))"
    [ -x "$off" ] || { note "fifa15/fifa15-offline.sh is not here, so ItsAMe_Origin.dll was not checked"; return 0; }
    # "if VAR=$(...)": under set -e a failing substitution in a bare assignment
    # ends the script, and "not the CPY file" is exit 3 there, not a failure.
    if out="$("$off" check "$d" 2>&1)"; then rc=0; else rc=$?; fi
    case "$rc:$out" in
        0:original*)
            ok "ItsAMe_Origin.dll is the CPY original -- what Aurora15Connector needs"
            say "        To play without the connector:  ./fifa15/fifa15-offline.sh apply \"$d\"" ;;
        0:offline*)
            ok "ItsAMe_Origin.dll is offline-patched -- run fifa15.exe from the bottle"
            print -r -- "$out" | sed 's/^/        /'
            say "        Before using Aurora15Connector:  ./fifa15/fifa15-offline.sh revert \"$d\"" ;;
        3:*)
            note "direct offline play is not ready with the installed DLL"
            print -r -- "$out" | sed 's/^/        /' ;;
        *)
            note "could not tell which ItsAMe_Origin.dll is there:"
            print -r -- "$out" | sed 's/^/        /' ;;
    esac
    return 0
}

# ------------------------------------------------- FIFA 16's game folder
# The folder is the player's own and nothing in it is checked or changed:
# FIFA 16 runs fifa16.exe straight from it, with no launcher. What the bottle
# needs is a drive letter that reaches it. A bottle cxbottle makes has y: on
# the home folder, so anything under ~ is reachable already (the run that
# proved the fix used Y:\Downloads\FIFA 16). A folder outside ~, or a bottle
# whose y: has gone, is given a letter of its own.
f16_game_dir() {
    game_dir_of fifa16
}

# Says where the game is and how the bottle reaches it. "f16_check_game map"
# also adds the drive letter when none reaches it; without "map" it changes
# nothing, which is what --verify needs. Leaves the Windows path to fifa16.exe
# in F16_EXE_WIN for the closing message.
F16_EXE_WIN=""
f16_check_game() {
    local mode="${1:-check}" d l gwin dd="$BOTTLE_DIR/$BOTTLE/dosdevices" letter=""
    say ""
    say "The FIFA 16 game folder"
    if [ -n "${FIFA16_DIR:-}" ] && [ ! -f "$FIFA16_DIR/fifa16.exe" ]; then
        note "FIFA16_DIR is $FIFA16_DIR, and there is no fifa16.exe in it"
    fi
    if d="$(game_dir_choice_lost fifa16)"; then
        note "your choice $d is not reachable (drive not connected?)"
    fi
    if ! l="$(game_dir_line fifa16)"; then
        note "no FIFA 16 folder found (looked at Aurora.exe's record in the $BOTTLE bottle,"
        say "        ~/Downloads, ~/Desktop, ~/Games, ~/Documents, ~, /Applications and"
        say "        each drive in /Volumes). The game is never modified, but the bottle"
        say "        needs a drive letter that reaches it. If it is elsewhere:"
        say "            FIFA16_DIR='/path/to/FIFA 16' ./setup.sh --fifa16"
        return 0
    fi
    d="${l#*$'\t'}"
    ok "fifa16.exe in $d  ($(game_dir_source_says "$l"))"
    if [ ! -d "$dd" ]; then
        note "the $BOTTLE bottle has no dosdevices folder, so no drive letter was checked"
        return 0
    fi
    if gwin="$(unix_path_to_win "$d" 2>/dev/null)"; then
        ok "the $BOTTLE bottle reaches it as $gwin"
        F16_EXE_WIN="$gwin\\fifa16.exe"
        return 0
    fi
    if [ "$mode" != map ]; then
        note "no drive letter in the $BOTTLE bottle reaches $d"
        say "        CrossOver's Run Command cannot browse to fifa16.exe. Fix:"
        say "            ./setup.sh --fifa16"
        return 0
    fi
    # y: first, where CrossOver itself puts the home folder, when the game is
    # under it and the letter is free. Otherwise the first free letter from
    # x: down, pointed at the game folder itself.
    if [ "${d#$HOME/}" != "$d" ] && [ ! -e "$dd/y:" ] && [ ! -L "$dd/y:" ]; then
        ln -s "$HOME" "$dd/y:" 2>/dev/null && letter=y
    else
        for letter in x w v u t s r q p o n m l k j i h; do
            [ -e "$dd/$letter:" ] || [ -L "$dd/$letter:" ] || break
            letter=""
        done
        [ -n "$letter" ] && { ln -s "$d" "$dd/$letter:" 2>/dev/null || letter=""; }
    fi
    if [ -n "$letter" ] && gwin="$(unix_path_to_win "$d" 2>/dev/null)"; then
        ok "gave the $BOTTLE bottle drive ${(U)letter}: -- the game is $gwin"
        F16_EXE_WIN="$gwin\\fifa16.exe"
    else
        note "could not give the $BOTTLE bottle a drive letter for $d"
        say "        Add one yourself: open ${BOTTLE} in CrossOver, Wine Configuration,"
        say "        Drives, Add, and point it at that folder."
    fi
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
# Which DLL depends on the game. FIFA 17: Aurora17's redirect shim is a proxy
# version.dll. FIFA 15: Aurora15Connector's EA-MITM hook (it rewrites the
# game's ProtoSSLConnect target to Aurora's server) is a proxy dinput8.dll next
# to fifa15.exe. Without the override the game loads Wine's own dinput8, talks
# to spring14.gosredirector.ea.com and says the servers are closed -- with the
# Origin/LSX side working perfectly (FIFA 15 checkpoint fact 81). FIFA 16:
# none. Nothing redirects it anywhere, and the bottle the fix was proven in
# had no override, so it gets none. FIFA 21: version, as FIFA 17. The Aurora
# launcher's proxy version.dll sits beside FIFA21.exe.
if [ "$GAME" = fifa15 ]; then OVERRIDE_DLL=dinput8; elif [ "$GAME" = fifa16 ]; then OVERRIDE_DLL=""; else OVERRIDE_DLL=version; fi
OVERRIDE_LINE="\"$OVERRIDE_DLL\"=\"native,builtin\""
# The programs the overrides are written for. Each override used to go in the
# bottle-wide section above, which is right for a bottle that holds one game
# and wrong for one that holds several: a bottle-wide msvcr110=native,builtin
# puts FIFA 16 on Microsoft's runtime too, and its loading fix was proven on
# Wine's own. So the C runtime pairs and FIFA 15's dinput8 now go under
# HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides, which Wine reads before
# the bottle-wide section, for the game's programs only. FIFA 17 has two:
# _fifa17.exe is its loader, which loads from the same folder and had these
# overrides as much as FIFA17.exe did while they were bottle-wide. FIFA 21 has
# FIFA21.exe, for its ucrtbase (see the C runtime override below). A
# bottle-wide override an earlier setup.sh wrote is left where it is and still
# counts (dll_override_is_set): removing it is not this script's to do, and
# nothing that works today should stop working.
#
# version stays bottle-wide, as it always was. The launchers put proxy
# version.dll files beside programs that are not FIFA17.exe -- Impulsum17
# beside Impulsum17Launcher.exe in the FIFA 17 folder, the Aurora launcher
# beside FIFA 13, 16 and 21 -- and every one of them was proven with the
# bottle-wide override. A bottle-wide version=native,builtin is harmless to
# FIFA 16, which has no version.dll of its own to prefer.
if [ "$GAME" = fifa15 ]; then OVERRIDE_EXES=(fifa15.exe); elif [ "$GAME" = fifa16 ]; then OVERRIDE_EXES=(); elif [ "$GAME" = fifa21 ]; then OVERRIDE_EXES=(FIFA21.exe); else OVERRIDE_EXES=(FIFA17.exe _fifa17.exe); fi

# ------------------------------------------------ the C runtime override
# An online match is a lockstep simulation: every client runs the same maths on
# the same inputs and has to arrive at the same result. Wine carries its own
# copies of the Visual C++ runtimes and by default loads those in place of
# Microsoft's, and Wine's floating point is not Microsoft's to the last bit, so
# this Mac's simulation drifted from every Windows player's and the match was
# torn down at kick-off: FIFA 17's own match report ended in GDESYNCEND and the
# player saw a disconnect seconds after the whistle. Told to prefer the native
# files, the same match played on -- and a goal was scored.
#
# Which pair depends on the game, because they were built against different
# runtimes: FIFA 17 imports msvcr120/msvcp120 (Visual Studio 2013), FIFA 15 and
# its DLLs import msvcr110/msvcp110 (Visual Studio 2012). Only those two per
# game: vcruntime140/ucrtbase and the rest are different runtimes that other
# things in the bottle use, and forcing those native breaks them.
#
# Nothing is downloaded either way. FIFA 17 ships Microsoft's own copies in its
# game folder, next to FIFA17.exe, so the override alone is enough. FIFA 15
# ships none, so f15_ensure_crt_dlls puts a Microsoft pair where the game will
# find it first -- from the FIFA 17 folder, or out of the VS2012 redistributable
# that FIFA 15 itself carries in _Redist.
#
# FIFA 16 gets neither. The override is for online matches, and FIFA 16 here
# is played offline; its loading-loop fix was found and proven on Wine's own
# msvcr110, and nothing here should move that ground under it.
#
# FIFA 21 gets no pair either. Its maths is in ucrtbase, and Aurora 21 pairs
# two players only when both run Microsoft's: the client pack's maths bridge
# loads the pinned Microsoft ucrtbase into FIFA21.exe, and under Wine that
# load comes back as Wine's own unless FIFA21.exe prefers native ucrtbase.
# The PowerShell stand-in writes that override at PLAY (for the bridge too);
# configure_bottle writes FIFA21.exe's now, for that one program only, so
# nothing else in the bottle is moved off Wine's ucrtbase.
if [ "$GAME" = fifa15 ]; then CRT_OVERRIDE_DLLS=(msvcr110 msvcp110); elif [ "$GAME" = fifa16 ] || [ "$GAME" = fifa21 ]; then CRT_OVERRIDE_DLLS=(); else CRT_OVERRIDE_DLLS=(msvcr120 msvcp120); fi

bottle_user_reg()   { print -r -- "$BOTTLE_DIR/$BOTTLE/user.reg"; }
bottle_system_reg() { print -r -- "$BOTTLE_DIR/$BOTTLE/system.reg"; }

# Is LINE there, exactly, under SECTION in the registry file REG?
# awk, not grep: the same value name turns up under other keys in the same file
# -- "version"= does, under application keys -- and setting one of those would
# do nothing while looking right. The section and line go in through the
# environment, not -v: awk -v unescapes backslashes, and every key in this file
# is full of them. The section is compared without case, as Windows and
# wineserver compare key names: a launcher may have written
# AppDefaults\\fifa17.exe where this script says FIFA17.exe, and wineserver
# merges the two into the first spelling it read. The line is compared as is.
reg_line_is_set() {
    local reg="$1"
    [ -f "$reg" ] || return 1
    A17_SEC="$2" A17_LINE="$3" awk '
        BEGIN { sec = tolower(ENVIRON["A17_SEC"]) }
        substr($0,1,1)=="[" { insec = (index(tolower($0), sec)==1); next }
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
    # Section and value name without case (see reg_line_is_set), so an
    # existing section is reused under its own spelling, not appended twice.
    if grep -qiF "$sec" "$reg"; then
        A17_SEC="$sec" A17_LINE="$line" A17_NAME="$name=" awk '
            BEGIN { sec = tolower(ENVIRON["A17_SEC"]); vname = tolower(ENVIRON["A17_NAME"]) }
            substr($0,1,1)=="[" {
                dropping = 0
                if (insec && !wrote) { print ENVIRON["A17_LINE"]; wrote=1 }
                insec = (index(tolower($0), sec)==1)
                print; next
            }
            dropping && substr($0,1,1)!="[" {
                if (substr($0, length($0), 1) != "\\") dropping = 0
                next
            }
            insec && index(tolower($0), vname)==1 {
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

# The DllOverrides key of one program, in the form user.reg spells it.
appdefaults_section() { print -r -- '[Software\\Wine\\AppDefaults\\'"$1"'\\DllOverrides]'; }

# DLL=native,builtin for every one of this game's programs, or bottle-wide.
dll_override_is_set() {
    local exe line="\"$1\"=\"native,builtin\""
    reg_line_is_set "$(bottle_user_reg)" "$OVERRIDE_SECTION" "$line" && return 0
    [ ${#OVERRIDE_EXES} -gt 0 ] || return 1
    for exe in $OVERRIDE_EXES; do
        reg_line_is_set "$(bottle_user_reg)" "$(appdefaults_section "$exe")" "$line" || return 1
    done
    return 0
}
# Written per program (see OVERRIDE_EXES), except version, which is
# bottle-wide (see OVERRIDE_EXES).
set_dll_override() {
    local dll="$1" exe
    if [ "$dll" = version ]; then
        set_reg_line "$(bottle_user_reg)" "$OVERRIDE_SECTION" "\"$dll\"=\"native,builtin\"" "\"$dll\""
        return
    fi
    for exe in $OVERRIDE_EXES; do
        set_reg_line "$(bottle_user_reg)" "$(appdefaults_section "$exe")" \
            "\"$dll\"=\"native,builtin\"" "\"$dll\"" || return 1
    done
    return 0
}
# Whether this override is bottle-wide in this bottle, from an earlier setup.sh.
dll_override_is_global() {
    reg_line_is_set "$(bottle_user_reg)" "$OVERRIDE_SECTION" "\"$1\"=\"native,builtin\""
}

# version counts only bottle-wide: a per-program one would miss the launchers'
# proxies beside other programs (see OVERRIDE_EXES).
version_override_is_set() {
    if [ "$OVERRIDE_DLL" = version ]; then dll_override_is_global version
    else dll_override_is_set "$OVERRIDE_DLL"; fi
}
set_version_override()    { set_dll_override "$OVERRIDE_DLL"; }

# See the C runtime override above. Same file, one line per DLL per program.
crt_override_is_set() {
    local dll
    for dll in $CRT_OVERRIDE_DLLS; do
        dll_override_is_set "$dll" || return 1
    done
    return 0
}
set_crt_override() {
    local dll
    for dll in $CRT_OVERRIDE_DLLS; do
        set_dll_override "$dll" || return 1
    done
    return 0
}

# FIFA 16 runs on Wine's own msvcr110/msvcp110: its loading fix was found and
# proven there. A bottle FIFA 15 was set up in by an earlier setup.sh has
# both bottle-wide as native,builtin, and in that bottle fifa16.exe would load
# Microsoft's wherever it found one. A per-program "builtin" outranks the
# bottle-wide value, so fifa16.exe is pinned to Wine's own -- only where such
# a bottle-wide value is there to outrank. A FIFA 16 bottle without one is
# left exactly as the fix was proven in.
F16_CRT_PIN=(msvcr110 msvcp110)
f16_crt_pin_needed() {
    local dll
    for dll in $F16_CRT_PIN; do
        reg_line_is_set "$(bottle_user_reg)" "$OVERRIDE_SECTION" "\"$dll\"=\"native" && return 0
    done
    return 1
}
f16_crt_is_pinned() {
    local dll
    for dll in $F16_CRT_PIN; do
        reg_line_is_set "$(bottle_user_reg)" "$(appdefaults_section fifa16.exe)" "\"$dll\"=\"builtin\"" || return 1
    done
    return 0
}
f16_pin_crt() {
    local dll
    for dll in $F16_CRT_PIN; do
        set_reg_line "$(bottle_user_reg)" "$(appdefaults_section fifa16.exe)" \
            "\"$dll\"=\"builtin\"" "\"$dll\"" || return 1
    done
    return 0
}

# Is this DLL Microsoft's own, and not Wine's stand-in for it? Wine's builtins
# carry the string "Wine builtin DLL" in the clear. A real Microsoft one carries
# "Microsoft Corporation" in its version resource, which is UTF-16 -- every
# letter followed by a zero byte -- hence the dots in the pattern. Both greps
# read the file as text because these are binaries and grep would otherwise
# only say "binary file matches" and, worse, stop at the first NUL on some
# systems.
crt_dll_is_microsoft() {
    local f="$1"
    [ -f "$f" ] || return 1
    LC_ALL=C grep -qa "Wine builtin DLL" "$f" && return 1
    LC_ALL=C grep -qa "M.i.c.r.o.s.o.f.t. .C.o.r.p" "$f"
}

# Microsoft's copies of BOTH of this game's runtime DLLs, in one directory.
crt_dlls_are_microsoft_in() {
    local dir="$1" dll
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    for dll in $CRT_OVERRIDE_DLLS; do
        crt_dll_is_microsoft "$dir/$dll.dll" || return 1
    done
    return 0
}

# Where FIFA 15 will actually find a Microsoft pair -- printed, so the report
# can say where. Windows looks in the program's own folder before system32, and
# the bottle's system32 holds Wine's own copies unless a redistributable has
# been installed over them, so the game folder is asked first.
f15_crt_native_dir() {
    local d
    d="$(f15_game_dir 2>/dev/null || true)"
    if [ -n "$d" ] && crt_dlls_are_microsoft_in "$d"; then print -r -- "$d"; return 0; fi
    d="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32"
    if crt_dlls_are_microsoft_in "$d"; then print -r -- "$d"; return 0; fi
    return 1
}

# A FIFA 17 install is the cheapest source of the pair FIFA 15 needs: its game
# folder ships Microsoft's own msvcr110/msvcp110 as well as the 120 pair FIFA 17
# itself loads. Every FIFA 17 folder game_dir_candidates knows of, a drive in
# /Volumes and the launchers' records included, but asking for the DLLs rather
# than for the loader -- this runs under GAME=fifa15, where nothing has been
# told where FIFA 17 is.
f15_crt_donor_dir() {
    local l
    for l in ${(f)"$(game_dir_candidates fifa17)"}; do
        crt_dlls_are_microsoft_in "${l#*$'\t'}" && { print -r -- "${l#*$'\t'}"; return 0; }
    done
    return 1
}

# Puts a Microsoft-built C runtime where FIFA 15 will load it from. The registry
# override only says "prefer the native file"; with no native file to prefer,
# Wine loads its own and the match desyncs just the same. FIFA 17 needs none of
# this -- Microsoft's copies ship beside FIFA17.exe -- but FIFA 15's folder has
# none, and the ones in the bottle's system32 are Wine's.
#
# Three sources, cheapest first, and not one of them downloads anything: the
# pair already sitting in a FIFA 17 folder on this Mac, then the VS2012
# redistributable FIFA 15 itself carries in _Redist, then a note asking for the
# files. Never a stop: only an online match cares.
f15_ensure_crt_dlls() {
    local app="$1" d src dll redist rwin wine sys wpid waited=0
    d="$(f15_game_dir 2>/dev/null || true)"
    if [ -z "$d" ]; then
        note "no FIFA 15 folder found, so its C runtime was not checked"
        say "        For a game kept elsewhere:  FIFA15_DIR='/path/to/FIFA 15' ./setup.sh --fifa15"
        return 1
    fi
    if crt_dlls_are_microsoft_in "$d"; then
        ok "${(j: + :)CRT_OVERRIDE_DLLS} — Microsoft's own, already beside fifa15.exe"
        return 0
    fi
    if src="$(f15_crt_donor_dir)"; then
        # Added beside the game, not over it: these two files are not part of
        # FIFA 15 and nothing of the game's own is touched.
        for dll in $CRT_OVERRIDE_DLLS; do
            cp -p "$src/$dll.dll" "$d/$dll.dll" 2>/dev/null || break
        done
        if crt_dlls_are_microsoft_in "$d"; then
            ok "${(j: + :)CRT_OVERRIDE_DLLS} — copied Microsoft's own beside fifa15.exe"
            say "        from $src (nothing downloaded: they were already on this Mac)"
            return 0
        fi
        note "could not copy the C runtime from $src into $d"
    fi
    redist="$d/_Redist/vcredist_x64_2012_x64.exe"
    wine="$app/Contents/SharedSupport/CrossOver/bin/wine"
    sys="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32"
    if [ -f "$redist" ] && [ -x "$wine" ] && rwin="$(unix_path_to_win "$d/_Redist" 2>/dev/null)"; then
        say "        installing ${redist:t} in the bottle — this takes a minute"
        # --wait-children because the redistributable hands the real work to a
        # second process and returns; the wrapper would otherwise be back before
        # a single file had been written.
        "$wine" --bottle "$BOTTLE" --wait-children --workdir "$d/_Redist" \
            --cx-app "$rwin\\${redist:t}" /install /quiet /norestart >/dev/null 2>&1 &
        wpid=$!
        # Bounded: an installer that puts a dialog up behind every other window
        # would otherwise hold the install open for as long as the user is away.
        while [ "$waited" -lt 180 ] && kill -0 "$wpid" 2>/dev/null; do
            /bin/sleep 1
            waited=$((waited + 1))
        done
        kill -TERM "$wpid" 2>/dev/null || true
        wait "$wpid" 2>/dev/null || true
        if crt_dlls_are_microsoft_in "$sys"; then
            ok "${(j: + :)CRT_OVERRIDE_DLLS} — installed into the bottle's system32 (${waited}s)"
            say "        from the game's own _Redist folder"
            return 0
        fi
        note "the VS2012 redistributable ran but system32 still holds Wine's own runtime"
    fi
    note "no Microsoft copy of ${(j: or :)CRT_OVERRIDE_DLLS} anywhere this looked"
    say "        Copy msvcr110.dll and msvcp110.dll from a Windows machine, or from"
    say "        a FIFA 17 install, into  $d"
    say "        Offline play is unaffected; online matches desync at kick-off."
    return 1
}

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

# ------------------------------------------- the licence guard on the shims
# The two shortcuts CrossOver shows for the game itself -- _fifa17.lnk and
# FIFA17.lnk -- start the loader directly, without Aurora and without this
# script. That is a perfectly good way to play single player, and it is the
# obvious thing to click in CrossOver's bottle window, so people do. It is
# also the one launch path with no §18 guard on it: Aurora's PLAY seeds the
# licence itself (ensure_licence in aurora17/aurora-pwsh.c) and --play-offline
# now does too, but a click here went straight to the loader. Remake the
# bottle in CrossOver after installing and that click is a launch into the
# 0xFFFFFFFA failure with nothing on screen to say why.
#
# A cxmenu shim is a two-line /bin/sh script, so the guard is a line in front
# of its exec. It is deliberately toothless: output discarded, always true, so
# a moved or deleted release folder costs the shim nothing and the game starts
# exactly as it does today. --ensure-licence returns in milliseconds when the
# file is already there, which is every click after the first.
GUARD_MARK='# aurora17-licence-guard'

guard_menu_shims() {
    local self="$1" app="$2" f n=0 tmp line
    # The bottle and the app are named outright rather than left to the
    # defaults: this shim belongs to one bottle, and someone running with
    # AURORA_BOTTLE set has a shim per bottle, each of which must top up its
    # own. A shim that seeded the default bottle instead would report success
    # having done nothing for the game about to start.
    line="AURORA_BOTTLE=\"$BOTTLE\" AURORA_TARGET=\"$app\" \"$self\" --ensure-licence >/dev/null 2>&1 || true"
    for f in ${(f)"$(menu_shims)"}; do
        [ -n "$f" ] || continue
        # Only the game's own shortcuts. Aurora17Connector.lnk is left alone:
        # it seeds the licence on PLAY by itself, and it is not the loader.
        grep -qi '[/\\]_\{0,1\}fifa17\.lnk' "$f" || continue
        # Already guarded, by this same release folder: nothing to do.
        if grep -q "$GUARD_MARK" "$f" && grep -qF -- "$line" "$f"; then
            continue
        fi
        [ -f "$f.bak-aurora17" ] || cp -X "$f" "$f.bak-aurora17" 2>/dev/null || cp "$f" "$f.bak-aurora17" || return 1
        tmp="$(mktemp -t a17shim)" || return 1
        # Strip any guard from an older run (the marker and the line under it),
        # then put the current one back in front of the exec. Writing through
        # cat keeps the shim's own mode bits -- it has to stay executable.
        awk -v m="$GUARD_MARK" -v g="$line" '
            skip            { skip = 0; next }
            $0 == m         { skip = 1; next }
            !ins && /^exec / { print m; print g; ins = 1 }
                            { print }
        ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
        grep -q "$GUARD_MARK" "$tmp" || { rm -f "$tmp"; return 1; }
        cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
        n=$((n+1))
    done
    print -r -- "$n"
}

# Shims that start the game with no guard on them -- what --verify reports.
unguarded_menu_shims() {
    local f
    for f in ${(f)"$(menu_shims)"}; do
        [ -n "$f" ] || continue
        grep -qi '[/\\]_\{0,1\}fifa17\.lnk' "$f" || continue
        grep -q "$GUARD_MARK" "$f" || print -r -- "$f"
    done
}

# ------------------------------------------- the bottle's certificate store
# Reported by --report only, and settled on 2026-09-05: the count is a SYMPTOM
# of how far a launch got, never a cause. Wine fills HKLM\...\Root\Certificates
# from the Mac's own trust store the first time any process in the bottle opens
# the Root store (crypt32's CRYPT_ImportSystemRootCertsToReg, which writes
# Microsoft's five roots before it asks macOS for the rest, so an import that
# started at all leaves at least five). In every bundle seen, the first thing
# to open that store is the game's EA login step: on the reference machine the
# 163 entries carry the registry timestamp of the first launch, two seconds
# before the shim's first origin-auth-code-entry; a tester's bottle went from
# 0 to 161 in the very launch that first issued an auth code. So 0 means "no
# launch in this bottle has ever reached the EA login", which the shim log
# says more directly, and a bottle that plays online cannot have 0. Do not
# make --verify fail on it, and do not try to fill it: there is nothing to
# fill it with that the login step would not do itself.
root_cert_count() {
    local reg="$BOTTLE_DIR/$BOTTLE/system.reg" n
    [ -f "$reg" ] || { print -r -- 0; return 1 }
    # grep -c prints 0 AND exits 1 on no match, so a "|| print 0" fallback
    # printed the zero twice (visible in one tester's report).
    n="$(grep -c 'SystemCertificates\\\\Root\\\\Certificates\\\\' "$reg" 2>/dev/null || true)"
    print -r -- "${n:-0}"
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
    ent="$(mktemp -t cxent)"
    after="$(mktemp -t cxent)"

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
# of any length collapses to one slash. The mapping itself is the folder
# gate's (cxg_win_to_unix in fixes/x86_64-unix/cx-fifa17-gate), which has to do
# the same at every game start: one copy, not two.
win_path_to_unix() {
    cxg_win_to_unix "$BOTTLE_DIR/$BOTTLE" "$1"
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

# Every folder FIFA 17 might be played from, one per line as
# "sources<TAB>Mac path", best first, each with FIFA17.exe in it. The order:
#   AURORA_GAME_DIR   said outright, always first
#   gate log          where FIFA17.exe last actually started in this bottle
#                     (the folder gate writes cxfifa-gate.log in the bottle)
#   CAS               HKCU\Software\CAS\Launcher  FifaFolder
#   Impulsum17        its Inno uninstall key's InstallLocation (it installs
#                     itself into the game folder)
#   Aurora.exe        Aurora15Connector.ini  Fifa17Path (often empty: Aurora
#                     finds FIFA 17 on its own)
#   Aurora17          the old connector's connector.json gameDirectory
#   EA registry       EA Sports\FIFA 17  Install Dir
#   guess             ~/Downloads, ~/Desktop, ~/Games, ~ (and FIFA17_DIR)
# Until the launchers' own records were read here, the home-folder guesses
# came second and won: on a Mac with a stray ~/Downloads/FIFA 17, --verify,
# the licence seeding and Impulsum17's check all looked at a folder no
# launcher used. The same folder named by several sources is one line.
fifa17_dir_candidates() {
    local reg w log d sec
    local -A FC_SRC; local -a FC_ORDER
    FC_SRC=(); FC_ORDER=()
    _fifa17_cand() {
        local d="$2"
        [ -n "$d" ] || return 0
        [ -f "$d/FIFA17.exe" ] || return 0
        d="${d:A}"
        if (( ${+FC_SRC[$d]} )); then
            [[ ", ${FC_SRC[$d]}, " == *", $1, "* ]] || FC_SRC[$d]="${FC_SRC[$d]}, $1"
        else
            FC_SRC[$d]="$1"; FC_ORDER+=( "$d" )
        fi
    }
    _fifa17_win() { local u; u="$(win_path_to_unix "$2" 2>/dev/null)" && _fifa17_cand "$1" "$u"; return 0; }
    _fifa17_cand AURORA_GAME_DIR "${AURORA_GAME_DIR:-}"
    log="$BOTTLE_DIR/$BOTTLE/cxfifa-gate.log"
    if [ -f "$log" ]; then
        d="$(awk -F'\t' 'tolower($2) == "fifa17.exe" && $3 != "-" { d = $3 } END { print d }' "$log" 2>/dev/null)"
        _fifa17_cand "gate log" "$d"
    fi
    reg="$(bottle_user_reg)"
    w="$(reg_value "$reg" '[Software\\CAS\\Launcher]' FifaFolder 2>/dev/null || true)"
    _fifa17_win CAS "$w"
    reg="$(bottle_system_reg)"
    for sec in '[Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\'"$IMPULSUM_UNINSTALL_KEY"']' \
               '[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\'"$IMPULSUM_UNINSTALL_KEY"']'; do
        w="$(reg_value "$reg" "$sec" InstallLocation 2>/dev/null || true)"
        _fifa17_win Impulsum17 "$w"
    done
    d="$(aurora_ini_dir Fifa17Path 2>/dev/null || true)"
    _fifa17_cand Aurora.exe "$d"
    w="$(connector_game_dir 2>/dev/null || true)"
    _fifa17_win Aurora17 "$w"
    for sec in '[Software\\Wow6432Node\\EA Sports\\FIFA 17]' '[Software\\EA Sports\\FIFA 17]'; do
        w="$(reg_value "$reg" "$sec" "Install Dir" 2>/dev/null || true)"
        _fifa17_win "EA registry" "$w"
    done
    for d in "${FIFA17_DIR:-}" "$HOME/Downloads/FIFA 17" "$HOME/FIFA 17" "$HOME/Desktop/FIFA 17" \
             "$HOME/Games/FIFA 17"; do
        _fifa17_cand guess "$d"
    done
    for d in $FC_ORDER; do print -r -- "${FC_SRC[$d]}	$d"; done
    return 0
}
# Impulsum17's Inno Setup AppId, which names its uninstall key.
IMPULSUM_UNINSTALL_KEY='{8F3C5E0A-1C34-4D8E-9E1B-7C2A5D9F1707}_is1'

# Where FIFA 17 is, in macOS terms, for the things that start its loader
# (the licence seeding, --play-offline, the offline menu entry): the first
# folder above that also has _fifa17.exe in it.
game_dir_find() {
    local l
    for l in ${(f)"$(fifa17_dir_candidates)"}; do
        [ -f "${l#*$'\t'}/_fifa17.exe" ] && { print -r -- "${l#*$'\t'}"; return 0; }
    done
    return 1
}

# /Users/me/Downloads/FIFA 17 -> Y:\Downloads\FIFA 17, through the bottle's own
# dosdevices links, longest match first so y: beats z:. The loader is started by
# drive letter because that is how CrossOver starts it, and how the run that
# proved this worked. The folder gate's mapping, as above.
unix_path_to_win() {
    cxg_unix_to_win "$BOTTLE_DIR/$BOTTLE" "$1"
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
    local app="$1" force="${2:-0}" lic gdu gwin wine waited=0 wpid prev="" kept=""
    lic="$(bottle_licence_file)"
    # Presence is all the rest of this script has ever tested, and a file that
    # is there but is not the blob _fifa17.exe writes passes every check while
    # the game behaves as though it had none: it will not start from Aurora or
    # from FIFA17.exe, one loader run fixes it, and something later puts the
    # wrong bytes back. There is no safe constant to compare against -- the EA
    # App writes a different 1649-byte file than the loader does -- so the only
    # honest check is to make the loader write a fresh one and show both hashes.
    if [ -f "$lic" ] && [ "$force" != 1 ]; then
        ok "the licence file is already there ($(stat -f%z "$lic") bytes)"
        return 0
    fi
    if [ -f "$lic" ]; then
        prev="$(shasum -a 256 "$lic" | cut -c1-16)"
        kept="$lic.aurora17-previous"
        # Kept, not deleted: if the loader writes nothing we put it back, so a
        # forced re-seed can never leave a bottle worse off than it found it.
        mv -f "$lic" "$kept" 2>/dev/null || { note "could not move the old licence file aside"; return 1; }
        say "        replacing the licence file that is there now ($prev)"
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
        local now; now="$(shasum -a 256 "$lic" | cut -c1-16)"
        ok "wrote the licence file after ${waited}s ($(stat -f%z "$lic") bytes, $now)"
        if [ -n "$prev" ] && [ "$prev" != "$now" ]; then
            note "the licence file changed: $prev -> $now"
            say "        The old one was not what the loader writes, which is why the"
            say "        game would not start with it. Nothing else reports this,"
            say "        because every other check only asks whether the file exists."
        elif [ -n "$prev" ]; then
            ok "unchanged, so the licence file was not the problem ($now)"
        fi
        [ -n "$kept" ] && rm -f "$kept" 2>/dev/null
        return 0
    fi
    if [ -n "$kept" ]; then
        mv -f "$kept" "$lic" 2>/dev/null || true
        note "the loader wrote nothing, so the licence file that was there is back."
    fi
    note "the loader ran for ${waited}s and wrote no licence file:"
    say "        $lic"
    say "        Start FIFA 17 once from CrossOver and let it reach its menu."
    return 1
}

# The bottle menu entry an offline install adds, so the game can be started the
# way everything else in CrossOver is: open the copy, click the entry. The GUI
# is what an offline session otherwise lacks -- started this way there is a
# CrossOver window running, so --unstick stands down on its own
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

# Whether Aurora17 has actually been used in this bottle, whatever the receipt
# says. Either signal is written by Aurora itself and by nothing else: the
# hosts receipt it leaves once it owns the EA mappings, and the game folder its
# connector records on the first PLAY.
aurora_in_use() {
    local rc gd
    rc="$(hosts_receipt_file 2>/dev/null || true)"
    [ -n "$rc" ] && [ -f "$rc" ] && return 0
    gd="$(connector_game_dir 2>/dev/null || true)"
    [ -n "$gd" ] && return 0
    return 1
}

# ------------------------------------------------ every game in the bottle
# A bottle can now hold every game, and the launchers start them in it, so
# "is FIFA 17 set up" is no longer the whole question. --verify with no game
# named answers the rest in two tables: the games (folder, settings, DLL
# overrides, and the game started offline with no launcher), then the
# launchers, one row per game each one starts. Each state is "ready",
# "missing <the first thing it lacks>" or "not installed"; a launcher that
# does not start a game has no row for it. It reads files and changes
# nothing. A state that
# says ready has passed the same static checks as the rest of --verify, which
# is not the same as a launch: see the closing words of verify_install.
#
# Where each launcher lives, as each one installs itself:
#   Aurora.exe   the Aurora launcher (FIFA 13, 15, 16, 17, 21). It installs
#                itself into the bottle as AppData\Local\Aurora15Connector\
#                Aurora15Connector.exe, and keeps the game folders it was
#                given in Aurora15Connector.ini there.
#   Impulsum17   an Inno installer that puts Impulsum17Launcher.exe and its
#                own version.dll into the FIFA 17 folder itself (FIFA 17 only).
#   CAS          per user, AppData\Local\CAS\cas.exe (FIFA 17 only here).
#   RebornFUT    a folder unzipped on the Mac (RebornFUT-3.1.45 and the like)
#                holding RebornFUT.exe (FIFA 17 only). REBORN_DIR names one
#                kept somewhere else.
#   direct       the game's own exe from the bottle, no launcher.
GT_GAMES=( fifa13 fifa15 fifa16 fifa17 fifa21 )
GT_LAUNCHERS=( aurora impulsum cas reborn direct )

game_label_of() { print -r -- "FIFA ${1#fifa}"; }
gt_launcher_label() {
    case "$1" in
        aurora) print -r -- Aurora.exe ;; impulsum) print -r -- Impulsum17 ;;
        cas) print -r -- CAS ;; reborn) print -r -- RebornFUT ;; *) print -r -- "$1" ;;
    esac
}
# The value NAME has under SECTION in REG, quotes taken off. SECTION is in
# the file's own spelling, brackets and doubled backslashes included, and is
# compared without case, as Windows does: the launchers write FIFA21.exe and
# a person may write fifa21.exe.
reg_value() {
    local reg="$1"
    [ -f "$reg" ] || return 1
    A17_SEC="$2" A17_NAME="\"$3\"=" awk '
        BEGIN { sec = tolower(ENVIRON["A17_SEC"]); name = tolower(ENVIRON["A17_NAME"]) }
        substr($0,1,1)=="[" { insec = (index(tolower($0), sec)==1); next }
        insec && index(tolower($0), name)==1 { v = substr($0, length(name)+1); found = 1 }
        END { if (!found) exit 1; sub(/\r$/, "", v); gsub(/^"|"$/, "", v); print v }
    ' "$reg"
}

# The Aurora launcher's folder in the bottle, if it has been run there.
aurora_launcher_dir() {
    local a d
    a="$(bottle_appdata 2>/dev/null)" || return 1
    d="${a:h}/Aurora15Connector"
    [ -f "$d/Aurora15Connector.exe" ] || [ -f "$d/Aurora.exe" ] || return 1
    print -r -- "$d"
}

# A game folder the Aurora launcher was pointed at, from its own ini, as a
# Mac path. KEY is the ini's: FifaPath (FIFA 15), Fifa13Path, Fifa16Path...
aurora_ini_dir() {
    local d ini w
    d="$(aurora_launcher_dir)" || return 1
    ini="$d/Aurora15Connector.ini"
    [ -f "$ini" ] || return 1
    w="$(sed -n "s/^$1=//p" "$ini" | tr -d '\r' | tail -1)"
    [ -n "$w" ] || return 1
    win_path_to_unix "$w"
}

# ------------------------------------------------- where each game is
# The folders the player picked in "Choose game folders", one line per game as
# fifa15.folder=/Volumes/Untitled/FIFA 15. It lives outside the package, so a
# new zip keeps it, and uninstall.sh removes it with the rest of the folder.
# Only read here: --choose-folder writes it.
# Where external drives are mounted. Tests point it at a folder of their own,
# because a real Mac may well have a FIFA folder on a real drive.
VOLUMES_DIR="${CX_VOLUMES_DIR:-/Volumes}"

# The folder the player chose for GAME, whether or not it is there today.
# Read line by line, never sourced: a path is only ever a value.
game_dir_choice() {
    local d
    [ -f "$CHOICES_FILE" ] || return 1
    d="$(sed -n "s/^$1\.folder=//p" "$CHOICES_FILE" | tr -d '\r' | tail -1)"
    [ -n "$d" ] || return 1
    print -r -- "$d"
}

# The chosen folder when it has no game in it today: an unplugged drive, most
# likely. The search goes on without it, and --verify says so rather than
# quietly using another folder in its place.
game_dir_choice_lost() {
    local d
    d="$(game_dir_choice "$1")" || return 1
    [ -f "$d/$(game_exe_of "$1")" ] && return 1
    print -r -- "$d"
}

# Every folder GAME might be played from, one per line as "sources<TAB>Mac
# path", best first, each with the game's exe in it. The order:
#   FIFAnn_DIR        said outright for this run, always first (FIFA 17's is
#                     AURORA_GAME_DIR, as it always was)
#   chosen            the player's choice in choices.conf
#   the launchers     what they recorded in this bottle: for FIFA 17 every
#                     record fifa17_dir_candidates reads (gate log, CAS,
#                     Impulsum17, Aurora.exe, Aurora17, EA registry); for the
#                     others the Aurora launcher's ini (Aurora.exe): FifaPath
#                     for FIFA 15, Fifa13Path, Fifa16Path, Fifa21Path
#   guess             ~/Downloads, ~/Desktop, ~/Games, ~/Documents, ~,
#                     /Applications, then each drive in /Volumes, one level
#                     down (FIFA 15, FIFA-15 or FIFA_15)
# FIFA 15 and 16 used to look only in the home folders, and those guesses came
# before the launcher's record: a game kept on an external drive was "not
# found" by --fifa15, and a stray ~/Downloads/FIFA 15 beat the folder Aurora.exe
# plays. FIFA 17 had the same fault until fifa17_dir_candidates; this is that
# order for every game. The same folder named by several sources is one line.
game_dir_candidates() {
    local g="$1" n="${1#fifa}" exe var key l s
    local -A GC_SRC; local -a GC_ORDER
    GC_SRC=(); GC_ORDER=()
    exe="$(game_exe_of "$g")"
    [ -n "$exe" ] || return 1
    _game_cand() {
        local d="$2"
        [ -n "$d" ] || return 0
        [ -f "$d/$exe" ] || return 0
        d="${d:A}"
        if (( ${+GC_SRC[$d]} )); then
            [[ ", ${GC_SRC[$d]}, " == *", $1, "* ]] || GC_SRC[$d]="${GC_SRC[$d]}, $1"
        else
            GC_SRC[$d]="$1"; GC_ORDER+=( "$d" )
        fi
    }
    if [ "$g" = fifa17 ]; then var=AURORA_GAME_DIR; else var="FIFA${n}_DIR"; fi
    _game_cand "$var" "${(P)var:-}"
    _game_cand chosen "$(game_dir_choice "$g" 2>/dev/null || true)"
    if [ "$g" = fifa17 ]; then
        # Its own list already ends with the home-folder guesses; the drives
        # below come after them.
        for l in ${(f)"$(fifa17_dir_candidates)"}; do
            for s in "${(@s:, :)l%%$'\t'*}"; do _game_cand "$s" "${l#*$'\t'}"; done
        done
    else
        case "$g" in fifa15) key=FifaPath ;; *) key="Fifa${n}Path" ;; esac
        _game_cand Aurora.exe "$(aurora_ini_dir "$key" 2>/dev/null || true)"
    fi
    for l in "$HOME/Downloads/FIFA $n" "$HOME/Desktop/FIFA $n" "$HOME/Games/FIFA $n" \
             "$HOME/Documents/FIFA $n" "$HOME/FIFA $n" "/Applications/FIFA $n" \
             "$VOLUMES_DIR"/*/FIFA(\ |-|_)$n(N/); do
        _game_cand guess "$l"
    done
    for l in $GC_ORDER; do print -r -- "${GC_SRC[$l]}	$l"; done
    return 0
}

# The folder a game is played from, as "sources<TAB>Mac path": the first of
# game_dir_candidates.
game_dir_line() {
    local l
    l="$(game_dir_candidates "$1" | head -1)"
    [ -n "$l" ] || return 1
    print -r -- "$l"
}

# Where a game is, as a Mac path.
game_dir_of() {
    local l
    l="$(game_dir_line "$1")" || return 1
    print -r -- "${l#*$'\t'}"
}

# How the first source of a game_dir_candidates line reads beside the folder:
# "Aurora.exe's record", "your choice", "guess", or the variable that named it.
game_dir_source_says() {
    local s="${1%%$'\t'*}"
    s="${s%%,*}"
    case "$s" in
        chosen)        print -r -- "your choice" ;;
        guess)         print -r -- "guess" ;;
        *_DIR)         print -r -- "$s" ;;
        "gate log")    print -r -- "where it last started" ;;
        "EA registry") print -r -- "EA's registry" ;;
        *)             print -r -- "$s's record" ;;
    esac
}

# Where the game's own Wine settings come from in this bottle:
#   table        the copy's ntdll.so, by the program's name
#   AppDefaults  HKCU\Software\Wine\AppDefaults\<exe>\CrossOver-FIFA says
#                otherwise for this program
#   bare env     the bottle's [EnvironmentVariables], as before the table
#   missing ...  none of them gives the game what it needs
# FIFA 13 is not in the table and needs nothing anyone knows of, so it runs
# with whatever the bottle has.
game_settings_source() {
    local g="$1" exe sec prof k v reg; local -a got lack
    reg="$(bottle_user_reg)"
    exe="$(game_exe_of "$g")"
    got=(); lack=()
    if [ "$PROFILES" = 1 ]; then
        sec='[Software\\Wine\\AppDefaults\\'"$exe"'\\CrossOver-FIFA]'
        prof="$(reg_value "$reg" "$sec" Profile 2>/dev/null || true)"
        [ -n "$prof" ] && got+=( "Profile=$prof" )
        for k in DrTrap TopdownLimit Fifa16DstFix; do
            v="$(reg_value "$reg" "$sec" "$k" 2>/dev/null || true)"
            [ -n "$v" ] && got+=( "$k=$v" )
        done
        # PAE is the one FIFA 16 need the table cannot meet per program.
        # CX_PF_PAE=1 or a bare CX_DR_TRAP=3 turns it on (bottle_pae_on).
        if [ "$g" = fifa16 ] && ! bottle_pae_on; then
            lack+=( "CX_PF_PAE=1" )
        fi
        if [ ${#got} -gt 0 ]; then v="AppDefaults (${(j:, :)got})"
        elif [ "$g" = fifa13 ]; then v="bare env"
        else v="table"; fi
        [ ${#lack} -gt 0 ] && v="$v; missing ${(j: :)lack}"
        print -r -- "$v"
        return 0
    fi
    case "$g" in
        fifa15) [ -n "$(conf_value CX_TOPDOWN_LIMIT)" ] || lack+=( CX_TOPDOWN_LIMIT ) ;;
        fifa16) [ "$(conf_value CX_DR_TRAP)" = 3 ] || lack+=( "CX_DR_TRAP=3" )
                [ -n "$(conf_value CX_FIFA16_DSTFIX)" ] || lack+=( CX_FIFA16_DSTFIX ) ;;
        fifa17|fifa21) [ "$(conf_value CX_DR_TRAP)" = 2 ] || lack+=( "CX_DR_TRAP=2" ) ;;
    esac
    if [ ${#lack} -gt 0 ]; then print -r -- "missing ${(j: :)lack}"; else print -r -- "bare env"; fi
}

# DLL=native... for the whole bottle.
dll_native_global() {
    local v
    v="$(reg_value "$(bottle_user_reg)" "$OVERRIDE_SECTION" "$1" 2>/dev/null || true)"
    [[ "$v" == native* ]]
}

# DLL=native... for every one of these programs, or for the whole bottle.
dll_native_for() {
    local dll="$1" reg exe v; shift
    reg="$(bottle_user_reg)"
    v="$(reg_value "$reg" "$OVERRIDE_SECTION" "$dll" 2>/dev/null || true)"
    [[ "$v" == native* ]] && return 0
    for exe in "$@"; do
        v="$(reg_value "$reg" "$(appdefaults_section "$exe")" "$dll" 2>/dev/null || true)"
        [[ "$v" == native* ]] || return 1
    done
    return 0
}

# The DLL overrides a game needs, as one cell: the ones that are there, or
# "missing" and the ones that are not.
game_dlls() {
    local g="$1" dll reg; local -a want have lack exes
    reg="$(bottle_user_reg)"
    want=(); exes=()
    case "$g" in
        fifa13) print -r -- "none known"; return 0 ;;
        fifa15) want=( dinput8 msvcr110 msvcp110 ); exes=( fifa15.exe ) ;;
        fifa17) want=( version msvcr120 msvcp120 ); exes=( FIFA17.exe _fifa17.exe ) ;;
        fifa16)
            # Wine's own runtime is the point (see f16_pin_crt).
            if f16_crt_pin_needed && ! f16_crt_is_pinned; then
                print -r -- "missing msvcr110 builtin pin"
            elif f16_crt_is_pinned; then
                print -r -- "msvcr110 msvcp110 builtin"
            else
                print -r -- "none needed"
            fi
            return 0 ;;
        fifa21)
            # The Aurora launcher's PowerShell stand-in writes this at PLAY.
            if dll_native_for ucrtbase FIFA21.exe; then print -r -- "ucrtbase"
            else print -r -- "ucrtbase at PLAY"; fi
            return 0 ;;
    esac
    have=(); lack=()
    for dll in $want; do
        # version only counts bottle-wide (see OVERRIDE_EXES).
        if [ "$dll" = version ]; then
            if dll_native_global version; then have+=( version ); else lack+=( "version (bottle-wide)" ); fi
            continue
        fi
        if dll_native_for "$dll" $exes; then have+=( "$dll" ); else lack+=( "$dll" ); fi
    done
    if [ ${#lack} -gt 0 ]; then
        print -r -- "missing ${(j: :)lack}"
    elif [ "$g" = fifa15 ] && ! gt_f15_has_microsoft_crt; then
        # An override with no Microsoft copy to prefer does nothing.
        print -r -- "missing Microsoft msvcr110"
    else
        print -r -- "${(j: :)have}"
    fi
}

# f15_crt_native_dir, for whichever game this run is for: the pair is FIFA
# 15's whatever CRT_OVERRIDE_DLLS says, and the folder may be one only the
# Aurora launcher knows.
gt_f15_has_microsoft_crt() {
    local -a CRT_OVERRIDE_DLLS
    CRT_OVERRIDE_DLLS=( msvcr110 msvcp110 )
    crt_dlls_are_microsoft_in "${GT_DIR[fifa15]:-}" \
        || crt_dlls_are_microsoft_in "$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32"
}

# The launchers that are not the Aurora one, found where each one puts itself.
cas_launcher_exe() {
    local a; a="$(bottle_appdata 2>/dev/null)" || return 1
    [ -f "${a:h}/CAS/cas.exe" ] && print -r -- "${a:h}/CAS/cas.exe"
}
# Impulsum17 lives in a FIFA 17 folder, not necessarily the first one.
impulsum_launcher_exe() {
    local l
    for l in ${(f)"$(fifa17_dir_candidates)"}; do
        [ -f "${l#*$'\t'}/Impulsum17Launcher.exe" ] \
            && { print -r -- "${l#*$'\t'}/Impulsum17Launcher.exe"; return 0; }
    done
    return 1
}
reborn_launcher_exe() {
    local d a; local -a inside
    inside=( "$BOTTLE_DIR/$BOTTLE/drive_c/Program Files"/RebornFUT*(N/) )
    a="$(bottle_appdata 2>/dev/null || true)"
    [ -n "$a" ] && inside+=( "${a:h}"/RebornFUT*(N/) )
    for d in "${REBORN_DIR:-}" "$HOME"/Downloads/RebornFUT*(N/) "$HOME"/Desktop/RebornFUT*(N/) \
             "$HOME"/Games/RebornFUT*(N/) "$HOME"/RebornFUT*(N/) $inside; do
        [ -n "$d" ] || continue
        [ -f "$d/RebornFUT.exe" ] && { print -r -- "$d/RebornFUT.exe"; return 0; }
    done
    return 1
}

# Whether Impulsum17's own version.dll is in reach: in its folder, or kept in
# that folder's .crossover-fifa by the folder gate.
impulsum_dll_reachable() {
    local exe d
    exe="$(impulsum_launcher_exe 2>/dev/null)" || return 1
    d="${exe:h}"
    [ "$(cxg_dll_kind "$d/version.dll")" = impulsum ] && return 0
    [ "$(cxg_dll_kind "$d/$CXG_STASH/impulsum/version.dll")" = impulsum ]
}

# The pieces more than one launcher needs.
gt_webview2_ok() {
    [ -f "$BOTTLE_DIR/$BOTTLE/drive_c/webview2-fixed/$WEBVIEW2_VERSION/msedgewebview2.exe" ] \
        && [ -n "$(conf_value WEBVIEW2_BROWSER_EXECUTABLE_FOLDER)" ]
}
gt_licence_ok() { [ -f "$(bottle_licence_file)" ]; }
gt_powershell_ok() {
    local psdir="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
    cmp -s "$HERE/aurora17/powershell.exe" "$psdir/powershell.exe" 2>/dev/null \
        || cmp -s "$HERE/aurora17/powershell.exe" "$psdir/$CAS_HANDOFF" 2>/dev/null
}
gt_dnscache_ok() {
    local line
    for line in "${DNSCACHE_LINES[@]}"; do
        reg_line_is_set "$(bottle_system_reg)" "$DNSCACHE_SECTION" "$line" || return 1
    done
}

# The single-game variables a bottle may still carry from before the per-game
# table: FIFA 15's CX_TOPDOWN_LIMIT and FIFA 16's CX_FIFA16_DSTFIX. With the
# table, fifa15.exe and fifa16.exe take their own and ignore these, so all
# they still do is reach the programs the table does not list -- the
# launchers, WebView2, .NET helpers -- and CX_TOPDOWN_LIMIT squeezes every
# large top-down reservation those make under 8 GB. Prints the ones there.
LEFTOVER_GAME_VARS=( CX_TOPDOWN_LIMIT CX_FIFA16_DSTFIX )
leftover_game_vars() {
    local conf="$1" v
    for v in $LEFTOVER_GAME_VARS; do
        grep -Eq "^\"$v\"[[:space:]]*=" "$conf" 2>/dev/null && print -r -- "$v"
    done
    return 0
}

# The FIFA 17 launchers this bottle has, by name, one per line: the ones the
# per-game table does not list, and which therefore run under the bottle's
# bare CX_DR_TRAP.
fifa17_launchers_here() {
    aurora_launcher_dir >/dev/null 2>&1 && print -r -- "Aurora.exe"
    impulsum_launcher_exe >/dev/null 2>&1 && print -r -- "Impulsum17"
    cas_launcher_exe >/dev/null 2>&1 && print -r -- "CAS"
    reborn_launcher_exe >/dev/null 2>&1 && print -r -- "RebornFUT"
    { [ "$GAME" = fifa17 ] || (( ${SHARED_WITH[(Ie)FIFA 17]} )); } && print -r -- "Aurora17Connector"
    return 0
}

# One cell. GT_DIR, GT_SET and GT_DLL hold the game's own columns.
gt_cell() {
    local g="$1" l="$2" out
    # Which launcher starts which game.
    case "$l:$g" in
        aurora:*) ;;
        impulsum:fifa17|cas:fifa17|reborn:fifa17) ;;
        direct:fifa15|direct:fifa16|direct:fifa17) ;;
        *) print -r -- "unsupported"; return 0 ;;
    esac
    case "$l" in
        aurora)   aurora_launcher_dir >/dev/null 2>&1   || { print -r -- "not installed"; return 0; } ;;
        impulsum) impulsum_launcher_exe >/dev/null 2>&1 || { print -r -- "not installed"; return 0; } ;;
        cas)      cas_launcher_exe >/dev/null 2>&1      || { print -r -- "not installed"; return 0; } ;;
        reborn)   reborn_launcher_exe >/dev/null 2>&1   || { print -r -- "not installed"; return 0; } ;;
    esac
    # The game itself: its folder, its settings, its overrides.
    [ -n "${GT_DIR[$g]:-}" ] || { print -r -- "missing game folder"; return 0; }
    case "${GT_SET[$g]}" in *missing*) print -r -- "missing ${GT_SET[$g]#*missing }"; return 0 ;; esac
    case "${GT_DLL[$g]}" in missing*) print -r -- "${GT_DLL[$g]}"; return 0 ;; esac
    # What this launcher needs of the bottle for this game.
    case "$l" in
        impulsum|cas|reborn) gt_webview2_ok || { print -r -- "missing WebView2 $WEBVIEW2_VERSION"; return 0; } ;;
    esac
    case "$l" in
        cas) cmp -s "$CAS_PS" "$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0/powershell.exe" 2>/dev/null \
                 || { print -r -- "missing CAS device check"; return 0; } ;;
        aurora) proxy_autodetect_is_off || { print -r -- "missing proxy setting"; return 0; } ;;
    esac
    # The Aurora launcher's proxy version.dll beside FIFA 13, 16 and 21, and
    # Impulsum17's beside its own launcher, load only through the bottle-wide
    # override (see OVERRIDE_EXES). FIFA 17's own column already asks for it.
    case "$l" in
        aurora|impulsum) dll_native_global version || { print -r -- "missing version override"; return 0; } ;;
    esac
    # Impulsum17's own version.dll. Only its installer ever puts it in, and
    # every other launcher replaces it, so it counts when it is in the folder
    # or kept where the folder gate can put it back.
    if [ "$l" = impulsum ]; then
        impulsum_dll_reachable || { print -r -- "missing Impulsum DLL"; return 0; }
    fi
    if [ "$l:$g" = aurora:fifa21 ]; then
        gt_powershell_ok || { print -r -- "missing PowerShell stand-in"; return 0; }
        gt_dnscache_ok   || { print -r -- "missing Dnscache stand-in"; return 0; }
    fi
    if [ "$g" = fifa17 ]; then
        gt_licence_ok || { print -r -- "missing licence file"; return 0; }
    fi
    if [ "$l:$g" = direct:fifa15 ]; then
        # The crack's Origin emulator must be the offline-patched one.
        out="$("$HERE/fifa15/fifa15-offline.sh" check "${GT_DIR[$g]}" 2>/dev/null || true)"
        [[ "$out" == offline* ]] || { print -r -- "missing offline patch"; return 0; }
    fi
    if [ "$l:$g" = direct:fifa16 ]; then
        unix_path_to_win "${GT_DIR[$g]}" >/dev/null 2>&1 || { print -r -- "missing drive letter"; return 0; }
    fi
    print -r -- "ready"
}

verify_games_table() {
    local app="$1" g l pae table_line w
    local -A GT_DIR GT_SRC GT_SET GT_DLL
    local -a row head rows
    say ""
    say "Every game in the $BOTTLE bottle"
    say ""
    say "  CrossOver copy   $app"
    case "$PROFILES:$PROFILES_WHY" in
        1:*)       table_line="yes (its ntdll.so has $PROFILE_MARKER): games can share a bottle" ;;
        0:off)     table_line="turned off in this bottle (\"CX_GAME_PROFILES\" = \"0\")" ;;
        0:no-copy) table_line="no copy there to check" ;;
        *)         table_line="no: each game needs its own bottle (./setup.sh --repair updates the copy)" ;;
    esac
    say "  per-game table   $table_line"
    say "  bottle           $BOTTLE  ($BOTTLE_DIR/$BOTTLE)"
    [ -d "$BOTTLE_DIR/$BOTTLE" ] || say "                   (there is no such bottle)"
    pae="$(conf_value CX_PF_PAE)"
    if [[ "$pae" != 1* ]] && bottle_pae_on; then
        say "  CX_PF_PAE        ${pae:-not set}, but PAE is on: the bottle's CX_DR_TRAP is 3"
    else
        say "  CX_PF_PAE        ${pae:-not set}"
    fi
    say ""
    for g in $GT_GAMES; do
        # The folder, and which source named it (game_dir_candidates).
        l="$(game_dir_line "$g" 2>/dev/null || true)"
        GT_DIR[$g]="${l#*$'\t'}"
        GT_SRC[$g]="${l%%$'\t'*}"
        GT_SET[$g]="$(game_settings_source "$g" 2>/dev/null || true)"
        GT_DLL[$g]="$(game_dlls "$g" 2>/dev/null || true)"
    done
    # Columns padded to their widest cell, a rule under the heading, no
    # vertical bars: it reads in Terminal and pastes into a bug report.
    gt_print_table() {
        local w i n out rule=""; local -a r widths
        for w in "$@"; do
            r=( "${(@ps:\t:)w}" )
            for i in {1..${#r}}; do (( ${#r[i]} > ${widths[i]:-0} )) && widths[i]=${#r[i]}; done
        done
        n=$(( ${#widths} * 2 - 2 )); for i in $widths; do n=$(( n + i )); done
        repeat $n rule+="─"
        for w in "$@"; do
            r=( "${(@ps:\t:)w}" ); out=""
            for i in {1..${#widths}}; do out+="${(r:${widths[i]}:)r[i]}  "; done
            while [[ $out == *" " ]]; do out="${out% }"; done
            print -r -- "  $out"
            [ -n "$rule" ] && { print -r -- "  $rule"; rule=""; }
        done
    }
    rows=( "game	folder	settings	DLL overrides	offline" )
    for g in $GT_GAMES; do
        w="missing"
        [ -n "${GT_DIR[$g]}" ] && w="found (${GT_SRC[$g]%%,*})"
        row=( "$(game_label_of "$g")" "$w" "${GT_SET[$g]:-?}" "${GT_DLL[$g]:-?}" )
        w="$(gt_cell "$g" direct 2>/dev/null || print -r -- '?')"
        [ "$w" = unsupported ] && w="-"
        row+=( "$w" )
        rows+=( "${(pj:\t:)row}" )
    done
    gt_print_table $rows
    say ""
    rows=( "launcher	game	state" )
    for l in ${GT_LAUNCHERS:#direct}; do
        head=( "$(gt_launcher_label "$l")" )
        for g in $GT_GAMES; do
            w="$(gt_cell "$g" "$l" 2>/dev/null || print -r -- '?')"
            [ "$w" = unsupported ] && continue
            if [ "$w" = "not installed" ]; then
                rows+=( "${head[1]}	-	not installed" ); break
            fi
            rows+=( "${head[1]}	$(game_label_of "$g")	$w" )
            head=( "" )
        done
    done
    gt_print_table $rows
    say ""
    # Each folder with what named it. A chosen folder that is not there today
    # is said, with what was used instead, never swapped for a guess unsaid.
    for g in $GT_GAMES; do
        w=""
        if l="$(game_dir_choice_lost "$g" 2>/dev/null)"; then
            w="your choice $l is not reachable (drive not connected?); using "
            [ -n "${GT_DIR[$g]}" ] || { say "  $(game_label_of "$g"): ${w}none"; continue; }
        fi
        [ -n "${GT_DIR[$g]}" ] || continue
        say "  $(game_label_of "$g"): $w${GT_DIR[$g]}  ($(game_dir_source_says "${GT_SRC[$g]}"))"
    done
    say "  settings: table = the copy's own per-game settings; AppDefaults = this"
    say "  bottle's choice for that program; bare env = the bottle's variables."
    say "  offline = the game's own exe started with no launcher; - = it has none."
    say "  ready means every static check passed; only a launch proves it plays."
    return 0
}

# ------------------------------------------- the FIFA 17 folder and its gate
# Whether the folder gate runs in this bottle, as "on", "stale", "off" or
# "none" (this package has no gate to install yet), a tab, and what to say.
# It runs when the copy's ntdll.so has GATE_MARKER, the script is beside it
# and the bottle has not turned it off.
fifa17_gate_state() {
    local app="$1" wine ntdll script
    wine="$app/Contents/SharedSupport/CrossOver/lib/wine"
    ntdll="$wine/x86_64-unix/ntdll.so"; script="$wine/$GATE"
    if [[ "$(conf_value CX_FIFA_GATE)" == 0* ]]; then
        print -r -- "off	off in this bottle (\"CX_FIFA_GATE\" = \"0\" in its cxbottle.conf)"
    elif ! LC_ALL=C grep -aqF "$GATE_MARKER" "$ntdll" 2>/dev/null; then
        if LC_ALL=C grep -aqF "$GATE_MARKER" "$HERE/fixes/x86_64-unix/ntdll.so" 2>/dev/null; then
            print -r -- "off	off: ${app:t}'s ntdll.so is older than the folder gate (./setup.sh --repair updates it)"
        else
            print -r -- "none	off: this package's ntdll.so has no folder gate yet"
        fi
    elif [ ! -f "$script" ]; then
        print -r -- "off	off: ${GATE:t} is missing from ${app:t} (./setup.sh --repair puts it in)"
    elif ! cmp -s "$HERE/fixes/$GATE" "$script"; then
        print -r -- "stale	on, but ${app:t}'s ${GATE:t} is not this package's (./setup.sh --repair replaces it)"
    else
        print -r -- "on	on (ntdll.so has $GATE_MARKER, script is the shipped one)"
    fi
}

# The gate log's lines for one folder, newest first: "HH:MM launcher: what".
fifa17_gate_runs() {
    local log="$BOTTLE_DIR/$BOTTLE/cxfifa-gate.log"
    [ -f "$log" ] || return 0
    awk -F'\t' -v d="$1" -v today="$(date +%Y-%m-%d)" '
        $3 == d && (tolower($2) == "fifa17.exe" || tolower($2) == "impulsum17launcher.exe") {
            t = substr($1, 12, 5); if (substr($1, 1, 10) != today) t = substr($1, 6, 5) " " t
            who = $4; sub(/\(.*/, "", who)
            if (tolower($2) == "impulsum17launcher.exe") who = "Impulsum17 launcher"
            what = $5; if ($6 != "ok") what = what " (" $6 ")"
            line[++n] = t "\t" who "\t" what "\t" $6 "\t" tolower($2)
        }
        END { for (i = n; i >= 1; i--) print line[i] }' "$log" 2>/dev/null
    return 0
}

# One block in --verify: every folder FIFA 17 might be played from, what is in
# it, and whether the gate is there to put it right. Read only. Sets
# FOLDER_PROBLEMS to the number of BAD lines, which verify_install counts.
verify_fifa17_folders() {
    local app="$1" l src d gl gstate gtext pfx="$BOTTLE_DIR/$BOTTLE" shown=0 v x t
    local CXG_RO=1      # the gate's functions only read from here on
    local -a cands lnch pointed runs bk cnt
    local -A FX
    FOLDER_PROBLEMS=0
    cands=( ${(f)"$(fifa17_dir_candidates)"} )
    say ""
    say "FIFA 17 game folder"
    if [ ${#cands} -eq 0 ]; then
        say "  none found. A folder kept somewhere else:"
        say "      AURORA_GAME_DIR='/path/to/FIFA 17' ./setup.sh --verify"
        return 0
    fi
    lnch=()
    aurora_launcher_dir >/dev/null 2>&1 && lnch+=( Aurora.exe )
    impulsum_launcher_exe >/dev/null 2>&1 && lnch+=( Impulsum17 )
    cas_launcher_exe >/dev/null 2>&1 && lnch+=( CAS )
    gl="$(fifa17_gate_state "$app")"
    gstate="${gl%%$'\t'*}"; gtext="${gl#*$'\t'}"
    CXG_PS_OUT="$(cxg_ps)"
    pointed=()
    for l in $cands; do
        src="${l%%$'\t'*}"; d="${l#*$'\t'}"
        x=""
        for v in CAS Impulsum17 Aurora.exe Aurora17 "EA registry"; do
            [[ ", $src, " == *", $v, "* ]] && x="${x:+$x, }$v"
        done
        [ -n "$x" ] && pointed+=( "$x uses ${d/#$HOME/~}" )
        # A guess, when anything better is known, is one line.
        t="${d/#$HOME/~}"
        (( ${#t} < 28 )) && t="${(r:28:)t}"
        if [ "$src" = guess ] && [ ${#cands} -gt 1 ]; then
            say "  $t only a guess: no launcher points here"
            continue
        fi
        shown=$((shown + 1))
        FX=( build "" cas_around 0 dll missing total 0 kept 0 in_cas_original 0 unchecked 0
             own "" changed "" missing "" unrecoverable "" added "" parked "" cas_mod "" cas_files 0 )
        for v in ${(f)"$(cxg_folder_facts "$d" "$pfx")"}; do
            [[ "$v" == *=* ]] || continue
            case "$v" in
                backup=*) bk+=( "${v#backup=}" ) ;;
                *) FX[${v%%=*}]="${v#*=}" ;;
            esac
        done
        runs=( ${(f)"$(fifa17_gate_runs "$d")"} )
        # The heading: where the game last ran from, and who points here.
        gl=""
        for v in $runs; do
            [[ "${v##*$'\t'}" == fifa17.exe ]] || continue
            gl="FIFA 17 last ran here ${v%%$'\t'*} (${${v#*$'\t'}%%$'\t'*})"; break
        done
        if [[ "$x" == *,* ]]; then
            gl="${gl:+$gl; }${x%, *} and ${x##*, } point here"
        elif [ -n "$x" ]; then
            gl="${gl:+$gl; }$x points here"
        fi
        [[ ", $src, " == *", AURORA_GAME_DIR, "* ]] && gl="${gl:+$gl; }AURORA_GAME_DIR names it"
        [ -n "$gl" ] || gl="only a guess: no launcher points here"
        say "  $t $gl"

        # The data files.
        if [ "${FX[build]:-}" != known ]; then
            say "  data files      unknown FIFA 17 build (FIFA17.exe is not the final update):"
            say "                  the gate leaves its data files alone"
            note "unknown FIFA 17 build in ${d/#$HOME/~}: the folder gate cannot tell its own"
            say "        data files from a launcher's there, so it leaves them as they are"
        elif [ "${FX[unchecked]:-0}" -gt 0 ] && [ -z "${FX[changed]}${FX[added]}" ]; then
            say "  data files      not checked: CAS has not been used with this folder, and"
            say "                  nothing else changes them"
        elif [ -z "${FX[changed]}${FX[added]}${FX[missing]}" ]; then
            say "  data files      the game's own (${FX[total]} of ${FX[total]})"
        elif [ -n "${FX[changed]}" ] && [ -z "${FX[own]}" ]; then
            v="${FX[cas_mod]:-CAS's}"
            cnt=( ${(s:,:)FX[changed]} ${(s:,:)FX[added]} )
            say "  data files      CAS mod data ($v, ${#cnt} files)"
            if [ -n "${FX[unrecoverable]}" ]; then
                say "                  and nothing to put the game's own back from (below)"
            else
                say "                  the next launch that is not CAS's puts the game's own back"
            fi
        else
            cnt=( ${(s:,:)FX[own]} )
            say "  data files      mixed: ${#cnt} of ${FX[total]} are the game's own${FX[added]:+; ${FX[added]//,/, } in}"
            [ -n "${FX[missing]}" ] && say "                  missing: ${FX[missing]//,/, }"
            note "the data files in ${d/#$HOME/~} are half the game's own and half a"
            say "        launcher's. The next launch puts them right."
        fi
        if [ -n "${FX[unrecoverable]}" ] && ! cxg_running FIFA17.exe; then
            bad "CAS's data is in ${d/#$HOME/~} and the game's own copy of"
            say "        ${FX[unrecoverable]//,/, } is nowhere: not in .crossover-fifa, not in"
            say "        CAS's original/ folder. Until it is, FIFA 17 started from anything but"
            say "        CAS closes about 30 seconds in. If another copy of FIFA 17 is on this"
            say "        Mac, ./setup.sh --fix-folder takes the files from it (for a copy it"
            say "        does not find: FIFA17_DIR='/path/to/that FIFA 17' ./setup.sh --fix-folder)."
            say "        Otherwise use CAS's own restore button, or reinstall the game's files."
            FOLDER_PROBLEMS=$((FOLDER_PROBLEMS + 1))
        fi
        say "  version.dll     $(cxg_dll_label "${FX[dll]}")${FX[dll_sha8]:+ (${FX[dll_sha8]})}"
        # The kept originals.
        if [ "${FX[kept]}" -gt 0 ] || [ "${FX[cas_around]}" = 1 ]; then
            if [ "${FX[kept]}" = "${FX[total]}" ]; then
                say "  originals       ${FX[kept]}/${FX[total]} in .crossover-fifa, match FIFA 17's final update"
            elif [ "${FX[in_cas_original]}" -gt 0 ]; then
                say "  originals       ${FX[kept]}/${FX[total]} in .crossover-fifa; CAS keeps copies in its original/ folder"
                say "                  (./setup.sh --fix-folder keeps them here, so they outlive CAS)"
            else
                say "  originals       ${FX[kept]}/${FX[total]} in .crossover-fifa"
            fi
        else
            say "  originals       not needed: CAS has not been used with this folder"
        fi
        # Impulsum17's DLL.
        if [ -n "${FX[impulsum_here]:-}" ] || [ -n "${FX[impulsum_kept]:-}" ]; then
            if [ -n "${FX[impulsum_kept]:-}" ]; then
                if [ "${FX[dll]}" = impulsum ]; then
                    say "  Impulsum DLL    kept in .crossover-fifa (${FX[impulsum_kept]}), and in the folder"
                else
                    say "  Impulsum DLL    kept in .crossover-fifa (${FX[impulsum_kept]}); the gate puts it back"
                    say "                  when Impulsum17 starts"
                fi
            elif [ "${FX[dll]}" = impulsum ]; then
                say "  Impulsum DLL    in the folder, not kept yet: Impulsum17's next start keeps it"
                say "                  (or ./setup.sh --fix-folder)"
            else
                say "  Impulsum DLL    not on this Mac: Impulsum17's PLAY will stop and say so."
                say "                  Run Impulsum17-Setup again (it keeps nothing else of yours)."
                note "Impulsum17's version.dll is gone from ${d/#$HOME/~}: another launcher"
                say "        replaced it. Run Impulsum17-Setup again, then press Play in Impulsum17."
            fi
        fi
        say "  gate            $gtext"
        if [ "$gstate" = off ] && [ ${#lnch} -ge 2 ]; then
            bad "the folder gate is off, and the $BOTTLE bottle has ${#lnch} FIFA 17 launchers"
            say "        (${(j:, :)lnch}). Each leaves the game folder its own way, and the next"
            say "        launch can die with the last one's files. Fix: ./setup.sh --repair"
            FOLDER_PROBLEMS=$((FOLDER_PROBLEMS + 1))
        elif [ "$gstate" = stale ]; then
            note "the folder gate's script in ${app:t} is not this package's. ./setup.sh --repair"
        elif [ "$gstate" = none ] && [ ${#lnch} -ge 2 ]; then
            note "${#lnch} FIFA 17 launchers share this folder and nothing puts it right"
            say "        between them: after a CAS PLAY, start the game from CAS again, or"
            say "        expect the next launch from another launcher to die at ~27 seconds."
        fi
        if [ ${#runs} -gt 0 ]; then
            v=""
            for x in ${runs[1,2]}; do
                v="${v:+$v | }${x%%$'\t'*} ${${x#*$'\t'}%%$'\t'*}: ${${${x#*$'\t'}#*$'\t'}%%$'\t'*}"
            done
            say "  last launches   $v"
            case "${${${${runs[1]#*$'\t'}#*$'\t'}#*$'\t'}%%$'\t'*}" in
                failed|incomplete)
                    bad "the last game start could not put ${d/#$HOME/~} right:"
                    say "        ${${${runs[1]#*$'\t'}#*$'\t'}%%$'\t'*}"
                    say "        The next start tries again. The log is $BOTTLE_DIR/$BOTTLE/cxfifa-gate.log"
                    FOLDER_PROBLEMS=$((FOLDER_PROBLEMS + 1)) ;;
            esac
        fi
        [ -n "${FX[journal]:-}" ] && note "the last gate run in ${d/#$HOME/~} was interrupted; the next start finishes it"
        if [ -n "${FX[unknown_changes]:-}" ]; then
            note "since FIFA 17 last started, files changed in ${d/#$HOME/~} that no known"
            say "        launcher writes: ${FX[unknown_changes]//,/, }"
        fi
        # The launchers' backups, by what is in them, not by their names.
        if [ ${#bk} -gt 0 ]; then
            v="  other files    "
            for x in $bk; do
                if [ "${x%%:*}" = verorig.dll ] && [ "${x#*:}" = wine ]; then
                    say "$v ${x%%:*} is Wine's own (CAS's redirect hands calls on to it)"
                else
                    say "$v ${x%%:*} is $(cxg_dll_label "${x#*:}")"
                fi
                v="                 "
            done
            say "                  (copies the launchers made; FIFA 17 itself loads only version.dll)"
        fi
        bk=()
    done
    if [ ${#pointed} -gt 1 ]; then
        note "the launchers do not agree on the game folder: ${(j:; :)pointed}"
    fi
    return 0
}

# Keeps the copies the folder gate puts back, in every FIFA 17 folder a
# launcher uses: the game's own data files once CAS has anything to do with
# the folder (each checked against the table, about 75 MB, once), and any
# Impulsum17 version.dll found. A file whose original is in neither the
# folder nor CAS's original/ (CAS uninstalled with its data still in the
# game, say) is taken from any other copy of FIFA 17 it knows of, the
# home-folder guesses included, when that copy's file is the table's. It
# never changes a file of the game's own:
# putting the game's files back is the gate's job, at the next start, when it
# knows which launcher is starting. --fix-folder runs it, and so does step 9e
# of the bottle setup, which the installer and --repair both run.
fix_fifa17_folders() {
    local l src d pfx="$BOTTLE_DIR/$BOTTLE" acts o
    local -a cands left
    cands=( ${(f)"$(fifa17_dir_candidates)"} )
    if [ ${#cands} -eq 0 ]; then
        note "no FIFA 17 folder found, so nothing to keep. For one kept elsewhere:"
        say "        AURORA_GAME_DIR='/path/to/FIFA 17' ./setup.sh --fix-folder"
        return 0
    fi
    for l in $cands; do
        src="${l%%$'\t'*}"; d="${l#*$'\t'}"
        [ "$src" = guess ] && [ ${#cands} -gt 1 ] && continue
        if ! cxg_cas_around "$d" "$pfx" && [ ! -f "$d/Impulsum17Launcher.exe" ] \
           && [ ! -d "$d/$CXG_STASH" ] && [ "$(cxg_dll_kind "$d/version.dll")" != impulsum ]; then
            ok "${d/#$HOME/~}: nothing to keep (no CAS and no Impulsum17 here)"
            continue
        fi
        if ! cxg_stash_make "$d"; then
            note "could not write $d/$CXG_STASH"
            continue
        fi
        if ! cxg_lock "$d/$CXG_STASH" 15; then
            note "${d/#$HOME/~} is busy (a game start holds it); run this again"
            continue
        fi
        CXG_ACTS=(); CXG_PROBS=()
        CXG_JOURNAL="$d/$CXG_STASH/journal"
        cxg_capture "$d" "$pfx" || true
        if [ "$(cxg_build_of "$d")" = known ] && cxg_vanilla_wanted "$d" "$pfx" \
           && [ -n "$(cxg_vanilla_unkept "$d")" ]; then
            for o in $cands; do
                cxg_capture_vanilla_from "$d" "${o#*$'\t'}" || true
            done
            CXG_PROBS=( ${CXG_PROBS:#no original of *} )
            left=( ${${(f)"$(cxg_vanilla_unkept "$d")"}%% *} )
            [ ${#left} -gt 0 ] && CXG_PROBS+=( "no original of ${(j:, :)${left:t}}" )
        fi
        rm -f "$CXG_JOURNAL"
        CXG_JOURNAL=""
        cxg_unlock "$d/$CXG_STASH"
        acts="${(j:, :)CXG_ACTS}"
        ok "${d/#$HOME/~}: ${acts:-everything worth keeping is already kept}"
        [ ${#CXG_PROBS} -gt 0 ] && note "${(j:; :)CXG_PROBS}"
        if [ -f "$d/Impulsum17Launcher.exe" ] && [ ! -f "$d/$CXG_STASH/impulsum/version.dll" ]; then
            note "Impulsum17's version.dll is not on this Mac: another launcher replaced it."
            say "        Run Impulsum17-Setup again; its next start keeps the DLL."
        fi
    done
    return 0
}

verify_install() {
    local app="$1" problems=0
    # An offline install (./setup.sh --offline) has no Aurora17 by design, so
    # the checks for Aurora's stand-in, its EA names and its certificate would
    # all report BAD on a perfectly good install. The receipt says which kind
    # this was; the flag says so during the install itself.
    local offline=0 offline_from_receipt=0
    [ "${NO_AURORA:-0}" = 1 ] && offline=1
    if [ "$offline" = 0 ] && [ -f "$RECEIPT" ] && grep -q '^offline=1$' "$RECEIPT"; then
        offline=1; offline_from_receipt=1
    fi
    # The receipt records the last thing setup.sh was asked to do, not what the
    # bottle is being used for. Running --offline over a bottle that already
    # had Aurora17 in it rewrites the receipt and leaves every online piece in
    # place and working -- and this then skipped all of them and finished with
    # "Everything checks out", which is the worst answer a check can give.
    # Believe the bottle over the receipt.
    if [ "$offline_from_receipt" = 1 ] && aurora_in_use; then
        offline=0
        note "the receipt says this was an offline install, but Aurora17 has run"
        say "        in the $BOTTLE bottle since, so its parts are checked below."
        say "        To correct the receipt, re-run  ./setup.sh  without --offline."
    fi
    say ""
    say "Checking $app"
    say ""

    [ -d "$app" ] || { bad "there is no app at $app"; return 1; }
    is_crossover_bundle "$app" \
        && ok "is a CrossOver bundle" \
        || { bad "$app is not a CrossOver bundle"; problems=$((problems+1)); }
    # Every machine that has played online so far ran macOS 15 or 26. The one
    # macOS 14 user crashed 0xC0000005 at the main menu -- and still did after
    # updating to macOS 26, so that crash is not a macOS 14 matter. What is
    # left is only that nobody has confirmed online play on 14. Not BAD.
    if [ "$offline" = 0 ] && [ "${GAME:-fifa17}" = fifa17 ]; then
        case "$(sw_vers -productVersion 2>/dev/null)" in
            14.*)
                note "macOS 14: online play has not been confirmed on macOS 14 yet. If the game"
                say "        crashes after the main menu, quit CrossOver and double-click"
                say "        'diagnostics/12 Play with a crash log.command', then collect a bundle." ;;
        esac
    fi

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
            # These four are modified after installation -- an rpath is added
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
    for so in ntdll.so crypt32.so win32u.so; do
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

    local ent; ent="$(mktemp -t cxent)"
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
        for kv in $BOTTLE_SETTINGS; do
            k="${kv%%=*}"; v="${kv#*=}"
            # -Fx, not a regexp: WEBVIEW2_BROWSER_EXECUTABLE_FOLDER's value is a
            # Windows path, and "\9" in a regexp is a back-reference to a group
            # that does not exist, which grep rejects outright.
            if grep -Fqx -- "\"$k\" = \"$v\"" "$conf"; then
                ok "$k"
            elif (( ${SOFT_SETTINGS[(Ie)$k]} )) && grep -q "^\"$k\" = " "$conf"; then
                # See add_setting: another game's value, which the games the
                # table lists do not read.
                ok "$k is another game's value here; $GAME_LABEL takes its own from the table"
            else
                bad "$k is not set to $v in the $BOTTLE bottle"; problems=$((problems+1))
            fi
        done
        # Where the game's own settings come from, now that they need not be
        # in the bottle at all. Not a BAD either way: the line above already
        # says whether the bottle has what this setup needs.
        if [ "$PROFILES" = 1 ]; then
            GAME_SRC="$(game_settings_source "$GAME")"
            case "$GAME_SRC" in
                *missing*) note "$GAME_LABEL's own settings: $GAME_SRC (${COPY_APP:t}'s ntdll.so has the per-game table)" ;;
                *) ok "$GAME_LABEL's own settings: $GAME_SRC (${COPY_APP:t}'s ntdll.so has the per-game table)" ;;
            esac
            # What the bottle's leftover single-game variables still reach
            # (see leftover_game_vars). Never an ok: a launcher gets them.
            local lv
            for lv in ${(f)"$(leftover_game_vars "$conf")"}; do
                note "$lv = $(conf_value "$lv") is still bottle-wide here. The games the table"
                say "        lists ignore it, but every program it does not list -- the"
                say "        launchers, WebView2, .NET helpers -- still runs with it."
                if [ ${#SHARED_WITH} -gt 0 ]; then
                    if [ "$GAME" = fifa17 ]; then
                        say "        Fix (removes it, keeps a backup):  AURORA_BOTTLE='$BOTTLE' ./setup.sh --bottle"
                    else
                        say "        Fix (removes it, keeps a backup):  AURORA_BOTTLE='$BOTTLE' ./setup.sh --$GAME"
                    fi
                fi
            done
            # A bare CX_DR_TRAP=3 is left alone on purpose (it is the launchers'
            # baseline in a FIFA 16 bottle, and it turns PAE on), but FIFA 17's
            # launchers were proven under 2.
            local -a f17l
            f17l=( ${(f)"$(fifa17_launchers_here)"} )
            if [[ "$(conf_value CX_DR_TRAP)" == 3* ]] && [ ${#f17l} -gt 0 ]; then
                note "CX_DR_TRAP is 3 bottle-wide here (FIFA 16's mode), and the FIFA 17"
                say "        launchers in this bottle (${(j:, :)f17l}) run with it; they were proven"
                say "        under 2. The games the table lists take their own. Left as it is;"
                say "        if a launcher misbehaves, set it to \"2\" and add \"CX_PF_PAE\" = \"1\""
                say "        (CrossOver closed) so FIFA 16 keeps PAE."
            fi
        fi
        # Settings this script never writes. They arrive from other guides
        # (DXVK_CONFIG_FILE, WINEMSYNC) and have turned up on every bottle
        # that failed in a way nobody could explain. Not a BAD: none is proven
        # to break anything. Named, so a bug report shows them.
        local -a foreign; local fk
        foreign=()
        for fk in ${(f)"$(sed -n '/^\[EnvironmentVariables\]/,/^\[/p' "$conf" 2>/dev/null \
                          | sed -n 's/^"\([A-Za-z_][A-Za-z0-9_]*\)" = .*/\1/p')"}; do
            [ -n "$fk" ] || continue
            case "$fk" in
                CX_GRAPHICS_BACKEND|CX_DR_TRAP|WINE_SIMULATE_WRITECOPY|CX_TOPDOWN_LIMIT|CX_FIFA16_DSTFIX|CX_PF_PAE|CX_GAME_PROFILES|WINE_COREAUDIO_EXCLUDE|WEBVIEW2_BROWSER_EXECUTABLE_FOLDER|PROMPT) ;;
                *) foreign+=( "$fk" ) ;;
            esac
        done
        if [ "${#foreign}" -gt 0 ]; then
            note "the $BOTTLE bottle has settings this script never wrote: ${(j:, :)foreign}"
            say "        They came from somewhere else. If the game fails for no reason"
            say "        anyone can name, quit CrossOver (Command-Q) and remove them from"
            say "        [EnvironmentVariables] in $conf"
        fi
    else
        bad "no bottle called '$BOTTLE' at $BOTTLE_DIR"
        problems=$((problems+1))
    fi

    # The folder the variable above points at. The variable on its own is worth
    # nothing: the WebView2 loader falls back to the evergreen runtime, and the
    # launcher's window is blank again.
    if [ "$GAME" = fifa17 ] && [ "${WEBVIEW2_RUNTIME:-}" != skip ]; then
        local wv="$BOTTLE_DIR/$BOTTLE/drive_c/webview2-fixed/$WEBVIEW2_VERSION"
        if [ -f "$wv/msedgewebview2.exe" ] && [ -f "$wv/$WEBVIEW2_VERSION.manifest" ]; then
            ok "WebView2 $WEBVIEW2_VERSION in the $BOTTLE bottle"
        else
            bad "the WebView2 $WEBVIEW2_VERSION runtime is not in the $BOTTLE bottle — the"
            say "        RebornFUT launcher's window will be blank. Run ./setup.sh --bottle"
            problems=$((problems+1))
        fi
    fi

    # The CAS launcher's two pieces (step 9c). Notes, never BAD: CAS is a
    # second launcher nobody has to use, and the game plays without it.
    if [ "$GAME" = fifa17 ] && [ "${CAS_SUPPORT:-}" != skip ]; then
        local casps="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0/powershell.exe"
        if cmp -s "$CAS_PS" "$casps" 2>/dev/null; then
            ok "CAS's device check answers in the $BOTTLE bottle"
        else
            note "the $BOTTLE bottle's powershell.exe is not CAS's stand-in, so the CAS"
            say "        launcher says \"Install the latest CAS launcher to verify this"
            say "        device.\" and sign-in never starts. Run ./setup.sh --bottle"
        fi
        # The handler starts whichever wine and bottle it was built with; one
        # built for another copy or bottle hands the link to the wrong place.
        local cassrc="$CAS_LINK_APP/Contents/Resources/cas-link.applescript"
        if cas_link_registered \
           && grep -Fq -- "\"$app/Contents/SharedSupport/CrossOver/bin/wine\"" "$cassrc" 2>/dev/null \
           && grep -Fq -- "\"$BOTTLE\"" "$cassrc" 2>/dev/null; then
            ok "CAS Link (CrossOver) takes cas:// sign-in links"
        elif cas_link_registered; then
            note "CAS Link (CrossOver) was built for another CrossOver copy or bottle,"
            say "        so CAS's sign-in link would go there. Run ./setup.sh --bottle"
        else
            note "nothing on this Mac takes cas:// links, so CAS's Discord sign-in"
            say "        cannot get back from the browser. Run ./setup.sh --bottle"
        fi
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
        # One rpcss.exe per Wine boot: two of them is two sessions on one
        # prefix, the leftover of a boot that never ended (see --report).
        local boots
        boots="$(ps -o command= -p "${(j:,:)holding}" 2>/dev/null | grep -c 'rpcss\.exe' || true)"
        if [ "${boots:-0}" -gt 1 ]; then
            note "$boots Wine sessions are up on this bottle at once. One is a leftover:"
            say "        quit CrossOver, run Stop.command, then open it again."
        fi
    else
        bad "${#holding} process(es) are still inside the $BOTTLE bottle with"
        say "        no CrossOver running. The bottle will hang on loading until"
        say "        they are gone. Run:  ./setup.sh --unstick"
        problems=$((problems+1))
    fi

    # Check whether any Aurora ports are held by orphaned processes. Aurora17's
    # server listens on 47170-47173; Aurora15Connector's Origin stand-in on 3216.
    # FIFA 16 has no Aurora and so no port to check, and FIFA 21 none known.
    local port_pids=""
    if [ -n "$GAME_PORTS" ]; then
        port_pids="$(/usr/sbin/lsof -nP -iTCP:$GAME_PORTS -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | tr '\n' ' ')"
        port_pids="${port_pids% }"
    fi
    if [ -z "$GAME_PORTS" ]; then
        ok "$GAME_LABEL: no Aurora ports to check"
    elif [ -z "$port_pids" ]; then
        ok "all Aurora ports ($GAME_PORTS_LABEL) are free"
    elif [ -n "$(crossovers_running)" ] || hold_pid_alive; then
        # hold_pid_alive covers a session started by --play-log or
        # --play-offline: CrossOver is closed by design there, so testing
        # crossovers_running alone called a live session an orphan, six lines
        # after the check above had called it "playing right now".
        note "Aurora service is active on port(s) $GAME_PORTS_LABEL (PID: $port_pids)"
    else
        bad "orphaned process(es) holding Aurora port(s) (PID: $port_pids) with CrossOver closed."
        if [ "$GAME" = fifa15 ]; then
            say "        Aurora15Connector will say 'Local port 3216 is in use'. Run:  ./setup.sh --unstick"
        else
            say "        The launcher will fail with 'A server is already listening'. Run:  ./setup.sh --unstick"
        fi
        problems=$((problems+1))
    fi

    # Without this the redirect shim is never loaded and the only symptom is
    # "servers have been shut down" -- with every other check here passing.
    # FIFA 16 has no override (see OVERRIDE_DLL).
    if [ -n "$OVERRIDE_DLL" ] && [ -f "$(bottle_user_reg)" ]; then
        version_override_is_set \
            && ok "$OVERRIDE_DLL = native,builtin in the $BOTTLE bottle" \
            || { bad "the $BOTTLE bottle loads Wine's own $OVERRIDE_DLL.dll, so"
                 say "        Aurora's redirect never loads and the game will"
                 say "        say the servers are shut down. Quit CrossOver fully,"
                 say "        then re-run ./setup.sh"
                 problems=$((problems+1)); }
    fi

    # See the C runtime override. Offline play never notices; an online match
    # ends at kick-off, which looks like a network fault and is not one.
    if [ ${#CRT_OVERRIDE_DLLS} -gt 0 ] && [ -f "$(bottle_user_reg)" ]; then
        crt_override_is_set \
            && ok "${(j: + :)CRT_OVERRIDE_DLLS} = native,builtin in the $BOTTLE bottle" \
            || { bad "the $BOTTLE bottle loads Wine's own C runtime rather than"
                 say "        Microsoft's, so online matches desync at kick-off (the game"
                 say "        shows a disconnect right after kick-off). Quit CrossOver"
                 if [ "$GAME" = fifa15 ]; then
                   say "        fully, then re-run  ./setup.sh --fifa15"
                 else
                   say "        fully, then re-run  ./setup.sh"
                 fi
                 problems=$((problems+1)); }
    fi

    # FIFA 21's ucrtbase (see the C runtime override). A note: the PowerShell
    # stand-in writes it at PLAY whether or not setup has.
    if [ "$GAME" = fifa21 ] && [ -f "$(bottle_user_reg)" ]; then
        if dll_override_is_set ucrtbase; then
            ok "ucrtbase = native,builtin for FIFA21.exe in the $BOTTLE bottle"
        else
            note "FIFA21.exe does not prefer Microsoft's ucrtbase in the $BOTTLE bottle yet."
            say "        The PowerShell stand-in sets it at PLAY; ./setup.sh --fifa21 sets it now."
        fi
    fi

    # See f16_pin_crt. A note: FIFA 16 still starts on Microsoft's runtime,
    # but that is not the ground its loading fix was proven on.
    if [ "$GAME" = fifa16 ] && [ -f "$(bottle_user_reg)" ] && f16_crt_pin_needed; then
        if f16_crt_is_pinned; then
            ok "fifa16.exe kept on Wine's own ${(j: and :)F16_CRT_PIN}"
        else
            note "the $BOTTLE bottle prefers Microsoft's msvcr110/msvcp110 for every program"
            say "        (FIFA 15's setup did that), so FIFA 16 loads them too; its loading"
            say "        fix was proven on Wine's own. Fix:  AURORA_BOTTLE='$BOTTLE' ./setup.sh --fifa16"
        fi
    fi

    # And an override is only half of it: Wine can only prefer a native runtime
    # if there is one. FIFA 17 ships the pair beside FIFA17.exe, so there is
    # nothing to look for; FIFA 15 is given one at install time and this says
    # whether it is still there.
    if [ "$GAME" = fifa15 ]; then
        local crt_dir=""
        if crt_dir="$(f15_crt_native_dir)"; then
            ok "${(j: + :)CRT_OVERRIDE_DLLS} — Microsoft's own, in $crt_dir"
        else
            bad "every copy of the C runtime FIFA 15 can reach is Wine's own, so"
            say "        the override above has nothing to prefer and online matches"
            say "        still desync at kick-off. Quit CrossOver fully, then re-run"
            say "        ./setup.sh --fifa15  (with FIFA15_DIR='/path/to/FIFA 15' in"
            say "        front of it if its game folder is not found below)"
            problems=$((problems+1))
        fi
    fi

    # Without this Aurora's helper spends five seconds looking for a proxy before
    # its first request, and the shim's five-second deadline for the Origin auth
    # code runs out first. See BUGS.md §21. FIFA 16 has no helper, and its
    # bottle is not given the setting.
    if [ "$GAME" != fifa16 ] && [ -f "$(bottle_user_reg)" ]; then
        proxy_autodetect_is_off \
            && ok "proxy auto-detect off in the $BOTTLE bottle" \
            || { if [ "$GAME" = fifa15 ]; then
                   bad "proxy auto-detect is on in the $BOTTLE bottle, so every fresh"
                   say "        .NET process (Aurora15Connector, its client) waits five seconds"
                   say "        for a proxy lookup before its first request. Quit CrossOver"
                   say "        fully, then re-run  ./setup.sh --fifa15"
                 elif [ "$GAME" = fifa21 ]; then
                   bad "proxy auto-detect is on in the $BOTTLE bottle, so every fresh"
                   say "        .NET process (the Aurora launcher's bridges) waits five seconds"
                   say "        for a proxy lookup before its first request. Quit CrossOver"
                   say "        fully, then re-run  ./setup.sh --fifa21"
                 else
                   bad "proxy auto-detect is on in the $BOTTLE bottle, so Aurora's"
                   say "        helper spends five seconds looking for a proxy and misses"
                   say "        the deadline for the Origin auth code. The game will quit"
                   say "        saying the Origin client was terminated. Quit CrossOver"
                   say "        fully, then re-run ./setup.sh"
                 fi
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

    # See guard_menu_shims. Not a BAD: an unguarded shortcut plays perfectly
    # well in a bottle that has its licence file, and the check just above
    # this one is the one that decides whether the shortcut works at all.
    # It only matters once the bottle is remade, which is exactly when nobody
    # is reading this. A note keeps it visible without crying wolf.
    local -a unguarded
    unguarded=( ${(f)"$(unguarded_menu_shims)"} )
    unguarded=( ${unguarded:#} )
    if [ "${#unguarded}" -eq 0 ]; then
        ok "licence guard on the bottle's game shortcuts"
    else
        note "${#unguarded} game shortcut(s) have no licence guard, so clicking"
        say "        FIFA 17 in CrossOver after remaking the bottle would hit §18"
        say "        (starts, then quits ~20s in with nothing on screen). Fix:"
        say "        AURORA_BOTTLE='$BOTTLE' ./setup.sh --bottle"
        for f in $unguarded; do say "        ${f:t}"; done
    fi

    # FIFA 15 has no PowerShell stand-in: Aurora15Connector is one program. The
    # checks below are FIFA 17's and are skipped for it (not re-indented).
    # FIFA 21 has its own: the bottle's stand-in, and the Dnscache one.
    if [ "$GAME" = fifa15 ]; then
        ok "FIFA 15: no Aurora17 stand-in to check"
        f15_check_game
    elif [ "$GAME" = fifa16 ]; then
        ok "FIFA 16: no Aurora17 stand-in to check"
        f16_check_game
    elif [ "$GAME" = fifa21 ]; then
        # The Aurora launcher's PLAY reaches the stand-in in the bottle; the
        # Aurora17 folder's is Aurora17Connector's and not looked at.
        if gt_powershell_ok; then
            ok "PowerShell stand-in in the bottle"
        else
            bad "the $BOTTLE bottle has no PowerShell stand-in, so the Aurora launcher's"
            say "        FIFA 21 PLAY does nothing. Quit CrossOver fully, then re-run"
            say "        ./setup.sh --fifa21"
            problems=$((problems+1))
        fi
        if gt_dnscache_ok; then
            ok "Dnscache stand-in in the bottle (the Aurora launcher's DNS Client check)"
        else
            bad "the $BOTTLE bottle has no DNS Client service, so the Aurora launcher"
            say "        stops before FIFA 21 starts. Quit CrossOver fully, then re-run"
            say "        ./setup.sh --fifa21"
            problems=$((problems+1))
        fi
        f21_check_game
    elif [ "$offline" = 1 ]; then
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
    elif cmp -s "$CAS_PS" "$psdir/powershell.exe" 2>/dev/null; then
        # CAS's stand-in has the name (step 9c) and hands PLAY's calls to
        # Aurora17's beside it, so that is the file that has to be right.
        if cmp -s "$HERE/aurora17/powershell.exe" "$psdir/$CAS_HANDOFF" 2>/dev/null; then
            ok "PowerShell stand-in in the bottle (as $CAS_HANDOFF, behind CAS's)"; found=1
        elif [ -f "$psdir/$CAS_HANDOFF" ]; then
            stale=1; stale_at+=( "the $BOTTLE bottle ($CAS_HANDOFF)" )
        fi
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

    # EA names, hosts receipt, redirect shim, licence and certificate are all
    # Aurora17's. Aurora15's hook redirects by address (EA-MITM.ini) and the
    # game serves its own licence, so for FIFA 15 none of this applies.
    if [ "$GAME" = fifa15 ]; then
        ok "FIFA 15: Aurora17's EA names, licence and certificate checks do not apply"
    elif [ "$GAME" = fifa16 ]; then
        ok "FIFA 16: Aurora17's EA names, licence and certificate checks do not apply"
    elif [ "$GAME" = fifa21 ]; then
        # FIFA 21's stand-in writes its own names at PLAY.
        ok "FIFA 21: Aurora17's EA names, licence and certificate checks do not apply"
    elif [ "$offline" = 1 ]; then
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

    verify_no_cleanup_agent || problems=$((problems+1))

    # The game folder the launchers share, and the gate that keeps it right
    # for each of them. FIFA 17's alone: no other game's launchers change it.
    if [ "$GAME" = fifa17 ]; then
        FOLDER_PROBLEMS=0
        verify_fifa17_folders "$app"
        problems=$((problems + FOLDER_PROBLEMS))
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
        if [ "$GAME" = fifa15 ]; then
            say "For direct offline play, the DLL check above must say offline-patched."
            say "Otherwise use Aurora15Connector's PLAY button. These checks do not test a launch."
            return 0
        fi
        if [ "$GAME" = fifa16 ]; then
            say "These checks do not test a launch. Run fifa16.exe in the $BOTTLE bottle,"
            say "press start and pick a language: the menus appearing is the real test."
            return 0
        fi
        if [ "$GAME" = fifa21 ]; then
            say "These checks do not test a launch. Open the Aurora launcher in the $BOTTLE"
            say "bottle and press PLAY on FIFA 21: the game reaching its menus is the real test."
            return 0
        fi
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
# Where everything a bug report needs is written: a "diagnostics" folder beside
# this script, so the zip, the report and the copied logs sit next to the
# commands that made them and nobody has to be told a path. The Desktop and the
# temp folder are only fallbacks, for a package opened from a read-only volume.
diagnostics_dir() {
    local d
    for d in "$HERE/diagnostics" "$HOME/Desktop/aurora17-diagnostics" \
             "${TMPDIR:-/tmp}/aurora17-diagnostics"; do
        mkdir -p "$d" 2>/dev/null || continue
        if [ -w "$d" ]; then print -r -- "$d"; return 0; fi
    done
    print -r -- "${TMPDIR:-/tmp}"
}

# One line per launch, from what the shim and the server wrote. The shim logs
# origin-auth-capability-loaded once per game start, origin-default-user-result
# once per GetDefaultUser (three of them means the main menu came up with the
# licence accepted) and origin-auth-code-issued once per Origin auth code (one
# or more means the EA login went through). Between the menu and the auth code
# the game opens its first connection to Aurora: the redirector, right after
# Ultimate Team is chosen. The server logs that request without a timestamp,
# which is how a whole investigation once read "nothing on the wire" off a log
# that had it -- so it is counted here rather than left to a grep by time.
launch_progress() {
    local logs="$1"
    if [ -f "$logs/redirect-shim.log" ]; then
        print -r -- "redirect-shim.log, newest launches (UTC): GetDefaultUser results / auth codes"
        awk '/origin-auth-capability-loaded/{if(l!="")print l" du="du" auth="au; l=$1; du=0; au=0}
             /origin-default-user-result/{du++} /origin-auth-code-issued/{au++}
             END{if(l!="")print l" du="du" auth="au}' "$logs/redirect-shim.log" 2>/dev/null \
            | tail -10 | sed 's/^/  /'
        print -r -- "  du=0: never reached the main menu.  du=1: no licence file, or quit early."
        print -r -- "  du=3 auth=0: main menu, then gone before the EA login.  auth>0: logged in."
    else
        print -r -- "(no redirect-shim.log)"
    fi
    local srv; srv="$(ls -t "$logs"/server-*.log 2>/dev/null | head -1)"
    [ -n "$srv" ] || return 0
    local rd bf tls
    rd="$(grep -c 'Redirector <= ' "$srv" 2>/dev/null || true)"
    tls="$(grep -c 'Blaze TLS established' "$srv" 2>/dev/null || true)"
    bf="$(grep -c 'Blaze frame ' "$srv" 2>/dev/null || true)"
    print -r -- "newest server log (${srv:t}): redirector requests=${rd:-0}  Blaze TLS=${tls:-0}  Blaze frames=${bf:-0}"
    if [ "${rd:-0}" -eq 0 ]; then
        print -r -- "  0 redirector requests: no game in this server's lifetime opened its first"
        print -r -- "  connection to Aurora. That connection comes right after Ultimate Team is"
        print -r -- "  chosen and before the Origin auth code, so a du=3 auth=0 launch above with"
        print -r -- "  0 here died between the main menu and its first socket: network start-up,"
        print -r -- "  name resolution (a17hosts) or the shim's connect redirect, not the server."
    fi
    return 0
}

report_mode() {
    local app="$1"
    local out; out="$(diagnostics_dir)/report.txt"

    {
        print -r -- "==== aurora17 report ===================================="
        print -r -- "when      $(date '+%Y-%m-%d %H:%M:%S %z')"
        print -r -- "macOS     $(sw_vers -productVersion) ($(uname -m)), build $(sw_vers -buildVersion 2>/dev/null)"
        print -r -- "mac       $(sysctl -n hw.model 2>/dev/null), $(( $(sysctl -n hw.memsize 2>/dev/null || print 0) / 1073741824 )) GB"
        print -r -- "app       $app"
        print -r -- "version   $(crossover_version "$app")"
        print -r -- "bottle    $BOTTLE_DIR/$BOTTLE"
        # Which package wrote this. A report from an older setup.sh has fewer
        # sections, and knowing that up front saves asking for a second one.
        local rev; rev="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || true)"
        if [ -n "$rev" ] && [ -n "$(git -C "$HERE" status --porcelain -- setup.sh 2>/dev/null)" ]; then rev="$rev-dirty"; fi
        print -r -- "tools     setup.sh of $(date -r "$HERE/setup.sh" '+%Y-%m-%d' 2>/dev/null), ${rev:-not a git checkout}"
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
            # One rpcss.exe per Wine boot. Two means two sessions on one prefix
            # -- setup.sh's own boot never ended and CrossOver started another
            # -- which only the etime column ever showed before.
            local boots
            boots="$(ps -o command= -p "${(j:,:)hold}" 2>/dev/null | grep -c 'rpcss\.exe' || true)"
            if [ "${boots:-0}" -gt 1 ]; then
                print -r -- ""
                print -r -- "NOTE: $boots Wine sessions are up on this bottle at once (one rpcss.exe"
                print -r -- "      each). One of them is a leftover. Quit CrossOver, run Stop.command,"
                print -r -- "      then open it again."
            fi
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

        print -r -- "---- every game in the bottle --------------------------"
        verify_games_table "$app" 2>&1 || true
        print -r -- ""

        print -r -- "---- bottle settings -----------------------------------"
        sed -n '/^\[EnvironmentVariables\]/,$p' "$BOTTLE_DIR/$BOTTLE/cxbottle.conf" 2>/dev/null \
            || print -r -- "(no cxbottle.conf)"
        print -r -- ""

        print -r -- "---- version DLL override ------------------------------"
        if version_override_is_set; then
            print -r -- "$OVERRIDE_DLL = native,builtin  OK"
        else
            print -r -- "NOT SET -- Aurora's redirect shim cannot load"
        fi
        print -r -- ""

        print -r -- "---- C runtime DLL override ----------------------------"
        if crt_override_is_set; then
            print -r -- "${(j: + :)CRT_OVERRIDE_DLLS} = native,builtin  OK"
        else
            print -r -- "NOT SET -- online matches desync at kick-off"
        fi
        local crt_dir=""
        if [ "$GAME" = fifa15 ]; then
            crt_dir="$(f15_crt_native_dir 2>/dev/null || true)"
            print -r -- "Microsoft copies: ${crt_dir:-none found -- Wine's own everywhere FIFA 15 looks}"
        else
            crt_dir="$(game_dir_find 2>/dev/null || true)"
            if [ -n "$crt_dir" ] && crt_dlls_are_microsoft_in "$crt_dir"; then
                print -r -- "Microsoft copies: $crt_dir (shipped with the game)"
            else
                print -r -- "Microsoft copies: ${crt_dir:-no FIFA 17 folder found} -- not Microsoft's"
            fi
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
        print -r -- "root certificates: $(root_cert_count)  (filled by the game's EA login step; 0 = no launch here has reached it. A symptom, not a cause)"
        print -r -- ""

        print -r -- "---- CrossOver logs of a launch (crash logs) -----------"
        crash_logs_report
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

        print -r -- "---- how far each launch got ---------------------------"
        launch_progress "$logs"
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

# macOS crash reports for the game, Wine and the connector.
#
# A Windows-side access violation (0xC0000005) is normally turned by Wine into
# an SEH exception and handled inside the process, so macOS never sees a crash
# and this collects nothing -- that absence is itself an answer, and the index
# file says so rather than leaving a silent empty folder. When the fault does
# escape Wine, the report names the faulting module and address, which is the
# one thing no other log in this bundle carries and the whole question in a
# "it started, then it died" report. Wine names its processes after the PE, so
# the game's report is FIFA17.exe-<date>.ips, not something generic.
#
# Only the names we put on this machine, newest twelve: a DiagnosticReports
# folder is a record of everything that has ever crashed on it, and the rest of
# that is none of our business.
collect_crash_reports() {
    setopt localoptions nullglob
    local out="$1" index="$2"
    local -a dirs=( "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports )
    local -a names=( 'FIFA17.exe' '_fifa17.exe' 'wine*' 'CrossOver*' 'cxrun*' 'Aurora17*' )
    local -a found
    local d n f

    for d in $dirs; do
        [ -d "$d" ] || continue
        for n in $names; do
            found+=( "$d"/${~n}-*.ips "$d"/${~n}-*.crash "$d"/${~n}_*.ips "$d"/${~n}_*.crash )
        done
    done
    # A case-insensitive filesystem matches wine* twice over; ls -t would then
    # spend two of the twelve slots on one file.
    found=( ${(u)found} )

    if (( ! ${#found} )); then
        {
            print -r -- "No crash report naming FIFA17.exe, Wine or CrossOver was found in:"
            for d in $dirs; do print -r -- "  $d"; done
            print -r -- ""
            print -r -- "For an 0xC0000005 that Wine handled itself this is the expected"
            print -r -- "result: the Windows process exits with that code and macOS never"
            print -r -- "sees a crash, so there is nothing here to collect."
        } > "$index" 2>/dev/null || true
        return 0
    fi

    mkdir -p "$out" 2>/dev/null || return 0
    {
        print -r -- "Crash reports naming the game, Wine or CrossOver (newest first):"
        print -r -- ""
        for f in ${(f)"$(/bin/ls -t -- ${found} 2>/dev/null | head -12)"}; do
            [ -n "$f" ] || continue
            cp "$f" "$out/" 2>/dev/null || continue
            print -r -- "  ${f:t}"
            # What faulted, in a couple of bounded lines. An .ips keeps it in
            # JSON on the payload line -- pretty-printed, so the separator is
            # '" : "' and not '":"' -- while a pre-Ventura .crash spells it out
            # in headers. The rest of either file is machine inventory.
            { grep -o -m1 '"exception" *: *{[^}]*}' "$f" 2>/dev/null
              grep -o -m1 '"termination" *: *{[^}]*}' "$f" 2>/dev/null
              grep -o -m1 'Exception Type:.*' "$f" 2>/dev/null
              grep -o -m1 'Crashed Thread:.*' "$f" 2>/dev/null; } \
                | cut -c1-240 | sed 's/^/      /' || true
        done
    } > "$index" 2>&1 || true
    # setup.sh runs under set -e and a bundle is worth more than this extra:
    # nothing collected here is ever a reason to lose the rest of it.
    return 0
}

# ------------------------------------------- CrossOver's log of a launch
# Where the crash logs --play-log writes go. CrossOver's own GUI log option
# writes ~/Library/Logs/CrossOver/<bottle>.cxlog in the same format, and those
# are read too when they mention the game.
crash_log_dir() { print -r -- "$(diagnostics_dir)/crash-logs"; }

# The logs worth reading, newest first: ours, then CrossOver's GUI ones that
# name the game. At most $1 of them (default 3).
crash_logs_found() {
    setopt localoptions nullglob
    local limit="${1:-3}" f
    local -a mine theirs
    mine=( "$(crash_log_dir)"/*.cxlog(N) )
    for f in "$HOME/Library/Logs/CrossOver"/*.cxlog(N); do
        grep -q -m1 -E 'FIFA17\.exe|Aurora17Connector' "$f" 2>/dev/null && theirs+=( "$f" )
    done
    (( ${#mine} + ${#theirs} )) || return 0
    /bin/ls -t -- "${mine[@]}" "${theirs[@]}" 2>/dev/null | head -"$limit"
    return 0
}

# One page from one CrossOver log: every unhandled exception in it and, for the
# first one, the module it landed in. Wine's +loaddll trace names every module
# a process loads and its base address, so an address is placed by the highest
# base below it in the same pid. An address more than 256 MB above every module
# is code that came from no module at all -- generated at run time, which for
# this game means the protector's own -- and telling those two apart is the
# whole reason the log exists. winedbg's backtrace and the CTXAV line from the
# ntdll instrumentation (CX_CTXLOG=1) are printed when they are there.
crash_log_summary() {
    local log="$1"
    [ -s "$log" ] || { print -r -- "no log at $log"; return 1 }
    local -a hits
    hits=( ${(f)"$(grep -n -E 'err:seh:NtRaiseException Unhandled exception|^wine: Unhandled|Unhandled exception: ' "$log" 2>/dev/null | head -20)"} )
    hits=( ${hits:#} )
    print -r -- "log:       $log"
    print -r -- "written:   $(date -r "$log" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    print -r -- "size:      $(wc -c < "$log" | tr -d ' ') bytes, $(wc -l < "$log" | tr -d ' ') lines"
    print -r -- "launches:  $(grep -c 'Loaded L".*FIFA17.exe" at' "$log" 2>/dev/null || true) of FIFA17.exe seen in it"
    local ctxav; ctxav="$(grep -m1 '^CTXAV ' "$log" 2>/dev/null || true)"
    if (( ! ${#hits} )); then
        print -r -- "unhandled: none -- if the game died anyway, it was not an exception Wine saw"
        [ -n "$ctxav" ] && print -r -- "first AV:  $ctxav"
        return 0
    fi
    print -r -- "unhandled: ${#hits} exception(s)"
    local h
    for h in $hits; do print -r -- "  $(print -r -- "${h#*:}" | cut -c1-160)"; done

    local line pid code addr
    line="${hits[1]#*:}"
    pid="$(print -r -- "$line" | awk -F: '{print $2}')"
    code="$(print -r -- "$line" | sed -n 's/.*exception code \([0-9a-fA-F]*\).*/\1/p')"
    addr="$(print -r -- "$line" | sed -n 's/.*addr 0x\([0-9a-fA-F]*\).*/\1/p')"
    [ -n "$addr" ] || addr="$(print -r -- "$line" | sed -n 's/.*(0x\([0-9a-fA-F]*\)).*/\1/p')"
    print -r -- ""
    print -r -- "first one: code ${code:-?} at 0x${addr:-?} in pid ${pid:-?}"
    if [ -n "$addr" ] && [ -n "$pid" ]; then
        local best_base=0 best_name="" base name off seen=0
        for h in ${(f)"$(grep -E "^[0-9.]+:${pid}:[0-9a-f]+:trace:loaddll:build(_ntdll)?_module Loaded L\"" "$log" 2>/dev/null \
                        | sed -n 's/.*Loaded L"\(.*\)" at \([0-9A-Fa-f]*\):.*/\2 \1/p')"}; do
            base="${h%% *}"; name="${h#* }"
            [ -n "$base" ] || continue
            seen=$((seen + 1))
            (( 0x$base <= 0x$addr )) || continue
            (( 0x$base >= best_base )) || continue
            best_base=$(( 0x$base )); best_name="$name"
        done
        if [ "$seen" -eq 0 ]; then
            print -r -- "module:    unknown -- the log has no +loaddll lines for pid $pid"
        elif [ -z "$best_name" ]; then
            print -r -- "module:    NONE -- below every module pid $pid loaded ($seen of them), so this is"
            print -r -- "           code generated at run time, not a module: a JIT in a .NET process,"
            print -r -- "           and in the game the protector's own code (BUGS.md 3, CX_SMC_FLUSH)."
        else
            off=$(( 0x$addr - best_base ))
            if (( off > 0x10000000 )); then
                print -r -- "module:    NONE -- $(printf '0x%x' $off) past the nearest one (${best_name##*\\\\}), so this is"
                print -r -- "           code generated at run time, not a module: a JIT in a .NET process,"
                print -r -- "           and in the game the protector's own code (BUGS.md 3, CX_SMC_FLUSH)."
            else
                print -r -- "module:    ${best_name##*\\\\} + $(printf '0x%x' $off)   (loaded at $(printf '0x%x' $best_base))"
            fi
        fi
    fi
    [ -n "$ctxav" ] && print -r -- "first AV:  $ctxav"
    # a17hosts writes one line per name looked up when AURORA17_HOSTS_DEBUG is
    # set, which --play-log does. Untimestamped, so placed by line number
    # against the exception: a launch that died before its first socket is
    # located by the last name it asked for -- or by asking for none.
    local -a names
    names=( ${(f)"$(grep -n -E '^a17hosts: (getaddrinfo|gethostbyname)\(' "$log" 2>/dev/null | tail -12)"} )
    names=( ${names:#} )
    local exline="${hits[1]%%:*}"
    print -r -- ""
    if (( ${#names} )); then
        print -r -- "names looked up (a17hosts, last ${#names}; the exception is at line ${exline:-none}):"
        for h in $names; do print -r -- "  line ${h%%:*}: $(print -r -- "${h#*:}" | cut -c1-140)"; done
    else
        print -r -- "names looked up: none logged -- either AURORA17_HOSTS_DEBUG was not set for this"
        print -r -- "           launch, or nothing in the bottle resolved a name before the log ended."
    fi
    local bt; bt="$(grep -n -m1 'Backtrace:' "$log" 2>/dev/null | cut -d: -f1 || true)"
    if [ -n "$bt" ]; then
        print -r -- ""
        print -r -- "winedbg backtrace (first):"
        sed -n "${bt},$((bt + 24))p" "$log" | cut -c1-160 | sed 's/^/  /'
    fi
    return 0
}

# --report: the summaries of the newest logs, or how to make one.
crash_logs_report() {
    local f n=0
    for f in ${(f)"$(crash_logs_found 3)"}; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        crash_log_summary "$f" 2>/dev/null || true
        print -r -- ""
    done
    if [ "$n" -eq 0 ]; then
        print -r -- "(none) -- Aurora's own logs say the game exited 0xC0000005 but never where."
        print -r -- "To make one: quit CrossOver, double-click 'diagnostics/12 Play with a"
        print -r -- "crash log.command', press PLAY there, let it crash, then collect."
    fi
    return 0
}

# --bundle: the summaries, a bounded extract of each log, and the whole newest
# log when it is not enormous. The extract is what a reader needs from a
# 30 MB trace: the header, every module the crashing process loaded, and every
# line about an exception with a little context after it.
collect_crash_logs() {
    setopt localoptions nullglob
    local out="$1" index="$2" f base pid first=1
    local -a found
    found=( ${(f)"$(crash_logs_found 3)"} )
    found=( ${found:#} )
    if (( ! ${#found} )); then
        {
            print -r -- "No CrossOver log of a launch was found, in"
            print -r -- "  $(crash_log_dir)"
            print -r -- "  $HOME/Library/Logs/CrossOver"
            print -r -- ""
            print -r -- "Aurora's logs record that the game exited (0xC0000005 says an access"
            print -r -- "violation) but never where. CrossOver's own log does: to make one, quit"
            print -r -- "CrossOver, double-click 'diagnostics/12 Play with a crash log.command',"
            print -r -- "press PLAY in the launcher it opens, let the game crash, then run"
            print -r -- "'1 Collect diagnostics.command' again."
        } > "$index" 2>/dev/null || true
        return 0
    fi
    mkdir -p "$out" 2>/dev/null || return 0
    {
        for f in $found; do
            crash_log_summary "$f" 2>&1 || true
            print -r -- "----"
        done
    } > "$index" 2>&1 || true
    for f in $found; do
        base="${f:t:r}"
        pid="$(grep -m1 -E 'err:seh:NtRaiseException Unhandled exception' "$f" 2>/dev/null | awk -F: '{print $2}')"
        {
            print -r -- "==== extract of $f"
            head -12 "$f"
            print -r -- "==== modules loaded by ${pid:-every pid}"
            if [ -n "$pid" ]; then grep -E "^[0-9.]+:${pid}:[0-9a-f]+:trace:loaddll:" "$f"
            else grep -E 'trace:loaddll:.*FIFA17' "$f"; fi | head -400
            print -r -- "==== exceptions and errors"
            grep -n -E 'Unhandled exception|^CTXAV |Backtrace:|err:|^wine: ' "$f" | head -400 | cut -c1-240
            print -r -- "==== names looked up (a17hosts)"
            grep -n '^a17hosts: ' "$f" | tail -200 | cut -c1-200
            print -r -- "==== 40 lines after the first unhandled exception"
            local n; n="$(grep -n -m1 -E 'err:seh:NtRaiseException Unhandled exception' "$f" | cut -d: -f1 || true)"
            [ -n "$n" ] && sed -n "${n},$((n + 40))p" "$f" | cut -c1-240
        } > "$out/$base.extract.txt" 2>/dev/null || true
        # The whole newest log too, when a zip can carry it.
        if [ "$first" = 1 ] && [ "$(stat -f %z "$f" 2>/dev/null || print 0)" -le 41943040 ]; then
            cp "$f" "$out/" 2>/dev/null || true
        fi
        first=0
    done
    return 0
}

# The network as the Mac sees it, for a launch that died before its first
# socket: which resolvers answer, which interfaces are up and with what, and
# whether a VPN or a proxy is in the way. The Mac's own interface addresses
# stay in -- an interface with no IPv4, or a dozen utun ones, is the kind of
# thing this is for -- except that IPv6 addresses are cut to their first group
# and hardware (MAC) addresses are dropped.
collect_network_snapshot() {
    local out="$1"
    {
        print -r -- "hostname        $(hostname 2>/dev/null)"
        print -r -- "LocalHostName   $(scutil --get LocalHostName 2>/dev/null)"
        print -r -- ""
        print -r -- "---- resolvers (scutil --dns, unscoped) ----"
        scutil --dns 2>/dev/null | awk '/^DNS configuration \(for scoped/{exit} {print}' | head -90
        print -r -- ""
        print -r -- "---- interfaces (ifconfig; no hardware addresses, IPv6 cut short) ----"
        ifconfig -a 2>/dev/null \
            | grep -v -E '^[[:space:]]+(ether|lladdr) ' \
            | sed -E 's/(inet6 )[0-9a-fA-F:.]+(%[A-Za-z0-9]+)?/\1xxxx:...\2/' \
            | head -240
        print -r -- ""
        print -r -- "---- hardware ports ----"
        networksetup -listallhardwareports 2>/dev/null | grep -v 'Ethernet Address' | head -80
        print -r -- ""
        print -r -- "---- system proxy settings ----"
        scutil --proxy 2>/dev/null | head -30
    } > "$out" 2>&1 || true
    return 0
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
    local dest; dest="$(diagnostics_dir)"
    # Collected in the temp folder and deleted once it is zipped: the zip is
    # the thing that gets sent, and a second unzipped copy of it beside the
    # commands is only something else to mistake for the one to attach.
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/aurora17-bundle-$stamp.XXXXXX")" || return 1
    local zipf="$dest/${work:t}.zip"

    mkdir -p "$work/logs"

    say "Collecting..."
    report_mode "$app" > "$work/report.txt" 2>&1 || true

    local logs="$BOTTLE_DIR/$BOTTLE/drive_c/users/crossover/AppData/Local/Aurora17/Logs"
    local f kind keep
    # Every connector log, and the newest few of the other two kinds. Aurora
    # writes one connector log per PLAY and that is where the launcher's error
    # codes land (ERROR [Code 25]: ...), so keeping only the newest three lost
    # the code for most of the launches in a bundle: one bundle held 21 whole
    # sessions in redirect-shim.log and 3 connector logs. They are 1-7 KB each.
    # Server and client logs are the big ones and the newest answer the
    # question; the server's stderr (server-*.log.err) is where a crash lands,
    # and the old glob (server-*.log) never matched it.
    for kind in connector server client; do
        keep=8; [ "$kind" = connector ] && keep=200
        local -a candidates
        candidates=( "$logs"/$kind-*.log(N) "$logs"/$kind-*.log.err(N) )
        (( ${#candidates} )) || continue
        for f in ${(f)"$(/bin/ls -t -- "${candidates[@]}" 2>/dev/null | head -"$keep")"}; do
            [ -n "$f" ] && cp "$f" "$work/logs/" 2>/dev/null || true
        done
    done
    for f in redirect-shim.log wire-transcript.log; do
        [ -f "$logs/$f" ] && cp "$logs/$f" "$work/logs/" 2>/dev/null || true
    done

    # The faulting module, when macOS caught the fault at all. Aurora's own logs
    # can say the game exited 0xC0000005 but never which module did it, and that
    # is exactly the question those reports come in asking.
    collect_crash_reports "$work/crash-reports" "$work/crash-reports.txt"

    # CrossOver's own log of a launch, when one was made (--play-log, or the
    # GUI's log option): the only record that says which module an
    # 0xC0000005 landed in. Guarded so an older harness without the function
    # still bundles everything else.
    if whence -w collect_crash_logs >/dev/null 2>&1; then
        collect_crash_logs "$work/crash-logs" "$work/crash-logs.txt" || true
    fi
    # The Mac's network set-up, for the crash that comes before the game's
    # first socket. Same guard, same reason.
    if whence -w collect_network_snapshot >/dev/null 2>&1; then
        collect_network_snapshot "$work/network.txt" || true
    fi

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
        for f in $FILES $RESOLVER $GATE x86_64-unix/ws2_32.so; do
            if [ -f "$w/$f" ]; then
                print -r -- "  $(shasum -a 256 "$w/$f" | cut -c1-16)  $f"
            else
                print -r -- "  MISSING                    $f"
            fi
        done
        print -r -- ""
        print -r -- "minimum macOS each Mach-O file declares (LC_BUILD_VERSION minos; the"
        print -r -- "shipped ones were built with the macOS 26 SDK for a 15.0 target):"
        for f in $FILES $RESOLVER x86_64-unix/ws2_32.so; do
            case "$f" in *.so|*.dylib) ;; *) continue ;; esac
            [ -f "$w/$f" ] || continue
            print -r -- "  $(otool -l "$w/$f" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')  $f"
        done
    } > "$work/payload.txt" 2>&1

    ( cd "${work:h}" && zip -qr "$zipf" "${work:t}" ) \
        || { say "Could not write $zipf"; rm -rf "$work"; return 1 }

    rm -rf "$work"

    # Keep the three newest zips and drop the rest, so running this after every
    # failed attempt does not fill the folder up.
    local old
    for old in ${(f)"$(/bin/ls -t -- "$dest"/aurora17-bundle-*.zip(N) 2>/dev/null | tail -n +4)"}; do
        [ -n "$old" ] && rm -f "$old"
    done

    say ""
    say "Wrote $zipf"
    say ""
    say "Send that file. It contains the checks above, the Aurora17 logs, any"
    say "crash report macOS kept for the game or Wine, any CrossOver log of a"
    say "launch (see --play-log), the bottle's hosts file and its settings, the"
    say "Mac's network set-up (interfaces and resolvers, no hardware addresses),"
    say "and the hashes of what is installed. It contains no account, password or"
    say "session token."
    say ""
    return 0
}

# ------------------------- the fixed-version WebView2 runtime, into the bottle
# See the WEBVIEW2_* block near the top for why 99.0.1150.52 and not the
# runtime the launcher installs for itself.
#
# Never a stop, except for a cabinet that does not match its hash. Without the
# runtime the launcher's window is blank, which is exactly where it was before
# this step existed, and nothing else in the bottle is affected.
#
# Extraction is Wine's own cabarc.exe: no Homebrew tool is needed, it takes
# about two seconds, and the tree it produces is byte-identical to 7-Zip's. It
# only reads Windows paths, so the cabinet is put inside the bottle first.
# The CrossOver wine wrapper rewrites arguments that look like paths, so the
# arguments below are the shape that survives it -- "-p X", never "-F:*".
install_webview2_runtime() {
    local app="$1"
    local root="$BOTTLE_DIR/$BOTTLE/drive_c/webview2-fixed"
    local dir="$root/$WEBVIEW2_VERSION"
    local cab="$root/download.cab"
    local extracted="$root/$WEBVIEW2_CAB_NAME"
    local wine="$app/Contents/SharedSupport/CrossOver/bin/wine"
    local got=""

    if [ "${WEBVIEW2_RUNTIME:-}" = skip ]; then
        note "skipped — WEBVIEW2_RUNTIME=skip was set"
        say "        The RebornFUT launcher's window stays blank without it."
        return 0
    fi
    # Idempotent: the download is 165 MB and the folder is 365 MB unpacked.
    if [ -f "$dir/msedgewebview2.exe" ]; then
        ok "WebView2 $WEBVIEW2_VERSION — already in the $BOTTLE bottle"
        return 0
    fi
    if [ ! -d "$BOTTLE_DIR/$BOTTLE" ]; then
        note "no bottle called '$BOTTLE' yet, so there is nowhere to put it"
        return 0
    fi
    if [ ! -x "$wine" ]; then
        note "no wine in ${app:t} to unpack the cabinet with"
        return 0
    fi
    mkdir -p "$root" || { note "could not make $root"; return 0; }

    if [ -n "${WEBVIEW2_CAB:-}" ]; then
        if [ ! -f "${WEBVIEW2_CAB:A}" ]; then
            note "no cabinet at ${WEBVIEW2_CAB:A} (WEBVIEW2_CAB)"
            say "        Unset WEBVIEW2_CAB to download it instead."
            return 0
        fi
        cp "${WEBVIEW2_CAB:A}" "$cab" || { note "could not copy ${WEBVIEW2_CAB:A} into the bottle"; return 0; }
        say "        from ${WEBVIEW2_CAB:A} — nothing downloaded"
    else
        say "        downloading 165 MB, once — this takes a minute"
        if ! curl -fL --retry 2 -o "$cab" "$WEBVIEW2_URL"; then
            rm -f "$cab"
            note "could not download the runtime from"
            say "        $WEBVIEW2_URL"
            say "        The launcher's window stays blank until this succeeds. With no"
            say "        internet here, fetch that file elsewhere and run:"
            say "          WEBVIEW2_CAB=/path/to/the.cab ./setup.sh --bottle"
            return 0
        fi
    fi

    got="$(shasum -a 256 "$cab" | cut -d' ' -f1)"
    if [ "$got" != "$WEBVIEW2_SHA256" ]; then
        rm -f "$cab"
        die $E_PAYLOAD "The WebView2 runtime cabinet is not the file it should be.
             expected  $WEBVIEW2_SHA256
             got       $got
         It has been deleted, and nothing was unpacked from it. Either the
         download was cut short, or that file is not Microsoft's. Run this
         again to fetch it afresh."
    fi

    rm -rf "$extracted"
    if ! "$wine" --bottle "$BOTTLE" --cx-app cabarc.exe \
                 -p X 'C:\webview2-fixed\download.cab' 'C:\webview2-fixed\' >/dev/null 2>&1; then
        note "cabarc could not unpack the cabinet in the $BOTTLE bottle"
    fi
    rm -f "$cab"
    if [ ! -f "$extracted/msedgewebview2.exe" ]; then
        rm -rf "$extracted"
        note "the cabinet unpacked to nothing usable — the launcher's window stays blank"
        say "        Quit CrossOver completely and run ./setup.sh --bottle again."
        return 0
    fi
    mv -f "$extracted" "$dir" || { note "could not put the runtime at $dir"; return 0; }
    ok "WebView2 $WEBVIEW2_VERSION unpacked into the $BOTTLE bottle"
    say "        this is what makes the RebornFUT launcher's window draw at all"
    return 0
}

# --------------------------------------------- the CAS launcher, in the bottle
# See the CAS_* block near the top. CAS runs PowerShell by its full path,
# %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe, which is also
# where step 8 puts Aurora17's stand-in. One file cannot be both, so CAS's
# takes the name and Aurora17's moves beside it as aurora17-powershell.exe,
# where CAS's hands it every command line that is not CAS's own -- PLAY from
# an Aurora17 folder setup.sh did not find still reaches it, exit code and
# all. Step 8 knows this and refreshes that file instead of the name.
#
# The device id is a hash of this Mac's hardware UUID as Wine's WMI reports
# it, so it stays the same across bottles, reinstalls and runs. That is on
# purpose: CAS bans by device, and an id made up per bottle would look like
# dodging one.
#
# The file it replaces is kept as powershell.exe.wine-stub, once, unless step
# 8 already kept Wine's stub as powershell.exe.wine-stub-orig. Wine's
# fake-dll refresh after a CrossOver update does not overwrite a native file,
# so nothing puts the stub back behind our back. Never a stop.
install_cas_powershell() {
    local psdir="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
    local ps="$psdir/powershell.exe" aurora="$HERE/aurora17/powershell.exe"

    if [ ! -d "$BOTTLE_DIR/$BOTTLE" ]; then
        note "no bottle called '$BOTTLE' yet, so there is nowhere to put CAS's stand-in"
        return 0
    fi
    if cmp -s "$CAS_PS" "$ps"; then
        ok "CAS's device check — already answered in the $BOTTLE bottle"
        return 0
    fi
    mkdir -p "$psdir" || { note "could not make $psdir"; return 0; }
    if [ -f "$ps" ] && cmp -s "$aurora" "$ps"; then
        # Aurora17's, from step 8. It goes beside, first: if that copy
        # fails, PLAY keeps the file it has and CAS goes without.
        if ! cmp -s "$aurora" "$psdir/$CAS_HANDOFF"; then
            cp -X "$aurora" "$psdir/$CAS_HANDOFF" || {
                note "could not move Aurora17's stand-in aside in the $BOTTLE bottle,"
                say "        so CAS's stand-in was not put in. Quit CrossOver completely"
                say "        and run ./setup.sh --bottle again."
                return 0
            }
        fi
    elif [ -f "$ps" ] && [ ! -f "$ps.wine-stub" ] && [ ! -f "$ps.wine-stub-orig" ]; then
        # Somebody else's file -- Wine's stub on a bottle step 8 never
        # touched. Keep it once; never overwrite that copy.
        cp -X "$ps" "$ps.wine-stub" || {
            note "could not keep the bottle's own powershell.exe, so it was left as it is"
            say "        and CAS will say \"Install the latest CAS launcher to verify this"
            say "        device.\" Quit CrossOver completely and run ./setup.sh --bottle again."
            return 0
        }
    fi
    cp -X "$CAS_PS" "$ps" || {
        note "could not write CAS's stand-in into the $BOTTLE bottle"
        say "        CAS will say \"Install the latest CAS launcher to verify this device.\""
        say "        Quit CrossOver completely and run ./setup.sh --bottle again."
        return 0
    }
    if [ -f "$psdir/$CAS_HANDOFF" ]; then
        ok "CAS's device check now answers in the $BOTTLE bottle"
        say "        (Aurora17's stand-in is beside it as $CAS_HANDOFF and still gets PLAY)"
    elif [ -f "$ps.wine-stub" ]; then
        ok "CAS's device check now answers in the $BOTTLE bottle"
        say "        (Wine's own powershell.exe is kept beside it as powershell.exe.wine-stub)"
    else
        ok "CAS's device check now answers in the $BOTTLE bottle"
    fi
    return 0
}

# Whether macOS hands cas:// links to CAS Link (CrossOver). LaunchServices'
# own table is the answer; its dump names a claim by CFBundleURLName, which
# is ours. A macOS whose lsregister cannot dump that table falls back on the
# app being there and saying so in its Info.plist.
cas_link_registered() {
    local dump
    [ -d "$CAS_LINK_APP" ] || return 1
    dump="$("$LSREGISTER" -dump URLSchemeBinding 2>/dev/null || true)"
    if [ -n "$dump" ]; then
        grep -Eq '^cas:[[:space:]].*CAS sign-in' <<< "$dump"
        return
    fi
    /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' \
        "$CAS_LINK_APP/Contents/Info.plist" 2>/dev/null | grep -qx cas
}

# The app is built here rather than shipped: the wine it runs and the bottle
# it names are this install's, and a signed bundle cannot be edited after the
# fact. The source it was built from is kept inside it, so a second run that
# would build the same app finds it already there and leaves it alone.
# osacompile writes a fresh Info.plist, which is why the plist edits come
# after it and the signature after those. Never a stop: without it CAS still
# runs and only the browser's sign-in hand-back is lost.
install_cas_link() {
    local app="$1"
    local wine="$app/Contents/SharedSupport/CrossOver/bin/wine"
    local tmp built src w b p n

    if [ ! -f "$CAS_LINK_SRC" ]; then
        note "fixes/cas-link.applescript is missing from this package"
        return 0
    fi
    if [ ! -x "$LSREGISTER" ]; then
        note "this macOS has no lsregister, so nothing can claim cas:// links"
        return 0
    fi
    tmp="$(mktemp -d -t caslink)" || { note "could not make a scratch folder"; return 0; }
    built="$tmp/${CAS_LINK_APP:t}"

    # Each value goes into an AppleScript string, so its backslashes and
    # double quotes are escaped the AppleScript way.
    w="${wine//\\/\\\\}";             w="${w//\"/\\\"}"
    b="${BOTTLE//\\/\\\\}";           b="${b//\"/\\\"}"
    p="${BOTTLE_DIR//\\/\\\\}";       p="${p//\"/\\\"}"
    n="${${app:t:r}//\\/\\\\}";       n="${n//\"/\\\"}"
    src="$(<"$CAS_LINK_SRC")"
    src="${src//@WINE@/$w}"
    src="${src//@BOTTLE_PATH@/$p}"
    src="${src//@BOTTLE@/$b}"
    src="${src//@APPNAME@/$n}"
    print -r -- "$src" > "$tmp/cas-link.applescript"

    if cmp -s "$tmp/cas-link.applescript" "$CAS_LINK_APP/Contents/Resources/cas-link.applescript" \
       && codesign --verify "$CAS_LINK_APP" 2>/dev/null && cas_link_registered; then
        rm -rf "$tmp"
        ok "CAS Link (CrossOver) — already takes cas:// links to the $BOTTLE bottle"
        return 0
    fi

    if ! osacompile -o "$built" "$tmp/cas-link.applescript" >/dev/null 2>&1; then
        rm -rf "$tmp"
        note "osacompile could not build CAS Link (CrossOver)."
        say "        CAS still runs, but the browser cannot hand Discord sign-in back"
        say "        to it. Run ./setup.sh --bottle again to retry."
        return 0
    fi
    local plist="$built/Contents/Info.plist"
    if ! { plutil -replace CFBundleIdentifier -string "$CAS_LINK_ID" "$plist" \
           && plutil -replace LSUIElement -bool YES "$plist" \
           && plutil -replace CFBundleURLTypes \
                  -json '[{"CFBundleURLName":"CAS sign-in","CFBundleURLSchemes":["cas"]}]' "$plist" \
           && cp "$tmp/cas-link.applescript" "$built/Contents/Resources/cas-link.applescript" \
           && codesign -fs - "$built" >/dev/null 2>&1; } then
        rm -rf "$tmp"
        note "could not finish building CAS Link (CrossOver) — CAS sign-in from the"
        say "        browser will not reach the bottle. Run ./setup.sh --bottle again."
        return 0
    fi

    # Swap it in: the old one is unregistered first so LaunchServices does
    # not keep a claim on a bundle that is about to vanish.
    mkdir -p "${CAS_LINK_APP:h}" 2>/dev/null || true
    if [ -d "$CAS_LINK_APP" ]; then
        "$LSREGISTER" -u "$CAS_LINK_APP" >/dev/null 2>&1 || true
        rm -rf "$CAS_LINK_APP"
    fi
    if ! mv "$built" "$CAS_LINK_APP"; then
        rm -rf "$tmp"
        note "could not put CAS Link (CrossOver) in ${CAS_LINK_APP:h}"
        return 0
    fi
    rm -rf "$tmp"
    "$LSREGISTER" -f "$CAS_LINK_APP" >/dev/null 2>&1 || true
    if cas_link_registered; then
        ok "CAS Link (CrossOver) takes cas:// links to the $BOTTLE bottle"
        say "        (in ${CAS_LINK_APP:h}; this is how Discord sign-in gets back to CAS)"
    else
        note "CAS Link (CrossOver) is built but macOS has not given it cas:// links."
        say "        Open it once from ${CAS_LINK_APP:h}, then try signing in again."
    fi
    return 0
}

# Step 9c, both halves. FIFA 17 only: configure_bottle returns before this
# for the other games.
install_cas_support() {
    local app="$1"
    if [ "${CAS_SUPPORT:-}" = skip ]; then
        note "skipped — CAS_SUPPORT=skip was set"
        say "        The CAS launcher cannot verify this Mac or finish sign-in without it."
        return 0
    fi
    install_cas_powershell
    install_cas_link "$app"
}

# ------------------------------- FIFA 21's launcher, the DNS Client check
# The Aurora launcher plays FIFA 21 in this same bottle, but before it starts
# anything it asks the service manager whether Windows' DNS Client service,
# Dnscache, is running. A bottle has no such service, so the check fails and
# PLAY never gets as far as the game. Wine has no DNS Client to offer, and the
# game does not need one: its lookups go through Wine's resolver, which
# a17hosts already steers.
#
# So Dnscache is made a name for a service Wine does have. spoolsv.exe is
# Wine's print spooler, a do-nothing service process that starts and stays
# up; registered as its own process under this name, with start type 2, Wine
# starts it with the bottle and the launcher sees "Running". Proven in the
# bottle FIFA 21 first played online from (launcher log: dnsClient=Running;
# startType=2; preflight=pass). These are the values `sc create` wrote there.
#
# Written straight into system.reg, like every other key here, so CrossOver
# has to be quit, which setup.sh already makes sure of. Never a stop: FIFA 17
# does not need it.
DNSCACHE_SECTION='[System\\CurrentControlSet\\Services\\Dnscache]'
DNSCACHE_LINES=(
    '"DisplayName"="DNS Client"'
    '"ErrorControl"=dword:00000001'
    '"ImagePath"=str(2):"C:\\windows\\system32\\spoolsv.exe"'
    '"ObjectName"="LocalSystem"'
    '"Start"=dword:00000002'
    '"Type"=dword:00000010'
)
install_dnscache_standin() {
    local reg line missing=0
    reg="$(bottle_system_reg)"
    if [ ! -f "$reg" ]; then
        note "no bottle called '$BOTTLE' yet, so there is nowhere to add it"
        return 0
    fi
    for line in "${DNSCACHE_LINES[@]}"; do
        reg_line_is_set "$reg" "$DNSCACHE_SECTION" "$line" || { missing=1; break; }
    done
    if [ "$missing" = 0 ]; then
        ok "the DNS Client check FIFA 21's launcher makes — already answered in the $BOTTLE bottle"
        return 0
    fi
    for line in "${DNSCACHE_LINES[@]}"; do
        set_reg_line "$reg" "$DNSCACHE_SECTION" "$line" "${line%%=*}" || {
            note "could not add the DNS Client stand-in to the $BOTTLE bottle"
            say "        FIFA 21's Aurora launcher will stop before the game starts."
            say "        Quit CrossOver completely and run ./setup.sh --bottle again."
            return 0
        }
    done
    ok "FIFA 21's Aurora launcher will find a DNS Client running in the $BOTTLE bottle"
    say "        (Wine's print spooler, registered as Dnscache; it starts with the bottle)"
    return 0
}

# What FIFA 21 needs that is not the bottle's to give: the Aurora launcher
# installed in it, and a game folder. Both are the player's to do in the
# launcher, so these are notes, never a stop.
f21_check_game() {
    local d
    if aurora_launcher_dir >/dev/null 2>&1; then
        ok "the Aurora launcher is in the $BOTTLE bottle"
    else
        note "the Aurora launcher (Aurora.exe) is not in the $BOTTLE bottle yet, and FIFA 21"
        say "        plays only from it. Run Aurora.exe once in this bottle (CrossOver's"
        say "        Run Command), then play FIFA 21 from it."
    fi
    if d="$(game_dir_of fifa21 2>/dev/null)"; then
        ok "FIFA 21 is in $d"
    else
        note "no FIFA 21 folder found; the Aurora launcher asks for it, and nothing"
        say "        here needs it"
    fi
    return 0
}

# Step 8's second half: the stand-in inside the bottle, so it is found no
# matter where Aurora17 lives -- and the Aurora launcher, which plays FIFA 21
# through the pack's Start-Aurora21.ps1, only ever finds this one. It is the
# same file for both: aurora17/powershell.exe does Start-Aurora21.ps1's work
# too. The file being replaced is Wine's own stub; we keep a copy of it.
# Once step 9c has put CAS's stand-in in that name, CAS's hands every call
# that is not its own device check on to $CAS_HANDOFF beside it, so that is
# the file kept current here, and CAS's is left where it is. Wine's stub was
# kept when CAS's went in. Sets PS_OK=1 and PS_BOTTLE_ACTION once it is in;
# a bottle that is not there is left for the caller to report.
install_bottle_powershell() {
    PSDIR="$BOTTLE_DIR/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
    PS_BOTTLE_NAME=powershell.exe
    [ -d "$BOTTLE_DIR/$BOTTLE" ] || return 0
    if [ -f "$PSDIR/powershell.exe" ] && cmp -s "$CAS_PS" "$PSDIR/powershell.exe"; then
        PS_BOTTLE_NAME="$CAS_HANDOFF"
        PS_BOTTLE_ACTION=replaced
    elif [ -f "$PSDIR/powershell.exe" ] \
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
    cp -X "$HERE/aurora17/powershell.exe" "$PSDIR/$PS_BOTTLE_NAME" \
        || die $E_PERMISSION "Could not write the stand-in into the $BOTTLE bottle.
         Quit CrossOver completely and run this again. If it repeats, check
         there is free disk space."
    if [ "$PS_BOTTLE_NAME" = powershell.exe ]; then
        ok "into the $BOTTLE bottle ($PS_BOTTLE_ACTION)"
    else
        ok "into the $BOTTLE bottle, as $PS_BOTTLE_NAME behind CAS's stand-in"
    fi
    PS_OK=1
}

# Takes the named leftover single-game variables (leftover_game_vars) out of
# cxbottle.conf, after saving it as cxbottle.conf.bak-<time> next to it.
remove_leftover_game_vars() {
    local conf="$1" backup tmp v pat; shift
    backup="$conf.bak-$(date +%Y%m%d-%H%M%S)"
    if ! { cp -X "$conf" "$backup" 2>/dev/null || cp "$conf" "$backup"; }; then
        note "could not back up $conf; ${(j: and :)@} left in it"
        return 0
    fi
    pat="^\"(${(j:|:)@})\"[[:space:]]*="
    tmp="$(mktemp -t a17conf)" || { note "could not remove ${(j: and :)@} from $conf"; return 0; }
    grep -Ev "$pat" "$conf" > "$tmp"
    if [ -s "$tmp" ] && cat "$tmp" > "$conf"; then
        for v in "$@"; do
            ok "removed $v from this bottle's settings"
        done
        say "        An earlier single-game setup put it there. This bottle now holds more"
        say "        than one game, the games the per-game table lists take their own and"
        say "        never read it, and all it still did was reach the launchers, WebView2"
        say "        and .NET helpers here, where CX_TOPDOWN_LIMIT can break large reservations."
        say "        The old file is kept as $backup"
    else
        note "could not remove ${(j: and :)@} from $conf (the backup is $backup)"
    fi
    rm -f "$tmp"
    return 0
}

# One setting into the bottle's [EnvironmentVariables], in $CONF.
add_setting() {
    # A key that is present with the wrong value is not "already set". Left
    # alone it silently keeps the wrong graphics backend and the game hangs.
    # -Fx, not a regexp: see the same grep in verify_install. A value
    # with a backslash in it is a Windows path, not a pattern.
    if grep -Fqx -- "\"$1\" = \"$2\"" "$CONF"; then
        ok "$1 — already set"
    elif grep -q "^\"$1\" = " "$CONF"; then
        # One of SOFT_SETTINGS: another game set up in this bottle first put
        # its own value there. With the profile table no game the table lists
        # reads it, so it is left as that game's setup wrote it -- changing it
        # would change what the launchers in this bottle run with, and
        # stopping would make a second game impossible to add.
        if (( ${SOFT_SETTINGS[(Ie)$1]} )); then
            note "$1 is $(sed -n "s/^\"$1\" = \"\(.*\)\"$/\1/p" "$CONF" | head -1) in this bottle, from a game set up in it before;"
            say "        left as it is. $GAME_LABEL gets its own value from the copy's"
            say "        per-game table, which ignores this one."
            return 0
        fi
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

# ------------------------------------------- the bottle, on its own
# Steps 7 to 9c are everything that lives in the bottle rather than in the
# CrossOver copy: the settings, the version override, the shortcuts, the
# PowerShell stand-in, the six network mappings, the licence file, the
# WebView2 runtime and the CAS launcher's two pieces (one of which, the
# cas:// handler, lives in ~/Applications but names this bottle).
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
        say "        exists, run:   AURORA_BOTTLE='name' ./setup.sh --bottle"
        say "        or re-run this installer."
    else
        # See "one bottle, every game" near the top. With the table this
        # bottle gets only what its games share, and a game that shares it
        # with another is simply added.
        if [ "$PROFILES" = 1 ]; then
            if [ ${#SHARED_WITH} -gt 0 ]; then
                ok "adding $GAME_LABEL to the $BOTTLE bottle, which already has ${(j: and :)SHARED_WITH}"
            fi
            ok "${APP:t} gives each game its own settings (its ntdll.so has the per-game table),"
            say "        so this bottle gets only the settings every game shares"
            # See leftover_game_vars. In a bottle that holds another game,
            # they go (a backup first); in a game's own bottle they stay.
            local -a stray
            stray=( ${(f)"$(leftover_game_vars "$CONF")"} )
            if [ ${#stray} -gt 0 ] && [ ${#SHARED_WITH} -gt 0 ]; then
                remove_leftover_game_vars "$CONF" $stray
            elif [ ${#stray} -gt 0 ]; then
                say "        (${(j: and :)stray} from an earlier setup is left as it is: the games"
                say "        the table lists ignore it, and every other program in the bottle"
                say "        -- launchers, WebView2, .NET helpers -- still gets it, as before)"
            fi
        fi
        grep -q '^\[EnvironmentVariables\]' "$CONF" || printf '\n[EnvironmentVariables]\n' >> "$CONF"
        for kv in $BOTTLE_SETTINGS; do add_setting "${kv%%=*}" "${kv#*=}"; done

        # FIFA 15 only: the game must run in a window. Full screen asks for a
        # display-mode switch that the Mac driver applies only while the game
        # is the active application, and the switch never lands, so the game
        # sits on a black screen. The file is read at start-up; an existing one
        # is the player's own and is left alone.
        if [ "$GAME" = fifa15 ]; then
            F15INI="$HOME/Documents/FIFA 15/fifasetup.ini"
            if [ -f "$F15INI" ]; then
                if grep -q '^FULLSCREEN = 0' "$F15INI"; then
                    ok "fifasetup.ini — windowed already"
                else
                    note "$F15INI sets full screen; the game may show a black window."
                    say "        Set  FULLSCREEN = 0  in it if it does."
                fi
            else
                mkdir -p "${F15INI:h}" \
                    && printf 'RESOLUTIONWIDTH = 1280\nRESOLUTIONHEIGHT = 800\nASPECTRATIO = 1.600\nRENDERINGQUALITY = 3\nWAITFORVSYNC = 1\nVOICECHAT = 1\nFULLSCREEN = 0\n' > "$F15INI" \
                    && ok "fifasetup.ini — windowed 1280x800 (in ~/Documents/FIFA 15)" \
                    || note "could not write $F15INI"
            fi
        fi

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
        # See f15_ensure_crt_dlls. The override set below only tells Wine
        # to prefer a native C runtime; FIFA 15's folder ships none, so one has
        # to be put there first or there is nothing to prefer. FIFA 17 ships its
        # own and needs nothing here.
        if [ "$GAME" = fifa15 ]; then
            f15_ensure_crt_dlls "$APP" || true
        fi
        # See the comment on set_version_override. Nothing else puts this there,
        # and without it every other part of the install is wasted.
        # FIFA 16 needs none of the three user.reg settings below: no redirect
        # DLL, no online C runtime, and no Aurora helper racing a proxy lookup.
        # None of the three was in the bottle its fix was proven in.
        # The C runtime and dinput8 overrides are per program, version is
        # bottle-wide (see OVERRIDE_EXES); a per-program one an earlier
        # setup.sh wrote bottle-wide counts, and is left where it is.
        if [ "$GAME" = fifa16 ]; then
            ok "FIFA 16: no DLL override or proxy setting needed"
            # See f16_pin_crt: only in a bottle that has FIFA 15's runtime
            # override bottle-wide. Not a stop: FIFA 16 then loads whichever
            # msvcr110 it finds, which is how it ran before this existed.
            if [ -f "$(bottle_user_reg)" ] && f16_crt_pin_needed; then
                if f16_crt_is_pinned; then
                    ok "fifa16.exe: ${(j: + :)F16_CRT_PIN} = builtin — already set"
                elif f16_pin_crt; then
                    ok "fifa16.exe: ${(j: + :)F16_CRT_PIN} = builtin"
                    say "        this bottle has them as native,builtin for every program (from"
                    say "        FIFA 15's setup); FIFA 16's fix was proven on Wine's own"
                else
                    note "could not keep fifa16.exe on Wine's own ${(j: and :)F16_CRT_PIN} in $(bottle_user_reg)"
                    say "        Quit CrossOver completely and run this again."
                fi
            fi
        elif [ -f "$(bottle_user_reg)" ]; then
            if [ "$OVERRIDE_DLL" = version ]; then
                OVERRIDE_WHERE="for the whole bottle"
            else
                OVERRIDE_WHERE="for ${(j:, :)OVERRIDE_EXES}"
            fi
            if version_override_is_set; then
                if [ "$OVERRIDE_DLL" != version ] && dll_override_is_global "$OVERRIDE_DLL"; then
                    ok "$OVERRIDE_DLL = native,builtin — already set, for the whole bottle by an earlier setup"
                else
                    ok "$OVERRIDE_DLL = native,builtin $OVERRIDE_WHERE — already set"
                fi
            elif set_version_override; then
                ok "$OVERRIDE_DLL = native,builtin $OVERRIDE_WHERE (kept the old user.reg as user.reg.bak-aurora17)"
                say "        this is what lets Aurora's redirect load at all"
            else
                die $E_PERMISSION "Could not set the $OVERRIDE_DLL DLL override in
                 $(bottle_user_reg)
             Without it the game will say the servers have been shut down.
             Quit CrossOver completely and run this again."
            fi
            # See the C runtime override. Same file again. Not a stop: without
            # it the game installs and plays offline exactly as before, and it
            # is only an online match that ends at kick-off.
            if [ ${#CRT_OVERRIDE_DLLS} -gt 0 ]; then
                if crt_override_is_set; then
                    ok "${(j: + :)CRT_OVERRIDE_DLLS} = native,builtin — already set"
                elif set_crt_override; then
                    ok "${(j: + :)CRT_OVERRIDE_DLLS} = native,builtin for ${(j:, :)OVERRIDE_EXES}"
                    say "        without this, online matches desync at kick-off"
                else
                    note "could not point Wine at the game's own C runtime in $(bottle_user_reg)"
                    say "        offline play is unaffected; online matches will desync at"
                    say "        kick-off. Quit CrossOver completely and run this again."
                fi
            fi
            # FIFA 21's ucrtbase, for FIFA21.exe only (see the C runtime
            # override). Not a stop: the PowerShell stand-in writes it at PLAY.
            if [ "$GAME" = fifa21 ]; then
                if dll_override_is_set ucrtbase; then
                    ok "ucrtbase = native,builtin for FIFA21.exe — already set"
                elif set_dll_override ucrtbase; then
                    ok "ucrtbase = native,builtin for FIFA21.exe"
                    say "        this is what lets the maths bridge give FIFA 21 Microsoft's maths"
                else
                    note "could not set ucrtbase for FIFA21.exe in $(bottle_user_reg)"
                    say "        the PowerShell stand-in sets it at PLAY instead"
                fi
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

        # See guard_menu_shims. After the repointing, so the guard goes into
        # the shim that is actually going to be used.
        GUARDED="$(guard_menu_shims "$SELF" "$APP" 2>/dev/null || print -r -- fail)"
        case "$GUARDED" in
            fail) note "could not add the licence guard to the bottle's shortcuts."
                  say "        Clicking FIFA 17 in CrossOver still works, but if the bottle"
                  say "        is ever remade, run this again before using it." ;;
            0)    ok "the licence guard is on the bottle's game shortcuts" ;;
            *)    ok "licence guard added to $GUARDED game shortcut(s)"
                  say "        they now top up the licence file themselves, so remaking"
                  say "        the bottle in CrossOver cannot bring §18 back" ;;
        esac

        BOTTLE_OK=1
    fi

    if [ "$GAME" = fifa16 ]; then
        # The same three steps, for the same reason, and nothing in their
        # place: fifa16.exe runs on its own. What it needs from the bottle is
        # the four settings above and a drive letter for its folder, which
        # f16_check_game sees to once this returns.
        say ""
        say "8-9a. Skipped — these three steps are FIFA 17's (Aurora17 stand-in, EA names, licence)"
        PS_OK=1; PS_AURORA_DIR=""; PS_BOTTLE_ACTION=""; HOSTS_OK=1; LICENCE_OK=1
        return 0
    fi
    if [ "$GAME" = fifa15 ]; then
        # Steps 8, 9 and 9a are FIFA 17's: the PowerShell stand-in exists for
        # Aurora17's Play.ps1, the six names are Aurora17's redirect targets,
        # and 1027460.dlf is FIFA 17's licence. Aurora15Connector is a single
        # self-contained program and FIFA 15's crack serves its own licence.
        # Aurora15Connector runs under CrossOver as is; what it needs from the
        # bottle is the dinput8 override set above (its EA-MITM hook is a proxy
        # dinput8.dll) and the three settings. Nothing to install.
        say ""
        say "8-9a. Skipped — these three steps are FIFA 17's (Aurora17 stand-in, EA names, licence)"
        PS_OK=1; PS_AURORA_DIR=""; PS_BOTTLE_ACTION=""; HOSTS_OK=1; LICENCE_OK=1
        return 0
    fi
    if [ "$GAME" = fifa21 ]; then
        # FIFA 21 plays only from the Aurora launcher, and what that needs of
        # the bottle beyond step 7 is two stand-ins: PowerShell, which its
        # PLAY runs Start-Aurora21.ps1 through, and Dnscache (9d), which it
        # asks about before it starts anything. The Aurora17 folder is
        # Aurora17Connector's and not looked for. Step 9's names are
        # Aurora17's -- FIFA 21's stand-in writes its own at PLAY -- and 9a to
        # 9c are FIFA 17's licence and launchers. In a bottle CAS is in,
        # Aurora17's stand-in goes beside CAS's, which keeps the name.
        say ""
        say "8. Installing the PowerShell stand-in the Aurora launcher needs for FIFA 21"
        PS_OK=0; PS_AURORA_DIR=""; PS_BOTTLE_ACTION=""
        install_bottle_powershell
        [ "$PS_OK" = 1 ] || note "no bottle called '$BOTTLE' yet, so there is nowhere to put it"
        say ""
        say "9-9c. Skipped — FIFA 17's (EA names, licence, WebView2, CAS)"
        HOSTS_OK=1; LICENCE_OK=1
        say ""
        say "9d. Letting the Aurora launcher start FIFA 21"
        install_dnscache_standin
        return 0
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
        say ""
        say "9b. Installing the browser runtime the RebornFUT launcher needs"
        install_webview2_runtime "$APP"
        say ""
        say "9c. Making the CAS launcher work"
        install_cas_support "$APP"
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

    # Also install it inside the bottle (install_bottle_powershell).
    install_bottle_powershell

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

    # ------------------------------------------- 9b. the launcher's browser
    # See install_webview2_runtime. Last, because it is the only step here that
    # can want the internet, and everything the game itself needs is already in
    # by the time it runs.
    say ""
    say "9b. Installing the browser runtime the RebornFUT launcher needs"
    install_webview2_runtime "$APP"

    # ---------------------------------------------- 9c. the CAS launcher
    # See install_cas_powershell and install_cas_link. After 9b, whose
    # runtime CAS's window needs as much as RebornFUT's, and after step 8,
    # whose file in the bottle it moves aside.
    say ""
    say "9c. Making the CAS launcher work"
    install_cas_support "$APP"

    # -------------------------------------------- 9d. FIFA 21's launcher
    # See install_dnscache_standin. Online only: an offline install has no
    # Aurora launcher to ask.
    say ""
    say "9d. Letting the Aurora launcher start FIFA 21"
    install_dnscache_standin

    # ------------------------------------------- 9e. the FIFA 17 game folder
    # See fix_fifa17_folders. Only keeps copies; the gate does the rest.
    say ""
    say "9e. Keeping copies of the FIFA 17 files launchers replace"
    fix_fifa17_folders
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
# ----------------------------------- removing the old background cleanup
# Older versions of this package installed a LaunchAgent here. It is gone;
# what is left is the code that takes it off a machine that still has one.
CLEANUP_LABEL=com.fifa-crossover-cleanup
CLEANUP_BASE="$HOME/Library/Application Support/FIFA-CrossOver"
CLEANUP_HELPER="$CLEANUP_BASE/cleanup"
# A session started outside CrossOver's window -- ./setup.sh --play-offline --
# has no GUI to prove it is alive, and every rule here calls a Wine process
# with no GUI behind it an orphan. So the launcher writes its own pid here for
# as long as it runs, and --unstick and --shutdown leave everything alone
# while that pid is alive. A crashed launcher leaves a pid that is gone, which
# reads as no hold at all.
CLEANUP_HOLD="$CLEANUP_BASE/session-hold"
CLEANUP_PLIST="$HOME/Library/LaunchAgents/$CLEANUP_LABEL.plist"
# The background cleanup agent was removed. What it did -- wake every 30
# seconds, for ever, on every machine this package is installed on -- is not
# something to leave on somebody else's Mac for a game patch. Its ownership
# rules were also wider than its name: our_server_dirs() enumerates every
# bottle under BOTTLE_DIR, so a stranger's Rocket League or Steam bottle was
# in scope for its kills and its directory removals too.
#
# Nothing replaces it, because nothing needs to. A stray connector costs a
# held port and a locked bottle, and both only matter at the *next* launch --
# not while the Mac sits idle. Stop.command (--shutdown) and --unstick do the
# same sweep when asked, and --verify reports leftovers instead of acting on
# them. patches/README-stray-processes.md has the full diagnosis.
cleanup_agent_present() {
    [ -f "$CLEANUP_PLIST" ] || [ -e "$CLEANUP_HELPER" ] \
        || launchctl print "gui/$UID/$CLEANUP_LABEL" >/dev/null 2>&1
}

# Runs on every install, so publishing this uninstalls the agent from the
# machines that already have it. Returns 0 only when there was one to remove.
remove_cleanup_agent() {
    local had=0
    cleanup_agent_present && had=1
    launchctl bootout "gui/$UID/$CLEANUP_LABEL" 2>/dev/null || true
    rm -f "$CLEANUP_PLIST" "$CLEANUP_HELPER" 2>/dev/null || true
    rm -f "$CLEANUP_BASE/last-gui-seen" "$CLEANUP_BASE/last-report" 2>/dev/null || true
    rm -rf "$CLEANUP_BASE/cleanup.lock" 2>/dev/null || true
    [ "$had" -eq 1 ] || return 1
    return 0
}

verify_no_cleanup_agent() {
    if cleanup_agent_present; then
        bad "the old background cleanup agent is still installed; it wakes every 30 s"
        say "        Remove it:  ./setup.sh --agent"
        return 1
    fi
    ok "no background agent -- nothing of ours runs unless you start it"
    return 0
}

if [ "$MODE" = agent ]; then
    say ""
    say "Removing the background cleanup agent"
    say ""
    if remove_cleanup_agent; then
        ok "removed -- nothing of this package runs in the background any more"
    else
        ok "there was none installed"
    fi
    say ""
    say "To clear leftovers now:  ./setup.sh --shutdown   (or double-click Stop.command)"
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

# Nothing may be inside the bottle while its registry is edited. Step 7 writes
# user.reg and system.reg (the DLL override, the proxy setting, the controller
# setting); a live Wine session keeps the registry in memory and writes it
# back out when it exits, so anything written now would be thrown away
# silently the next time CrossOver quits -- and the game would say the servers
# have been shut down with every check in --verify saying ok. See
# prefix_holders. The full install has always checked this; --bottle, and so
# --fifa15 on an existing copy, did not, and edited a live bottle under an
# open CrossOver.
require_bottle_free() {
    local -a holding
    holding=( ${(f)"$(prefix_holders)"} )
    holding=( ${holding:#} )
    [ "${#holding}" -gt 0 ] || return 0
    if [ -n "$(crossovers_running)" ]; then
        die $E_PERMISSION "The $BOTTLE bottle is open in CrossOver.
         Quit CrossOver completely -- Command-Q, not just closing the window --
         and run this again. Setting the bottle up now would leave its settings
         to be overwritten when CrossOver does quit, and the game would say the
         servers have been shut down. Nothing has been changed."
    fi
    if [ "$GAME" = fifa17 ] && hold_pid_alive; then
        die $E_PERMISSION "FIFA 17 is playing right now (started by --play-offline).
         Quit the game first, then run this again. Nothing has been changed."
    fi
    die $E_PERMISSION "${#holding} leftover process(es) are still inside the $BOTTLE bottle
         with no CrossOver running. They will overwrite whatever is written
         here, and the bottle will hang on loading. Free it first:
             ./setup.sh --unstick
         Nothing has been changed."
}

# The bottle steps boot the prefix themselves -- cxbottle's wineboot, the
# loader run that writes the licence file -- and leave that wineserver
# running. The user then opens CrossOver, which boots a second session on the
# same prefix: two rpcss.exe, a registry written twice, and "install, then
# play straight away" failing for every first-time user. With no CrossOver
# open, every CrossOver wineserver alive is this script's own or an orphan, so
# end them and let CrossOver start clean. --bottle has done this since
# 2026-09-02; the full install did not, and left the session it had started.
end_own_wine_session() {
    if [ -z "$(crossovers_running)" ] && [ -n "$(wineserver_pids)" ]; then
        shutdown_wineservers
        ok "ended the Wine session this script started, so CrossOver opens the bottle fresh"
    fi
}

# What has to be true of the Mac itself before anything is written into a
# CrossOver copy. Said once, here, so the install and --repair cannot disagree.
# Sets OSVER for the messages that quote it.
require_supported_mac() {
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
}

# One installer at a time. Two at once -- a .command double-clicked twice --
# would delete and copy the same app over each other. A lock left behind by a
# run that was killed names a pid that is gone, and is taken over.
SETUP_LOCK="${TMPDIR:-/tmp}/fifa-crossover-setup.lock"
take_setup_lock() {
    local other
    if ! mkdir "$SETUP_LOCK" 2>/dev/null; then
        other="$(cat "$SETUP_LOCK/pid" 2>/dev/null || true)"
        case "$other" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$other" 2>/dev/null \
                   && die $E_PERMISSION "Another copy of this installer is already running (pid $other).
         Let it finish, then run this again. Nothing has been changed." ;;
        esac
        rm -rf "$SETUP_LOCK" 2>/dev/null || true
        mkdir "$SETUP_LOCK" 2>/dev/null \
            || die $E_PERMISSION "Could not make the lock folder $SETUP_LOCK.
         Nothing has been changed."
    fi
    print -r -- "$$" > "$SETUP_LOCK/pid" 2>/dev/null || true
    # Not "trap ... EXIT": set inside a function, zsh runs that when the
    # FUNCTION returns, and the lock was gone before the copy began. zshexit
    # is zsh's hook for the shell itself ending, however it ends.
    zshexit() { rm -rf "$SETUP_LOCK" 2>/dev/null; }
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
    # The games and their Aurora programs, by name. Nearly always found above
    # already (they hold a server directory), but a game that has lost even
    # that -- FIFA 15 frozen at the flag, its connector gone -- still sits on
    # its bottle and on port 3216, and with no CrossOver open it is an orphan
    # by the rule above. Anything in a session a wineserver still owns stays.
    for P in ${(f)"$(game_leftovers)"}; do
        [ -n "$P" ] || continue
        [ "${LIVE[(I)${P}	*]}" -gt 0 ] && continue
        [ "${HOLDING[(I)$P]}" -gt 0 ] || HOLDING+=( "$P" )
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

    # Free any lingering network ports: Aurora17's 47170-47173 and
    # Aurora15Connector's 3216, the Origin stand-in FIFA 15 talks to. A second
    # connector fails with "Local port 3216 is in use" while the first one's
    # Aurora15Client.exe is still sitting on it.
    # A holder whose wineserver is still alive is a running session (the
    # connector started from a shell, say) and is left alone like the rest.
    # So is anything that is not a Wine process at all: a native Mac program
    # on one of these ports -- a local FUT server on 3216, say -- is the
    # user's own, and a SIGKILL could land mid-write on whatever it keeps.
    # Only Wine's own processes and wineserver are ever signalled here.
    local port_pids P C
    PORT_KILL=(); PORT_LIVE=(); PORT_OTHER=()
    for P in ${(f)"$(/usr/sbin/lsof -nP -iTCP:$ALL_PORTS -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)"}; do
        [ -n "$P" ] || continue
        C="$(ps -o command= -p "$P" 2>/dev/null)"
        if [ "${LIVE[(I)${P}	*]}" -gt 0 ]; then PORT_LIVE+=( "$P" )
        elif is_wine_command "$C"; then PORT_KILL+=( "$P" )
        else PORT_OTHER+=( "$P  ${C[1,70]}" )
        fi
    done
    if [ "${#PORT_LIVE}" -gt 0 ]; then
        say "  port holder(s) in a Wine session that is still running -- left alone: ${PORT_LIVE}"
    fi
    if [ "${#PORT_OTHER}" -gt 0 ]; then
        say "  port holder(s) that are not Wine processes -- left alone:"
        for C in ${PORT_OTHER}; do print -r -- "        $C"; done
    fi
    if [ "${#PORT_KILL}" -gt 0 ]; then
        kill -9 ${PORT_KILL} 2>/dev/null || true
        ok "freed the Aurora ports 47170-47173 and 3216 (terminated PID: ${PORT_KILL})"
    else
        ok "no lingering processes on the Aurora ports (47170-47173, 3216)"
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
    take_setup_lock
    require_bottle_free
    if [ "$F15_ONE" = 1 ]; then
        add_game_ntdll "$TARGET"
        f15_add_gdiplus "$TARGET"
        [ -d "$BOTTLE_DIR/$BOTTLE" ] || make_bottle "$TARGET"
    elif [ "$F16_ONE" = 1 ]; then
        # No gdiplus.dll: that is Aurora15Connector's, and FIFA 16 has none.
        add_game_ntdll "$TARGET"
        f16_add_win32u "$TARGET"
        [ -d "$BOTTLE_DIR/$BOTTLE" ] || make_bottle "$TARGET"
    fi
    if [ ! -d "$BOTTLE_DIR/$BOTTLE" ] && [ "$GAME" = fifa21 ]; then
        die $E_UNSUPPORTED "There is no bottle called '$BOTTLE' at
         $BOTTLE_DIR
         FIFA 21 plays from the Aurora launcher: make the bottle in CrossOver,
         run Aurora.exe in it once, quit CrossOver, then run this again. For
         another name:   AURORA_BOTTLE='name' ./setup.sh --fifa21"
    fi
    [ -d "$BOTTLE_DIR/$BOTTLE" ] \
        || die $E_UNSUPPORTED "There is no bottle called '$BOTTLE' at
         $BOTTLE_DIR
         Make it in CrossOver first, then run this again. For another
         name:   AURORA_BOTTLE='name' ./setup.sh --bottle"
    say ""
    say "Setting up the $BOTTLE bottle for ${TARGET:t}"
    configure_bottle "$TARGET"
    [ "$GAME" = fifa15 ] && f15_check_game
    [ "$GAME" = fifa16 ] && f16_check_game map
    [ "$GAME" = fifa21 ] && f21_check_game
    end_own_wine_session
    say ""
    if [ "$BOTTLE_OK" = 1 ] && [ "$PS_OK" = 1 ] && [ "$HOSTS_OK" = 1 ]; then
        remove_cleanup_agent && note "removed the old background cleanup agent; use Stop.command instead"
        if [ "$GAME" = fifa15 ]; then
            if [ "$(aurora_bottle_kind "$BOTTLE" 2>/dev/null || true)" = modern ]; then
                green "Done. Open ${TARGET:t:r}, pick the $BOTTLE bottle, and play FIFA 15"
                say "      from the Aurora launcher."
            else
                green "Done. Open ${TARGET:t:r}, then run Aurora15Connector in the $BOTTLE bottle (or"
                say "      fifa15.exe from the game folder, after  ./fifa15/fifa15-offline.sh apply)."
            fi
            say ""
            say "In Aurora15Connector, never press \"Repair connection\": under Wine it"
            say "kills its own Origin stand-in and the game then hangs at the flag."
            say "If a second connector says port 3216 is in use:  ./setup.sh --unstick"
        elif [ "$GAME" = fifa16 ]; then
            green "Done. Open ${TARGET:t:r}, pick the $BOTTLE bottle, choose Run Command and"
            say "      run ${F16_EXE_WIN:-fifa16.exe from your FIFA 16 folder}."
            say "      Tick the box that saves it as a launcher, and next time it is one"
            say "      click in the bottle."
        elif [ "$GAME" = fifa21 ]; then
            green "Done. Open ${TARGET:t:r}, then the Aurora launcher in the $BOTTLE bottle,"
            say "      and play FIFA 21 from it."
        else
            green "Done. Open ${TARGET:t:r}, then Aurora17Connector in the $BOTTLE bottle."
        fi
        say ""
        # Named, when it is not the game's own default: in a shared bottle
        # the plain command would check a different one.
        if [ "$GAME" = fifa15 ]; then
            say "To check:  ${AURORA_BOTTLE:+AURORA_BOTTLE='$BOTTLE' }./setup.sh --fifa15 --verify"
        elif [ "$GAME" = fifa16 ]; then
            say "To check:  ${AURORA_BOTTLE:+AURORA_BOTTLE='$BOTTLE' }./setup.sh --fifa16 --verify"
        elif [ "$GAME" = fifa21 ]; then
            say "To check:  ${AURORA_BOTTLE:+AURORA_BOTTLE='$BOTTLE' }./setup.sh --fifa21 --verify"
        else
            say "To check:  AURORA_BOTTLE='$BOTTLE' ./setup.sh --verify"
        fi
        say ""
        exit 0
    fi
    red "NOT FINISHED — see the lines above."
    say ""
    exit $E_INCOMPLETE
fi

# Replaces the EA licence file with whatever the game's own loader writes now.
#
# --verify, seed_bottle_licence and the stand-in's ensure_licence all test the
# same thing: does 1027460.dlf exist. None of them looks at what is in it. A
# bottle holding the wrong 1649-byte blob therefore passes every check while the
# game refuses to start from Aurora or from FIFA17.exe, and the only thing that
# has ever fixed it is running _fifa17.exe by hand. This is that, supported, and
# it prints both hashes so the answer is on the screen either way.
if [ "$MODE" = reseed-licence ]; then
    say ""
    say "Re-seeding the EA licence file"
    say ""
    [ -d "$TARGET" ] || die $E_INCOMPLETE "There is no $TARGET yet. Run ./setup.sh first."
    [ -d "$BOTTLE_DIR/$BOTTLE" ] \
        || die $E_UNSUPPORTED "There is no bottle called '$BOTTLE' at
         $BOTTLE_DIR
         For another name:  AURORA_BOTTLE='name' ./setup.sh --reseed-licence"
    if seed_bottle_licence "$TARGET" 1; then
        say ""
        ok "done — press PLAY, or double-click PLAY FIFA 17 offline.command"
        say ""
        exit 0
    fi
    say ""
    red "NOT DONE — see the lines above."
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

# Keeps the copies the folder gate needs (fix_fifa17_folders). Never changes
# the game's own files, and needs neither CrossOver quit nor the app.
if [ "$MODE" = fix-folder ]; then
    say ""
    say "Keeping copies of the FIFA 17 files launchers replace ($BOTTLE bottle)"
    say ""
    [ -d "$BOTTLE_DIR/$BOTTLE" ] \
        || die $E_UNSUPPORTED "There is no bottle called '$BOTTLE' at
         $BOTTLE_DIR
         For another name:  AURORA_BOTTLE='name' ./setup.sh --fix-folder"
    fix_fifa17_folders
    say ""
    exit 0
fi

# ------------------------------------------------------- --ensure-licence
# What the Start Menu shims call on every click (see guard_menu_shims). Quiet
# and always successful by design: it runs in front of someone's launch, with
# no terminal to print to, and a guard that could refuse to start the game
# would be worse than the bug it exists to prevent. Everything it needs may
# legitimately be absent -- no bottle yet, no patched CrossOver -- and in that
# case there is nothing to seed and nothing to say.
if [ "$MODE" = ensure-licence ]; then
    if [ ! -d "$TARGET" ] && [ "$TARGET_EXPLICIT" = 0 ] \
       && [ -d "$HOME/Applications/${TARGET:t}" ]; then
        TARGET="$HOME/Applications/${TARGET:t}"
    fi
    if [ -d "$BOTTLE_DIR/$BOTTLE" ] \
       && [ -x "$TARGET/Contents/SharedSupport/CrossOver/bin/wine" ]; then
        seed_bottle_licence "$TARGET" >/dev/null 2>&1 || true
    fi
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
    # The licence file, every time (BUGS.md §18). Step 9a puts it in the bottle
    # at install time, but the bottle outlives the install: remaking it in
    # CrossOver, or pointing AURORA_BOTTLE at a different one, leaves a bottle
    # that was never seeded and the game dies 0xFFFFFFFA about twenty seconds
    # in with nothing on screen. Aurora's PLAY has had its own guard for this
    # since §18 was closed (ensure_licence in aurora17/aurora-pwsh.c); this is
    # the same guard for the path that does not go through Aurora. It costs
    # nothing when the file is there -- seed_bottle_licence returns at once --
    # and about three seconds when it is not.
    # A second window would seed nothing, watch the first window's game, and
    # -- through the trap below -- kill it when closed. One session at a time.
    if hold_pid_alive; then
        die $E_INCOMPLETE "FIFA 17 is already running from another window (pid $(cat "$CLEANUP_HOLD" 2>/dev/null)).
         Play in that one, or quit it first. Nothing has been started."
    fi
    seed_bottle_licence "$TARGET" || true
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
    # not waiting for the game. Watch the bottle instead: FIFA 17 in THIS
    # bottle, by bottle_game_pids. game_leftovers matches every game and every
    # Aurora program by name, so with Aurora15Connector listening it said
    # "FIFA 17 is running" before the game existed and never saw it close.
    # The hold file below is what tells --unstick and --shutdown that a Wine
    # session with no CrossOver window is deliberate, so this script has to
    # stay up for as long as the game is.
    WAITED=0
    while [ "$WAITED" -lt 90 ] && [ -z "$(bottle_game_pids)" ]; do
        /bin/sleep 1
        WAITED=$((WAITED + 1))
    done
    if [ -z "$(bottle_game_pids)" ]; then
        wait "$WPID" 2>/dev/null || true
        say ""
        note "FIFA 17 did not appear within ${WAITED}s."
        say "        If it started and closed again, the bottle is probably missing"
        say "        its licence file: run  ./setup.sh --verify , which says so."
        exit $E_INCOMPLETE
    fi
    ok "FIFA 17 is running — leave this window open while you play"
    while [ -n "$(bottle_game_pids)" ]; do
        # Touching the hold keeps it obviously current for anyone reading it.
        print -r -- "$$" > "$CLEANUP_HOLD" 2>/dev/null || true
        /bin/sleep 5
    done
    wait "$WPID" 2>/dev/null || true
    say ""
    ok "FIFA 17 closed"
    exit 0
fi

# Starts Aurora17's launcher from here, through the patched copy, with
# CrossOver's own log turned on -- the same log its GUI makes with its log
# option, written to the diagnostics folder instead. Everything the launcher
# starts, the game included, inherits the log, so when the game dies on an
# unhandled exception Wine's "Unhandled exception code c0000005 ... addr" line
# and the +loaddll module map land in it, and crash_log_summary can say which
# module the address is in -- or that it is in none, which for this game means
# the protector's generated code. Aurora's own logs record only the exit code.
#
# Quiet by default: every trace channel off except loaddll and the err class
# of seh -- the two kinds of line that matter -- so the timing of the launch
# is as close to a normal PLAY as a log allows (BUGS.md 3 records a crash that
# tracing made disappear).
# AURORA_LOG_LEVEL=full keeps CrossOver's default channels (+seh traces every
# exception the protector raises; several MB a minute). AURORA_CTXLOG=1 adds
# the ntdll instrumentation's CTXAV line, which says whether the first access
# violation was in a module or in generated code even without a backtrace.
if [ "$MODE" = play-log ]; then
    say ""
    say "Starting Aurora17's launcher with CrossOver's log turned on"
    say ""
    [ -d "$TARGET" ] || die $E_INCOMPLETE "There is no $TARGET yet.
         Run  ./setup.sh  first (or double-click START HERE.command)."
    [ -d "$BOTTLE_DIR/$BOTTLE" ] \
        || die $E_UNSUPPORTED "There is no bottle called '$BOTTLE' at
         $BOTTLE_DIR
         For another name:  AURORA_BOTTLE='name' ./setup.sh --play-log"
    ADIR="$(aurora_dir_find 2>/dev/null || true)"
    [ -n "$ADIR" ] && ADIR="${ADIR:A}"
    [ -n "$ADIR" ] || die $E_INCOMPLETE "No Aurora17 folder with Aurora17Connector.exe in it was found.
         For one kept elsewhere:
           AURORA_DIR='/path/to/Aurora17' ./setup.sh --play-log"
    AWIN="$(unix_path_to_win "$ADIR" 2>/dev/null || true)"
    [ -n "$AWIN" ] || die $E_INCOMPLETE "The $BOTTLE bottle has no drive letter for
         $ADIR
         Add one in CrossOver (Bottle > Control Panel > Drives), then try again."
    PWINE="$TARGET/Contents/SharedSupport/CrossOver/bin/wine"
    [ -x "$PWINE" ] || die $E_PAYLOAD "$TARGET is incomplete (no wine inside it).
         Run ./setup.sh again."
    # Two launchers on one bottle fight over ports 47170-47173, and a launcher
    # started by the GUI writes no log. This one has to be the only one.
    [ -z "$(crossovers_running)" ] \
        || die $E_INCOMPLETE "CrossOver is open. Quit it with Cmd-Q (or double-click Stop.command),
         wait for it to go, then run this again. The launcher has to be started
         from here for its log to be written."
    [ -z "$(game_leftovers fifa17)" ] \
        || die $E_INCOMPLETE "Aurora17 or FIFA 17 is still running. Double-click Stop.command,
         wait for it to finish, then run this again."
    if hold_pid_alive; then
        die $E_INCOMPLETE "FIFA 17 is already running from another window (pid $(cat "$CLEANUP_HOLD" 2>/dev/null)).
         Quit it first, then run this again. Nothing has been started."
    fi
    LOGDIR="$(crash_log_dir)"
    mkdir -p "$LOGDIR" 2>/dev/null \
        || die $E_PERMISSION "Could not make $LOGDIR to write the log into."
    LOG="$LOGDIR/play-$(date '+%Y%m%d-%H%M%S').cxlog"
    # CrossOver's wrapper prepends its own defaults (+seh,+unwind,+process,
    # +module,+loaddll,+threadname) and Wine applies per-channel entries on top
    # of them, so "-all" cannot switch a channel the wrapper named back off;
    # each one has to be cleared by name. loaddll is the one default kept.
    CHAN="-seh,err+seh,-unwind,-process,-module,-threadname"
    case "${AURORA_LOG_LEVEL:-}" in
        full) CHAN="-unwind,-module,-process" ;;
    esac
    [ "${AURORA_CTXLOG:-0}" = 1 ] && export CX_CTXLOG=1
    # One line per name the bottle resolves, from a17hosts.dylib into this same
    # log. The crash so far dies after the main menu and before the game's first
    # connection to Aurora; whether it got as far as asking for
    # gosredirector.ea.com is the question, and this is the only thing that
    # answers it. A few dozen lines per launch.
    export AURORA17_HOSTS_DEBUG=1
    mkdir -p "$CLEANUP_BASE" 2>/dev/null || true
    print -r -- "$$" > "$CLEANUP_HOLD" 2>/dev/null || true
    trap 'rm -f "$CLEANUP_HOLD" 2>/dev/null' EXIT INT TERM
    ok "Aurora17:    $ADIR"
    ok "bottle:      $BOTTLE"
    ok "log:         $LOG"
    ok "channels:    $CHAN${CX_CTXLOG:+  (+ CX_CTXLOG=1)}, plus every name looked up"
    say ""
    say "The Aurora17 launcher opens in a moment. Press PLAY in it and play until"
    say "the game crashes or you quit. If a box about a program error appears,"
    say "click Close. Then close the launcher window; this prints what the log"
    say "says as soon as it has gone. Aurora's server stays up afterwards, as it"
    say "does after a normal session: double-click Stop.command when you are done."
    say ""
    # Wait for the launcher itself (the wrapper's default). --wait-children
    # would wait for Aurora's server, which outlives every session on purpose.
    "$PWINE" --bottle "$BOTTLE" --workdir "$ADIR" --cx-log "$LOG" --debugmsg "$CHAN" \
        --cx-app "$AWIN\\Aurora17Connector.exe" || true
    # The launcher may exit before its children finish writing: let the game
    # go if it is still going, so the exception lines are complete.
    WAITED=0
    while [ "$WAITED" -lt 20 ] && [ -n "$(bottle_game_pids)" ]; do
        /bin/sleep 1
        WAITED=$((WAITED + 1))
    done
    say ""
    if [ ! -s "$LOG" ]; then
        note "no log was written to $LOG"
        say "        CrossOver wrote nothing at all, which means the launcher never started."
        exit $E_INCOMPLETE
    fi
    say "What the log says"
    say ""
    crash_log_summary "$LOG" | tee "$LOG.summary.txt" | sed 's/^/  /'
    say ""
    ok "log kept at $LOG"
    say "        Now double-click '1 Collect diagnostics.command' (or ./setup.sh --bundle):"
    say "        the zip picks this log up, with the summary above."
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
    # No game named: every game in the bottle first, then FIFA 17's own
    # checks as always. Those decide the exit code, as they always have, so
    # --repair, setup-both.sh and anyone scripting this see no change.
    if [ "$GAME_EXPLICIT" = 0 ]; then
        verify_games_table "$TARGET"
        say ""
        say "FIFA 17 in detail (--fifa15 --verify, --fifa16 --verify and --fifa21 --verify do the others)"
    fi
    verify_install "$TARGET" || exit $E_INCOMPLETE
    exit 0
fi

# Replaces whatever in a CrossOver-FIFA copy is not the shipped fix, then
# redoes the search path and the signature. The full installer does the same
# three steps on a fresh 1 GB copy; this does them on the copy that is there,
# which is what an update needs: the launcher fixes (ole32.dll, win32u.so)
# were added in September 2026, and an install from before has neither, and
# until now only the full re-copy could put them in. The order is the one
# --resign refuses on purpose: files first, signature last, so the signature
# can never bless the wrong file.
refresh_fixes() {
    local app="$1" wine="$1/Contents/SharedSupport/CrossOver/lib/wine" f so mode="" RPATH_ERR
    local -a stale
    stale=()
    if ! ( cd "$HERE/fixes" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1; then
        die $E_PAYLOAD "fixes/ does not match its own checksums.
         This copy of the package is damaged, so there is nothing safe to
         install from it. Download it again."
    fi
    # Missing, or not the shipped file. The .dll files are installed unchanged
    # and compare byte for byte; the .so files are rpath-edited and signed after
    # installation, so LC_UUID identifies them (see verify_install).
    for f in $FILES; do
        if [ ! -f "$wine/$f" ]; then stale+=( "$f" ); continue; fi
        case "$f" in
        *.dll) cmp -s "$HERE/fixes/$f" "$wine/$f" || stale+=( "$f" ) ;;
        *.so)  [ "$(macho_uuid "$wine/$f")" = "$(macho_uuid "$HERE/fixes/$f")" ] || stale+=( "$f" ) ;;
        esac
    done
    # An in-place install (AURORA_IN_PLACE=1) keeps CrossOver's own file as
    # .orig so uninstall can put it back. A file replaced here for the first
    # time needs that backup too, or uninstall would have nothing to restore.
    [ -f "$RECEIPT" ] && mode="$(sed -n 's/^mode=//p' "$RECEIPT" 2>/dev/null | head -1)"
    for f in $stale; do
        if [ "$mode" = in-place ] && [ -f "$wine/$f" ] && [ ! -f "$wine/$f.orig" ]; then
            cp "$wine/$f" "$wine/$f.orig" \
                || die $E_PERMISSION "Could not back up $f.
$APP_MGMT_HINT"
        fi
        cp -X "$HERE/fixes/$f" "$wine/$f" \
            || die $E_PERMISSION "Could not install $f into $app.
$APP_MGMT_HINT"
        ok "${f:t} — replaced"
    done
    if [ "${#stale}" -eq 0 ]; then
        ok "all ${#FILES} fix files are the shipped versions"
    fi
    # The resolver and the ws2_32.so edit, as the installer and --resign do them.
    if [ ! -f "$wine/$RESOLVER" ] || ! cmp -s "$HERE/fixes/$RESOLVER" "$wine/$RESOLVER"; then
        cp -X "$HERE/fixes/$RESOLVER" "$wine/$RESOLVER" \
            || die $E_PERMISSION "Could not install ${RESOLVER:t} into $app.
$APP_MGMT_HINT"
        stale+=( "$RESOLVER" )
        ok "${RESOLVER:t} — replaced"
    else
        ok "${RESOLVER:t}"
    fi
    # The folder gate's script, added beside ntdll.so the same way. Not
    # Mach-O, but inside the app, so a changed one needs the app re-signed.
    if [ ! -f "$wine/$GATE" ] || ! cmp -s "$HERE/fixes/$GATE" "$wine/$GATE"; then
        cp -X "$HERE/fixes/$GATE" "$wine/$GATE" \
            || die $E_PERMISSION "Could not install ${GATE:t} into $app.
$APP_MGMT_HINT"
        chmod 755 "$wine/$GATE" 2>/dev/null || true
        stale+=( "$GATE" )
        ok "${GATE:t} — replaced"
    else
        ok "${GATE:t}"
    fi
    if ws2_32_is_patched "$wine"; then
        ok "ws2_32.so — reads the bottle's hosts file"
    else
        install_name_tool -change "$LIBSYSTEM" "$RESOLVER_PATH" "$wine/x86_64-unix/ws2_32.so" 2>/dev/null \
            || die $E_PERMISSION "Could not point ws2_32.so at ${RESOLVER:t}.
$APP_MGMT_HINT"
        ws2_32_is_patched "$wine" \
            || die $E_PAYLOAD "ws2_32.so did not take the change. Nothing will
         resolve to Aurora17 and the game will not connect."
        stale+=( x86_64-unix/ws2_32.so )
        ok "ws2_32.so — now reads the bottle's hosts file"
    fi
    # The search path: a freshly copied .so has lost it (step 5 of the install).
    for so in ntdll.so crypt32.so win32u.so; do
        if has_lib64_rpath "$wine/x86_64-unix/$so"; then
            ok "$so search path"
        elif RPATH_ERR="$(install_name_tool -add_rpath "$RPATH_LIB64" "$wine/x86_64-unix/$so" 2>&1)"; then
            stale+=( "x86_64-unix/$so" )
            ok "$so search path — added"
        elif print -r -- "$RPATH_ERR" | grep -q 'would duplicate path'; then
            ok "$so search path"
        else
            print -r -- "$RPATH_ERR"
            die $E_PERMISSION "Could not repair the search path in $so.
$APP_MGMT_HINT"
        fi
    done
    # Signing is redone when anything above changed, or when the signature does
    # not verify as it is (macOS says the app is damaged). A copy that is right
    # and signed is left alone: signing is the step that needs App Management.
    if [ "${#stale}" -ne 0 ] || ! codesign --verify --deep --strict "$app" 2>/dev/null; then
        sign_payload "$wine"
        resign_app "$app"
    else
        ok "signature verifies, so it was left as it is"
    fi
    return 0
}

# FIFA 15 launched by Aurora.exe needs its overrides in this same bottle.
# Repair only a game whose folder is found here; a child failure is reported
# while the remaining FIFA 17 repairs and checks still run.
REPAIR_FIFA15_OK=1
repair_fifa15() {
    local folder
    [ "$(aurora_bottle_kind "$BOTTLE" 2>/dev/null || true)" = modern ] || return 0
    if ! folder="$(game_dir_of fifa15 2>/dev/null)"; then
        note "FIFA 15: no game folder found, so its setup was skipped"
        return 0
    fi
    say ""
    say "        FIFA 15 in the $BOTTLE bottle ($folder)"
    if AURORA_BOTTLE="$BOTTLE" "$HERE/setup.sh" --fifa15 \
       && AURORA_BOTTLE="$BOTTLE" "$HERE/setup.sh" --fifa15 --verify; then
        ok "FIFA 15: set up and checked in the $BOTTLE bottle"
    else
        REPAIR_FIFA15_OK=0
        note "FIFA 15: not finished; continuing with FIFA 17's repairs"
    fi
    return 0
}

# ------------------------------------------------------------- --repair
# Puts an install that once worked right again, on this Mac or on one the
# folder was carried to, without copying CrossOver again. It is the repairs
# this script already has, in the order they depend on each other:
#
#   1. --shutdown     games and Aurora first, then every wineserver, then the
#                     CrossOver GUI. A session that is still up keeps serving
#                     the DLLs it loaded and writes the registry back on exit,
#                     so nothing below is safe while one is running.
#   2. the copy       refresh_fixes: every fix file that is missing from the
#                     CrossOver-FIFA copy or is not the shipped one is replaced,
#                     the search path and the signature are redone.
#   3. --bottle       settings, the version and C runtime overrides, hosts, the
#                     menu entries, the PowerShell stand-in, a licence file if
#                     there is none, the WebView2 runtime the RebornFUT
#                     launcher's window needs (a 165 MB download, once), and
#                     the CAS launcher's device check and cas:// handler.
#                     Then FIFA 15's setup and verification in the same bottle,
#                     when Aurora.exe and a FIFA 15 folder are found there.
#   4. the licence    the game's own loader writes a fresh one over whatever
#                     is there. A file that exists but is wrong passes every
#                     other check while the game relaunches itself with no
#                     window until it quits (SETUP.md, 0xFFFFFFFA) -- and the
#                     RebornFUT launcher only says "running" while that happens.
#                     Then --unstick, because the loader's session leaves
#                     orphans in the bottle that would fail the check below.
#   5. --verify       the same check as always, so the last word is the one
#                     people already know how to read.
#
# Steps 1, 3 and 5 are this script run again with that flag, so their checks,
# messages and exit codes are exactly the ones documented for each. This
# process holds the installer lock only while it edits the copy itself.
if [ "$MODE" = repair ]; then
    if [ ! -d "$TARGET" ] && [ "$TARGET_EXPLICIT" = 0 ] \
       && [ -d "$HOME/Applications/${TARGET:t}" ]; then
        TARGET="$HOME/Applications/${TARGET:t}"
    fi
    say ""
    say "Fixing the FIFA 17 install"
    say ""
    require_supported_mac
    [ -d "$TARGET" ] || die $E_PAYLOAD "No patched CrossOver at $TARGET, so there is nothing to fix yet.
         Run ./setup.sh (or double-click 'START HERE.command') to install.
         If the copy is somewhere else:
             AURORA_TARGET=/path/to/CrossOver-FIFA.app ./setup.sh --repair"
    is_crossover_bundle "$TARGET" \
        || die $E_PAYLOAD "$TARGET is not a CrossOver bundle. Refusing to touch it.
         If the copy is somewhere else:
             AURORA_TARGET=/path/to/CrossOver-FIFA.app ./setup.sh --repair"
    REPAIR_VER="$(crossover_version "$TARGET")"
    [ "$REPAIR_VER" = "26.3" ] || die $E_PAYLOAD "These fixes are built for CrossOver 26.3 exactly; ${TARGET:t} is $REPAIR_VER.
         Putting 26.3 files into it would not work. Install CrossOver 26.3 and
         run ./setup.sh again, or rebuild the files: see patches/README."
    require_clt
    ok "CrossOver $REPAIR_VER at $TARGET"
    # The steps run as their own ./setup.sh see the same copy and bottle.
    export AURORA_TARGET="$TARGET" AURORA_BOTTLE="$BOTTLE"

    say ""
    say "1 of 5. Quitting CrossOver cleanly"
    "$HERE/setup.sh" --shutdown || exit $?

    say ""
    say "2 of 5. The fix files in ${TARGET:t}"
    take_setup_lock
    refresh_fixes "$TARGET"
    rm -rf "$SETUP_LOCK" 2>/dev/null || true
    zshexit() { :; }

    say ""
    say "3 of 5. The $BOTTLE bottle"
    REPAIR_HAD_LICENCE=0
    [ -f "$(bottle_licence_file)" ] && REPAIR_HAD_LICENCE=1
    "$HERE/setup.sh" --bottle || exit $?
    repair_fifa15

    say ""
    say "4 of 5. The licence file"
    if [ "$REPAIR_HAD_LICENCE" = 1 ]; then
        if ! seed_bottle_licence "$TARGET" 1; then
            note "the licence file could not be re-made; the check below says whether"
            say "        the one that is there still counts"
        fi
    elif [ -f "$(bottle_licence_file)" ]; then
        ok "written fresh by step 3, so there is nothing to replace"
    else
        note "step 3 could not write it (no FIFA 17 folder with _fifa17.exe was found)."
        say "        The check below names it. AURORA_GAME_DIR='/path/to/FIFA 17'"
        say "        tells this where the game is."
    fi
    # The loader run leaves a Wine session behind: its wineserver goes when
    # asked, but services.exe, rpcss.exe, explorer.exe and friends outlive it
    # as orphans inside the bottle, and --verify (rightly) calls a bottle with
    # orphans in it BAD. --unstick is the documented cure, and with CrossOver
    # already quit by step 1 it clears exactly those and nothing else.
    say ""
    say "        clearing the session the loader left behind"
    "$HERE/setup.sh" --unstick >/dev/null 2>&1 || "$HERE/setup.sh" --unstick || exit $?

    say ""
    say "5 of 5. Checking"
    if "$HERE/setup.sh" --verify && [ "$REPAIR_FIFA15_OK" = 1 ]; then
        say ""
        green "Fixed. Open ${TARGET:t:r}, then the $BOTTLE bottle, and press PLAY."
        say ""
        exit 0
    fi
    say ""
    if [ "$REPAIR_FIFA15_OK" != 1 ]; then
        red "NOT FIXED — FIFA 15's setup or check failed in the $BOTTLE bottle."
        say "To check it:  AURORA_BOTTLE=${(qq)BOTTLE} ./setup.sh --fifa15 --verify"
    else
        red "NOT FIXED — the check above names what is still wrong."
    fi
    say "If it is something this cannot change (a game folder that moved, a"
    say "bottle that does not exist), put that right and run this again."
    say ""
    exit $E_INCOMPLETE
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
    # what SETUP.md sends people to when something is missing. A resolver that
    # is there but is not the shipped one (a debug build left from a hunt, an
    # older package) is replaced the same way: --bottle never touches the app,
    # so until now only a full 1 GB re-copy could clear "a17hosts.dylib is not
    # the shipped version" from --verify.
    RESIGN_WINE="$TARGET/Contents/SharedSupport/CrossOver/lib/wine"
    if [ ! -f "$RESIGN_WINE/$RESOLVER" ]; then
        cp -X "$HERE/fixes/$RESOLVER" "$RESIGN_WINE/$RESOLVER" \
            || die $E_PERMISSION "Could not install ${RESOLVER:t} into $TARGET.
$APP_MGMT_HINT"
        ok "added ${RESOLVER:t}"
    elif ! cmp -s "$HERE/fixes/$RESOLVER" "$RESIGN_WINE/$RESOLVER"; then
        cp -X "$HERE/fixes/$RESOLVER" "$RESIGN_WINE/$RESOLVER" \
            || die $E_PERMISSION "Could not replace ${RESOLVER:t} in $TARGET.
$APP_MGMT_HINT"
        ok "replaced ${RESOLVER:t} with the shipped version"
    fi
    # The folder gate's script, the same way: signing seals it with the app.
    if [ ! -f "$RESIGN_WINE/$GATE" ] || ! cmp -s "$HERE/fixes/$GATE" "$RESIGN_WINE/$GATE"; then
        cp -X "$HERE/fixes/$GATE" "$RESIGN_WINE/$GATE" \
            || die $E_PERMISSION "Could not install ${GATE:t} into $TARGET.
$APP_MGMT_HINT"
        chmod 755 "$RESIGN_WINE/$GATE" 2>/dev/null || true
        ok "put in the shipped ${GATE:t}"
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
take_setup_lock

require_supported_mac
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
ok "all ${#FILES} replacement files present in CrossOver, and the ws2_32.so we edit"

# Keeping CrossOver's own permissions is the one step with nothing to fall back
# on, and it runs at the very end -- after 2 GB has been copied and nine files
# replaced. Read them from the original now, while nothing has happened yet, so
# a CrossOver that cannot supply them stops here instead of there.
PRE_ENT="$(mktemp -t cxpre)"
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
# A checksum only says the files are the ones SHA256SUMS names, not that they
# are the build this game needs. An older package's ntdll.so matches its own
# sums and has no FIFA 16 fix in it, and FIFA 16 would install "done" and then
# never get past its start screen. The same test add_game_ntdll makes.
if [ "$GAME" = fifa16 ] \
   && ! strings -a "$HERE/fixes/x86_64-unix/ntdll.so" 2>/dev/null | grep -q "$NTDLL_MARKER"; then
    die $E_PAYLOAD "fixes/ntdll.so is a build without the FIFA 16 patch.
         Download the complete main-branch package again. FIFA 16 cannot run with this file."
fi

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

# Step 7 edits the bottle's registry, which a live session would overwrite on
# its way out. See require_bottle_free.
require_bottle_free

# ------------------------------------------- the bottle has to exist first
# The bottle is CrossOver's to make, and the launcher inside it is what a
# player actually presses. Neither can be done from here: New Bottle is a
# CrossOver step, and the launcher has to be saved from its Run Command
# dialog, pointed at the Aurora17 folder we cannot guess.
#
# Checked before anything is written, because everything after this point goes
# into a bottle -- step 7's settings, step 8's stand-in, step 9's EA names.
# Without one the installer used to copy a gigabyte, note the missing bottle in
# passing at step 7, and finish "done" with nothing that plays.
#
# An offline install, --fifa15 and --fifa16 need no launcher in the bottle, so
# they make it themselves with cxbottle -- after the copy exists, since it is
# the copy's cxbottle that makes it. That needs CrossOver closed: an open one
# lists the bottles it found when it started and puts the new one's registry
# back its own way on quit. So it is checked here, before a gigabyte is copied, rather
# than in make_bottle afterwards. --fifa21 needs the Aurora launcher in the
# bottle, so like a plain install it stops, and says how to make it.
MAKE_BOTTLE=0
if [ ! -f "$BOTTLE_DIR/$BOTTLE/cxbottle.conf" ] && { [ "$F15_ONE" = 1 ] || [ "$F16_ONE" = 1 ] || [ "$NO_AURORA" = 1 ]; }; then
    [ ! -e "$BOTTLE_DIR/$BOTTLE" ] \
        || die $E_UNSUPPORTED "There is a '$BOTTLE' folder in $BOTTLE_DIR, but it is not a
         finished bottle (no cxbottle.conf in it). Move it out of the way, or
         make the bottle in CrossOver (+ > Windows 10 64-bit, named exactly
         $BOTTLE) and quit CrossOver. Then run this again.
         Nothing has been changed."
    RUNNING="$(crossovers_running)"
    if [ -n "$RUNNING" ]; then
        say "  CrossOver is open:"
        print -r -- "$RUNNING" | sed 's/^/        /'
        die $E_PERMISSION "The $BOTTLE bottle has to be made while CrossOver is closed.
         Quit it completely -- Command-Q, not just closing the window -- and
         run this again. Nothing has been changed."
    fi
    MAKE_BOTTLE=1
    ok "no $BOTTLE bottle yet -- it will be made once the copy exists"
elif [ ! -f "$BOTTLE_DIR/$BOTTLE/cxbottle.conf" ] && [ "$GAME" = fifa21 ]; then
    die $E_UNSUPPORTED "There is no bottle called '$BOTTLE' yet.
         FIFA 21 plays from the Aurora launcher: make the bottle in CrossOver
         (+ > Windows 10 64-bit, named exactly $BOTTLE), run Aurora.exe in it
         once, quit CrossOver completely (Command-Q), then run this again.
         Already using another name?   AURORA_BOTTLE='name' ./setup.sh --fifa21
         Nothing has been changed."
elif [ ! -f "$BOTTLE_DIR/$BOTTLE/cxbottle.conf" ]; then
    die $E_UNSUPPORTED "There is no bottle called '$BOTTLE' yet.
         Make it first, in CrossOver, along with the Aurora17 launcher:
           1. Open CrossOver and press + (New Bottle).
           2. Choose Windows 10 64-bit and name it exactly:  $BOTTLE
           3. With that bottle selected, choose Run Command and browse to
              Aurora17Connector.exe in your Aurora17 folder. Tick the box
              that saves it as a launcher and give it a name.
           4. Quit CrossOver completely (Command-Q).
         Then run this again. SETUP.md, \"Setting up the bottle\", walks
         through it field by field.
         Already using another name?   AURORA_BOTTLE='name' ./setup.sh
         No Aurora17, single player only?   ./setup.sh --offline
         Nothing has been changed."
fi

# =========================================================================
# From here on things change on disk.
# =========================================================================
say ""
if [ "$IN_PLACE" = "1" ]; then
    say "2. Using your real CrossOver (AURORA_IN_PLACE=1)"
    say "        This changes every bottle you run in CrossOver, not just FIFA."
    say "        ./uninstall.sh puts the nine files back, but it cannot restore"
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
# deleting the whole copy, so writing .orig files into it would be nine pointless
# writes and nine more things to go wrong.
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
# The FIFA 17 folder gate's script, beside ntdll.so, which runs it.
cp -X "$HERE/fixes/$GATE" "$WINE/$GATE" \
    || die $E_PERMISSION "Could not install ${GATE:t} into $APP.
$APP_MGMT_HINT"
chmod 755 "$WINE/$GATE" 2>/dev/null || true
ok "${GATE:t}"
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
# All three rebuilt .so files lose it, and all three need it: ntdll.so to find
# its sibling libraries, crypt32.so to find the gnutls CrossOver already ships
# in lib64, win32u.so to find libMoltenVK.dylib and libfreetype.dylib there.
# Without it CrossOver silently falls back to a graphics path that does not work
# on macOS, and the game hangs on the loading screen forever.
say ""
say "5. Repairing the library search path"
for so in ntdll.so crypt32.so win32u.so; do
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

if [ "$MAKE_BOTTLE" = 1 ]; then
    make_bottle "$APP"
fi
configure_bottle "$APP"
[ "$GAME" = fifa15 ] && f15_check_game
[ "$GAME" = fifa16 ] && f16_check_game map
[ "$GAME" = fifa21 ] && f21_check_game
end_own_wine_session

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
    elif [ "$GAME" = fifa15 ]; then
        say "To play:  open ${TARGET:t:r}  (not your normal CrossOver), pick the"
        if [ "$(aurora_bottle_kind "$BOTTLE" 2>/dev/null || true)" = modern ]; then
            say "          $BOTTLE bottle and play FIFA 15 from the Aurora launcher."
        else
            say "          $BOTTLE bottle and run Aurora15Connector, or fifa15.exe from the"
            say "          game folder after fifa15-offline.sh apply (SETUP.md, FIFA 15)."
        fi
        say "          In the connector never press \"Repair connection\": under Wine it"
        say "          kills its own Origin stand-in and the game hangs at the flag."
        say "          Port 3216 in use afterwards?  ./setup.sh --unstick"
    elif [ "$GAME" = fifa16 ]; then
        say "To play:  open ${TARGET:t:r}  (not your normal CrossOver), pick the"
        say "          $BOTTLE bottle, choose Run Command and run"
        say "          ${F16_EXE_WIN:-fifa16.exe from your FIFA 16 folder}."
        say "          Tick the box that saves it as a launcher, and next time it is"
        say "          one click in the bottle. No launcher program is involved: the"
        say "          game runs on its own (SETUP.md, FIFA 16)."
    elif [ "$GAME" = fifa21 ]; then
        say "To play:  open ${TARGET:t:r}  (not your normal CrossOver), pick the"
        say "          $BOTTLE bottle, run the Aurora launcher and play FIFA 21 from it"
        say "          (SETUP.md, 9d)."
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
    remove_cleanup_agent && note "removed the old background cleanup agent; use Stop.command instead"
    say ""
    say "To quit when you stop playing:    double-click Stop.command"
    say "                                  (or ./setup.sh --shutdown -- closing"
    say "                                  CrossOver's window leaves FIFA and Aurora"
    say "                                  running and the ports held)"
    say "To check an install at any time:  ./setup.sh --verify"
    say "If anything goes wrong:           double-click Diagnostics.command, or run"
    say "                                  ./setup.sh --bundle, then send the zip it"
    say "                                  writes into the diagnostics folder. Every"
    say "                                  other check and repair is a double-click in"
    say "                                  that folder: see diagnostics/README.md."
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
