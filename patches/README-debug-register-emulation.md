# Debug registers under Rosetta 2 (`CX_DR_TRAP=3`), and `PF_PAE_ENABLED`

Two patches against `crossover-sources-26.3.0`, applied after the eight before
them and before FIFA 16's loading-loop fix, and a third, applied after that
fix, that stops Wine's system calls faulting on a watched `KUSER_SHARED_DATA`:

| Patch | Files | Gate |
|---|---|---|
| `crossover-26.3-debug-register-emulation.patch` | `dlls/ntdll/unix/signal_x86_64.c`, `virtual.c`, `thread.c` | `CX_DR_TRAP=3` in the bottle; modes 0-2 unchanged |
| `crossover-26.3-pf-pae-enabled.patch` | `dlls/ntdll/unix/system.c` | `CX_DR_TRAP=3` in the bottle (x86_64 only) |
| `crossover-26.3-drtrap-syscall-stub.patch` | `dlls/ntdll/unix/signal_x86_64.c`, `dlls/win32u/message.c` | `CX_DR_TRAP=3` in the bottle; the `win32u` half runs in every bottle and reads the same value |

All three are in `build.sh`'s `PATCHES` list (ninth, tenth and twelfth, with
`crossover-26.3-fifa16-dst-complement.patch` eleventh) and in the shared
`fixes/x86_64-unix/ntdll.so`; the stub patch's `win32u` half is in
`fixes/x86_64-unix/win32u.so`. Only the FIFA 16 bottle profile
(`AURORA_GAME=fifa16`) sets `CX_DR_TRAP=3`. The shipped FIFA 17 bottle keeps
`CX_DR_TRAP=2` and FIFA 15's sets no `CX_DR_TRAP`, so neither runs any of this
but that `win32u` half, which returns the same tick count by another route;
the PAE fix, gated the same way, has not been run with FIFA 17. They were first
built and tested in a separate CrossOver app (`CrossOver-FIFA16.app`, bottle
`FIFA16-dev`).

```
patch -p1 --forward < ../patches/crossover-26.3-debug-register-emulation.patch
patch -p1 --forward < ../patches/crossover-26.3-pf-pae-enabled.patch
patch -p1 --forward < ../patches/crossover-26.3-fifa16-dst-complement.patch
patch -p1 --forward < ../patches/crossover-26.3-drtrap-syscall-stub.patch
```

## The problem

