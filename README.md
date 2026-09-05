# FIFA 17 on a Mac (Apple silicon)

FIFA 17 and its Aurora17 server do not run in stock CrossOver on an Apple
silicon Mac. This package fixes that.

It works on a **copy** of CrossOver called **CrossOver-FIFA**. Your own
CrossOver and all your other bottles are never touched.

**FIFA 15** (the 2015 CPY release) runs on that same copy. That half is
**experimental**: it reaches the title screen and an attract-mode match, but
controller, sound and saves are not play-tested yet. `fifa15/README.md` says
exactly where it stands, and SETUP.md has the section for it.

## What you need

- A Mac with Apple silicon (M1 or newer), macOS 14 or newer
- **CrossOver 26.3** exactly. Other versions are refused.
- Apple's command line tools. In Terminal: `xcode-select --install`
- Your own copy of FIFA 17
- Your own copy of Aurora17 (not needed for offline play)
- FIFA 15 only: your own copy of FIFA 15, in your Downloads folder

## Before you install

1. Put the **FIFA 17** folder and the **Aurora17** folder in your Downloads folder.
   Doing FIFA 15 too? Put the **FIFA 15** folder there as well.
2. In CrossOver, make a new bottle: **+** → **Windows 10 64-bit** → name it exactly `Aurora17`.
3. Aurora17 only: select the bottle, choose **Run Command**, browse to
   `Aurora17Connector.exe`, and tick the box to save it as a launcher.
4. Quit CrossOver with **⌘Q**.

The installer stops if the bottle is not there. SETUP.md explains each step.

Only the `Aurora17` bottle is made by hand. The `Aurora15` bottle FIFA 15 needs
is made for you.

## Install

Pick one:

| I want | Double-click |
|---|---|
| Online play, Ultimate Team, career, everything (needs Aurora17) | **START HERE.command** |
| Single player only, no Aurora17 | **START HERE offline.command** |
| Both games, in the one copy | **Both games.command** |
| FIFA 15 only (makes the copy first if it is not there) | **FIFA 15.command** |

If macOS says "Apple could not verify..." go to **System Settings → Privacy &
Security**, scroll down, and click **Open Anyway**. You only do this once.

The installer prints every step. If it stops, the reason is in **red** with the
fix right under it.

## Play

- **Normal install:** open **CrossOver-FIFA**, open the Aurora17 bottle, press **PLAY FIFA 17**.
- **Offline install:** open **CrossOver-FIFA**, open the Aurora17 bottle, click
  **FIFA 17 (offline)**. Or double-click **PLAY FIFA 17 offline.command** and
  keep that window open while you play.
- **FIFA 15:** open **CrossOver-FIFA**, open the **Aurora15** bottle, and run
  **Aurora15Connector**. Without Aurora, run
  `./fifa15/fifa15-offline.sh apply` once and then run `fifa15.exe` from that
  bottle instead. Never press the connector's **Repair connection** button —
  under Wine it kills the connector's own client and the game hangs.
  `fifa15/README.md` covers both ways in full.

Always use **CrossOver-FIFA**, not your normal CrossOver. They look the same,
but only the copy has the fixes.

## Stop

Quit however you like. A background helper cleans up leftovers 45 seconds after
CrossOver quits. To clean up right now, double-click **Stop.command**.

Note: closing a bottle window does not quit CrossOver. It stays in the menu
bar. Press **⌘Q** to quit it properly.

## Something wrong?

Double-click **Diagnostics.command**. It collects the logs a bug report needs
into one zip in the **diagnostics** folder and opens that folder for you.

Every other check and repair is a double-click in there too — check the
install, unstick a bottle, repair the signature, run a smoke test — one
`.command` file each, listed in `diagnostics/README.md`. Nothing there needs
Terminal, and the ones that only look at things say so.

The same actions from Terminal, if you prefer:

```sh
./setup.sh --verify     # checks everything, changes nothing
./setup.sh --unstick    # bottle stuck loading forever? quit CrossOver, run this
./setup.sh --bundle     # zips logs for a bug report (no passwords or keys)

./setup.sh --fifa15            # set FIFA 15 up
./setup.sh --fifa15 --verify   # check the FIFA 15 setup, change nothing
./setup-both.sh --verify       # check both games
```

**SETUP.md** has the full troubleshooting guide.

## Undo

Double-click **Uninstall.command**. It removes the CrossOver-FIFA copy and the
one file it put in your Aurora17 folder. Your own CrossOver was never changed.

If you used the FIFA 15 offline patch, undo that one yourself first —
`./fifa15/fifa15-offline.sh revert` — because it changed a file inside your own
game folder, which Uninstall never touches.

## Files

| | |
|---|---|
| `START HERE.command` | install (normal, with Aurora17) |
| `START HERE offline.command` | install (single player, no Aurora17) |
| `Both games.command` | install FIFA 17, then set FIFA 15 up |
| `FIFA 15.command` | set FIFA 15 up on its own (experimental) |
| `PLAY FIFA 17 offline.command` | play offline without opening CrossOver |
| `Stop.command` | quit game, Aurora and CrossOver cleanly |
| `Diagnostics.command` | collect the logs for a bug report |
| `Uninstall.command` | undo everything |
| `diagnostics/` | one `.command` per check and repair, and where their zips, reports and logs are written |
| `setup.sh`, `uninstall.sh`, `setup-both.sh` | what the .command files run |
| `fifa15/` | the FIFA 15 notes, and the offline patch for the crack's Origin emulator |
| `fixes/` | the files that go into the CrossOver copy, with source and checksums |
| `aurora17/` | the PowerShell stand-in and certificate Aurora needs |
| `patches/` | the Wine source changes the fixes were built from |
| `build.sh` | rebuilds `fixes/` from source |
| `SETUP.md` | full guide and troubleshooting |
| `NOTICE.md` | licences: MIT for our parts, LGPL for the Wine parts |

Nothing here belongs to anyone else. No game, no CrossOver, no Aurora17.
