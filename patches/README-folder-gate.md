# Folder gate: ntdll asks a script before FIFA 17 starts

`crossover-26.3-fifa17-folder-gate.patch`, unix ntdll only
(`dlls/ntdll/unix/loader.c`). `build.sh` applies it last, after the game
profiles. This file covers the C half. The script it runs,
`fixes/cx-fifa17-gate`, decides what happens to the folder; the design for
both halves is in `../HANDOFF-launcher-coexistence.md` (sections 3.3 to 3.6).

## Why

Aurora.exe, CAS and Impulsum17 all change files in the one FIFA 17 folder,
and each leaves it in a state the others cannot run from. Every one of them
starts `FIFA17.exe` with `CreateProcess`, inside Wine, so the start of that
process is the one moment every launch path shares, including the ones that
never pass through a CrossOver shortcut (`cas://` links, self-updates, a
launcher left in the tray). The policy changes whenever a launcher does, so
it lives in a zsh script that `--repair` can replace. The C part only
collects facts, runs the script, and acts on one exit code.

## What it does

`cx_folder_gate()` runs once per process, in `start_main_thread`, straight
after `cx_profile_init()`. At that point the image path, the process
parameters (environment included) and the server connection exist, and no
guest code or DLL has loaded.

1. Takes the file name from `ImagePathName` and compares it, case-insensitively,
   with `FIFA17.exe` and `Impulsum17Launcher.exe`. Any other exe returns
   here, so other processes pay only this name compare.
2. Returns if `CX_FIFA_GATE` starts with `0`. Set it in `cxbottle.conf`
   `[EnvironmentVariables]`, the same way as `CX_GAME_PROFILES`.
