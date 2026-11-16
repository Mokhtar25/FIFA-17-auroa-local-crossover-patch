#!/bin/zsh
# FIFA 12 probe: collects everything about why Aurora 12's Play ends at once,
# runs a few short tests, and leaves one zip on the Desktop to send back.
#
# Run it from Terminal (a downloaded .command loses its permission to run):
#     zsh ~/Downloads/fifa12-probe.command
#
# It takes about 5 minutes. It starts FIFA 12 a few times; when the game
# opens, leave it alone: the script closes it again. It changes nothing in the
# bottle except what Aurora's own Play changes (and the same clean-up after).
# It never copies Aurora 12's key or certificates (the maclink folder) or a
# Discord sign-in.

emulate -L zsh
setopt nullglob pipefail
unsetopt nomatch

BOTTLE="${FIFA12_BOTTLE:-Aurora17}"
APP=/Applications/CrossOver-FIFA.app
WINE="$APP/Contents/SharedSupport/CrossOver/bin/wine"
WINESERVER="$APP/Contents/SharedSupport/CrossOver/bin/wineserver"
BD="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
DC="$BD/drive_c"
U="$DC/users/crossover"
A12="$U/AppData/Local/Aurora12"
F12="$A12/FIFA12"
DBG="$DC/Program Files (x86)/Windows Kits/10/Debuggers/x86"
CDBW='C:\Program Files (x86)\Windows Kits\10\Debuggers\x86\cdb.exe'
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${FIFA12_PROBE_DIR:-$HOME/Desktop}/fifa12-probe-$STAMP"
PROBE_W='C:\fifa12probe'
PROBE="$DC/fifa12probe"

mkdir -p "$OUT" || { print "Could not make $OUT"; exit 1; }
CONSOLE="${TMPDIR:-/tmp}/fifa12-probe-$STAMP-console.txt"
exec > >(tee -a "$CONSOLE") 2>&1

say()  { print -r -- "$*"; }
step() { print -r -- ""; print -r -- "== $*"; }
sha()  { shasum -a 256 "$1" 2>/dev/null | cut -c1-16; }
cp_to() { [ -f "$1" ] && { mkdir -p "${2:h}"; cp "$1" "$2" 2>/dev/null; }; return 0; }

# Lists files with size, date and the first 16 hex of their SHA-256.
list_hashed() {
    local f
    for f in "$@"; do
        [ -f "$f" ] || continue
        printf '%s  %10s  %s  %s\n' "$(sha "$f")" "$(stat -f %z "$f")" \
            "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f")" "${f:t}"
    done
}

# Sections of a Wine registry file whose key starts with one of the prefixes.
reg_sections() {
    local reg="$1"; shift
    [ -f "$reg" ] || { say "(no ${reg:t})"; return 0; }
    LC_ALL=C P="${(pj:\n:)@}" awk '
        BEGIN { n = split(tolower(ENVIRON["P"]), p, "\n") }
        substr($0,1,1)=="[" { on = 0; for (i = 1; i <= n; i++) if (index(tolower($0), p[i]) == 1) on = 1; if (on) print "" }
        on { print }' "$reg"
}

# A Windows program in the bottle, its output to a file, cut off after
# $1 seconds. Everything after the first three arguments goes to wine.
run_wine() {
    local secs="$1" out="$2" pid t=0; shift 2
    ( cd /tmp && "$WINE" --bottle "$BOTTLE" --no-gui "$@" ) > "$out" 2>&1 &
    pid=$!
    while kill -0 $pid 2>/dev/null; do
        sleep 1; t=$((t + 1))
        if [ $t -ge "$secs" ]; then
            print -r -- "[probe: stopped after $secs s]" >> "$out"
            kill $pid 2>/dev/null
            return 124
        fi
    done
    wait $pid
}

wine_session_running() {
    pgrep -f "CrossOver-FIFA.app/.*wineserver" >/dev/null 2>&1
}

stop_bottle() {
    "$WINE" --bottle "$BOTTLE" --no-gui --cx-app wineboot.exe -k >/dev/null 2>&1 || true
    WINEPREFIX="$BD" "$WINESERVER" -k >/dev/null 2>&1 || true
    sleep 2
}

say "FIFA 12 probe, $(date)"
say "Everything goes into: $OUT"

if [ ! -x "$WINE" ] || [ ! -d "$DC" ]; then
    say "Could not find CrossOver-FIFA or the $BOTTLE bottle. Stopping."
    exit 1
fi

