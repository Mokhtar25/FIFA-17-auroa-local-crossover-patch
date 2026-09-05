# Handoff: FIFA 17 crashes 0xC0000005 at the Origin auth step

**Status:** root cause narrowed to one step, one strong correlation, and one
in-repo note that contradicts it. Not closed. Read "The contradiction" before
acting on the hypothesis.

**Reporter:** a user on macOS 14.6.1 arm64, CrossOver 26.3, bottle `Aurora17`.
Symptom as reported: "game crashes after the start menu."

---

## 1. The symptom, precisely

FIFA 17 launches, reaches the menu, then dies with **`0xC0000005`**
(STATUS_ACCESS_VIOLATION), 48–59 s after launch. Six occurrences across two
bundles, every attempt, no exceptions. Offline play on the same machine and the
same bottle is unaffected.

The connector misreports it:

```
WARN  Fresh admitted FIFA17 process (pid 684) exited with code 0xC0000005.
INFO  FIFA 17 quit 48 seconds in with the licence file present.
      This is the known start-up race; trying again (attempt 2 of 4)...
```

That is wrong and it matters. The documented start-up race (SETUP.md,
`0x00000003 — the start-up race`) is a C-runtime `abort()` at ~22 s. This is a
segfault at ~50 s. The retry gate keys on *duration + licence present* rather
than exit code, so it burns four launches on a deterministic fault and sends
users to race remedies that cannot help. **That gate is in the closed connector,
not in this repo.**

---

## 2. The decisive evidence: working vs broken

The two runs are identical at every layer until one instant. Diffing a working
bundle against a broken one is what found this; nothing in the broken bundle
alone was enough.

### The instant they diverge

Both runs make three `GetProfile` calls over LSX, at the same cadence. Then:

**Working** (`client-20260905-164700-680.log`, +03:00):

```
16:47:37.862  GetProfile #3
16:47:45.074  GetGameInfo
16:47:45.193  Issued one PID-bound Aurora17 Origin auth-code response to FIFA17.   <-- +7.3s
16:47:45.655  Issued one PID-bound Aurora17 Origin auth-code response to FIFA17.
16:47:46.073  GetProfile #4  ... #5, #6, #7
16:48:31      exited 0x00000000   (clean, user quit)
```

**Broken** (four separate runs, +01:00): `GetProfile #3`, then nothing, then
`0xC0000005` at **+7.18 s, +7.66 s, +19.3 s, +19.97 s**.

The fault lands in the same window where the working run receives its auth code.

### Shim event counts, whole bundles

| `redirect-shim.log` event | working | broken |
|---|---:|---:|
| `origin-auth-code-entry` | 9 | **0** |
| `origin-auth-code-pipe-request` | 9 | **0** |
| `origin-auth-code-issued` | 9 | **0** |
| client `Issued one PID-bound …` | 3 | **0** |
| `origin-auth-code-sync-bridge-enabled` | 12 | 24 |
| `origin-auth-code-sync-bridge-failed` | 55 | 7 |

The broken side is **zero, not refused**. The game never reaches the shim's
auth-code entry point. Note the bridge *arms* in both, and the working machine
logs `...-failed` far more often while playing fine — SETUP.md already says that
message appears on machines that work, so do not chase it.

### The environment difference

| | working | broken |
|---|---|---|
| bottle root certificates | **163** | **0** |
| macOS | 15.7.8 arm64 | 14.6.1 arm64 |
| CrossOver | 26.3 | 26.3 |
| game build | `retail-17.0.3175939.0` | same |
| shim | `3DFC7195D8C6` (223,232 B) | same |
| shim patch RVAs | `0x06F28790` / `0x048ACF60` / `0x06F340AF` | **all identical** |

---

## 3. Hypothesis

The Origin auth-code step is the first thing in the launch that needs **TLS**.
Everything before it — LSX handshake, `GetProfile`, `GetGameInfo`, the ebisu
gate — is plaintext on a local socket, which is exactly why the broken run is
indistinguishable from the working one until that instant.

With an empty root store there is no trust anchor for the handshake to the local
redirector, and the game faults instead of failing gracefully.

This explains every observation: offline never touches TLS; all static checks
pass because none of them tests the root store; the shim looks healthy because
it *is* healthy.

## 4. The contradiction — read this before acting

`setup.sh:1454-1460`, written by an earlier investigation, says the opposite:

```
# Reported by --report only, as an observation. A fresh bottle has an empty
# root store and a working one had 163 certificates, so the count is worth
# having in a diagnosis -- but it is NOT known to cause anything. The theory
# that an empty store was what stalled a fresh bottle was tested and is wrong:
# a full game session on a fresh 64-bit bottle left the count at 0. Treat
# it as an open question rather than acting on this number.
```

Both can be true only if that earlier test session never reached the Origin auth
step. "A full game session" is ambiguous and may have been single-player.

**The decisive check:** find that earlier session's bundle and grep its
`redirect-shim.log` for `origin-auth-code-issued`.

- **Present** → an empty root store is compatible with successful auth. The
  hypothesis is dead and the 163-vs-0 correlation is a coincidence between two
  machines that differ in other ways. Look elsewhere.
