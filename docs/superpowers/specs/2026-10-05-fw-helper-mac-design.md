# fw-helper-mac — design

Date: 2026-10-05. Status: approved in brainstorming, awaiting written-spec review.

## 1. Intent

A macOS sibling of [fw-helper](https://github.com/Wooloomooloo2/fw-helper) (Linux) and
[fw-helper-windows](https://github.com/Wooloomooloo2/fw-helper-windows) for Apple Silicon
laptops, built and tested on a **MacBook Pro 16" M4 Max (Mac16,5), macOS 26.6**.

Two goals, in priority order (both are required for the project to be "done"):

1. **Replace AlDente** — battery charge limiting and fan control that are reliable and cheap
   in CPU (AlDente's CPU use is the main complaint).
2. **Gaming overlay and telemetry** — an in-game overlay (including FPS) and a monitoring
   window, which AlDente does not provide at all.

Distribution: public GPL-3.0 source on GitHub; for now installed only on the author's Mac,
signed with the author's Apple Development certificate. Developer ID signing and
notarisation are a later packaging step, and the structure must not preclude them.

### Success criteria

- Charge limit holds overnight with the app quit; charging measurably stops at the limit
  (battery current 0), not merely a key that reads back.
- Custom fan curve drives both fans, and every exit path hands the fans back to the system.
- Overlay is visible over a fullscreen game and shows FPS, CPU/GPU watts/clock/utilisation,
  temperatures, fan RPM, RAM and battery.
- Background cost: helper idle < 0.2% CPU; telemetry sampling at 1 Hz < 1% CPU while
  the overlay or monitor is open. Measured, not estimated.
- AlDente can be uninstalled.

### Platform reality (what is and is not possible)

| Feature | Apple Silicon |
|---|---|
| Charge limit, heat protection, top-up | Yes — SMC writes (root) |
| Fan curve / manual RPM | Yes — SMC writes (root); RPM read needs no root |
| TDP / PL1 / PL2 | **Not available.** No user power-limit interface exists. Do not add one |
| Performance modes | `pmset powermode` 0 Automatic / 1 Low / 2 High (High is supported on this machine) |
| CPU/GPU/ANE/DRAM watts, clocks, residency | Yes, unprivileged, via IOReport (private framework) |
| Temperatures | Yes, unprivileged, via SMC read and/or IOHIDEventSystem |
| Another app's FPS | No public API. Approach under test: Metal HUD logging (M0) |

## 2. Architecture

Native Swift (Swift 6, SwiftUI), one repo, one Xcode project backed by a Swift package.

```
FWCore        library, no UI. SMC access, IOReport sampler, battery/fan/profile policy (pure), CSV format
fwhelperd     root LaunchDaemon (SMAppService.daemon). SMC writes, fan loop, charge controller, FPS log reader, recording
FW Helper.app SwiftUI MenuBarExtra + Settings/Monitor windows + overlay NSPanel. Unprivileged
fwhelperctl   CLI over the same XPC interface; `status` also works without the helper
```

### Privilege boundary

- The app never runs as root and reads all telemetry itself, so monitor and overlay work even
  when the helper is not installed or not approved.
- The helper owns every SMC write and persists independently of the app (the charge limit
  must hold with the app closed). Its state lives in
  `/Library/Application Support/fw-helper/state.json`.
- XPC interface (Mach service), typed and minimal:
  `status`, `setProfile`, `setChargeLimit`, `setHeatProtection`, `topUp`, `startCalibration`,
  `cancelCalibration`, `setFanCurve`, `releaseFans`, `startRecording`, `stopRecording`,
  `subscribeFPS`.
- The helper accepts only clients whose code signature matches the author's Team ID
  (`setCodeSigningRequirement` on the connection).

### Fan lease (carried over from Linux ADR 0006 / Windows ADR 0005)

Fan control is borrowed. The helper returns fans to system control (`F*Md` = auto, unlock
cleared):

- on normal exit and SIGTERM,
- before sleep (IOKit sleep notification) — re-acquired after wake,
- from a watchdog if the control loop misses 5 s,
- on startup, unconditionally, before anything else (covers a crash; launchd restarts it),
- when any temperature driving the curve cannot be read,
- when the curve is released or a profile with "system fan control" is applied.

Recovery reads hardware, not flags: release writes auto even if the helper believes it
never took the fans.

### Coexistence with AlDente

Both write the same SMC charge keys. The helper detects a running AlDente (process and its
helper `com.apphousekitchen.aldente-pro.helper` or equivalent, confirmed in M0) and refuses to apply
battery control while it runs, reporting that reason. Fan features are unaffected.

### Sampling cost

Telemetry is sampled at 1 Hz, only while a consumer is attached (overlay, monitor,
recording, CLI) — reference counted, as in the Windows app. With no consumer, the app
samples nothing. The helper's charge controller polls battery state every 30 s and
reacts to power-source change notifications. Timers use leeway/coalescing.

## 3. Features

### Battery (milestone M2)

- **Charge limit** 50–100%. Mechanism chosen in M0 (candidates `CHTE`; legacy `CH0B`/`CH0C`).
  Below the limit on AC: charging allowed; at or above: charging inhibited.
  If the battery is above the limit on AC, it is held (not discharged — discharge was not requested).
- **Heat protection**: charging is inhibited while battery temperature ≥ threshold
  (default set from M0 measurements, initially 40 °C), resumes 3 °C below it.
- **Top-up**: one-off charge to 100%. Reverts to the limit on unplug, or 24 h after start.
- **Calibration**: guided cycle — charge to 100%, hold 1 h, discharge to 15% (requires the
  adapter to be inhibited via `CHIE` or the user unplugging; M0 decides), charge back to the
  limit. Cancellable; cancel restores normal limit behaviour.
- Battery state machine is pure (`BatteryPolicy`: inputs → desired charger state), unit-tested.

### Fans (M3)

- Two fans on this machine. 8-point curve, temperature = max(CPU die, GPU die) sensors chosen in M0.
- Pure `FanController` per tick: hysteresis, ramp rate limit, stall band (no target below the
  fan's measured minimum), override to max at a hard temperature (set from M0 baseline,
  no lower than the system's own behaviour), unit-tested with a fake SMC.
- "System" mode = release to macOS. A floor option ("never quieter than macOS would be")
  follows the Windows app's FirmwareFloor idea if M0 shows the system target is readable.

### Profiles (M4)

- Built-ins: **Silent** (powermode Low, quiet curve), **Balanced** (Automatic, system fans),
  **Performance** (High, aggressive curve). User profiles saved from the app.
- A profile = power mode + fan mode/curve. Battery settings are global, not per-profile.
- Separate remembered profile for AC and battery; switch on power-source change.
- Global hotkey to cycle profiles (default ⌃⇧F5, matching Windows).

### App UI (M5)

- MenuBarExtra: profile switcher, live CPU/GPU watts and temps, fan RPM, battery %/limit,
  helper status and any "why not" messages.
- Settings window: profiles, fan curve editor (drag points), battery options, overlay options,
  launch at login (SMAppService.mainApp).
- Monitor window: Swift Charts on a shared time axis — load, power, clocks, temperature,
  fan, memory, battery, FPS; 300-sample live history; start/stop recording; open past sessions.
- Recording runs in the helper (survives the app closing). Sessions are CSV under
  `/Library/Application Support/fw-helper/sessions/`, world-readable; columns only ever appended;
  readers map by header name; keep the last 20; 12 h auto-stop.

### Overlay (M6)

- Borderless non-activating `NSPanel`, `ignoresMouseEvents`, level above fullscreen windows,
  `collectionBehavior` `.canJoinAllSpaces` + `.fullScreenAuxiliary` + `.stationary`.
- Compact (one line) and detailed layouts; corner position; global show/hide hotkey.
- Contents: FPS (+ frametime), CPU W/clock/util, GPU W/clock/util, CPU & GPU temp, fan RPM,
  RAM used, battery %.
- **FPS:** source chosen by the M0 spike. Primary candidate: Metal HUD logging
  (`MTL_HUD_LOG_ENABLED`) read live from the unified log by the helper and streamed over XPC.
  If the spike fails, fallback is a toggle that enables Apple's Metal Performance HUD
  alongside our overlay, and FPS is omitted from our overlay and CSV.

### CLI

`fwhelperctl status | profile <name> | charge-limit <n> | top-up | fan curve … | fan release |
record start [label] | record stop | selftest`.

## 4. Milestones

Each is verified on hardware before the next starts; findings go to `docs/hardware-baseline.md`.

- **M0 — hardware baseline spike.** Probe tools only. Answers: working charge-inhibit key and
  its efficacy (current → 0); adapter inhibit for calibration; fan unlock/control sequence on
  M4 (`Ftst`, `F*Md`, `F*Tg`), min/max RPM, whether the system reclaims fans, release behaviour;
  temperature sensor keys (CPU/GPU die, battery); IOReport channels for CPU/GPU/ANE/DRAM energy,
  clocks, residency; AlDente's helper identifiers; and the FPS spike (Metal HUD log —
  availability, latency, CPU cost, tested in a real game).
- **M1 — core and telemetry.** FWCore SMC reader, IOReport sampler, battery/RAM readers;
  `fwhelperctl status`; unit tests.
- **M2 — helper and battery.** fwhelperd, SMAppService registration, XPC with signature check,
  AlDente detection, charge limit, heat protection, top-up, calibration. AlDente retired.
- **M3 — fans.** FanController + lease loop + watchdog + sleep handling.
- **M4 — profiles.** Power mode, curves, AC/battery memory, hotkey.
- **M5 — app UI.** Menu bar, settings, curve editor, monitor, recording.
- **M6 — overlay.** Panel, layouts, FPS integration, hotkey.
- **M7 — packaging.** Signed build in /Applications, helper approval flow, README, CHANGELOG.

## 5. Testing and error handling

- Hardware behind protocols (`SMCReading`, `SMCWriting`, `PowerSampling`, `BatteryReading`);
  pure policy types are tested with fakes via `swift test`. No test touches real SMC.
- `fwhelperctl selftest` exercises the hardware and writes a report.
- Hard rule: **read-back is not efficacy.** A feature is "working" only when its effect is
  measured (charge current 0, RPM change, sustained behaviour), and the evidence is recorded.
- Every feature exposes a capability: available, or the exact reason it is not (helper not
  approved, AlDente running, SMC key missing, sensor unreadable). No partial failure may leave
  fans or the charger in a borrowed state.

## 6. Out of scope

Power limits/TDP and undervolting (no interface exists), discharge-on-AC as a user feature,
MagSafe LED control, sailing mode, keyboard backlight, display refresh switching, Intel Macs.

## 7. Repository conventions

Mirrors the sibling repos: `CLAUDE.md` with "Current state / Resume here / Hard rules / Traps",
`docs/adr/` for decisions, `docs/hardware-baseline.md` for measured facts, `CHANGELOG.md`,
GPL-3.0 `LICENSE`.
