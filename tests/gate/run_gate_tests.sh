#!/bin/zsh
# Proves the C half of the FIFA 17 folder gate
# (patches/crossover-26.3-fifa17-folder-gate.patch) with a stand-in script:
# what ntdll hands cx-fifa17-gate, what it keeps from it, and what each exit
# of the script does to the process being started. Exits 1 if any check
# fails, 0 if all pass.
#
#   ./run_gate_tests.sh /path/to/CrossOver-FIFA-copy.app [bottle]
#
# Point it at a COPY of the app carrying the ntdll.so under test (cp -cR makes
# one in a second), never at the app you play with, and at a throwaway bottle
# (default GateTest): it stages exes in drive_c and kills the bottle's
# wineserver between runs. The real cx-fifa17-gate beside the copy's ntdll.so,
# if there is one, is set aside for the run and put back at the end; a stub
# stands in for it that logs its argv, environment and open files and exits
# with whatever the test asks for.
set -eu

APP="${1:?usage: run_gate_tests.sh /path/to/app-copy.app [bottle]}"
BOTTLE="${2:-GateTest}"
HERE="${0:A:h}"
W="$APP/Contents/SharedSupport/CrossOver"
U="$W/lib/wine/x86_64-unix"
B="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
[ -x "$W/bin/wine" ] || { print -r -- "no wine in $APP"; exit 2 }
[ -d "$B/drive_c" ] || { print -r -- "no bottle $BOTTLE"; exit 2 }
case "$APP" in /Applications/*) print -r -- "refusing to run against an installed app; use a copy"; exit 2 ;; esac
case "$BOTTLE" in Aurora17|Aurora15|FIFA16|FIFA17) print -r -- "refusing to run in $BOTTLE; use a throwaway bottle"; exit 2 ;; esac
LC_ALL=C grep -aqF CX_FOLDER_GATE_V1 "$U/ntdll.so" || { print -r -- "$U/ntdll.so has no folder gate"; exit 2 }

PROBE="$HERE/gate_probe.exe"
T="$(mktemp -d -t cxgate)"
CTL="$T/ctl" LOG="$T/log" GATE="$U/cx-fifa17-gate"
[ -e "$GATE" ] && mv "$GATE" "$T/real-gate"
restore() {
    rm -f "$GATE"
    [ -e "$T/real-gate" ] && mv "$T/real-gate" "$GATE"
    WINEPREFIX="$B" "$W/bin/wineserver" -k 2>/dev/null || true
}
trap restore EXIT

cat > "$T/stub" <<STUB
#!/bin/zsh
# Stand-in for cx-fifa17-gate: logs what it was given, exits as $CTL says.
typeset -A C
for l in \${(f)"\$(<$CTL)"}; C[\${l%%=*}]=\${l#*=}
[ "\${C[fast]:-}" = 1 ] && exit \${C[code]:-0}
{
  print -r -- "=== pid=\$\$ pgid=\$(ps -o pgid= -p \$\$)"
  for a in "\$@"; print -r -- "ARG \$a"
  env | sed 's/^/ENV /'
  [ "\${C[lsof]:-}" = 1 ] && lsof -n -P -p \$\$ | sed 's/^/FD /'
} >> $LOG 2>&1
[ -n "\${C[sleep]:-}" ] && { print -r -- "SLEEPING" >> $LOG; sleep \${C[sleep]} }
print -r -- "EXITING \${C[code]:-0}" >> $LOG
exit \${C[code]:-0}
STUB
install_stub() { cp "$T/stub" "$GATE" }
install_stub

stage() { mkdir -p "$B/drive_c/${1:h}"; cp "$PROBE" "$B/drive_c/$1" }
stage gate/fifa17/FIFA17.exe
stage gate/imp/Impulsum17Launcher.exe
stage gate/game/game.exe
stage "Games/FIFA 17/FIFA17.exe"

kill_session() { WINEPREFIX="$B" "$W/bin/wineserver" -k 2>/dev/null || true }
ctl() { print -l -- "$@" > "$CTL"; : > "$LOG" }

FAILS=0 CHECKS=0
check() {  # <description> <command...>
    CHECKS=$((CHECKS+1))
    if "${@:2}"; then print -r -- "   ok   $1"; else FAILS=$((FAILS+1)); print -r -- "   FAIL $1"; fi
}
has()    { [[ "$1" == *"$2"* ]] }
hasnot() { [[ "$1" != *"$2"* ]] }

run() {  # <label> <env...> -- <wine args>; output in OUT, script log in LOGTXT
    local label="$1"; shift
    local -a envs
    while [ "$1" != -- ]; do envs+=( "$1" ); shift; done
    shift
    print -r -- "== $label  [${envs[*]:-no env}]  $*"
    kill_session
    OUT="$(env CX_BOTTLE="$BOTTLE" "${envs[@]}" "$W/bin/wine" --bottle "$BOTTLE" --debugmsg +cxgate \
             --wait-children "$@" 2>&1 | grep -E '^GPROBE|^SPAWN|cxgate' \
             | sed -E 's/^[0-9a-f]{4}:(trace|warn):cxgate:cx_folder_gate /\1 /' || true)"
    LOGTXT="$(<$LOG)"
    print -r -- "$OUT" | sed 's/^/   | /'
}
arg_of() {  # <name> [nth entry]: the value after --<name> in the nth logged call
    print -r -- "$LOGTXT" | awk -v want="--$1" -v nth="${2:-1}" '
        /^=== / { n++ } n == nth && /^ARG / { a = substr($0, 5); if (prev == want) { print a; exit } prev = a }'
}
calls() { print -r -- "$LOGTXT" | grep -c '^=== ' || true }

# --------------------------------------------------------------- (a) args
ctl code=0 lsof=1
run "(a) a launcher (game.exe) starts FIFA17.exe in a path with spaces" -- 'C:\gate\game\game.exe' \
    --setenv FUT17_GAME_CODE=secretvalue123 --setenv IMPULSUM_TOKEN=hunter2 --spawn 'C:\Games\FIFA 17\FIFA17.exe'
ENVN="$(arg_of envnames)"
check "--exe FIFA17.exe"                          [ "$(arg_of exe)" = FIFA17.exe ]
check "--image is the full Windows path"          [ "$(arg_of image)" = 'C:\Games\FIFA 17\FIFA17.exe' ]
check "--parent game.exe"                         [ "$(arg_of parent)" = game.exe ]
check "--prefix is the bottle"                    [ "$(arg_of prefix)" = "${B:A}" -o "$(arg_of prefix)" = "$B" ]
check "--winpid is the child's pid"               has "$OUT" "GPROBE main exe=C:\\Games\\FIFA 17\\FIFA17.exe pid=$(arg_of winpid)"
check "envnames has FUT17_GAME_CODE"              has ",$ENVN," ",FUT17_GAME_CODE,"
check "envnames has IMPULSUM_TOKEN"               has ",$ENVN," ",IMPULSUM_TOKEN,"
check "envnames has no '='"                       hasnot "$ENVN" "="
check "no value reaches the script"               eval 'hasnot "$LOGTXT" secretvalue123 && hasnot "$LOGTXT" hunter2'
check "CXGATE count matches the list"             has "$OUT" "envnames=$(( ${#${(s:,:)ENVN}} )) "
check "the script's env is the minimal one"       [ "$(print -r -- "$LOGTXT" | sed -n 's/^ENV //p' | grep -vE '^(PATH=/usr/bin:/bin:/usr/sbin:/sbin|HOME=|LANG=|CX_FIFA_GATE_FROM_WINE=1$|SHLVL=|PWD=/$|OLDPWD=/$|LOGNAME=|_=/usr/bin/env$)' | wc -l | tr -d ' ')" = 0 ]
PIDS=( $(print -r -- "$LOGTXT" | sed -n 's/^=== pid=\([0-9]*\) pgid= *\([0-9]*\).*/\1 \2/p') )
check "it leads its own process group"            [ "${PIDS[1]:-x}" = "${PIDS[2]:-y}" ]
check "FIFA17.exe ran (exit 0 lets it run)"       has "$OUT" "SPAWN ok exit=0x00000000"
# ------------------------------------------------------- (g) descriptors
FDS="$(print -r -- "$LOGTXT" | sed -n 's/^FD //p' | tail -n +2)"
print -r -- "$FDS" | sed 's/^/   fd: /'
check "(g) no socket, pipe, kqueue or shm in the script" \
    eval '! print -r -- "$FDS" | awk "{print \$5}" | grep -qiE "unix|sock|ipv|pipe|kqueue|shm|systm"'
