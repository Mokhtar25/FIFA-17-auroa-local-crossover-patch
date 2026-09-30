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
