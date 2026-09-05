# FIFA 17 exits 0xC0000005 at the main menu — where this stands

**Status (2026-09-05, second pass):** the earlier root-store hypothesis is
dead, killed by evidence in this repo's own bundles. The crash is real,
deterministic, and so far confined to the one macOS 14 machine. Nothing in
Aurora's logs can locate it; the package now ships the tool that can, and the
launcher no longer misreports it as the start-up race. What is still missing
is one run of that tool on the affected machine.

**Reporter:** a user on macOS 14.6.1 arm64, CrossOver 26.3, bottle `Aurora17`.
Symptom: "game crashes after the start menu." Every machine that plays online
(three bundles, three people) runs macOS 15.7.8 or 26.5.

---

## 1. What the crash is

FIFA 17 reaches the main menu and dies with `0xC0000005` about 50 s after
launch — seven crashes across two bundles, every attempt. Offline play on the
same machine and bottle is fine (user-verified). Every static check passes.

Working and crashing launches are identical at every layer until one moment:

```
working  (+03:00)                       crashing (+01:00)
16:47:37.86  GetProfile  (#3)           14:33:48.57  GetProfile  (#3)
16:47:45.07  GetGameInfo                14:33:56.22  game gone  (+7.65 s)
16:47:45.19  auth code issued (+7.33 s)
```

Same game build (`retail-17.0.3175939.0`), same shim (`3DFC7195D8C6`), same
three patch RVAs, same LSX request sequence, three `GetDefaultUser` calls in
both. In that seven-second window there is no HTTP, no TLS, no server-side
event, no shim event and no error on either machine. The first
`origin-auth-code-entry` never comes on the crashing one. Across the seven
crashes the gap from `GetProfile #3` to death was 7.2, 7.6, 7.7, 9.6, 19.3,
20.0 and 52 s, so it is the login step, not a fixed timer.

## 2. The root-store hypothesis is dead

The first pass proposed that an empty `SystemCertificates\Root` store (0 on
the crashing machine, 163 on the reference one) broke a TLS step. It does not.
The count is a *symptom* of how far a launch got:

- Wine fills that registry key from the Mac's trust store the first time any
  process opens the LocalMachine Root store (`crypt32`
  `CRYPT_ImportSystemRootCertsToReg`). It writes Microsoft's five roots
  **before** asking macOS for the rest, so an import that started at all
  leaves at least five. 0 means no process in that bottle ever opened the
  store.
- On the reference bottle every one of the 163 entries carries registry
  timestamp `1788456140` = 2026-09-03 17:22:20Z. The shim's first ever
  `origin-auth-code-entry` on that bottle is 17:22:22.000Z. The store was
  filled by the login step, two seconds before the hook fired.
- A tester's bottle read 0 in a bundle at 19:58Z on 2026-09-04 and 161 in the
  next one at 21:32Z; the shim log in between shows the first launch that
  ever issued an auth code (20:12:55Z). Same binaries in both bundles.
- The game does not use schannel for EA traffic at all: it uses EA's own
  ProtoSSL and the shim's `proto-ssl-bypass` (Aurora17's
  `New-DevCertificate.ps1` says so in its header).

So the earlier `setup.sh` comment saying "tested and is wrong" was right,
and it now says why. `--report` prints the count with that reading. Do not
make `--verify` fail on it and do not try to fill it.

## 3. What shipped in this pass

| change | where |
|---|---|
| The launcher stops on the first crash instead of relaunching it four times as "the known start-up race". It reads the game's exit code from the connector log; an NTSTATUS (`0xC0000005`, `0xC000001D`, `0xC00000FD`, anything `0xC…`) is now **code 26** with the right words, and the race message carries the code too. | `aurora17/aurora-pwsh.c` (`game_exit_code_from_log`, `fifa_crashed`), rebuilt `powershell.exe` |
| `./setup.sh --play-log` / `diagnostics/12 Play with a crash log.command`: starts the Aurora17 launcher through CrossOver's `--cx-log` so the game's `Unhandled exception code c0000005 … addr` line and the `+loaddll` module map are captured, then prints which module the address is in — or that it is in none (generated code). Quiet channels by default so the timing stays close to a normal PLAY; `AURORA_LOG_LEVEL=full` and `AURORA_CTXLOG=1` for more. | `setup.sh` (`crash_log_summary`, mode block) |
| `--bundle` collects those logs (summary, bounded extract, the newest whole log), and CrossOver's own GUI logs that name the game. `--report` shows the summaries, the Mac model and the OS build. `payload.txt` lists the minimum macOS each shipped Mach-O declares. | `setup.sh` |
| `--verify` notes on macOS 14 that online play is unconfirmed there and names the tool. | `setup.sh` |
| `root_cert_count` no longer prints `0` twice. | `setup.sh` |
| Docs: `0xC0000005` section, code 26, command 12. | `SETUP.md`, `README.md`, `diagnostics/README.md` |

**The affected user must re-run the installer** (`START HERE.command`, or
`8 Set the bottle up again.command`) to get the rebuilt stand-in; `--verify`
says `BAD … not the shipped stand-in` until they do.

## 4. What to do next, in order

1. On the affected machine: quit CrossOver, double-click
   `12 Play with a crash log.command`, press PLAY, let it crash, close the
   launcher, then `1 Collect diagnostics.command`. The bundle's
   `crash-logs.txt` says the exception, the address and the module.
