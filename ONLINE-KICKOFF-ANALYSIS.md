# FIFA 17 + FIFA 15: PvP disconnect at kickoff

**Superseded on 2026-09-08 by live results: see [HANDOFF-pvp-desync.md](HANDOFF-pvp-desync.md).** Two captured matches showed a clean transport and a game-reported desync (`GDESYNCEND`); the network hypotheses below are ruled out for FIFA 17. Kept for the method and the FIFA 15 notes.

**Start here during live testing: [first controlled session](#first-live-session).**

Prepared 2026-09-08, Europe/Istanbul. Completed static analysis; see the final verification checkpoint. No game, launcher, or game server was started during this investigation. No gameplay fix has been applied or verified.

## Current answer

**The strongest working hypothesis is a failure in the PvP connection or match-start synchronization. The root cause is still unconfirmed.** Both games reach their online services, and the user clarified that the disconnect happens **only against another player**. That narrows the investigation beyond generic login, certificate, or offline gameplay failures. Different launchers and servers do not prove a single shared bug: they share this Mac, network, and CrossOver installation, and could also have separate faults with the same popup.

The first live test must distinguish three outcomes: gameplay traffic never becomes bidirectional; traffic arrives but match setup/synchronization fails; or a game/helper process exits and the disconnect is a consequence. Successful sign-in, a working FUT menu, and surviving an AI match do not establish a working PvP path.

There is also a concrete baseline problem: the inspected FIFA 17 folder and Aurora17 bottle still contain the old Aurora17 redirect setup, while the requested launcher is Reborn17. Installed launcher versions differ from the files named in the request. Establish what actually launches before changing network settings.

## What is known, and what is not

| Item | Evidence | Confidence / limit |
|---|---|---|
| FIFA 17 uses Reborn17; FIFA 15 uses Aurora15Connector | User report and supplied executable paths | Confirmed task scope; running versions not yet established |
| Both reach online services but disconnect at PvP kickoff | User report, including “only another player” | Reported behavior; no timestamped reproduction captured here |
| AI is not the reported failure | User clarification | Recheck the same online mode during the controlled session |
| Both use a common patched CrossOver environment | Local app/bottle inspection | CrossOver-FIFA 26.3, build 26.3.0.39832 |
| Exact popup, match mode, opponent setup, server region, host/guest role | Not supplied or correlated in logs | Record during the first test; do not guess |

There is no proven kickoff trace, no demonstrated Windows comparison, and no verified live server-side reason code in the evidence examined. Whether the first kickoff touch, first input, a fixed timeout, or the transition into the match triggers the disconnect remains open.

## Artifact and bottle identity

The suffix `-2` in a downloaded filename is not a software version. Record both the launcher initially opened and any updated launcher process it starts.

| Artifact | Version evidence | Size | SHA-256 prefix |
|---|---|---:|---|
| `~/Downloads/Reborn17-3.1.10.exe` | Version resource 3.1.10.0 | 488,448 | `aa404d8e3540ded1` |
| Reborn update cached in **both** Aurora17 and Aurora15 AppData | Version resource 3.1.11.0 | 502,272 | `4d86c8b93388658f` |
| `~/Downloads/Aurora15Connector-2.exe` | Version resource 1.1.51.0 | 10,112,000 | `d72650e612e3d3ac` |
| Aurora15Connector installed inside Aurora15 bottle | Version resource 1.1.64.0 | 10,671,104 | `081c454524d8badb` |
| Aurora15Connector installed inside Aurora17 bottle | Version resource 1.1.52.0 | 10,118,144 | `fbe03fd3fb6dda0b` |

Full hashes and exact locations are in [file identities](diagnostics/online-kickoff/checkpoints/02-file-identities.json). These are September 8 disk observations, not guarantees about later updates. The Aurora15 log records 1.1.51.0 followed by 1.1.64.0 on September 8. A cached Reborn update proves download/storage, not that it ran.

Both bottles map `Y:` to `/Users/mokhtar` and `Z:` to `/`. Thus different bottles can still modify the **same physical game folder**. Bottle separation alone does not isolate game DLLs, game data, or macOS network ports. The existence of another launcher's files in a bottle does not prove that launcher was active at failure time.

## Local findings that change the test plan

### FIFA 17: the inspected installation still reflects Aurora17

`~/Downloads/FIFA 17/version.dll` hashes `3dfc7195d8c69eef27f1cede0738946fbe827a61704b7100321e6e627c4bf19c`, contains the string `Aurora17Redirect`, and matches the historical Aurora17 shim in this repository's diagnostics. `aurora17-redirect.ini` is present. The root of this folder has no `crumpet.ini`, `senorclutch.ini`, or `reborn-ca.pem`; the supplied Reborn executable references those names, but strings alone do not show which files every supported profile requires.

The Aurora17 bottle's hosts file currently sends these six names to `127.0.0.1`:

```text
f17.aurora.test
gosredirector.ea.com
easw.easports.com
content.lt.easfc.ea.com
pal.gt.easfc.ea.com
pg.fifa12.test.easportsworld.ea.com
```

The installed resolver design reads the bottle hosts file before falling back to macOS. This is a potential Reborn conflict **only if the failed run uses this bottle, game folder, and affected lookups**. Reborn might install a different profile at launch, intercept another boundary, or use another folder. Inspect the loaded DLL path and post-launch hashes before concluding anything. Do not delete hosts mappings or swap `version.dll` experimentally without a backed-up, supported profile and a rollback plan. See [resolver source](fixes/a17hosts.c).

### FIFA 15: online and offline modes are distinct

The current `ItsAMe_Origin.dll` hash is `5b141fb03c6f50228e48ddaf8dfb49428194a1f01be1a63c826c5bce4dec487a`, the variant historically observed after connector installation. It is **not** the documented offline-patched `e6b423c5…` file. A verified original backup `ItsAMe_Origin.dll.aurora15.bak` remains. Hash identity does not prove the current version is the correct one for every newer connector.

The repository documents an Origin stand-in on local TCP 3216 and a native `dinput8` hook. Its offline patch is for direct offline launch and must not be used as a PvP fix. The documented “Repair connection” action can kill the connector's own client under Wine; do not use it as an exploratory step. See [FIFA 15 mode instructions](fifa15/README.md) and [prior Wine findings](patches/README-fifa15-wine-fixes.md).

The inspected `EA-MITM.ini` describes redirecting `ProtoSSLConnect`, includes redirect destination ports 42230 and 17502, and says its connect and update stages are separate. Those are static configuration values, **not a verified PvP gameplay port list**. A breakpoint on only Winsock `connect` can miss the earlier hook decision and connectionless UDP traffic.

### Shared patches and cleanup

Both bottles use D3DMetal and `WINE_SIMULATE_WRITECOPY=1`. Aurora17 additionally records `CX_DR_TRAP=2`; Aurora15 records `CX_TOPDOWN_LIMIT=0x1ffffffff`. These are compatibility settings, not established disconnect causes. Disabling several at once would destroy the useful comparison.

The patch named [fifa17-online](patches/crossover-26.3-fifa17-online.patch) changes virtual-memory reporting and certificate/private-key handling. It does not implement a PvP UDP fix. The [hosts shim](fixes/a17hosts.c) interposes `getaddrinfo` and `gethostbyname`, not send/receive or match synchronization.

The old cleanup LaunchAgent plist is absent on this Mac. Loaded-job state was not checked. Current repository scripts remove the old agent; an older handoff describing installation is stale. Do not blame cleanup without a timestamped helper/process exit. `Stop.command` affects all CrossOver bottles, so use it only after saving other work and collecting the failed session's evidence.

## Available logs: useful history, missing kickoff evidence

| Location | Observation | Use |
|---|---|---|
| `diagnostics/report.txt` | September 5 Aurora17 report | Historical setup/login evidence; not Reborn PvP evidence |
| Aurora17 bottle `%LOCALAPPDATA%\Aurora17\Logs` | Connector/client/server logs, including September 6 Blaze traffic | Old stack; do not interpret a peer closing here as Reborn's kickoff cause |
| Aurora15 bottle `%LOCALAPPDATA%\Aurora15Connector\logs\launcher.log` | September 8 version changes, game-folder errors, later authenticated validation | Establish launcher/version/setup timeline; no correlated kickoff failure |
| Aurora15 bottle `%LOCALAPPDATA%\Aurora15Connector\logs\EA-MITM.log` | September 7 hook initialization sequences | Evidence a hook initialized then; no explicit kickoff/disconnect reason found |
| Reborn17 AppData in inspected bottles | Config/update files; no Reborn `.log` found in inspected trees | Log destination/support remains to be established; absence is not proof no logging exists |

Aurora15 logs also exist in the Aurora17 bottle. Use the actual running bottle's logs. September 8 launcher errors about a missing game folder precede the later successful validation and must not be presented as the explanation for a match that already reached kickoff.

## Five hypotheses, ranked for testing

These are falsifiable hypotheses, not diagnoses. Ranking reflects the PvP-only symptom and the inspected state.

| Rank | Hypothesis | Prediction | Discriminating evidence / what weakens it |
|---|---|---|---|
| 1 | PvP peer/relay path fails: NAT filtering, wrong interface/address, failed relay selection or allocation | Control-service traffic works but expected gameplay exchange is absent, one-way, or aimed at an unreachable endpoint | Match-correlated traffic on both endpoints plus actual peer/relay assignment. Sustained valid gameplay exchange before an explicit synchronization rejection weakens a pure reachability explanation |
| 2 | Wrong launcher profile, routing, bottle, or updated client combination | Loaded shim/config or advertised endpoint belongs to another stack, or the launcher/version differs from the intended baseline | Confirm loaded DLLs, selected game path, hashes before/after launch and supported profile. A documented clean profile fixes only that variable and survives repeated matches; correct identical profiles weaken it |
| 3 | Peer game-content/build mismatch causes rejection or desynchronization | Transport is established, but peers disagree at match initialization or first simulation exchange | Compare supported executable/data/profile versions and server validation reason. Matching approved content plus no data/desync rejection weakens it; arbitrary DLL removal is not a test |
| 4 | CrossOver/Wine/Rosetta behavior affects peer networking, synchronization, or helper lifetime | Windows control works while equivalent Mac sessions fail, with a reproducible API/exit/timing difference | Match Winsock events to packets and process exits. Passing Windows only narrows to the Mac path; it does not distinguish macOS networking from Wine without further evidence |
| 5 | Server/opponent/session-state issue at the PvP transition | Server logs reject membership/state, relay allocation, host migration, or session liveness at the same timestamp; Windows peers may fail too | Two Windows peers on the same server/mode and a second known-working opponent. Consistently Mac-only failure across controls weakens a general server outage |

Online AI passing lowers the priority of generic rendering/startup faults but does not rule out a timing or synchronization bug that only matters between peers. If failure follows one opponent, investigate that peer and the pair's path before changing both games. Different servers can still share protocol assumptions or upstream code; no shared implementation has been established here.

## What research can and cannot establish

Wine exposes a `winsock` trace channel for socket calls and statuses. That can connect a Wine operation to an observed socket, but it is not a substitute for packets or proof of remote delivery. Source is upstream Wine, not a verified exact match for all CrossOver 26.3 internals. [Wine socket implementation](https://github.com/wine-mirror/wine/blob/master/dlls/ws2_32/socket.c)

CrossOver supports a log file and explicit Wine channels. The installed wrapper was read and supports the options used below; the launch commands have **not** been executed. [CodeWeavers logging instructions](https://support.codeweavers.com/2-creating-a-debug-log)

UDP NAT mapping and filtering behavior can affect peer communication independently of an already working client/server connection. That is a mechanism to test, not evidence that either launcher uses a particular NAT traversal protocol. Do not assume STUN, TURN, ICE, UPnP, a port range, or relay protocol without this stack's documentation or observed traffic. [IETF UDP NAT requirements](https://www.rfc-editor.org/rfc/rfc4787)

Static launcher strings suggest relay-related capabilities in both programs and uniform gameplay-content checks in Aurora15. Strings may be unused or describe optional paths. Public-source research and its limits are recorded separately in [network research](diagnostics/online-kickoff/research/network-primary-sources.md) and [compatibility research](diagnostics/online-kickoff/research/compatibility-primary-sources.md).

<a id="first-live-session"></a>

## First controlled session: 25–40 minutes

Complete this for **one game first**, preferably the one with an available known-working opponent. Do not change both installations before learning from the first failure.

1. **Identify the exact run — 5 minutes.** Record game/mode, launcher displayed version, actual executable path, bottle, game folder, server/region, opponent platform/version and who invites whom. Save screenshots of these non-secret fields. Preserve hashes/config backups before allowing profile repair or an update. If the launcher updates, label the new version as a new baseline.
2. **Establish the AI control — 5 minutes.** In the same online profile, run an AI match through kickoff for 2 real minutes. Record process survival and whether online menus still respond. Do not apply the offline patch to obtain this control.
3. **Capture one PvP failure — 5–10 minutes.** Use ordinary launcher logging and the timeline below, without heavy Wine tracing first. Record exact popup text on both machines, whether the match clock moves, first touch/input, return-to-menu behavior, and whether each game/launcher/helper stays alive. Save logs immediately after the failure and before cleanup.
4. **Repeat the same pairing once — 5–10 minutes.** Same server, profile, opponent and network. Add a bounded packet capture if prepared. Record elapsed time from both matchmaking and kickoff; a constant timeout from matchmaking can merely expire at kickoff. Do not change settings yet.
5. **Choose one branch — 5–10 minutes.** Use the evidence table below. Select a Windows control, a network-path test, profile validation, or focused Wine logging; do not run every experiment by default. Save a run checkpoint before proceeding.

**Red:** reaches a PvP match, then the reported disconnect occurs at/near kickoff, with exact elapsed time and both participants' observations recorded. Login failure or inability to find an opponent is a different failure and makes this run inconclusive for the kickoff bug.

**Provisional green:** both players remain connected, both inputs affect the match, and the match continues for at least 2 real minutes after kickoff. **Fix accepted:** three consecutive PvP kickoffs survive and at least one full match completes and reports a normal result, for each game separately. A functioning menu or AI match alone is not green.

After **three failed fixes**, stop changing settings and name the doubtful assumption, for example: “We assumed packets were blocked, but never captured the selected relay path.” Re-read evidence and revise the hypothesis. Repeated baseline reproductions are measurements, not separate attempted fixes.

## Timestamped run record

Save one `run.md` per attempt. Use UTC wall time in the notes; Wine trace timestamps can be relative tick counts, so record the wall-clock launch anchor as well. Have both players note their clock offset rather than assuming clock synchronization.

```text
Run ID: YYYYMMDDTHHMMSSZ-fifa17-baseline-01
Game / exact PvP mode:
Launcher initially opened / displayed version / actual running version:
Bottle / actual game folder / loaded shim path:
Game build / profile or content version / hash manifest:
Server and region / match ID (keep privately):
Mac runtime / opponent platform and version:
Network interface / VPN state / same LAN or separate networks:
Inviter / invitee (do not assume this equals network host):
Single change since prior run: NONE
UTC launch:
UTC authenticated:
UTC matchmaking started:
UTC peer matched / loading began:
UTC kickoff visible:
UTC first input or ball touch:
UTC popup on Mac / exact text:
UTC popup on opponent / exact text:
Match clock reached / elapsed real seconds from kickoff:
Game / launcher / helper PIDs before and after:
Returned to menu? Online menus still work?
Observed endpoint tuples / relay assignment / last traffic time:
Server reason / first relevant error / missing evidence:
Result: RED / PROVISIONAL GREEN / INCONCLUSIVE
Next single test / prediction / rollback:
```

## Correct launcher logging commands — later only

Do **not** use `./setup.sh --play-log` or diagnostic number 12 for this Reborn test: they explicitly start `Aurora17Connector.exe`. Existing `--smoke` tests startup/LSX, not PvP. FIFA15 `--bundle`, `--report`, and `--smoke` are unsupported. Existing TCP checks for 47170–47173 do not cover unknown gameplay UDP endpoints.

The lower-friction alternative is CrossOver-FIFA → correct bottle → exact launcher → **Run with Options → Create log file**, then set channels. Check that the shortcut does not select the old Aurora17 executable. The following Terminal form gives explicit identity; choose **one** game block. Run only when live testing is available, with previous game sessions closed normally.

### Create a private run directory — 30 seconds

Run in a new Terminal. Keep these variables in that Terminal for the launch command.

```sh
cd /Users/mokhtar/Downloads/FIFA-17-crossover-patch-work
umask 077
KICKOFF_RUN="$PWD/diagnostics/online-kickoff/runs/$(date -u '+%Y%m%dT%H%M%SZ')"
mkdir -p "$KICKOFF_RUN"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$KICKOFF_RUN/launch-anchor.txt"
KICKOFF_WINE='/Applications/CrossOver-FIFA.app/Contents/SharedSupport/CrossOver/bin/wine'
KICKOFF_CHANNELS='-seh,err+seh,-unwind,+process,-module,-threadname,+loaddll,+timestamp,+pid'
```

This is the low-volume process/module baseline. It retains error-level exceptions while suppressing routine exception/unwind chatter from protected executables. It can still contain private data. Do not enable every trace channel.

### FIFA 17 / Reborn supplied executable

```sh
"$KICKOFF_WINE" --bottle 'Aurora17' \
  --workdir '/Users/mokhtar/Downloads' \
  --cx-log "$KICKOFF_RUN/reborn.cxlog" \
  --debugmsg "$KICKOFF_CHANNELS" \
  --cx-app 'Y:\Downloads\Reborn17-3.1.10.exe'
```

### FIFA 15 / Aurora supplied executable

```sh
"$KICKOFF_WINE" --bottle 'Aurora15' \
  --workdir '/Users/mokhtar/Downloads' \
  --cx-log "$KICKOFF_RUN/aurora15.cxlog" \
  --debugmsg "$KICKOFF_CHANNELS" \
  --cx-app 'Y:\Downloads\Aurora15Connector-2.exe'
```

These paths match this Mac's inspected drive mappings. Substitute the confirmed launcher executable if testing an installed update, and record its hash. A launcher may hand off to an updated process and exit; keep the run directory and verify that the **game process itself** appears in the trace. If the handoff loses logging, launch the confirmed installed executable directly in the same bottle for a separately labelled run. Do not defeat update requirements to force an obsolete client.

For one focused socket repeat, append `,+winsock` to `KICKOFF_CHANNELS` before launch. For the stale-hosts hypothesis, prefix the launch command with `AURORA17_HOSTS_DEBUG=1` to request the shipped resolver's lookup trace. This variable only helps if that resolver is loaded, and it is not a universal Reborn debug option. No undocumented `Reborn17Trace.dll` injection or activation is proposed.

Verbose tracing can alter timing and produce large files. Capture only the minimum launch-to-failure interval, then repeat a candidate passing setup without heavy tracing. Do not interpret a logged nonblocking operation as a fatal failure without its completion/error context.

## Observe processes and sockets — later only

At the menu, loading screen, and immediately after the popup, record observations in a second Terminal. Replace the directory value with the **same absolute run directory** created above.

```sh
KICKOFF_RUN='/absolute/path/to/the/current/run'
date -u '+%Y-%m-%dT%H:%M:%SZ' >> "$KICKOFF_RUN/observations.txt"
ps -axo pid,ppid,etime,comm | rg -i 'fifa|aurora|reborn|wine|crossover' >> "$KICKOFF_RUN/observations.txt"
/usr/sbin/lsof -nP -iUDP -iTCP >> "$KICKOFF_RUN/sockets.txt"
```

`comm` avoids intentionally collecting full command-line arguments, which may include credentials. Socket output includes other applications and private endpoint addresses; keep it local. Wine process names can obscure which Windows program owns a socket, so correlate OS PID, Wine PID, launch log and time. A listening TCP socket is not a gameplay exchange; UDP may have no `LISTEN` state. Short-lived sockets can be missed by a snapshot.

Where needed, select the game/helper OS PIDs after identifying them and record per-PID sockets with `lsof -a -p PID -nP -i`. If the game closes, preserve its exit status and matching macOS crash report before starting another run. A helper exit **before** the disconnect is different from normal shutdown **after** it.

## Packet capture — later, 60–120 seconds per attempt

Use this only for the transport branch. Capture the interval from just before matching/loading until 15 seconds after the popup, then press **Ctrl-C** in each capture Terminal. Inspect tcpdump's dropped-packet count before treating missing traffic as evidence. Apple documents macOS packet tracing and the need to select the correct interface. [Apple packet-trace guide](https://developer.apple.com/documentation/network/recording-a-packet-trace)

List interfaces with `sudo /usr/sbin/tcpdump -D`. Obtain the default route with `/sbin/route -n get default`. Do not assume the default interface is the gameplay route: check `/sbin/route -n get PEER_OR_RELAY_IP` after learning the actual endpoint. A tunnel, relay, or local helper can require a different interface. Use the appropriate IPv6 route lookup if the observed endpoint is IPv6.

Start with these two capture surfaces, in separate Terminals. Replace placeholders; `en0` is an example, not a determined interface. These commands require local administrator approval when run and were not run during analysis.

```sh
# Terminal A: actual peer/relay-facing interface, initially discover TCP/UDP/ICMP.
sudo /usr/sbin/tcpdump -i en0 -n -s 128 -U \
  -w '/absolute/path/to/the/current/run/network.pcap' \
  '(udp or tcp or icmp or icmp6)'
```

```sh
# Terminal B: local game/helper traffic, if this stack uses loopback.
sudo /usr/sbin/tcpdump -i lo0 -n -s 128 -U \
  -w '/absolute/path/to/the/current/run/loopback.pcap' \
  '(udp or tcp or icmp or icmp6)'
```

The 128-byte snapshot is for endpoints, sizes, timing and transport headers. It may contain partial payload, cannot guarantee header-only collection, and can truncate protocol data needed for deeper decoding. Narrow subsequent captures to observed endpoints. A full-payload capture should be a separate deliberate test on the relevant traffic, not the default. These unrotated examples require the operator to stop them at 120 seconds; they do not automatically stop.

The public API's HTTPS host need not be the gameplay endpoint. Avoid an initial filter limited to TCP 443, old Aurora ports, or a guessed UDP port. If a VPN is involved, capture its actual routed interface as well as necessary outer traffic; encrypted outer packets alone cannot identify application messages. If the opponent can capture their own traffic, compare both sides' timestamps and endpoint tuples. Do not collect someone else's machine traffic without their participation.

Wireshark can summarize conversations and packet rates after capture. A UDP packet seen leaving this Mac is not proof the peer received it. A reply seen on the Mac interface is not proof Wine delivered it to the game. A TCP FIN/RST after a disconnect may be cleanup. UDP error 10054 can follow an ICMP Port Unreachable response; correlate the tuple and packet rather than treating it as proof of a Wine defect. [Microsoft WSASendTo errors](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsasendto) Encrypted packet flow alone cannot establish a game's semantic desync reason.

## Read the evidence before choosing a change

| Observation at kickoff | Next bounded action | What it can establish |
|---|---|---|
| No candidate gameplay flow on chosen interface | Check actual endpoints, tunnel/loopback route and capture drops; then inspect socket creation/send calls | Distinguishes missing capture coverage from no attempted gameplay transport |
| Mac sends, no corresponding reply reaches Mac | Compare opponent/relay view and endpoint assignment; test one alternate network path | Local filtering, NAT, peer reachability or relay allocation becomes plausible; outbound-only is not enough to identify which |
| Replies reach interface, but Wine/game does not consume them | Match socket tuple/PID and Winsock receive/event trace in one repeat | Narrows toward host filter or Wine delivery/API behavior; may still be unrelated packets |
| Sustained exchange, then explicit match rejection or desync | Compare approved game/profile/content versions and server reason | Tests application-level validation; packet quantity alone is not proof valid gameplay traffic |
| Game/client/helper exits or resets before popup | Preserve exit code/crash evidence and compare lifetime on Windows | Establishes whether disconnect follows process loss; does not prove why it exited |

Winsock `WSAEWOULDBLOCK` (10035) may be normal for nonblocking sockets, and pending overlapped work needs completion evidence. Bind errors such as 10048 deserve an owner/tuple check; timeouts or resets need a timeline. Interpret the observed API and error together using [Microsoft Winsock errors](https://learn.microsoft.com/en-us/windows/win32/winsock/windows-sockets-error-codes-2).

## Controlled comparisons after the baseline

Run only the next test justified by the preceding evidence. Estimated time is per game, excluding finding an opponent or downloading content.

| Test | Keep fixed / change only | Interpretation | Estimate |
|---|---|---|---|
| Two known-working Windows peers on the same server/mode | Match approved versions/content; use separate player accounts | Failure here weakens a Mac-only explanation; success is the reference flow | 10–15 min |
| Mac vs the same known-working Windows opponent | Same service/region/mode and comparable content | Mac-only failure narrows to Mac setup/path; it does not alone prove a Wine bug | 10–15 min |
| Same Mac pairing via a second network | Keep game/profile/opponent fixed; change access path, preferably without adding a VPN | Success implicates the original path; hotspot failure does not clear NAT because mobile networks can also restrict peers | 10–15 min |
| Validated launcher profile/content in an isolated test copy | Preserve original bottle **and physical game folder**; use documented supported setup and same server | Improvement supports setup/content conflict; a full clean-copy change is broad and needs later minimization | 15–30 min plus copy time |
| One targeted runtime/relay/role comparison | Choose one supported option based on trace; preserve every other setting | A supported relay selector, invitation-role reversal, or single runtime setting may distinguish a branch; invitation role is not proof of network host | 10–15 min |

If no Windows machine or supported relay selector is available, mark that comparison unavailable. Do not replace it with an unverified assumption or install a new runtime merely to fill the table. A same-LAN success can test a local path, but hairpin routing or a mandatory relay may still be involved; establish topology from evidence.

Do not begin with broad port forwarding, DMZ, disabling the firewall, clearing all hosts entries, changing IPv6 globally, replacing Wine DLLs, or removing compatibility patches. Once a trace establishes a specific blocked path or option difference, propose a narrow reversible change and record its original value. Confirm before any destructive action.

## Preserve each run and make checkpoints regularly

Checkpoint after the baseline, after **every single-variable experiment**, and before any update/profile/registry/game-file change. Raw evidence belongs in a new private run directory, not a shared public issue or commit.

1. **Save raw evidence — 1 minute.** Keep this run's launcher/game logs, Wine log if used, packets if used, timeline and exact popup. Preserve timestamps and the corresponding log interval rather than selecting only the newest unrelated file.
2. **Record the result — 1 minute.** Fill `run.md`: one changed variable, prediction, actual outcome, pass/fail/inconclusive and next action. Record both endpoint observations.
3. **Preserve file identity — 1 minute.** Hash actual running launcher, game executable, loaded shims and relevant content manifest before/after any repair. Do not hash only the original download if an update ran.
4. **Record rollback — 1 minute.** Name the saved bottle/config/game-file copy and original option value. A bottle backup does not restore DLLs in Downloads. Preserve existing `.before-*` and `.aurora15.bak` files.
5. **Prepare a shareable extract — 2 minutes.** Redact account IDs, tokens, cookies, passwords, authorization headers, tickets and private endpoint/account details as needed. Keep consistent labels such as PEER_A across extracts; retain the private originals for correlation.

Raw configs such as `account.json`, `client.ini`, connector settings, access sessions, wire transcripts and packet payloads may contain secrets. Do not copy whole AppData trees into a public artifact or assume the older bundle script's redaction covers Reborn. Nothing is uploaded by this guide. The commands may produce root-owned pcaps; read/copy them with appropriate local permissions instead of changing permissions broadly.

## Developer/server handoff if the cause remains unresolved

Prepare this locally; the investigation has not contacted anyone. Share only when authorized.

```text
Subject: [FIFA 15 or FIFA 17] PvP ends at kickoff; online AI control passes

Launcher actual version/hash, game build/profile, CrossOver build:
Server/region/mode, UTC window, private match/correlation ID:
Opponent platform/version and inviter/invitee:
Exact popup, kickoff-to-failure seconds, both endpoints' outcome:
Whether game, launcher, and local helper remained alive:
Observed assigned peer/relay tuple and packet flow (sanitized):
Earliest correlated socket/process/server error:
Windows control / alternate-network / supported-content comparison:
Attached minimal redacted log window and run record:

Please identify the match state transition and first disconnect reason,
selected direct/relay topology and endpoint assignment, relay allocation or
reachability failure, content/build validation mismatch, and which side
initiated teardown. Please distinguish an initiating error from cleanup.
```

A terminal “peer closed” entry or the generic disconnect popup does not establish the initiator. Request the events **before** the teardown, with comparable timestamps from the affected client, opponent, and server.

## Completion and resumption

This work's deliverable is a static analysis and a live-test procedure. It does not claim the kickoff bug is fixed. There is no automated regression test exercising this PvP symptom because the required live players/server session is unavailable.

The existing repository edits were preserved. No Git commit, push, installation, binary patch, hosts change, gameplay launch, server probe, or packet capture was performed for this task. Public documentation browsing and read-only local inspection were used. Two lower-model research subagents contributed independent notes.

Resume from [the post-agent checkpoint](diagnostics/online-kickoff/checkpoints/03-agents-complete.md) and [final verification](diagnostics/online-kickoff/checkpoints/04-final-verification.md). The next useful evidence is one exact Reborn or Aurora15 PvP run with confirmed executable/bottle/profile, UTC kickoff and disconnect times, process survival, and the opponent's result.

**Next action — under 2 minutes:** fill the game, actual launcher version, bottle and opponent platform fields in the run record before the next live session.
