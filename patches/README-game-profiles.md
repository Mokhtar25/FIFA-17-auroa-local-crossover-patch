# Game profiles: each FIFA picks its own Wine workarounds

`crossover-26.3-game-profiles.patch`, unix ntdll only. `build.sh` applies it
last, after every other patch.

## Why

Each game's workaround used to be a bottle-wide environment variable in
`cxbottle.conf`: `CX_TOPDOWN_LIMIT` for FIFA 15, `CX_DR_TRAP=3` and
`CX_FIFA16_DSTFIX` for FIFA 16, `CX_DR_TRAP=2` for FIFA 17 and 21. That only
works while a bottle runs one game. The community launchers (Aurora.exe,
Impulsum17, CAS, RebornFUT) start several FIFA games out of one bottle, and
each game then ran with whatever the bottle was set up for. FIFA 15 in the
Aurora17 bottle got FIFA 17's `CX_DR_TRAP=2` and no `CX_TOPDOWN_LIMIT`, and
died with 0x80000004 -- the crash `CX_TOPDOWN_LIMIT` exists to prevent.

The settings belong to the game, not the bottle, so ntdll now looks them up
by the game's exe name.

## What it does

Once per process, in `start_main_thread`, right after `init_startup_info` has
the main exe's path and before any guest code runs, `cx_profile_init`
(`dlls/ntdll/unix/loader.c`) takes the file name of the exe and resolves
three settings. For each one, the first of these that says anything wins:

1. `HKCU\Software\Wine\AppDefaults\<exe>\CrossOver-FIFA`, REG_SZ values
   `DrTrap`, `TopdownLimit`, `Fifa16DstFix`. Same syntax as the environment
   variables; `Fifa16DstFix` also takes `off`. An empty value counts as not
   there (setup.sh reads them the same way).
2. The same key's `Profile` = `fifa15` | `fifa16` | `fifa17` | `fifa21` |
   `none`. For a renamed exe, or (`none`) to switch the table off for one exe
   and fall back to the bottle's variables. An unknown name is ignored with a
   warning.
3. The built-in table, exe name compared case-insensitively:

   | exe | profile | CX_DR_TRAP | CX_TOPDOWN_LIMIT | CX_FIFA16_DSTFIX |
   |---|---|---|---|---|
   | fifa15.exe | fifa15 | 0 | 0x1ffffffff | off |
   | fifa16.exe | fifa16 | 3 | off | auto (`=0`) |
   | fifa17.exe, _fifa17.exe | fifa17 | 2 | off | off |
   | fifa21.exe, fifa21_trial.exe | fifa21 | 2 | off | off |

   FIFA 15's `CX_DR_TRAP` is `CX_FIFA15_DR_TRAP` at the top of the table, the
   one place to change it.
4. The bare environment variable, exactly as before. This is what every
   process the table does not name keeps getting: the launchers, WebView2,
   .NET helpers, Wine's own services.
5. Off.

A profile sets all three settings, including the ones it turns off. That is
the point: FIFA 15 in a bottle that says `CX_DR_TRAP=2` must get 0, not 2.

Child processes resolve their own profile from their own exe; nothing is
inherited. FIFA 17's `/dbrv` relaunch is the same exe, so the same profile.

`CX_GAME_PROFILES=0` ignores layers 1-3: the old behaviour, setting for
setting. `WINEDEBUG=+cxprofile` (or `--debugmsg +cxprofile`) logs one line
per process:

    CXPROFILE exe=fifa15.exe profile=fifa15 source=table dr_trap=0 topdown=0x1ffffffff dstfix=off image_size=0x514d1 checksum=0x0005cc3e

`source` is the highest layer that contributed. `image_size` and `checksum`
are the PE file size and header checksum, to tell two builds of one game
apart in a report.

## The details that are easy to get wrong

**Nothing may cache before the profile is known.** `drbp_mode`, the dst fix
and the top-down limit each used to read their variable once and keep it.
`save_context` asks `drbp_mode` on every signal, so a signal taken before
`cx_profile_init` would have pinned the process to its bottle's value for
good. The readers now call `cx_dr_trap()`, `cx_fifa16_dstfix()` and
`cx_topdown_limit()`, which answer from the bare variables until the profile
is resolved, and from the profile after. The bare variables are parsed once,
first thing in `start_main_thread` (or on the first getter call, if anything
comes earlier), into statics of their own (`cx_env`) that only ever give that
pre-profile answer: no `getenv` per signal, and nothing read early can stand
in for the profile. The bare variable rather
than "off" because that is what the old build answered at that moment, and it
is what `virtual_map_user_shared_data` (which runs earlier still) already
acted on. No guest code has run before the switch, so nothing can be armed
under the old value.

**Mode 3 needs a second view of KUSER_SHARED_DATA**, and
`virtual_map_user_shared_data` sets it up before the exe name is known -- only
when the bottle-wide variable says 3. When a profile resolves to 3 and the
bottle did not, `virtual_alias_user_shared_data` maps it inside
`cx_profile_init`. The reverse case (bottle says 3, profile says 0 or 2) keeps
the extra view; it is read-only and only mode 3's fault path looks at it.

**PF_PAE_ENABLED cannot be per game.** It lives in KUSER_SHARED_DATA, which
the process that boots the wineserver session fills in once for every process
in it. Whichever exe happened to start the session would decide it for all.
So it stays a bottle setting: `CX_PF_PAE=1` turns it on, and a bare
`CX_DR_TRAP=3` still does too. 64-bit Windows always reports PF_PAE_ENABLED,
so turning it on for a launcher bottle changes nothing anyone could object to.
`CX_PF_PAE` is honoured with `CX_GAME_PROFILES=0` as well; it is not part of
the per-exe layer.

## Testing it

`tests/profiles/profile_probe.c` reports, from inside the process, the
top-down address, PF_PAE_ENABLED, whether a self-armed and a cross-thread
execute breakpoint fire (which tells modes 0, 2 and 3 apart), and whether an
access through a complemented pointer reaches the handler already fixed.
`tests/profiles/run_probes.sh <copy of the app> [bottle]` copies it under
every name above and runs the matrix (no env, each game's old bottle env,
`CX_GAME_PROFILES=0`, `CX_PF_PAE=1`, AppDefaults aliases and overrides, a
launcher in a path with spaces starting `C:\Games\FIFA 15\fifa15.exe`, and
`drrf_test.exe` renamed `fifa16.exe` with no env at all, which needs the
mode-3 second view). Each row is checked against the table above, both what
ntdll logged (`CXPROFILE`) and what the probe saw (`PROBE`), plus an
AppDefaults row with empty values (which must count as absent); the script
prints `ALL n CHECKS PASSED` and exits 0, or names each mismatch and exits 1.
Run it against a `cp -c` copy of the app with a throwaway bottle, never the
one you play in.

Results 2026-10-11, CrossOver 26.3 sources, with the shipped
`fixes/x86_64-unix/ntdll.so`: all 95 checks passed; every row as the table above
predicts; with `CX_GAME_PROFILES=0` every row follows the bare variables
(an earlier run of the same matrix found those rows identical to the previous
`ntdll.so`); `drrf_test` as `fifa16.exe` with no
variables 7/7 (3/7 with profiles off, the stock result).

Not tested: the real games. The probe shows each process gets the settings
the table gives it; that FIFA 15 then starts from the Aurora17 bottle is the
next thing to check.
