#!/bin/zsh
# Runs profile_probe.exe under every name and setting the game-profile patch
# has to tell apart, prints one line per process -- what the probe saw from
# the inside (PROBE) next to what ntdll logged it decided (CXPROFILE) -- and
# checks both against the matrix in patches/README-game-profiles.md. Exits 1
# if any row is not what the table predicts, 0 if every row is.
#
#   ./run_probes.sh /path/to/CrossOver-FIFA-copy.app [bottle]
#
# Point it at a COPY of the app carrying the ntdll.so under test
# (cp -c makes one in a second), never at the app you play with. The bottle
# (default zz-profiles-test) must be a throwaway one: this writes AppDefaults
# keys into it and kills its wineserver between runs, so each run boots a
# fresh session with its own environment (PF_PAE_ENABLED is per session).
set -eu

APP="${1:?usage: run_probes.sh /path/to/app-copy.app [bottle]}"
BOTTLE="${2:-zz-profiles-test}"
HERE="${0:A:h}"
W="$APP/Contents/SharedSupport/CrossOver"
B="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
[ -x "$W/bin/wine" ] || { print -r -- "no wine in $APP"; exit 2 }
[ -d "$B/drive_c" ] || { print -r -- "no bottle $BOTTLE"; exit 2 }
case "$APP" in /Applications/*) print -r -- "refusing to run against an installed app; use a copy"; exit 2 ;; esac

PROBE="$HERE/profile_probe.exe"
DRRF="$HERE/../drbp/drrf_test.exe"

stage() {  # <dir under drive_c> <name> [exe]
    mkdir -p "$B/drive_c/$1"
    cp "${3:-$PROBE}" "$B/drive_c/$1/$2"
}
# One directory per name: the Mac file system ignores case, so fifa15.exe and
# FIFA15.EXE cannot share one.
for n in fifa15.exe fifa16.exe FIFA17.exe _fifa17.exe FIFA21.exe Aurora.exe \
         msedgewebview2.exe game.exe; do
    stage "probe/$n.d" "$n"
done
stage probe/upper FIFA15.EXE
stage "Games/FIFA 15" fifa15.exe
stage "Launcher Dir" Aurora.exe
[ -f "$DRRF" ] && stage probe/drrf fifa16.exe "$DRRF"

kill_session() { WINEPREFIX="$B" "$W/bin/wineserver" -k 2>/dev/null || true; }
wine() { "$W/bin/wine" --bottle "$BOTTLE" "$@"; }

reg_clear() { wine reg delete 'HKCU\Software\Wine\AppDefaults' /f >/dev/null 2>&1 || true; }
reg_set() {  # <exe> <value> <data>
    wine reg add "HKCU\\Software\\Wine\\AppDefaults\\$1\\CrossOver-FIFA" /v "$2" /d "$3" /f >/dev/null 2>&1
}

# ------------------------------------------------------------ expectations
# A setting triple is "<dr_trap> <topdown limited 0|1> <dstfix on|off>".
FAILS=0; CHECKS=0
typeset -A ENVV

# The built-in table, by exe name without case.
table_of() {
    case "${(L)1}" in
        fifa15.exe) print -r -- "0 1 off" ;;
        fifa16.exe) print -r -- "3 0 on" ;;
        fifa17.exe|_fifa17.exe|fifa21.exe|fifa21_trial.exe) print -r -- "2 0 off" ;;
    esac
}
# The bare variables of the run in ENVV.
env_settings() {
    local dr="${ENVV[CX_DR_TRAP]:-0}" lim=0 dst=off
    [ -n "${ENVV[CX_TOPDOWN_LIMIT]+x}" ] && lim=1
    [ -n "${ENVV[CX_FIFA16_DSTFIX]+x}" ] && dst=on
    print -r -- "${dr:0:1} $lim $dst"
}
# PF_PAE_ENABLED, per session: CX_PF_PAE=1 or a bare CX_DR_TRAP=3.
env_pae() {
    [[ "${ENVV[CX_PF_PAE]:-}" == 1* || "${ENVV[CX_DR_TRAP]:-}" == 3* ]] && print 1 || print 0
}
# What <exe> should get in the run in ENVV. SCENARIO is "plain" or
# "appdefaults" (the keys reg_set writes below).
expected_for() {
    local exe="$1" t s; local -a f
    s="$(env_settings)"
    [ "${ENVV[CX_GAME_PROFILES]:-}" = 0 ] && { print -r -- "$s"; return }
    t="$(table_of "$exe")"
    [ -n "$t" ] && s="$t"
    if [ "$SCENARIO" = appdefaults ]; then
        f=( ${=s} )
        case "${(L)exe}" in
            game.exe)           s="$(table_of fifa15.exe)" ;;        # Profile fifa15
            fifa17.exe)         s="$(env_settings)" ;;               # Profile none
            _fifa17.exe)        s="3 ${f[2]} ${f[3]}" ;;             # DrTrap 3
            fifa16.exe)         s="${f[1]} ${f[2]} off" ;;           # Fifa16DstFix off
            aurora.exe)         s="${f[1]} 1 ${f[3]}" ;;             # TopdownLimit
            msedgewebview2.exe) ;;                                   # Profile fifa99: ignored
        esac
    fi
    print -r -- "$s"
}

fail() { FAILS=$((FAILS+1)); print -r -- "   FAIL $*"; }

# Checks the captured output of one run for one exe.
check_exe() {  # <output> <exe>
    local out="$1" exe="$2" want pae cx probe dr lim dst m top v
    local -a w
    want="$(expected_for "$exe")"; w=( ${=want} ); pae="$(env_pae)"
    CHECKS=$((CHECKS+1))
    cx="$(print -r -- "$out" | grep -F "CXPROFILE exe=$exe " | head -1 || true)"
    probe="$(print -r -- "$out" | grep -F "PROBE exe=$exe " | head -1 || true)"
    [ -n "$cx" ] || { fail "$exe: no CXPROFILE line (want $want)"; return }
    [ -n "$probe" ] || { fail "$exe: no PROBE line (want $want)"; return }
    # What ntdll says it decided.
    dr="${${cx##*dr_trap=}%% *}"; v="${${cx##*topdown=}%% *}"; dst="${${cx##*dstfix=}%% *}"
    [ "$v" = 0 ] && lim=0 || lim=1
    [ "$dst" = off ] || dst=on
    [ "$dr $lim $dst" = "$want" ] || fail "$exe: CXPROFILE says '$dr $lim $dst', want '$want'"
    # What the process saw from the inside.
    m=0
    [[ "$probe" == *" xbp=1 "* ]] && m=2
    [[ "$probe" == *" selfbp=1 "* ]] && m=3
    top="${${probe##*topdown=}%% *}"; top="${top#0x}"; top="${top#0X}"
    (( 16#$top < 16#200000000 )) && lim=1 || lim=0
    [[ "$probe" == *" dstfix=fixed"* ]] && dst=on || dst=off
    v="${${probe##*pae=}%% *}"
    # Mode 1 (probe) behaves like 0 from the inside.
    [ "${w[1]}" = 1 ] && w[1]=0
    [ "$m $lim $dst" = "${(j: :)w}" ] || fail "$exe: PROBE saw '$m $lim $dst', want '${(j: :)w}'"
    [ "$v" = "$pae" ] || fail "$exe: PROBE pae=$v, want $pae"
}

capture() {  # <env...> -- <windows path> [args]; output in OUT
    local -a envs
    while [ "$1" != -- ]; do envs+=( "$1" ); shift; done
    shift
    OUT="$(env "${envs[@]}" "$W/bin/wine" --bottle "$BOTTLE" --debugmsg +cxprofile --wait-children "$@" 2>&1 \
        | grep -E '^PROBE|^SPAWN|CXPROFILE exe=(fifa|FIFA|_fifa|Aurora|msedge|game|drrf)|^DRRF|^\[[0-9]\]' \
        | sed -E 's/^[0-9a-f]{4}:trace:cxprofile:cx_profile_init //' || true)"
}

set_envv() {
    local kv
    ENVV=()
    for kv in "$@"; do [ "$kv" = X_NONE=1 ] || ENVV[${kv%%=*}]="${kv#*=}"; done
}

run() {  # <label> <env...> -- <windows path> [args]; checks every exe in CHECK
    local label="$1"; shift
    local -a envs; local e
    while [ "$1" != -- ]; do envs+=( "$1" ); shift; done
    shift
    print -r -- "== $label  [${envs[*]:-no env}]  $1 ${@:2}"
    set_envv "${envs[@]}"
    capture "${envs[@]}" -- "$@"
    print -r -- "$OUT" | sed 's/^/   /'
    for e in $CHECK; do check_exe "$OUT" "$e"; done
}

ALL=( 'C:\probe\fifa15.exe.d\fifa15.exe' 'C:\probe\upper\FIFA15.EXE' 'C:\probe\fifa16.exe.d\fifa16.exe'
      'C:\probe\FIFA17.exe.d\FIFA17.exe' 'C:\probe\_fifa17.exe.d\_fifa17.exe' 'C:\probe\FIFA21.exe.d\FIFA21.exe'
      'C:\probe\Aurora.exe.d\Aurora.exe' 'C:\probe\msedgewebview2.exe.d\msedgewebview2.exe'
      'C:\probe\game.exe.d\game.exe' )

matrix() {  # <label> <env...>
    local label="$1" p; shift
    kill_session
    for p in $ALL; do CHECK=( "${p##*\\}" ); run "$label" "$@" -- "$p"; done
}

kill_session
reg_clear
SCENARIO=plain
matrix "no env"                    X_NONE=1
matrix "Aurora17-style env"        CX_DR_TRAP=2
matrix "FIFA16-style env"          CX_DR_TRAP=3 CX_FIFA16_DSTFIX=0
matrix "Aurora15-style env"        CX_TOPDOWN_LIMIT=0x1ffffffff
matrix "profiles off, no env"      CX_GAME_PROFILES=0
matrix "profiles off, Aurora17"    CX_GAME_PROFILES=0 CX_DR_TRAP=2
matrix "profiles off, FIFA16"      CX_GAME_PROFILES=0 CX_DR_TRAP=3 CX_FIFA16_DSTFIX=0
matrix "CX_PF_PAE=1"               CX_PF_PAE=1

kill_session
reg_set game.exe Profile fifa15
reg_set FIFA17.exe Profile none
reg_set _fifa17.exe DrTrap 3
reg_set fifa16.exe Fifa16DstFix off
reg_set Aurora.exe TopdownLimit 0x1ffffffff
reg_set msedgewebview2.exe Profile fifa99
SCENARIO=appdefaults
matrix "AppDefaults, Aurora17 env" CX_DR_TRAP=2
matrix "AppDefaults, profiles off" CX_GAME_PROFILES=0 CX_DR_TRAP=2
# An empty value says nothing: fifa16.exe is back to the table's dst fix.
kill_session
reg_clear
reg_set fifa16.exe Fifa16DstFix ''
reg_set fifa16.exe DrTrap ''
SCENARIO=plain
CHECK=( fifa16.exe ); run "AppDefaults, empty values" CX_DR_TRAP=2 -- 'C:\probe\fifa16.exe.d\fifa16.exe'
reg_clear

kill_session
SCENARIO=plain
CHECK=( Aurora.exe fifa15.exe )
run "parent->child" CX_DR_TRAP=2 -- 'C:\Launcher Dir\Aurora.exe' --spawn 'C:\Games\FIFA 15\fifa15.exe'
[[ "$OUT" == *"SPAWN exit=0"* ]] || fail "parent->child: the child did not run to exit 0"

if [ -f "$B/drive_c/probe/drrf/fifa16.exe" ]; then
    kill_session
    CHECK=(); run "drrf_test as fifa16.exe, no env (mode 3 from the table)" X_NONE=1 -- 'C:\probe\drrf\fifa16.exe'
    CHECKS=$((CHECKS+1))
    [[ "$OUT" == *"DRRF: 7/7"* ]] || fail "drrf_test as fifa16.exe with no env: want 7/7"
    kill_session
    CHECK=(); run "drrf_test as fifa16.exe, profiles off (stock)" CX_GAME_PROFILES=0 -- 'C:\probe\drrf\fifa16.exe'
    CHECKS=$((CHECKS+1))
    [[ "$OUT" == *"DRRF: "* && "$OUT" != *"DRRF: 7/7"* ]] \
        || fail "drrf_test with profiles off: want the stock result (not 7/7)"
fi
kill_session

print -r -- ""
if [ "$FAILS" = 0 ]; then
    print -r -- "ALL $CHECKS CHECKS PASSED"
    exit 0
fi
print -r -- "$FAILS OF $CHECKS CHECKS FAILED"
exit 1
