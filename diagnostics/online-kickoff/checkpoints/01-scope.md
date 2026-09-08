# Checkpoint 01 — scope and baseline

Saved 2026-09-08 (Europe/Istanbul). Step 1 of 4 underway.

User reports both FIFA 17 through Reborn17 3.1.10 and FIFA 15 through Aurora15Connector 2 can connect online, but an online match ends with a disconnect message at kickoff. Different launchers and servers; common Mac/CrossOver environment. Live testing is unavailable. Deliver static analysis and a complete Markdown live-testing guide; no claimed fix.

Repository HEAD: `96b43a149e7e19c15a82bda9ff94ed398f61c047`. Existing modified files: MANUAL.md, PLAY FIFA 17 offline.command, README.md, SETUP.md, START HERE offline.command, START HERE.command, Stop.command, diagnostics/_action.zsh, uninstall.sh. Existing untracked HANDOFF-dual-fifa-and-cleanup.md. Preserve all. Checkpoints are files, not Git commits; do not revive prior handoff instructions to publish.

Launcher identities (read-only inspection; neither executed):

| File | SHA-256 | Format |
|---|---|---|
| /Users/mokhtar/Downloads/Reborn17-3.1.10.exe | aa404d8e3540ded16c6e52b71e852c781f20e516bb369aa29b213e215396f287 | PE32+ x86-64 Windows GUI |
| /Users/mokhtar/Downloads/Aurora15Connector-2.exe | d72650e612e3d3ac130308a7c25e8ae37b989b115163a2bc21a588851bb498e6 | PE32+ x86-64 Windows GUI |

Existing diagnostics/report.txt is dated September 5 and describes Aurora17, not the supplied Reborn launcher. Old startup/authentication investigations do not establish the kickoff cause. Current scripts remove an old background cleanup agent; an older handoff describes installing it and is stale on that point.

Method: diagnosing-bugs and research skills, with the user's explicit no-live-testing scope overriding the diagnosis skill's prerequisite for a live reproducer. Hypotheses will be labelled untested. Research subagents explicitly authorized with lower models and no inherited conversation. No launcher/server/game execution or configuration changes.

Next: inspect available local evidence, research primary sources, then design a timestamped pass/fail live loop.
