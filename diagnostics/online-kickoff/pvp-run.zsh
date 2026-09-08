#!/bin/zsh
# One instrumented PvP run: launcher + game under CrossOver's own log
# (+winsock,+iphlpapi), a socket/process sampler, an optional packet capture,
# and a timestamped notes file. Everything lands in one private run folder.
#
#   ./pvp-run.zsh session [--game fifa17|fifa15] [--label NAME] [--no-capture]
#       start, wait for you to play, stop. Type a note + Return at any moment
#       (e.g. "kickoff", "popup: Connection lost") and it is timestamped.
#       Empty line = stop and collect.
#   ./pvp-run.zsh start   [same options]     start only (backgrounds)
#       --relay: Wine relay trace instead of the winsock channels (startup
#       failures only; heavy; honours RelayFromExclude/RelayExclude in the
#       bottle's HKCU\Software\Wine\Debug). Implies --no-capture.
#   ./pvp-run.zsh stop                       stop the current run and collect
#   ./pvp-run.zsh mark "text"                timestamp a note into the current run
#   ./pvp-run.zsh status
#   ./pvp-run.zsh summary [RUN_DIR]          re-print the summary of a run
#
# Nothing here changes the bottle, the game folder, hosts, the VPN or the
# firewall. The run folder can hold private data (endpoint addresses, account
# names); credentials and tokens are redacted from the copies it makes.

if [ -z "${ZSH_VERSION:-}" ]; then
    exec /bin/zsh "$0" "$@"
fi
set -u
umask 077

HERE="${0:A:h}"
REPO="${HERE:h:h}"
RUNS="$HERE/runs"
CURRENT="$RUNS/.current"
APP='/Applications/CrossOver-FIFA.app'
WINE="$APP/Contents/SharedSupport/CrossOver/bin/wine"
BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
LAUNCHER17="$HOME/Downloads/Reborn17-3.1.15.exe"
GAMEDIR17="$HOME/Downloads/FIFA 17"
CHANNELS='-seh,err+seh,-unwind,+process,-module,-threadname,+loaddll,+timestamp,+pid,+winsock,+iphlpapi'

now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
say() { print -r -- "$@"; }
die() { print -r -- "pvp-run: $*" >&2; exit 2; }

redact() {
    # credentials / tokens out of any copied text
    sed -E \
        -e 's/^(Username|Password|password|token|access_token)[[:space:]]*=.*/\1=<redacted>/' \
        -e 's/(access_token|token|password|session_id|sid)=[^&[:space:]"]+/\1=<redacted>/g' \
        -e 's/(rb17|RB17)[A-Za-z0-9]{8,}/\1<redacted>/g' \
        -e 's/("(access_token|token|password|sid|session)"[[:space:]]*:[[:space:]]*")[^"]*"/\1<redacted>"/g'
}

vpn_line() {
    local ifc srv
    ifc=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    srv=$(defaults read ch.protonvpn.mac ConnectedServerNameDoNotUse 2>/dev/null)
    if pgrep -qx ProtonVPN 2>/dev/null; then
        if [[ "$ifc" == utun* ]]; then
            say "VPN: ON  default route via $ifc  (ProtonVPN, last server: ${srv:-?})"
        else
            say "VPN: app running but default route via ${ifc:-?} (tunnel down)"
        fi
    else
        say "VPN: OFF (ProtonVPN not running)  default route via ${ifc:-?}"
    fi
}