check "(g) no Wine file open in the script" \
    eval '! print -r -- "$FDS" | grep -v "cx-fifa17-gate$" | grep -qiE "wine|server-|/Bottles/|\\.wine"'
check "(g) descriptors are only 0-2 and zsh's own (10+)" \
    eval '! print -r -- "$FDS" | awk "\$4 ~ /^[3-9][rwu]/" | grep -q .'

ctl code=0
run "(a) via cmd /c start" -- 'C:\gate\game\game.exe' --cmd 'C:\windows\system32\cmd.exe /c start /wait C:\gate\fifa17\FIFA17.exe'
check "parent of a start'ed FIFA17.exe is start.exe" [ "$(arg_of parent)" = start.exe ]
ctl code=0
run "(a) via cmd /c" -- 'C:\gate\game\game.exe' --cmd 'C:\windows\system32\cmd.exe /c C:\gate\fifa17\FIFA17.exe'
check "parent under cmd /c is cmd.exe"            [ "$(arg_of parent)" = cmd.exe ]
ctl code=0
run "(a) straight from the wine command line" -- 'C:\gate\fifa17\FIFA17.exe'
DIRECT_PARENT="$(arg_of parent)"
check "parent from the command line is reported ($DIRECT_PARENT)" [ -n "$DIRECT_PARENT" ]
ctl code=0
run "(a) Impulsum17Launcher.exe is gated too" -- 'C:\gate\game\game.exe' --spawn 'C:\gate\imp\Impulsum17Launcher.exe'
check "--exe Impulsum17Launcher.exe"              [ "$(arg_of exe)" = Impulsum17Launcher.exe ]
check "--image C:\\gate\\imp\\Impulsum17Launcher.exe" [ "$(arg_of image)" = 'C:\gate\imp\Impulsum17Launcher.exe' ]

