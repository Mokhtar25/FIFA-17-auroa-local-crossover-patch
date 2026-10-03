# FIFA 15, FIFA 16 + FIFA 17 on a Mac (Apple silicon)

FIFA 17 and its Aurora17 server do not run in stock CrossOver on an Apple
silicon Mac. This package fixes that.

It works on a **copy** of CrossOver called **CrossOver-FIFA**. Your own
CrossOver and all your other bottles are never touched.

**FIFA 15** (the 2015 CPY release) runs on that same copy. That half is
**experimental**: it reaches the title screen and an attract-mode match, but
controller, sound and saves are not play-tested yet. `fifa15/README.md` says
exactly where it stands, and SETUP.md has the section for it.

**FIFA 16** runs on that same copy too, in its own `FIFA16` bottle, and is
**experimental and unreliable for now**. It needs your own FIFA 16 game
folder; this package never ships a game. The stutter in play is fixed. The
endless loading after the language screen is not reliably fixed: the fix
matches one exact memory address, and the game puts that buffer somewhere
different from one launch to the next. When it lands in the right place the
game reaches the menus; when it does not, the game loops at the language
screen, or freezes loading a match. Quitting and launching again sometimes
gets a run through, but nothing guarantees it. SETUP.md, "FIFA 16", has the
details.

## What you need

- A Mac with Apple silicon (M1 or newer), macOS 14 or newer
- **CrossOver 26.3** exactly. Other versions are refused.
- Apple's command line tools. In Terminal: `xcode-select --install`
- Your own copy of whichever games you want to play
- Aurora17 for FIFA 17 online play; Aurora15Connector for FIFA 15 online play

## Before you install

**FIFA 15 only?** Put your game folder in Downloads, quit CrossOver, and
double-click **FIFA 15.command**. **FIFA 16?** The same, with your **FIFA 16**
folder and **FIFA 16.command**. The steps below are for FIFA 17 or both games.

1. Put the **FIFA 17** folder and the **Aurora17** folder in your Downloads folder.
   Doing FIFA 15 too? Put the **FIFA 15** folder there as well.
2. Normal install (with Aurora17): in CrossOver, make a new bottle: **+** →
   **Windows 10 64-bit** → name it exactly `Aurora17`.
3. Normal install: select the bottle, choose **Run Command**, browse to
   `Aurora17Connector.exe`, and tick the box to save it as a launcher. That
   launcher is how you press PLAY.
4. Quit CrossOver with **⌘Q**.

The normal install stops if the bottle is not there. SETUP.md explains each step.

Steps 2 and 3 are only for the normal install. The offline install makes the
`Aurora17` bottle for you if it is not there, and FIFA 15 makes its `Aurora15`
bottle for you as well. Quit CrossOver first either way.

## Install

Pick one:

| I want | Double-click |
|---|---|
| Online play, Ultimate Team, career, everything (needs Aurora17) | **START HERE.command** |
| Single player only, no Aurora17 | **START HERE offline.command** |
| Both games, in separate Aurora17 and Aurora15 bottles | **Both games.command** |
| FIFA 15 only (makes the copy first if it is not there) | **FIFA 15.command** |
| FIFA 16 (makes the copy first if it is not there) | **FIFA 16.command** |

If macOS says "Apple could not verify..." go to **System Settings → Privacy &
Security**, scroll down, and click **Open Anyway**. You only do this once.

Already have FIFA 17 installed? **Both games.command** copies CrossOver again
(about 1 GB, which is how an update reaches the copy) and sets both bottles up.
If the FIFA 17 half is not finished, FIFA 15 is still set up, and the message
at the end says what FIFA 17 is missing.
For FIFA 17 offline plus FIFA 15, run `./setup-both.sh --offline`.

Updating an install you already have, or fixing one that stopped working:
double-click **Fix my installation.command**. It quits CrossOver cleanly,
replaces any fix file in the CrossOver-FIFA copy that is missing or out of
date and re-signs it, sets the Aurora17 bottle up again (settings, overrides,
hosts, menu entries, and the WebView2 runtime the RebornFUT launcher needs if
it is not there yet), has the game's own loader write a fresh licence file,
and checks the lot. CrossOver is not copied again, so it takes a minute or
two. From Terminal it is `./setup.sh --repair`; for FIFA 15, `./setup.sh
--fifa15` brings that bottle up to date, and `./setup.sh --fifa16` does the
same for FIFA 16.

The **RebornFUT** launcher needs two more fixes from version 3.1.45 on, the
point where it became a WebView2 app. Both are CrossOver bugs its browser
window walks into, and both are now fixed here: `ole32.dll`, because
`RevokeDragDrop` followed a drop target into the browser process and crashed
the launcher as it opened, and `win32u.so`, because CrossOver's cross-process
window flush sent a message while holding the USER lock and killed the browser
process a moment later. An install made before those files existed does not
have them: double-click **Fix my installation.command**, which puts them into
the CrossOver-FIFA copy and re-signs it without copying CrossOver again.
The blank window that was left after those two is fixed as well, and not by a
patch. Every Edge WebView2 runtime from version 100 on draws through a
DirectX and DirectComposition path Wine cannot drive; runtimes up to 99 draw
through plain GDI, which CrossOver handles. So setup puts Microsoft's
fixed-version runtime 99.0.1150.52 in the bottle (a 165 MB download, once) and
points the launcher at it with one bottle setting. The evergreen runtime the
launcher installs for itself is left alone and simply not used, and every
other WebView2 app on your Mac is unaffected. `HANDOFF-rebornfut-launcher.md`
has the version-by-version evidence.

