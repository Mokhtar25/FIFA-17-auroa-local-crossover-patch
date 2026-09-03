# FIFA 17 on a Mac — setup

This fixes problems in CrossOver itself, not in the game. Without the fixes the
game either restarts itself forever, hangs on a black loading screen, has no
sound, says the servers have been shut down, or Aurora's **PLAY** button does
nothing at all.

**It does not change your CrossOver.** It makes a separate copy called
**CrossOver-FIFA**, puts seven small files in that, and adds one file to your
Aurora17 folder. Your own CrossOver and every other bottle you run in it are
left exactly as they are — so Rocket League, the EA App, or whatever else you
have keeps working on the CrossOver you already trust.

**The copy needs about 1 GB of disk. Nothing is downloaded. The game is never
modified.**

Both CrossOvers share the same bottles, so you only set the bottle up once. Just
do not run the *same* bottle in both at the same time.

---

## What is in this file

Read the first three in order. The rest is there when you need it.

1. [What you need first](#what-you-need-first) — versions, and the two things to
   install before anything else
2. [Setting up the bottle](#setting-up-the-bottle--where-the-game-and-aurora-go)
   — make the `Aurora17` bottle and save the launcher. **This part is yours to
   do; the installer cannot, and stops if it is not done.**
3. [The quick way](#the-quick-way--double-click) — double-click one file
4. [The manual way](#the-manual-way) — the same nine steps by hand, if you would
   rather watch it happen
5. [Playing](#playing) — starting the game, quitting it properly, and
   [playing without Aurora17](#playing-without-aurora17) (single player only)
6. [If something goes wrong](#if-something-goes-wrong) — start at
   [the first thing to check](#the-first-thing-to-check); every error I have
   seen is below it, with what causes it
7. [Why the version matters](#why-the-version-matters),
   [FIFA 15](#fifa-15--experimental), [undoing it](#undoing-it),
   [what is in here](#what-is-actually-in-here)

---

## What you need first

| | |
|---|---|
| A Mac with Apple silicon | M1 or newer. The installer checks, and stops on an Intel Mac |
| **macOS 14 or newer** | built and tested on 15.7.8 |
| **CrossOver 26.3** | exactly — not 26.2, not 26.4. See *Why the version matters* below |
| Apple's command line tools | in Terminal: `xcode-select --install`. The installer checks, and stops if they are missing |
| Your own copy of FIFA 17 | build `17.0.3175939.0`, the only one supported |
| Your own copy of Aurora17 | with its bottle already set up |

CrossOver, the game and Aurora17 are not included here, and cannot be shared.

---

## Setting up the bottle — where the game and Aurora go

> **Give FIFA 17 a bottle of its own, and put nothing else in it.**
> A Windows 10 64-bit bottle, used for this game and nothing else.

Nothing has to be "pointed at" the bottle, and this trips people up, so here it
is plainly.

**CrossOver already shows a bottle your whole home folder.** Every bottle gets
`Y:` mapped to `/Users/yourname` and `Z:` mapped to the root of the disk,
automatically, with no setup. So if FIFA 17 and Aurora17 are anywhere under your
home folder — Downloads is fine — Windows can already see them:

```
~/Downloads/Aurora17        is   Y:\Downloads\Aurora17
~/Downloads/FIFA 17         is   Y:\Downloads\FIFA 17
```

You do not copy the game into the bottle, and you do not install it. It stays
where it is.

**1. Make a bottle.** In CrossOver: **+** (New Bottle) → **Windows 10 64-bit** →
name it `Aurora17`. That name is what the installer looks for; if you call it
something else, tell the installer:

```
AURORA_BOTTLE="My Bottle" ./setup.sh
```

**2. Put Aurora17 and FIFA 17 somewhere under your home folder.** Extract the
Aurora17 zip as its own folder — `~/Downloads/Aurora17` is the default the
installer looks in. Keep every file it came with together.

**3. Run the launcher once.** Select the bottle, choose **Run Command**, and
browse to `Aurora17Connector.exe` inside your Aurora17 folder. Tick the box to
save it as a launcher and give it a name, so from then on it is just a
double-click.

**4. Tell Aurora where the game is — in Aurora, not in CrossOver.** The launcher
looks for FIFA 17 by itself. If it does not find it, press **BROWSE** and pick
the folder that contains `FIFA17.exe`. Aurora remembers it; you never do this
again.

That is the whole setup. The bottle needs nothing else installed in it — no
.NET, no Visual C++ runtime, no PowerShell. Aurora carries its own, and the one
piece CrossOver was missing is what this package supplies.

---

## The quick way — double-click

Double-click **START HERE.command**.

That is all. It finds CrossOver on its own and prints what it is doing at every
step. If it has to stop, the reason is in **red**, followed by the steps to fix
it. Then skip to **Playing**.

> **The first time, macOS may refuse to open it** because it came from the
> internet ("Apple could not verify..."). If it does: open **System Settings →
> Privacy & Security**, scroll down, and click **Open Anyway**. On macOS 14 and
> older, **right-click** the file → **Open** works too. You only do this once.
>
> Or avoid it altogether: open Terminal, type `zsh ` (with a space), drag
> `START HERE.command` into the window, and press Return.

If CrossOver is somewhere unusual and it cannot find it, tell it where:

```
./setup.sh /path/to/CrossOver.app
```

To check an install at any time — it changes nothing:

```
./setup.sh --verify
```

To undo everything later, double-click **Uninstall.command**.

---

## The manual way

Same thing by hand, if you would rather see it happen. Nine steps.

### 1. Make the copy, and find the folder

In Applications, select **CrossOver**, press **⌘D** to duplicate it, and rename
the duplicate **CrossOver-FIFA**. Everything below is done to the *copy*.

> **Do it to the copy, not the original.** Two reasons. Your other bottles keep
> running on the CrossOver you already trust. And since macOS 14, changing an
> installed app needs a permission called **App Management** — a fresh copy you
> made yourself does not, so this route never hits that wall.

Right-click **CrossOver-FIFA** → **Show Package Contents**, then open:

```
Contents → SharedSupport → CrossOver → lib → wine
```

Two folders matter: `x86_64-unix` and `x86_64-windows`.

### 2. Make backups

Copy these six files and add `.orig` to the end of each copy. **Do this first** —
they are how you undo everything.

```
x86_64-unix/ntdll.so              →  ntdll.so.orig
x86_64-unix/winecoreaudio.so      →  winecoreaudio.so.orig
x86_64-unix/crypt32.so            →  crypt32.so.orig
x86_64-windows/version.dll        →  version.dll.orig
x86_64-windows/crypt32.dll        →  crypt32.dll.orig
x86_64-windows/secur32.dll        →  secur32.dll.orig
```

### 3. Copy the new files in

From this folder's `fixes/`, copy each file over the one with the same name.
The three in `x86_64-unix` go in `x86_64-unix`; the three in `x86_64-windows`
go in `x86_64-windows`.

**`crypt32` is two files, not one,** and both are needed. Replacing only
`crypt32.dll` changes nothing at all — the half that matters is `crypt32.so`.

Then copy `fixes/x86_64-unix/a17hosts.dylib` into `x86_64-unix` as well. That one
is new — there is nothing of that name to replace — and the next step wires it in.

### 3a. Let the game find Aurora17 by name

FIFA reaches EA's servers by name. Aurora17 answers those names on your own Mac,
so they have to point at your Mac and not at EA. Aurora17's launcher already
writes them into the hosts file **inside the bottle**, on every PLAY and every
REPAIR SETUP — but Wine asks macOS to resolve names, and macOS has never heard of
that file, so it was being written and ignored.

`a17hosts.dylib` is what reads it. One command connects it:

```
APP=/Applications/CrossOver-FIFA.app
W="$APP/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix"
install_name_tool -change /usr/lib/libSystem.B.dylib @rpath/a17hosts.dylib "$W/ws2_32.so"
```

Check it took:

```
otool -L "$W/ws2_32.so" | grep a17hosts
```

That must print a line. If it prints nothing, the game will not connect.

Nothing outside the copy and the bottle changes, and no password is needed. Names
the bottle's hosts file does not mention are resolved normally, so the rest of the
internet — and any other EA software on your Mac — is unaffected.

### 4. Repair the search path

Two of the files need a line telling them where to find their neighbours. Paste
these into Terminal, correcting the path if your CrossOver is elsewhere:

```
APP=/Applications/CrossOver-FIFA.app
W="$APP/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix"
install_name_tool -add_rpath '@loader_path/../../../lib64' "$W/ntdll.so"
install_name_tool -add_rpath '@loader_path/../../../lib64' "$W/crypt32.so"
```

Every command from here on uses that same `$APP`. **It must be the copy.** If
you point these at your real CrossOver you change the app all your other bottles
run in, and you will hit the App Management wall as well.

Skip either if it says the path is already there — that is fine, not an error.

**Do not skip this step.** Without it CrossOver quietly stops using the Mac
graphics support and the game hangs on the loading screen with no clue why.

### 5. Sign the files

Replacing files inside an app breaks its signature, so it has to be signed
again. First save the permissions CrossOver came with:

```
codesign -d --entitlements /tmp/cx.plist --xml "$APP"
```

Now add one permission to that file. Without it the app will not open at all:

```
/usr/libexec/PlistBuddy \
  -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
  /tmp/cx.plist
```

Then sign the changed Mac files, and the app itself with that file. `ws2_32.so`
is in the list because step 3a edited it, and `a17hosts.dylib` because it is new:

```
codesign --force --sign - "$W/ntdll.so" "$W/winecoreaudio.so" "$W/crypt32.so" \
                          "$W/a17hosts.dylib" "$W/ws2_32.so"

codesign --force --sign - -o runtime --entitlements /tmp/cx.plist "$APP"
codesign --verify --deep --strict "$APP"
```

The last line must print nothing. If it complains, the app will not open.

**Both parts matter.** Sign without the saved permissions and CrossOver silently
loses its microphone and camera access. Sign without the added one and the app
dies at launch with no window at all, naming `Sparkle.framework` and "different
Team IDs" — because an ad-hoc signature has no Team ID, and the hardened runtime
refuses to load CodeWeavers' own frameworks into it.

The three Windows files need no signing at all.

### 6. Add three settings to your bottle

This is what lets you play from CrossOver normally, with no Terminal.

Open your Aurora17 bottle folder:

```
~/Library/Application Support/CrossOver/Bottles/Aurora17/cxbottle.conf
```

Scroll to the bottom, find the section headed `[EnvironmentVariables]`, and add:

```
"CX_GRAPHICS_BACKEND" = "d3dmetal"
"CX_DR_TRAP" = "2"
"WINE_SIMULATE_WRITECOPY" = "1"
```

If the section is not there, add that heading first, on its own line.

What each one does:

| setting | without it |
|---|---|
| `CX_GRAPHICS_BACKEND` | the game hangs on the loading screen forever |
| `CX_DR_TRAP` | the game closes and reopens itself endlessly and never starts |
| `WINE_SIMULATE_WRITECOPY` | online never connects; you get "servers have been shut down" |

### 6a. Let the bottle load Aurora's shim

Aurora's redirect shim is a `version.dll` that sits next to `FIFA17.exe`. Wine
has a `version.dll` of its own and prefers it, which means the shim is never
loaded and the game tells you the servers have been shut down — with everything
else working perfectly.

**Quit CrossOver completely first.** Then open:

```
~/Library/Application Support/CrossOver/Bottles/Aurora17/user.reg
```

Find the section headed `[Software\\Wine\\DllOverrides]` and add this line
inside it:

```
"version"="native,builtin"
```

If that section is not in the file, add it at the end, on its own line, with the
setting under it.

There is a `"version"=` line elsewhere in that file, under a different heading.
That one is a version number and has nothing to do with this. The line must go
under `DllOverrides`.

`./setup.sh` does this for you; this is the manual equivalent.

### 6b. Put a PlayStation controller's buttons in the right places

If you play with a controller and Cross acts as Circle, R1 as R2 and so on, this
is the fix. Wine offers the pad to the game twice — once raw, once through SDL
as an Xbox-style controller — and FIFA 17 takes the raw one, whose buttons are
numbered in Sony's order while the game reads them in Microsoft's. Turning the
raw one off leaves the one the game reads correctly. A keyboard is not affected
either way.

**Quit CrossOver completely first.** Then open:

```
~/Library/Application Support/CrossOver/Bottles/Aurora17/system.reg
```

(`system.reg`, not `user.reg` this time.) Find the section headed
`[System\\CurrentControlSet\\Services\\winebus]` and add this line inside it:

```
"DisableHidraw"=dword:00000001
```

If that section is not in the file, add it at the end, on its own line, with the
setting under it. Reconnect the controller once the bottle is running.

`./setup.sh` does this for you; this is the manual equivalent.

### 6c. Turn the bottle's proxy auto-detect off

A brand-new bottle has no Internet settings of its own, and Wine reads that as
"Automatically detect settings" being ticked. Every fresh .NET program in the
bottle — Aurora's helper is one — then spends up to five seconds hunting for a
proxy before its first request, even for an address on your own Mac. Aurora's
shim only waits five seconds for that helper, so it gives up first and the game
puts up a box saying the Origin client was terminated. Nothing here needs a
proxy: everything Aurora talks to is this Mac.

**Quit CrossOver completely first.** Then open:

```
~/Library/Application Support/CrossOver/Bottles/Aurora17/user.reg
```

Add this at the end, on its own two lines:

```
[Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\\Connections] 0
"DefaultConnectionSettings"=hex:46,00,00,00,00,00,00,00,01,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00
```

That is one long line, all on one line, however your editor wraps it. It is the
same thing as unticking that box on Windows.

`./setup.sh` does this for you; this is the manual equivalent.

### 7. The sound fix — only some Macs need this

Check whether this folder exists on your Mac:

```
/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver
```

**If it does not exist, you are done. Skip this step.**

If it does, add one more line to the same section:

```
"WINE_COREAUDIO_EXCLUDE" = "Microsoft Teams Audio"
```

**Why:** that Microsoft driver stops answering, and any program that asks it
anything freezes solid and never recovers. FIFA asks every sound device a
question when it starts, so it walks into it every single time — the game
freezes before reaching the menu, with no sound and no error.

This is not CrossOver's fault and not the game's. The same freeze happens to
ordinary Mac programs that have nothing to do with either. The setting simply
tells the game to skip that one device by name; everything else works normally
and you get full sound.

### 8. The one file that goes in your Aurora17 folder

Copy `aurora17/powershell.exe` from this folder into the folder where
`Aurora17Connector.exe` lives — usually `~/Downloads/Aurora17`.

**Why:** Aurora's **PLAY FIFA 17** button does its real work by running a script
through Windows PowerShell. CrossOver has no PowerShell — it has a placeholder
that does nothing and then reports that it succeeded. Aurora believes it, so the
button appears to work and nothing happens: no game, no error, no clue. This file
is a small stand-in that does the work the script would have done.

It is a plain program, about 190 KB, and its complete source is beside it as
`aurora-pwsh.c` if you want to read or rebuild it. It only ever runs Aurora's own
four scripts and refuses anything else. When it does refuse, it says so and exits
with a numbered code — the table under *What Aurora's error codes mean* below.

### 8a. The certificate Aurora cannot make here

Copy `aurora17/redirector-dev.pfx` into `server/Aurora17Server/` inside your
Aurora17 folder, if there is not one there already.

**Why:** Aurora's redirector answers the game over HTTPS, so it needs a
certificate for `f17.aurora.test`. On Windows it makes its own on first run,
through PowerShell's PKI module. That module is a Windows component; it is not
in a CrossOver bottle and cannot be added to one. Without the file, the launcher
stops on first PLAY with

```
Creating a new redirector certificate needs Windows PowerShell's PKI module,
which this bottle does not have.
```

The one in `aurora17/` is a throwaway self-signed certificate for a name that
can never resolve publicly, used only by the loopback server on your own Mac.

### 9. The six EA names, inside the bottle

The installer does this for you. By hand: add these six lines to
`drive_c/windows/system32/drivers/etc/hosts` **inside the bottle**, keeping the
`# aurora17` tag on each and using Windows line endings.

```
127.0.0.1 f17.aurora.test # aurora17
127.0.0.1 gosredirector.ea.com # aurora17
127.0.0.1 easw.easports.com # aurora17
127.0.0.1 content.lt.easfc.ea.com # aurora17
127.0.0.1 pal.gt.easfc.ea.com # aurora17
127.0.0.1 pg.fifa12.test.easportsworld.ea.com # aurora17
```

**Why:** Aurora's launcher writes these itself — but on a bottle where they are
not already there it does it through what it calls *the elevated setup step*, a
second copy of itself running as Administrator. Wine has no UAC, that second
copy exits 1, and the launcher stops with

```
Aurora17 could not finish: The elevated setup step exited with code 1
```

*before the server is ever started*. The game then launches with no session, its
shim asks the helper for an Origin auth code, is refused, and FIFA quits on its
own. From the outside that reads as "the game works but the server does not".

There is nothing to elevate for: the file is inside the bottle and belongs to
you. The installer writes it, and writes Aurora's own recovery receipt beside it
at `drive_c/users/crossover/AppData/Local/Aurora17/ShimReceipts/hosts-mapping.json`,
so the launcher finds the mappings already present and receipt-owned and never
reaches the elevated path at all. Anything already in that hosts file that is
not tagged `# aurora17` is kept, and the original is saved as
`hosts.bak-aurora17`.

### 9a. The licence file the game will not start without

The installer does this for you (it is the last thing `./setup.sh --bottle`
does), and the launcher does it on its own if it finds the file missing. By hand:
start `_fifa17.exe` from your game folder once in the bottle, wait a few seconds,
and quit it. That run writes

```
C:\ProgramData\Electronic Arts\EA Services\License\1027460.dlf
```

**Why:** Aurora's launcher starts `FIFA17.exe` directly. Without that file the
game takes its Origin activation path instead of its normal one: it relaunches
itself, the process Aurora is watching exits with `0xFFFFFFFA` about twenty
seconds in, and the launcher sits on *WORKING...* with no error. With the file
present the same launch connects. The file is made from your own copy of the
game, so it is not shipped here; one loader run per bottle makes it, and it is
the same 1649 bytes every time. `./setup.sh --verify` reports it as
`licence file present`; if your game lives somewhere other than
`~/Downloads/FIFA 17`, say where with `AURORA_GAME_DIR='/path/to/FIFA 17'`.

---

## Playing

Open **CrossOver-FIFA** — the copy, not your normal CrossOver — open the
**Aurora17** bottle, and press **PLAY FIFA 17**.

That is the whole thing. No Terminal, nothing to start first. Aurora starts its
own local server, signs you in, and launches the game.

Both CrossOvers share the same bottles, so the Aurora17 bottle appears in both.
Only CrossOver-FIFA has the fixes, so use that one for the game — and do not run
the same bottle in both at once.

While it works, the ACTIVITY panel in the launcher reads:

```
Starting Aurora17 and FIFA 17...
Server is up.
Enrolling...
Launching FIFA 17...
FIFA 17 is running (pid NNNN). Go to Ultimate Team.
```

If FIFA's Configuration window opens, click **Play** in it; Aurora keeps your
session ready for four minutes while you do.

The launcher's other buttons work too: **REPAIR SETUP** re-runs the game, shim,
certificate and hosts checks without starting FIFA; **CHECK AGAIN** just looks;
and **100M + RESET CLUB** empties the club and grants 100,000,000 coins. Leave
Ultimate Team before using that last one, and re-enter it afterwards.

### If you would rather not use the launcher

You do not have to. In CrossOver, choose **Run Command**, tick the option to save
it as a launcher, and make two:

| name it | command to run |
|---|---|
| Aurora17 Server | `powershell.exe` with the arguments `-NoProfile -ExecutionPolicy Bypass -File scripts\Play.ps1 -ServerOnly`, started in your Aurora17 folder |
| FIFA 17 | `Aurora17Connector.exe` with the argument `launch` |

Then double-click the server, wait a few seconds, and double-click the game.
This route does not renew your local sign-in, so when it eventually stops with
`Session request was rejected with HTTP 401`, press **PLAY FIFA 17** in Aurora's
own window once and it will be renewed.

---

## If something goes wrong

### Start here, always

```
./setup.sh --verify
```

It changes nothing. It checks every file, the signature, the permissions, the
bottle settings, the version DLL override, the bottle's proxy auto-detect, the
bottle's own shortcuts, whether anything is still holding the bottle, name
resolution and the PowerShell stand-in, and prints `BAD` in red beside whatever
is wrong. Do this before anything in the table below — most of the time it
names the problem outright.

Every one of those checks is static. A bottle can pass all of them and still
fail to play, so when `--verify` is clean and the game still does not work:

```
./setup.sh --smoke
```

That one watches a real launch. Press **PLAY FIFA 17** when it asks, and it
waits up to two minutes and then says **PASS** or **FAIL** — reading the same
two markers a person would look for by hand:

| verdict | what it saw |
|---|---|
| `PASS` | `origin-auth-code-issued` — the session was issued, Ultimate Team should load |
| `FAIL: FIFA exited on its own` | the connector logged a non-zero exit, usually `0xFFFFFFFA` |
| `FAIL: the shim was refused an auth code` | `origin-auth-code-refused` |
| `FAIL: the auth-code bridge kept failing` | `origin-auth-code-sync-bridge-failed`, repeating every ~19 s |
| `INCONCLUSIVE` | the game exited cleanly (`0x00000000`) before any session was issued — normal if you closed it yourself. It prints the last thing the shim reported |
| `nothing launched` | no new connector log — PLAY was never pressed, so nothing was tested |

A `FAIL` here with a clean `--verify` is the one case the install cannot
diagnose itself. Send the zip from `./setup.sh --bundle`.

Let the game reach Ultimate Team before closing it. A launch can load the
shim, patch its gate and resolve a user without ever requesting an auth
code, so quitting early reads as `INCONCLUSIVE` rather than as a pass.

If it says everything is fine and the game still misbehaves, or if you are
asking someone else for help:

```
./setup.sh --report
```

Also changes nothing. It prints one diagnosis — the checks above, plus which
CrossOver is *actually* running, what is holding the bottle, the bottle
settings, the shim's fingerprint in the game folder, and whether the shim ever
loaded — and saves it to
`aurora17-report.txt`. Send that file rather than describing the symptom; it
contains everything anyone would otherwise have to ask you for, and no keys,
tokens or paths outside the game and the bottle.

If you are reporting a problem to someone else, send the bundle instead:

```
./setup.sh --bundle
```

Also changes nothing. It writes `aurora17-bundle-<date>.zip` to your Desktop
containing the report above, the Aurora17 connector, server, client and shim
logs, the bottle's hosts file and its receipt, the bottle's settings, and the
checksums of everything installed. It is the whole first round of questions,
answered in advance. It contains no account, password or session token.

### If the bottle never finishes loading

CrossOver opens, the bottle sits there with its spinner, and nothing ever
happens — quitting CrossOver and reopening it changes nothing.

```
./setup.sh --unstick
```

**Quit CrossOver first.** The command refuses to do anything while any copy of
CrossOver is open, and says so.

What it fixes: every bottle runs a small set of Windows services, and they are
started by a `wineserver` that is supposed to outlive them. When that server
dies first — a crash, a forced quit, or CrossOver being replaced underneath it
by an installer — those services stay behind, no longer belonging to any
program you can see, still holding a lock file that says the bottle is busy.
The next time you open that bottle, CrossOver waits for a server that is not
there. It waits forever, and quitting CrossOver does not help, because the
processes it is waiting on were never CrossOver's to begin with.

`--unstick` closes them and removes the abandoned lock. It touches nothing in
the bottle itself: no files, no settings, no saves.

It looks at **every** bottle, not only the Aurora17 one. CrossOver's window
waits on all of them at once, so one leftover in any bottle leaves every bottle
spinning. It also picks up the `conhost.exe` that Aurora's server leaves behind,
which sits outside the bottle but holds the same lock. Anything that still has a
living `wineserver` — a Wine session that is genuinely running — is listed and
left alone.

You should rarely need to run it, because every successful install turns on a
per-user timer that, starting 45 seconds after CrossOver quits, does what
`--unstick` does by itself every 30 seconds and logs to
`~/Library/Application Support/FIFA-CrossOver/cleanup.log`. It never touches
a running CrossOver session or a non-Wine program, and it stays inside its own
bottles: Wine names a prefix's `/tmp` lock directory after that prefix's device
and inode, so another Wine runtime's session — Whisky, Wineskin, a plain `wine`
— is left alone even while no CrossOver is open. `./setup.sh --agent`
reinstalls the timer; `./uninstall.sh` removes it.

Two things to know about when it does *not* act, both on purpose:

- **While CrossOver is open it does nothing at all**, and closing a bottle
  window is not quitting CrossOver — the app stays in the menu bar. So the
  leftovers from a session you closed with the red dot sit there until you
  quit CrossOver properly (Command-Q). This is the fail-closed half of the
  design: with CrossOver open, a process that looks abandoned is
  indistinguishable from a game that is still loading, or one you are about to
  start again, and closing someone's live game is far worse than leaving a
  stray. `./setup.sh --unstick` does it on demand instead of waiting.
- **Quitting CrossOver while FIFA is still playing** counts as leaving a stray
  behind, and the game is closed 45 seconds later. Quit the game first.

`./setup.sh --shutdown` (or double-click `Stop.command`) covers both: it closes
the games and Aurora first, then the wineservers, then the GUI, in that order,
so nothing is left for the timer to find.

This is also worth running if you have ever opened the Aurora17 bottle in your
**normal** CrossOver. Each copy leaves its own session behind, and one copy
cannot adopt the other's.

### Playing without Aurora17

`./setup.sh --offline` (or **START HERE offline.command**) installs everything
the game itself needs and nothing Aurora17's: the CrossOver copy, the seven
fixes, the signature and the bottle settings — steps 1 to 7 — and then stops.
Steps 8 and 9, the PowerShell stand-in and the six EA name mappings, exist only
so Aurora17's PLAY button works and its redirect is reached, so they are
skipped.

Step 9a is kept, and it is worth saying why, because it looks like Aurora's:
`1027460.dlf` is FIFA 17's own licence file, written by the game's loader on a
first run. A bottle without it loses its first launch to `0xFFFFFFFA`
(BUGS.md §18). Aurora17's launcher normally writes it on PLAY — offline there
is no launcher, so the installer runs the loader once itself.

Step 10 adds a **FIFA 17 (offline)** entry to the bottle, so the game starts
the way everything else in CrossOver does: open **CrossOver-FIFA**, pick the
bottle, click the entry. It is a "raw" menu entry rather than a Windows
shortcut, because the game folder lives outside the bottle and `_fifa17.exe`
has no shortcut of its own to point at. `./setup.sh --offline-menu` re-adds it,
which is what to run if the game folder moves; `./uninstall.sh` removes it.

**PLAY FIFA 17 offline.command** (`./setup.sh --play-offline`) is the same
launch without opening CrossOver at all. Both run `_fifa17.exe` in the bottle
through the patched copy — the same thing step 9a does, without the stopping.
Kick-off, career, tournaments and skill games all work, with a controller.
Online, FUT and anything that needs an EA account do not: nothing in an offline
install talks to EA.

Started from the CrossOver window, none of the next two paragraphs applies:
there is a CrossOver GUI running, so the background cleanup stands down by
itself, and quitting CrossOver afterwards clears the session as usual. They
matter only for the terminal launcher, which runs with no GUI at all:

- Leave the terminal window open while you play. It holds
  `session-hold` in `~/Library/Application Support/FIFA-CrossOver`, and that
  file is the only thing telling the background cleanup that a Wine session
  with no CrossOver GUI behind it is deliberate. Without it the cleanup would
  see the game as a stray and close it 45 seconds in. `--unstick` and
  `--shutdown` refuse to run while it is held, and say so.
- Closing that window stops the game.

`./setup.sh --verify` knows which kind of install it is looking at (the receipt
records it) and does not report Aurora17's missing pieces as faults on an
offline install. It still checks the licence file, which is the game's own.

Adding Aurora17 later needs no undoing: install Aurora17, then run
`./setup.sh` with no flag, and steps 8 and 9 fill in what the offline install
left out.

### The first thing to check

**Did you open CrossOver-FIFA, or your normal CrossOver?** They look identical
in the Dock and they share the same bottles, so it is easy to launch the wrong
one — and the fixes are only in the copy. If FIFA restarts in a loop, hangs on
the loading screen, cannot reach EA, or says the servers are shut down, quit
both, open **CrossOver-FIFA**, and try again before reading any further.

### While the installer is running

Every stop is printed in red as `STOPPED: ...`, with the steps to fix it right
under it. The table is the same information, for reference.

| what you see | what it means | what to do |
|---|---|---|
| `Apple's command line tools are not installed` (exit 2) | two Apple tools the installer needs are missing | In Terminal: `xcode-select --install`, press Install, run again. Nothing was changed. |
| `macOS will not let this change ...` (stops, exit 3) | App Management permission is missing | Turn it on for your Terminal in System Settings → Privacy & Security → App Management, **quit Terminal completely**, reopen it, run again. Nothing was changed. |
| `do not match their checksums` (exit 4) | the package is damaged or incomplete | Download and extract the package again. Do **not** install what is on disk now. |
| `built for CrossOver 26.3 exactly` (exit 4) | wrong CrossOver version | See "Why the version matters" below. Nothing was changed. |
| `Refusing ...` (exit 2) | `AURORA_TARGET` names something unsafe or not an app | Point it at a path ending in `.app` that is not `/Applications` itself. |
| `Not enough disk space` (exit 2) | the 1 GB copy will not fit | Free the amount it names and run again. Nothing was changed. |
| `is running. Quit it first` (exit 3) | CrossOver-FIFA is open | Quit it fully — ⌘Q, not just closing the window — and run again. |
| `The ... bottle is open in CrossOver` (exit 3) | the installer will not edit a bottle Wine has open — Wine holds the registry in memory and writes its own copy back when it quits, which would undo step 6a silently | Quit CrossOver fully — ⌘Q — and run again. Nothing was changed. |
| `leftover process(es) are still inside the ... bottle` (exit 3) | a previous session never closed; it would overwrite whatever the installer writes, and the bottle will hang on loading | `./setup.sh --unstick`, then run the installer again. Nothing was changed. |
| `is set to something else` | a bottle setting exists with the wrong value | Open the `cxbottle.conf` it names, fix or delete that one line, run again. |
| `could not read the permissions on ...` (a note, not a stop) | that CrossOver's signature was replaced at some point, so it no longer carries its own permission list | Nothing to do. The installer signs with the four CrossOver 26.3 ships with instead, then verifies they landed. Microphone, camera and Apple Events keep working. |
| `Signing lost these permissions` / `did not verify` | signing went wrong | `./setup.sh --resign`. If that fails too, `./uninstall.sh` and install again. |
| `NOT FINISHED` (exit 5) | CrossOver is patched but the bottle or the stand-in is not done | The missing piece is listed. Fix it, run again, confirm with `--verify`. |

### After it is installed

| what you see | what it means | what to do |
|---|---|---|
| The game opens and closes over and over, forever | `CX_DR_TRAP` is missing | `--verify`, then step 6 |
| Stuck on the loading screen | the search path or the graphics setting | `--verify`, then steps 4 and 6 |
| **The bottle itself never opens** — CrossOver's spinner runs forever, and quitting and reopening CrossOver does not help | a previous session's Windows services outlived their `wineserver` and still hold the bottle's lock; they are not CrossOver's children any more, so quitting CrossOver leaves them running | Quit CrossOver, then `./setup.sh --unstick`. `--verify` reports this as `BAD` too |
| Freezes before the menu, no sound | the Teams audio driver | Step 7 |
| The game works when you start it from inside CrossOver-FIFA, but not from its shortcut in `~/Applications/CrossOver` | that shortcut hardcodes the CrossOver that made it, which was your normal one, so the game runs unpatched | `./setup.sh` repoints it and `--verify` checks it. The original is kept as `.bak-aurora17` |
| "Servers have been shut down", and `--verify` says everything is fine | the bottle is loading Wine's own `version.dll`, so Aurora's shim never loads | `--verify` now says `BAD` for this. Quit CrossOver fully and re-run `./setup.sh`, or step 6a by hand |
| "Servers have been shut down" | `WINE_SIMULATE_WRITECOPY` is missing, or the files did not install | `--verify`, then steps 3 and 6 |
| "Unable to connect to EA" | `crypt32` or `secur32.dll` did not install | `--verify`, then step 3 |
| The game cannot reach Aurora17 — a connection error at the redirector, but everything else works | `ws2_32.so` is not reading the bottle's hosts file, so the names still go to EA | `--verify` says `ws2_32.so still asks macOS to resolve names`. Run `./setup.sh` again, or step 3a by hand |
| **Everything verifies, the shim loads, and the game still quits ~20 s in** — the connector logs `exited with code 0xFFFFFFFA` | the bottle has no EA licence file (`C:\ProgramData\Electronic Arts\EA Services\License\1027460.dlf`); Aurora starts `FIFA17.exe` directly and only your `_fifa17.exe` writes it | press PLAY again — the launcher now seeds it — or `AURORA_BOTTLE='yourbottle' ./setup.sh --bottle`. See *The game quits about twenty seconds in* below |
| **A popup outside the game: "FIFA 17 is shutting down because the Origin client was terminated"** | the bottle's proxy auto-detect was on, so Aurora's helper spent five seconds looking for a proxy and missed the shim's five-second deadline for the Origin auth code | `--verify` says `proxy auto-detect` is on; quit CrossOver fully and run `./setup.sh` again (or `AURORA_BOTTLE='yourbottle' ./setup.sh --bottle`) |
| **"Aurora17 could not finish: The elevated setup step exited with code 1"** | the launcher is trying to write the six EA names into the bottle's hosts file through an Administrator copy of itself, and Wine has no UAC | `./setup.sh` writes them, and Aurora's receipt, itself — step 9. Then press PLAY again. `--verify` reports both |
| **The game starts and quits by itself a few seconds later**, and `redirect-shim.log` ends in `origin-auth-code-refused helper-declined` | the launcher never got past its own setup, so no session was ever enrolled — nine times in ten that is the elevated step, above | Fix that first, then start the game from **PLAY FIFA 17**, never by running `FIFA17.exe` |
| **"Creating a new redirector certificate needs Windows PowerShell's PKI module"** | Aurora is trying to mint its HTTPS certificate and there is no PKI module in a bottle | Step 8a — copy `aurora17/redirector-dev.pfx` into `server/Aurora17Server/`. `./setup.sh` does it |
| `--verify` says the bottle's hosts file names none of the 6 EA hosts | the installer has not written them yet | Run `./setup.sh` again. Aurora's launcher would otherwise try, and fail, to elevate for it |
| `--verify` says Aurora17 has no hosts receipt | the mappings are there but Aurora does not know it put them there, so its first PLAY will still try to elevate | Run `./setup.sh` again |
| You have an `AURORA17` block in `/etc/hosts` from an older setup | it is no longer needed — the fix works inside the bottle now | It does no harm. To remove it: edit `/etc/hosts` (needs a password), delete the block, then `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |
| **PLAY does nothing at all** — no game, no error, and the button becomes clickable again | Aurora17 is not finding the stand-in: it is in neither place, or it is in a different bottle than the one you opened | `--verify` says which. If it is missing, `AURORA_DIR=/path/to/Aurora17 ./setup.sh` |
| PLAY does nothing, and something is already using port 47170 | a server left running by an earlier attempt is holding the port | `./setup.sh --unstick` frees ports 47170-47173. To see what holds it first: `lsof -nP -iTCP:47170 -sTCP:LISTEN` |
| **`ERROR [Code 13]: The server did not pass its authenticated readiness check`** | Aurora's server started and bound its port, but never answered its health check as ready. On a working bottle the first poll succeeds in about two seconds, so a four-minute timeout is never "the server was slow" — it is a condition that was never going to become true. The message now names which one. | **Read the `Last probe:` line in the error.** If it says the server rejected the control key (HTTP 403 or 401), a server from an earlier attempt is still listening with a different key, or `%LOCALAPPDATA%\Aurora17\control-key.txt` was replaced: run `./setup.sh --unstick` and press PLAY again. If it says `readiness.ready was not true`, the server is ours and genuinely did not finish starting — the reason is in the `server-*.log` the message names. Note those logs carry no timestamps, so they cannot be lined up against the connector logs by time. Still failing: `AURORA_BOTTLE='yourbottle' ./setup.sh --bundle`. |
| "Aurora17 could not finish — Success." | only `crypt32.dll` was installed, not `crypt32.so` | Step 3 — it is **two** files |
| "REPAIR SETUP" closes the launcher | the fixes are not fully installed | `./setup.sh --verify` names the missing piece; install again if it lists any |
| **CrossOver-FIFA crashes the moment you open it**, no window, a crash report naming `Sparkle.framework` and "different Team IDs" | its signature is missing the permission that lets it load its own frameworks | `./setup.sh --resign` — a few seconds, nothing is re-copied |
| Microphone or camera stopped working in CrossOver-FIFA | it was signed without CrossOver's own permissions | `./setup.sh --resign`, which preserves and then verifies them |
| A CrossOver update landed and FIFA broke | the update replaced the app; the copy is untouched but may now be a different version | Run `./setup.sh` again. If CrossOver moved past 26.3, see below. |

### The game quits about twenty seconds in

The symptom is specific. `./setup.sh --verify` says **Everything checks
out**, `redirect-shim.log` reaches `origin-auth-code-sync-bridge-enabled
verified-build`, and the game still dies:

```
+00:00  Started the direct FIFA17 launch candidate (pid N)
+00:07  signaled verified shim readiness
+00:24  exited with code 0xFFFFFFFA
```

followed by `origin-auth-code-sync-bridge-failed pipe-capability` lines in
`redirect-shim.log` every twenty seconds, and the launcher stuck on *WORKING...*.

**The cause is one missing file:**

```
C:\ProgramData\Electronic Arts\EA Services\License\1027460.dlf
```

Aurora starts `FIFA17.exe` directly, and without that licence file the game goes
into Origin activation: it relaunches itself, the process Aurora is bound to
exits `0xFFFFFFFA`, the helper discards the session, and the relaunched copy has
no pipe to talk to — the `pipe-capability` lines are that copy failing, after
the fact. Your own `_fifa17.exe` writes the file within four seconds of
starting. Every bottle that ever played had it; every bottle that failed did not.

What fixes it, in order of least effort:

1. Press **PLAY** again. The stand-in now checks for the file before it starts
   the server, runs your loader for a few seconds if the file is missing, stops
   it, and then launches normally. You will see
   `Seeding the FIFA 17 licence file (first launch in this bottle)...` in the
   launcher.
2. If the launcher reports **code 24**, it could not find `_fifa17.exe` next to
   your game. Start FIFA 17 once yourself from CrossOver (any way that reaches
   the menu), quit, and PLAY again.
3. From Terminal, `AURORA_BOTTLE='yourbottle' ./setup.sh --bottle` seeds the
   file (step 9a) and `./setup.sh --verify` confirms it with
   `licence file present`.

A launch that works logs this in the client log within about 17 seconds of the
shim signalling ready:

```
Accepted the LSX connection owned by FIFA17 pid N
Completed the FIFA17 LSX challenge handshake.
```

If you move to a new bottle for any other reason: nothing outside the bottle is
touched, so the game folder, Aurora's shim in it, and the Aurora17 folder all
carry over. What does not carry over is the Ultimate Team club, which lives at
`drive_c\users\crossover\AppData\Local\Aurora17\Server\fut-state.json`
inside the old bottle. Copy that one file across if you want your progress; leave
`access-sessions.json` behind, it is regenerated.

### "The Origin client was terminated"

A box appears *outside* the game, after it has already reached the servers:

> FIFA 17 is shutting down because the Origin client was terminated

`--verify` says everything is fine, the game launches, and it still happens. Look
in `%LOCALAPPDATA%\Aurora17\Logs` for these three lines:

```
redirect-shim.log   origin-auth-code-pipe-request begin
                    origin-auth-code-refused helper-declined   (five seconds later)
client-*.log        The one-use Origin auth bridge request failed closed
                    ERROR Client failed: TaskCanceledException: A task was canceled.
```

Five seconds between the first two is the whole story. A new bottle has no
Internet settings of its own, and Wine reads that as "Automatically detect
settings" being ticked, so Aurora's helper spends five seconds hunting for a
proxy before it makes its first request — and Aurora's shim only waits five
seconds for it. The helper loses, exits, and the connection the game believes is
Origin drops with it. Nothing in the install is wrong; the bottle is just slow
off the mark. On most networks that hunt fails instantly and you never see this.

The fix is one bottle setting. Quit CrossOver completely, then:

```
./setup.sh
```

or, if the rest is already installed:

```
AURORA_BOTTLE='yourbottle' ./setup.sh --bottle
```

`./setup.sh --verify` then says `proxy auto-detect off`. Step 6c is the manual
equivalent.

### What Aurora's error codes mean

The stand-in that replaces PowerShell reports every refusal as
`ERROR [Code n]: ...` in the launcher window and in
`%LOCALAPPDATA%\Aurora17\Logs\connector-*.log`. Quote the number.

| code | meaning | what to do |
|---|---|---|
| 10 | another launch is already in progress | wait, or quit the launcher and reopen it |
| 11 | port 47170 is busy and the holder is not visible to this launch — almost always our own Aurora server left over from an earlier launch | quit the launcher completely, `./setup.sh --unstick`, PLAY again |
| 12 | the packaged server would not start | the server log is in the bundle; check it is not missing from your Aurora17 folder |
| 13 | the server started but never passed its readiness check | usually the certificate — code 22 |
| 14 | the control key could not be created or read | `%LOCALAPPDATA%\Aurora17` is not writable |
| 15 | the player-head cache could not be refreshed | close FIFA, then PLAY again |
| 16 | FIFA is already running | close it |
| 17 | the server refused to enroll the account | server log |
| 18 / 19 | the launcher itself could not be started or found | do not rename or move `Aurora17Connector.exe` |
| 20 | FIFA did not start in time | try again; if it repeats, send a bundle |
| 21 | the club reset failed | the server was not running |
| 22 | no `redirector-dev.pfx`, and no PKI module to make one | step 8a |
| 23 | Aurora asked PowerShell to do something the stand-in does not implement | send a bundle — the log records the exact command line |
| 24 | no licence file in the bottle, and no `_fifa17.exe` next to the game to make one | start FIFA 17 once from CrossOver, then PLAY again — step 9a |
| 25 | FIFA quit within a minute of starting, licence present | if you closed it yourself, ignore it; otherwise the newest `client-*.log` says why |

### What the installer's exit codes mean

| code | meaning |
|---:|---|
| 0 | finished, and verified |
| 2 | unsupported Mac, or a setting that cannot be used |
| 3 | a permission problem — usually App Management |
| 4 | the package or your CrossOver is not what it should be |
| 5 | installed, but not finished — the game will not start yet |

---

## Why the version matters

These files are built to match CrossOver 26.3 exactly. Putting them into a
different version will not work and may stop CrossOver launching at all, which
is why `setup.sh` refuses rather than trying.

**A CrossOver update will undo all of this.** Just run `./setup.sh` again
afterwards. If the update moved to a newer version, you will need to rebuild
from `patches/` first.

**An Aurora17 update does not.** Nothing here is tied to one Aurora17 build:
the installer looks only for `Aurora17Connector.exe` and the `server/` folder,
and the PowerShell stand-in reproduces Aurora's own scripts, which have not
changed between builds. Tested with `0.1.0-dev.404a406c33de` and
`0.1.0-dev.e3cd78725d62` (2 September 2026). After extracting a new build, run
`./setup.sh` once more so step 8 and 8a put the stand-in and the certificate
into the new folder — newer builds ship without `redirector-dev.pfx`.

---

## FIFA 15 — experimental

The same CrossOver copy also runs FIFA 15 (the 2015 CPY release), with a bottle of its own.
Nothing about FIFA 17 changes: FIFA 15's top-down Wine patch is inert unless the bottle sets
`CX_TOPDOWN_LIMIT`, which only the FIFA 15 bottle profile does, and its other fix, a `gdiplus.dll`
that stops Aurora15Connector crashing when it closes, is a file the FIFA 17 profile never touches.

One command sets it all up (or double-click `FIFA 15.command`):

```
./setup.sh --fifa15
```

Starting from nothing and wanting both games? `./setup-both.sh` (or `Both games.command`) runs the
FIFA 17 install and then this, into the same CrossOver-FIFA; `./setup-both.sh --verify` checks both.

What it does depends on what is already there:

- **No CrossOver-FIFA yet:** the full install from "Installing" above, with the FIFA 15 profile —
  the seven files instead of six (`gdiplus.dll` is the seventh), and steps 8 to 9a skipped, since
  they are FIFA 17's (the Aurora17 stand-in, the EA names, the licence).
- **CrossOver-FIFA already there** (made by `./setup.sh` or by an earlier `--fifa15`): the copy is
  left as it is, except that `gdiplus.dll` is put in if it is missing. No re-copy.
- **The `Aurora15` bottle** is made if it does not exist — Windows 10, 64-bit, using the copy's own
  `cxbottle`, about twenty seconds. CrossOver must be closed for that.
- **The bottle settings** (step 7): `CX_GRAPHICS_BACKEND`, `WINE_SIMULATE_WRITECOPY`,
  `CX_TOPDOWN_LIMIT`; the `dinput8` DLL override set to `native,builtin`; proxy auto-detect off;
  `DisableHidraw`; a windowed `~/Documents/FIFA 15/fifasetup.ini` if there is none. The override is
  what makes Aurora work: Aurora15Connector's EA-MITM hook is a proxy `dinput8.dll` beside
  `fifa15.exe`, and without it the bottle loads Wine's own, the game reaches the real EA redirector
  and says the servers are closed while everything else looks fine.
- **The game folder** is looked for (`~/Downloads/FIFA 15`, `~/Desktop`, `~/Games`, `~`; or
  `FIFA15_DIR=/path ./setup.sh --fifa15`) and its `ItsAMe_Origin.dll` is reported: the CPY
  original (what Aurora15Connector needs), the offline-patched one, or the connector's own. It is
  only reported, never changed.

Then, one of two ways to play:

- **With Aurora15Connector:** start `Aurora15Connector-*.exe` in the `Aurora15` bottle, sign in,
  press PLAY; it starts the game itself and hosts the Origin stand-in the game talks to. It wants the
  CPY original `ItsAMe_Origin.dll` (it checks the hash and installs its own). One connector at a
  time: a second instance fails with "Local port 3216 is in use". **Never press the connector's
  "Repair connection" button under CrossOver**: Wine cannot tell it which process owns port 3216,
  so Repair stops the connector's own Origin stand-in, and the game it then starts hangs at the
  splash or the flag. If the connector complains about port 3216 at start, close it and run
  `./setup.sh --unstick` instead (an `Aurora15Client.exe` often outlives the connector window).
  Play Offline from the queue works, and so does an admitted online session once the queue lets you in.
- **Without it:** `./fifa15/fifa15-offline.sh apply "/path/to/FIFA 15"`, then run `fifa15.exe` from
  the game folder in the `Aurora15` bottle. Without this patch the game hangs at the language screen
  with the flag mid-wave (`fifa15/README.md` says why). Run `fifa15-offline.sh revert` before going
  back to the connector.

Other forms: `./setup.sh --fifa15 --verify` checks the copy and the bottle (its Aurora17 lines are
skipped for FIFA 15); `./setup.sh --fifa15 --bottle` does the bottle only, and `AURORA_BOTTLE='name'`
picks another bottle name. `./setup.sh --unstick` frees FIFA 15's leftovers too: a `fifa15.exe` or
`Aurora15Client.exe` left behind with CrossOver closed, and port 3216. `--smoke` and `--report` are
FIFA 17 only and say so.

Verified: language screen, title, intro and the attract-mode match, on Apple silicon; with
Aurora15Connector, sign-in, content download, game launch, the Origin handshake, an offline
session into the menus, and an admitted online session on Aurora's servers (30 minutes, 2026-09-03,
reported working by the player). Not yet checked in detail: input, sound, saves.

## Undoing it

```
./uninstall.sh
```

Or double-click **Uninstall.command**.

Or by hand: **drag CrossOver-FIFA to the Trash**, and delete `powershell.exe`
from your Aurora17 folder. That is all of it — your own CrossOver was never
changed, so there is nothing to put back. The bottle settings do nothing on
their own and can be left.

`uninstall.sh` reads the record written when it installed, and undoes exactly
what is in it. It will not touch a CrossOver it did not patch, and it will not
delete a `powershell.exe` that is not the one it put there.

Nothing was ever written outside the copy, the bottle and your Aurora17 folder —
in particular, no system file, and at no point were you asked for a password.

(If you used `AURORA_IN_PLACE=1` to patch your real CrossOver instead,
`./uninstall.sh` puts the six `.orig` files back, points `ws2_32.so` at the
system resolver again, removes `a17hosts.dylib`, and re-signs it, keeping the
permissions it has. It **cannot** restore CodeWeavers' own signature — six
replaced files are not enough to rebuild that. The app works, but it now carries
an ad-hoc signature. To have CrossOver exactly as it shipped, reinstall it.
This is the main reason the default is a separate copy.)

---

## What is actually in here

| | |
|---|---|
| `README.md` | the short version of this file |
| `START HERE.command` | double-click to install |
| `Uninstall.command` | double-click to undo |
| `fixes/` | the seven files that go into the CrossOver copy, their source, and their checksums |
| `aurora17/` | the PowerShell stand-in, its source, the redirector certificate Aurora cannot make in a bottle, and their checksums |
| `patches/` | the source code changes the six Wine files were built from, and how to apply them |
| `build.sh` | rebuilds every file in `fixes/` from source, so you need not take ours on trust |
| `LICENSE` | MIT, for the parts that are ours |
| `NOTICE.md` | which files are MIT and which are LGPL, and how to rebuild the LGPL ones |
| `dev/` | the Terminal scripts, and tools we used |
| `BUGS.md` | all sixteen problems, what causes each, who owns the code |
| `HANDOFF.md` | the full engineering record |
| `HANDOFF-AURORA-GUI.md` | how Aurora's own launcher was made to work |
| `PORTABLE.md` | how this package is put together |

The six CrossOver files are built from freely published CrossOver source code,
and the changes are in `patches/` as their licence requires — `./build.sh` puts
the two back together and rebuilds them, so the claim is one you can check rather
than one you have to believe. The stand-in and `a17hosts.dylib` are our own, with
their source beside them. `NOTICE.md` says which files carry which licence.

Nothing in here belongs to anyone else — no game, no CrossOver, no Aurora, no
certificate or key. You need your own copy of each.
