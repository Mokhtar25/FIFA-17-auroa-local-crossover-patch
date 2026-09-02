# Wine fixes found while chasing the FIFA 15 start-up crash, and the one that was not Wine

Patches against `crossover-sources-26.3.0`. Since the `fifa15` branch, `build.sh` applies
`crossover-26.3-topdown-alloc-limit.patch` after the four FIFA 17 patches; it is env-gated, so
FIFA 17 is unaffected. The others here are records of the investigation and are not built.
Full history lives outside the repo (the FIFA 15 checkpoint documents, sessions 1-9).

## Status of FIFA 15 itself (2026-09-02): runs to the attract-mode match
Three things are needed. (1) `crossover-26.3-topdown-alloc-limit.patch` in the unix ntdll with
`CX_TOPDOWN_LIMIT=0x1ffffffff` in the bottle environment: gets the game to boot. (2) An
`ntdll.so` that still carries the `@loader_path/../../../lib64` rpath (setup.sh repairs it;
without it the game silently runs on wined3d and hangs). (3) Windowed mode via
`~/Documents/FIFA 15/fifasetup.ini` (`FULLSCREEN = 0`): full screen asks for a display-mode
switch the Mac driver only applies while the app is active. `AURORA_GAME=fifa15 ./setup.sh
--bottle` does (2) and (3).

## The language-screen freeze was the crack, not Wine
With the above the game reached the language screen and froze with the flag mid-wave. Relay
logs showed the front-end thread in the Origin SDK's connect loop (socket, 127.0.0.1:3216,
sleep 1 s, close, repeat) with `connect` never reaching ws2_32. Dumping the decrypted image
from the running game (ReadProcessMemory from a helper inside the bottle; the exe is encrypted
on disk) and disassembling it showed why: the crack's Origin emulator `ItsAMe_Origin.dll`
diverts the protector's import resolution of `OpenProcess`, `GetModuleBaseNameW`,
`RegOpenKeyExW`, `RegQueryValueExW` and `getenv` to fakes that report Origin installed
(`ClientPath` = `Z:\Program Files (x86)\Origin\Origin.exe`) and running, and its fake
`OpenProcess` writes a `mov rax,-1; ret` stub into the protector's obfuscated import slot for
`connect`. The SDK (`OriginSDKImpl::Initialize`, OriginSDK 9.5.0.4) then tries 30 times a
second apart and returns 0xA0020000. The game's `FifaEbisuManager::Initialize` accepts only
0xA0020007/0xA0020008 ("not installed / not running") as "go offline"; anything else makes it
shut the SDK down and call `OriginStartup` again from its job queue, 30 s per call, forever.
Windows behaves the same at the socket level, so this is not a Wine difference.

Fix, without Aurora: make the emulator's two registry hooks pass through to the real registry
(3 bytes: file offset 0x9ed `75`->`EB`, 0xa6a-0xa6b `74 34`->`90 90`). No Origin key, the SDK
returns 0xA0020008 at once, the game goes offline; the 60-second black splash (two such calls
on the main thread) disappears as well. `fifa15/fifa15-offline.sh` applies and reverts it with
hash checks. With Aurora15Connector the fix is not wanted: the connector installs its own
emulator that lets `connect` through to the Origin stand-in it hosts on 127.0.0.1:3216.

## crossover-26.3-topdown-alloc-limit.patch  (THE fix; opt-in, `CX_TOPDOWN_LIMIT=<addr>`)
`NtAllocateVirtualMemory`: cap `MEM_TOP_DOWN` allocations without a requested base at the given
address. Why: Windows hands top-down allocations addresses just under the user-space limit
(`0x7FFFFFxx0000`), whose low dword has bits 30 and 31 set. Wine on macOS ends the top-down
region near `0x7ff001dxxxxx` (bit 30 clear). This game's protector generates code at runtime
that computes its next block address from bit 30 of its own address; with the bit clear it
enters an unconditional stack-popping loop, a `popfq` pops VM data as flags, TF gets set, and
the process dies with `EXCEPTION_SINGLE_STEP` (0x80000004) at `0x7ff001d31b06`. With
`0x1ffffffff` the blocks land at `0x1FFxx0000`, which looks like Windows 7 to that predicate.
Isolation (session 7): this patch alone, on otherwise stock PE ntdll and kernelbase, is GREEN;
removing only the env var reproduces the original crash. Inert when the variable is unset.
Applies cleanly on pristine sources and on top of the four FIFA 17 patches.

## crossover-26.3-uef-debugport.patch  (Windows-parity; not load-bearing for FIFA 15)
`kernelbase!UnhandledExceptionFilter` gated the process's top-level filter on
`PEB->BeingDebugged`. Windows gates it on the process debug port
(`NtQueryInformationProcess(ProcessDebugPort)`); writing the PEB byte does not fool Windows.
FIFA 15's protection sets that byte itself, so under Wine its `SetUnhandledExceptionFilter`
handlers were never called. Falls back to the PEB flag if the query fails.

## crossover-26.3-unwind-fault-guard.patch  (robustness; not load-bearing for FIFA 15)
`call_seh_handlers` could fault inside `RtlVirtualUnwind2` when a frame's unwind data sends the
unwinder past `StackBase`; that AV was dispatched, its own search faulted the same way, 268
nested dispatches until `EXCEPTION_STACK_OVERFLOW`. Now the unwind step runs under
`__TRY/__EXCEPT_ALL` and the search stops with `EXCEPTION_STACK_INVALID`.

## crossover-26.3-win-segment-selectors.patch  (opt-in, `CX_WIN_SEGS=1`; keep OFF)
macOS runs 64-bit user code with `cs=0x2b/ss=0x23`, Windows has `cs=0x33/ss=0x2b`; guest-visible
contexts leaked the macOS values. Real divergence, but with it ON the FIFA 15 runner exited
early (status 5) in session 5. Off by default; leave it off.

## crossover-26.3-heap-destroy-invalid-handle.patch  (correct in itself; DO NOT use for FIFA 15)
`RtlDestroyHeap` dereferenced a handle that `unsafe_heap_from_handle` had already rejected, and
on stack garbage with `HEAP_VALIDATE_PARAMS` set it `DbgPrint`ed and hit `DbgBreakPoint()`.
The patch derives the flag from `PEB->NtGlobalFlag` as Windows does. But this game's protector
deliberately provokes exactly that `int3` (fake heap handle, `BeingDebugged=1` set by itself)
and does its decryption inside the VEH that swallows it; with the patch the VEH never runs and
the game dies elsewhere (`execute access to E7545194BCD81D34`). Windows evidently also breaks
here. Reverted in the FIFA 15 tree.

## fable-f15-singlestep-tracer.patch  (diagnostic only, not installed)
Env-gated single-step instruction tracer in the unix ntdll (`CX_F15_TRACE=<file>` plus
`_NTH/_HANDLE/_STACKBASE/_EXE/_MAX`). Arms TF on the Nth `NtWaitForSingleObject` of a chosen
thread and logs 160-byte records per instruction. Analyzer `f15an.py` (capstone). This is how
facts 37-41 were established. Removed from the installed build in session 7.
