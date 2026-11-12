#!/usr/bin/env python3
"""snapdiff.py -- compare two FIFA 14 `.data` snapshots dword by dword.

The snapshots are the `snap-<t>-.data.bin` files written by fifa14cap.exe
(tests/windows/fifa14cap.c, snap_section): a raw ReadProcessMemory copy of the
`.data` section of fifa14.exe, starting at image_base + section RVA and
`min(SizeOfRawData, VirtualSize)` bytes long.  For the shipped fifa14.exe that is

    VA 0x03FBB000 .. 0x04278000   (0x2BD000 = 2 871 296 bytes)

(0x400000 + RVA 0x3BBB000; verified against the PE header).  Snapshots are
taken at 0.3, 1.0, 3.0 and 8.0 s after the process appears.  An unreadable
64 KiB chunk is left zero by the capture tool, see --zero-chunks below.

Typical use (the one command for the Mac vs Windows comparison):

    tests/windows/snapdiff.py --mac tests/windows/baseline-mac-snap --win <dir-or-zip>

picks snap-3.0s-.data.bin and snap-8.0s-.data.bin from each side (searched
recursively in a directory; a .zip is read in place), compares Mac 3.0 s with
Windows 3.0 s, and classifies every differing dword using the 8.0 s file of
the same side:

    STABLE    equal at 3 s and 8 s on each side, different across  (interesting)
    VOL-MAC   the Mac value changed between 3 s and 8 s
    VOL-WIN   the Windows value changed between 3 s and 8 s
    VOL-BOTH  both changed

Two plain files work too:   snapdiff.py A.bin B.bin  [--a2 A_later.bin --b2 B_later.bin]

Pointer-like values (flag letters in the dump and in --hide-ptr):
    I  image            0x00400000..0x04F7A000   (exe incl. unpacked VM area)
    L  low heap/stack   0x00010000..0x003FFFFF
    D  high / DLL       0x10000000..0x7FFFFFFF (excluding image)
  --hide-ptr      drop diffs where both sides are pointer-like and at least one is L/D
                  (heap/stack/DLL addresses differ run to run: noise)
  --hide-ptr-all  also drop image-vs-image differences
"""
import argparse
import glob
import io
import os
import struct
import sys
import zipfile

DEFAULT_BASE = 0x03FBB000          # 0x400000 + .data RVA 0x3BBB000
IMG_LO, IMG_HI = 0x00400000, 0x04F7A000
LOW_LO, LOW_HI = 0x00010000, 0x00400000
DLL_LO, DLL_HI = 0x10000000, 0x80000000


def ptr_class(v):
    if IMG_LO <= v < IMG_HI:
        return "I"
    if LOW_LO <= v < LOW_HI:
        return "L"
    if DLL_LO <= v < DLL_HI:
        return "D"
    return ""


# ------------------------------------------------------------------ loading

def load(path, want=None):
    """Read a snapshot.  `path` is a file, or (with `want`) a directory / zip
    searched recursively for a file named `want`."""
    if want is None:
        with open(path, "rb") as f:
            return f.read(), path
    if os.path.isdir(path):
        hits = sorted(glob.glob(os.path.join(path, "**", want), recursive=True))
        if not hits:
            raise SystemExit("snapdiff: %s not found under %s" % (want, path))
        if len(hits) > 1:
            print("snapdiff: note: %d matches for %s under %s, using %s" % (len(hits), want, path, hits[0]),
                  file=sys.stderr)
        with open(hits[0], "rb") as f:
            return f.read(), hits[0]
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if os.path.basename(n) == want]
            if not names:
                raise SystemExit("snapdiff: %s not in %s" % (want, path))
            return z.read(names[0]), "%s!%s" % (path, names[0])
    raise SystemExit("snapdiff: %s is neither a directory nor a zip" % path)


def snapname(t):
    return "snap-%s-.data.bin" % t


# ------------------------------------------------------------------ output helpers

