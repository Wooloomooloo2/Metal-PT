# CLAUDE.md

Living context for this repository. **Update "Current state" and "Resume here" at the end of every session.**

## What this is

Metal-PT (Metal Performance Telemetry), macOS Apple Silicon; formerly fw-helper-mac, a sibling of fw-helper / fw-helper-windows.
Two apps from one repo: Metal-PT (telemetry, no root) and Metal-PT Helper (battery/fans, root helper, later; the old
"helper" rules below apply to it). Design: `docs/superpowers/specs/2026-11-24-metal-pt-design.md` (earlier: `2026-10-05-fw-helper-mac-design.md`).
Plans: `docs/superpowers/plans/`. Measured hardware facts: `docs/hardware-baseline.md`.
**Do not re-derive hardware facts — they are measured and recorded.**

## Commands

    swift build
    swift test                      # unit tests, no hardware
    .build/debug/mptprobe ...        # read commands work unprivileged
    sudo .build/debug/mptprobe ...   # write experiments (charge-test, fan-test, fan-release, smc write)
    .build/debug/mpt ...        # benchmarking (unprivileged): record, run, hud, stack, ls, summary, compare; alone: usage

## Hard rules

1. **Fan control is a lease.** Every path that takes the fans must have a matching hand-back to system control.
2. **Recovery reads hardware, not flags.** Release writes "auto" even if we believe we never took the fans.
3. **Read-back is not efficacy.** Verify the effect (battery current 0, RPM change), and record the evidence.
4. **SMC keys and byte layouts come from measurement on this machine** (`docs/hardware-baseline.md`), never from forum posts alone.
5. **No TDP, power-limit or undervolt features.** Apple Silicon has no such interface.
6. The app never runs as root. Only the Helper (root daemon, from M2) writes the SMC. `mptprobe` is a dev tool.
7. Record decisions as ADRs in `docs/adr/`; hardware facts in `docs/hardware-baseline.md` tagged `[M]` or `[?]`.

## Traps

- SMC integers are **little-endian** on this machine (E1); `flt ` is little-endian; `#KEY` is big-endian. Some keys
  (`CHTE`) are written by other tools as `01 00 00 00`. Write raw bytes, and record exactly which bytes worked.
- IORegistry stores signed battery values as unsigned 64-bit: −1550 mA reads as 18446744073709550066.
- zsh's `log` is a builtin: always `/usr/bin/log`.
- Each Metal HUD line appears twice in the unified log (empty subsystem, then `com.apple.metal.hud`); FrameCounter dedupes.
- AlDente writes the same charge keys. Quit it (and confirm its helper is not rewriting them) before any charge experiment.

## Current state

Metal-PT plan in progress: `docs/superpowers/plans/2026-11-24-metal-pt-app.md` (Task 1, the rename, done).
M0 hardware baseline (`docs/superpowers/plans/2026-10-07-m0-hardware-baseline.md`) is paused (E2-E5, E7 pending).
Benchmarking engine (`mpt`, `MPTCore`) built and reviewed, 154 tests. Docs: `docs/run-bundle-format.md`, README.
Not yet verified with a real Wine game. Decision record: `docs/adr/0003-metal-pt-rename-and-split.md`.

## Resume here

Continue `docs/superpowers/plans/2026-11-24-metal-pt-app.md` at its first unchecked task.
