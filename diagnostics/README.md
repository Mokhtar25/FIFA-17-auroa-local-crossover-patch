# Diagnostics

Everything in here is a double-click. Nothing here needs Terminal, and nothing
here needs a command typed. If you were asked for "the logs" or "the zip", the
answer is the first file.

Open this folder in Finder and double-click the one you want.

| Double-click | What it does | Changes anything? |
|---|---|---|
| `1 Collect diagnostics.command` | Collects the report, the newest logs, the bottle settings and the hashes into one `aurora17-bundle-<date>.zip` **in this folder**. Send that zip. | no |
| `2 Report.command` | Prints one page of diagnosis and saves it as `report.txt` here. | no |
| `3 Check the install.command` | Checks an install that is already there and says `ok` / `note` / `BAD` for each thing. | no |
| `4 Unstick.command` | Frees a bottle stuck on "loading", and the ports Aurora17 holds. | processes only |
| `5 Quit CrossOver cleanly.command` | Quits CrossOver properly, so no strays and no held ports are left behind. | processes only |
| `6 Repair the signature.command` | Re-signs the CrossOver copy when macOS says it is damaged. | the copy |
| `7 Smoke test.command` | Watches one PLAY from start to finish and says pass or fail. | no |
| `8 Set the bottle up again.command` | Puts the settings and menu entries into a freshly made bottle. | the bottle |
| `9 Install background cleanup.command` | Installs the background job that clears strays and ports by itself. | adds a LaunchAgent |
| `10 Re-add offline menu entry.command` | Puts the "FIFA 17 (offline)" entry back in the bottle. | the bottle |

`Diagnostics.command`, one folder up, is the same as number 1 — it is there so
it can be found without opening this folder.

## Where the files land

Everything is written here, beside these commands:

    diagnostics/aurora17-bundle-<date>.zip     <- send this one
    diagnostics/report.txt                     <- what number 2 saved

The three newest zips are kept and older ones are deleted, so running a command
after every failed attempt does not fill this folder up.

The zip holds the checks, every connector log (one per PLAY, with that launch's
error code) and the newest server and client logs, the bottle's
hosts file and settings, and the hashes of what is installed. The logs are the
`logs` folder inside it — double-click the zip to open it if you want to read
them yourself. It holds no
account, no password and no session token. Nothing leaves your Mac on its own —
these commands write a file and tell you where it is.

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
    ./setup.sh --offline-menu

Use `./setup.sh`, `zsh ./setup.sh` or double-click. `bash setup.sh` used to stop
with `A: unbound variable`; it now re-runs itself under zsh instead.