x86-64 debug registers (Dr0-3 addresses, Dr7 enables and R/W/LEN, Dr6
status) are part of the user-mode thread context on Windows. A thread can arm
them on itself or on another thread through `SetThreadContext`, and the CPU
raises `EXCEPTION_SINGLE_STEP` (#DB) on a hit. Debuggers use them, and so do
runtime protection systems.

Rosetta 2 does not support them (CrossOver's CW HACK 22131). Stock Wine drops
them without a word: a self-armed breakpoint never fires and
`GetThreadContext` reads zeros back. The shipped `CX_DR_TRAP=2` covers one
pattern, an execute breakpoint armed by another thread. On the conformance
suite, control and mode 2 score the same (drbp 2/8).

## How mode 3 emulates them

Breakpoints are emulated with page protection. A process-wide table holds
every armed slot (1024 entries, 256 threads).

- **Execute breakpoint.** The page loses execute. The fault on the
  breakpointed instruction becomes a #DB *before* it runs, the way hardware
  does it. Resuming with `EFLAGS.RF` skips it once.
- **Write watchpoint (rw=01).** The page loses write. Any faulting access is
  decoded for its exact address and width. It is then stepped over once under
  TF, and a #DB is delivered *after* the instruction if it touched a watched
  byte.
- **Read+write watchpoint (rw=11).** The page loses all access. For
  `KUSER_SHARED_DATA` (`0x7ffe0000`), which every thread reads constantly, a
  decoded read is completed inside the fault handler out of a second,
  read-only mapping of the same page. The #DB is raised straight away, so no
  protection window opens that another thread's read could slip through.
- **Dr6** is per event: `0xffff0ff0` plus the B bits of this hit, plus BS
  when a TF step is pending.
- **Dr7**: its global-enable bits are stripped on every context write, as
  Windows does.

## Bugs fixed, in the order they were found

Some were caught by `tests/drbp`. The rest (3, 12, 13, 14) only showed up
under a real protected workload, and the tests were extended afterwards
where they could be.

1. **Self-armed debug registers went to the server, which Rosetta refuses.**
   In mode 3 they stay thread-local (`ctxlog_set_context_thread`), and the
   mode 1/2 `drbp_arm` path is skipped.
2. **A hit on a thread armed by another thread gave the handler zeros.** The
   fault handlers now take the arming registers from the drcache
   (`segv_handler`/`trap_handler` → `drcache_get`).
3. **Exception contexts carried stale debug registers.** `save_context` took
   Dr0-7 from `amd64_thread_data()`, which a cross-thread arm never updates.
   So any exception on such a thread gave its handler zeros, and `NtContinue`
   wrote them back, disarming the thread. `save_context` now reads the
   drcache in mode 3.
4. **Genuine TF steps got a stale Dr6.** Every SINGLE_STEP goes through
   `NtGetContextThread`, and the drcache replaced this event's Dr6 with the
   previous hit's. `trap_handler` now writes its own Dr6 into the cache
   (`drcache_set_dr6`).
5. **Syscall stubs read KUSER on every call** (`testb $1, 0x7ffe0308`). The
   read was undecodable, so it opened a step-over window, and fires were lost
   whenever any thread made a syscall (drrf phase 6: 28/64). The decoder now
   completes `test`/`cmp` forms with flags computed in C. The syscall
   dispatcher reads its own copies of the three KUSER fields it needs
   (`usd_xsave_enabled`, `usd_xstate_features`, `usd_xstate_flags`), and the
   instrumentation-callback pointer uses the fixed `0x7ffe1000` rather than
   the alias. Bug 17's stub redirect reopened the same window in one race;
   see there.
6. **ALU reads of watched bytes** (`add/or/adc/sbb/and/sub/xor r, m`) fell
   back to the racy step-over. They are now completed with exact flags
   (`xbp_alu`). `tests/drbp/tools/alu_test.c` fuzzes it against the native
   instructions: 4.8 M cases, 0 mismatches.
7. **The fallback assumed every access was 8 bytes wide.** A VEH writing a
   global next to a watched one counted as a hit and recursed until the
   stack ran out (drbp case 8 hung; under Rosetta it aborts with
   "EmulateForward on a synchronous exception"). Stores and read-modify-writes
   now decode to their exact address and width: mov, ALU, inc/dec, xchg and
   shifts, with 0x66/lock. An undecoded access counts as its faulting byte
   only.
8. **The step-over left its own TF set** when the guest had none (the other
   half of the case 8 hang). `xbp_handle_step` now clears it.
9. **Decoder errors.** `A0/A1` moffs is always an 8-byte address in 64-bit
   mode. `movsx` without REX.W zeroes the upper 32 bits. `fs:`/`gs:` prefixes
   are rejected, because the segment base was ignored. The effective address
   is computed from the instruction instead of trusted from `si_addr`.
10. **Disarm race → spurious access violation.** A thread faults on the
    stripped page, then the last watcher disarms and restores it, and the
    handler finds no watched page and reports a real AV.
    `xbp_fault_is_stale` retries when the restored protection allows the
    access.
11. **Accesses the page itself denies** stay the guest's own access
    violation, never a #DB (`xbp_prot_allows`).
12. **Unix-side accesses raised a #DB inside a syscall.** Wine's own read of
    a watched address inside `NtSetContextThread` turned into a failed
    `SetThreadContext` for the guest. Accesses inside a syscall
    (`is_inside_syscall`) are completed or stepped over, but never hit.
13. **The breakpoint table was 64 entries process-wide.** About 36 threads
    with 3-4 watchpoints each overflowed it, and later threads were left
    unarmed with no message. It is now `XBP_MAX 1024` and `DRCACHE_MAX 256`,
    with an `ERR` when full.
14. **The page games were visible.** Real debug registers never change page
    protection. `NtQueryVirtualMemory` now reports a watched page's own
    protection (`drbp_query_hook`). A guest `NtProtectVirtualMemory` on a
    watched page replaces that protection and is re-stripped underneath
    (`drbp_protect_hook`). An `xbp_internal` guard stops the hooks
    re-entering the table lock; the first version deadlocked.
15. **Thread exit.** Breakpoints, page references, step state and the cache
    entry are dropped in `drbp_thread_exit` (called from
    `pthread_exit_wrapper`), so a reused TID inherits nothing and pages get
    their access back.

And the separate patches:

16. **`PF_PAE_ENABLED` was FALSE.** Wine reads it from CPUID leaf 1 EDX bit 6,
    which Rosetta leaves clear. Long mode runs on PAE paging, and no 64-bit
    Windows has ever reported FALSE. `init_cpu_info` now sets it on x86_64
    when `CX_DR_TRAP` is 3, the only setting the one program known to need it
    (FIFA 16's protector, which hashes the feature array) runs under. Every
    other bottle reads the bit from CPUID as before. Where it applies, it also
    changes the `ProcessorFeatures` array in `KUSER_SHARED_DATA`.
17. **Every system call faulted while `KUSER_SHARED_DATA` was watched.**
    FIFA 16's protector keeps rw=11 watchpoints on `0x7ffe0270` armed for
    the whole session, so mode 3 keeps that page inaccessible, and every
    syscall stub in Wine's ntdll (259) and win32u (1,542, the NtUser and
    NtGdi calls) reads `0x7ffe0308` (`testb $1, 0x7ffe0308`, the Windows
    form). Bug 5 made those reads correct; they still each cost a fault.
    Under Rosetta a plain x86_64 SIGSEGV round trip costs about 16 us
    whatever the handler does (a trivial native test program measures the
    same), and Wine's handler adds about 1 us. In game that was ~70,000
    faults a second, 99% of them at offset `0x308`, from
    NtQueryPerformanceCounter (~20k/s), NtDelayExecution (~11.5k/s),
    NtQueryVirtualMemory (~11k/s), NtAlertThreadByThreadId and
    NtWaitForAlertByThreadId (~6k/s each) and NtProtectVirtualMemory
    (~3.7k/s): the stutter. `crossover-26.3-drtrap-syscall-stub.patch`
    retargets a stub on its first fault: the `testb` displacement is pointed
    at a copy of `SystemCall` at `0x7ffe1008`, on the page Wine already
    keeps the dispatcher pointer on, which no watchpoint covers. One byte
    changes, and the instruction's length and result do not. Only stubs
    inside Wine's own builtin images (a `MEM_IMAGE` mapping whose DOS header
    carries "Wine builtin DLL": ntdll and win32u) are touched, and only in
    mode 3.

    The first version touched ntdll's stubs alone, and the game still
    stuttered in play: win32u's stubs faulted, and so did win32u's unix
    side, which read the tick count straight off `0x7ffe0000` (three loads)
    for the hung-queue check on every PeekMessage and GetAsyncKeyState
    (PeekMessageW cost ~123 us a call armed, `kuser_perf`). That check now
    calls `NtGetTickCount`, which reads ntdll's own unprotected alias of the
    page, and compares in 32-bit arithmetic, which wraps correctly. This
    half is not gated: every bottle runs it and gets the same value, one
    function call instead of three loads.

    The redirect had a race. A thread that has already run a stub's old
    bytes can take its fault after another thread has redirected that stub;
    decoded as it then reads, the instruction missed the page and was
    stepped over, which makes the page readable for one instruction and lets
    other threads' watched reads through unseen. drrf phase 6 lost up to a
    third of its fires in 4 runs of 6 on the first version. Such a fault is
    now completed as the `SystemCall` read it was: 10 runs of 10 clean.

    In game, at the start screen: 1,140 faults a second with the ntdll-only
    version, 490 now. What is left is kernelbase's `GetTickCount` and
    `GetTickCount64` reading the page themselves, as on Windows (about 120
    calls a second each, 4 faults per game loop), steady rather than in
    bursts. `tests/drbp/kuser_perf.c` measures it.

## Results (Apple M4 Pro, Rosetta, 2026-09-28, the patched build as committed)

| Test | Control (no `CX_DR_TRAP`) | Mode 2 (shipped) | Mode 3 |
|---|---|---|---|
| `drbp_test` | 2/8 | 2/8 | **7/8** in 3 of 3 runs |
| `drrf_test` | 3/7 | — | **7/7** in 5 of 5 runs, 0 unexpected single-steps |
| `alu_test` | — | — | 4.8 M cases, 0 mismatches, 3 runs |

drbp case 3 fails in every column: a TF set through `SetThreadContext` on
the current thread is delivered late, and mode 3 does not affect it. TF set
with `pushfq/orq/popfq` is delivered on time (drrf phase 7). See
`tests/drbp/README.md`.

## Known limits

- The decoder handles no SSE/AVX loads, no `rep`/string ops and no 16-bit
  completed loads. Those accesses fall back to the step-over. It is still
  correct, but a read racing with another thread can pass a watchpoint.
- Every read of a watched page by any thread faults, and under Rosetta each
  fault costs about 16 us, so the page is slow while armed. Wine's syscall
  stubs in ntdll and win32u, and win32u's message queue, no longer read it
  (bug 17). Direct reads of the time fields still fault: `GetTickCount` and
  code that reads `0x7ffe0320` itself take ~17-21 us a call while armed,
  against ~1 ns unarmed (`tests/drbp/kuser_perf.c`). In FIFA 16 that is all
  that is left: `GetTickCount` and `GetTickCount64`, about 490 faults a
  second at the start screen.
- Mode 3 turns the drcache on, which logs a `CTXDR` line to stderr for every
  context get/set that carries debug registers. The shipped mode 2 does the
  same (baseline code in the rosetta patch).

## 32-bit programs (wow64), 2026-11-10

Everything above is the native x86-64 context path (`NtSetContextThread`,
`signal_x86_64.c`). A 32-bit program does not use it: its
`SetThreadContext`/`GetThreadContext` become
`NtSetInformationThread(ThreadWow64Context)` and land in
`set_thread_wow64_context`/`get_thread_wow64_context`, which until this patch
always went to the server. Under Rosetta the server answers
`STATUS_UNSUCCESSFUL` for debug registers, Wine warns "Setting debug
registers is not supported under Rosetta, faking success" and the registers
are dropped. Mode 3 did nothing for a 32-bit guest at all: the repository's
own `drbp_test`, rebuilt with `i686-w64-mingw32-gcc`, scored 2/8 with
`CX_DR_TRAP=3` resolved for it.

`crossover-26.3-wow64-debug-registers.patch` closes that:

- `set_thread_wow64_context` keeps a self-arm thread-local (as the native
  path does) and does not call the server, then arms the emulation through
  `xbp_apply_wow64`, which borrows `xbp_sync` with an amd64-shaped copy of the
  i386 context. A cross-thread arm is emulated and stored in the drcache.
- `get_thread_wow64_context` answers a `CONTEXT_DEBUG_REGISTERS` request from
  the thread-local copy and the drcache instead of the server.
- `xbp_decode_load` decodes 32-bit guest code with the 32-bit rules: ModRM
  `mod=00 rm=101` is absolute disp32, not RIP-relative, and a moffs operand is
  four bytes. Wine's own 64-bit code in the same process keeps the long-mode
  rules; the two are told apart by the faulting `SegCs`.
- After measuring the same sequence on Windows (`tests/drbp/wow32_probe.c`,
  the probe's output beside it), two differences were corrected in mode 3
  only: `Dr7` reads back with its legal bits alone (`& 0xffff0155`), and `Dr6`
  is cleared once a hit has been delivered (or `0` when the slots are
  disarmed). The third correction made here -- `EFLAGS.RF` set on every fault
  context -- was wrong for a `#DB`; see the 2026-11-10 entry below.

Result on this Mac: `drbp_test` 32-bit goes from 2/8 to case 1 (self-armed
execute breakpoint) passing and the context round trip reading back the
registers that were written. A plain 32-bit probe (`Dr0=0x11111111`,
`Dr3=0x44444444`, `Dr7=0x404`) reads all six back unchanged.

**Data watchpoints for a 32-bit guest, 2026-11-10 (`tests/trapstorm`).**
These used to be dropped from the emulation's table with one warning per
process. They now take the same path as a 64-bit guest's: the page loses
write, the faulting access is decoded (`xbp_decode_load` knows the 32-bit
addressing rules), stepped over under TF, and a trap-type `#DB` is delivered
after it. Two things stood in the way, both fixed in this patch:

- `EFLAGS.RF` swallowed the hit. A 32-bit handler resumes with the RF it was
  delivered with, and `xbp_sync` turns RF into `skip_addr`, which the data path
  honoured ("RF: run it once, no trap"). RF suppresses an *instruction*
  breakpoint for one instruction and nothing else; on hardware a data access
  still hits. `xbp_handle_fault` ignores `skip_addr` for a wow64 guest's data
  accesses. A 64-bit guest keeps the old rule (see "Not fixed" below).
- The hit's Dr6 was cleared before the guest read it. The `#DB` reaches
  `xbp_apply_wow64` as a context write, and the Windows rule "a continued
  context drops the status" was applied to it unless `Eip` sat on the
  breakpoint, which is true of an execute breakpoint and never of a data trap
  (it reports the next instruction). `setup_raise_exception` now remembers the
  Dr6 it is delivering (`cx_wow_deliver_dr6`) and `xbp_apply_wow64` lets
  exactly that value through once.

Not fixed: a 64-bit guest still lets RF swallow a data watchpoint at the
instruction a handler resumed to with RF set. It is the validated FIFA 16
behaviour and nothing 64-bit has shown it to be wrong.

**Exception context, closed 2026-11-10 (`tests/trapstorm`, 31/37 -> 37/37).**
Two things a 32-bit handler saw differently from Windows, both only for a
32-bit guest under mode 3:

- `EFLAGS.RF`: **corrected 2026-11-10 -- see the next entry.** This made the
  patch set RF for an execute breakpoint's `#DB` too. The Windows output kept
  beside the probe shows `eflags=0x246` on the `#DB` lines, i.e. RF clear;
  only the `#UD` and the access violation carry `0x10000`.
- `ContextFlags` is `0x1007f`, not `0x1003f`: Windows adds `CONTEXT_XSTATE`
  with an XSTATE area behind the context. Rosetta's signal frame has no area to
  point at, so `wow64`'s dispatcher saw no `CONTEXT_AMD64_XSTATE` and left the
  flag off. `setup_raise_exception` now builds an empty area (Mask 0, state in
  its initial configuration) in the space it already reserves for one, when the
  faulting code is 32-bit and the process has extended features (the bottle
  reports `GetEnabledXStateFeatures() == 7`). No `wow64.dll` change.

## Image sections that are writable but have no raw data

`crossover-26.3-image-demand-zero-protect.patch`, one hunk in
`dlls/ntdll/unix/virtual.c`, unrelated to debug registers except that a packed
image is where it shows. A section with `IMAGE_SCN_MEM_WRITE` and
`SizeOfRawData == 0` is demand-zero: there is no file content behind it, so
Windows backs it with private pages and `VirtualQuery` reports a plain
writable protection. Wine marked it `VPROT_WRITECOPY`, so it reported
`PAGE_EXECUTE_WRITECOPY` where Windows reports `PAGE_EXECUTE_READWRITE`. A
packer that checks its own unpack target section sees the difference.

**Round 5, 2026-11-10 night 5: a single-stepped `call` pushes 8 bytes under Rosetta.**
Three 32-bit conformance failures had one cause. `tests/drbp/wow32_arm.c` phase B
(arm an execute breakpoint on a page the process is also running code from: no
exception, zeroed registers, death reading address 0), `drbp_test32` case 4
(`Dr3=10010 Dr7=0`: ContextFlags printed where Dr3 should be) and case 6 (the arming
thread dies at `EIP=0x2cc`, `sizeof(CONTEXT)`) all arm a page that holds running
code. The emulation runs every instruction of such a page one at a time (fetch
fault, execute restored, TF step, execute taken away again), and Rosetta executes
a TF-stepped 32-bit `call rel32` (E8) as a 64-bit call: Esp drops by 8, not 4, the
return address is stored with a zero dword above it, and the callee finds that
zero where the caller's last argument was (`printf` got a NULL format) and its
`ret` leaves the caller 4 bytes off. Measured without any emulation involved
(`tests/drbp/wow32_tfstep.c`, an exe with no `DrTrap` entry, the guest sets TF
itself): E8 is -8; `call reg`, `call [mem]`, `ret`, `ret n`, `push`, `pop`, `enter`,
`leave`, `pushad`, string instructions, `cpuid`, jumps are all correct. The
registers were never zeroed: the earlier "eax=ebx=esi=edi=0" was `__mingw_pformat`'s
own `xor edi,edi; xor esi,esi` and a NULL format pointer. Case 6's "dr0=0 dr7=0"
`CTXDR store` line and the `0x2cc` were the same skew reaching the arguments of the
next `SetThreadContext` and a later `ret`.

`xbp_note_call` remembers, in both step-over paths (execute and data), that the
instruction about to be stepped is a 32-bit E8 and the Esp before it;
`xbp_fix_call`, at the step trap and before the page is stripped again, moves the
return address to the right dword when Esp is exactly 8 lower. Only a wow64 guest's
32-bit code is touched. Not covered: a guest that sets TF itself and steps over an
E8 still sees Esp -8 (case 3's TF delivery fails on Windows too, and the game was
not seen to use TF). Results: `wow32_arm` A/B/C OK, `drbp_test32` 7/8 (case 3 fails
as on Windows), `drbp_test` 64-bit 7/8, `trapstorm` 66/66, `wow32_probe` output
unchanged.

**Round 4, 2026-11-10 night: Windows 11 measured, round 3's run-once removed.**
`trapstorm` and `wow32_probe` were run on a real Windows 11 build 26200 machine
(`tests/windows/baseline-windows/`). Two things changed:

- Round 3's run-once (`cx_wow_db_skip`, below) is **deleted**. It assumed Windows
  runs the tapped instruction once whatever the handler returns; Windows does not.
  A handler that resumes at the breakpoint with RF clear is handed the same `#DB`
  again (the test saw nine deliveries until its own cap), and one that sets RF
  runs the instruction once, which `xbp_sync`'s RF handling (`skip_addr`) already
  did. `trapstorm` now has phase 3b for exactly this and passes 66/66.
- The segment selectors in the context a 32-bit handler is handed are Windows'
  (`cs=0x23 ds/es/gs=0x2b fs=0x53`) instead of Rosetta's (`0x107 0x23 0x10f`). They
  are given out for the one 32-bit context read the exception dispatch makes
  (`cx_wow_seg_lie`, set in `setup_raise_exception`) and translated back in
  `set_thread_wow64_context`; the real selectors stay in the CPU area. **`ss` is
  excluded by default** (`CX_SEGLIE` bit 1): a Windows-valued `ss` makes a nested
  exception inside a handler lose its stack and kills the process, cause not found.
  Widening the lie to every `GetThreadContext` broke wow64's own start-up.

Neither change moved FIFA 14 off its splash (the access-violation storm at
`0x03413A96` is identical); they are fidelity fixes against measured Windows
behaviour. Not regression-tested: FIFA 16 (64-bit, so untouched by both).

**`#DB` delivery vs Windows, 2026-11-10 (round 3, `wow32_probe` + `trapstorm`,
64/64).** The Windows probe output that the previous round had read the other
way turned up again (`/Volumes/Untitled/wow32_probe.txt`, Windows 6.2/9200). It
says two things the patch did not do:

- A `#DB` from an instruction breakpoint is handed to a 32-bit handler with
  **RF clear** (`eflags=0x246`), while `#UD` and access violations carry
  `0x10000`. The resume, not the delivery, is what runs the instruction once.
  `setup_raise_exception` therefore no longer marks the delivered context, and
  `xbp_apply_wow64` no longer sees RF on that path.
- A handler that continues at a *different* `Eip` still traps at the new
  address on Windows (`hit-l1` in the probe). The old build tied the run-once
  to the resume address (`xbp_sync`'s `skip_addr`), so it silently skipped that
  trap: 6 exceptions against Windows' 7.

Both are one change. The address a `#DB` was delivered *for* is pushed on a
small per-thread stack (`cx_wow_db_skip`, four deep, one per dispatch in
flight) and consumed by the next instruction fetch on an armed page: same
address, run it once; any other address, clear the entry and trap normally.
It has to be a separate stack rather than `skip_addr` because an interpreter
in the handler (a nested access violation, say) writes contexts of its own and
would clobber a single slot -- that is exactly how `trapstorm` phase 2 caught
the first version of this change.

`wow32_probe` now prints the same lines as Windows, the same seven exceptions,
same `Dr6`/`Dr7`/`ContextFlags`, same RF on each; only the low EFLAGS bits that
the caller itself produces differ (`0x206` vs `0x246`, AF vs ZF).