2. Read the module line:
   - **`FIFA17.exe + 0x…`** or another game DLL: the game's own code. Compare
     the offset against the shim's patch sites and the Origin SDK auth path;
     the `+seh` context in a full-level run gives the registers.
   - **`version.dll` (the 223,232-byte one in the game folder)**: the shim.
     Aurora17's, not ours; report to them with the offset.
   - **`crypt32`, `ntdll`, `secur32`, `ws2_32`, `a17hosts`**: ours or
     CrossOver's. Rebuild with symbols and look.
   - **NONE — generated code**: the protector's runtime code, the shape of
     BUGS.md §3 (a wrong-offset decode in an RWX page). That is the Rosetta
     re-translation hole CrossOver's CW HACK 18947 describes. Second run with
     `AURORA_CTXLOG=1` for the `CTXAV` line, then a third with
     `CX_SMC_FLUSH=1` in the bottle's `cxbottle.conf`
     `[EnvironmentVariables]` to see whether forcing re-translation changes
     it. Rosetta on macOS 14 and on 15 are not the same build.
3. If it **does not crash** with the log on: the crash is timing-sensitive
   (BUGS.md §3 saw exactly that). The quiet channel set is already as light
   as a log gets; the next step is a bottle-environment `CX_LOG` with
   `WINEDEBUG=-all` and only `err+seh` left, set by hand.

## 5. Open observations, not conclusions

- **macOS 14 is the only thing that differs.** Same payload hashes on every
  machine (`payload.txt` is byte-identical between the crashing and a working
  bundle). Same bottle settings, same hosts, same shim, same licence loader
  behaviour. SETUP.md has always said "tested on macOS 15".
- **The shipped Mach-O files declare `minos 15.0`** (built with the macOS 26.2
  SDK) while README requires macOS 14. They load on 14.6.1 — `ntdll.so` runs
  every process and offline play is fine — so dyld does not refuse them, and
  nothing in them calls an API newer than 10.15. Kept as an observation; a
  rebuild with `MACOSX_DEPLOYMENT_TARGET=14.0` is cheap insurance once a
  build tree is at hand, but there is no evidence yet that it matters.
- **Rosetta differs between 14 and 15** (AVX support arrived in 15; the
  translation cache behaviour CW HACK 18947 works around is undocumented).
  The rosetta patch's `CX_DR_TRAP=2` and `CX_SMC_FLUSH` are the levers that
  touch it.

## 6. Ruled out, with evidence — do not re-investigate

| Ruled out | Evidence |
|---|---|
| Empty root certificate store | §2: filled *by* the login step, on every machine, two seconds before the first auth hook |
| Wine build, D3DMetal, bottle settings, game files, `a17hosts.dylib` | offline `_fifa17.exe` plays on the same machine, bottle and patched copy |
| EA licence file | `--reseed-licence` wrote a byte-identical blob (`0b758831b7af43da`); crash unchanged. The blob is machine-specific by design; never hardcode a known-good hash |
| Shim mispatching / wrong build | identical shim hash, game build and all three patch RVAs on both machines |
| `GetDefaultUser` "3-call ceiling", `GetProfile #3` | both normal; every working run shows them |
| LSX / HTTP / TLS / server refusal in the window | nothing on the wire on either machine between `GetProfile #3` and the auth request |
| macOS crash report | none; Wine turns the SIGSEGV into SEH and exits with the code. `crash-reports.txt` says so |
| The start-up race (`0x00000003`, ~22 s, `abort()`) | different code, different time, and it clears on relaunch; this never did |

## 7. Code pointers

| What | Where |
|---|---|
| Launcher retry gate and the new crash verdict | `aurora17/aurora-pwsh.c`, `run_play` loop, `game_exit_code_from_log`, `fifa_crashed` |
| `--play-log` mode | `setup.sh`, block `if [ "$MODE" = play-log ]` |
| Summary, collection, report section | `setup.sh`: `crash_log_summary`, `collect_crash_logs`, `crash_logs_report` |
| Root store note and count | `setup.sh`: `root_cert_count` |
| The one-shot `CTXAV` report and `CX_SMC_FLUSH` | `patches/crossover-26.3-fifa17-rosetta.patch` (`drbp_report_av`, `smc_flush_on`) |
| Wine's root import | `dlls/crypt32/rootstore.c` `CRYPT_ImportSystemRootCertsToReg`, called from `store.c` when the LocalMachine `Root` store is opened |
| The shim's log events | `redirect-shim.log` is UTC; connector and client logs are local time |

## 8. Bundles this rests on (user-supplied, in `~/Downloads`)

- `aurora17-bundle-20260905-132914.ebpH7m.zip` — crashing, macOS 14.6.1
- `aurora17-bundle-20260905-143403.VDrqku.zip` — crashing, after the licence reseed
- `aurora17-bundle-20260905-164900.heKB8g.zip` — working, macOS 15.7.8 (in `diagnostics/`)
- `aurora17-bundle-20260904-205827.zip` / `-223209.zip` — one tester, macOS 26.5.2, before and after the first launch that reached the login step (root store 0 → 161)
- `aurora17-bundle-20260904-224943.zip` — offline install, macOS 26.5.1 (root store 0, never online, no crash)

```sh
# per launch: GetDefaultUser calls and auth codes issued
awk '/origin-auth-capability-loaded/{if(l!="")print l" du="du" auth="au; l=$1; du=0; au=0}
     /origin-default-user-result/{du++} /origin-auth-code-issued/{au++}
     END{print l" du="du" auth="au}' <bundle>/logs/redirect-shim.log
# when a bottle's root store was filled (registry key timestamps are unix time)
grep 'Root\\\\Certificates\\\\' "$BOTTLE/system.reg" | awk '{print $NF}' | sort | uniq -c
```
