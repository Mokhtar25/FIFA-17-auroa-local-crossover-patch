# FIFA 17 exits 0xC0000005 at the main menu — where this stands

**Status (2026-09-05, third pass):** two hypotheses are dead. The root store
(second pass) and now macOS 14: the affected user updated to macOS 26.6.2 and
crashes exactly as before. The second pass also misread the window — it said
nothing happens server-side between `GetProfile #3` and the auth code. In a
working run the game's first connection to Aurora (the redirector, then the
Blaze pre-auth exchange) happens right there; the server logs it without a
timestamp, which is why a grep by time missed it. On the crashing machine the
redirector never receives a connection. So the game dies between the main menu
and its first socket. The package now shows that directly in `--report`, logs
every name the bottle resolves in `--play-log`, and collects the Mac's network
set-up in a bundle. What is still missing is the same thing as before: one run
of command 12 on the affected machine. The user has not had the new package
yet — their newest report (17:32 +01:00) came from the old one.

**Reporter:** one user, first on macOS 14.6.1 arm64 and since 2026-09-05
17:32 on macOS 26.6.2, CrossOver 26.3, bottle `Aurora17`. Symptom: "game
crashes after the start menu." Other people on 15.7.8, 26.5.x and 26.6.2 play
online with identical binaries.

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
both. The first `origin-auth-code-entry` never comes on the crashing one.
Across the seven crashes the gap from `GetProfile #3` to death was 7.2, 7.6,
7.7, 9.6, 19.3, 20.0 and 52 s, so it is the login step, not a fixed timer.

**Correction (third pass).** The second pass said that in this window there is
"no HTTP, no TLS, no server-side event" on either machine. Wrong on the
working side. `server-*.log` shows, in a working run and in this order:

```
Redirector <= POST /redirector/getServerInstance
Redirector => 200 273B advertising f17.aurora.test:47173 secure=True
Blaze TLS established: Tls12 TLS_NULL_WITH_NULL_NULL
Blaze frame 0: component=0x0009 command=0x0007 ... (PreAuth)
... 37 frames ...
[16:47:45.646] cdn-http <= GET /routing            <- first timestamped line
POST /v1/origin/auth-codes                        <- the auth code, 16:47:45.19
```

The `RedirectorListener` and `BlazeListener` lines carry no timestamp, so a
grep for `16:47:3x-16:47:4x` never saw them. The redirector request and the
whole Blaze pre-auth exchange sit inside the seven seconds after
`GetProfile #3`: choosing Ultimate Team makes the game open its first
connection to Aurora, do pre-auth, and only then ask the shim for the Origin
auth code.

On the crashing machine every server log of a crashing launch
(`server-20260905-133432/134937/143008/143259.log`) has exactly two
`Redirector` lines and two `Blaze` lines — the "listening on" lines — and no
request. The game never connected. Whatever kills it runs after the menu and
before its first socket to Aurora: the game's own network start-up
(DirtySDK `NetConn`, adapter enumeration), name resolution
(`a17hosts.dylib` → `gosredirector.ea.com` → 127.0.0.1), or the shim's connect
redirect and ProtoSSL bypass. Nothing on the server side can be involved.

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

## 3. What shipped

### Third pass (2026-09-05, evening)

