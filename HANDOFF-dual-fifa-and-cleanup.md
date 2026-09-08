# Handoff: publish dual FIFA support, offline recovery, and cleanup fixes

Continue by reviewing the pending diff, committing the implementation, and pushing `main` to `origin`. The user explicitly authorized the push. **Nothing has been committed or pushed yet.** This handoff was requested before the session limit; it records the state on 2026-09-08.

## Resume steps

1. Read `git status --short --branch` and `git diff`; include untracked implementation files in the review. Completion: account for the changes described below while retaining main's newer FIFA 17 fixes.
2. Run `python3 -m unittest discover -s tests -v`, `git diff --check`, and the two checksum manifests if code or payloads changed. Completion: tests pass and every shipped payload matches its manifest. Results at handoff are recorded below.
3. Stage the implementation and documentation explicitly, then inspect `git diff --cached --stat` and the staged diff. Keep this operational handoff local unless its publication is desired. Completion: no local game DLLs, temporary fixtures, or unrelated files are staged.
4. Commit and push `main` normally to `origin`. The user already approved this; no additional permission question is needed. Git writes and networking require sandbox escalation here. Completion: the pushed remote main hash equals the new local commit; do not force-push over concurrent work.
5. Tell the user the commit and test result, with the next action `./setup.sh --agent` to refresh their installed cleanup helper. Completion: distinguish published script changes from local helper installation and live gameplay verification.

## Repository and authorization

Working directory is the FIFA-17-crossover-patch-work folder in the user's Downloads. Branch: `main`. Remote: `git@github.com:Mokhtar25/FIFA-17-auroa-local-crossover-patch.git`.

At handoff, HEAD and fetched `origin/main` both equal `8b092a39e903e8784d5a0477dda4bcb3f9f11a24`. `git fetch origin` completed successfully during this session. A normal fetch first failed because `.git/FETCH_HEAD` is read-only in the sandbox; retrying with `sandbox_permissions: require_escalated` was approved and succeeded. The fetch process has finished.

The user initially requested main support both FIFA 15 and FIFA 17 in separate bottles, using the `fifa15` branch as the source. They then confirmed our local fix for FIFA 15's language-selection freeze worked and said: “lets push this for other users as well.” They also asked to add it to checks and fix launchers/connectors remaining as strays after quitting CrossOver. Preserve all three requests.

User prefers short, actionable updates, progress counts, and one small next action. Subagents are not authorized by default. No subagents were used. Relevant skills already read: diagnosing-bugs and writing-for-agents. Do not replace main wholesale with the older FIFA 15 branch: it would remove recent crash diagnostics and Aurora17 shim fixes.

## Implementation in the working tree

### Both games on main

Selected FIFA 15 branch files were copied into this working tree: `Both games.command`, `FIFA 15.command`, `setup-both.sh`, `fifa15/`, the gdiplus DLL and its source patch, and FIFA 15 investigation patch records. Main's existing Aurora17 shim and resolver binaries were preserved. The ntdll/topdown patch was already on main.

`setup.sh` defaults to separate `Aurora17` and `Aurora15` bottles. It supports `FIFA17_BOTTLE` and `FIFA15_BOTTLE`; single-game legacy `AURORA_BOTTLE` still works. It rejects selecting the other game's bottle, including canonical path/case collisions and a bottle containing the other profile's environment setting. The combined installer rejects ambiguous `AURORA_BOTTLE`, selects each game explicitly, validates its arguments, forwards a custom CrossOver source path to both invocations, and checks both even when the first verification fails. Its `--offline` means FIFA 17 offline plus normal FIFA 15 setup; FIFA 15's game-folder patch is a separate explicit action.

Both profiles now install `gdiplus.dll` as part of the shared payload, preventing a FIFA 17 reinstall from removing Aurora15Connector's exit-crash fix. FIFA 17-specific launch/log/bundle actions are refused for FIFA 15. Documentation and `NOTICE.md` describe the combined package and the additional LGPL Wine binary.

### Confirmed language-screen fix

The user launched `fifa15.exe` directly. The original offline helper refused the installed DLL hash:

```text
5b141fb03c6f50228e48ddaf8dfb49428194a1f01be1a63c826c5bce4dec487a
```

