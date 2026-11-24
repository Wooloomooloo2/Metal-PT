# Metal-PT (rename + telemetry app) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the project to Metal-PT and build the Metal-PT app (main window + menu bar + hotkeys + overlay + runs,
compare, export) on the existing recording engine. The Helper app is a separate, later plan.

**Architecture:** SwiftPM only. `MPTCore` (renamed `FWCore`) keeps hardware readers and the recording/report engine
and gains the recording session moved out of the CLI. A new `MPTApp` library holds app logic that is testable
without UI (telemetry hub, follow rule, FPS-logging lease, hotkey parsing, exporter, run index). A `MetalPT`
executable target is the SwiftUI/AppKit app, assembled into `Metal-PT.app` by `scripts/make-app.sh`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI (`NavigationSplitView`, `MenuBarExtra`, Swift Charts), AppKit
(`NSPanel`, `WKWebView`), Carbon `RegisterEventHotKey`, `UserNotifications`, `ServiceManagement` (`SMAppService.mainApp`),
Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-24-metal-pt-design.md` (§4 rename, §5 app, §6 upload format, §8 build, §11
decisions). Mockups: `docs/superpowers/specs/metal-pt-mockups/*.html`. Recording engine: `docs/run-bundle-format.md`,
`docs/superpowers/specs/2026-11-24-benchmarking-design.md`. Measured facts: `docs/hardware-baseline.md`.

## Global Constraints

- macOS 15+, Apple Silicon. `swift build` warning-free; `swift test` green after every task.
- Names (spec §4): package `metal-pt`; `MPTCore`; CLI `mpt`; dev tool `mptprobe`; run folders `*.mptrun/`; data root
  `~/Documents/Metal-PT/` with `runs/`, `projects/`, `exports/`; HTML meta `mpt-run`; app `Metal-PT.app`, bundle id
  `io.github.wooloomooloo2.metal-pt`; display name "Metal-PT".
- Metal-PT never runs as root, never writes the SMC, never needs the Helper.
- Run bundle `schema` stays 1; no `.fwrun` migration (spec §11.6).
- Privacy: nothing personal in any run or export file (existing `Privacy` rules); exports show exactly what is sent.
- Hotkeys default ⌃⇧F6 (record) and ⌃⇧F7 (overlay); no Accessibility permission required.
- FPS logging = `launchctl setenv/unsetenv MTL_HUD_ENABLED 1` and `MTL_HUD_LOG_ENABLED 1`, held as a lease: unset on
  turn-off and on quit; adopt-or-unset at launch (spec §5).
- Background cost (spec §11.3): log stream only while FPS logging is on; sampler only while the window, the overlay,
  a recording, or the menu bar *with a followed game* consumes it. Nothing otherwise.
- Follow rule (spec §11.4): prefer HUD processes whose stack is not "native", then busiest; never Metal-PT itself;
  a user pick sticks until that process exits.
- Upload file (spec §6): `<run>.mptrun.zip` = run folder minus `summary.html` + `manifest.json`
  `{format:"metal-pt-run", schema:1, files:[{path,bytes,sha256}], app, includesNotes}`; refuse > 25 MB; notes excluded
  unless opted in.
- UI tasks are verified with `MetalPT --render-snapshots DIR`, a hidden mode that renders each page/overlay with
  fixture data to PNG via `ImageRenderer` (no Screen Recording permission needed). Look at the PNGs.
- Commit trailer lines from the session; never `git reset`; never commit `docs/data/aldente-ids.txt` unless the
  controller says so (the user staged it).

## Review Focus

1. Metal-PT quits or crashes while FPS logging is on → variables never left set unexpectedly: unset on quit; at the
   next launch, adopted if the setting is on, else unset. (Task 6 tests `adoptsWhenEnabled`, `unsetsStaleWhenDisabled`.)
2. Record hotkey pressed with no game followed → recording still starts (telemetry only) and the notification says
   "no game detected yet"; FPS fills in once a game appears. (Task 5 test `startWithoutGameRecordsTelemetry`.)
3. Quit while recording → the run is finished (end time, summary) before exit. (Task 9 manual check + Task 5 test
   `stopFinishesBundle`.)
4. Sleep/wake during a recording → no bogus rows: a tick gap > 5 s ends the steady window and adds warning
   "recording spanned a sleep". (Task 3 test `sleepGapAddsWarning`.)
5. Hundreds of runs → the Runs list loads from a cached index without parsing frames.csv. (Task 11 test
   `indexSkipsFramesAndCaches`.)

---

### Task 1: Rename to Metal-PT

**Files:** `Package.swift`; move `Sources/FWCore` → `Sources/MPTCore`, `Sources/fwbench` → `Sources/mpt`,
`Sources/fwprobe` → `Sources/mptprobe`, `Tests/FWCoreTests` → `Tests/MPTCoreTests`; every source/test/doc reference;
`README.md`, `CLAUDE.md`, `docs/run-bundle-format.md`, `docs/m0-test-plan.md`; `.gitignore` (add `.superpowers/`);
create `docs/adr/0003-metal-pt-rename-and-split.md`.

- [ ] **Step 1:** `git mv` the directories; update `Package.swift` (name `metal-pt`, products `MPTCore`, `mpt`,
  `mptprobe`, test target `MPTCoreTests`); replace `import FWCore` / `@testable import FWCore`.
- [ ] **Step 2:** Strings: `.fwrun` → `.mptrun` (RunBundle naming/collision code and tests); `FW Benchmark` →
  `Metal-PT`; meta `fwhelper-run` → `mpt-run`; page titles "· fwbench" → "· Metal-PT"; usage text `fwbench` → `mpt`,
  `fwprobe` → `mptprobe`; DispatchQueue labels; `appVersion` constant → "0.2.0-dev".
- [ ] **Step 3:** Docs: README title "Metal-PT", CLI section renamed, intro per spec §1 (two apps; Helper not yet
  built); run-bundle-format and test plan B1 names; CLAUDE.md: title/intro, Commands, the SMC trap corrected to "SMC
  integers are **little-endian** on this machine (E1); `flt ` little-endian; `#KEY` big-endian", Current state (Metal-PT
  plan in progress), Resume here (this plan's first unchecked task). Historical specs/plans/ADRs keep old names
  (they are records), except a one-line "Renamed to Metal-PT, see ADR 0003" note at the top of the 2026-10-05 spec.
- [ ] **Step 4:** ADR 0003: decision (rename; two apps, one repo; why: no Developer ID; GPL-3.0), consequences.
- [ ] **Step 5:** `rg -n 'fwbench|fwprobe|FWCore|FW Benchmark|fwrun|fwhelper' Sources Tests README.md CLAUDE.md docs/run-bundle-format.md docs/m0-test-plan.md`
  → no hits (ADR 0003 and historical docs excepted). `swift build` warning-free, `swift test` green (154).
- [ ] **Step 6: Commit** `Rename the project to Metal-PT`.
- [ ] **Step 7 (controller, not the implementer; ask the user first):** add remote
  `https://github.com/Wooloomooloo2/Metal-PT.git`; fetch; merge the remote's initial commit with
  `--allow-unrelated-histories` keeping our `LICENSE` (GPL-3.0) and `README.md`; push branches. No force-push.

### Task 2: SMC integers decode little-endian

**Files:** `Sources/MPTCore/SMC/SMCValue.swift`, `Tests/MPTCoreTests/SMCValueTests.swift`.

- [ ] **Step 1: Failing tests** from hardware-baseline E1: `B0AC [si16] 27 FD` → −729; `B0AV [ui16] 5E 2C` → 11358;
  `B0CT [ui16] 90 00` → 144; `#KEY [ui32] 00 00 0D 3A` → 3386 (the one big-endian exception, matched by key);
  `sp78`/`fpe2` keep their current tests unless E1 contradicts them (it doesn't measure them — leave as is, add a
  `// [?]` comment). Existing tests asserting big-endian ui16/ui32/si16 are updated deliberately.
- [ ] **Step 2–4:** RED, implement (`ui16/ui32/ui64/si16` little-endian except key `#KEY`), GREEN; `mptprobe smc read B0AC B0AV B0CT #KEY` shows the E1 values.
- [ ] **Step 5: Commit** `Decode SMC integers little-endian, as measured`.

### Task 3: Recording session in the core

**Files:** create `Sources/MPTCore/Bench/RecordingSession.swift`; slim `Sources/mpt/Session.swift` to CLI glue (or
delete it); `Tests/MPTCoreTests/RecordingSessionTests.swift`.

**Interfaces:**
- Produces: `public final class RecordingSession: @unchecked Sendable` with
  `public struct Options: Sendable { seconds: Double?; warmup: Double; label, settings, notes: String; runsRoot: URL;
  follow: FollowRule; launch: [String]? }`,
  `public init(options: Options, telemetry: TelemetrySource, hud: HUDEventSource, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 })`,
  `public func start() throws`, `public func stop() -> RunResult` (idempotent; finishes, renames, writes summary.html),
  `public var onTick: (@Sendable (SessionStatus) -> Void)?`,
  `public struct SessionStatus: Sendable { elapsed: Double; fps: Double?; followedPID: Int32?; followedApp: String?; stack: Stack?; sample: TelemetrySample }`,
  `public struct RunResult: Sendable { directory: URL; summary: URL? }`.
  `public protocol HUDEventSource: AnyObject { func start(onEvent: @escaping @Sendable (HUDEvent) -> Void) throws; func stop() }`
  (MetalHUDLogStream conforms; tests use a fake).
- The session no longer owns signals or a Lease — the CLI keeps its Lease and calls `stop()`; the app calls `stop()`
  on quit.
- Sleep gap: a tick whose clock is > 5 s after the previous one closes the steady window at the previous tick and adds
  warning "recording spanned a sleep" (test `sleepGapAddsWarning`).

- [ ] **Step 1: Failing tests** with fakes (TelemetrySource, HUDEventSource, clock): `startStopWritesBundle` (3 ticks
  → 3 rows, run.json end set, summary.html exists); `stopFinishesBundle` (stop twice → same result, no throw);
  `startWithoutGameRecordsTelemetry` (no HUD events → rows with empty fps, warning "game process never identified");
  `sleepGapAddsWarning`.
- [ ] **Step 2–4:** RED; move the logic from `Sources/mpt/Session.swift` (keep its behaviour: warm-up validation,
  child launch for `launch`, rename-at-finish, stack detection with 2 s wait); `mpt record`/`run` use it; GREEN.
- [ ] **Step 5:** `swift build`; `.build/debug/mpt run --seconds 6 --warmup 1 --out <tmp> -- <spin test app>` still
  works (frames.csv, summary). Clean up.
- [ ] **Step 6: Commit** `Move the recording session into MPTCore`.

### Task 4: Follow rule for the app

**Files:** `Sources/MPTCore/Bench/FrameCounter.swift` (or new `FollowPolicy.swift`), `RunRecorder.swift`,
tests `Tests/MPTCoreTests/FollowPolicyTests.swift`.

**Interfaces:** `public enum FollowRule { case busiest; case pid(Int32); case nameContains(String); case preferTranslated(exclude: Set<Int32>, pinned: Int32?) }`.
`preferTranslated`: candidates = live HUD PIDs minus `exclude`; if `pinned` is live → pinned; else among candidates
whose `StackDetector` runtime is non-nil and != "native", the busiest; else the busiest candidate. Stack lookups are
injected (`stackOf: (Int32) -> Stack?`) and cached per PID.

- [ ] **Step 1: Failing tests:** `prefersWineOverBusierNative` (native PID 3000 frames, Wine PID 500 → Wine);
  `fallsBackToBusiest` (all native); `excludesSelf`; `pinnedWinsWhileLive`; `pinnedExpiresWhenStale`.
- [ ] **Step 2–4:** RED, implement, GREEN.
- [ ] **Step 5: Commit** `Follow translated games first in the app`.

### Task 5: MPTApp library — telemetry hub

**Files:** `Package.swift` (target `MPTApp` depends on `MPTCore`; test target `MPTAppTests`);
`Sources/MPTApp/TelemetryHub.swift`; `Tests/MPTAppTests/TelemetryHubTests.swift`.

**Interfaces:** `@MainActor public final class TelemetryHub: ObservableObject` with
`@Published public private(set) var latest: HubSnapshot?`, `@Published public private(set) var history: [HubSnapshot]`
(ring, 300), `@Published public private(set) var recording: SessionStatus?`,
`public func acquire(_ need: Need) -> Token` / `Token.release()` where `enum Need { case hud, samples }`,
`public func startRecording(options:) throws`, `public func stopRecording() -> RunResult?`,
`public var pinned: Int32?`, `public var followCandidates: [(pid: Int32, app: String, stack: Stack?)]`.
`HubSnapshot { time, sample: TelemetrySample, fps: Double?, followedPID, followedApp, stack }`.
Rules: log stream runs while any `.hud` token is held (FPS logging on holds one); sampler runs while any `.samples`
token is held or a recording runs; the menu bar acquires `.samples` only while `latest?.followedPID != nil`
(implemented in the hub as a "menu bar wants samples when a game is followed" flag). One sampler, one stream, shared
with the recording session (the session gets the hub's sources).
Dependencies injected (sampler factory, stream factory, clock) for tests.

- [ ] **Step 1: Failing tests:** `nothingRunsWithoutTokens`; `hudTokenStartsStreamOnly`; `samplesTokenStartsSampler`;
  `releasingLastTokenStops`; `menuBarSamplesOnlyWhileGameFollowed`; `recordingKeepsSamplerUntilStopped`;
  `historyCapsAt300`; `startWithoutGameRecordsTelemetry` (via hub).
- [ ] **Step 2–4:** RED, implement, GREEN.
- [ ] **Step 5: Commit** `Add the telemetry hub`.

### Task 6: FPS-logging lease and hotkey model

**Files:** `Sources/MPTApp/FPSLogging.swift`, `Sources/MPTApp/Hotkey.swift`, tests in `Tests/MPTAppTests/`.

**Interfaces:** `public final class FPSLogging { init(launchctl: LaunchctlRunning); func reconcileAtLaunch(enabled: Bool);
func setEnabled(_ on: Bool) throws; func releaseAtQuit(); var isOn: Bool }`; `protocol LaunchctlRunning { func getenv(_:) -> String?; func setenv(_:_:) throws; func unsetenv(_:) throws }`
(real impl runs `/bin/launchctl`; tests fake it). `setEnabled(false)` and `releaseAtQuit()` read back with getenv and
throw/log if still set.
`public struct HotkeyCombo: Codable, Equatable { keyCode: UInt32; modifiers: UInt32 }` with
`static let record = ⌃⇧F6`, `static let overlay = ⌃⇧F7`, `var display: String` ("⌃⇧F6"), `init?(display:)`.

- [ ] **Step 1: Failing tests:** `adoptsWhenEnabled` (vars set, enabled → isOn, no change); `unsetsStaleWhenDisabled`;
  `setEnabledSetsBoth`; `turnOffReadsBack` (fake keeps value → throws); `releaseAtQuitUnsets`;
  `hotkeyDisplayRoundTrip` (⌃⇧F6, ⌥⌘P).
- [ ] **Step 2–4:** RED, implement, GREEN.
- [ ] **Step 5: Commit** `Add the FPS-logging lease and hotkey model`.

### Task 7: App shell — window, sidebar, menu bar, snapshots

**Files:** `Package.swift` (executable target `MetalPT`, depends on `MPTApp`, links SwiftUI/AppKit);
`Sources/MetalPT/MetalPTApp.swift`, `AppModel.swift`, `MenuBarView.swift`, `Sidebar.swift`, `Snapshots.swift`,
`GlobalHotkeys.swift` (Carbon `RegisterEventHotKey` + `InstallEventHandler`), placeholder pages.

- `@main struct MetalPTApp: App` with a `Window("Metal-PT", id: "main")` (`NavigationSplitView`: Live, Runs, Compare,
  Settings) and `MenuBarExtra` (title: "◉ 58 fps · 41 W" while a game is followed, else an SF Symbol;
  dropdown per mockup `app-shape.html` option B / spec §5).
- Activation policy: `.regular` while the main window is open, `.accessory` when closed (Dock icon only with window).
- `AppModel` (`@MainActor ObservableObject`) owns `TelemetryHub`, `FPSLogging`, settings (`@AppStorage`), hotkeys;
  wires ⌃⇧F6 → toggle recording, ⌃⇧F7 → overlay; `applicationWillTerminate` → stop recording, `FPSLogging.releaseAtQuit()`.
- `--render-snapshots DIR`: renders every page and the menu-bar dropdown with fixture data (a fake hub fed from a
  bundled fixture run) to `DIR/<name>-light.png` and `-dark.png` via `ImageRenderer`, then exits. Later tasks add
  their pages to it.
- `MetalPT` refuses to run as root (alert + exit).

- [ ] **Step 1:** Build; `swift run MetalPT --render-snapshots /tmp/x` produces sidebar + menu PNGs; look at them.
- [ ] **Step 2:** Launch `swift run MetalPT` briefly: menu-bar item appears; window opens; quit cleanly
  (`pkill -INT MetalPT` or Quit menu); no leftover `log` child; `launchctl getenv MTL_HUD_ENABLED` empty.
- [ ] **Step 3: Commit** `Add the Metal-PT app shell`.

### Task 8: Live page

**Files:** `Sources/MetalPT/LivePage.swift` (+ snapshot entry).

- Content per spec §5 Live: "Following: <exe> ▾" picker (`hub.followCandidates`, sets `hub.pinned`), stack line,
  Record/Stop button with elapsed and hotkey hint, Swift Charts over `hub.history`: FPS (+ frame time if present),
  power (system W; GPU W labelled "may under-read"), CPU P/E + GPU busy, temps + fans. Empty states: "FPS logging is
  off — turn it on, then start your game" (button), "No game yet — start or relaunch your game after turning on FPS
  logging".
- The page acquires `.samples` while visible.
- [ ] **Step 1:** Snapshot with fixture data (following a game, recording) and both empty states; look at them.
- [ ] **Step 2: Commit** `Add the Live page`.

### Task 9: Recording from hotkey, notifications

**Files:** `Sources/MetalPT/Notifications.swift`, `AppModel.swift`.

- ⌃⇧F6 / menu / Live button → `hub.startRecording(options:)` with `runsRoot = ~/Documents/Metal-PT/runs`,
  `follow: .preferTranslated(exclude: [getpid()], pinned: hub.pinned)`; posts "Recording <app> · <stack>" (or "no
  game detected yet"); stop posts "Run saved — add settings" whose action opens the run in Runs.
- Notification permission requested on first recording; recording works if denied.
- [ ] **Step 1:** Manual check with the spin test app started with HUD env: hotkey starts/stops; run folder under a
  temp `runsRoot` (Settings → data folder override, or env `MPT_DATA_ROOT` honoured for dev); notifications appear
  (or are logged when unavailable in an unbundled `swift run`); quit while recording finishes the run.
- [ ] **Step 2: Commit** `Record from the hotkey with notifications`.

### Task 10: Overlay

**Files:** `Sources/MetalPT/OverlayPanel.swift` (NSPanel: `.nonactivatingPanel`, `ignoresMouseEvents`,
level `.screenSaver`, `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`),
`OverlayView.swift` (compact strip / detailed panel per `overlay.html`).

- Style setting: `auto` (compact; detailed while recording — default), `compact`, `detailed`. Corner setting, default
  top-left; opacity. Acquires `.samples` while shown. ⌃⇧F7 toggles.
- [ ] **Step 1:** Snapshots of compact, detailed, and recording states; look at them.
- [ ] **Step 2:** Manual: overlay over a fullscreen app (the spin test app is windowed — use any fullscreen app),
  click-through works, toggles with ⌃⇧F7.
- [ ] **Step 3: Commit** `Add the in-game overlay`.

### Task 11: Run index and Runs page

**Files:** `Sources/MPTApp/RunIndex.swift` (+ tests), `Sources/MetalPT/RunsPage.swift`, `RunDetailView.swift`
(`WKWebView` showing `summary.html`), `EditNotesSheet.swift`.

**Interfaces:** `public struct RunEntry: Codable, Identifiable { id: String (dir name); game; stackLine; settings; label;
start: Date; duration: Double; medianFPS: Double?; low1: Double? }`;
`public final class RunIndex { init(root: URL); func entries() -> [RunEntry]; func refresh(); func update(dir:, settings:, notes:, label:) throws }`.
Cache at `<root>/.index.json` keyed by dir name + run.json mtime; entries built with `RunBundle.load(_:frames: false)`
except `low1`, which is computed once (with frames) when a run is first indexed and cached. `update` rewrites the
run's user fields through `Privacy.scrub`, regenerates `summary.html`, refreshes the entry.

- [ ] **Step 1: Failing tests:** `indexSkipsFramesAndCaches` (second `entries()` doesn't re-parse: count loads via an
  injected loader); `updateRewritesUserFieldsAndSummary`; `removedRunDropsFromIndex`.
- [ ] **Step 2–4:** RED, implement, GREEN.
- [ ] **Step 5:** Runs page per `runs-submit.html`: filter field (game/stack/settings/label), list rows, detail web
  view, "Edit settings/notes", "Submit…", multi-select → "Compare selected…" (creates a compare project and switches
  to Compare). Snapshots; look at them.
- [ ] **Step 6: Commit** `Add the Runs page`.

### Task 12: Compare page

**Files:** `Sources/MetalPT/ComparePage.swift`.
- Project list (`~/Documents/Metal-PT/projects`), report in a web view (regenerated on open), baseline picker, add
  runs (sheet listing RunIndex entries), remove, rename. Uses `CompareProject` / `CompareReport` as the CLI does.
- [ ] **Step 1:** Snapshot with a fixture project; manual add/remove/baseline round-trip.
- [ ] **Step 2: Commit** `Add the Compare page`.

### Task 13: Export and Submit sheet

**Files:** `Sources/MPTCore/Bench/RunExport.swift` (+ tests), `Sources/MetalPT/SubmitSheet.swift`,
`docs/run-bundle-format.md` (zip + manifest section).

**Interfaces:** `public enum RunExport { static func preview(_ bundle: RunBundle, includeNotes: Bool) -> ExportPreview;
static func write(_ bundle: RunBundle, includeNotes: Bool, to dir: URL) throws -> URL }`;
`ExportPreview { game, stackLine, mac, settings, notes?, sampleCount, frameCount, bytes, privacyLine }`.
Zip built by staging a temp copy (run.json with `user.notes` cleared unless included; samples.csv; frames.csv if
present; manifest.json) and `/usr/bin/ditto -c -k --norsrc`. `bytes` > 25 MB → `RunExport.Error.tooLarge`.

- [ ] **Step 1: Failing tests:** `zipHasManifestAndNoSummary` (unzip with `/usr/bin/ditto -x -k` to temp; manifest
  lists files with correct sizes and sha256); `notesExcludedByDefault`; `notesIncludedWhenOptedIn`; `refusesOver25MB`
  (injected size); `fileNameEndsMptrunZip`.
- [ ] **Step 2–4:** RED, implement, GREEN.
- [ ] **Step 5:** Sheet per `runs-submit.html`: preview fields, notes tick box, "Export file…" (save to
  `~/Documents/Metal-PT/exports/`, reveal in Finder), disabled "Submit (website coming soon)". Snapshot.
- [ ] **Step 6: Commit** `Export runs for submission`.

### Task 14: Settings page and launch at login

**Files:** `Sources/MetalPT/SettingsPage.swift`.
- FPS logging toggle (with explanation), hotkeys (record/overlay; click-to-record a new combo; conflicts reported),
  overlay style/corner/opacity, data folder (default `~/Documents/Metal-PT`, change via panel), launch at login
  (`SMAppService.mainApp` register/unregister, status shown; disabled with an explanation when unbundled).
- [ ] **Step 1:** Snapshot; manual toggle of FPS logging reflects in `launchctl getenv`.
- [ ] **Step 2: Commit** `Add Settings`.

### Task 15: App bundle, release zip, docs

**Files:** `scripts/make-app.sh`, `Resources/MetalPT/Info.plist`, `Resources/MetalPT/AppIcon.icns` (simple generated
icon: a gauge glyph — builder's design, generated with a small Swift/CoreGraphics script kept in `scripts/`),
README (Install, Open Anyway, build from source, using the app), CLAUDE.md (Commands, Current state, Resume here).

- `scripts/make-app.sh metal-pt [--sign IDENTITY]`: `swift build -c release --product MetalPT`; create
  `build/Metal-PT.app/Contents/{MacOS,Resources}`; copy binary as `Metal-PT`, Info.plist (CFBundleIdentifier per
  constraints, CFBundleName/DisplayName "Metal-PT", version from a `VERSION` file, `LSMinimumSystemVersion` 15.0,
  `NSHighResolutionCapable`), icon; sign ad-hoc (`codesign -s - --force --deep`) unless `--sign`; zip to
  `build/Metal-PT-<version>.zip` with `ditto -c -k --keepParent`. A `helper` argument is reserved (prints "not yet").
- [ ] **Step 1:** Run the script; `codesign -dv build/Metal-PT.app` ok; open the app from the bundle: menu bar,
  window, notifications and launch-at-login work bundled; quit.
- [ ] **Step 2:** Docs updated; `swift test` green.
- [ ] **Step 3: Commit** `Build Metal-PT.app and document installing it`.
