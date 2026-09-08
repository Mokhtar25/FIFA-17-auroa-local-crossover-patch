# Shared-runtime compatibility research

Saved 2026-09-08 (Europe/Istanbul). Static research only: no game, launcher, or server program was executed, and no configuration was changed.

## Finding

There is not enough evidence to call this a Wine socket bug. The later clarification that kickoff fails only against another player, while online play against AI works, raises peer/relay transport and player-to-player synchronization above generic rendering or game-start causes. Both games using the same CrossOver 26.3/macOS host keeps that shared layer in scope, but version drift and gameplay-data validation remain credible alternatives.

The next useful result is a branch: establish whether a PvP packet flow or Winsock call fails at kickoff, or whether bidirectional traffic remains healthy while the server rejects the match or the two clients diverge.

## Evidence boundaries

### Local evidence

- `fixes/a17hosts.c` interposes only `getaddrinfo()` and `gethostbyname()`. It does not interpose `socket`, `connect`, `send`, `recv`, polling, or time APIs. Its debug lines can prove which address a name resolved to; they cannot prove packet delivery.
- `setup.sh --play-log` is specific to the old Aurora17 layout. It discovers and launches `Aurora17Connector.exe`, reads `%LOCALAPPDATA%\Aurora17\Logs`, and selects CrossOver logs containing `FIFA17.exe|Aurora17Connector`. The repository has no Reborn-specific path, process, or log handling.
- FIFA 15's offline and connector modes are mutually exclusive in the current project. `fifa15-offline.sh` modifies `ItsAMe_Origin.dll` for direct offline use; `fifa15/README.md` requires reverting the offline patch before Aurora15Connector installs its supported DLL and says to launch from the connector while its client remains listening on port 3216.
- `patches/crossover-26.3-fifa17-online.patch` changes PE virtual-memory reporting plus certificate/private-key handling. It does not change Winsock send, receive, polling, or UDP behavior. The patch filename does not establish coverage of match gameplay.

Read-only artifact inspection elsewhere in this investigation found unresolved identity drift: a Reborn 3.1.11 update is cached although the supplied installer is 3.1.10; the supplied Aurora15Connector reports 1.1.51 while installed copies report 1.1.52 and 1.1.64; Aurora15 material exists in both bottles. Those facts do not show which executable handled either failed match. They make an exact run manifest the first test prerequisite.

### Sourced general facts

Wine's upstream `ws2_32` implementation sends Windows socket work through AFD I/O controls, translates the resulting NT status to Winsock errors, and has trace points for addresses, connect, send/receive setup, polling/event selection, socket options, shutdown, and status. The source declares the `winsock` debug channel. [Wine `ws2_32/socket.c`](https://github.com/wine-mirror/wine/blob/master/dlls/ws2_32/socket.c#L27-L32), [connect path](https://github.com/wine-mirror/wine/blob/master/dlls/ws2_32/socket.c#L1281-L1317), [send/receive paths](https://github.com/wine-mirror/wine/blob/master/dlls/ws2_32/socket.c#L1013-L1123)

