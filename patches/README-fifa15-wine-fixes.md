# Wine fixes found while chasing the FIFA 15 startup crash

Three patches against `crossover-sources-26.3.0`. They are **not** in `build.sh`'s
`PATCHES` list — FIFA 17 (`/Applications/CrossOver-FIFA17.app`) does not need them, and
its runtime is untouched. They are installed in the FIFA 15 experiment clone
(`/Applications/CrossOver-FIFA.app`), built from
`scratchpad/crossover-thread-times/src/sources/wine`.

## crossover-26.3-uef-debugport.patch  (real Windows-parity bug)
`kernelbase!UnhandledExceptionFilter` gated the process's own top-level filter on
`PEB->BeingDebugged`. Windows gates it on the process **debug port**
(`NtQueryInformationProcess(ProcessDebugPort)`) — writing the PEB byte, a standard
anti-debug move, does not fool Windows. FIFA 15's protection sets that byte itself, so
under Wine its `SetUnhandledExceptionFilter` handlers (0x142EB56DA, 0x142EABBF1) were
never called and the exception fell out of `NtRaiseException`: that was the
`Unhandled exception code 80000004` RED. Falls back to the PEB flag if the query fails.
Affects any app that sets the flag itself, not just this one.

## crossover-26.3-unwind-fault-guard.patch  (robustness, Windows-parity)
`call_seh_handlers` could fault inside `RtlVirtualUnwind2` when a frame's unwind data
sends the unwinder past `StackBase`. That AV was then dispatched, its own handler search
faulted the same way, and so on: 268 nested dispatches (~0xF00 bytes each) until
`EXCEPTION_STACK_OVERFLOW`, and a 2M-line log. Windows reports a bad stack instead of
faulting. Now the unwind step runs under `__TRY/__EXCEPT_ALL` and the search stops with
`EXCEPTION_STACK_INVALID`.

## crossover-26.3-win-segment-selectors.patch  (opt-in, `CX_WIN_SEGS=1`)
macOS runs 64-bit user code with `cs=0x2b/ss=0x23`; Windows always has `cs=0x33/ss=0x2b`.
Guest-visible contexts (`setup_raise_exception`, `NtGetContextThread`) leaked the macOS
values, which any guest validating `CONTEXT.SegCs` can see. Off by default; it made no
difference to FIFA 15, but the divergence is real.

## Status of FIFA 15 itself
Still does not run. With these fixes the old crash signature is gone and the game's
filter is reached, but nothing in the process wants the `EXCEPTION_SINGLE_STEP` it raises
at its VM gadget (VEH declines it, SEH declines, top filter declines) — the `popfq` there
consumes VM data (`0x39f`, bit 3 set: not a flags image), i.e. an anti-tamper path inside
the crack's Denuvo-emulator VM. See `dev/FIFA15-CHECKPOINT.md`.
