# Metal-PT and Metal-PT Helper — design

Date: 2026-11-24. Status: agreed in brainstorming (mockups reviewed), awaiting written-spec review.
Supersedes the product framing of `2026-10-05-fw-helper-mac-design.md`; its safety rules (fan lease, battery policy,
AlDente coexistence, privilege boundary) still apply to the Helper and are referenced, not repeated.
Builds on `2026-11-24-benchmarking-design.md` (the recording engine, done: branch `m1b-benchmarking`).

## 1. Intent

Two free, open-source Mac apps for Apple Silicon, built from one repo (`metal-pt`,
https://github.com/Wooloomooloo2/Metal-PT):

- **Metal-PT (Metal Performance Telemetry)** — for people playing Windows games on Macs (CrossOver, Protium, Whisky…
  with DXMT, D3DMetal, DXVK…). It shows live performance, records runs with a hotkey from inside a game, summarises and
  compares runs, and prepares a run for submission to a public website (built later, on Cloudflare) so a shared
  database of game performance on Macs can grow.
- **Metal-PT Helper** — battery charge limiting and fan control (the AlDente replacement), via a root helper.
  A free bonus for users; not needed for telemetry.

**Why two apps:** the author cannot get an Apple Developer Program membership (Apple's address check rejects a house
name with no number). Without Developer ID, an app can still be shipped to others (unsigned/ad-hoc, approved once via
System Settings → Privacy & Security → Open Anyway), but a root helper cannot be trusted or distributed sensibly.
Metal-PT therefore needs no root and no helper; the Helper is built now, runs on the author's Mac (Apple Development
certificate), and ships to others once Developer ID exists.

### Success
- A user can install Metal-PT, play a game, press ⌃⇧F6 to start/stop recording, and see the run's summary, compare
  runs, and export a submission — without a terminal.
- Telemetry works on any Apple Silicon Mac, showing only what that Mac has (no fans on an Air, no battery on a mini).
- The author can uninstall AlDente: charge limit holds with the app closed, verified by battery current 0.
- Every Helper feature is enabled on a Mac only after an in-app hardware check on that Mac has proven it works.

### Non-goals (this design)
- The website and its upload API (separate project). Metal-PT defines the upload file and an Export button; "Submit"
  is present but disabled ("website coming soon").
- Launching games from the app for per-frame lows: stays a CLI feature (`mpt run -- <cmd>`) for now.
- Notarisation, auto-update, App Store. Intel Macs. TDP / power limits / undervolt (no interface exists — hard rule 5).

### Anti-goals
- Anything uploaded without the user seeing exactly what is sent.
- A Helper feature that reports success from a read-back alone (hard rule 3).
- Metal-PT requiring the Helper, root, or the Helper's presence.

## 2. Constraints
- macOS 15+, Apple Silicon only. Swift 6, SwiftUI; AppKit where SwiftUI can't (overlay panel, report web view).
- No Apple Developer Program: Metal-PT ships ad-hoc signed; the Helper is signed with the author's free Apple
  Development certificate and is for the author's Mac until Developer ID exists. Nothing may preclude notarising later.
- Hardware varies across users (M1–M4, Pro/Max/Ultra; laptops with/without fans; desktops without battery). Readers
  must tolerate missing channels/keys; the measured facts in `docs/hardware-baseline.md` are the author's M4 Max only.
- CLAUDE.md hard rules apply unchanged (fan lease, recovery reads hardware, read-back ≠ efficacy, SMC facts from
  measurement, no TDP, app never root, ADRs).

## 3. Approaches considered and chosen

| Decision | Options | Chosen | Why |
|---|---|---|---|
| Product split | one app with helper / two apps | **two apps, one repo** | No Developer ID: telemetry must ship without a root helper |
| Metal-PT shape | menu-bar first / main window + menu bar | **main window with sidebar + menu-bar item** | Runs, Compare, Submit need room; menu bar keeps one-click Record |
| Overlay default | compact / detailed / compact that expands while recording | **compact, expands while recording** | Out of the way while playing, detail when it matters |
| Helper enabling | M0 measurements first / in-app hardware check / telemetry first, helper later | **in-app hardware check, build it all now** | Works on every user's Mac; turns M0 into a guided step |
| Building .app bundles | SwiftPM + script / XcodeGen / hand-made Xcode project | **SwiftPM + `scripts/make-app.sh`** | One build system, nothing to install, reviewable |
| Repo | separate repos / one | **one repo, shared core** | Both need the same readers; Helper alone writes |