3. The script is `cx-fifa17-gate` in the directory of the loaded
   `ntdll.so` (Wine's own `ntdll_dir`, which `dladdr` resolves at start-up).
   If it is missing, the gate logs one warning and returns.
4. Collects the facts:
   - **parent**: `NtQueryInformationProcess(ProcessBasicInformation)` gives
     `InheritedFromUniqueProcessId`. Then `NtOpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`
     and `ProcessImageFileNameWin32` give the parent's image path, and the
     gate keeps its file name. If any step fails, or there is no parent, the
     value is `-`. These calls already work at this point; the tests below
     get the right parent every time.
   - **envnames**: the name of every variable in the PEB environment block
     (`ProcessParameters->Environment`), joined with commas, never a value.
     The block is read directly because a child's unix environment does not
     carry the parent's Windows variables (CW Hack 24717). The per-drive
     `=C:` entries are skipped because they are not variables. A name that
     contains a comma is skipped too, because the list could not carry it.
5. Starts the script with `posix_spawn`:

       /bin/zsh -f <ntdll dir>/cx-fifa17-gate --exe <exe file name>
           --image <full Windows image path> --parent <parent file name or ->
           --envnames <NAME,NAME,...> --prefix <WINEPREFIX (config_dir)>
           --winpid <Windows pid, decimal>

   - `POSIX_SPAWN_CLOEXEC_DEFAULT`, so none of Wine's descriptors reaches
     the script, the wineserver socket above all. Only stdin, stdout and
     stderr exist in the child, and all three are `/dev/null`.
   - The environment is `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `LANG`
     (each copied only if set) and `CX_FIFA_GATE_FROM_WINE=1`. Nothing else
     is passed, so no secrets and no `WINE*` variables reach the script.
   - The working directory is `/`. The script runs in its own process group,
     with an empty signal mask and every signal at its default action (Wine's
     mask and ignored signals are not inherited).
   - `-f` stops zsh from reading `~/.zshenv`, which could otherwise change
     `PATH` and the rest of the environment above.
6. Polls `waitpid(WNOHANG)` every 20 ms for up to `CX_FIFA_GATE_TIMEOUT`
   seconds (default 60; a missing, zero or invalid value means 60). On a
   timeout it sends `SIGTERM` to the script's whole process group, waits up to
   1 s, sends `SIGKILL` if anything is still running, reaps the script and
   goes on.
7. **Exit status 10** ends the process with
   `NtTerminateProcess(NtCurrentProcess(), 0xC0F17A7E)`, before the game runs
   any code. The launcher's `CreateProcess` fails with that status:
   `GetLastError()` is 317 and `RtlGetLastNtStatus()` is `0xC0F17A7E`.
   A process started straight from the unix command line exits with unix
   status 126 (`0x7E`).

`WINEDEBUG=+cxgate` (or `--debugmsg +cxgate` with CrossOver's `bin/wine`)
logs one line per gated process:

    CXGATE exe=FIFA17.exe parent=game.exe envnames=130 status=exit=0 ms=26

`status` is `exit=N`, `signal=N`, `timeout=Ns`, `spawn-failed` or `lost`
(`waitpid` failed). It also logs a warning (shown only with `+cxgate`, since
Wine's warning class is off by default) for a missing script, a failed
spawn, a timeout and a refusal.

`ntdll.so` contains the string `CX_FOLDER_GATE_V1`, so setup.sh can tell a
gated build from an older one, the way `CX_GAME_PROFILES` marks the profiles
build: `LC_ALL=C grep -aqF CX_FOLDER_GATE_V1 ntdll.so`.

## Failure policy

Only exit status 10 stops a launch. In every other case the launch goes on
exactly as it would without the gate: any other status, a signal, a missing
script, a failed spawn, a failed `waitpid`, or a timeout. Deciding when to
refuse is the script's job (`../HANDOFF-launcher-coexistence.md` 3.6). The
launcher's `CreateProcess` waits for the gate, because the parent's
`NtCreateUserProcess` waits for the child to finish its init.

## Things that are easy to get wrong

**The parent can be a Wine program.** Started from CrossOver's `bin/wine`
(and so from a CrossOver shortcut), `FIFA17.exe` has the parent
`winewrapper.exe`. Under `cmd /c start` the parent is `start.exe`, and under
`cmd /c` it is `cmd.exe`. The script has to count all three as "started
directly".

**The script runs under Rosetta.** The Wine process is x86_64, and macOS
starts a universal binary from it, `/bin/zsh` included, as x86_64 too.
Everything the script runs inherits that. Neither
`posix_spawnattr_setbinpref_np` nor `setarchpref_np` changed this when
called from a translated process. It costs about 5 ms per process start
(zsh starts in 10 ms translated and 5 ms native), so the C side leaves it
alone. If the script ever runs many tools, it can use
`arch -arm64e <tool>` for them.

**The 20 ms poll sets the floor.** A script that exits at once is noticed at
the first 20 ms tick at the earliest.

## Testing it

`tests/gate/gate_probe.c` prints `GPROBE main ...` as the first thing its
`main` does, which proves the process got that far. With `--spawn <exe>` or
`--cmd <command line>` it also starts a child, times the `CreateProcess`
call, and prints the child's exit code or the failed call's `GetLastError`
and `RtlGetLastNtStatus`. `--setenv` puts a variable in the child's
environment, and `--repeat N` averages N starts.

`tests/gate/run_gate_tests.sh <copy of the app> [bottle]` copies the probe in
as `FIFA17.exe`, `Impulsum17Launcher.exe` and `game.exe`. It sets aside any
real `cx-fifa17-gate` beside the copy's `ntdll.so` and puts in a stub that
logs its argv, its environment and `lsof -p $$`, then exits with whatever the
test asks for (or sleeps first). Each scenario runs in a fresh wineserver
session. The script prints `ALL n CHECKS PASSED` or names each failure. Run
it against a `cp -cR` copy of the app, with the copy's `ntdll.so` installed
the way setup.sh installs it (lib64 rpath, ad-hoc signature, app re-signed),
and in a throwaway bottle.

Results 2026-10-12, CrossOver 26.3 sources, with the shipped
`fixes/x86_64-unix/ntdll.so` (same LC_UUID as the tested copy), in a clone
of the app and a throwaway bottle. All 44 checks passed:

- (a) Arguments. `game.exe` started `C:\Games\FIFA 17\FIFA17.exe` with
  `FUT17_GAME_CODE` and `IMPULSUM_TOKEN` set. The stub got
  `--exe FIFA17.exe`, the full image path with its spaces, `--parent game.exe`,
  the bottle as `--prefix` and the child's own pid as `--winpid`. The
  `--envnames` list had both names, no `=`, and the same count as the
  CXGATE line (132). Neither value appeared anywhere in the stub's log. Under
  `cmd /c start /wait` the parent was `start.exe`, under `cmd /c` it was
  `cmd.exe`, and from the `wine` command line it was `winewrapper.exe`.
  `Impulsum17Launcher.exe` was gated, with its own name and path.
- (b) `game.exe` starting `game.exe`, with the stub set to refuse: the
  script never ran, there was no CXGATE line, and both processes ran.
- (c) Exit 10: `CreateProcess` failed with err 317 and status `0xc0f17a7e`.
  The child's `main` never printed, from a parent and from the command line
  alike. Exit 0 and exit 3 let the child run.
- (d) The stub slept 30 s with `CX_FIFA_GATE_TIMEOUT=2`: `status=timeout=2s`
  and a warning, gated in 2028 ms, the child ran, and the stub's `sleep 30`
  child was gone too (the whole process group was stopped).
- (e) `CX_FIFA_GATE=0`, with the stub set to refuse: the script never ran,
  there was no CXGATE line, and the child ran.
- (f) No script: one `no script at "<path>"` warning, and the child ran.
- (g) `lsof` in the script showed only `/dev/null` on 0 to 2, `/` as the
  working directory, the script itself and zsh's own redirections (fd 10 and
  up). No socket, pipe, kqueue or shared memory, and no Wine or bottle file.
  The environment was the four variables above, plus what zsh and `env` set
  themselves (`SHLVL`, `PWD`, `OLDPWD`, `LOGNAME`, `_`). The script led its
  own process group.
- (h) `FIFA17.exe` starting `FIFA17.exe`: two gated starts, and the second
  had `--parent FIFA17.exe`.
- (i) Fast path, with a stub that exits 0 at once, 20 starts each: a gated
  `CreateProcess` averaged 55.1 ms against 27.6 ms for `game.exe`, so the
  gate adds about 28 ms per start. The CXGATE times were 20 to 30 ms. A
  second run gave 56.2 ms against 32.5 ms.
- (j) `tests/profiles/run_probes.sh` against the same copy, with an exit-0
  stub in place: `ALL 95 CHECKS PASSED`, the same as before the gate.

The patch applies cleanly after all thirteen others to a pristine
`crossover-sources-26.3.0` tree, and gives a `loader.c` identical to the one
built here.

Not tested: the real script, real launchers and the real game. These tests
cover the C half against a stub.