# ----------------------------------------------------------- (b) not gated
ctl code=10
run "(b) game.exe starts game.exe, script says refuse" -- 'C:\gate\game\game.exe' --spawn 'C:\gate\game\game.exe'
check "(b) the script never ran"                  [ "$(calls)" = 0 ]
check "(b) no CXGATE line"                        hasnot "$OUT" CXGATE
check "(b) both ran"                              has "$OUT" "SPAWN ok exit=0x00000000"

# ------------------------------------------------------------ (c) refusal
ctl code=10
run "(c) script exits 10" -- 'C:\gate\game\game.exe' --spawn 'C:\gate\fifa17\FIFA17.exe'
check "(c) the script ran once"                   [ "$(calls)" = 1 ]
check "(c) CreateProcess failed with 0xC0F17A7E"  has "$OUT" "SPAWN failed err=317 status=0xc0f17a7e"
check "(c) FIFA17.exe's main never ran"           hasnot "$OUT" 'GPROBE main exe=C:\gate\fifa17'
check "(c) CXGATE status=exit=10"                 has "$OUT" "status=exit=10 "
ctl code=10
run "(c) script exits 10, FIFA17.exe from the command line" -- 'C:\gate\fifa17\FIFA17.exe'
check "(c) main never ran (command line)"         hasnot "$OUT" 'GPROBE main'
ctl code=3
run "(c) script exits 3: fail open" -- 'C:\gate\game\game.exe' --spawn 'C:\gate\fifa17\FIFA17.exe'
check "(c) exit 3 lets it run"                    has "$OUT" "SPAWN ok exit=0x00000000"

