# Diagnostics

Everything in here is a double-click. Nothing here needs Terminal, and nothing
here needs a command typed. If you were asked for "the logs" or "the zip", the
answer is the first file.

Open this folder in Finder and double-click the one you want.

| Double-click | What it does | Changes anything? |
|---|---|---|
| `1 Collect diagnostics.command` | For every game, with or without a CrossOver-FIFA copy: collects a one-page summary, the checks, the saved setup runs, each FIFA bottle's settings and launcher logs, where each game was found and what is running into one `fifa-diagnostics-<date>.zip` **in this folder**, and prints its full path. Send that zip. | no |
| `2 Report.command` | Prints one page of diagnosis and saves it as `report.txt` here. | no |
| `3 Check the install.command` | Checks an install that is already there and says `ok` / `note` / `BAD` for each thing. | no |
| `4 Unstick.command` | Frees a bottle stuck on "loading". It works on every bottle, not only the FIFA ones, and frees the ports Aurora17 and Aurora15 hold (47170-47173 and 3216). | processes only |
| `5 Quit CrossOver cleanly.command` | Quits CrossOver properly and shuts every bottle down, not only the FIFA ones, so no strays and no held ports are left behind. | processes only |
| `6 Repair the signature.command` | Re-signs the CrossOver copy when macOS says it is damaged. | the copy |
| `7 Smoke test.command` | Watches one PLAY from start to finish and says pass or fail. | no |
| `8 Set the bottle up again.command` | Puts the settings and menu entries into a freshly made bottle. | the bottle |
| `9 Remove background cleanup.command` | Takes off the 30-second LaunchAgent older versions installed. Nothing runs in the background now. | removes a LaunchAgent |
| `10 Re-add offline menu entry.command` | Puts the "FIFA 17 (offline)" entry back in the bottle. | the bottle |
| `11 Re-seed the licence file.command` | Makes the game's own loader write a fresh EA licence file, and prints the hash before and after. Use it when PLAY and `FIFA17.exe` will not start but `_fifa17.exe` does. | the licence file |
| `12 Play with a crash log.command` | Quit CrossOver first. Starts the Aurora17 launcher with CrossOver's own log on; press PLAY in it, let the game crash, close the launcher, and it prints where the crash was (which module, or generated code). It also records every name the bottle looks up, so the log says how far the game got before it died. The log lands in `crash-logs/` here and the next bundle picks it up. Use it for `FIFA 17 crashed` / exit code `0xC0000005`. | no (writes a log here) |
| `13 Check the install (FIFA 15).command` | Checks the FIFA 15 bottle, shared app, offline DLL and original-backup status. | no |
| `15 Fix my installation.command` | One run that puts an install right again without copying CrossOver: quits CrossOver cleanly, replaces any fix file in the copy that is missing or out of date and re-signs it, sets the bottle up again (including the WebView2 runtime the RebornFUT launcher needs), has the game's loader write a fresh licence file, then checks the lot. Also the update path for an older install. | the copy and the bottle |
| `16 Check the install (FIFA 16).command` | Checks the FIFA 16 bottle and its four settings, the shared app, and whether the bottle has a drive letter that reaches the game folder. | no |

Number 1 collects for every game. Smoke tests are FIFA 17's only: for FIFA 15
use number 13, or `./setup-both.sh --verify` to check both installations, and
for FIFA 16 number 16.

`Diagnostics.command`, one folder up, is the same as number 1, and **Fix my
installation.command** beside it is the same as number 15 — they are there so
they can be found without opening this folder.

## Where the files land

Everything is written here, beside these commands:

    diagnostics/fifa-diagnostics-<date>.zip    <- send this one
    diagnostics/report.txt                     <- what number 2 saved

The three newest zips are kept and older ones are deleted (the older
`aurora17-bundle-<date>.zip` ones too), so running a command after every failed
attempt does not fill this folder up. (If this folder cannot be written, the zip
goes to `~/Desktop/aurora17-diagnostics`; the window says where.)

Every double-click that runs setup — START HERE, the FIFA 15 and FIFA 16
commands, Both games, Choose game folders, Fix my installation and everything
in this folder — also saves what its window showed in

    ~/Library/Logs/FIFA-CrossOver/<what ran>-<date>.log

with the macOS version, the package version and the exit code. The newest 20
are kept. The zip carries the newest 10, so a setup that failed in a window that
has since been closed can still be read.

What the zip holds, all of it text:

- `summary.txt`, the page to read first: the package and macOS versions, the
  CrossOver and CrossOver-FIFA versions (or that there is no copy), each bottle
  and the launchers in it, each game's folder and which bottle has its DLL
  overrides, every `BAD` line from the checks, and the end of the newest setup run
- `checks/`: `--verify` for FIFA 17, 15, 16 and 21, with their exit codes
- `setup-logs/`: the saved setup runs above
- `bottles/<name>/` for each bottle with anything FIFA in it: its settings, its
  Wine DLL overrides (only those registry sections, never the whole registry),
  its hosts file, its launchers, and their newest logs (the Aurora launcher,
  Aurora17Connector, CAS, Impulsum17, the FIFA 17 folder gate). Other bottles
  are only named in the summary
- `games.txt`: every folder each game could be in, and the DLLs, programs and
  settings files in the one it is played from
- `processes.txt`: what of Wine, CrossOver and the launchers is running and the
  ports they hold
- `report.txt` (what number 2 prints), any crash report macOS kept for the game
  or for Wine, any CrossOver log of a launch (number 12 makes one, and its
  summary says which module a crash was in), the Mac's network set-up
  (interfaces and resolvers, no hardware addresses), the hashes of what is
  installed, the install receipt and your saved folder choices

Every file is cut to its last megabyte at most (a CrossOver log of a launch to
its last 4 MB) and passes through one filter:
your home folder becomes `~`, e-mail addresses become `<email>`, and any value
after a name like token, password, secret, session, auth, ticket, cookie or API
key becomes `<redacted>`. No account file, no whole registry and no program
file is copied. Double-click the zip to read it yourself first if you like.
Nothing leaves your Mac on its own — these commands write a file and tell you
where it is.

## If a window closes instantly, or macOS refuses to open one

macOS quarantines files that arrived in a downloaded zip. Right-click the
`.command` file, choose **Open**, then **Open** again in the box that appears.
That is only needed once; every command here clears the quarantine for the rest
of the folder when it runs.

## Running these from Terminal instead

Each command is `./setup.sh` with one flag, run from the folder above this one:

    ./setup.sh --bundle        ./setup.sh --report      ./setup.sh --verify
    ./setup.sh --unstick       ./setup.sh --shutdown    ./setup.sh --resign
    ./setup.sh --smoke         ./setup.sh --bottle      ./setup.sh --agent
    ./setup.sh --offline-menu  ./setup.sh --reseed-licence
    ./setup.sh --play-log      ./setup.sh --repair

Use `./setup.sh`, `zsh ./setup.sh` or double-click. `bash setup.sh` used to stop
with `A: unbound variable`; it now re-runs itself under zsh instead.