Read-only inspection found the same file in this Mac's `~/Downloads/FIFA 15`, with `ItsAMe_Origin.dll.aurora15.bak` matching the supported original:

```text
4463ce725e2af8b858095511801901630355fe1eba66fbb8fc7a5ba3b0f0300b
```

We staged the three-byte patch from that original, verified the result, and installed it after an approved filesystem escalation while no FIFA 15/connector processes were running. The patched hash is:

```text
e6b423c536823be4379681dad8bd9d7334e4db53a394025b86b7af7a8a9cda71
```

The previous installed DLL was preserved locally as `ItsAMe_Origin.dll.before-offline-5b141fb03c6f5022`; the Aurora backup was untouched, and `ItsAMe_Origin.dll.offline-orig` was created. The user then said “it worked.” These local game files belong outside the repository and must not be shipped. The user confirmed passing the freeze, not an exhaustive test of simultaneous matches, controllers, sound, or saves.

The repository helper now implements this recovery: `fifa15/fifa15-offline.sh apply` patches only an exact-hash original, using `.offline-orig` or `.aurora15.bak` when the installed file differs. It preserves the installed file with its full SHA in the backup filename, refuses invalid/conflicting backups, verifies the patched output before replacement, and checks that the game and connector are closed. It supports `FIFA15_DIR`, re-execs under zsh, and rejects extra arguments. Revert restores a verified original and also preserves the current file.

The helper's `check` reports installed-file status and available verified backup without changing anything. `f15_check_game` now displays this status instead of calling an unknown DLL “probably Aurora15Connector's own” and marking it OK. FIFA 15 verification invokes that check. Original/unrecognized installed files produce an offline-readiness note rather than automatically failing an otherwise valid connector setup. `diagnostics/13 Check the install (FIFA 15).command` runs the game profile's verification.

### Connector cleanup

Two regression tests failed before these fixes: a child spawned during termination was left running, and successful FIFA 15 bottle-only setup never refreshed the cleanup agent. Both now pass.

The generated background helper in `setup.sh` rescans twice after its initial client/server shutdown to catch late children. Existing TERM-then-KILL behavior, GUI/session-hold checks, and bounded waits remain. The helper runs every 30 seconds with a 45-second grace based on the last observed GUI/held session. It does not act while CrossOver stays open merely because a bottle window was closed.

The helper now persists the installer's `CX_BOTTLE_PATH` in a shell-quoted header, since launchd does not inherit that environment. Successful bottle-only setup refreshes the agent as well as full installs. `CLEANUP_REVISION=2` identifies the new helper. `verify_cleanup_agent` checks helper presence/version, configured bottle location, and the loaded launchd job; verification reports the repair command `./setup.sh --agent` when needed. The new helper has **not** been installed into this user's Library during these latest changes.

Cleanup tests simulate processes and signals; they exercise the real generated cleanup lifecycle but do not kill live programs. Existing process ownership classifiers were not redesigned. Do not describe the tests as live confirmation of every connector shutdown case.

## Validation and remaining review

`python3 -m unittest discover -s tests -v`: **23 tests passed**, about 3 seconds. Test files are `tests/test_scripts.py`, `tests/test_fifa15_offline.py`, and `tests/test_cleanup.py`. Coverage includes separate profiles, failure propagation, bottle aliases, backup recovery/refusal/revert, read-only status, process guards, cleanup rescan/escalation, GUI reopening, session holds, grace, custom bottle paths, and agent refresh/version/loading checks.

Offline tests use synthetic data and substitute only fixture hash constants into a temporary copy of the actual helper. No game binaries are fixtures. Gameplay was confirmed separately by the user on their real installation.

Immediately before writing this handoff, `git diff --check` passed. All nine entries in `fixes/SHA256SUMS` and all three in `aurora17/SHA256SUMS` passed using `shasum -a 256 -c SHA256SUMS` from each directory. Documentation changed after the last complete unit test run; executable code did not.

The next session should finish the final diff review, including untracked files, then commit/push. `git diff --stat` alone omits those untracked files. There is no pending tool process, Git merge, commit, or push to resume. No public release asset has been created; the authorized destination is the main branch.
