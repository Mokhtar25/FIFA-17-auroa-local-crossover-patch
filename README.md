# FIFA 17 on a Mac — CrossOver fixes for Apple silicon

FIFA 17 and its Aurora17 local server do not run on an Apple silicon Mac under
stock CrossOver. This package fixes that in a **copy** of CrossOver. Your own
CrossOver, and every other bottle in it, are left alone.

## You need

- A Mac with Apple silicon (M1 or newer), macOS 14 or newer
- **CrossOver 26.3** exactly. The installer refuses any other version.
- Apple's command line tools. In Terminal: `xcode-select --install`
- Your own FIFA 17 and Aurora17, set up in a bottle called `Aurora17` (SETUP.md shows how)

## Install

1. Download this package as a zip and unzip it.
2. Double-click **START HERE.command**.
3. Open **CrossOver-FIFA** (the copy, not your normal CrossOver), open the
   Aurora17 bottle, and press **PLAY FIFA 17**.

If macOS refuses to open the file ("Apple could not verify..."): open
System Settings → Privacy & Security, scroll down, and click **Open Anyway**.
On macOS 14 and older, right-click the file → Open works too.
Or skip that: open Terminal, type `zsh ` (with a space), drag
`START HERE.command` into the window, and press Return.

The installer prints what it does at every step. If it has to stop, the reason
is in **red**, followed by the steps to fix it.

## Without Aurora17 (single player only)

If you only want to play — kick-off, career, tournaments, skill games — you do
not need Aurora17 at all. Double-click **START HERE offline.command** instead of
`START HERE.command`. It installs the CrossOver copy, the fixes and the bottle
settings, and nothing that talks to EA: no PowerShell stand-in, no EA name
redirects, no certificate.

Then play with **PLAY FIFA 17 offline.command**, which starts the game's own
loader inside the bottle. Keep that window open while you play — it is what
tells the background cleanup the game is running on purpose.

Online, FUT and anything needing an EA account do not work in an offline
install; that is what Aurora17 is for. Adding it later is just installing
Aurora17 and double-clicking `START HERE.command`, which fills in the missing
pieces in the same copy.

## When you finish playing

Double-click **Stop.command** instead of closing CrossOver's window. Closing the
window (the red dot) leaves FIFA 17 and its Aurora17 programs running with
nothing on screen: they keep the bottle locked and sit on the ports Aurora
needs, so the next **PLAY FIFA 17** says a port is already in use, or hangs on
the loading screen forever. `Stop.command` closes the game, then Aurora, then
CrossOver, in that order.

Forgetting is not fatal. The installer also sets up a background cleanup that
clears leftovers by itself 45 seconds after CrossOver quits. It never touches a
running session, a non-Wine program, or another Wine app's bottles, and
`./uninstall.sh` removes it.

## If something goes wrong

```sh
./setup.sh --verify     # checks everything, changes nothing, marks problems BAD
./setup.sh --bundle     # zips the logs for a bug report (no passwords or keys in it)
```

SETUP.md has the full troubleshooting table.

## Undo

Double-click **Uninstall.command**. It deletes the CrossOver-FIFA copy and the
PowerShell stand-in it put in your Aurora17 folder. Your own CrossOver was
never changed.

## What is in here

| | |
|---|---|
| `START HERE.command`, `Uninstall.command` | double-click to install, or to undo |
| `Stop.command` | double-click to quit CrossOver cleanly when you finish playing |
| `START HERE offline.command`, `PLAY FIFA 17 offline.command` | install and play without Aurora17 — single player only |
| `setup.sh`, `uninstall.sh` | what those two run |
| `fixes/` | the seven files that go into the CrossOver copy, with source and checksums |
| `aurora17/` | the PowerShell stand-in and the certificate Aurora needs, with source and checksums |
| `patches/` | the Wine source changes the fixes were built from |
| `build.sh` | rebuilds `fixes/` from source, so you need not take ours on trust |
| `SETUP.md` | full instructions and troubleshooting |
| `NOTICE.md` | licences: MIT for our parts, LGPL for the Wine parts |

Nothing here belongs to anyone else: no game, no CrossOver, no Aurora17.
