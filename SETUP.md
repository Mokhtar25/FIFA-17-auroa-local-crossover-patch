# FIFA 17 on a Mac — setup guide

This package fixes CrossOver so FIFA 17 runs on an Apple silicon Mac. Without
the fixes the game restarts forever, hangs on a black loading screen, has no
sound, says the servers are shut down, or Aurora's **PLAY** button does nothing.

**Your CrossOver is not changed.** The installer makes a copy called
**CrossOver-FIFA**, puts seven small files in it, and adds one file to your
Aurora17 folder. Every other bottle you own keeps running on your normal
CrossOver.

- The copy needs about 1 GB of disk.
- Nothing is downloaded.
- The game is never modified.
- Both CrossOvers share the same bottles. Never open the same bottle in both at once.

---

## Contents

1. [What you need](#what-you-need)
2. [Set up the bottle](#set-up-the-bottle) — you do this part, the installer cannot
3. [Install](#install) — [normal](#normal-install-with-aurora17) or [offline](#offline-install-no-aurora17)
4. [Play](#play)
5. [Stop and clean up](#stop-and-clean-up)
6. [Troubleshooting](#troubleshooting) — start at [Check these first](#check-these-first)
7. [Manual install](#manual-install-step-by-step) — the same thing by hand
8. [Reference](#reference) — version notes, uninstall, file list

**How to read the troubleshooting section:** every problem is a red box, and
the fix is the green box right under it.

> [!CAUTION]
> 🔴 **Red = the error or symptom you see.**

> [!TIP]
> 🟢 **Green = what to do about it.**

---

## What you need

| | |
|---|---|
| Apple silicon Mac | M1 or newer. The installer stops on an Intel Mac. |
| macOS 14 or newer | tested on macOS 15 |
| **CrossOver 26.3** | exactly this version. Not 26.2, not 26.4. See [Why the version matters](#why-the-version-matters). |
| Apple's command line tools | in Terminal: `xcode-select --install` |
| FIFA 17 | build `17.0.3175939.0`, the only one supported |
| Aurora17 | with its bottle set up (see below). Not needed for offline play. |

CrossOver, the game and Aurora17 are not included and cannot be shared.

---

## Set up the bottle

> Give FIFA 17 a bottle of its own. Put nothing else in it.

You do not copy the game into the bottle and you do not install it. Every
bottle already sees your whole home folder as drive `Y:`. So if the game is in
Downloads, Windows already sees it:

```
~/Downloads/Aurora17        is   Y:\Downloads\Aurora17
~/Downloads/FIFA 17         is   Y:\Downloads\FIFA 17
```

**1. Make a bottle.** In CrossOver: **+** (New Bottle) → **Windows 10 64-bit**
→ name it `Aurora17`. If you use another name, tell the installer:

```
AURORA_BOTTLE="My Bottle" ./setup.sh
```

**2. Put FIFA 17 (and Aurora17) under your home folder.** Extract the Aurora17
zip as its own folder. `~/Downloads/Aurora17` and `~/Downloads/FIFA 17` are the
defaults the installer looks for. Other locations:

```
AURORA_DIR=/path/to/Aurora17 AURORA_GAME_DIR='/path/to/FIFA 17' ./setup.sh
```

**Offline install? Stop here.** Steps 3 and 4 are for Aurora17 only.

**3. Run the launcher once.** Select the bottle, choose **Run Command**, browse
to `Aurora17Connector.exe` in your Aurora17 folder. Tick the box to save it as
a launcher.

**4. Tell Aurora where the game is.** If the launcher does not find FIFA 17 by
itself, press **BROWSE** and pick the folder that contains `FIFA17.exe`. Aurora
remembers it.

The bottle needs nothing else. No .NET, no Visual C++, no PowerShell.

---

## Install

### Normal install (with Aurora17)

Double-click **START HERE.command**.

It finds CrossOver, makes the copy, installs the fixes, and sets up the bottle.
It prints every step. If it stops, the reason is in **red** with the fix under
it. Then go to [Play](#play).

> [!CAUTION]
> 🔴 macOS refuses to open the file: "Apple could not verify..."

> [!TIP]
> 🟢 Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway**. On macOS 14 and older, right-click the file → **Open** also works. You only do this once.
> Or skip it: open Terminal, type `zsh ` (with a space), drag `START HERE.command` into the window, press Return.

Useful commands (run in Terminal, inside this folder):

```sh
./setup.sh /path/to/CrossOver.app   # CrossOver is somewhere unusual
./setup.sh --verify                 # check an install, changes nothing
./uninstall.sh                      # undo everything
```

### Offline install (no Aurora17)

For kick-off, career, tournaments and skill games only. No online, no
Ultimate Team, nothing that needs an EA account.

Double-click **START HERE offline.command** (or run `./setup.sh --offline`).

It installs the CrossOver copy, the fixes and the bottle settings, then adds a
**FIFA 17 (offline)** entry to the bottle. It installs nothing that talks to
EA: no PowerShell stand-in, no EA name redirects, no certificate.

Want Aurora17 later? Install Aurora17, then double-click **START HERE.command**.
It fills in the missing pieces. Nothing to undo first.

Moved the game folder? `./setup.sh --offline-menu` repoints the entry.

---

## Play

**Always use CrossOver-FIFA**, never your normal CrossOver. They look identical
and share the same bottles, but only the copy has the fixes.

### Normal install

Open **CrossOver-FIFA** → open the **Aurora17** bottle → press **PLAY FIFA 17**.

Aurora starts its own local server, signs you in and launches the game. The
ACTIVITY panel shows:

```
Starting Aurora17 and FIFA 17...
Server is up.
Enrolling...
Launching FIFA 17...
FIFA 17 is running (pid NNNN). Go to Ultimate Team.
```

If FIFA's Configuration window opens, click **Play** in it. Aurora waits four
minutes for you.

Other launcher buttons: **REPAIR SETUP** re-checks the game, shim, certificate
and hosts without starting FIFA. **CHECK AGAIN** just looks. **100M + RESET
CLUB** empties the club and grants 100,000,000 coins. Leave Ultimate Team before
using it.

### Offline install

Two ways, same result:

- Open **CrossOver-FIFA** → open the **Aurora17** bottle → click **FIFA 17 (offline)**.
- Or double-click **PLAY FIFA 17 offline.command**. This does not open CrossOver.
  **Keep that window open while you play.** It tells the background cleanup the
  game is running on purpose. Closing the window stops the game.

---

## Stop and clean up

Quit however you like. The installer sets up a background helper that clears
leftovers 45 seconds after CrossOver quits: the game, Aurora's programs, the
bottle lock and the ports. You do not have to do anything.

Two rules it follows on purpose:

- **It does nothing while CrossOver is open.** Closing a bottle window with the
  red dot does not quit CrossOver. It stays in the menu bar. Press **⌘Q** to
  quit it properly, or leftovers stay until you do.
- **Quit the game before CrossOver.** If FIFA is still running when CrossOver
  quits, the helper closes it 45 seconds later.

To clean up right now: double-click **Stop.command**. It closes the game, then
Aurora, then CrossOver, in that order.

The helper never touches a running session, a non-Wine program or another Wine
app's bottles. `./setup.sh --agent` reinstalls it. `./uninstall.sh` removes it.
Its log is at `~/Library/Application Support/FIFA-CrossOver/cleanup.log`.

---

## Troubleshooting

### Check these first

**1. Did you open CrossOver-FIFA, or your normal CrossOver?**
They look identical and share bottles. If FIFA loops, hangs on loading, cannot
reach EA, or says the servers are shut down: quit both, open **CrossOver-FIFA**,
try again.

**2. Run the checker.** It changes nothing and prints `BAD` in red beside
whatever is wrong. Most of the time it names the problem outright.

```sh
./setup.sh --verify
```

**3. Still failing with a clean `--verify`?** Watch a real launch:

```sh
./setup.sh --smoke
```

Press **PLAY FIFA 17** when it asks. Let the game reach Ultimate Team. After up
to two minutes it prints one of:

| result | meaning |
|---|---|
| `PASS` | the session was issued, Ultimate Team should load |
| `FAIL: FIFA exited on its own` | the game quit. The connector log's exit code says which fault: see [The game quits about 20 seconds in](#the-game-quits-about-20-seconds-in) |
| `FAIL: the shim was refused an auth code` | no session was enrolled. See the elevated setup error below |
| `FAIL: the auth-code bridge kept failing` | same as the first FAIL, seen from the shim's side |
| `INCONCLUSIVE` | the game exited cleanly before a session was issued. Normal if you closed it yourself |
| `nothing launched` | PLAY was never pressed |

**4. Asking someone for help?** Send the bundle, not a description. Either
double-click **Diagnostics.command**, or:

```sh
./setup.sh --bundle
```

It writes `aurora17-bundle-<date>.zip` into the **diagnostics** folder beside
`setup.sh`, with the report, the Aurora logs, the bottle's hosts file and
settings, and the checksums. It contains no account, password or session
token. `./setup.sh --report` prints the same diagnosis without the logs and
saves it as `diagnostics/report.txt`.

Every other check and repair is a double-click in that folder too — one
`.command` file each, listed in `diagnostics/README.md`. Nothing there needs
Terminal.

### CrossOver GUI never finishes loading the bottle

This is the most common problem after a crash or a forced quit.

> [!CAUTION]
> 🔴 CrossOver opens, the bottle sits there with its spinner forever, and nothing happens. Quitting CrossOver and reopening it does not help. Sometimes **every** bottle spins, not only Aurora17.

> [!TIP]
> 🟢 **Quit CrossOver completely (⌘Q), then run:**
> ```sh
> ./setup.sh --unstick
> ```
> It refuses to run while any CrossOver is open, and says so.

**Why it happens:** every bottle runs a few Windows services under a
`wineserver`. When that server dies first (a crash, a forced quit, an update
replacing CrossOver underneath it), the services stay behind and keep holding
the bottle's lock file. CrossOver waits for a server that no longer exists.
Quitting CrossOver does not help because those processes were never
CrossOver's. One leftover in any bottle makes every bottle spin.

`--unstick` closes those leftovers and removes the abandoned lock. It touches
no files, settings or saves. Anything with a living `wineserver` is left alone.

Also run it if you ever opened the Aurora17 bottle in your **normal**
CrossOver. Each copy leaves its own session, and one cannot adopt the other's.

> [!CAUTION]
> 🔴 `--unstick` or `--shutdown` says a session is held and refuses to run.

> [!TIP]
> 🟢 A **PLAY FIFA 17 offline.command** window is still open. Close it first.

### CrossOver-FIFA will not open at all

> [!CAUTION]
> 🔴 CrossOver-FIFA crashes the moment you open it. No window. The crash report names `Sparkle.framework` and "different Team IDs".

> [!TIP]
> 🟢 Its signature lost the permission that lets it load its own frameworks. Run `./setup.sh --resign`. Takes a few seconds, nothing is re-copied.

> [!CAUTION]
> 🔴 Microphone or camera stopped working in CrossOver-FIFA.

> [!TIP]
> 🟢 It was signed without CrossOver's own permissions. Run `./setup.sh --resign`.

### Installer errors

The installer prints every stop in red as `STOPPED: ...` with the fix under it.
The same information, for reference:

> [!CAUTION]
> 🔴 `Apple's command line tools are not installed` (exit 2)

> [!TIP]
> 🟢 In Terminal: `xcode-select --install`, press Install, run the installer again. Nothing was changed.

> [!CAUTION]
> 🔴 `macOS will not let this change ...` (exit 3)

> [!TIP]
> 🟢 App Management permission is missing. Turn it on for Terminal in **System Settings → Privacy & Security → App Management**, **quit Terminal completely**, reopen it, run again.

> [!CAUTION]
> 🔴 `do not match their checksums` (exit 4)

> [!TIP]
> 🟢 The package is damaged or incomplete. Download and extract it again. Do **not** install what is on disk now.

> [!CAUTION]
> 🔴 `built for CrossOver 26.3 exactly` (exit 4)

> [!TIP]
> 🟢 Wrong CrossOver version. Install CrossOver 26.3. See [Why the version matters](#why-the-version-matters).

> [!CAUTION]
> 🔴 `Refusing ...` (exit 2)

> [!TIP]
> 🟢 `AURORA_TARGET` points somewhere unsafe. Point it at a path ending in `.app` that is not `/Applications` itself.

> [!CAUTION]
> 🔴 `Not enough disk space` (exit 2)

> [!TIP]
> 🟢 Free the amount it names (about 1 GB) and run again.

> [!CAUTION]
> 🔴 `is running. Quit it first` (exit 3)

> [!TIP]
> 🟢 CrossOver-FIFA is open. Quit it with **⌘Q**, not just the red dot, and run again.

> [!CAUTION]
> 🔴 `The ... bottle is open in CrossOver` (exit 3)

> [!TIP]
> 🟢 The installer will not edit a bottle that Wine has open, because Wine would write its own settings back over the change. Quit CrossOver with **⌘Q** and run again.

> [!CAUTION]
> 🔴 `leftover process(es) are still inside the ... bottle` (exit 3)

> [!TIP]
> 🟢 A previous session never closed. Run `./setup.sh --unstick`, then the installer again.

> [!CAUTION]
> 🔴 `is set to something else`

> [!TIP]
> 🟢 A bottle setting exists with the wrong value. Open the `cxbottle.conf` it names, fix or delete that line, run again.

> [!CAUTION]
> 🔴 `could not read the permissions on ...` (a note, not a stop)

> [!TIP]
> 🟢 Nothing to do. The installer uses the standard CrossOver 26.3 permissions instead and verifies they landed.

> [!CAUTION]
> 🔴 `Signing lost these permissions` or `did not verify`

> [!TIP]
> 🟢 Run `./setup.sh --resign`. If that fails too, run `./uninstall.sh` and install again.

> [!CAUTION]
> 🔴 `NOT FINISHED` (exit 5)

> [!TIP]
> 🟢 CrossOver is patched but the bottle or the stand-in is not done. The missing piece is listed. Fix it, run again, confirm with `./setup.sh --verify`.

### Game problems after install

> [!CAUTION]
> 🔴 The game opens and closes over and over, forever.

> [!TIP]
> 🟢 The `CX_DR_TRAP` bottle setting is missing. Run `./setup.sh --verify`, then `./setup.sh` again. Manual: [step 6](#6-add-three-settings-to-the-bottle).

> [!CAUTION]
> 🔴 Stuck on the loading screen.

> [!TIP]
> 🟢 The search path or the graphics setting is missing. Run `./setup.sh --verify`, then `./setup.sh` again. Manual: [steps 4](#4-repair-the-search-path) and [6](#6-add-three-settings-to-the-bottle).

> [!CAUTION]
> 🔴 Freezes before the menu, no sound.

> [!TIP]
> 🟢 The Microsoft Teams audio driver is wedged. See [step 7](#7-the-sound-fix-only-some-macs).

> [!CAUTION]
> 🔴 The game works from inside CrossOver-FIFA, but not from its shortcut in `~/Applications/CrossOver`.

> [!TIP]
> 🟢 That shortcut points at your normal CrossOver, so the game runs unpatched. Run `./setup.sh` again. It repoints the shortcut and keeps the original as `.bak-aurora17`.

> [!CAUTION]
> 🔴 "Servers have been shut down", and `--verify` says everything is fine.

> [!TIP]
> 🟢 The bottle is loading Wine's own `version.dll`, so Aurora's shim never loads. Quit CrossOver with **⌘Q** and run `./setup.sh` again. Manual: [step 6a](#6a-let-the-bottle-load-auroras-shim).

> [!CAUTION]
> 🔴 "Servers have been shut down".

> [!TIP]
> 🟢 `WINE_SIMULATE_WRITECOPY` is missing or the files did not install. Run `./setup.sh --verify`, then `./setup.sh` again.

> [!CAUTION]
> 🔴 "Unable to connect to EA".

> [!TIP]
> 🟢 `crypt32` or `secur32.dll` did not install. Run `./setup.sh --verify`, then `./setup.sh` again.

> [!CAUTION]
> 🔴 A connection error at the redirector. Everything else works.

> [!TIP]
> 🟢 The EA names still go to EA instead of your Mac. `--verify` says `ws2_32.so still asks macOS to resolve names`. Run `./setup.sh` again. Manual: [step 3a](#3a-let-the-game-find-aurora17-by-name).

> [!CAUTION]
> 🔴 "Aurora17 could not finish: The elevated setup step exited with code 1"

> [!TIP]
> 🟢 The launcher is trying to write EA names into the bottle's hosts file as Administrator, and Wine has no UAC. Run `./setup.sh` again. It writes them itself. Then press PLAY again.

> [!CAUTION]
> 🔴 The game starts and quits by itself a few seconds later. `redirect-shim.log` ends in `origin-auth-code-refused helper-declined`.

> [!TIP]
> 🟢 No session was enrolled, almost always because of the elevated setup error above. Fix that first. Then always start the game from **PLAY FIFA 17**, never by running `FIFA17.exe`.

> [!CAUTION]
> 🔴 "Creating a new redirector certificate needs Windows PowerShell's PKI module"

> [!TIP]
> 🟢 Run `./setup.sh` again. It copies `aurora17/redirector-dev.pfx` into `server/Aurora17Server/` in your Aurora17 folder. Manual: [step 8a](#8a-the-certificate).

> [!CAUTION]
> 🔴 `--verify` says the bottle's hosts file names none of the 6 EA hosts, or Aurora17 has no hosts receipt.

> [!TIP]
> 🟢 Run `./setup.sh` again.

> [!CAUTION]
> 🔴 You have an `AURORA17` block in `/etc/hosts` from an older setup.

> [!TIP]
> 🟢 Harmless. The fix works inside the bottle now. To remove it: edit `/etc/hosts` (needs a password), delete the block, then run `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`.

> [!CAUTION]
> 🔴 **PLAY does nothing.** No game, no error, and the button becomes clickable again.

> [!TIP]
> 🟢 Aurora cannot find the PowerShell stand-in. `./setup.sh --verify` says which. If it is missing: `AURORA_DIR=/path/to/Aurora17 ./setup.sh`.

> [!CAUTION]
> 🔴 PLAY does nothing, and something is already using port 47170.

> [!TIP]
> 🟢 A server from an earlier attempt still holds the port. Run `./setup.sh --unstick`. To see what holds it first: `lsof -nP -iTCP:47170 -sTCP:LISTEN`.

> [!CAUTION]
> 🔴 `ERROR [Code 13]: The server did not pass its authenticated readiness check`

> [!TIP]
> 🟢 Read the `Last probe:` line in the error.
> - If it says the server rejected the control key (HTTP 401 or 403): an older server is still listening with a different key. Run `./setup.sh --unstick`, press PLAY again.
> - If it says `readiness.ready was not true`: the server did not finish starting. The reason is in the `server-*.log` the message names.
> - Still failing: `./setup.sh --bundle`.

> [!CAUTION]
> 🔴 "Aurora17 could not finish — Success."

> [!TIP]
> 🟢 Only `crypt32.dll` was installed, not `crypt32.so`. It is **two** files. Run `./setup.sh` again. Manual: [step 3](#3-copy-the-new-files-in).

> [!CAUTION]
> 🔴 "REPAIR SETUP" closes the launcher.

> [!TIP]
> 🟢 The fixes are not fully installed. `./setup.sh --verify` names the missing piece.

> [!CAUTION]
> 🔴 A CrossOver update landed and FIFA broke.

> [!TIP]
> 🟢 The update replaced your CrossOver. Run `./setup.sh` again. If CrossOver moved past 26.3, see [Why the version matters](#why-the-version-matters).

> [!CAUTION]
> 🔴 PlayStation controller: Cross acts as Circle, R1 as R2, and so on.

> [!TIP]
> 🟢 Run `./setup.sh` again. It sets `DisableHidraw` in the bottle. Reconnect the controller once the bottle is running. Manual: [step 6b](#6b-fix-playstation-controller-buttons).

### The game quits about 20 seconds in

Two different faults land in the same twenty-second window, and `--verify` says
everything checks out for both. **The exit code in the connector log tells them
apart. Read it before doing anything else:**

| exit code | cause | go to |
|---|---|---|
| `0xFFFFFFFA` | no EA licence file | [below](#0xfffffffa--no-licence-file) |
| `0x00000003` | the game quit itself at Direct3D start-up | [below](#0x00000003--dies-at-direct3d-start-up) |

```sh
grep 'exited with code' ~/Library/Application\ Support/CrossOver/Bottles/Aurora17/drive_c/users/crossover/AppData/Local/Aurora17/Logs/connector-*.log | tail -1
```

#### `0xFFFFFFFA` — no licence file

> [!CAUTION]
> 🔴 `--verify` says everything checks out. The shim loads. The game still dies. The connector log shows:
> ```
> +00:00  Started the direct FIFA17 launch candidate (pid N)
> +00:07  signaled verified shim readiness
> +00:24  exited with code 0xFFFFFFFA
> ```
> and the launcher sits on *WORKING...*.

> [!TIP]
> 🟢 The bottle has no EA licence file (`C:\ProgramData\Electronic Arts\EA Services\License\1027460.dlf`). In order of least effort:
> 1. **Press PLAY again.** The stand-in now seeds the file itself. You will see `Seeding the FIFA 17 licence file (first launch in this bottle)...`.
> 2. If the launcher reports **code 24**, it could not find `_fifa17.exe` next to the game. Start FIFA 17 once yourself from CrossOver, quit, PLAY again.
> 3. From Terminal: `AURORA_BOTTLE='Aurora17' ./setup.sh --bottle`. Then `./setup.sh --verify` should say `licence file present`.

**Why:** Aurora starts `FIFA17.exe` directly. Without the licence file the game
goes into Origin activation, relaunches itself, and the copy Aurora is watching
exits. Your own `_fifa17.exe` writes the file within four seconds of starting.
Every bottle that ever played had it. Every bottle that failed did not.

Moving to a new bottle? Your Ultimate Team club lives at
`drive_c\users\crossover\AppData\Local\Aurora17\Server\fut-state.json` in the
old bottle. Copy that file across. Leave `access-sessions.json`, it is
regenerated.

#### `0x00000003` — dies at Direct3D start-up

> [!CAUTION]
> 🔴 The licence file **is** present, `--verify` is clean, and the launcher reports `ERROR [Code 25]`. The connector log ends:
> ```
> +00:00  Started the direct FIFA17 launch candidate (pid N)
> +00:02  signaled verified shim readiness
> +00:22  exited with code 0x00000003
> ```
> and the newest `client-*.log` shows the LSX handshake completing and every request answered, with `SetDownloaderUtilization` a tenth of a second before the exit.

> [!TIP]
> 🟢 This is **not** an Aurora fault, whatever the error code suggests. Every request the game made was served; it quit on its own immediately afterwards, while starting Direct3D. Code 25 is `ERR_FIFA_QUIT_EARLY`, which only reports that the game left early — it cannot see why.

Work through these in order.

**1. Take out anything that is not ours.** Open
`~/Library/Application Support/CrossOver/Bottles/Aurora17/cxbottle.conf`. Under
`[EnvironmentVariables]` there should be **only** the keys from
[step 6](#6-add-three-settings-to-the-bottle) (plus the sound one, if you have
it). Delete anything else — `WINEMSYNC`, `DXVK_CONFIG_FILE` and a
`CX_GRAPHICS_BACKEND` changed to something other than `d3dmetal` have all
turned up on bottles that fail this way. **Quit CrossOver with ⌘Q first**, or it
writes the file back out over your edit. Then try again.

**2. Check your macOS version.** `sw_vers -productVersion`. These fixes are
built against CrossOver 26.3, whose D3DMetal predates the newest macOS
releases; the failures seen so far have been on much newer macOS than this was
developed on. There is no fix here yet — but say which version you are on in a
bug report, because it is the thing that separates the machines that play from
the machines that do not.

**3. Get the graphics log.** This is what a useful report contains:

```sh
WINEDEBUG=+d3d,+dxgi ./setup.sh --play-offline 2>&1 | tee ~/Desktop/fifa-d3d.log
```

Then `./setup.sh --bundle`, and send both. The game is exiting deliberately at
device or swap-chain creation, and that log names what it asked for and did not
get.

> [!NOTE]
> `MakeWindowAssociation: Ignoring flags 7` and `[D3DMetal] Unsupported API: D3D11 timestamp query` both appear in these logs and are **normal**. Nearly every DXGI program prints the first, and D3DMetal prints the second for any unsupported call. Neither is the reason the game quit.

### "The Origin client was terminated"

> [!CAUTION]
> 🔴 A box appears *outside* the game after it reached the servers: "FIFA 17 is shutting down because the Origin client was terminated". `--verify` says everything is fine.

> [!TIP]
> 🟢 The bottle's proxy auto-detect was on, so Aurora's helper spent five seconds hunting for a proxy and missed the shim's five-second deadline. Quit CrossOver with **⌘Q**, then run `./setup.sh` (or `AURORA_BOTTLE='Aurora17' ./setup.sh --bottle`). `--verify` should then say `proxy auto-detect off`. Manual: [step 6c](#6c-turn-proxy-auto-detect-off).

The tell-tale in `%LOCALAPPDATA%\Aurora17\Logs`: five seconds between
`origin-auth-code-pipe-request begin` and `origin-auth-code-refused
helper-declined` in `redirect-shim.log`.

### Aurora error codes

The PowerShell stand-in reports every refusal as `ERROR [Code n]: ...` in the
launcher and in `%LOCALAPPDATA%\Aurora17\Logs\connector-*.log`.

| code | meaning | what to do |
|---|---|---|
| 10 | another launch is already in progress | wait, or quit the launcher and reopen it |
| 11 | port 47170 is busy, almost always our own server left over | quit the launcher, `./setup.sh --unstick`, PLAY again |
| 12 | the packaged server would not start | check `server/` is not missing from your Aurora17 folder |
| 13 | the server started but never passed its readiness check | see Code 13 above |
| 14 | the control key could not be created or read | `%LOCALAPPDATA%\Aurora17` is not writable |
| 15 | the player-head cache could not be refreshed | close FIFA, PLAY again |
| 16 | FIFA is already running | close it |
| 17 | the server refused to enroll the account | check the server log |
| 18 / 19 | the launcher could not be started or found | do not rename or move `Aurora17Connector.exe` |
| 20 | FIFA did not start in time | try again; if it repeats, send a bundle |
| 21 | the club reset failed | the server was not running |
| 22 | no `redirector-dev.pfx`, and no PKI module to make one | run `./setup.sh` again ([step 8a](#8a-the-certificate)) |
| 23 | Aurora asked for something the stand-in does not implement | send a bundle |
| 24 | no licence file, and no `_fifa17.exe` next to the game | start FIFA 17 once from CrossOver, then PLAY again |
| 25 | FIFA quit within a minute of starting | if you closed it yourself, ignore; otherwise see [The game quits about 20 seconds in](#the-game-quits-about-20-seconds-in) — the exit code in the connector log says which fault |

### Installer exit codes

| code | meaning |
|---:|---|
| 0 | finished and verified |
| 2 | unsupported Mac, or a setting that cannot be used |
| 3 | a permission problem, usually App Management |
| 4 | the package or your CrossOver is not what it should be |
| 5 | installed but not finished. The game will not start yet |

---

## Manual install, step by step

The installer does all of this. Read on only if you want to see it happen or
do it by hand. Offline install: do steps 1 to 7, then 9a.

### 1. Make the copy

In Applications, select **CrossOver**, press **⌘D**, rename the duplicate
**CrossOver-FIFA**. Everything below is done to the copy.

Why the copy: your other bottles keep their trusted CrossOver, and a copy you
made yourself does not need the macOS **App Management** permission.

Right-click **CrossOver-FIFA** → **Show Package Contents** → open:

```
Contents → SharedSupport → CrossOver → lib → wine
```

Two folders matter: `x86_64-unix` and `x86_64-windows`.

### 2. Make backups

Copy these six files and add `.orig` to each copy. They are how you undo.

```
x86_64-unix/ntdll.so              →  ntdll.so.orig
x86_64-unix/winecoreaudio.so      →  winecoreaudio.so.orig
x86_64-unix/crypt32.so            →  crypt32.so.orig
x86_64-windows/version.dll        →  version.dll.orig
x86_64-windows/crypt32.dll        →  crypt32.dll.orig
x86_64-windows/secur32.dll        →  secur32.dll.orig
```

### 3. Copy the new files in

From `fixes/`, copy each file over the one with the same name. The three in
`x86_64-unix` go in `x86_64-unix`, the three in `x86_64-windows` go in
`x86_64-windows`.

**`crypt32` is two files.** Both are needed. Replacing only `crypt32.dll` does
nothing.

Also copy `fixes/x86_64-unix/a17hosts.dylib` into `x86_64-unix`. It is new.

### 3a. Let the game find Aurora17 by name

FIFA reaches EA by name. Aurora answers those names on your Mac. Aurora writes
them into the hosts file inside the bottle, but Wine asks macOS to resolve
names, and macOS never reads that file. `a17hosts.dylib` fixes that:

```sh
APP=/Applications/CrossOver-FIFA.app
W="$APP/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix"
install_name_tool -change /usr/lib/libSystem.B.dylib @rpath/a17hosts.dylib "$W/ws2_32.so"
otool -L "$W/ws2_32.so" | grep a17hosts     # must print a line
```

Names not in the bottle's hosts file resolve normally. The rest of the internet
is unaffected.

### 4. Repair the search path

```sh
install_name_tool -add_rpath '@loader_path/../../../lib64' "$W/ntdll.so"
install_name_tool -add_rpath '@loader_path/../../../lib64' "$W/crypt32.so"
```

"Already there" is fine. **Do not skip this.** Without it the game hangs on the
loading screen.

### 5. Sign the files

Save CrossOver's permissions, add one, then sign:

```sh
codesign -d --entitlements /tmp/cx.plist --xml "$APP"
/usr/libexec/PlistBuddy \
  -c 'Add :com.apple.security.cs.disable-library-validation bool true' /tmp/cx.plist

codesign --force --sign - "$W/ntdll.so" "$W/winecoreaudio.so" "$W/crypt32.so" \
                          "$W/a17hosts.dylib" "$W/ws2_32.so"
codesign --force --sign - -o runtime --entitlements /tmp/cx.plist "$APP"
codesign --verify --deep --strict "$APP"       # must print nothing
```

Sign without the saved permissions and CrossOver loses microphone and camera
access. Sign without the added one and the app crashes at launch naming
`Sparkle.framework`. The Windows files need no signing.

### 6. Add three settings to the bottle

Open `~/Library/Application Support/CrossOver/Bottles/Aurora17/cxbottle.conf`.
Under `[EnvironmentVariables]` (add the heading if missing) add:

```
"CX_GRAPHICS_BACKEND" = "d3dmetal"
"CX_DR_TRAP" = "2"
"WINE_SIMULATE_WRITECOPY" = "1"
```

| setting | without it |
|---|---|
| `CX_GRAPHICS_BACKEND` | hangs on the loading screen |
| `CX_DR_TRAP` | the game restarts itself forever |
| `WINE_SIMULATE_WRITECOPY` | "servers have been shut down" |

### 6a. Let the bottle load Aurora's shim

Aurora's shim is a `version.dll` next to `FIFA17.exe`. Wine prefers its own, so
the shim never loads. **Quit CrossOver first.** Open
`~/Library/Application Support/CrossOver/Bottles/Aurora17/user.reg`, find
`[Software\\Wine\\DllOverrides]` (add it at the end if missing) and add:

```
"version"="native,builtin"
```

There is another `"version"=` line under a different heading. Ignore it.

### 6b. Fix PlayStation controller buttons

**Quit CrossOver first.** Open
`~/Library/Application Support/CrossOver/Bottles/Aurora17/system.reg`, find
`[System\\CurrentControlSet\\Services\\winebus]` (add it at the end if missing)
and add:

```
"DisableHidraw"=dword:00000001
```

Reconnect the controller once the bottle is running.

### 6c. Turn proxy auto-detect off

**Quit CrossOver first.** Open `user.reg` (same folder) and add at the end, as
two lines:

```
[Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\\Connections] 0
"DefaultConnectionSettings"=hex:46,00,00,00,00,00,00,00,01,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00
```

The second line is one long line.

### 7. The sound fix (only some Macs)

Check whether this folder exists:

```
/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver
```

If not, skip this step. If it does, add to `[EnvironmentVariables]`:

```
"WINE_COREAUDIO_EXCLUDE" = "Microsoft Teams Audio"
```

That Microsoft driver stops answering and freezes any program that asks it a
question. FIFA asks every sound device at startup.

### 8. The PowerShell stand-in

Copy `aurora17/powershell.exe` into the folder where `Aurora17Connector.exe`
lives, usually `~/Downloads/Aurora17`.

Aurora's PLAY button works by running a PowerShell script. CrossOver's
`powershell.exe` is a placeholder that does nothing and reports success. This
file does the real work. It is about 190 KB, source beside it as
`aurora-pwsh.c`. It only runs Aurora's own scripts and refuses anything else.

### 8a. The certificate

Copy `aurora17/redirector-dev.pfx` into `server/Aurora17Server/` inside your
Aurora17 folder, if there is not one already.

Aurora makes its own on Windows through PowerShell's PKI module, which a bottle
does not have. This is a throwaway self-signed certificate for `f17.aurora.test`,
used only by the local server on your Mac.

### 9. The six EA names, inside the bottle

Add these to `drive_c/windows/system32/drivers/etc/hosts` **inside the bottle**,
with Windows line endings and the `# aurora17` tag on each:

```
127.0.0.1 f17.aurora.test # aurora17
127.0.0.1 gosredirector.ea.com # aurora17
127.0.0.1 easw.easports.com # aurora17
127.0.0.1 content.lt.easfc.ea.com # aurora17
127.0.0.1 pal.gt.easfc.ea.com # aurora17
127.0.0.1 pg.fifa12.test.easportsworld.ea.com # aurora17
```

Aurora would write these itself, but through an Administrator copy of itself,
and Wine has no UAC. The installer also writes Aurora's receipt at
`drive_c/users/crossover/AppData/Local/Aurora17/ShimReceipts/hosts-mapping.json`
so the launcher never tries to elevate. Untagged lines are kept. The original is
saved as `hosts.bak-aurora17`.

### 9a. The licence file

Start `_fifa17.exe` from your game folder once in the bottle, wait a few
seconds, quit. That writes:

```
C:\ProgramData\Electronic Arts\EA Services\License\1027460.dlf
```

Without it the game takes the Origin activation path and quits about 20 seconds
in. The file is made from your own copy of the game, so it is not shipped here.

### 10. Offline menu entry (offline install only)

`./setup.sh --offline-menu` adds the **FIFA 17 (offline)** entry to the bottle.
It is a raw menu entry that runs `_fifa17.exe` from your game folder.

---

## Reference

### Why the version matters

These files are built for CrossOver 26.3 exactly. In another version they will
not work and may stop CrossOver launching. That is why the installer refuses.

**A CrossOver update undoes all of this.** Run `./setup.sh` again afterwards.
If the update moved past 26.3, you need to rebuild from `patches/` first.

**An Aurora17 update does not.** After extracting a new build, run `./setup.sh`
once so the stand-in and certificate go into the new folder. Tested with
`0.1.0-dev.404a406c33de` and `0.1.0-dev.e3cd78725d62`.

### Playing without Aurora's launcher

In CrossOver, choose **Run Command**, tick "save as launcher", make two:

| name | command |
|---|---|
| Aurora17 Server | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Play.ps1 -ServerOnly`, started in your Aurora17 folder |
| FIFA 17 | `Aurora17Connector.exe launch` |

Double-click the server, wait a few seconds, double-click the game. When it
eventually stops with `Session request was rejected with HTTP 401`, press
**PLAY FIFA 17** in Aurora's own window once to renew the sign-in.

### Uninstall

```sh
./uninstall.sh
```

Or double-click **Uninstall.command**. Or by hand: drag CrossOver-FIFA to the
Trash and delete `powershell.exe` from your Aurora17 folder.

Your own CrossOver was never changed. The bottle settings do nothing on their
own and can stay. Nothing was ever written outside the copy, the bottle and
your Aurora17 folder. You were never asked for a password.

If you used `AURORA_IN_PLACE=1` to patch your real CrossOver, `uninstall.sh`
puts the `.orig` files back and re-signs the app. It cannot restore
CodeWeavers' own signature. Reinstall CrossOver to have it exactly as shipped.

### What is in here

| | |
|---|---|
| `README.md` | the short version of this file |
| `START HERE.command`, `START HERE offline.command` | install, normal or offline |
| `PLAY FIFA 17 offline.command` | play offline without opening CrossOver |
| `Stop.command`, `Uninstall.command` | clean quit, undo |
| `setup.sh`, `uninstall.sh` | what the .command files run |
| `fixes/` | the seven files for the CrossOver copy, source and checksums |
| `aurora17/` | the PowerShell stand-in, its source, the certificate, checksums |
| `patches/` | the Wine source changes the fixes were built from |
| `build.sh` | rebuilds `fixes/` from source |
| `LICENSE`, `NOTICE.md` | MIT for our parts, LGPL for the Wine parts |

The Wine files are built from published CrossOver source. The changes are in
`patches/` as the licence requires, and `./build.sh` rebuilds them, so you can
check rather than trust.

Nothing in here belongs to anyone else. No game, no CrossOver, no Aurora, no
key. You need your own copy of each.
