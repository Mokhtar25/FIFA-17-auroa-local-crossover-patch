# A saved copy of what a double-click command printed. Sourced by every
# wrapper that runs setup.sh. Without it the only record of a failed setup was
# the Terminal window, which the tester had usually closed by the time anyone
# asked what it said; "1 Collect diagnostics" now picks these files up.
#
#   source "$PWD/lib/runlog.zsh"
#   runlog_start <label> "${0:A}" "$@"
#
# runlog_start runs the whole wrapper again as a child, with its output shown
# live and saved to ~/Library/Logs/FIFA-CrossOver/<label>-YYYYmmdd-HHMMSS.log,
# then exits with the child's exit code. Nothing else changes: stdin stays the
# terminal (the wrappers end with "read -r _", and setup.sh asks questions),
# the window shows the same text, and colours stay on screen through
# CX_COLOR=1, which setup.sh and the wrappers honour when their output is a
# pipe. The saved file has the colour codes taken out.
#
# When the log folder cannot be written it returns at once and the wrapper
# carries on exactly as it did before there were logs. Inside the child it
# also returns at once (CX_RUNLOG_ACTIVE), which is what keeps it from
# starting itself again.

RUNLOG_PACKAGE="${${(%):-%x}:A:h:h}"
RUNLOG_KEEP=20

# This package's version as setup.sh --version says it: line 1 of VERSION,
# with the commit from line 2 when a zip made by git archive has one.
runlog_version() {
    local v="" id=""
    { IFS= read -r v; IFS= read -r id; } 2>/dev/null < "$RUNLOG_PACKAGE/VERSION" || true
    [[ "$id" == *'$Format'* ]] && id=""
    print -r -- "${v:-unknown}${id:+ ($id)}"
}

runlog_start() {
    local label="$1" self="$2"; shift 2
    [ -z "${CX_RUNLOG_ACTIVE:-}" ] || return 0
    local dir="${CX_RUNLOG_DIR:-$HOME/Library/Logs/FIFA-CrossOver}"
    mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ] || return 0
    local stamp log raw n=1 rc
    stamp="$(date '+%Y%m%d-%H%M%S')"
    log="$dir/$label-$stamp.log"
    # Two runs in one second (a test, or a double double-click) get -2, -3.
    while [ -e "$log" ]; do n=$((n + 1)); log="$dir/$label-$stamp-$n.log"; done
    raw="$(mktemp "$dir/.$label-XXXXXX" 2>/dev/null)" || return 0
    {
        print -r -- "==== $label, $(date '+%Y-%m-%d %H:%M:%S %z')"
        print -r -- "macOS     $(sw_vers -productVersion 2>/dev/null) build $(sw_vers -buildVersion 2>/dev/null), $(uname -m)"
        print -r -- "patch     $(runlog_version)"
        print -r -- "command   ${self:t}${*:+ ${(j: :)${(q-)@}}}"
        print -r -- "folder    ${self:h}"
        print -r -- "===="
    } > "$raw" 2>/dev/null || { rm -f "$raw"; return 0; }

    [ -t 1 ] && export CX_COLOR=1
    # tee -i: Ctrl-C stops setup.sh, which then prints how far it got; tee
    # has to live through that to show it and save it. This shell also stays
    # for the footer, so it only notes the signal and goes on waiting.
    trap ':' INT
    CX_RUNLOG_ACTIVE=1 /bin/zsh "$self" "$@" 2>&1 | tee -ai "$raw"
    rc=${pipestatus[1]}
    trap - INT

    # The file without colour codes, cursor moves or the screen clear, and
    # with the footer the window never shows.
    {
        LC_ALL=C sed -E $'s/\e\\[[0-9;?]*[A-Za-z]//g; s/\e[()][A-Za-z0-9]//g; s/\e//g; s/\r$//' "$raw"
        print -r -- ""
        print -r -- "==== exit code $rc, $(date '+%Y-%m-%d %H:%M:%S %z')"
    } > "$log" 2>/dev/null || true
    rm -f "$raw"

    # Only the newest few: one is written for every double-click.
    local old; local -a logs
    logs=( "$dir"/*.log(N) )
    if (( ${#logs} > RUNLOG_KEEP )); then
        for old in ${(f)"$(/bin/ls -t -- "${logs[@]}" 2>/dev/null | tail -n +$((RUNLOG_KEEP + 1)))"}; do
            [ -n "$old" ] && rm -f -- "$old"
        done
    fi
    exit "$rc"
}
