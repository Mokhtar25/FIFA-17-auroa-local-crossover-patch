# Why FIFA and Aurora stay running after CrossOver is gone

This replaces the background cleanup agent, which was a 30-second poll
installed on every user's Mac. That is not an acceptable thing to ship, and
it was treating a symptom. This is what the symptom is.

## What is actually left behind

The agent kept a log, so there is a record rather than a theory. Seventeen
runs over four days on the development machine:

| runs | live processes found | stale server dirs |
|---|---|---|
| 3 | 1, 10, 9 clients + 1 wineserver | 0-6 |
| 14 | **none** | 1-7 |

Two of the three real ones (2026-09-05 01:43 and 02:06) are the interesting
ones: nine or ten Wine clients, one wineserver, and two processes holding the
Aurora ports. Every run after 2026-09-05 16:49 found nothing alive at all.

So the strays are real but rare, and fourteen of seventeen wake-ups were the
agent cleaning up after nothing.

## The mechanism

Three things stack up, and only the last one is ours to fix.

**1. The Aurora connectors are servers. Nothing ever tells them to stop.**
`Aurora15Connector` and `Aurora17Server` listen on 3216 and 47170-47173 and
keep listening after the game exits, because that is what they are for. The
two port-holding pids in the log above are these. No amount of quitting the
game reaches them.

**2. A wineserver lives exactly as long as its last client.** CrossOver 26.3
does not start it persistent -- there is no `-p` in the launch path, and
`wineserver --persistent` is only reachable by hand. So a wineserver that is
still up 45 seconds after CrossOver quit is not the cause of anything: it is
evidence that a client is still up. That client is normally the connector
from (1), or one of the bottle's own Windows services that ignored
`WM_ENDSESSION`. Those reparent to launchd and keep the prefix's `/tmp`
lock, which is the state `--unstick` exists for.

**3. Closing the window is not quitting.** CrossOver's
`applicationShouldTerminateAfterLastWindowClosed:` returns false; it stays in
the menu bar with the bottle live. A real Cmd-Q does try to shut the bottles
down -- `cxbottle` runs `wineboot.exe --end-session --shutdown --force
--kill` and waits five seconds -- but that path can be cancelled, and it
reports "There are still applications running" and aborts rather than
forcing. Most people close the window and believe they have quit.

## Why no background process replaces it

A stray connector costs a held port and a locked bottle. Both of those only
matter at the **next** launch. Nothing degrades while the Mac sits idle, so
there is nothing that has to be noticed within 30 seconds, and no reason to
run code on somebody's machine between one play session and the next.

`Stop.command` (`./setup.sh --shutdown`) does the whole sweep in the right
order, `./setup.sh --unstick` frees a bottle whose session outlived its
wineserver, and `./setup.sh --verify` reports leftovers without touching
them. Sessions started by our own launchers still clean up on exit through
their existing traps.

## The second bug the agent had

`our_server_dirs()` walks **every** bottle under the bottles directory, not
the two this package owns. It is used to decide which `/tmp` server
directories may be deleted and which pids may be signalled. Inside
`--unstick` that is defensible: it refuses to run while any CrossOver is
open, so anything still in a prefix is an orphan by definition.

Inside an unattended timer it was not. On the development machine that set
was nine bottles -- Rocket League, EA App, WinRAR, heroic. On a user's Mac,
45 seconds after they quit CrossOver, the agent was entitled to kill Wine
processes and remove server directories belonging to bottles that have
nothing to do with FIFA. Nobody hit it, and it would have been a bad way to
find out.

## Still unverified

The chain in (2) is read off CrossOver 26.3's own code and Wine's, not off a
captured failure: no session was traced from a live connector through
Cmd-Q to a surviving pid. Reproducing it means launching the game and
quitting CrossOver with a `ps` snapshot on either side. Until that is done,
treat "which client keeps the wineserver up" as the likely answer rather
than the proven one -- the connector is the strongest candidate because it
is the one holding the ports in the log.