The **CAS** launcher draws with that same runtime, and setup fixes the two
places it stopped after that: a `powershell.exe` in the bottle that answers
its device check (without it CAS says "Install the latest CAS launcher to
verify this device." and sign-in never starts), and a small app in
`~/Applications`, **CAS Link (CrossOver)**, that brings the browser's
`cas://` sign-in link back to the bottle. `CAS_SUPPORT=skip` leaves both out.
SETUP.md, "9c. The CAS launcher", says what each one does and what it sends.

Custom bottle names: `FIFA17_BOTTLE="My FIFA 17" FIFA15_BOTTLE="My FIFA 15" ./setup-both.sh`.
Use distinct bottles. Unset `AURORA_BOTTLE` before running the combined installer.

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
  bottle instead. The patch can recover from Aurora15Connector’s verified
  original backup and preserves the currently installed DLL. Never press the connector's **Repair connection** button —
  under Wine it kills the connector's own client and the game hangs.
  `fifa15/README.md` covers both ways in full.
- **FIFA 16:** open **CrossOver-FIFA**, open the **FIFA16** bottle, choose
  **Run Command** and run `fifa16.exe` from your FIFA 16 folder (setup prints
  its exact path, for example `Y:\Downloads\FIFA 16\fifa16.exe`). Tick the box
  to save it as a launcher and next time it is one click. There is no launcher
  program: the game runs on its own, offline.

Always use **CrossOver-FIFA**, not your normal CrossOver. They look the same,
but only the copy has the fixes.

For online matches the installer also points each bottle at Microsoft's own C
runtime instead of Wine's. Without that, the maths differs from every Windows
player's in the last bit and the match disconnects at kick-off. FIFA 17 has
Microsoft's copies in its game folder already; FIFA 15 has none, so the
installer puts a pair beside `fifa15.exe` — taken from your FIFA 17 folder, or
installed from the VS2012 redistributable in FIFA 15's own `_Redist` folder.
Nothing is downloaded for that, and no file of the game's own is changed.

## Stop

Quit with **Stop.command**. It closes the game, then Aurora, then CrossOver,
in the order that leaves no strays and no held ports. It shuts every bottle in
CrossOver down, not only the FIFA ones.

Nothing from this package runs in the background. Earlier versions installed a
helper that woke every 30 seconds for as long as you owned the Mac; it is gone,
and installing or running `./setup.sh --agent` takes it off if you have one.
A leftover connector costs a held port until the next launch, and Stop.command
or `./setup.sh --unstick` clears it whenever you like.

Note: closing a bottle window does not quit CrossOver. It stays in the menu
bar. Press **⌘Q** to quit it properly.

## Something wrong?

For FIFA 17, double-click **Diagnostics.command**. It collects the logs a bug report needs
into one zip in the **diagnostics** folder and opens that folder for you.

For FIFA 15, use **diagnostics/13 Check the install (FIFA 15).command**.
If it freezes at the language screen, see [the launch-mode check](fifa15/README.md#frozen-at-the-language-screen).
For FIFA 16, use **diagnostics/16 Check the install (FIFA 16).command**.

Every other check and repair is a double-click in there too — check the
install, unstick a bottle, repair the signature, run a smoke test — one
`.command` file each, listed in `diagnostics/README.md`. Nothing there needs
Terminal, and the ones that only look at things say so.

The same actions from Terminal, if you prefer:

```sh
./setup.sh --verify     # checks everything, changes nothing
./setup.sh --unstick    # bottle stuck loading forever? quit CrossOver, run this
./setup.sh --bundle     # zips FIFA 17 logs for a bug report (no passwords or keys)
./setup.sh --play-log   # FIFA 17 crashes on every PLAY? identifies the module

./setup.sh --fifa15            # set FIFA 15 up
./setup.sh --fifa15 --verify   # check the FIFA 15 setup, change nothing
./setup.sh --fifa16            # set FIFA 16 up
./setup.sh --fifa16 --verify   # check the FIFA 16 setup, change nothing
./setup-both.sh --verify       # check both games
```

**SETUP.md** has the full troubleshooting guide.

## Undo

Double-click **Uninstall.command**. It removes the shared CrossOver-FIFA copy and the
one file it put in your Aurora17 folder, disabling this setup for **every game**.
Your bottles and saves remain. Your own CrossOver was never changed.

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
| `FIFA 16.command` | set FIFA 16 up on its own (experimental) |
| `PLAY FIFA 17 offline.command` | play offline without opening CrossOver |
| `Stop.command` | quit game, Aurora and CrossOver cleanly |
| `Diagnostics.command` | collect the logs for a bug report |
| `Fix my installation.command` | repair or update an install without copying CrossOver again |
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
