# FIFA 17 + Aurora17 on CrossOver — Apple Silicon patch

FIFA 17 and the Aurora17 local server do not work on Apple Silicon macOS under stock
CrossOver. This package patches a **copy** of CrossOver so they do.

Full instructions are in [SETUP.md](SETUP.md). Read that before running anything.

## What you need

- Apple Silicon Mac, macOS 14 or newer
- **CrossOver 26.3** — the installer refuses any other version rather than guessing
- FIFA 17 and Aurora17 already installed in a CrossOver bottle

## Install

```sh
git clone git@github.com:Mokhtar25/FIFA-17-auroa-local-crossover-patch.git
cd FIFA-17-auroa-local-crossover-patch
./setup.sh
```

Or download the repo as a zip and double-click **START HERE.command**.

To check an installation at any time — it changes nothing and prints `BAD`
beside whatever is wrong:

```sh
./setup.sh --verify
```

## It does not touch your CrossOver

`setup.sh` copies `/Applications/CrossOver.app` to `/Applications/CrossOver-FIFA.app`
and patches the copy. Your normal CrossOver, and every other bottle you run in it, are
left alone. Launch **CrossOver-FIFA** to play; launch CrossOver as usual for everything
else.

`AURORA_IN_PLACE=1` patches the real CrossOver instead, if you would rather.
`AURORA_TARGET`, `AURORA_BOTTLE`, `AURORA_DIR` and `CX_BOTTLE_PATH` override the paths.

## Undo

```sh
./uninstall.sh
```

Or double-click **Uninstall.command**. It deletes `CrossOver-FIFA.app` and restores the
bottle's original `powershell.exe`.

## What is in here

| | |
|---|---|
| `START HERE.command` | double-click to install |
| `Uninstall.command` | double-click to undo |
| `setup.sh` `uninstall.sh` | what the two `.command` files run |
| `fixes/` | the six replacement CrossOver files, and their checksums |
| `aurora17/` | the PowerShell stand-in, its source, and its checksum |
| `patches/` | the source changes the six files were built from |
| `SETUP.md` | the full instructions, including troubleshooting |

Exit codes: `0` verified · `2` unsupported Mac or setting · `3` permission ·
`4` wrong CrossOver or damaged package · `5` installed but not finished.

## Provenance

The six CrossOver files are built from freely published CrossOver source, and the
changes that produced them are included in `patches/` as that requires. The PowerShell
stand-in is original work; its source is `aurora17/aurora-pwsh.c`. No game, CrossOver,
or Aurora binaries are redistributed here.