if pgrep -x CrossOver >/dev/null 2>&1 || wine_session_running; then
    say ""
    say "CrossOver or a Windows program is still running."
    say "Quit CrossOver-FIFA (Command-Q), close the Aurora launcher, then press return."
    read -r _
    if pgrep -x CrossOver >/dev/null 2>&1; then
        say "CrossOver is still open. Quit it and run this again."
        exit 1
    fi
fi
stop_bottle

# ------------------------------------------------------------------ static
step "1. This Mac"
{
    sw_vers; uname -m; sysctl -n hw.model machdep.cpu.brand_string
    say "CrossOver-FIFA: $(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null) build $(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null)"
    say "Wine files in CrossOver-FIFA:"
    list_hashed "$APP/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix"/{ntdll,win32u,crypt32,winecoreaudio}.so \
        "$APP/Contents/SharedSupport/CrossOver/lib/wine/x86_64-windows"/{ntdll,wow64,wow64win,wow64cpu,kernelbase,kernel32,version,ole32}.dll \
        "$APP/Contents/SharedSupport/CrossOver/lib/wine/i386-windows"/{ntdll,kernelbase,kernel32,ucrtbase,msvcrt,xmllite,dbghelp}.dll
    say "locale: $(defaults read -g AppleLocale 2>/dev/null)  languages: $(defaults read -g AppleLanguages 2>/dev/null | tr -d '\n ')"
    system_profiler SPDisplaysDataType 2>/dev/null | grep -iE 'Resolution|Looks like|Main Display'
    say "patch receipt:"; cat "$HOME/Library/Application Support/Aurora17/install-receipt.conf" 2>/dev/null
} > "$OUT/mac.txt" 2>&1
say "ok"

step "2. The bottle's settings and registry"
cp_to "$BD/cxbottle.conf" "$OUT/bottle/cxbottle.conf"
{
    say "#### user.reg"
    reg_sections "$BD/user.reg" '[Software\\Wine' '[Environment]' '[Software\\EA Sports' '[Software\\Electronic Arts'
    say ""; say "#### system.reg"
    reg_sections "$BD/system.reg" '[Software\\EA Sports' '[Software\\Wow6432Node\\EA Sports' \
        '[Software\\Electronic Arts' '[Software\\Wow6432Node\\Electronic Arts' \
        '[System\\CurrentControlSet\\Control\\Session Manager\\Environment' \
        '[Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug' \
        '[Software\\Wow6432Node\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug' \
        '[Software\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options' \
        '[Software\\Wow6432Node\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options' \
        '[Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags' \
        '[System\\CurrentControlSet\\Control\\Nls' '[Software\\Wine' \
        '[Software\\Microsoft\\Windows NT\\CurrentVersion]' '[Software\\Wow6432Node\\Microsoft\\Windows NT\\CurrentVersion]'
} > "$OUT/bottle/registry.txt" 2>&1
cp_to "$DC/windows/system32/drivers/etc/hosts" "$OUT/bottle/hosts.txt"
say "ok"

step "3. The debugger"
{
    say "folder: $DBG"
    ls -la "$DBG" 2>&1
    for d in Visualizers Visualizers.off; do [ -d "$DBG/$d" ] && say "$d: $(ls "$DBG/$d" | wc -l | tr -d ' ') files, changed $(stat -f '%Sm' "$DBG/$d")"; done
    say ""; say "Debuggers folder (siblings, e.g. .before-fifa12, .x86-fifa12-partial):"; ls -la "${DBG:h}" 2>&1
    say ""; say "every file under x86 (sha16, size, date, path):"
    ( cd "$DBG" 2>/dev/null && find . -type f | sort | while IFS= read -r f; do
        printf '%s  %10s  %s  %s\n' "$(sha "$f")" "$(stat -f %z "$f")" "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f")" "$f"
      done )
} > "$OUT/debugger.txt" 2>&1
say "ok"