## 4. Rename (first, before new features)

| Was | Becomes |
|---|---|
| repo/folder `fw-helper-mac` | `metal-pt` (remote `github.com/Wooloomooloo2/Metal-PT`) |
| package `fw-helper-mac` | `metal-pt` |
| `FWCore` | `MPTCore` |
| `fwbench` | `mpt` (CLI) |
| `fwprobe` | `mptprobe` (dev tool) |
| run folder `*.fwrun/` | `*.mptrun/` (same layout, `schema: 1` — nothing was published under the old name) |
| `~/Documents/FW Benchmark/` | `~/Documents/Metal-PT/` (`runs/`, `projects/`, `exports/`) |
| HTML meta `fwhelper-run` | `mpt-run` |
| upload file | `*.mptrun.zip` (§6) |
| future `fwhelperd`, `fwhelperctl` | `mpt-helperd`, `mpt-helperctl` |

Bundle ids: `io.github.wooloomooloo2.metal-pt`, `…metal-pt-helper`, daemon `…metal-pt-helper.daemon`.
Docs, README, CLAUDE.md, ADRs and plans are updated to the new names; ADR 0003 records the rename and the split.

## 5. Metal-PT (the telemetry app)

### Structure
- `MPTCore` (existing, renamed): readers, `TelemetrySampler`, `MetalHUDLogStream`, `FrameCounter`, `StackDetector`,
  `RunRecorder`, `RunBundle`, `RunSummary`, `SummaryReport`, `CompareProject`, `CompareReport`, `Privacy`.
- New `MPTApp` library (app logic, testable without UI): a shared **telemetry hub** that owns one sampler + one log
  stream, reference-counted by consumers (Live view, menu bar, overlay, recording) — nothing samples when nothing is
  watching; recording control; settings; the HUD-logging lease.
- `Metal-PT` executable target (SwiftUI app) assembled into `Metal-PT.app` by `scripts/make-app.sh`.
- `mpt` CLI stays (record/run/ls/summary/compare/hud/stack) on the same core.

### Window (sidebar)
- **Live** — followed game (exe name), detected stack, live charts (FPS + frame time, power, utilisation,
  temps/fans) over the last 5 minutes, Record button with elapsed time.
