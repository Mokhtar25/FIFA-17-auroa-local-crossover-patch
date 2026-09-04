# Doing it by hand

Everything `setup.sh` does, as commands you can run one at a time. Same result —
the script exists only so nobody has to read this page.

Run each block from **this folder** (the one holding `setup.sh` and `fixes/`).
Start by putting yourself there, in Terminal:

```sh
cd ~/Downloads/"FIFA 17"/release      # or wherever you unzipped it
```

Then set these two, once per Terminal window. Everything below uses them.

```sh
SRC=/Applications/CrossOver.app
APP=/Applications/CrossOver-FIFA.app
WINE="$APP/Contents/SharedSupport/CrossOver/lib/wine"
BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
BOTTLE=Aurora17
```

**Before anything:** System Settings → Privacy & Security → **App Management** →
switch on Terminal, then quit Terminal completely and reopen it. CrossOver is a
signed app; without that permission every write below fails with "Operation not
permitted" even though the folders look writable.

Quit CrossOver before you start.

---

## 1. Check the payload

The shipped files must be intact, or you are installing rubbish.

```sh
( cd fixes && shasum -a 256 -c SHA256SUMS )
```

Eight lines, all `OK` — seven binaries plus `a17hosts.c`, the source of the
one file here that is ours rather than a rebuilt Wine component. Anything else —
re-download, do not continue.

## 2. Make a separate CrossOver

Your real CrossOver is left alone; the fixes go in a copy. It is about 2 GB.

```sh
rm -rf "$APP"
ditto "$SRC" "$APP"
```

Check it is the right thing before you go on:

```sh
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
# com.codeweavers.CrossOver
ls -d "$WINE/x86_64-unix"
```

> Doing it **in place** instead (patching your real CrossOver, affecting every
> bottle): skip this step and set `APP=$SRC`. Back up the six replaced files
> first —
> `cp "$WINE/$f" "$WINE/$f.orig"` for each — because reinstalling CrossOver is
> the only other way back.

## 3. Install the seven files

`-X` drops the quarantine flag the zip put on them. Left on, Gatekeeper can
refuse to load them and the failure is unreadable.

```sh
for f in x86_64-unix/ntdll.so x86_64-unix/winecoreaudio.so x86_64-unix/crypt32.so \
         x86_64-unix/a17hosts.dylib \
         x86_64-windows/version.dll x86_64-windows/crypt32.dll x86_64-windows/secur32.dll; do
    cp -X "fixes/$f" "$WINE/$f" && echo "ok  $f"
done
```

`a17hosts.dylib` is the only one that replaces nothing — it is new, and step 3a
is what puts it in the path.

## 3a. Point name resolution at the bottle's hosts file

FIFA reaches EA's servers by name, and Aurora17 answers those names locally.
Aurora17's launcher already writes them into the hosts file **inside the
bottle**, on every PLAY and every REPAIR SETUP — but Wine asks macOS to resolve
names, so that file was written and read by nobody, and only a root-owned block
in `/etc/hosts` decided. `a17hosts.dylib` reads it. One string, in one load
command, connects the two:

```sh
install_name_tool -change /usr/lib/libSystem.B.dylib @rpath/a17hosts.dylib \
    "$WINE/x86_64-unix/ws2_32.so"
otool -L "$WINE/x86_64-unix/ws2_32.so" | grep a17hosts    # must print a line
```

If that prints nothing the game will not connect. The warning
`install_name_tool` prints about invalidating the code signature is expected —
step 5 signs it again.

`a17hosts.dylib` re-exports the whole of libSystem and overrides two functions
out of it, so this changes name resolution and nothing else. Names the bottle's
hosts file does not mention resolve normally, so the rest of the internet — and
any other EA software on the Mac — is unaffected. `install_name_tool -change`
the other way round undoes it exactly.

## 4. Repair the library search path

`ntdll.so` needs it to find its sibling libraries, `crypt32.so` to find the
gnutls CrossOver ships in `lib64`. Without it CrossOver falls back to a graphics
path that does not work on macOS and the game hangs on the loading screen.

Look first — **`crypt32.so` normally already has it** and must not be given it
twice:

```sh
otool -l "$WINE/x86_64-unix/ntdll.so"   | grep -A2 LC_RPATH
otool -l "$WINE/x86_64-unix/crypt32.so" | grep -A2 LC_RPATH
```

Add it only to the one whose output does **not** list
`@loader_path/../../../lib64` (normally just `ntdll.so`):

```sh
install_name_tool -add_rpath '@loader_path/../../../lib64' "$WINE/x86_64-unix/ntdll.so"
```

If you get this:

```
would duplicate path, file already has LC_RPATH for: @loader_path/../../../lib64
changing install names or rpaths can't be redone ... the program must be relinked
```

then the rpath was already there and nothing is wrong — that file is done, move
on. (The second line is scary and irrelevant: it is `install_name_tool`
explaining that it cannot undo the write it just refused to make. The file is
untouched.) If `otool` prints nothing at all for a file that clearly has the
rpath, your `otool` is broken — `xcode-select --install`, or
`sudo xcode-select --reset` if Xcode was moved or deleted.

## 5. Sign

Five Mac binaries now need it. Changing a signed file breaks its signature, and
an unsigned library will not load. `a17hosts.dylib` is new, and `ws2_32.so` is
CrossOver's own file that step 3a edited — so it is no longer covered by
CodeWeavers' signature either.