- **Absent / no bundle** → the earlier test never exercised this path, it does
  not refute anything, and the hypothesis stands.

Do not update `--verify` to fail on a zero count until this is settled. If it
resolves in favour of the hypothesis, that check is the fix that would have
caught this on the user's first run.

---

## 5. Ruled out, with evidence — do not re-investigate

| Ruled out | Evidence |
|---|---|
| Wine build, D3DMetal, macOS 14.6.1, bottle settings, game files, `a17hosts.dylib` | `_fifa17.exe` (offline) plays fine on the same machine, same bottle, same patched CrossOver. User-verified. |
| EA licence file | `--reseed-licence` produced a **byte-identical** blob (`0b758831b7af43da` before and after). Crash persisted afterwards. |
| player-head cache (`error 5` on quarantine/delete) | Offline works with the same Documents folder. |
| Shim mispatching / wrong build | Identical shim hash, game build and all three patch RVAs on both machines. |
| `GetDefaultUser` "3-call ceiling" | **Normal.** All 12 working runs also show exactly 3. |
| `GetProfile #3` being anomalous | **Normal.** The working run makes it too. |
| macOS crash report | None exists. Wine converts the SIGSEGV to SEH and handles it in-process, so macOS records nothing. Confirmed on the user's machine. |

### Dead ends already walked

1. **Graphics/D3DMetal at menu build.** Plausible until offline was tested. Killed by the A/B.
2. **Wrong licence blob.** The blob is machine-specific — the user's loader makes `0b75…`, the working machine's makes `67d1…`. Same size (1649 B), different bytes, both correct for their own machine. **Do not hardcode a known-good licence hash**; it would false-alarm every user.
3. **Shim hook exhaustion after 3 calls.** Refuted by the working bundle.

---

## 6. Open questions

1. Does an empty root store actually break the auth handshake? (§4)
2. Why is this bottle's root store empty when another bottle on 26.3 has 163?
   Population happens at bottle creation; his may predate a step or have been
   made differently. 163 → 0 is *nothing loaded*, not partial failure.
3. Is the empty store a cause or a symptom of the same underlying thing?

---

## 7. Code pointers

| What | Where |
|---|---|
| `root_cert_count` — counts `SystemCertificates\Root\Certificates\` in `system.reg` | `setup.sh:1461` |
| The "observation only" comment that contradicts the hypothesis | `setup.sh:1454-1460` |
| Where the count is printed (report only, never a check) | `setup.sh:2456` |
| `--verify` licence check — tests existence only | `setup.sh:2262` |
| `seed_bottle_licence` — short-circuits on existence | `setup.sh:1689` |
| `ensure_licence` — same, on the PLAY path | `aurora17/aurora-pwsh.c:530` |
| `collect_crash_reports` — added during this investigation | `setup.sh:2607` |
| TLS-related Wine patches (ours) | `patches/crossover-26.3-fifa17-online.patch`, `...-cng.patch` |

**Not in this repo:** the Aurora17 connector and its redirect shim
(`version.dll`, `3dfc7195d8c69eef`, 223,232 B, installed into the game folder).
`NOTICE.md` lists Aurora17 under "Not included, and not ours to include." Do not
confuse it with `fixes/x86_64-windows/version.dll` (`8692fefeff4ede61`,
77,704 B), which is Wine's and *is* built here.

### Minor bug noticed in passing

`root_cert_count` (`setup.sh:1461`) prints `0` twice when the count is zero:
`grep -c` outputs `0` **and** exits non-zero, so the `|| print -r -- 0` fallback
also fires. Visible in the user's report as two lines. Cosmetic.

---

## 8. Reproducing / data

Bundles used (user-supplied, in `~/Downloads`):

- `aurora17-bundle-20260905-132914.ebpH7m.zip` — broken, 3 crashes
- `aurora17-bundle-20260905-143403.VDrqku.zip` — broken, post-licence-reseed
- `aurora17-bundle-20260905-164900.heKB8g.zip` — **working**, the one that cracked it

Useful one-liners:

```sh
# does a bundle ever issue an auth code?
grep -c origin-auth-code-issued <bundle>/logs/redirect-shim.log

# GetDefaultUser calls per run
grep -c origin-default-user-result <bundle>/logs/redirect-shim.log

# exit codes across every launch
grep -h "exited with code" <bundle>/logs/connector-*.log
```

Note when correlating: `redirect-shim.log` is UTC; connector and client logs are
local, and the two machines here are `+01:00` and `+03:00`.

---

## 9. What shipped during this investigation

Branch `diagnose-licence-blob-and-crash-reports`, commit `9c178d8`:

- `--reseed-licence` + `diagnostics/11 Re-seed the licence file.command` — makes
  the loader write a fresh licence and prints the hash before and after. Used to
  eliminate the licence theory in one double-click.
- `collect_crash_reports` in `bundle_mode` — keeps any macOS crash report for the
  game, Wine or CrossOver, and writes an explicit "none, and here is why" note
  when Wine handled the fault itself.

Both are diagnostics. Neither fixes the crash.

## 10. Immediate advice for the affected user

Offline works — single player, career and kick-off are all available via
`PLAY FIFA 17 offline.command`. Online and Ultimate Team are broken until this
is resolved.