- **Runs** — filterable list (game, stack, settings, date, duration, median FPS, 1 % low); selecting a run shows its
  summary (the existing HTML report, in a `WKWebView`); "Edit settings/notes" (writes the run's user fields);
  "Submit…"; tick runs → "Compare selected…".
- **Compare** — saved comparisons; each shows the existing compare report; pick baseline, add/remove runs, rename.
- **Submit** — reached from a run; see §6.
- **Settings** — hotkeys; overlay corner/style/opacity; FPS logging (below); data folder; launch at login.

### Menu-bar item
Shows FPS and system watts while a game is followed (otherwise an icon). Dropdown: current game + stack, Record /
Stop (with hotkey hint), overlay on/off, recent runs, Open Metal-PT, Quit.

### Hotkeys
⌃⇧F6 start/stop recording, ⌃⇧F7 overlay on/off; both configurable. Registered as global hotkeys that need no
Accessibility permission and work over fullscreen games. Start/stop posts a notification ("Recording
HorizonZeroDawnRemastered · Protium DXMT" / "Run saved — add settings"); clicking "Run saved" opens that run.

### Overlay
Borderless, click-through, non-activating panel above fullscreen apps on all Spaces. Default style: compact one-line
strip (● time · FPS · 1 % low · system W · GPU % · die °C) that expands to the detailed panel (FPS large, frame-time
sparkline, power, CPU P/E, GPU, temps/fans, stack) while recording. Corner configurable; default top-left (the Metal
HUD is top-right). Style settable to always-compact or always-detailed.

### FPS logging (the Metal HUD)
FPS needs `MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1` in the game's environment (measured, E8), which also shows
Apple's HUD on screen. Settings → "FPS logging: on" sets both via `launchctl setenv` for apps launched afterwards and
unsets them when turned off or when Metal-PT quits (a lease, as `mpt hud on`). The Live view and menu explain that
games/launchers must be started after turning it on. If the variables are found set at launch without Metal-PT
holding them (crash), Metal-PT adopts them when the setting is on, unsets them when off.

### Run notes
After a recording stops, the run's settings/notes can be typed in the Runs page. These feed "what differs".

## 6. Upload format

- Export writes `~/Documents/Metal-PT/exports/<run folder name>.zip` (the folder name already ends `.mptrun`, so the
  file is `<…>.mptrun.zip`): a zip of the run folder **without** `summary.html`, plus `manifest.json` at the zip root:
  `{ "format": "metal-pt-run", "schema": 1, "files": [{ "path", "bytes", "sha256" }], "app": "<version>",
  "includesNotes": bool }`.
- The run folder's existing privacy scrubbing applies (no user name, home path, host name, serial). Free-text notes are
  excluded unless the user ticks "Also send my notes"; the label and game settings are included (they are the point).
- Size: 1 Hz samples + frames are small (≈ 1 MB for 2 min with frames, more for long runs). Exports over 25 MB are
  refused with a message (keeps to a single Cloudflare Worker request body).
- The Submit sheet shows: game, stack, Mac, settings, notes (with the tick box), data size and counts, and the
  privacy line; buttons "Export file…" (enabled) and "Submit" (disabled until the website exists).
- `docs/run-bundle-format.md` gains the zip/manifest section; the website is not specified further here.

## 7. Metal-PT Helper (battery + fans)

Carries over `2026-10-05-fw-helper-mac-design.md` §2 (privilege boundary, XPC interface, fan lease, AlDente
coexistence, sampling cost) and §3 Battery, Fans, Profiles, with these changes:

- Separate menu-bar app `Metal-PT Helper.app` + settings window; the root daemon is registered with
  `SMAppService.daemon` from inside it. `mpt-helperctl` CLI over the same XPC interface.
- Dropdown: profile (Silent / Balanced / Performance), battery % and state ("holding at limit"), charge limit slider,
  Top up, heat protection, measured battery current; fans (RPM, curve, die temp); helper and AlDente status. Fan curve
  editor and battery options in the settings window. Sections a Mac lacks are hidden.
- **Hardware check, per Mac** (replaces "M0 decides" for each user): enabling charge limiting or a fan curve for the
  first time runs a guided check through the daemon, then stores the result keyed by model id + macOS build in the
  daemon's state; a macOS update re-runs it.
  - Charge: preconditions (charger connected, battery < 95 %, AlDente not running); find the candidate key from a
    data table of known keys/bytes (seeded from measurement on the author's Mac); write; watch battery current fall
    to ≈ 0 within a timeout; restore; confirm current rises; save. Any failure restores the original bytes and leaves
    the feature off with the reason.
  - Fans: take one fan to a target RPM, confirm the RPM really changes, hand back, confirm the system controls it
    again; then the same for each fan.
  - The author's own run of these checks also fills `docs/hardware-baseline.md` (E2/E4) — the app can export the
    check log.
- Ships to others only with Developer ID (later); until then the README says it is for building from source.

## 8. Build and distribution
- `swift build` / `swift test` as now. `scripts/make-app.sh [metal-pt|helper] [--sign IDENTITY]` builds release
  executables, assembles `.app` bundles (Info.plist, icon, embedded daemon plist for the Helper), and signs
  (ad-hoc by default; the Helper needs the author's Apple Development identity).
- Releases: GitHub Releases with a zipped `Metal-PT.app` and a README section on "Open Anyway". Building from source
  documented.

## 9. Order of work
1. Rename (§4), ADR 0003, docs; push to the new remote (GPL-3.0, see §10).
2. Metal-PT: telemetry hub, app shell (window + menu bar), Live, hotkeys + notifications, FPS logging lease, overlay.
3. Metal-PT: Runs, Compare, Submit/export, Settings, launch at login, `make-app.sh`, release zip.
4. Helper: daemon + XPC + code-signature check, state, hardware-check framework, AlDente detection.
5. Helper: battery (limit, heat protection, top-up, calibration) behind the charge check.
6. Helper: fans (curve, lease, watchdog, sleep) behind the fan check; profiles (power mode + fans, AC/battery).

## 10. Open items
- **Licence (decided 2026-11-24): GPL-3.0.** The GitHub repo's initial commit (GPL-2.0 `LICENSE` + stub `README.md`)
  is merged into this history (unrelated-histories merge, no force-push), keeping this repo's GPL-3.0 `LICENSE` and
  README.
- Real-game verification (test plan B1) happens once Metal-PT runs; it may change FPS-logging details.

## 11. Decisions made while writing this up (the designer's calls — open to correction)

1. **The hardware check is the measurement.** Hard rule 4 says SMC keys/bytes come from measurement on the machine.
   The known-keys table holds *candidates* (from the E1 inventory and other tools, tagged `[?]`); the check, run as
   root with the original bytes restored on any failure, measures whether a candidate works on this Mac (current → 0
   for charge, RPM change for fans). Only a passed check enables a feature. So the Helper does not wait for a separate
   `mptprobe` M0 session; the author's first check run fills E2/E4 in the baseline and promotes those entries to `[M]`.
   Entries for other Mac generations (e.g. `CH0B`/`CH0C`) may be added as candidates; they still only enable after a
   check passes on that Mac.
2. **Calibration is left out of the first Helper version.** It needs adapter inhibit (`CHIE`, unmeasured) and a
   third check type. Charge limit, heat protection and top-up ship; calibration is a later addition. Heat protection
   default 40 °C (from the original spec), adjustable 35–45 °C, resumes 3 °C below.
3. **What runs in the background.** Two separately counted costs: the log stream runs whenever FPS logging is on
   (it is how a game is noticed; measured ≈ 1.1 % of one core, E8); the 1 Hz sampler runs only while something shows
   or records numbers — the window, the overlay, a recording, or the menu-bar item *while a game is followed*. With
   FPS logging off and no window/overlay/recording, Metal-PT samples nothing.
4. **Which process is "the game".** Follow rule for the app: among processes logging HUD lines, prefer those the
   stack detector identifies as Wine/translated (non-"native"); among those, the busiest; Metal-PT itself is never
   followed. The Live view and menu show "Following: <exe> ▾" with a picker listing the other HUD processes, and the
   choice sticks until that process exits. The CLI keeps `--pid`/`--name`.
5. **After a macOS update (or any change of model id/build) the Helper suspends** charge limiting and fan curves
   (charging and fans return to macOS), notifies the user, and re-runs the check automatically when its
   preconditions are met (charger connected, battery < 95 %, AlDente not running); passing re-enables the feature.
   Unverified bytes are never written on a new build.
6. **Git.** Work continues from `m1b-benchmarking` (which contains M0's commits) on a new branch `metal-pt`; the
   rename is its first task. `main` gets these branches when the author chooses to merge. No `.fwrun` migration:
   `~/Documents/FW Benchmark/` does not exist on the author's Mac (only throwaway demo runs were made), so readers
   accept `.mptrun` only.
7. **Recording session logic moves into the core** (`Sources/fwbench/Session.swift` → `MPTCore`), so the app and the
   CLI share it.
8. **CLAUDE.md's trap "SMC integer types are big-endian" is wrong for this machine** (E1 measured little-endian); the
   rename task corrects the trap, and `SMCValue` integer decoding is fixed (with the Helper's checks depending on it).
9. **Mockups** are in `docs/superpowers/specs/metal-pt-mockups/` (HTML fragments shown during brainstorming; open in a
   browser — unstyled but readable).

## 12. Left to the builder
App icon design; exact SwiftUI layouts within the agreed mockups; chart implementation for Live (Swift Charts);
settings storage (UserDefaults for the app, JSON state file for the daemon); the known-keys data table format; how
the telemetry hub schedules timers.
