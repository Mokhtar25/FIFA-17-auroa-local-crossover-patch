# FIFA 15 — experimental

FIFA 15 (the 2015 CPY release) runs on the same patched CrossOver as FIFA 17. What it needs on
top, and where each piece is:

| piece | where |
|---|---|
| Wine patch `crossover-26.3-topdown-alloc-limit.patch` (the start-up crash) | applied by `build.sh`; inert unless the bottle sets `CX_TOPDOWN_LIMIT` |
| bottle settings `CX_TOPDOWN_LIMIT=0x1ffffffff`, `CX_GRAPHICS_BACKEND=d3dmetal`, `WINE_SIMULATE_WRITECOPY=1`, windowed `fifasetup.ini` | `AURORA_GAME=fifa15 ./setup.sh --bottle` |
| the language-screen freeze | `fifa15-offline.sh` (this folder), *or* Aurora15Connector's own Origin stand-in |

## Without Aurora (offline)
1. Make a 64-bit Windows 10 bottle called `Aurora15` in the CrossOver copy that `setup.sh` made.
2. `AURORA_GAME=fifa15 ./setup.sh --bottle`
3. `./fifa15/fifa15-offline.sh apply "/path/to/FIFA 15"`
4. In the CrossOver copy, run `fifa15.exe` from the game folder in the `Aurora15` bottle.

Verified 2026-09-02 on Apple silicon (CrossOver 26.3.0): language screen, title, intro, attract-mode
match. Keyboard, controller, sound and saves are not yet play-tested.

## With Aurora15Connector
Not yet tried under CrossOver. The connector replaces `ItsAMe_Origin.dll` with its own version,
checks the original's hash first, and hosts the Origin service the game's SDK connects to on
127.0.0.1:3216 — so the freeze should not occur with it, and `fifa15-offline.sh` must be
**reverted** before running it. What the connector needs inside a bottle beyond the settings
above is unknown until it is run there.

## What does not work yet
`setup.sh --verify/--report/--smoke` know FIFA 17 only; `--smoke` and `--report` refuse
`AURORA_GAME=fifa15`. `--verify` checks the CrossOver copy and the three bottle settings, but
still prints its Aurora17 lines (stand-in, EA names, licence, version.dll) as BAD for a FIFA 15
bottle; ignore those. `uninstall.sh` removes the CrossOver copy as usual.

Engineering record: `patches/README-fifa15-wine-fixes.md` (and, outside the repo, the FIFA 15
checkpoint documents).
