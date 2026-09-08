# FIFA 15 — experimental

FIFA 15 (the 2015 CPY release) runs on the same patched CrossOver as FIFA 17. What it needs on
top, and where each piece is:

| piece | where |
|---|---|
| Wine patch `crossover-26.3-topdown-alloc-limit.patch` (the start-up crash) | applied by `build.sh`; inert unless the bottle sets `CX_TOPDOWN_LIMIT` |
| bottle settings `CX_TOPDOWN_LIMIT=0x1ffffffff`, `CX_GRAPHICS_BACKEND=d3dmetal`, `WINE_SIMULATE_WRITECOPY=1`, the `dinput8` override, windowed `fifasetup.ini` | `./setup.sh --fifa15` (makes the `Aurora15` bottle too) |
| the language-screen freeze | `fifa15-offline.sh` (this folder), *or* Aurora15Connector's own Origin stand-in |

## Without Aurora (offline)

1. `./setup.sh --fifa15` — makes the CrossOver copy if needed, the `Aurora15` bottle, and its settings.
2. Close FIFA 15 and Aurora15Connector, then run `./fifa15/fifa15-offline.sh apply "/path/to/FIFA 15"`.
3. In the CrossOver copy, run `fifa15.exe` from the game folder in the `Aurora15` bottle.

Verified 2026-09-02 on Apple silicon (CrossOver 26.3.0): language screen, title, intro, attract-mode
match. Keyboard, controller, sound and saves are not yet play-tested.

If Aurora15Connector previously replaced `ItsAMe_Origin.dll`, the patch now
looks for a verified original in `ItsAMe_Origin.dll.aurora15.bak` or
`ItsAMe_Origin.dll.offline-orig`. It patches that original and preserves the
installed DLL as `ItsAMe_Origin.dll.before-offline-<sha256>`. An unrecognized
DLL without a verified original backup is left unchanged.

Confirmed 2026-09-07: direct launch froze at language selection with a
connector-installed DLL; patching the verified Aurora15 backup allowed the
user to pass language selection. No game or emulator DLL is included here.

## With Aurora15Connector
Run `Aurora15Connector-*.exe` in the `Aurora15` bottle after `./setup.sh --fifa15`. The connector
replaces `ItsAMe_Origin.dll` with its own version, checks the original's hash first, and hosts the
Origin service the game's SDK connects to on 127.0.0.1:3216 — so the freeze does not occur with it,
and `fifa15-offline.sh` must be **reverted** before running it. Sign-in, content download, game
launch and the Origin handshake work under CrossOver; the `dinput8` override the setup sets is what
lets its EA-MITM hook load. **Never press the connector's "Repair connection" button** under
Wine: `GetExtendedTcpTable` reports no owner for port 3216 there, so Repair kills the connector's own
`Aurora15Client.exe` and the game then hangs at the flag (UPSTREAM.md A5). If a second connector says
port 3216 is in use, quit CrossOver and run `./setup.sh --unstick`.

## Frozen at the language screen

`Both games.command` configures the bottles; it does not launch FIFA 15 or
apply its offline patch. A successful setup does not check the Origin connection
that the game waits for at the language screen.

1. Check how you started the game: Aurora15Connector's PLAY button or `fifa15.exe` directly.
2. For direct offline play, close the game and run `./fifa15/fifa15-offline.sh check`.
   If it reports the original version or a verified original backup, follow the
   offline steps above. Supply the game-folder path if it is outside Downloads.
3. For Aurora15Connector, use its PLAY button and keep its client running.
   If you applied the offline patch, revert it before using the connector.
   Do not use its **Repair connection** button; see the known failure above.

These are recorded causes of the same symptom, not confirmation of the cause
on another machine. If it still freezes, record the launch method, the DLL check
output and any connector error before changing more settings.

## Checks and cleanup

`./setup.sh --fifa15 --verify` (or **diagnostics/13 Check the install (FIFA 15).command**)
now reports whether the installed DLL is offline-patched and whether a verified
original is available. It also checks that the current background cleanup helper
is loaded. These checks change no game files and do not test a live launch.

Rerunning **FIFA 15.command** refreshes the background helper even when the
shared app already exists. To update just cleanup, run `./setup.sh --agent`.
The helper checks every 30 seconds, allows a 45-second grace period after the
last observed CrossOver session, requests termination, and force-closes
stragglers after 10 seconds. It rescans for children created during shutdown.
It pauses while CrossOver is open or a script holds a deliberate playing session.
**Stop.command** performs cleanup immediately.

## What does not work yet
`--smoke`, `--report` and `--bundle` know FIFA 17 only and refuse `--fifa15`. `./setup.sh --fifa15 --verify`
checks the CrossOver copy and the bottle. `./setup.sh --unstick` also frees a FIFA 15 game or
connector left behind with CrossOver closed, and port 3216. `uninstall.sh` removes the shared CrossOver
copy for both games; bottles and saves remain.

Engineering record: `patches/README-fifa15-wine-fixes.md` (and, outside the repo, the FIFA 15
checkpoint documents).
