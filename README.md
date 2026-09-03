# FIFA 17 on a Mac (Apple silicon)

FIFA 17 and its Aurora17 server do not run in stock CrossOver on an Apple
silicon Mac. This package fixes that.

It works on a **copy** of CrossOver called **CrossOver-FIFA**. Your own
CrossOver and all your other bottles are never touched.

## What you need

- A Mac with Apple silicon (M1 or newer), macOS 14 or newer
- **CrossOver 26.3** exactly. Other versions are refused.
- Apple's command line tools. In Terminal: `xcode-select --install`
- Your own copy of FIFA 17
- Your own copy of Aurora17 (not needed for offline play)

## Before you install

1. Put the **FIFA 17** folder and the **Aurora17** folder in your Downloads folder.
2. In CrossOver, make a new bottle: **+** → **Windows 10 64-bit** → name it exactly `Aurora17`.
3. Aurora17 only: select the bottle, choose **Run Command**, browse to
   `Aurora17Connector.exe`, and tick the box to save it as a launcher.
4. Quit CrossOver with **⌘Q**.

The installer stops if the bottle is not there. SETUP.md explains each step.

## Install

Pick one:

| I want | Double-click |
|---|---|
| Online play, Ultimate Team, career, everything (needs Aurora17) | **START HERE.command** |
| Single player only, no Aurora17 | **START HERE offline.command** |

If macOS says "Apple could not verify..." go to **System Settings → Privacy &
Security**, scroll down, and click **Open Anyway**. You only do this once.

The installer prints every step. If it stops, the reason is in **red** with the
fix right under it.

## Play

- **Normal install:** open **CrossOver-FIFA**, open the Aurora17 bottle, press **PLAY FIFA 17**.
- **Offline install:** open **CrossOver-FIFA**, open the Aurora17 bottle, click
  **FIFA 17 (offline)**. Or double-click **PLAY FIFA 17 offline.command** and
  keep that window open while you play.

Always use **CrossOver-FIFA**, not your normal CrossOver. They look the same,
but only the copy has the fixes.

## Stop

Quit however you like. A background helper cleans up leftovers 45 seconds after
CrossOver quits. To clean up right now, double-click **Stop.command**.

Note: closing a bottle window does not quit CrossOver. It stays in the menu
bar. Press **⌘Q** to quit it properly.

## Something wrong?

```sh
./setup.sh --verify     # checks everything, changes nothing
./setup.sh --unstick    # bottle stuck loading forever? quit CrossOver, run this
./setup.sh --bundle     # zips logs for a bug report (no passwords or keys)
```

**SETUP.md** has the full troubleshooting guide.

## Undo

Double-click **Uninstall.command**. It removes the CrossOver-FIFA copy and the
one file it put in your Aurora17 folder. Your own CrossOver was never changed.

## Files

| | |
|---|---|
| `START HERE.command` | install (normal, with Aurora17) |
| `START HERE offline.command` | install (single player, no Aurora17) |
| `PLAY FIFA 17 offline.command` | play offline without opening CrossOver |
| `Stop.command` | quit game, Aurora and CrossOver cleanly |
| `Uninstall.command` | undo everything |
| `setup.sh`, `uninstall.sh` | what the .command files run |
| `fixes/` | the files that go into the CrossOver copy, with source and checksums |
| `aurora17/` | the PowerShell stand-in and certificate Aurora needs |
| `patches/` | the Wine source changes the fixes were built from |
| `build.sh` | rebuilds `fixes/` from source |
| `SETUP.md` | full guide and troubleshooting |
| `NOTICE.md` | licences: MIT for our parts, LGPL for the Wine parts |

Nothing here belongs to anyone else. No game, no CrossOver, no Aurora17.