| change | where |
|---|---|
| `--report` gains `how far each launch got`: one line per launch from `redirect-shim.log` (`du=` GetDefaultUser results, `auth=` auth codes issued, with the legend) and, for the newest server log, `redirector requests=N  Blaze TLS=N  Blaze frames=N` with the reading for 0. This is §1's correction, made into a report line so nobody greps by time again. | `setup.sh` `launch_progress` |
| `--report` header gains `tools  setup.sh of <date>, <git hash>` so an old-package report is recognisable at a glance. | `setup.sh` `report_mode` |
| `--play-log` sets `AURORA17_HOSTS_DEBUG=1`; `a17hosts.dylib` now logs unmapped lookups too (`-> real resolver, rc=N`), not only mapped ones. `crash_log_summary` prints the last twelve names looked up with their line numbers against the exception line; the bundle extract keeps up to 200. Debug off, behaviour unchanged; the dylib was rebuilt with build.sh's exact command and `fixes/SHA256SUMS` updated. | `fixes/a17hosts.c`, `fixes/x86_64-unix/a17hosts.dylib`, `setup.sh` |
| `--bundle` writes `network.txt`: hostname, unscoped resolvers (`scutil --dns`), interfaces (`ifconfig -a` without MAC addresses, IPv6 cut to the first group), hardware ports, system proxy settings. | `setup.sh` `collect_network_snapshot` |
| `--verify`'s macOS 14 note no longer ties the crash to macOS 14. | `setup.sh` |
| Docs: SETUP.md `0xC0000005` section rewritten to the new window; diagnostics/README.md. | |

### Second pass (2026-09-05, afternoon)

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

0. **Ship the package.** The branch `diagnose-licence-blob-and-crash-reports`
   is four-plus commits ahead of `main` and has never been pushed or released.
   The user's 17:32 report has no `tools` line, no `mac` line, no crash-log
   section and still says `PowerShell stand-in ... OK` for the old stand-in:
   they are on the old package and the old launcher still relaunched the
   crash as "attempt 2 of 4" (shim log: launches at 16:31:20Z and 16:32:12Z,
   52 s apart). Nothing in §4 can happen until they have the new one. Note
   the `diagnostics/` numbering collides with the `fifa15` branch (there, 11
   and 12 are the FIFA 15 commands) — renumber when syncing.
1. On the affected machine: re-run `START HERE.command`, quit CrossOver,
   double-click `12 Play with a crash log.command`, press PLAY, go to
   Ultimate Team, let it crash, close the launcher, then
   `1 Collect diagnostics.command`. The bundle's `crash-logs.txt` says the
   exception, the address, the module and the last names looked up;
   `network.txt` says what the Mac's network looks like.
2. Read the `names looked up` block first — it bisects the window:
   - **`getaddrinfo(gosredirector.ea.com) -> 127.0.0.1` is there, before the
     exception**: the game resolved the redirector and died connecting to it.
     That is the shim's connect redirect / ProtoSSL bypass or Wine's `ws2_32`
     connect path. Compare against a working machine's log (mine, same
     command) for what follows that line there.
   - **Other names, then the exception, and no `gosredirector`**: it died in
     network start-up before reaching the redirector. Look at which names
     (its own hostname? an EA host that is not in the six mappings, answered
     by the real resolver?) and at `network.txt`: interfaces without IPv4,
     `utun` VPN interfaces, unusual resolvers, a proxy.
   - **No names at all**: it never reached the resolver. Adapter enumeration
     (`iphlpapi` → `getifaddrs`) is the first thing DirtySDK does; again
     `network.txt`.
3. Then read the module line:
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
4. If it **does not crash** with the log on: the crash is timing-sensitive
   (BUGS.md §3 saw exactly that). The quiet channel set is already as light
   as a log gets; the next step is a bottle-environment `CX_LOG` with
   `WINEDEBUG=-all` and only `err+seh` left, set by hand.

## 5. Open observations, not conclusions

- **Nothing in the bundles differs any more.** Same payload hashes on every
  machine (`payload.txt` is byte-identical between the crashing and a working
  bundle). Same bottle settings, same hosts, same shim, same licence loader
  behaviour, and since 17:32 the same macOS as a working user (26.6.2). What
  the bundles have never carried is the Mac's network set-up, which is the
  layer the corrected window points at; `network.txt` fixes that.
