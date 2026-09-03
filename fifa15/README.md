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
2. `./fifa15/fifa15-offline.sh apply "/path/to/FIFA 15"`
3. In the CrossOver copy, run `fifa15.exe` from the game folder in the `Aurora15` bottle.

Verified 2026-09-02 on Apple silicon (CrossOver 26.3.0): language screen, title, intro, attract-mode
match. Keyboard, controller, sound and saves are not yet play-tested.

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

## What does not work yet
`--smoke` and `--report` know FIFA 17 only and refuse `--fifa15`. `./setup.sh --fifa15 --verify`
checks the CrossOver copy and the bottle. `./setup.sh --unstick` also frees a FIFA 15 game or
connector left behind with CrossOver closed, and port 3216. `uninstall.sh` removes the CrossOver
copy as usual.

Engineering record: `patches/README-fifa15-wine-fixes.md` (and, outside the repo, the FIFA 15
checkpoint documents).