identity() {
    # $1 = game, $2 = out file
    local game="$1" out="$2"
    {
        say "captured: $(now)"
        say "game: $game"
        say "macOS: $(sw_vers -productVersion 2>/dev/null)  $(uname -m)"
        say "CrossOver: $(defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null)"
        say
        vpn_line
        say "public ip (default route): $(curl -sS -m 6 https://api.ipify.org 2>/dev/null || say '?')"
        say "public ip (en0 direct):    $(curl -sS -m 6 --interface en0 https://api.ipify.org 2>/dev/null || say '?')"
        say "interfaces:"; ifconfig | grep -E '^[a-z0-9]+:|inet ' | grep -B1 'inet ' | grep -v '^--' | sed 's/^/  /'
        say "DNS: $(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3}' | sort -u | tr '\n' ' ')"
        say
        say "macOS firewall: $(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)"
        /usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null | grep -A1 -iE 'crossover|wine|fifa' | sed 's/^/  /'
        say
        if [[ "$game" == fifa17 ]]; then
            say "launcher: $LAUNCHER17"
            shasum -a 256 "$LAUNCHER17" 2>/dev/null
            say "game folder: $GAMEDIR17"
            ( cd "$GAMEDIR17" && shasum -a 256 FIFA17.exe version.dll CardsDLL_Win64_retail.dll 2>/dev/null )
            say "-- crumpet.ini (redacted)"; redact < "$GAMEDIR17/crumpet.ini" 2>/dev/null
            say "-- aurora17-redirect.ini present: $([ -f "$GAMEDIR17/aurora17-redirect.ini" ] && say yes || say no)"
            local rb="$BOTTLES/Aurora17/drive_c/users/crossover/AppData/Local/Reborn17"
            say "-- client.ini (redacted)"; redact < "$rb/client.ini" 2>/dev/null
            say "-- game-profile.json"; grep -E '"(profileVersion|minimumLauncherVersion|name|sha256|supersedes)"' "$rb/game-profile/game-profile.json" 2>/dev/null | sed 's/^/  /'
            say "-- bottle hosts"; grep -v '^#' "$BOTTLES/Aurora17/drive_c/windows/system32/drivers/etc/hosts" 2>/dev/null | sed 's/^/  /'
            say "-- version.dll override: $(grep -E '^"version"=' "$BOTTLES/Aurora17/user.reg" 2>/dev/null)"
            say "-- C runtime overrides (native = Microsoft DLLs from the game folder; none listed = Wine built-ins):"
            "$WINE" --bottle Aurora17 --wait-children reg query 'HKCU\Software\Wine\DllOverrides' 2>/dev/null | grep -iE '^ *(msvcr1|msvcp1|vcruntime|concrt|ucrtbase)' | sed 's/^ */  /'
        else
            local c="$BOTTLES/Aurora15/drive_c/users/crossover/AppData/Local/Aurora15Connector/Aurora15Connector.exe"
            say "launcher: $c"; shasum -a 256 "$c" 2>/dev/null
            ( cd "$HOME/Downloads/FIFA 15" && shasum -a 256 fifa15.exe ItsAMe_Origin.dll dinput8.dll 2>/dev/null )
            say "-- bottle hosts"; grep -v '^#' "$BOTTLES/Aurora15/drive_c/windows/system32/drivers/etc/hosts" 2>/dev/null | sed 's/^/  /'
        fi
    } > "$out" 2>&1
}

sampler() {
    # $1 = run dir. Every 2 s: sockets of wine/game processes. Every 10 s: processes.
    local run="$1" n=0
    while :; do
        {
            say "=== $(now)"
            /usr/sbin/lsof +c 0 -nP -iUDP -iTCP 2>/dev/null | grep -iE 'wine|fifa|aurora|reborn|crossover|\.exe'
        } >> "$run/sockets.log"
        if (( n % 5 == 0 )); then
            {
                say "=== $(now)"
                ps -axo pid,ppid,etime,rss,comm | grep -iE 'wine|fifa|aurora|reborn|crossover|\.exe' | grep -v grep
            } >> "$run/procs.log"
        fi
        (( n++ ))
        sleep 2
    done
}

cmd_mark() {
    [ -f "$CURRENT" ] || die "no current run"
    local run; run=$(<"$CURRENT")
    say "$(now)  $*" >> "$run/marks.txt"
    say "marked: $(now)  $*"
}