# ------------------------------------------------------------ (d) timeout
ctl code=10 sleep=30
run "(d) script sleeps 30 s, CX_FIFA_GATE_TIMEOUT=2" CX_FIFA_GATE_TIMEOUT=2 -- \
    'C:\gate\game\game.exe' --spawn 'C:\gate\fifa17\FIFA17.exe'
TMS="${${OUT##*status=timeout=2s ms=}%%[^0-9]*}"
check "(d) status=timeout=2s"                     has "$OUT" "status=timeout=2s"
check "(d) a WARN says so"                        has "$OUT" "warn CXGATE exe=FIFA17.exe script still running after 2 s"
check "(d) stopped within 2.0-2.3 s ($TMS ms)"    eval '[ "${TMS:-0}" -ge 2000 ] && [ "${TMS:-0}" -le 2300 ]'
check "(d) FIFA17.exe ran anyway (fail open)"     has "$OUT" "SPAWN ok exit=0x00000000"
check "(d) the script was stopped mid-sleep"      eval 'has "$LOGTXT" SLEEPING && hasnot "$LOGTXT" EXITING'
check "(d) its sleep child was stopped too"       eval '! pgrep -f "^sleep 30$" >/dev/null'

# ---------------------------------------------------------- (e) kill switch
ctl code=10
run "(e) CX_FIFA_GATE=0" CX_FIFA_GATE=0 -- 'C:\gate\game\game.exe' --spawn 'C:\gate\fifa17\FIFA17.exe'
check "(e) the script never ran"                  [ "$(calls)" = 0 ]
check "(e) no CXGATE line"                        hasnot "$OUT" CXGATE
check "(e) FIFA17.exe ran"                        has "$OUT" "SPAWN ok exit=0x00000000"

# ------------------------------------------------------- (f) no script
rm -f "$GATE"
run "(f) no cx-fifa17-gate beside ntdll.so" -- 'C:\gate\game\game.exe' --spawn 'C:\gate\fifa17\FIFA17.exe'
check "(f) one WARN"                              [ "$(print -r -- "$OUT" | grep -c 'warn CXGATE exe=FIFA17.exe no script at')" = 1 ]
check "(f) FIFA17.exe ran"                        has "$OUT" "SPAWN ok exit=0x00000000"
install_stub

# ------------------------------------------------ (h) FIFA17.exe -> FIFA17.exe
ctl code=0
run "(h) FIFA17.exe starts FIFA17.exe" -- 'C:\gate\fifa17\FIFA17.exe' --spawn 'C:\Games\FIFA 17\FIFA17.exe'
check "(h) two gated starts"                      [ "$(calls)" = 2 ]
check "(h) the second has --parent FIFA17.exe"    [ "$(arg_of parent 2)" = FIFA17.exe ]

# ----------------------------------------------------------- (i) overhead
ctl fast=1 code=0
N=20
run "(i) fast path: $N x game.exe starts FIFA17.exe (gated)" -- 'C:\gate\game\game.exe' --repeat $N --spawn 'C:\gate\fifa17\FIFA17.exe'
GATED="${${OUT##*mean_create_ms=}%% *}"
GMS=( ${(f)"$(print -r -- "$OUT" | sed -n 's/.* ms=\([0-9]*\)$/\1/p')"} )
run "(i) baseline: $N x game.exe starts game.exe (not gated)" -- 'C:\gate\game\game.exe' --repeat $N --spawn 'C:\gate\game\game.exe'
PLAIN="${${OUT##*mean_create_ms=}%% *}"
print -r -- "   CreateProcess mean: gated $GATED ms, not gated $PLAIN ms; CXGATE ms: ${GMS[*]}"
check "(i) $N gated starts logged"                [ "${#GMS}" = $N ]

print -r -- ""
if [ "$FAILS" = 0 ]; then
    print -r -- "ALL $CHECKS CHECKS PASSED"
    exit 0
fi
print -r -- "$FAILS OF $CHECKS CHECKS FAILED"
exit 1
