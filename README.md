# fw-helper-mac

Battery charge limit, fan control, performance profiles, monitoring and an in-game overlay for
**Apple Silicon MacBooks**. The macOS sibling of [fw-helper](https://github.com/Wooloomooloo2/fw-helper)
(Linux) and [fw-helper-windows](https://github.com/Wooloomooloo2/fw-helper-windows).

> **Status: M0 — hardware baseline.** Nothing user-facing yet. `fwprobe` is a developer tool for
> measuring what this hardware exposes. See `docs/superpowers/specs/` for the design.

Built and tested on a MacBook Pro 16" M4 Max (Mac16,5), macOS 26.6.

## What Apple Silicon does not allow

There is no TDP / power-limit interface and no undervolting on Apple Silicon. fw-helper-mac will not
pretend otherwise. Performance modes are macOS's Low Power / Automatic / High Power modes.

## Build

    swift build
    swift test
    .build/debug/fwprobe            # usage

## Benchmarking (fwbench)

`fwbench` records a game run (FPS, frame times, power, temperatures, fans, the Wine/Metal stack in use) and compares
runs: CrossOver vs Protium, DXMT vs D3DMetal, one in-game setting vs another. It runs as you, never as root, and needs
no helper. Details: `docs/adr/0002-unprivileged-benchmark-recording.md`.

Five-minute workflow:

    F=.build/debug/fwbench
    $F hud on                      # terminal 1: leave running; Ctrl-C unsets the HUD variables
    # relaunch the launcher / game so it picks the variables up, get to a repeatable scene
    $F record --warmup 15 --seconds 120 --label "CrossOver DXMT, High"   # terminal 2; writes summary.html at the end
    $F ls                          # run names
    $F summary <run> --open        # open the summary
    $F compare hzd add <run1> <run2>
    $F compare hzd report --open

`$F run --seconds 120 -- <command…>` launches the game itself with the HUD variables set and captures per-frame
times from its stderr, which adds 1 % / 0.1 % lows. `$F ls` lists runs; `$F` alone prints all commands.

- Files: runs in `~/Documents/FW Benchmark/runs/<UTC timestamp>-<game>.fwrun/`, compare projects in
  `~/Documents/FW Benchmark/projects/`. Format: `docs/run-bundle-format.md`. No user name, home path or host name is written.
- Cost (measured, `docs/hardware-baseline.md`): about 2.6 % of one core while recording (fwbench about 1.5 %, `log` about 1.1 %).
- Limits: FPS comes from Apple's Metal HUD, which is drawn on screen while `hud on` is active; no HUD, no FPS (telemetry still records).
  Per-frame lows exist only for runs started with `fwbench run`. `gpu_w` is IOReport and may under-read; use the
  SMC power columns for load. Metal games only; the SMC columns are measured on one Mac model.

## License

GPL-3.0.
