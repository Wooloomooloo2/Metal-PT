# Benchmarking: recording runs, summaries and comparisons — design

Date: 2026-11-24. Status: written after the user said "just dive in"; the calls marked *(call)* are mine and open to
correction. Amends `2026-10-05-fw-helper-mac-design.md` (milestone order, where recording runs).

## 1. Intent

Bring the Windows app's benchmarking workflow (fw-helper-windows `docs/plan-benchmarks-and-game-profiles.md`, phases
1–3) to the Mac, aimed at a different question. On Windows the variable is an app setting (power mode, fan curve). Here
the user is testing **how games run under Mac translation stacks** — CrossOver vs Protium, DXMT vs D3DMetal, Wine
builds — and **in-game settings**. So a run must capture *which stack ran the game*, and comparisons must line runs up
by that.

Later, a **public website** where anyone can upload runs to build a database of game performance on Macs. That site is
a separate project. This design only fixes the **run bundle format** so it can be uploaded and aggregated later.

### Success criteria

- Record a run without leaving the game (hotkey, later; CLI first) and get per-second FPS, power, clocks, temperatures,
  fans, memory and battery, and the stack in use, with no root.
- A one-run HTML summary: median FPS, 5th-percentile second, 1 %/0.1 % lows when frame times exist, FPS per watt,
  charts over time.
- A compare project (runs + baseline) whose HTML report shows FPS/power/efficiency bars, **what differs** (stack,
  layer version, game settings, power mode, AC/battery, macOS) and comparability warnings.
- Recording cost < 1 % CPU at 1 Hz, measured.
- Bundles contain no user name, home path or serial number.

### Non-goals / anti-goals

- No limiter rules engine yet. The Windows rules are Intel-specific (PL1, IGCL throttle reasons); Apple Silicon needs
  its own evidence first. *(call)*
- No game-profile auto-switching (Windows phase 5) — no app profiles exist yet on the Mac.
- Never inject into or modify a game, a Wine prefix or a translation layer. Reading is fine; changing their files is not.
- Not a website in this repo.

## 2. What was measured (2026-11-24, `docs/hardware-baseline.md` E6/E8)

- **FPS:** `MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1` makes Metal log `metal-HUD: <cumulative frames>,a,b,<per-frame
  interval/present-delay pairs>` about once a second. In the unified log the per-frame list is `<private>`, but the frame
  count, timestamp, PID and image path are public and readable without root → **per-second FPS for any Metal process**.
  The full line, with **every frame time**, goes to the process's stderr.
- **Stack detection:** `lsof -p <game pid>` (no root) shows the mapped runtime: e.g. Protium's
  `runtime/lib/wine/aarch64-unix/winemetal.so` (DXMT), `libarm64ecfex.so` (FEX), `libvulkan_kosmickrisp.dylib`,
  `d3d12.dll`, and a Metal cache under `…/C/dxmt/<exe>/`. The game process's name is its Windows path
  (`Z:\…\HorizonZeroDawnRemastered.exe`).
- **Power:** IOReport "Energy Model" gives only `GPU Energy` on this machine; CPU channels read 0. SMC `P***` keys
  (`PSTR`, `PHPC`, `PDTR` …) are unprivileged and track load, meanings unconfirmed. CPU/GPU residency channels work.

## 3. Approaches considered

| | Where recording runs | FPS source | Verdict |
|---|---|---|---|
| A | Root helper (original spec, M5) | unified log via helper | Waits for M2 helper + XPC; nothing it needs is privileged |
| **B** | **Unprivileged, in the user session: CLI `fwbench` now, the menu-bar app later; both on one FWCore recorder** | **unified log (per-second) + stderr when we launch the game (per-frame)** | **Chosen** *(call)*: ships first, no root, matches hard rule 6 |
| C | Overlay app only, no CLI | same as B | Slower to get running; hard to script repeatable runs |

Per-frame times through private log data (`log config --mode private_data:on`, root, system-wide) are left out for now:
it changes a system privacy setting. Revisit with the helper if stderr capture can't reach launcher-started games.

## 4. Design

### 4.1 Milestone order *(call)*

M1 core telemetry is pulled forward and extended, and benchmarking becomes **M1B**, before the helper (M2). Battery,
fans and profiles keep their order after it. Recorded as ADR 0002.

### 4.2 FWCore pieces (pure where possible, unit-tested)

