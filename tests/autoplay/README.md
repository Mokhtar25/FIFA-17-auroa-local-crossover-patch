# autoplay: drive the Aurora launcher and check how each game runs

Needs: macOS, `swiftc`, Screen Recording + Accessibility permission for the terminal app
(screenshots, System Events window rects, CGEvent clicks). Screenshots land in `out/`.

    ./play-game.sh 17 --unstick --authorize    # whole flow, 180 s watch, prints a verdict (12|15|16|17|21)
    ./play-game.sh 21 --unstick                # launcher already signed in: Not now, game pill, Play, watch
    ./play-game.sh 16 --unstick --no-play      # only open the game's page and print its Play state
    ./play-game.sh 12 --helper                 # FIFA 12: run Aurora 12's helper directly (see below)
    ./close-game.sh 21                         # press the red button of the game window (windowed games)
    ./key 49 0.4                               # hold a key (space) for 0.4 s; lib.sh `press_key <code>` is a quick tap
    ./play-fifa17.sh ...                       # old name, same as play-game.sh 17

Pieces (each usable alone):

| script | what it does |
|---|---|
| `launcher-start.sh [--unstick]` | start `Aurora15Connector.exe` in the Aurora17 bottle, wait for its window, bring it to front |
| `launcher-state.sh` | Play-button state from `launcher.log` (Discord presence lines filtered), pids, screenshot |
| `launcher-click.sh <button>` | screenshot, refuse unless the launcher is frontmost, click a named button (`signin`, `play`/`play17`, `fwnotnow`, `game12`..`game21`, `exit`, `trouble`); positions are fractions of the window rect, `--dry` only prints |
| `discord-authorize.sh` | clicks Discord's "Authorize" only if the front browser window title says Authorize; never types anything |
| `play-game.sh <game>` | start, sign in, answer the in-launcher firewall prompt with "Not now", press Play, press PLAY on the game's own Steampunks window, watch cpu/rss/graphics libs, verdict |

Sign-in: if Discord shows a login form, 2FA or a captcha, the flow stops (exit 3) and you sign in by
hand; re-run afterwards, it starts from "already signed in" (the launcher keeps the sign-in 7 days).

Verdict: backend from `lsof` while running and `vmmap` at the end (`D3DMetal.framework` wanted, no
`wined3d.dll`), exited or still running, CRASH lines in the game's `fut17shim.log`
(`~/Downloads/FIFA 17 a/`, falls back to `/Volumes/Untitled/FIFA 17a/`), and "frozen-looking" =
CPU above 200 % in the last 3 samples and the game window unchanged over 4 s.
`click` and `pixel` are compiled from the `.swift` files on first use.

## Per game (checked 2026-11-14, launcher 1.2.190)

| game | process (`ps`) | start window | notes |
|---|---|---|---|
| 21 | `Z:\...\FIFA 21\FIFA21.exe` | none | splash "Press START or SPACE" -> settings file LOAD (Return) -> "Hospitality settings" (Down+Return = keep in-game settings) -> main menu after ~15 s of loading |
| 15 | `Z:\...\FIFA 15\fifa15.exe` | none | splash with autosave notice, then intro movies that loop; no menu UI appeared after Return/Space/Esc/click |
| 12 | `Z:\...\FIFA 12\Game\fifa.exe` (under `cdb.exe`) | none | the launcher's Play runs `futlink repair` (about 70 s), then `futlink play` (works since 469d6da; before it stopped at repair, exit 22); `--helper` runs `futlink play` directly. Fullscreen, no title bar (close-game.sh does not work, use `./setup.sh --unstick`) |
| 16 | - | - | Play says "Server Migrating" (Closed), game folder not set, connector not installed: state only |

The Play button state of a page is only logged on a change, so `play_state` says `Unknown` before the first press on pages 12 and 15
(the screenshot `out/page-*.png` / `after-game*.png` shows it). The launcher closes itself when a windowed game is closed.
Games that poll the keyboard may miss a quick `press_key` tap; use `./key` (press and hold).
