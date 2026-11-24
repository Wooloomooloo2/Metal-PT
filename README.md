# Metal-PT

**Metal Performance Telemetry** for Apple Silicon Macs. Two free, open-source apps are planned from this repo
(https://github.com/Wooloomooloo2/Metal-PT):

- **Metal-PT**: for people playing Windows games on Macs (CrossOver, Protium, Whisky, with DXMT, D3DMetal, DXVK...).
  Live performance, hotkey-driven run recording, summaries and comparisons, and a submission file for a future
  public performance database. Needs no root and no helper.
- **Metal-PT Helper**: battery charge limiting and fan control via a root helper. Not yet built.

Today the repo holds the shared core (`MPTCore`), the `mpt` command-line recorder and `mptprobe`, a hardware probe
for development. The SwiftUI app is in progress. Design: `docs/superpowers/specs/2026-11-24-metal-pt-design.md`.

> **Status: M0 — hardware baseline.** Nothing user-facing yet. `mptprobe` is a developer tool for
> measuring what this hardware exposes. See `docs/superpowers/specs/` for the design.

Built and tested on a MacBook Pro 16" M4 Max (Mac16,5), macOS 26.6.

## What Apple Silicon does not allow

There is no TDP / power-limit interface and no undervolting on Apple Silicon. Metal-PT will not
pretend otherwise. Performance modes are macOS's Low Power / Automatic / High Power modes.

## Build

    swift build
    swift test
    .build/debug/mptprobe            # usage

## Command-line recorder (mpt)

`mpt` records a game run (FPS, frame times, power, temperatures, fans, the Wine/Metal stack in use) and compares
runs: CrossOver vs Protium, DXMT vs D3DMetal, one in-game setting vs another. It runs as you, never as root, and needs
no helper. Details: `docs/adr/0002-unprivileged-benchmark-recording.md`.

Five-minute workflow:

    F=.build/debug/mpt
    $F hud on                      # terminal 1: leave running; Ctrl-C unsets the HUD variables
    # relaunch the launcher / game so it picks the variables up, get to a repeatable scene
    $F record --warmup 15 --seconds 120 --label "CrossOver DXMT" --settings "High, 1440p"   # terminal 2;
                                   # writes summary.html at the end
    $F ls                          # run names
    $F summary <run> --open        # open the summary
    $F compare hzd add <run1> <run2>
    $F compare hzd report --open

`$F run --seconds 120 -- <command…>` launches the game itself with the HUD variables set and captures per-frame
times from its stderr, which adds 1 % / 0.1 % lows; it also writes summary.html at the end. Both `record` and `run`
take `--settings TEXT` (in-game settings) and `--notes TEXT`; the main display's size and refresh rate are recorded
too. `--warmup` must be shorter than `--seconds`. `$F ls` lists runs; `$F` alone prints all commands.

- Files: runs in ``$MPT_DATA_ROOT` (default `~/Documents/Metal-PT`) `/runs/<UTC timestamp>-<game>.mptrun/`, compare projects in
  `.../projects/`. Format: `docs/run-bundle-format.md`. No user name, home path or host name is written.
- Cost (measured, `docs/hardware-baseline.md`): about 2.6 % of one core while recording (mpt about 1.5 %, `log` about 1.1 %;
  measured with no HUD traffic).
- Limits: FPS comes from Apple's Metal HUD, which is drawn on screen while `hud on` is active; no HUD, no FPS (telemetry still records).
  Per-frame lows exist only for runs started with `mpt run`. `gpu_w` is IOReport and may under-read; use the
  SMC power columns for load. Metal games only; the SMC columns are measured on one Mac model.

## License

GPL-3.0.
