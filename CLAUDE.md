# CLAUDE.md

Living context for this repository. **Update "Current state" and "Resume here" at the end of every session.**

## What this is

macOS (Apple Silicon) sibling of fw-helper / fw-helper-windows. Design: `docs/superpowers/specs/2026-10-05-fw-helper-mac-design.md`.
Plans: `docs/superpowers/plans/`. Measured hardware facts: `docs/hardware-baseline.md`.
**Do not re-derive hardware facts — they are measured and recorded.**

## Commands

    swift build
    swift test                      # unit tests, no hardware
    .build/debug/fwprobe ...        # read commands work unprivileged
    sudo .build/debug/fwprobe ...   # write experiments (charge-test, fan-test, fan-release, smc write)
    .build/debug/fwbench ...        # benchmarking (unprivileged): record, run, hud, stack, ls, summary, compare; alone: usage

## Hard rules

1. **Fan control is a lease.** Every path that takes the fans must have a matching hand-back to system control.
2. **Recovery reads hardware, not flags.** Release writes "auto" even if we believe we never took the fans.
3. **Read-back is not efficacy.** Verify the effect (battery current 0, RPM change), and record the evidence.
4. **SMC keys and byte layouts come from measurement on this machine** (`docs/hardware-baseline.md`), never from forum posts alone.
5. **No TDP, power-limit or undervolt features.** Apple Silicon has no such interface.
6. The app never runs as root. Only the helper (`fwhelperd`, from M2) writes the SMC. `fwprobe` is a dev tool.
7. Record decisions as ADRs in `docs/adr/`; hardware facts in `docs/hardware-baseline.md` tagged `[M]` or `[?]`.

## Traps

- SMC integer types (`ui16`, `ui32`) are big-endian, but `flt ` is little-endian on Apple Silicon. Some keys
  (`CHTE`) are written by other tools as `01 00 00 00`, which does not fit a big-endian reading. Write raw bytes,
  and record exactly which bytes worked.
- IORegistry stores signed battery values as unsigned 64-bit: −1550 mA reads as 18446744073709550066.
- zsh's `log` is a builtin: always `/usr/bin/log`.
- Each Metal HUD line appears twice in the unified log (empty subsystem, then `com.apple.metal.hud`); FrameCounter dedupes.
- AlDente writes the same charge keys. Quit it (and confirm its helper is not rewriting them) before any charge experiment.

## Current state

M0 in progress — see `docs/superpowers/plans/2026-10-07-m0-hardware-baseline.md` (E2–E5, E7 pending).
M1B benchmarking (`fwbench`, branch `m1b-benchmarking`) built: Tasks 1–10 done and reviewed, final-review fixes applied, 154 tests. Docs:
`docs/run-bundle-format.md`, README. Not yet verified with a real Wine game (Task 11 steps 1–3).

## Resume here

The user will hands-on test benchmarking only once there is a UI and a global hotkey to start/stop recording
(decided 2026-11-24). Next: design and build that app layer on top of FWCore's recorder (menu-bar app, hotkey,
REC indicator, runs/compare browsing) — brainstorm first. Then B1 in `docs/m0-test-plan.md` with real games, recording
results in `docs/hardware-baseline.md` E8, then continue M0 at its first unchecked task.