cmd_start() {
    local game=fifa17 label=baseline capture=1
    while (( $# )); do
        case "$1" in
            --game) game="$2"; shift 2 ;;
            --label) label="$2"; shift 2 ;;
            --no-capture) capture=0; shift ;;
            --dry-run) DRY=1; shift ;;
            --relay) CHANNELS='-all,err+all,+relay,+loaddll,+timestamp,+pid'; capture=0; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done
    [[ "$game" == fifa17 || "$game" == fifa15 ]] || die "--game must be fifa17 or fifa15"
    [ -x "$WINE" ] || die "CrossOver-FIFA wine not found at $WINE"
    if [ -f "$CURRENT" ] && [ -f "$(<"$CURRENT")/pids" ]; then
        local old; old=$(<"$CURRENT")
        if awk '{print $2}' "$old/pids" | xargs -n1 kill -0 2>/dev/null; then
            die "a run is already in progress ($old). Run: $0 stop"
        fi
        say "previous run ($old) has no live processes; clearing it"
        rm -f "$old/pids"
    fi
    if pgrep -qf 'FIFA17.exe|fifa15.exe|Reborn17|Aurora15Connector' 2>/dev/null; then
        die "a game or launcher is already running. Close it completely first (Stop.command if needed)."
    fi
    # A leftover Wine session (wineserver, services.exe, explorer.exe, ...) from an
    # earlier launch makes FIFA17.exe die ~25 s after PLAY, before the menu, with
    # no exception (commit 8b092a3: loader-lock hang when a session is already
    # up). Runs 20260908T122231Z and 20260908T125019Z were both that, not the
    # DLL override they were meant to test. Refuse rather than guess.
    if pgrep -qf 'bin/wineserver|windows\\system32\\(services|winedevice|explorer|plugplay|rpcss|svchost)\.exe' 2>/dev/null; then
        die "a Wine session is still up from an earlier launch (wineserver/services.exe/explorer.exe). Run Stop.command (or ./setup.sh --shutdown) first, then start again."
    fi

    local run="$RUNS/$(date -u '+%Y%m%dT%H%M%SZ')-$game-$label"
    mkdir -p "$run" || die "cannot create $run"
    print -r -- "$run" > "$CURRENT"
    now > "$run/launch-anchor.txt"
    say "run folder: $run"
    say "collecting identity..."
    identity "$game" "$run/identity.txt"
    grep -E '^VPN:|^public ip' "$run/identity.txt"
    if grep -q '^VPN: ON' "$run/identity.txt"; then
        say "!! The VPN is ON. Every game packet leaves through ProtonVPN. If this run is meant to be VPN OFF, stop now, disconnect ProtonVPN, and start again."
    fi

    : > "$run/pids"
    sampler "$run" &
    print -r -- "sampler $!" >> "$run/pids"

    if (( capture )) && [[ -z "${DRY:-}" ]]; then
        if [ -t 0 ]; then
            say "packet capture needs your Mac password (sudo). Ctrl-C here skips it."
            if sudo -v; then
                sudo /usr/sbin/tcpdump -i pktap,all -k -n -s 128 -U -w "$run/capture.pcapng" >> "$run/tcpdump.out" 2>&1 &
                print -r -- "tcpdump-sudo $!" >> "$run/pids"
                sleep 1
                say "packet capture: on (pktap,all, 128-byte snapshot)"
            else
                say "packet capture: skipped (no sudo)"
            fi
        else
            say "packet capture: skipped (not a terminal; run from Terminal or the .command for a pcap)"
        fi
    else
        say "packet capture: off"
    fi

    if [[ -n "${DRY:-}" ]]; then
        say "dry run: not launching"
        return 0
    fi

    say "launching $game under CrossOver log ($run/wine.cxlog)..."
    export AURORA17_HOSTS_DEBUG=1
    if [[ "$game" == fifa17 ]]; then
        "$WINE" --bottle Aurora17 --workdir "$HOME/Downloads" \
            --cx-log "$run/wine.cxlog" --debugmsg "$CHANNELS" \
            --cx-app 'Y:\Downloads\Reborn17-3.1.15.exe' >> "$run/launch.out" 2>&1 &
    else
        "$WINE" --bottle Aurora15 --workdir "$HOME/Downloads/FIFA 15" \
            --cx-log "$run/wine.cxlog" --debugmsg "$CHANNELS" \
            --cx-app 'C:\users\crossover\AppData\Local\Aurora15Connector\Aurora15Connector.exe' >> "$run/launch.out" 2>&1 &
    fi
    print -r -- "launcher $!" >> "$run/pids"
    say "$(now)  launched $game" >> "$run/marks.txt"
    say
    say "The launcher is opening. Sign in, press PLAY, find ONE match against another player,"
    say "and play until the disconnect popup (or 2 real minutes past kickoff if it holds)."
}

