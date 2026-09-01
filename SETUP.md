# FIFA 17 on a Mac — setup

This fixes problems in CrossOver itself, not in the game. Without the fixes the
game either restarts itself forever, hangs on a black loading screen, has no
sound, says the servers have been shut down, or Aurora's **PLAY** button does
nothing at all.

**It does not change your CrossOver.** It makes a separate copy called
**CrossOver-FIFA**, puts six small files in that, and adds one file to your
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
| Your own copy of FIFA 17 | retail build `17.0.3175939.0`, the only one supported |
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

Same thing by hand, if you would rather see it happen. Eight steps.

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

Then sign the three changed Mac files, and the app itself with that file:

```
codesign --force --sign - "$W/ntdll.so" "$W/winecoreaudio.so" "$W/crypt32.so"

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
three scripts and refuses anything else.

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
| Aurora17 Server | `C:\run.bat` |
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
bottle settings and the PowerShell stand-in, and prints `BAD` beside whatever is
wrong. Do this before anything in the table below — most of the time it names
the problem outright.

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
| `is set to something else` | a bottle setting exists with the wrong value | Open the `cxbottle.conf` it names, fix or delete that one line, run again. |
| `Signing lost these permissions` / `did not verify` | signing went wrong | `./setup.sh --resign`. If that fails too, `./uninstall.sh` and install again. |
| `NOT FINISHED` (exit 5) | CrossOver is patched but the bottle or the stand-in is not done | The missing piece is listed. Fix it, run again, confirm with `--verify`. |

### After it is installed

| what you see | what it means | what to do |
|---|---|---|
| The game opens and closes over and over, forever | `CX_DR_TRAP` is missing | `--verify`, then step 6 |
| Stuck on the loading screen | the search path or the graphics setting | `--verify`, then steps 4 and 6 |
| Freezes before the menu, no sound | the Teams audio driver | Step 7 |
| "Servers have been shut down" | `WINE_SIMULATE_WRITECOPY` is missing, or the files did not install | `--verify`, then steps 3 and 6 |
| "Unable to connect to EA" | `crypt32` or `secur32.dll` did not install | `--verify`, then step 3 |
| **PLAY does nothing at all** — no game, no error, and the button becomes clickable again | Aurora17 is not finding the stand-in: it is in neither place, or it is in a different bottle than the one you opened | `--verify` says which. If it is missing, `AURORA_DIR=/path/to/Aurora17 ./setup.sh` |
| PLAY does nothing, and something is already using port 47170 | a server left running by an earlier attempt is holding the port | `lsof -nP -iTCP:47170 -sTCP:LISTEN`, then quit that process, then press PLAY again |
| "Aurora17 could not finish — Success." | only `crypt32.dll` was installed, not `crypt32.so` | Step 3 — it is **two** files |
| "REPAIR SETUP" closes the launcher | the fixes are not fully installed | `./setup.sh --verify` names the missing piece; install again if it lists any |
| **CrossOver-FIFA crashes the moment you open it**, no window, a crash report naming `Sparkle.framework` and "different Team IDs" | its signature is missing the permission that lets it load its own frameworks | `./setup.sh --resign` — a few seconds, nothing is re-copied |
| Microphone or camera stopped working in CrossOver-FIFA | it was signed without CrossOver's own permissions | `./setup.sh --resign`, which preserves and then verifies them |
| A CrossOver update landed and FIFA broke | the update replaced the app; the copy is untouched but may now be a different version | Run `./setup.sh` again. If CrossOver moved past 26.3, see below. |

### What the exit codes mean

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

(If you used `AURORA_IN_PLACE=1` to patch your real CrossOver instead,
`./uninstall.sh` puts the six `.orig` files back and re-signs it, keeping the
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
| `fixes/` | the six files that go into the CrossOver copy, and their checksums |
| `aurora17/` | the PowerShell stand-in, its source, and its checksum |
| `patches/` | the source code changes the six files were built from |
| `setup.sh` `uninstall.sh` | what the two `.command` files run |

The six CrossOver files are built from freely published CrossOver source code,
and the changes are included in `patches/` as that requires. The stand-in is our
own, and its source is in `aurora17/`. Nothing in here belongs to anyone else —
no game, no CrossOver, no Aurora.