```sh
for so in ntdll.so winecoreaudio.so crypt32.so a17hosts.dylib ws2_32.so; do
    codesign --force --sign - "$WINE/x86_64-unix/$so" && echo "ok  $so"
done
```

## 6. Sign the app — keeping its permissions

This is the step to not improvise. We can only sign ad-hoc, and CrossOver uses
the hardened runtime, which demands every library share the app's Team ID. Ours
is empty; the frameworks inside still carry CodeWeavers'. So the app dies before
showing a window (`Sparkle ... mapped file have different Team IDs`) unless
`disable-library-validation` is added. And CrossOver's own four permissions must
be carried over, or microphone, camera and Apple Events stop working.

```sh
ENT=$(mktemp -t cxent).plist
codesign -d --entitlements "$ENT" --xml "$APP" && [ -s "$ENT" ] && echo "read them"
```

If that fails, stop — signing without them takes permissions away.

```sh
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$ENT"
codesign --force --sign - -o runtime --entitlements "$ENT" "$APP"
```

Read back what actually landed — `codesign` can succeed and still not carry what
you handed it, and you only find out when the app will not open:

```sh
codesign -d --entitlements - --xml "$APP" | grep -c disable-library-validation   # 1
codesign --verify --deep --strict "$APP" && echo "signature ok"
```

## 7. The bottle settings

The game will not start without these. Bottles are shared between your real
CrossOver and the copy, so this is set once.

```sh
CONF="$BOTTLES/$BOTTLE/cxbottle.conf"
grep -q '^\[EnvironmentVariables\]' "$CONF" || printf '\n[EnvironmentVariables]\n' >> "$CONF"
grep -E '^"(CX_GRAPHICS_BACKEND|CX_DR_TRAP|WINE_SIMULATE_WRITECOPY|WINE_COREAUDIO_EXCLUDE)"' "$CONF"
```

For each of the three that the `grep` did **not** already print, append it:

```sh
printf '"CX_GRAPHICS_BACKEND" = "d3dmetal"\n'   >> "$CONF"
printf '"CX_DR_TRAP" = "2"\n'                   >> "$CONF"
printf '"WINE_SIMULATE_WRITECOPY" = "1"\n'      >> "$CONF"
```

A key already present with a **different** value is not "already set" — edit
that line to the value above, do not add a second one.

Only if `/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver` exists, add the
sound fix too. That driver stops answering and freezes anything that asks it a
question, including the game, before the menu:

```sh
printf '"WINE_COREAUDIO_EXCLUDE" = "Microsoft Teams Audio"\n' >> "$CONF"
```

## 8. The PowerShell stand-in

Aurora17's PLAY button runs `scripts/Play.ps1` through `powershell.exe`. Wine's
`powershell.exe` is a stub that prints a FIXME and returns 0 without doing
anything — and Aurora only checks the exit code, so PLAY silently does nothing.
Install the stand-in in both places it gets looked for.

Next to `Aurora17Connector.exe` (wherever you extracted Aurora17 — usually
`~/Downloads/Aurora17`):

```sh
A="$HOME/Downloads/Aurora17"
ls "$A/Aurora17Connector.exe"
[ -f "$A/powershell.exe" ] && [ ! -f "$A/powershell.exe.aurora-orig" ] &&
    cp -X "$A/powershell.exe" "$A/powershell.exe.aurora-orig"
cp -X aurora17/powershell.exe "$A/powershell.exe"
```

And inside the bottle, keeping Wine's stub:

```sh
PSDIR="$BOTTLES/$BOTTLE/drive_c/windows/system32/WindowsPowerShell/v1.0"
mkdir -p "$PSDIR"
[ -f "$PSDIR/powershell.exe" ] && [ ! -f "$PSDIR/powershell.exe.wine-stub-orig" ] &&
    cp -X "$PSDIR/powershell.exe" "$PSDIR/powershell.exe.wine-stub-orig"
cp -X aurora17/powershell.exe "$PSDIR/powershell.exe"
```

---

## Check the lot

Even done by hand, this still works and checks every step above at once:

```sh
./setup.sh --verify
```

It changes nothing. It compares the shipped files against `fixes/`, checks both
rpaths, checks all five signatures, checks that `ws2_32.so` is reading the
bottle's hosts file, checks the app kept its permissions, and checks the EA host
redirections in the bottle.

If it reports that the bottle's hosts file names none of the six, that is not a
fault on a bottle that has never played — Aurora17's launcher writes them
itself. Press PLAY once and check again.

`./uninstall.sh` still undoes a hand install too, as long as the paths are the
default ones — it reads
`~/Library/Application Support/Aurora17/install-receipt.conf`, which a hand
install does not write. Either write it yourself:

```sh
mkdir -p "$HOME/Library/Application Support/Aurora17"
cat > "$HOME/Library/Application Support/Aurora17/install-receipt.conf" <<EOF
mode=copy
target=$APP
source=$SRC
bottle_dir=$BOTTLES
bottle=$BOTTLE
aurora_dir=$A
bottle_powershell=replaced
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Contents/Info.plist")
installed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
```

— or just delete `/Applications/CrossOver-FIFA.app` when you are done with it,
which undoes the whole of a copy install.

## To play

Open **CrossOver-FIFA** — not your normal CrossOver — then Aurora17 in the
`Aurora17` bottle, and press PLAY FIFA 17. Both share the same bottles, so do
not run the same bottle in both at once.