cmd_stop() {
    [ -f "$CURRENT" ] || die "no current run"
    local run; run=$(<"$CURRENT")
    [ -f "$run/pids" ] || die "run $run is not in progress"
    say "$(now)  stop requested" >> "$run/marks.txt"
    local name pid
    while read -r name pid; do
        case "$name" in
            sampler) kill "$pid" 2>/dev/null ;;
            tcpdump-sudo)
                local child; child=$(pgrep -P "$pid" 2>/dev/null | head -1)
                sudo kill -INT "${child:-$pid}" 2>/dev/null
                sleep 2
                sudo chown "$USER" "$run/capture.pcapng" 2>/dev/null
                ;;
            launcher) : ;;   # never kill the game/launcher: the person closes it
        esac
    done < "$run/pids"
    rm -f "$run/pids"

    local game; game=$(awk -F': ' '/^game:/{print $2}' "$run/identity.txt")
    if [[ "$game" == fifa17 ]]; then
        redact < "$GAMEDIR17/crumpet-log.txt" > "$run/crumpet-log.txt" 2>/dev/null
        redact < "$GAMEDIR17/crumpet.ini" > "$run/crumpet.ini" 2>/dev/null
        ( cd "$GAMEDIR17" && shasum -a 256 FIFA17.exe version.dll CardsDLL_Win64_retail.dll ) > "$run/hashes-after.txt" 2>/dev/null
    else
        local lg="$BOTTLES/Aurora15/drive_c/users/crossover/AppData/Local/Aurora15Connector/logs"
        for f in launcher.log EA-MITM.log; do [ -f "$lg/$f" ] && redact < "$lg/$f" > "$run/$f"; done
    fi
    vpn_line >> "$run/marks.txt"
    cmd_summary "$run" | tee "$run/summary.txt"
    say
    say "collected in: $run"
    say "Before the next run: close the launcher, then double-click Stop.command (the Wine session"
    say "left behind makes the next FIFA17.exe die ~25 s after PLAY)."
}

