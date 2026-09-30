# What is under which licence, and how to rebuild it

Short version: **the installer, the scripts, the docs and `a17hosts.dylib` are MIT.
The nine patched Wine binaries and the patches are LGPL-2.1-or-later, because they
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
| `fixes/x86_64-unix/win32u.so` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-unix/winecoreaudio.so` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-windows/version.dll` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-windows/crypt32.dll` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-windows/secur32.dll` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-windows/gdiplus.dll` | Wine, modified by us | **LGPL-2.1-or-later** |
| `fixes/x86_64-windows/ole32.dll` | Wine, modified by us | **LGPL-2.1-or-later** |
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

## Downloaded at setup time, not redistributed here

The **Microsoft Edge WebView2 fixed-version runtime 99.0.1150.52** is
Microsoft's, licensed by Microsoft on its own terms. Nothing of it is shipped
in this package. `setup.sh` downloads Microsoft's own cabinet
(`Microsoft.WebView2.FixedVersionRuntime.99.0.1150.52.x64.cab`) from a
community archive of those cabinets, checks it against the SHA-256 recorded in
the script, and unpacks it into your bottle, because the RebornFUT launcher's
window will not draw on any runtime from version 100 on. The archive exists
because Microsoft keeps only the last two fixed versions on its own download
page; the file is Microsoft's, byte for byte, and the checksum is what says so.
Using it is between you and Microsoft's terms. `WEBVIEW2_RUNTIME=skip` leaves
it out entirely.

## Corresponding source — what the LGPL asks for, and where it is

The nine binaries above are modified Wine. Anyone receiving them is entitled to
the source they were built from and the means to rebuild them. That is:

1. **The upstream source**: `crossover-sources-26.3.0.tar.gz`, published by
   CodeWeavers with that release. Not redistributed here — it is 142 MB and
   unmodified — but it is the exact tarball these patches apply to, and nothing
   else will apply cleanly.
2. **Our modifications**: `patches/`, twelve build patches plus investigation records against that tarball.
3. **The build**: `./build.sh`, which does all of it end to end.

```sh
./build.sh --deps                                   # check the toolchain first
./build.sh /path/to/crossover-sources-26.3.0.tar.gz
```

It unpacks the tarball, applies the twelve build patches **in the order that works**
(rosetta → online → audio → cng → topdown → gdiplus → ole32 → win32u, then
FIFA 16's debug-register emulation → PF_PAE → dst-complement → drtrap syscall stub; alphabetical order produces a reject — see
`patches/README`), configures, makes the `config.h` edits that cannot
travel in a patch (SONAME_LIBGNUTLS, and the freetype and Vulkan ones win32u
needs), builds, and compares the result against `fixes/SHA256SUMS`.

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
- Of the twelve patches, the **online** one and **win32u** have been confirmed to
  rebuild byte-for-byte. The rest are unverified in that specific sense, which
  is exactly why `build.sh` compares and reports instead of asserting.

The first eight *are* confirmed to apply cleanly, in order, to a pristine
`crossover-sources-26.3.0.tar.gz`. FIFA 16's four were applied by `build.sh`,
in order, on top of those eight in an existing build tree; they have not yet
been applied starting from a pristine tarball.

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
- For FIFA 17 it downloads Microsoft's WebView2 runtime 99 once (165 MB) and
  unpacks it into the bottle at `drive_c/webview2-fixed` (365 MB).
  `uninstall.sh` deletes that folder and the one setting that names it.
  `WEBVIEW2_RUNTIME=skip` skips the download; `WEBVIEW2_CAB=` uses a copy you
  already have. That is the only thing this package ever downloads.
- It is pinned to **CrossOver 26.3 exactly** and refuses to install on anything
  else.
- **It never asks for a password and never writes outside those places.** No
  system file is touched.

Every one of those licences disclaims warranty and liability; the MIT text and
LGPL §15–16 both say so in the usual terms. Nothing here is fit for any purpose
beyond the one described.
