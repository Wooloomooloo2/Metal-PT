# ADR 0002: Benchmark recording runs unprivileged, ahead of the helper

Date: 2026-11-24. Status: accepted (user: "just dive in"; open to correction).

## Context
The user needs to compare games across Mac translation stacks (CrossOver, Protium, DXMT, D3DMetal) and in-game
settings now, and later share runs on a public site. The original spec put recording in the root helper (M5), after
battery (M2), fans (M3) and profiles (M4). Nothing recording needs is privileged: IOReport, SMC reads, HID
temperatures, `log stream` and `lsof` of the user's own processes all work as the user (measured, E6/E8 2026-11-24).

## Decision
- New milestone **M1B — benchmarking**, after M1 core telemetry and before M2.
- Recording runs in the user's session: the `fwbench` CLI first, the menu-bar app later, both on one FWCore recorder.
  The helper never records.
- FPS comes from the Metal HUD log: per-second counts from the unified log for any process, per-frame times from
  stderr when `fwbench run` launches the game. Private log data (root) is not used.
- The run bundle (`*.fwrun/`: `run.json`, `samples.csv`, `frames.csv`) is versioned and contains no personal data, so it
  can be uploaded later.
- `fwbench hud on` sets the HUD variables with `launchctl setenv` as a lease: every exit path unsets them.

## Alternatives rejected
- Recording in the helper: waits on M2 and XPC for no privilege gain, and a root process would read user game paths.
- Private log data for per-frame times everywhere: changes a system-wide privacy setting and needs root.

## Consequences
Benchmarking works with no helper installed. Recording stops when the CLI or app exits (no background survival); a
benchmark run is short and supervised, so this is acceptable. The spec's §3 "Recording runs in the helper" is superseded.