cmd_summary() {
    local run="${1:-$(<"$CURRENT")}"
    say "==== run: ${run:t}"
    say "anchor (UTC): $(<"$run/launch-anchor.txt")"
    grep -E '^VPN:|^public ip' "$run/identity.txt" 2>/dev/null
    say "---- marks"; cat "$run/marks.txt" 2>/dev/null
    local log="$run/wine.cxlog"
    if [ -f "$log" ]; then
        say "---- wine log: $(wc -l < "$log" | tr -d ' ') lines, $(du -h "$log" | cut -f1)"
        say "processes started:"; grep -E 'trace:process:(create_process|NtCreateUserProcess)|CreateProcess' "$log" | grep -oE '"[^"]*\.exe[^"]*"' | sort | uniq -c | head -10
        say "version.dll loaded:"; grep -iE 'loaddll.*version\.dll' "$log" | head -3 | cut -c1-200
        say "adapters seen by the game (iphlpapi):"; grep -E 'trace:iphlpapi' "$log" | grep -iE 'GetAdaptersAddresses|GetBestInterface|GetIpAddrTable|GetAdaptersInfo' | wc -l | tr -d ' '
        say "UDP sockets bound (winsock bind):"; grep -E 'winsock:.*bind' "$log" | grep -oE ':[0-9]{2,5}' | sort | uniq -c | sort -rn | head -8
        say "winsock errors (err/fixme/WSAE), top:"; grep -E '(err|fixme):winsock|WSAE[A-Z]+|status 0xc0000|10054|10035|10048|10061|10065' "$log" | sed -E 's/^[0-9a-f:.]+ //' | cut -c1-140 | sort | uniq -c | sort -rn | head -15
        say "names looked up (a17hosts):"; grep -E '^a17hosts: ' "$log" | grep -oE '\((gethostbyname|getaddrinfo)\)?\(?"[^"]+"' | sort | uniq -c | sort -rn | head -12
    else
        say "---- no wine log"
    fi
    if [ -f "$run/sockets.log" ]; then
        say "---- sockets seen (UDP, unique local/remote tuples):"
        grep -E 'UDP' "$run/sockets.log" | awk '{print $1, $(NF-1), $NF}' | sort | uniq -c | sort -rn | head -15
        say "---- sockets seen (TCP, remote endpoints):"
        grep -E 'TCP' "$run/sockets.log" | grep -oE '\->[0-9a-f.:\[\]]+:[0-9]+' | sort | uniq -c | sort -rn | head -12
    fi
    if [ -f "$run/capture.pcapng" ] && [ -r "$run/capture.pcapng" ]; then
        say "---- packets: $(du -h "$run/capture.pcapng" | cut -f1)  $(tail -2 "$run/tcpdump.out" 2>/dev/null | tr '\n' ' ')"
        say "top UDP conversations (src > dst : packets):"
        /usr/sbin/tcpdump -r "$run/capture.pcapng" -n -q udp 2>/dev/null | awk '{print $3, $4, $5}' | sed 's/:$//' | sort | uniq -c | sort -rn | head -20
        say "ICMP:"; /usr/sbin/tcpdump -r "$run/capture.pcapng" -n icmp 2>/dev/null | awk '{$1="";print}' | cut -c1-120 | sort | uniq -c | sort -rn | head -8
        say "TCP resets/FINs to game servers:"; /usr/sbin/tcpdump -r "$run/capture.pcapng" -n 'tcp[tcpflags] & (tcp-rst|tcp-fin) != 0' 2>/dev/null | awk '{print $3, $4, $5, $6, $7}' | sort | uniq -c | sort -rn | head -10
    fi
    if [ -f "$run/crumpet-log.txt" ]; then
        say "---- crumpet-log tail:"; tail -12 "$run/crumpet-log.txt"
    fi
}

cmd_status() {
    if [ -f "$CURRENT" ] && [ -f "$(<"$CURRENT")/pids" ]; then
        say "in progress: $(<"$CURRENT")"; cat "$(<"$CURRENT")/pids"
    else
        say "no run in progress"
    fi
    vpn_line
    ls -1dt "$RUNS"/*/ 2>/dev/null | head -5
}

cmd_session() {
    cmd_start "$@" || return $?
    [[ -n "${DRY:-}" ]] && { cmd_stop; return; }
    say
    say "Type a note + Return at any moment (e.g. 'matched', 'kickoff', 'popup: <exact text>')."
    say "Press Return on an empty line when the match is over to stop and collect."
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && break
        cmd_mark "$line"
    done
    cmd_stop
}

case "${1:-}" in
    session) shift; cmd_session "$@" ;;
    start)   shift; cmd_start "$@" ;;
    stop)    cmd_stop ;;
    mark)    shift; cmd_mark "$@" ;;
    status)  cmd_status ;;
    summary) shift; cmd_summary "$@" ;;
    *) sed -n '2,20p' "$0"; exit 1 ;;
esac
