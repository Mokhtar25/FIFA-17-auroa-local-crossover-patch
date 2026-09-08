# Checkpoint 04 — completed analysis and live-test guide

Saved 2026-09-08. Step 4 of 4 complete after both research agents finished and their findings were integrated.

Main deliverable: [ONLINE-KICKOFF-ANALYSIS.md](../../../ONLINE-KICKOFF-ANALYSIS.md).

The guide incorporates the user's PvP-only clarification, exact local file identities, launcher/version/bottle drift, old Aurora17 redirect evidence, five ranked hypotheses, a timed first session, explicit Reborn/Aurora15 logging commands, packet-capture limits, decision tables, Windows/network/profile comparisons, rollback, and a reusable run record. It distinguishes hypotheses from verified observations and does not claim a gameplay fix.

## Validation

Completed checks: seven Markdown documents had balanced code fences and no trailing whitespace; 12 local links resolved; seven shell code blocks passed `/bin/zsh -n`; all 17 file-identity records had valid SHA-256 format and positive sizes. `git diff --check` passed. No launcher/game command was executed. Syntax checks do not validate live logging propagation, packet capture permissions, server access, or PvP behavior.

Research integration corrected overconfident transport classifications, clarified that a limited packet snapshot can contain partial payload, and avoided recommending stock CrossOver as a kickoff control when required startup patches may be missing.

## Preserved state

All pre-existing tracked modifications and the older untracked handoff remain. Additional unrelated tracked edits appeared during this investigation (Both games.command, diagnostics/README.md, setup-both.sh, setup.sh, tests/test_cleanup.py, tests/test_scripts.py); these were not made or reverted by this task. The final status snapshot is preserved separately. Current script identity should be rechecked when live testing resumes. This task adds only the main Markdown guide and files under `diagnostics/online-kickoff/`. No Git commit or push, game/bottle/hosts modification, live capture, or gameplay test.

## Next live action

In under two minutes, fill the run record's game, actual launcher version, bottle and opponent platform. Then follow the guide's first controlled session for one game. Record the exact kickoff-to-popup interval and both players' outcomes before trying a fix.