def hexline(buf, off, nd, base, marks):
    """16 bytes = 4 dwords per line; `marks` = set of dword indexes that differ."""
    cells = []
    for k in range(4):
        i = off + 4 * k
        if i + 4 > len(buf):
            cells.append("        ")
            continue
        w = buf[i:i + 4]
        cell = w[::-1].hex()            # show as a little-endian dword value
        cells.append(("*" if (i // 4) in marks else " ") + cell)
    chunk = buf[off:off + 16]
    asc = "".join(chr(c) if 32 <= c < 127 else "." for c in chunk)
    return "%08x %s  |%s|" % (base + off, " ".join(cells), asc)


def preview(bufA, bufB, lo_i, hi_i, base, diffset, nbytes, la="A", lb="B"):
    """Side-by-side hexdump of dword indexes [lo_i, hi_i)."""
    start = (lo_i * 4) & ~15
    end = min(hi_i * 4, start + nbytes)
    end = (end + 15) & ~15
    out = []
    for off in range(start, end, 16):
        out.append("    %s %s" % (la, hexline(bufA, off, 4, base, diffset)))
        out.append("    %s %s" % (lb, hexline(bufB, off, 4, base, diffset)))
    if hi_i * 4 > end:
        out.append("    ... (%d more bytes in region)" % (hi_i * 4 - end))
    return "\n".join(out)


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", nargs="?", help="snapshot A (file) -- or use --mac/--win")
    ap.add_argument("b", nargs="?", help="snapshot B (file)")
    ap.add_argument("--a2", help="later snapshot of side A (volatility reference)")
    ap.add_argument("--b2", help="later snapshot of side B (volatility reference)")
    ap.add_argument("--mac", help="Mac snapshot directory (or zip)")
    ap.add_argument("--win", help="Windows snapshot directory (or zip)")
    ap.add_argument("--t1", default="3.0s", help="snapshot time compared (default 3.0s)")
    ap.add_argument("--t2", default="8.0s", help="later snapshot time for volatility (default 8.0s)")
    ap.add_argument("--base", type=lambda s: int(s, 0), default=DEFAULT_BASE,
                    help="VA of the first byte of the snapshots (default 0x%08X: image base + .data RVA)" % DEFAULT_BASE)
    ap.add_argument("--gap", type=int, default=2,
                    help="merge differing dwords separated by at most this many equal dwords (default 2)")
    ap.add_argument("--preview", type=int, default=64, help="hexdump bytes per region and side (default 64)")
    ap.add_argument("--max-regions", type=int, default=40, help="regions to print (default 40, 0 = all)")
    ap.add_argument("--min-dwords", type=int, default=1, help="skip regions with fewer differing dwords")
    ap.add_argument("--stable-only", action="store_true", help="print only regions that contain STABLE differences")
    ap.add_argument("--hide-ptr", action="store_true", help="drop heap/stack/DLL-pointer-vs-pointer differences")
    ap.add_argument("--hide-ptr-all", action="store_true", help="drop every pointer-vs-pointer difference")
    ap.add_argument("--pages", action="store_true", help="also print a per-4KiB-page table of differing dwords")
    ap.add_argument("--watch", action="append", default=[], metavar="VA",
                    help="also print the dword at this VA on every side (repeatable)")
    args = ap.parse_args()

    # ---- resolve inputs
    if args.mac or args.win:
        if not (args.mac and args.win):
            ap.error("--mac and --win go together")
        A, na = load(args.mac, snapname(args.t1))
        B, nb = load(args.win, snapname(args.t1))
        A2, na2 = load(args.mac, snapname(args.t2))
        B2, nb2 = load(args.win, snapname(args.t2))
        la, lb = "mac", "win"
    else:
        if not (args.a and args.b):
            ap.error("give two snapshot files, or --mac DIR --win DIR")
        A, na = load(args.a)
        B, nb = load(args.b)
        A2, na2 = load(args.a2) if args.a2 else (None, None)
        B2, nb2 = load(args.b2) if args.b2 else (None, None)
        la, lb = "A", "B"
    tagA, tagB = la.strip(), lb.strip()
    VA_, VB_ = "VOL-" + tagA.upper(), "VOL-" + tagB.upper()

    print("A (%s): %s  %d bytes" % (tagA, na, len(A)))
    print("B (%s): %s  %d bytes" % (tagB, nb, len(B)))
    if A2 is not None:
        print("A later: %s" % na2)
    if B2 is not None:
        print("B later: %s" % nb2)
    n = min(len(A), len(B))
    if len(A) != len(B):
        print("WARNING: sizes differ (%d vs %d); comparing the first %d bytes" % (len(A), len(B), n))
    for ref, nm in ((A2, na2), (B2, nb2)):
        if ref is not None and len(ref) < n:
            print("WARNING: %s is shorter than the compared range" % nm)
    nd = n // 4
    base = args.base
    print("range: VA 0x%08X .. 0x%08X (%d dwords), base %s" %
          (base, base + nd * 4, nd, "default" if args.base == DEFAULT_BASE else "overridden"))

    VA = struct.unpack_from("<%dI" % nd, A)
    VB = struct.unpack_from("<%dI" % nd, B)
    VA2 = struct.unpack_from("<%dI" % nd, A2) if A2 is not None and len(A2) >= nd * 4 else None
    VB2 = struct.unpack_from("<%dI" % nd, B2) if B2 is not None and len(B2) >= nd * 4 else None
    have_vol = VA2 is not None and VB2 is not None
    if not have_vol:
        print("note: no later snapshot on both sides -> no volatility classification (all diffs shown as UNKNOWN)")

    # ---- zero-chunk warning (fifa14cap leaves an unreadable 64 KiB chunk zero)
    CH = 0x10000
    zruns = {}
    for off in range(0, n - CH + 1, CH):
        za = A[off:off + CH].count(0) == CH
        zb = B[off:off + CH].count(0) == CH
        if za != zb:
            side = tagB if zb else tagA
            r = zruns.setdefault(side, [])
            if r and r[-1][1] == off:
                r[-1][1] = off + CH
            else:
                r.append([off, off + CH])
    for side, rs in zruns.items():
        for lo_, hi_ in rs:
            print("WARNING: VA 0x%08X..0x%08X (64 KiB chunks) is all-zero only on side %s "
                  "(real zeros, or an unreadable chunk in the capture)" % (base + lo_, base + hi_, side))

    # ---- classify every dword
    CLS = {}      # dword index -> (class, ptrflag)
    counts = {"STABLE": 0, VA_: 0, VB_: 0, "VOL-BOTH": 0, "UNKNOWN": 0}
    hidden = 0
    ptrdiff = 0
    for i in range(nd):
        a, b = VA[i], VB[i]
        if a == b:
            continue
        pa, pb = ptr_class(a), ptr_class(b)
        if pa and pb:
            ptrdiff += 1
            if args.hide_ptr_all or (args.hide_ptr and (pa != "I" or pb != "I")):
                hidden += 1
                continue
        if have_vol:
            va_ = VA2[i] != a
            vb_ = VB2[i] != b
            c = "VOL-BOTH" if va_ and vb_ else VA_ if va_ else VB_ if vb_ else "STABLE"
        else:
            c = "UNKNOWN"
        counts[c] += 1
        CLS[i] = (c, (pa or "-") + (pb or "-"))

    total = len(CLS)
    print()
    print("differing dwords shown: %d of %d (%.2f%%)   [%d hidden by pointer filter, %d pointer-vs-pointer in total]" %
          (total, nd, 100.0 * total / nd, hidden, ptrdiff))
    for k in ("STABLE", VA_, VB_, "VOL-BOTH", "UNKNOWN"):
        if counts[k]:
            print("  %-9s %d" % (k, counts[k]))

    # ---- watch list
    for w in args.watch:
        va = int(w, 0)
        i = (va - base) // 4
        if 0 <= i < nd:
            s = "  watch 0x%08X: %s=%08x" % (va, tagA, VA[i])
            if VA2: s += " (later %08x)" % VA2[i]
            s += "  %s=%08x" % (tagB, VB[i])
            if VB2: s += " (later %08x)" % VB2[i]
            print(s)
        else:
            print("  watch 0x%08X: outside the snapshot" % va)

    # ---- per-page table
    if args.pages:
        print("\nper 4 KiB page (only pages with differences): VA  diffs/1024  stable")
        per = {}
        for i, (c, _) in CLS.items():
            p = i // 1024
            d = per.setdefault(p, [0, 0])
            d[0] += 1
            d[1] += c in ("STABLE", "UNKNOWN")
        for p in sorted(per):
            print("  %08x  %4d/1024  %4d" % (base + p * 4096, per[p][0], per[p][1]))

    # ---- group into regions
    idx = sorted(CLS)
    regions = []
    for i in idx:
        if regions and i - regions[-1][1] - 1 <= args.gap:
            regions[-1][1] = i
            regions[-1][2].append(i)
        else:
            regions.append([i, i, [i]])
    rows = []
    for lo, hi, members in regions:
        if len(members) < args.min_dwords:
            continue
        cc = {}
        pt = 0
        for m in members:
            cc[CLS[m][0]] = cc.get(CLS[m][0], 0) + 1
            pt += CLS[m][1] != "--"
        if args.stable_only and not (cc.get("STABLE") or cc.get("UNKNOWN")):
            continue
        rows.append((lo, hi, members, cc, pt))

    print("\n%d region(s)%s (gap<=%d dwords)" % (len(rows), " with stable differences" if args.stable_only else "", args.gap))
    shown = 0
    for lo, hi, members, cc, pt in rows:
        if args.max_regions and shown >= args.max_regions:
            print("... %d more region(s); raise --max-regions" % (len(rows) - shown))
            break
        shown += 1
        desc = ", ".join("%s %d" % (k, v) for k, v in sorted(cc.items()))
        print("\n[%d] VA 0x%08X..0x%08X  span %d dwords, %d differ (%s)%s" %
              (shown, base + lo * 4, base + hi * 4 + 4, hi - lo + 1, len(members), desc,
               ", %d pointer-like" % pt if pt else ""))
        dset = set(members)
        print(preview(A, B, lo, hi + 1, base, dset, args.preview, tagA[:3].ljust(3), tagB[:3].ljust(3)))
        if have_vol:
            vol = [m for m in members if CLS[m][0] != "STABLE"]
            if vol and len(vol) <= 4:
                for m in vol:
                    print("    volatile dword 0x%08X: %s %08x->%08x, %s %08x->%08x" %
                          (base + m * 4, tagA, VA[m], VA2[m], tagB, VB[m], VB2[m]))
    print("\nlegend: '*' marks a differing dword; values are little-endian dwords; hexdump column is the ASCII of that side")
    return 0


if __name__ == "__main__":
    sys.exit(main())
