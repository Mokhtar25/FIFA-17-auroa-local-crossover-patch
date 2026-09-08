# Checkpoint 02 — local evidence

Saved 2026-09-08. Step 2 of 4: read-only local inspection complete; research underway.

## Confirmed observations

| Observation | Meaning and limit |
|---|---|
| CrossOver-FIFA.app is 26.3, build 26.3.0.39832; both bottles record that build and D3DMetal/WINE_SIMULATE_WRITECOPY=1 | Shared environment worth controlling; no proof it causes disconnects |
| Supplied Aurora15Connector-2.exe has version resource 1.1.51.0; Aurora15 installed copy is 1.1.64.0; Aurora17 installed copy is 1.1.52.0 | Filename suffix is not release version; September 8 Aurora15 log records 1.1.51.0 followed by 1.1.64.0 |
| Reborn17 3.1.11 update exists in both bottles; supplied file is 3.1.10 | Cached update does not prove execution; record actual version later |
| Downloads/FIFA 17/version.dll contains Aurora17Redirect and has the historical Aurora17 SHA; aurora17-redirect.ini remains | Inspected folder is in old Aurora17 state; unknown whether it is the failed Reborn session's actual game folder |
| Aurora17 hosts maps six names to 127.0.0.1, including gosredirector.ea.com | Potential conflicting routing if Reborn uses this bottle and affected lookups; do not remove blindly |
| Downloads/FIFA 17 has no crumpet.ini, senorclutch.ini, reborn-ca.pem at its root | Reborn binary references these names; absence is a clue, not proof a required file is missing for every profile |
| FIFA15 ItsAMe_Origin.dll currently hashes 5b141fb0…; original Aurora backup hashes 4463ce72… | Current DLL is the historically observed connector-installed variant, not the documented e6b423c5… offline patch; older handoff does not describe current disk state |
| Old cleanup LaunchAgent plist absent | No evidence this removed helper caused current failure; loaded state not checked |

## Available logs and their limits

Reborn17/client.ini exists in Aurora17; no Reborn .log found in the inspected AppData trees. Reborn logs may live elsewhere or require trace support. Aurora15 logs exist in BOTH bottles. September 8 Aurora15 launcher log contains game-folder failures followed by authenticated validation; these are not timestamp-correlated kickoff failures. EA-MITM.log in Aurora15 has two hook initialization sequences from September 7 with no explicit kickoff/disconnect event. Old Aurora17 server log from September 6 contains extensive Blaze/FUT traffic but belongs to a different launcher/server stack. Do not infer Reborn's failure from it.

Raw account/session configuration and wire transcripts were not copied into artifacts. Filtered source excerpts were inspected; sensitive fields were excluded.

## Static capability hints, not runtime facts

Reborn downloaded binary strings include `https://reborn-prod.crummieirc.com`, `https://reborn.crummieirc.com`, `relay-eu-3`, `relay-eu-4`, signed game-profile verification, `version.dll`, `Reborn17Trace.dll` (string has a preceding character in raw scan), and profile repair messaging. Aurora15 binary references `https://aurora15.onlyonemzy.com`, P2P firewall setup, relay fallback, and uniform gameplay-content verification. Strings do not establish active topology, exact ports, trace activation, or current server implementation.

## Instrumentation gap

`setup.sh --play-log` explicitly starts `Aurora17Connector.exe`, not Reborn. Existing `--smoke` measures launch/LSX success, not surviving kickoff. Existing report checks TCP 47170–47173, not actual gameplay UDP. FIFA15 `--bundle`, `--report`, and `--smoke` are unsupported. The installed CrossOver wrapper source supports `--bottle`, `--workdir`, `--cx-log`, `--debugmsg`, and `--cx-app`; direct explicit-launcher commands can be documented for later. Both bottles map `Y:` to /Users/mokhtar and `Z:` to /.

See `02-file-identities.json` for full hashes and sizes. Next: synthesize five falsifiable hypotheses and a minimally instrumented match test, with two-sided timing and separate transport/crash/server outcomes.