- **The licence blob is not machine-unique.** `1027460.dlf` is written by
  `_fifa17.exe` itself (SETUP.md 9a), 1649 bytes on every machine. The
  affected user's was `0b758831b7af43da` on macOS 14 (twice, reseed included)
  and is `9586cf6422fcefad` on 26.6.2 — identical to jaymatharu's (26.5.2,
  plays online). lachlanrenton (26.5.1) and gage.metz4 (26.6.2) share
  `fc6e3f72cad2f488`; mine (15.7.8) is `67d13d48ec5a3435`. So the game's
  machine identity under Wine changes with the OS (Rosetta's CPUID
  presentation is the obvious input) and is coarse enough for unrelated Macs
  to collide. The game accepted every one of these (it reaches the menu), so
  this is not the crash — but "machine-specific, never hardcode" in §6 is
  more precisely "OS/hardware-class-specific; still never hardcode".
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
| macOS 14 / Rosetta version | the same user updated to 26.6.2 (report 2026-09-05 17:32 +01:00) and crashes identically: du=3, no auth code, redirector never contacted; two other users play on 26.6.x |
| The Aurora server refusing or mishandling the game | §1 correction: the crashing launches' server logs show no redirector request at all; the game never reached it |
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
| Launch progress and redirector count in the report | `setup.sh`: `launch_progress` |
| Network snapshot in the bundle | `setup.sh`: `collect_network_snapshot` → `network.txt` |
| Name lookups in the crash log | `fixes/a17hosts.c` (`a17_log`, on with `AURORA17_HOSTS_DEBUG=1`); `crash_log_summary` "names looked up" |
| Redirector / Blaze server-side lines (no timestamps) | `server-*.log`: `Redirector <= POST /redirector/getServerInstance`, `Blaze TLS established`, `Blaze frame N` |

## 8. Separate match-entry crash on macOS 26.6.2

Bundle `aurora17-bundle-20260905-102827.PDkdCG.zip` reports macOS 26.6.2
arm64 and CrossOver 26.3. The user reports connecting successfully, then
crashing when entering a match with the Aurora server running. This is a
different observed failure stage; a shared underlying cause is unproven.
The macOS-14-only observation above concerns the pre-authentication failure,
not all crashes with online features enabled.

The latest launch, on September 5 (bundle-local time, UTC−04:00):

- `10:18:27` and `10:18:37`: three successful Origin auth-code responses.
- `10:19:01.172`: `POST /ut/game/fifa17/match`, with `type: OFFLINE`, returns
  `200 OK` and a 13,156-byte JSON response. This is FUT offline match activity
  while connected to Aurora, not evidence of an online opponent.
- `10:19:12.579`: `PUT /ut/game/fifa17/squad/3` returns `200 OK`.
- `10:19:15.328`: game PID 724 exits with `0xC0000005`, about 93 seconds
  after launch and 48 seconds after its first auth code.

Evidence is in `client-20260905-101741-668.log`,
`connector-20260905-101739-604.log`, and `wire-transcript.log`.
Successful HTTP status codes do not establish that the response contents
are correct. The bundle contains no CrossOver exception log or module map;
neither the exit code nor the last request identifies the faulting code.

Send the updated package, have the user rerun `START HERE.command`, then
use `diagnostics/12 Play with a crash log.command` to reproduce the
**match-entry** crash and `diagnostics/1 Collect diagnostics.command` to
collect it. Compare the exception address/module using section 4 before
grouping this with the pre-authentication crash. No fix for this match-entry
crash has been established.

## 9. Bundles this rests on (user-supplied, in `~/Downloads`)

- `aurora17-bundle-20260905-132914.ebpH7m.zip` — crashing, macOS 14.6.1
- `aurora17-bundle-20260905-143403.VDrqku.zip` — crashing, after the licence reseed
- report pasted 2026-09-05 17:32:22 +0100 (no bundle) — crashing, the same user on macOS 26.6.2, old package: shim log shows launches 16:31:20Z (du=3, no auth) and 16:32:12Z (the old launcher's relaunch), licence now `9586cf6422fcefad`
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
# did any game in a server's lifetime reach the redirector? (these lines have no timestamps)
grep -c 'Redirector <= ' <bundle>/logs/server-*.log
```