- `MetalHUDLine` — parse a `metal-HUD:` message (public or full) → frame count, a, b, frame times. Pure.
- `FrameCounter` — per-PID cumulative counts + timestamps → FPS per second; handles resets/restarts. Pure.
- `MetalHUDLogStream` — runs `/usr/bin/log stream --style ndjson --predicate 'eventMessage BEGINSWITH "metal-HUD"'`,
  decodes lines (PID, image path, timestamp, message). Reference-counted, only while recording or monitoring.
- `StackDetector` — PID → stack fingerprint from mapped files (`proc_pidinfo` region paths or `lsof`): runtime
  (CrossOver / Protium / Whisky / Kegworks / GPTK / native), Wine arch, x86 translator (Rosetta / FEX / none), graphics
  layers (D3DMetal, DXMT, DXVK, vkd3d, MoltenVK, KosmicKrisp), and versions where the bundle exposes one (Info.plist,
  file names). Fingerprint table is data, pure-tested on path lists.
- `TelemetrySampler` — 1 Hz: GPU W (IOReport), SMC power keys (raw, named), CPU P/E utilisation and residency
  (IOReport), GPU busy %, temperatures (HID), fan RPM (SMC), memory (host_statistics), battery %/W/AC, `pmset` power
  mode, thermal pressure (`ProcessInfo.thermalState`).
- `RunRecorder` — writes the bundle (4.3), buffered, flushed once a second.
- `RunSummary` — steady seconds (the followed process presenting frames; first 10 s trimmed; seconds above 2× median FPS
  left out), stats per column, 1 %/0.1 % lows from frame times. Port of the Windows logic. Pure.
- `CompareProject` + `SummaryReport` + `CompareReport` — self-contained HTML, system fonts, data embedded as JSON,
  ported from Windows. Pure string generation, tested against fixture bundles.

### 4.3 Run bundle (the upload unit)

A directory `~/Documents/FW Benchmark/runs/<yyyyMMdd-HHmmss>-<game>.fwrun/`:

- `run.json` — `schema: 1`; app version; machine (model id `Mac16,5`, chip, GPU cores, RAM, macOS build); game (exe
  name, title, store app id when known); **stack** (runtime + version, Wine arch, translator, graphics layers +
  versions); settings (power mode, AC/battery, display resolution and refresh); user fields (label, game settings, notes);
  start/end, steady window, FPS source (`log` per-second or `stderr` per-frame).
- `samples.csv` — 1 Hz, columns read by header name, append-only.
- `frames.csv` — optional, one row per frame (`t_ms,interval_ms,present_delay_ms`).
- `summary.html` — generated.

Privacy: paths are reduced to the part after the runtime root or the Wine `drive_c`; no user name, home path, hostname
or serial number in any file. Uploading = zipping the directory minus the HTML.

### 4.4 Surfaces

- **`fwbench` CLI (this phase):**
  - `fwbench record [--pid P | --name substr] [--seconds N] [--warmup S] [--label …]` — follows the Metal process
    with the most frames (or the given one);
  - `fwbench run [--seconds N] -- <command…>` — launches the game itself with the HUD env and captures stderr for
    frame times;
  - `fwbench hud on|off` — `launchctl setenv/unsetenv` of the two HUD variables for apps launched afterwards, as a
    lease (always undone on exit/Ctrl-C);
  - `fwbench summary <run>`, `fwbench compare <project.json> [add <run>…] [--baseline N]`, `fwbench ls`.
- **App (later, M5/M6):** menu-bar start/stop, global hotkey, REC indicator in the overlay, notes prompt after a run,
  compare window. Same FWCore recorder.

### 4.5 Website (separate project, later)

Consumes `run.json` + `samples.csv` + `frames.csv`. Aggregates by game × machine × stack. Not designed here beyond the
bundle staying versioned (`schema`) and private-by-construction.

## 5. Left to the builder

- Exact SMC power keys to record by default (record all non-zero `P***` floats under their key names until E6 names them).
- Stack fingerprint table contents — start from Protium/CrossOver paths found on this machine.
- HTML layout details — follow the Windows reports and `example_summary.html`.

## 6. Open questions / risks

- Does the HUD env reach a game launched by CrossOver/Protium/Steam? CrossOver has its own Metal HUD toggle; Protium
  loads `libMetalMetricsInterpose.dylib`. To test with a real game (E8 remainder).
- Does stderr reach us through `wine` / the launcher when `fwbench run` starts the game?
- Unified-log reader cost at 1 line/s/process — expected small; measure.
- CPU power: which SMC key, pending idle E6.