Wine treats reset, hangup, read, write, and connect-error readiness as distinct socket events. Its `select()` path includes reset/hangup in the read set and connect errors in the exception set. [Wine `ws2_32` polling](https://github.com/wine-mirror/wine/blob/master/dlls/ws2_32/socket.c#L2729-L2770), [Wine server socket events](https://github.com/wine-mirror/wine/blob/master/server/sock.c#L1205-L1287)

Microsoft documents that `WSAECONNRESET` on a UDP send/receive path may report that a previous send elicited ICMP “Port Unreachable.” Wine maps `STATUS_PORT_UNREACHABLE` and several reset statuses to `WSAECONNRESET`. Thus error 10054 plus a matching ICMP packet is an ordinary transport outcome; error 10054 alone is not proof of a compatibility defect. [Microsoft `WSASendTo`](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsasendto), [Wine status mapping](https://github.com/wine-mirror/wine/blob/master/dlls/ws2_32/socket.c#L561-L640)

Wine's trace header can add Wine tick-count timestamps and process IDs through the `timestamp` and `pid` channels; a thread ID is present in each normal header. [Wine `ntdll/thread.c`](https://github.com/wine-mirror/wine/blob/master/dlls/ntdll/thread.c#L125-L147). CodeWeavers documents `CX_LOG`, `CX_DEBUGMSG`, and **Run with Options → Create log file** as CrossOver's supported log route. [CodeWeavers: Creating a Debug Log](https://support.codeweavers.com/2-creating-a-debug-log)

Apple documents `tcpdump` as macOS's built-in packet capture tool. Darwin's `pktap` pseudo-interface can include loopback plus physical/tunnel interfaces and can preserve process, PID, interface, and direction metadata in pcap-ng. [Apple: Recording a Packet Trace](https://developer.apple.com/documentation/network/recording-a-packet-trace), the installed macOS `man tcpdump` reference (verify supported pktap options locally before use)

CodeWeavers describes D3DMetal as a Direct3D 11/12 translation layer and MSync as Mach-semaphore synchronization whose performance effect varies by application. These are legitimate controlled variables after transport is characterized, not evidence of the present cause. [CodeWeavers: Advanced Settings in CrossOver Mac 26](https://support.codeweavers.com/miscellanous/advanced-settings-in-crossover-mac-26). Apple documents Metal HUD and Instruments Game Performance/Metal System Trace for frame-time variation and CPU/GPU timelines. [Apple: Monitoring Metal graphics performance](https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance/), [Apple: Analyzing Metal performance](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app)

Apple states that Rosetta translates an entire x86_64 process on Apple silicon. That makes Rosetta part of the shared execution stack, but Apple does not document a FIFA timing or socket failure and the current evidence does not show one. [Apple: Rosetta translation environment](https://developer.apple.com/documentation/Apple-Silicon/about-the-rosetta-translation-environment)

### Untested hypotheses

| Hypothesis | Why it fits | Evidence that would weaken it |
|---|---|---|
| PvP direct/relay transition | AI online works; a remote player introduces a peer, relay, NAT traversal, or new bidirectional flow at kickoff | No new flow at kickoff and the existing flow stays bidirectional past the popup |
| Cross-client sync or gameplay-data mismatch | PvP requires both clients to agree; multiple connector versions/caches and cross-bottle material are present | Executed and gameplay-data hashes match a known-good pair, and server logs accept both |
| macOS firewall, VPN, NAT, or route interaction | Apple confirms its firewall governs incoming connections; peer/relay UDP may first matter at PvP kickoff | Host capture shows both directions healthy, no ICMP/reset, and the same route succeeds on a native control |
| Wine Winsock semantic mismatch | Both games use the same patched runtime; polling, async I/O, UDP errors, or an unsupported socket control could be shared | Host packets and `+winsock` calls/statuses agree with a Windows control and no relevant `fixme:winsock` occurs |
| PvP heartbeat/simulation timing | PvP kickoff begins real-time input exchange and heavier simulation | Frame time is stable, transport is timely, and server gives a non-timing rejection reason |

The firewall is a test target only if the capture shows an incoming-flow problem. Apple says unapproved incoming attempts can be denied until the user answers the alert; do not disable the firewall as a first diagnostic step. [Apple: Block connections with a firewall](https://support.apple.com/en-gb/guide/mac-help/mh34041/mac)

## Transport versus synchronization decision rule

| Observation in the same 10-second kickoff window | Classification | Next evidence |
|---|---|---|
| FIN, RST, ICMP unreachable, repeated unanswered UDP, or a socket timeout/reset appears before the popup | Relevant transport failure is a candidate; establish that this is the match flow and precedes teardown | Identify which peer sent it and compare server plus native-Windows control; do not yet blame Wine |
| Host capture has outbound packets but the matching peer/server capture does not | Network path/NAT/firewall candidate | Compare routes, VPN, firewall state, and relay selection |
| Host capture receives a packet but Wine does not complete the corresponding receive, or Wine reports successful send with no host packet | Wine/runtime boundary candidate | Compare native Windows and, only if it can reach this test, a controlled CrossOver copy retaining required startup fixes; preserve socket API/status sequence |
| Bidirectional packets and successful Winsock statuses continue through the popup, with a server validation/reason code | Cross-client/server rejection | Compare game-data preset, connector version, protocol/build ID, and both clients |
| Bidirectional packets continue but heartbeat/input cadence pauses with a frame-time spike and server timeout/desync | Timing/simulation candidate | Repeat a controlled performance A/B; one factor per run |

Encrypted traffic can show endpoints, direction, size, cadence, retransmission, ICMP, FIN, and RST. It cannot reveal a proprietary validation reason. That reason must come from launcher/client/server logs or project maintainers.

## Later live-test sequence

### 1. Freeze identity before changing anything

For each game, record the bottle, launcher path and displayed version, launcher SHA-256, actual game executable SHA-256, injected/replaced DLL hashes, game-data/preset version, both players' connector versions, opponent, mode, CrossOver build, macOS build, graphics backend, MSync state, and local/UTC start time. Preserve each launcher's update log.

**Green:** every path and hash is known, both players use the intended build/data, FIFA 15 uses the connector-supported DLL, not the offline patch, and the server confirms the expected gameplay data. **Red:** any executed path remains unknown, versions change during launch, cross-bottle material is selected, or the two players/server disagree. A red result stops compatibility attribution until identity is fixed.

### 2. Reproduce once with only a bounded packet capture

Use a 60–90 second header-limited pcap-ng capture covering lobby → PvP kickoff → popup. On macOS, `pktap,all` includes loopback and tunnels; a lower-noise alternative is `pktap,lo0,<active-interface>` after `networksetup -listallhardwareports` identifies the active interface. A suitable capture shape is:

```sh
sudo tcpdump -i pktap,all -n -s 128 -w YYYYMMDD-HHMM-game-kickoff.pcapng
```

Stop it immediately after the popup. Record exact UTC times for pressing the final match-start control, kickoff animation, and popup. The 128-byte snapshot retains transport headers and packet lengths while reducing payload exposure. If process metadata identifies traffic under a host Wine process rather than `FIFA15.exe`/`FIFA17.exe`, use the observed identity; do not assume the Windows process name is present.

**Provisionally healthy transport:** the identified PvP flow stays bidirectional without reset/ICMP or a timeout-sized gap until after the popup; this does not prove that the packets contain valid gameplay or were consumed by the game. **Red for transport:** a reset, unreachable, one-way flow, or cadence loss precedes the popup. “No packets” is invalid until the selected interfaces are proven to include loopback plus active/tunnel paths.

### 3. Repeat with launcher-accurate CrossOver socket tracing

Use CrossOver **Run with Options** on the exact launcher in the proven bottle with `+winsock,+timestamp,+pid`. For Reborn, do not use this repository's `--play-log`: it launches Aurora17Connector and searches Aurora17 paths. For FIFA 15, run the connector with its supported installed `ItsAMe_Origin.dll`, reverting the offline patch first if present; do not use the offline-patched DLL.

Capture packets at the same time only after Step 2 proves the symptom is stable. Search the CrossOver log around kickoff for `connect`, `send`, `recv`, `select`/event calls, `status`, `WSAGetLastError`, and `fixme:winsock`, especially any `SIO_UDP_CONNRESET` call. Compare socket handle, endpoint, status, and timestamp order rather than payload.

**Green for Wine boundary:** API results agree with host capture: successful sends become host packets, received host packets complete receives, and resets/timeouts have wire evidence. **Red for Wine boundary:** repeatable disagreement occurs in three equivalent runs and does not occur in a native-Windows control. One disagreement under heavy logging is insufficient because tracing can alter timing.

### 4. Obtain the server-side match decision

For the same run ID and UTC window, collect both clients' launcher logs and the server's session/match log. Ask the operator for both join results, selected direct/relay route, gameplay protocol/build identifiers, gameplay-data/preset hashes, first gameplay packet times, last heartbeat/input times, and disconnect reason code. Do not infer protocol meaning from strings embedded in a launcher binary.

**Green for data/validation:** the server accepts both builds and gameplay presets and records normal gameplay packets. **Red:** it rejects or substitutes a build/preset, selects a failed direct/relay path, or emits a validation/sync reason at kickoff. A generic client popup without server reason is inconclusive.

### 5. Test frame/simulation timing only after healthy transport

First record a 5–10 second Instruments Game Performance or Metal System Trace centered on kickoff, following Apple's recommended short capture window. Then repeat the same opponent/mode three times with one low-impact performance variable changed, such as a supported frame cap or lower render load. Keep launcher, game data, network, backend, and MSync fixed. Test MSync or backend only as a later separate pair because either changes a broad runtime layer.

**Green for timing sensitivity:** baseline fails 3/3, the single-variable condition passes 3/3, the server's validation/build result is unchanged, and packet cadence/heartbeat plus frame-time stall change together. This supports a timing-sensitive path; it still does not identify a Wine bug. **Red:** outcome does not track the variable, frame times are stable, or the server reports a deterministic data rejection.

## Instrumentation limits

- `+winsock` records API activity and statuses, not decrypted gameplay payload. `a17hosts` debug records resolution only. Neither replaces a packet capture or server reason code.
- `+relay`, full `+seh`, and broad “all channels” logs are too intrusive for the first timing comparison and can be extremely large. Use the narrow channel set after a packet-only baseline.
- Packet captures can expose peer IPs, ports, traffic timing, and up to the selected snapshot bytes. Keep them private, use a short window, avoid `-A/-X`, and share a redacted textual flow summary when raw packets are unnecessary.
- Wine `+timestamp` uses Wine tick count, while pcap uses host timestamps and project logs may use UTC or local time. Record explicit UTC markers and timezone; align events before comparing them.
- Upstream Wine master documents the mechanisms but is not byte-identical to CodeWeavers' patched Wine 11.0 in CrossOver 26.3. Check surprising results against the exact CrossOver source/build before filing a Wine claim.

## Result required before proposing a fix

A compatibility fix is justified only after one repeated red criterion identifies a boundary: exact artifact mismatch, server validation/synchronization, host network path, Wine API-to-host discrepancy, or performance-linked heartbeat failure. Until then, changing socket behavior, resolver code, firewall rules, D3DMetal, MSync, Rosetta controls, or game files would mix hypotheses and make the result harder to interpret.

Integration note: do not replace the patched runtime with stock CrossOver as the first control: the repository documents required startup fixes. Broad runtime replacement may prevent reaching kickoff and make the comparison inconclusive.
