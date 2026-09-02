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

## What you need first

| | |
|---|---|
| A Mac with Apple silicon | M1 or newer. The installer checks, and stops on an Intel Mac |
| **macOS 14 or newer** | built and tested on 15.7.8 |
| **CrossOver 26.3** | exactly — not 26.2, not 26.4. See *Why the version matters* below |
| Your own copy of FIFA 17 | build `17.0.3175939.0`, the only one supported |
| Your own copy of Aurora17 | with its bottle already set up |

None of those three are included here, and none of them can be shared.

---

## Setting up the bottle — where the game and Aurora go

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

That is all. It finds CrossOver on its own, prints what it is doing at every
step, and stops with a plain explanation if anything is wrong. Then skip to
**Playing**.

> **The first time, macOS may refuse to open it** because it came from the
> internet. If it does: **right-click** it → **Open** → **Open**. You only have
> to do that once.

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
refuses to load CodeWeavers' own frameworks into it. We made both mistakes and
each cost real debugging time.

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

**This is tested, not theory.** The game was started exactly this way, from that
button, and confirmed playing online on 2026-09-01.

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
bottle settings, the version DLL override, the bottle's own shortcuts, whether
anything is still holding the bottle, name
resolution and the PowerShell stand-in, and prints `BAD` beside whatever is wrong. Do this before anything in
the table below — most of the time it names the problem outright.

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

This is also worth running if you have ever opened the Aurora17 bottle in your
**normal** CrossOver. Each copy leaves its own session behind, and one copy
cannot adopt the other's.

### The first thing to check

**Did you open CrossOver-FIFA, or your normal CrossOver?** They look identical
in the Dock and they share the same bottles, so it is easy to launch the wrong
one — and the fixes are only in the copy. If FIFA restarts in a loop, hangs on
the loading screen, cannot reach EA, or says the servers are shut down, quit
both, open **CrossOver-FIFA**, and try again before reading any further.

### While the installer is running

| what you see | what it means | what to do |
|---|---|---|
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
| `Could not read CrossOver's own permissions` (older versions, stops) | same cause, but the older installer had nothing to fall back on | Use this version of `setup.sh` — it carries the list and continues. |
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
| **"Aurora17 could not finish: The elevated setup step exited with code 1"** | the launcher is trying to write the six EA names into the bottle's hosts file through an Administrator copy of itself, and Wine has no UAC | `./setup.sh` writes them, and Aurora's receipt, itself — step 9. Then press PLAY again. `--verify` reports both |
| **The game starts and quits by itself a few seconds later**, and `redirect-shim.log` ends in `origin-auth-code-refused helper-declined` | the launcher never got past its own setup, so no session was ever enrolled — nine times in ten that is the elevated step, above | Fix that first, then start the game from **PLAY FIFA 17**, never by running `FIFA17.exe` |
| **"Creating a new redirector certificate needs Windows PowerShell's PKI module"** | Aurora is trying to mint its HTTPS certificate and there is no PKI module in a bottle | Step 8a — copy `aurora17/redirector-dev.pfx` into `server/Aurora17Server/`. `./setup.sh` does it |
| `--verify` says the bottle's hosts file names none of the 6 EA hosts | the installer has not written them yet | Run `./setup.sh` again. Aurora's launcher would otherwise try, and fail, to elevate for it |
| `--verify` says Aurora17 has no hosts receipt | the mappings are there but Aurora does not know it put them there, so its first PLAY will still try to elevate | Run `./setup.sh` again |
| You have an `AURORA17` block in `/etc/hosts` from an older setup | it is no longer needed — the fix works inside the bottle now | It does no harm. To remove it: edit `/etc/hosts` (needs a password), delete the block, then `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |
| **PLAY does nothing at all** — no game, no error, and the button becomes clickable again | Aurora17 is not finding the stand-in: it is in neither place, or it is in a different bottle than the one you opened | `--verify` says which. If it is missing, `AURORA_DIR=/path/to/Aurora17 ./setup.sh` |
| PLAY does nothing, and something is already using port 47170 | a server left running by an earlier attempt is holding the port | `lsof -nP -iTCP:47170 -sTCP:LISTEN`, then quit that process, then press PLAY again |
| "Aurora17 could not finish — Success." | only `crypt32.dll` was installed, not `crypt32.so` | Step 3 — it is **two** files |
| "REPAIR SETUP" closes the launcher | the fixes are not fully installed | `./setup.sh --verify` names the missing piece; install again if it lists any |
| **CrossOver-FIFA crashes the moment you open it**, no window, a crash report naming `Sparkle.framework` and "different Team IDs" | its signature is missing the permission that lets it load its own frameworks | `./setup.sh --resign` — a few seconds, nothing is re-copied |
| Microphone or camera stopped working in CrossOver-FIFA | it was signed without CrossOver's own permissions | `./setup.sh --resign`, which preserves and then verifies them |
| A CrossOver update landed and FIFA broke | the update replaced the app; the copy is untouched but may now be a different version | Run `./setup.sh` again. If CrossOver moved past 26.3, see below. |

### What Aurora's error codes mean

The stand-in that replaces PowerShell reports every refusal as
`ERROR [Code n]: ...` in the launcher window and in
`%LOCALAPPDATA%\Aurora17\Logs\connector-*.log`. Quote the number.

| code | meaning | what to do |
|---|---|---|
| 10 | another launch is already in progress | wait, or quit the launcher and reopen it |
| 11 | something that is not Aurora is listening on port 47170 | `./setup.sh --unstick` |
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

---

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
| `START HERE.command` | double-click to install |
| `Uninstall.command` | double-click to undo |
| `fixes/` | the seven files that go into the CrossOver copy, their source, and their checksums |
| `aurora17/` | the PowerShell stand-in, its source, the redirector certificate Aurora cannot make in a bottle, and their checksums |
| `patches/` | the source code changes the six Wine files were built from, and how to apply them |
| `build.sh` | rebuilds every file in `fixes/` from source, so you need not take ours on trust |
| `LICENSE` | MIT, for the parts that are ours |
| `NOTICE.md` | which files are MIT and which are LGPL, and how to rebuild the LGPL ones |
| `setup.sh` `uninstall.sh` | what the two `.command` files run |

The six CrossOver files are built from freely published CrossOver source code,
and the changes are in `patches/` as their licence requires — `./build.sh` puts
the two back together and rebuilds them, so the claim is one you can check rather
than one you have to believe. The stand-in and `a17hosts.dylib` are our own, with
their source beside them. `NOTICE.md` says which files carry which licence.

Nothing in here belongs to anyone else — no game, no CrossOver, no Aurora, no
certificate or key. You need your own copy of each.