step "4. Windows DLLs that are not Wine's own (system32, syswow64)"
{
    for d in system32 syswow64; do
        say "#### $d: files without Wine's builtin marker"
        for f in "$DC/windows/$d"/*.(dll|DLL|exe|EXE)(.); do
            LC_ALL=C grep -q "Wine builtin DLL" "$f" 2>/dev/null || list_hashed "$f"
        done
        say ""
    done
    say "#### the stand-ins"
    list_hashed "$DC/windows/system32/WindowsPowerShell/v1.0"/*(.) "$DC/windows/syswow64/WindowsPowerShell/v1.0"/*(.)
    list_hashed "$DC/windows"/{system32,syswow64}/{certutil,tasklist}.exe*(.)
} > "$OUT/bottle/native-dlls.txt" 2>&1
say "ok"

step "5. The game folder"
GAME_MAC=""
gp="$F12/server/gamepath.txt"
if [ -f "$gp" ]; then
    gw="$(tr -d '\r\357\273\277' < "$gp" | head -1)"
    case "$gw" in
        [Cc]:\\*) GAME_MAC="$DC/${${gw#?:\\}//\\//}" ;;
        [Zz]:\\*) GAME_MAC="/${${gw#?:\\}//\\//}" ;;
    esac
fi
{
    say "gamepath.txt: $gw"
    say "as a Mac path: $GAME_MAC"
    if [ -d "$GAME_MAC" ]; then
        say ""; say "#### ${GAME_MAC:h}"; ls -la "${GAME_MAC:h}"
        say ""; say "#### Game (exe, dll, ini, hashed)"
        list_hashed "$GAME_MAC"/*.(exe|EXE|dll|DLL|ini|INI|asi|ASI)(.)
        say ""; say "#### Game, everything"; ls -la "$GAME_MAC"
        say ""; say "fifa.exe manifest: $(LC_ALL=C grep -ao 'requestedExecutionLevel[^/]*' "$GAME_MAC/fifa.exe" | head -1)"
        say ""; say "#### crash dumps"; ls -la "$GAME_MAC"/*.dmp "${GAME_MAC:h}"/*.dmp 2>&1
    fi
    say ""; say "#### fifasetup.ini"
    for f in "$U/Documents/FIFA 12/fifasetup.ini" "$HOME/Documents/FIFA 12/fifasetup.ini"; do
        [ -f "$f" ] && { say "-- $f"; cat "$f"; ls -la "${f:h}"; }
    done
} > "$OUT/game.txt" 2>&1
say "ok"

step "6. Aurora 12's own files and logs"
{
    say "#### $A12"; ls -la "$A12"
    say ""; say "#### FIFA12"; ls -la "$F12"
    say ""; say "#### FIFA12/server"; ls -la "$F12/server"
    say ""; say "#### FIFA12/server/logs"; ls -la "$F12/server/logs"
    say ""; say "#### FIFA12/tools"; list_hashed "$F12/tools"/*(.)
    say ""; say "#### FIFA12/logs"; ls -la "$F12/logs" 2>&1
    say ""; say "#### maclink (names only)"; ls -la "$A12/maclink" 2>&1
    say ""; say "#### FIFA12/python"; ls "$F12/python" 2>&1 | head -40
} > "$OUT/aurora12/listing.txt" 2>&1
for f in VERSION.txt setup_state.json; do cp_to "$F12/$f" "$OUT/aurora12/$f"; done
for f in gamepath.txt netconfig.json cdb_manifest.json cdb_run.txt launch_fifa.ps1 start_all.ps1 gamebuilds.py cdbpath.py; do
    cp_to "$F12/server/$f" "$OUT/aurora12/server/$f"
done
for f in "$F12/server/logs"/*(.); do cp_to "$f" "$OUT/aurora12/logs/${f:t}"; done
for f in "$F12/logs"/*(.); do cp_to "$f" "$OUT/aurora12/top-logs/${f:t}"; done
cp_to "$A12/maclink/unknown-scripts.log" "$OUT/aurora12/unknown-scripts.log"
L="$U/AppData/Local/Aurora15Connector/logs"
cp_to "$L/fifa12/launcher.log" "$OUT/aurora/fifa12-launcher.log"
[ -f "$L/launcher.log" ] && grep -v "Discord presence" "$L/launcher.log" | tail -600 > "$OUT/aurora/launcher-tail.log"
say "ok"

step "7. CrossOver's own logs"
mkdir -p "$OUT/crossover"
ls -la "$HOME/Library/Logs/CrossOver" > "$OUT/crossover/listing.txt" 2>&1
for f in ${(f)"$(/bin/ls -t "$HOME/Library/Logs/CrossOver"/* 2>/dev/null | head -3)"}; do
    [ -f "$f" ] && tail -c 2000000 "$f" > "$OUT/crossover/${f:t}"
done
say "ok"

# ------------------------------------------------------------- experiments
# One new thing per test. Each has a hard time limit. Wine's own messages
# (--debugmsg) go to the test's file next to what the program printed.
CH='+loaddll,+module,+process,+seh,+pid,+timestamp'
mkdir -p "$PROBE" "$OUT/tests"
rm -f "$PROBE"/*(.)
GAME_W="$gw"

# Runs a .bat in the bottle that runs one command and writes its full exit
# code (Wine's $? on the Mac side cuts an NTSTATUS to 8 bits).
bat_run() {
    local name="$1" secs="$2" workdir="$3" line="$4" channels="$5"
    printf '@echo off\r\n%s\r\necho exit %%ERRORLEVEL%% > %s\\%s-exit.txt\r\n' "$line" "$PROBE_W" "$name" > "$PROBE/$name.bat"
    local -a extra; extra=()
    [ -n "$channels" ] && extra=( --debugmsg "$channels" )
    [ -n "$workdir" ] && extra+=( --workdir "$workdir" )
    local t0=$SECONDS
    run_wine "$secs" "$OUT/tests/$name.txt" "${extra[@]}" --cx-app 'C:\windows\system32\cmd.exe' /c "$PROBE_W\\$name.bat"
    local rc=$?
    say "  $name: $((SECONDS - t0)) s, wine rc $rc, $(tr -d '\r' < "$PROBE/$name-exit.txt" 2>/dev/null || print 'no exit file')"
    print -r -- "elapsed $((SECONDS - t0)) s; $(tr -d '\r' < "$PROBE/$name-exit.txt" 2>/dev/null)" >> "$OUT/tests/summary.txt"
    cp_to "$PROBE/$name-cdb.log" "$OUT/tests/$name-cdb.log"
}

step "8. Test 1: can the bottle run a 32-bit program at all"
t0=$SECONDS
run_wine 60 "$OUT/tests/t1-cmd-ver.txt" --cx-app 'C:\windows\syswow64\cmd.exe' /c ver
say "  t1: $((SECONDS - t0)) s, rc $?: $(tr -d '\r' < "$OUT/tests/t1-cmd-ver.txt" | grep -i version | head -1)"

step "9. Test 2: the debugger on a harmless program (on a working Mac: about 6 s)"
bat_run t2 120 "" "\"$CDBW\" -logo $PROBE_W\\t2-cdb.log -G -c \"version;g;q\" C:\\windows\\syswow64\\cmd.exe /c exit" ""

step "10. Test 3: the same, with Wine's loader and crash messages"
stop_bottle
bat_run t3 120 "" "\"$CDBW\" -logo $PROBE_W\\t3-cdb.log -G -c \"version;g;q\" C:\\windows\\syswow64\\cmd.exe /c exit" "$CH"

step "11. Test 4: the debugger on fifa.exe, stopped at its first instruction"
stop_bottle
if [ -n "$GAME_W" ]; then
    bat_run t4 120 "$GAME_W" "\"$CDBW\" -logo $PROBE_W\\t4-cdb.log -c \"q\" \"$GAME_W\\fifa.exe\"" "+loaddll,+process,+seh,+pid,+timestamp"
else
    say "  skipped: no gamepath.txt"
fi

# Test 5 is the launch stand-in's exact command line: the same debugger
# script, the game folder as the current folder. The game may open; it is
# closed after 60 s.
step "12. Test 5: Aurora's own debugger script on the game (the game may open; it is closed after a minute)"
stop_bottle
if [ -n "$GAME_W" ] && [ -f "$F12/server/cdb_run.txt" ]; then
    (
        sleep 60
        "$WINE" --bottle "$BOTTLE" --no-gui --cx-app taskkill.exe /im fifa.exe >/dev/null 2>&1
        sleep 10
        "$WINE" --bottle "$BOTTLE" --no-gui --cx-app taskkill.exe /f /im fifa.exe >/dev/null 2>&1
        sleep 5
        "$WINE" --bottle "$BOTTLE" --no-gui --cx-app taskkill.exe /f /im cdb.exe >/dev/null 2>&1
    ) &
    closer=$!
    bat_run t5 120 "$GAME_W" "\"$CDBW\" -G -cf \"C:\\users\\crossover\\AppData\\Local\\Aurora12\\FIFA12\\server\\cdb_run.txt\" -logo $PROBE_W\\t5-cdb.log \"$GAME_W\\fifa.exe\"" "+loaddll,+process,+seh,+pid,+timestamp"
    kill $closer 2>/dev/null
else
    say "  skipped: no gamepath.txt or cdb_run.txt"
fi

# Test 6 is a real Play, through Aurora 12's helper, as Aurora's button runs
# it, with Wine's process and crash messages. Never cut short while the game
# runs: the helper takes its hosts entries out only when it ends normally.
step "13. Test 6: a real Play through Aurora 12's helper"
stop_bottle
if [ -f "$F12/tools/futlink.exe" ]; then
    say "  helper: $(sha "$F12/tools/futlink.exe")"
    say "  If FIFA 12 opens: wait for its first menu, then quit the game normally."
    t0=$SECONDS
    INI="$U/Documents/FIFA 12/fifasetup.ini"
    cat -v "$INI" > "$OUT/tests/t6-ini-before.txt" 2>&1
    # +d3d9 and wined3d's warnings say why the game's CreateDevice fails
    # (FIFA's dialog E0001); +win and the display mode calls say what screen
    # mode it asked for.
    ( cd /tmp && "$WINE" --bottle "$BOTTLE" --no-gui \
        --debugmsg "+loaddll,+process,+seh,+pid,+timestamp,+d3d9,warn+d3d,warn+d3d_caps,+display,warn+win" \
        --cx-app 'C:\users\crossover\AppData\Local\Aurora12\FIFA12\tools\futlink.exe' \
        --root 'C:\users\crossover\AppData\Local\Aurora12\FIFA12' play ) > "$OUT/tests/t6-play.txt" 2>&1 &
    p=$!
    told=0
    while kill -0 $p 2>/dev/null; do
        sleep 2
        if [ $((SECONDS - t0)) -ge 900 ]; then
            say "  still running after 15 minutes; stopping it"
            kill $p 2>/dev/null; break
        fi
        if [ $told = 0 ] && [ $((SECONDS - t0)) -ge 90 ]; then
            say "  FIFA 12 seems to be running. Quit it normally when you have seen its menu."
            told=1
        fi
    done
    wait $p 2>/dev/null
    say "  t6: $((SECONDS - t0)) s"
    print -r -- "t6 elapsed $((SECONDS - t0)) s" >> "$OUT/tests/summary.txt"
    for f in ${(f)"$(/bin/ls -t "$F12/server/logs"/cdb_*.log 2>/dev/null | head -2)"}; do cp_to "$f" "$OUT/tests/t6-${f:t}"; done
    cp_to "$F12/server/logs/futlink.log" "$OUT/tests/t6-futlink.log"
    cp_to "$F12/server/logs/forwarder.out" "$OUT/tests/t6-forwarder.out"
    cp_to "$F12/server/cdb_run.txt" "$OUT/tests/t6-cdb_run.txt"
    ls -la "$F12/server/logs" > "$OUT/tests/t6-logs-listing.txt" 2>&1
    cat -v "$INI" > "$OUT/tests/t6-ini-after.txt" 2>&1
    ls -la "${INI:h}" >> "$OUT/tests/t6-ini-after.txt" 2>&1
    # The game writes a crash dump or a log next to itself on E0001.
    [ -n "$GAME_MAC" ] && ls -lat "$GAME_MAC" | head -15 > "$OUT/tests/t6-game-newest.txt" 2>&1
else
    say "  skipped: no futlink.exe"
fi
stop_bottle

step "14. Clean-up"
H="$DC/windows/system32/drivers/etc/hosts"
if [ -f "$H" ] && grep -q "# FUT12 Aurora 12 (CrossOver)" "$H"; then
    say "  the hosts file still had Aurora 12's block; taking it out"
    cp "$H" "$OUT/bottle/hosts-left-over.txt"
    awk 'index($0, "# FUT12 Aurora 12 (CrossOver)") == 1 { in = !in; next } !in' "$H" > "$H.probe-tmp" && mv "$H.probe-tmp" "$H"
else
    say "  hosts file clean"
fi
rm -rf "$PROBE"

# Mask what names this Mac or its owner, then zip.
step "15. Packing"
cp "$CONSOLE" "$OUT/console.txt" 2>/dev/null
user="${USER:-$(id -un)}"
host="$(hostname -s 2>/dev/null)"
for f in "$OUT"/**/*(.); do
    LC_ALL=C P_HOME="$HOME" P_USER="$user" P_HOST="$host" perl -pi -e '
        BEGIN { $h = $ENV{P_HOME}; ($w = "Z:$h") =~ s{/}{\\}g; ($ww = $w) =~ s{\\}{\\\\}g; $u = $ENV{P_USER}; $n = $ENV{P_HOST} }
        s/\Q$ww\E/~/g; s/\Q$w\E/~/g; s/\Q$h\E/~/g;
        s/(signed in as )[^"\r\n]*/$1<name>/g;
        s/("user"\s*:\s*")[^"]*/$1<name>/g;
        s/(hostname\s*[=:]\s*).*/$1<host>/;
        s/\b\Q$u\E\b/<user>/g if length($u) > 2;
        s/\b\Q$n\E\b/<host>/gi if length($n) > 2;
    ' "$f" 2>/dev/null
done
ZIP="$OUT.zip"
ditto -c -k --keepParent "$OUT" "$ZIP" && rm -rf "$OUT"
say ""
say "Done. Send this file back:"
say "  $ZIP"
open -R "$ZIP" 2>/dev/null
