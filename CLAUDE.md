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
    .build/debug/MetalPT             # the app, unbundled (no notifications / login item); MPT_DATA_ROOT=dir isolates data
    MPT_DEBUG=1 .build/debug/MetalPT # debug builds only: extra logs + distributed-notification hooks (AppModel.debug*)
    .build/debug/MetalPT --render-snapshots DIR   # every page/overlay to PNG with fixture data
    scripts/make-app.sh metal-pt     # release build -> build/Metal-PT.app + build/Metal-PT-<VERSION>.zip, ad hoc signed
    swift scripts/make-icon.swift    # redraw Resources/MetalPT/AppIcon.icns (+ AppIcon-1024.png)

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
- Steam lives at `…/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx` (no `.app`); games inherit Steam's environment.
- AlDente writes the same charge keys. Quit it (and confirm its helper is not rewriting them) before any charge experiment.
- Never call `ProcessInfo.hostName` / `Host.current()` in the app: in the bundled app NSHost waits on mDNS / Local
  Network privacy and stalled a recording start and quit for over a minute. `Privacy.localHostNames()` reads locally.
- `VERSION` and `MetalPTVersion.current` must match (make-app.sh and `MetalPTVersionTests` check it).
- Tests use `MemoryDefaults`, never `UserDefaults(suiteName:)` (suites leave plists in ~/Library/Preferences).

## Current state

Metal-PT app plan (`docs/superpowers/plans/2026-11-24-metal-pt-app.md`) done, including the final whole-branch review
fixes (`.superpowers/sdd/2026-11-24-metal-pt-app/final-fix-report.md`), pending the user's manual checks: app with
Live, Runs, Compare, Settings, overlay, hotkeys, export; `scripts/make-app.sh` builds the ad-hoc-signed
`Metal-PT.app` (0.2.0, hardened runtime; launchctl, `log stream` and SMC/IOKit reads verified under it).
Still to check by hand: a real Wine game (CrossOver/Protium), a "Run saved" notification click in the bundled app,
and launch at login from /Applications (starts menu-bar only).
Metal-PT limiter/feedback plan (`docs/superpowers/plans/2026-11-24-metal-pt-limiter-and-feedback.md`) done incl. final
review fixes (`.superpowers/sdd/2026-11-24-metal-pt-limiter-and-feedback/final-fix-report.md`): GPU clock and
memory-pressure columns, "What held it back" (rulings L1/L3: clock threshold from the pmgr table, busy-only on low
power/battery), recording feedback, single instance + reopen, not-reporting-frames warning. Open `[?]`: P n -> MHz
mapping unverified until a heavy GPU-bound game run with `gpu_mhz` shows ~1578 MHz and "Mostly GPU".
M0 hardware baseline (`docs/superpowers/plans/2026-10-07-m0-hardware-baseline.md`) is paused (E2-E5, E7 pending).
Metal-PT game-title/FPS-per-watt plan (`docs/superpowers/plans/2026-11-25-metal-pt-game-title-and-efficiency.md`) done pending
final review: editable game title (`game.title`; `game.exe` stays the recorded app) and FPS/W as a headline metric.
`SummaryReport.version` 4 and run-index `cacheVersion` 4 regenerate older summaries and caches lazily.
Decision record: `docs/adr/0003-metal-pt-rename-and-split.md`.

2026-11-25 (uncommitted, tests pass, `build/Metal-PT.app` built, not installed): compare hang fix, same-game Add
Runs, runs named by what differs + coloured, D3DMetal version in the stack. See `docs/BACKLOG.md`.

## Resume here

User's manual checks of the rebuilt app: a heavy GPU-bound game recording (verify the GPU clock mapping and record it
`[M]` in hardware-baseline), the red menu-bar label and sounds, the not-reporting warning, notifications. Then a first
GitHub Release (upload `build/Metal-PT-<version>.zip`). Next: write the Metal-PT Helper plan (battery charge limit and
fans via a root helper; `make-app.sh helper` is reserved).
