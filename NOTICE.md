# What is under which licence, and how to rebuild it

Short version: **the installer, the scripts, the docs and `a17hosts.dylib` are MIT.
The six patched Wine binaries and the patches are LGPL-2.1-or-later, because they
are not ours to relicense.** `./build.sh` rebuilds all of it from source.

---

## The split

| file | whose | licence |
|---|---|---|
| `setup.sh`, `uninstall.sh`, `START HERE.command`, `Uninstall.command` | ours | MIT — see `LICENSE` |
| `build.sh` | ours | MIT |
| `SETUP.md`, `MANUAL.md`, and the rest of the documentation | ours | MIT |
| `fixes/a17hosts.c`, `fixes/x86_64-unix/a17hosts.dylib` | ours | MIT |
| `aurora17/aurora-pwsh.c`, `aurora17/powershell.exe` | ours | MIT |
| `fixes/x86_64-unix/ntdll.so` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-unix/crypt32.so` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-unix/winecoreaudio.so` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-windows/version.dll` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-windows/crypt32.dll` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-windows/secur32.dll` | Wine, modified by us | **LGPL-2.1-or-later** |
| `patches/*.patch` | modifications to the above | **LGPL-2.1-or-later** |

Full LGPL text: `fixes/LICENSE.LGPL`, copied verbatim from `COPYING.LIB` in the
Wine sources those binaries are built from.

`a17hosts.dylib` is MIT and not LGPL because it is not derived from Wine at all —
it is our own source, it links against macOS's libSystem, and it is loaded *by*
Wine rather than built *from* it.

## Not included, and not ours to include

CrossOver itself, FIFA 17, Aurora17, and any certificate or key belonging to
anyone else. You need your own copy of each. This package changes a **copy** of
CrossOver that you make; it never touches the original.

## Corresponding source — what the LGPL asks for, and where it is

The six binaries above are modified Wine. Anyone receiving them is entitled to
the source they were built from and the means to rebuild them. That is:

1. **The upstream source**: `crossover-sources-26.3.0.tar.gz`, published by
   CodeWeavers with that release. Not redistributed here — it is 142 MB and
   unmodified — but it is the exact tarball these patches apply to, and nothing
   else will apply cleanly.
2. **Our modifications**: `patches/`, four unified diffs against that tarball.
3. **The build**: `./build.sh`, which does all of it end to end.

```sh
./build.sh --deps                                   # check the toolchain first
./build.sh /path/to/crossover-sources-26.3.0.tar.gz
```

It unpacks the tarball, applies the four patches **in the order that works**
(rosetta → online → audio → cng; alphabetical order produces a reject — see
`patches/README`), configures, makes the SONAME_LIBGNUTLS edit that cannot
travel in a patch, builds, and compares the result against `fixes/SHA256SUMS`.

## Honest limits of that comparison

`build.sh` reports which rebuilt files match the shipped ones and which do not.
Read the difference carefully:

- **A match proves** the patch really does produce that binary.
- **A difference proves nothing on its own.** Wine does not build bit-for-bit
  reproducibly across machines — build paths, timestamps and toolchain versions
  end up inside the binaries.

Two things are known and worth stating rather than letting you find them:

- `crypt32.dll` ships at ~4.4 MB against a stock ~830 KB. That is debugging
  information left in by the build settings, not extra code. It should be
  stripped before anyone calls this finished.
- Of the four patches, only the **online** one has ever been confirmed to
  rebuild byte-for-byte. The others are unverified in that specific sense,
  which is exactly why `build.sh` compares and reports instead of asserting.

All four patches *are* confirmed to apply cleanly, in order, to a pristine
`crossover-sources-26.3.0.tar.gz`.

## What this does to your machine

Not a legal clause — just what it actually does, so nothing is a surprise:

- It makes a **separate copy** of CrossOver called `CrossOver-FIFA` and changes
  only that. Your own CrossOver and every other bottle you run in it are left
  alone.
- That copy is **ad-hoc re-signed** and so no longer carries CodeWeavers'
  signature. `uninstall.sh` puts the replaced files back but **cannot** restore
  that signature — only reinstalling CrossOver can.
- It edits one load command in the copy's `ws2_32.so`, so Wine reads the hosts
  file inside your bottle. `uninstall.sh` reverses it exactly.
- It writes one file into your Aurora17 folder and one into the bottle, and
  records both so uninstall can undo them.
- It is pinned to **CrossOver 26.3 exactly** and refuses to install on anything
  else.
- **It never asks for a password and never writes outside those places.** No
  system file is touched.

Every one of those licences disclaims warranty and liability; the MIT text and
LGPL §15–16 both say so in the usual terms. Nothing here is fit for any purpose
beyond the one described.
