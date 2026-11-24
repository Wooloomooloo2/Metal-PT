# M1B Benchmarking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An unprivileged `fwbench` CLI that records a game run (FPS, frame times, power, utilisation, temperatures,
fans, memory, battery, translation stack) into an uploadable `.fwrun` bundle, and writes HTML summaries and compare
reports.

**Architecture:** Pure parsing/analysis/report types in `FWCore/Bench/` with Swift Testing tests; thin OS readers
(`log stream`, `lsof`, IOReport, SMC, HID, battery) behind small protocols; `fwbench` is a new executable target on
FWCore. Recording runs in the user's session (ADR 0002).

**Tech Stack:** Swift 6, SwiftPM, Swift Testing, Foundation `Process`, existing `IOReportSampler`, `SMCConnection`,
`HIDTemperatureReader`, `SmartBatteryReader`.

**Spec:** `docs/superpowers/specs/2026-11-24-benchmarking-design.md` (read with ADR 0002 and `docs/hardware-baseline.md`
E6/E8).

## Global Constraints

- macOS 15+, Apple Silicon; `swift build` / `swift test` must pass; no new package dependencies.
- `fwbench` never runs as root: if `geteuid() == 0` exit 64 with "fwbench must not run as root".
- No SMC writes anywhere in this plan. Reads only.
- Unified log reader is exactly `/usr/bin/log` (zsh shadows `log`), args
  `stream --style ndjson --level debug --predicate 'eventMessage BEGINSWITH "metal-HUD"'`.
- HUD variables: `MTL_HUD_ENABLED=1`, `MTL_HUD_LOG_ENABLED=1`. Anything that sets them with `launchctl setenv` holds a
  `Lease` that unsets them on release and on signals.
- Bundle: directory `~/Documents/FW Benchmark/runs/<yyyyMMdd-HHmmss>-<game-slug>.fwrun/` with `run.json`
  (`"schema": 1`), `samples.csv`, optional `frames.csv`, generated `summary.html`.
- CSV: header row, columns read by header name, numbers formatted with `.` decimal point regardless of locale
  (`String(format:)` with `Locale(identifier: "en_US_POSIX")` or manual), empty cell = unknown.
- No user name, home path, hostname or serial number in any bundle file.
- Facts used below come from `docs/hardware-baseline.md`; don't re-derive them.

## Review Focus

1. The followed game restarts or its cumulative frame count goes down → no negative or huge FPS; the counter restarts.
   (Task 2 test `counterResetStartsOver`.)
2. No Metal HUD lines at all (HUD off, or a non-Metal app) → the run still records telemetry, FPS cells are empty, the
   CLI prints `no Metal HUD lines yet — run 'fwbench hud on' and relaunch the game`, the summary says "no FPS source".
   (Task 7 test `recorderWithoutFPSStillWritesSamples`, Task 8 test `summaryWithoutFPS`.)
3. Several Metal processes (Steam client, launcher, the game) → follow the PID with the most frames so far, not the
   first seen. (Task 2 test `followsBusiestProcess`.)
4. Ctrl-C during `record`/`run` → `run.json` gets `end` and the steady window, CSVs are complete lines, the HUD lease is
   released. (Task 7 test `finishIsIdempotentAndClosesFiles`.)
5. Partial or old bundles (no `frames.csv`, missing columns, unknown extra columns, `schema` > 1) → summary and compare
   still load; lows show "—"; schema > 1 gives a warning, not a crash. (Task 6 test `loadsBundleWithMissingPieces`.)

---

### Task 1: Metal HUD line parser

**Files:**
- Create: `Sources/FWCore/Bench/MetalHUDLine.swift`
- Test: `Tests/FWCoreTests/MetalHUDLineTests.swift`

**Interfaces:**
- Produces: `public struct MetalHUDLine: Equatable, Sendable { public let frames: Int; public let a: Double;
  public let b: Double; public let frameTimes: [FrameTime] }`, `public struct FrameTime: Equatable, Sendable
  { public let intervalMs: Double; public let presentDelayMs: Double }`,
  `public static func parse(_ message: String) -> MetalHUDLine?`

- [ ] **Step 1: Write failing tests** — `parsesPublicLogLine`: `"metal-HUD: 63,5.77,446.17<private>"` → frames 63, a 5.77,
  b 446.17, frameTimes empty. `parsesFullStderrLine`: the text after the timestamp prefix
  `"2026-11-24 12:24:13.635 spin[34283:27302095] metal-HUD: 75,10.61,468.19,51.11,0.01,8.34,0.01"` → frames 75,
  frameTimes `[(51.11,0.01),(8.34,0.01)]`. `rejectsOtherLines`: `"[libMTLHud] Metric x already exist"` → nil;
  `"metal-HUD: abc"` → nil. `oddTrailingValueIgnored`: a list with an unpaired last number drops it.
- [ ] **Step 2: Run** `swift test --filter MetalHUDLineTests` — expect FAIL (type missing).
- [ ] **Step 3: Implement** — find `"metal-HUD: "`, take the rest, strip a trailing `<private>`, split on `,`; first three
  fields required; remaining numbers paired.
- [ ] **Step 4: Run** `swift test --filter MetalHUDLineTests` — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "Parse Metal HUD log lines"`

### Task 2: Frame counter (per-second FPS per process)

**Files:**
- Create: `Sources/FWCore/Bench/FrameCounter.swift`
- Test: `Tests/FWCoreTests/FrameCounterTests.swift`

**Interfaces:**
- Consumes: `MetalHUDLine`.
- Produces: `public struct HUDEvent: Sendable { public let pid: Int32; public let imagePath: String;
  public let time: Double /* seconds, monotonic or epoch */; public let line: MetalHUDLine }`;
  `public struct FrameCounter { public init(); public mutating func add(_ event: HUDEvent);
  public func fps(pid: Int32, at time: Double) -> Double?; public var followedPID: Int32? { get };
  public func totalFrames(pid: Int32) -> Int }`.

- [ ] **Step 1: Write failing tests** — `fpsFromCumulativeCounts`: events (pid 7, t 0.0, frames 63), (t 1.016, 124) →
  `fps(pid:7, at:1.5)` ≈ 60.04 (61/1.016). `staleIsNil`: last event older than 2.5 s → nil.
  `counterResetStartsOver`: frames 500 then 30 → no negative FPS; next event (t+1, 90) gives 60.
  `followsBusiestProcess`: pid 1 gains 100 frames, pid 2 gains 5 000 → `followedPID == 2`; then pid 1 can't take over
  unless its total exceeds pid 2's.
- [ ] **Step 2: Run** `swift test --filter FrameCounterTests` — FAIL.
- [ ] **Step 3: Implement** — per PID keep last (time, frames), last FPS, total frames added (sum of positive deltas).
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "Count frames per process from Metal HUD lines"`

### Task 3: Unified log stream reader

**Files:**
- Create: `Sources/FWCore/Bench/MetalHUDLogStream.swift`
- Test: `Tests/FWCoreTests/MetalHUDLogStreamTests.swift`

**Interfaces:**
- Consumes: `MetalHUDLine.parse`, `HUDEvent`.
- Produces: `public static func decode(ndjsonLine: String) -> HUDEvent?` (pure; reads `processID`, `processImagePath`,
  `eventMessage`, `timestamp` formatted `yyyy-MM-dd HH:mm:ss.SSSSSSZ`, POSIX locale; time = epoch seconds);
  `public final class MetalHUDLogStream { public init(onEvent: @escaping @Sendable (HUDEvent) -> Void);
  public func start() throws; public func stop() }` — runs `/usr/bin/log` (Global Constraints), reads stdout line by
  line on a background queue, terminates the child in `stop()` and in `deinit`.

- [ ] **Step 1: Write failing tests** — `decodesLogLine` using a fixture line with `"processID":34546,
  "processImagePath":"/x/spin","timestamp":"2026-11-24 12:25:00.502304+0000","eventMessage":"metal-HUD: 63,5.77,446.17<private>"`
  → pid 34546, frames 63, time = that instant. `skipsHeaderAndJunk`: `"Filtering the log data using …"` → nil.
- [ ] **Step 2: Run** `swift test --filter MetalHUDLogStreamTests` — FAIL.
- [ ] **Step 3: Implement** `decode` and the `Process` wrapper.
- [ ] **Step 4: Run** — PASS. (The live stream is checked on hardware in Task 7 Step 5.)
- [ ] **Step 5: Commit** `git commit -m "Stream Metal HUD lines from the unified log"`

### Task 4: Translation stack detector

**Files:**
- Create: `Sources/FWCore/Bench/StackDetector.swift`, `Sources/FWCore/Bench/ProcessNames.swift`
- Test: `Tests/FWCoreTests/StackDetectorTests.swift`

**Interfaces:**
- Produces: `public struct Stack: Codable, Equatable, Sendable { public var runtime: String?  /* "Protium", "CrossOver",
  "Whisky", "Kegworks", "GPTK", "native" */; public var runtimeVersion: String?; public var wineArch: String?
  /* "arm64ec", "x86_64" */; public var translator: String? /* "FEX", "Rosetta", nil */; public var graphics: [String]
  /* e.g. ["DXMT", "vkd3d", "KosmicKrisp"] */ }`;
  `public static func fingerprint(mappedPaths: [String]) -> Stack` (pure);
  `public static func detect(pid: Int32) -> Stack` (runs `/usr/sbin/lsof -Fn -p <pid>`, collects `n` lines, calls
  `fingerprint`, then reads `runtimeVersion` from `<App>.app/Contents/Info.plist` `CFBundleShortVersionString`);
  `ProcessNames.displayName(pid:) -> String?` (argv[0] via `sysctl KERN_PROCARGS2`) and pure
  `ProcessNames.exeName(fromArgv0: String) -> String` (last component splitting on both `/` and `\`).
- Fingerprint table (substring of a mapped path → field), start with what was measured on this machine:
  `/Protium.app/` → runtime Protium; `/CrossOver.app/` or `CrossOver Preview` → CrossOver; `/Whisky.app/` → Whisky;
  `libarm64ecfex` → translator FEX, wineArch arm64ec; `/usr/libexec/rosetta` or `oahd` runtime → Rosetta;
  `winemetal.so` or `/C/dxmt/` → DXMT; `D3DMetal.framework` or `libd3dshared` → D3DMetal; `dxvk` in a dll path → DXVK;
  `libMoltenVK` → MoltenVK; `libvulkan_kosmickrisp` → KosmicKrisp; `vkd3d` or `d3d12core.dll` → vkd3d. No match → runtime
  "native". `graphics` keeps table order, no duplicates.

- [ ] **Step 1: Write failing tests** — `protiumHZDFingerprint`: paths from `docs/hardware-baseline.md`-era capture
  (`/Applications/Protium.app/Contents/SharedSupport/runtime/lib/wine/aarch64-unix/winemetal.so`, `…/libarm64ecfex.so`,
  `…/external/libvulkan_kosmickrisp.dylib`, `…/aarch64-windows/d3d12core.dll`) → runtime Protium, translator FEX,
  wineArch arm64ec, graphics ["DXMT", "KosmicKrisp", "vkd3d"] (order per table). `crossOverD3DMetal`:
  `/Applications/CrossOver.app/…/D3DMetal.framework/D3DMetal` + `/usr/libexec/rosetta/runtime` → CrossOver, Rosetta,
  ["D3DMetal"]. `nativeWhenNothingMatches`. `exeNameFromWindowsPath`:
  `"Z:\\Volumes\\OWC Express 1M2\\Protium Library\\steamapps\\common\\HZD\\HorizonZeroDawnRemastered.exe"` →
  `"HorizonZeroDawnRemastered.exe"`; `"/usr/bin/yes"` → `"yes"`.
- [ ] **Step 2: Run** `swift test --filter StackDetectorTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS. Hardware: with a Wine game running, `swift run fwbench stack <pid>` (Task 7 adds the
  command) prints the stack.
- [ ] **Step 5: Commit** `git commit -m "Detect the translation stack of a game process"`

### Task 5: Telemetry sample and sampler

**Files:**
- Create: `Sources/FWCore/Bench/TelemetrySample.swift`, `Sources/FWCore/Bench/TelemetrySampler.swift`,
  `Sources/FWCore/Bench/Utilisation.swift`
- Test: `Tests/FWCoreTests/UtilisationTests.swift`

**Interfaces:**
- Consumes: `IOReportSampler`, `IOReportChannel`, `PowerMath`, `SMCConnection`, `HIDTemperatureReader`,
  `SmartBatteryReader`.
- Produces: `public struct TelemetrySample: Sendable { public var gpuW: Double?; public var cpuPUtilPct: Double?;
  public var cpuEUtilPct: Double?; public var cpuCoreMaxPct: Double?; public var gpuBusyPct: Double?;
  public var smcPower: [String: Double] /* key → W */; public var tempMaxC: Double?; public var tempBatteryC: Double?;
  public var fanRPM: [Double]; public var memUsedGB: Double?; public var batteryPct: Int?; public var batteryW: Double?;
  public var onAC: Bool?; public var thermalState: String }`;
  `public final class TelemetrySampler { public init() throws; public func sample() -> TelemetrySample }`
  (first call primes IOReport and returns power/util nil);
  pure `Utilisation.busyShare(_ states: [IOReportState], idleNames: Set<String>) -> Double?` (1 − idle share;
  nil when total is 0).
- Readings (from hardware-baseline E6): GPU W = `Energy Model / GPU Energy [nJ]` over the interval; P-cores
  `CPU Core Performance States / PCPU*`, E-cores `ECPU*`, idle names `["IDLE", "DOWN"]`; cluster util = mean of cores;
  `cpuCoreMaxPct` = busiest core; GPU busy = `GPUPH` with idle names `["OFF"]`. SMC power: keys `PSTR PDTR PHPC PHPS
  PSVR PZC0 PZC1 PMVC PPMC PPSC` read as `flt` (meanings `[?]` — recorded raw under `smc_<KEY>_w`). Fans: `FNum` then
  `F<i>Ac`. Temperatures: `tempMaxC` = max of all HID readings; `tempBatteryC` = SMC `TB0T`. Memory:
  `host_statistics64` (active + wired + compressor) × page size. Battery W = mV × mA / 1e6 from `BatterySnapshot`.
  `thermalState` = `ProcessInfo.thermalState` as `nominal|fair|serious|critical`. One `SMCConnection` owned by the sampler.

- [ ] **Step 1: Write failing tests** — `busyShareIgnoresIdleAndDown`: IDLE 300, DOWN 100, V6P0 600 → 0.6.
  `busyShareZeroTotalIsNil`. `gpuBusyFromOff`: OFF 900, P1 100 → 0.1 with idleNames ["OFF"].
- [ ] **Step 2: Run** `swift test --filter UtilisationTests` — FAIL.
- [ ] **Step 3: Implement** `Utilisation`, `TelemetrySample`, `TelemetrySampler`.
- [ ] **Step 4: Run** — PASS. Hardware check in Task 7.
- [ ] **Step 5: Commit** `git commit -m "Sample telemetry for benchmark runs"`

### Task 6: Run bundle model and files

**Files:**
- Create: `Sources/FWCore/Bench/RunInfo.swift`, `Sources/FWCore/Bench/RunBundle.swift`, `Sources/FWCore/Bench/CSV.swift`,
  `Sources/FWCore/Bench/Privacy.swift`
- Test: `Tests/FWCoreTests/RunBundleTests.swift`

**Interfaces:**
- Consumes: `Stack`, `TelemetrySample`, `FrameTime`.
- Produces:
  - `public struct RunInfo: Codable, Sendable` with `schema: Int` (1), `appVersion`, `machine: Machine {modelID, chip,
    gpuCores?, memoryGB, osVersion, osBuild}`, `game: Game {exe, title?, storeAppID?}`, `stack: Stack`,
    `settings: Settings {powerMode?, onACAtStart?, displayWidth?, displayHeight?, refreshHz?}`,
    `user: UserFields {label, gameSettings, notes}` (all `String`, default ""), `start: Date`, `end: Date?`,
    `steadyStartS: Double?`, `steadyEndS: Double?`, `fpsSource: String` (`"log"`, `"stderr"`, `"none"`), `warnings: [String]`.
  - `public enum SampleColumns { public static let all: [String] }` = `t, elapsed_s, fps, fps_pid, fps_app, ft_p99_ms,
    ft_max_ms, gpu_w, cpu_p_util_pct, cpu_e_util_pct, cpu_core_max_pct, gpu_busy_pct, smc_PSTR_w, smc_PDTR_w,
    smc_PHPC_w, smc_PHPS_w, smc_PSVR_w, smc_PZC0_w, smc_PZC1_w, smc_PMVC_w, smc_PPMC_w, smc_PPSC_w, temp_max_c,
    temp_battery_c, fan0_rpm, fan1_rpm, mem_used_gb, battery_pct, battery_w, on_ac, thermal_state` (append-only).
  - `public final class RunBundleWriter { public init(directory: URL, info: RunInfo) throws;
    public func append(sample row: [String: String]) throws; public func append(frames: [FrameTime]) throws;
    public func finish(updating: (inout RunInfo) -> Void) throws }` — buffered, `finish` idempotent.
  - `public struct RunBundle { public let url: URL; public let info: RunInfo; public let rows: [[String: String]];
    public let frames: [FrameTime]?; public let warnings: [String]; public static func load(_ url: URL) throws -> RunBundle }`.
  - `public enum CSV { static func line(_ fields: [String]) -> String; static func parse(_ text: String) -> [[String: String]];
    static func number(_ value: Double?, digits: Int) -> String }`.
  - `public enum Privacy { public static func scrub(_ text: String) -> String }` — replaces `/Users/<name>` with `~`,
    removes the host name (`ProcessInfo.hostName`, `Host.current().localizedName`); applied to every string field of
    `RunInfo` before writing.
  - `public static func directoryName(start: Date, game: String) -> String` → `yyyyMMdd-HHmmss-<slug>.fwrun`, slug =
    lowercase alphanumerics and `-`, max 40 chars.

- [ ] **Step 1: Write failing tests** — `roundTripsBundle`: write info + 3 rows + 5 frames to a temp dir, `finish` with
  an `end`, `load` returns the same rows, frames, end. `numbersUsePOSIXDecimal`: `CSV.number(1.5, digits: 2)` == "1.50"
  even with `Locale(identifier:"de_DE")` set as the formatter context (call it through the API under test).
  `loadsBundleWithMissingPieces`: bundle without `frames.csv` and with an extra unknown column and `"schema": 2` → loads,
  frames nil, warnings contains "newer bundle format (schema 2)". `scrubsHomePaths`:
  `"/Users/alice/Games/x.exe"` → `"~/Games/x.exe"`. `directoryNameSlug`: game `"Horizon Zero Dawn™ Remastered.exe"`
  → `"20261124-122400-horizon-zero-dawn-remastered-exe.fwrun"`. `finishIsIdempotentAndClosesFiles`: calling `finish`
  twice writes `end` once and does not throw.
- [ ] **Step 2: Run** `swift test --filter RunBundleTests` — FAIL.
- [ ] **Step 3: Implement.** JSON with `.iso8601` dates, `.prettyPrinted, .sortedKeys`.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "Write and load .fwrun run bundles"`

### Task 7: Recorder and the `fwbench` CLI (record, run, hud, stack, ls)

**Files:**
- Create: `Sources/FWCore/Bench/RunRecorder.swift`, `Sources/fwbench/main.swift`, `Sources/fwbench/RecordCommands.swift`,
  `Sources/fwbench/HUDCommands.swift`
- Modify: `Package.swift` (product + `.executableTarget(name: "fwbench", dependencies: ["FWCore"])`)
- Test: `Tests/FWCoreTests/RunRecorderTests.swift`

**Interfaces:**
- Consumes: Tasks 1–6, `Lease`.
- Produces: `public protocol TelemetrySource { func sample() -> TelemetrySample }` (conformed by `TelemetrySampler`);
  `public final class RunRecorder { public init(writer: RunBundleWriter, telemetry: TelemetrySource, startTime: Double,
  follow: FollowRule); public func hud(_ event: HUDEvent); public func frames(_ times: [FrameTime], pid: Int32?);
  public func tick(at time: Double) throws /* one CSV row */; public func finish() throws }`;
  `public enum FollowRule { case busiest; case pid(Int32); case nameContains(String) }`.
  `tick` fills `fps`/`fps_pid`/`fps_app` from `FrameCounter` for the followed PID; `ft_p99_ms`/`ft_max_ms` from the
  frame times received since the last tick; telemetry columns from `TelemetrySample`.
- CLI (`fwbench`):
  - `record [--pid P | --name S] [--seconds N] [--warmup S] [--label TEXT]` — default `--seconds` none (until Ctrl-C),
    warm-up 0; prints one status line per 5 s (`12 s  58.9 fps  HorizonZeroDawnRemastered.exe  GPU 21.4 W`), and the
    hint from Review Focus 2 if no HUD line arrived after 5 s. Detects the stack when the followed PID is first known
    and writes it into `run.json`; `steadyStartS` = warm-up.
  - `run [--seconds N] [--warmup S] [--label TEXT] -- CMD ARGS…` — launches CMD with the HUD variables added to its
    environment, reads its stderr line by line, sends parsed frame times to `frames(_:pid:)` with `fpsSource "stderr"`,
    still runs the log stream for FPS; forwards non-HUD stderr lines to our stderr. Stops when N elapses, the child
    exits, or Ctrl-C (child left running on Ctrl-C).
  - `hud on|off` — `launchctl setenv`/`unsetenv` both variables. `hud on` holds the lease and waits until Ctrl-C
    (prints "HUD logging on for apps launched from now; Ctrl-C to turn off"), so it cannot be left on by accident.
  - `stack PID` — prints `StackDetector.detect` as JSON. `ls` — lists bundles (name, game, stack, duration, median FPS
    once Task 8 exists).
  - Root check from Global Constraints. Signals: one `Lease` whose restore calls `recorder.finish()` and (for `hud on`)
    unsets the variables.

- [ ] **Step 1: Write failing tests** with a fake `TelemetrySource` and a temp-dir writer:
  `recorderWritesFPSFromHUD` — HUD events pid 9 frames 0 at t 0, 60 at t 1, tick at t 1.2 → row fps "60.0", fps_pid "9".
  `recorderWithoutFPSStillWritesSamples` — no HUD events, 3 ticks → 3 rows, fps empty, gpu_w filled from the fake.
  `frameTimesGiveP99AndMax` — 100 frames of 16.67 ms and one of 50 ms before a tick → ft_max_ms "50.00",
  ft_p99_ms "16.67" (p99 = value at index ⌈0.99·n⌉−1 of sorted list).
- [ ] **Step 2: Run** `swift test --filter RunRecorderTests` — FAIL.
- [ ] **Step 3: Implement** `RunRecorder`, then the CLI and Package.swift entry.
- [ ] **Step 4: Run** `swift test` — PASS; `swift build` clean.
- [ ] **Step 5: Hardware check** — (a) `swift run fwbench record --seconds 15` with no game: 15 rows, sensible GPU W
  and fan RPM, hint printed. (b) Start a Metal test app with the HUD env, `fwbench record --seconds 15`: fps ≈ 60.
  (c) `fwbench run --seconds 15 -- <test app>`: `frames.csv` ≈ 900 rows. (d) While recording, `ps -o %cpu -p <fwbench>`
  and the `log` child — record both in `docs/hardware-baseline.md` E8 (target < 1 % combined).
- [ ] **Step 6: Commit** `git commit -m "Add fwbench: record runs into .fwrun bundles"`

### Task 8: Run summary (pure)

**Files:**
- Create: `Sources/FWCore/Bench/RunSummary.swift`
- Test: `Tests/FWCoreTests/RunSummaryTests.swift`

**Interfaces:**
- Consumes: `RunBundle`.
- Produces: `public struct ColumnStats: Sendable { min, mean, median, p5, max: Double; count: Int }`;
  `public struct RunSummary: Sendable { public let steadySeconds: [Int] /* row indices */; public let stats:
  [String: ColumnStats]; public let medianFPS: Double?; public let p5FPS: Double?; public let low1: Double?;
  public let low01: Double?; public let fpsPerWatt: Double?; public let powerColumn: String?; public let notes: [String];
  public init(_ bundle: RunBundle) }`.
- Steady seconds: if `steadyStartS`/`steadyEndS` set, rows inside them; else rows with fps present for the followed
  app, minus the first 10 s of those, minus rows with fps > 2 × median fps. With no fps at all: every row, and
  `notes` contains "no FPS source". Lows: FPS of the 99th / 99.9th percentile frame interval over frames whose time
  falls in the steady window (1000 / interval). `fpsPerWatt` = medianFPS / mean of `powerColumn`, where
  `powerColumn` = `smc_PSTR_w` if present else `gpu_w` (call: system power is what the user pays; `[?]` until E6).
  Notes also: steady time < 60 s ("short run"), any `on_ac` false ("on battery"), more than one `thermal_state`
  value above nominal ("thermal pressure: serious for N s").

- [ ] **Step 1: Write failing tests** — `trimsWarmupAndMenus`: 80 rows, fps 60 except rows 0–4 empty and rows 40–41
  at 300 → steady excludes rows 5–14 (first 10 s) and 40–41; medianFPS 60. `usesExplicitWindow`. `lowsFromFrames`:
  1000 frames of 16.67 ms + 20 of 50 ms → low1 == 20.0 (1000/50), low01 == 20.0 (percentile index
  ⌈p·n⌉−1 of the ascending intervals, as in Task 7). `summaryWithoutFPS`: notes contains
  "no FPS source", medianFPS nil, stats still has `gpu_w`. `fpsPerWattUsesSystemPower`.
- [ ] **Step 2: Run** `swift test --filter RunSummaryTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "Summarise a run's steady seconds"`

### Task 9: Summary HTML report + `fwbench summary`

**Files:**
- Create: `Sources/FWCore/Bench/HTML.swift` (escaping, shared CSS with light/dark tokens, static SVG line and bar chart
  helpers), `Sources/FWCore/Bench/SummaryReport.swift`
- Modify: `Sources/fwbench/main.swift` (`summary RUN [--open]`)
- Test: `Tests/FWCoreTests/SummaryReportTests.swift`

**Interfaces:**
- Consumes: `RunBundle`, `RunSummary`.
- Produces: `public enum SummaryReport { public static func html(_ bundle: RunBundle, _ summary: RunSummary) -> String }`;
  `HTML.escape(_:)`, `HTML.lineChart(series: [(name: String, values: [Double?])], steady: [Int], unit: String) -> String`,
  `HTML.bars(_ items: [(label: String, value: Double?, note: String)], unit: String) -> String`.
- Content (follow fw-helper-windows `SummaryReport` / `docs/example_summary.html`, but **system fonts only, no
  network, no script**): header (game, label, duration, stack line "Protium · FEX · DXMT", macOS, machine, power mode,
  AC/battery), notes as warnings; tiles: median FPS, 5 % second, 1 % low, 0.1 % low, mean power + FPS/W; charts with
  non-steady seconds shaded: FPS (+ ft_p99), power (GPU W and system W), CPU P/E util + GPU busy, temperatures + fans;
  a table of `ColumnStats` for every numeric column; user fields (game settings, notes). `<meta name="fwhelper-run">`
  holds the bundle directory name. Written to `<bundle>/summary.html`; `--open` runs `/usr/bin/open`.

- [ ] **Step 1: Write failing tests** — `escapesUserText`: label `<script>` appears as `&lt;script&gt;`.
  `containsTilesAndStack`: fixture → contains "60.0", "Protium · FEX · DXMT". `noNetworkReferences`: output contains
  neither `http://` nor `https://` nor `<script`. `missingLowsShowDash`.
- [ ] **Step 2: Run** `swift test --filter SummaryReportTests` — FAIL.
- [ ] **Step 3: Implement**; `record`/`run` write the summary on finish and print its path.
- [ ] **Step 4: Run** — PASS; open a real summary from Task 7's runs and look at it in light and dark mode.
- [ ] **Step 5: Commit** `git commit -m "Write an HTML summary for each run"`

### Task 10: Compare projects + report + `fwbench compare`

**Files:**
- Create: `Sources/FWCore/Bench/CompareProject.swift`, `Sources/FWCore/Bench/CompareReport.swift`
- Modify: `Sources/fwbench/main.swift`
- Test: `Tests/FWCoreTests/CompareTests.swift`

**Interfaces:**
- Consumes: `RunBundle`, `RunSummary`, `HTML`.
- Produces: `public struct CompareProject: Codable { public var name: String; public var baseline: Int;
  public var runs: [Entry]; public struct Entry: Codable { public var bundle: String /* dir name if under runs/, else
  absolute path */; public var name: String } ; public static func load(_ url: URL) throws -> CompareProject;
  public func save(to url: URL) throws }` at `~/Documents/FW Benchmark/projects/<name>.json`;
  `public enum CompareReport { public static func differences(_ infos: [RunInfo]) -> [(field: String, values: [String])];
  public static func warnings(_ runs: [(RunInfo, RunSummary)]) -> [String];
  public static func html(project: CompareProject, runs: [(RunBundle, RunSummary)]) -> String }`.
- `differences` fields (only those whose values differ): game, runtime, runtime version, translator, graphics,
  game settings, label, power mode, AC/battery, macOS build, machine, FPS source.
- `warnings`: different games; AC vs battery; steady lengths more than 2× apart; any steady time < 60 s; different
  machines; different macOS builds; mixed FPS sources ("1 % lows only for runs launched with fwbench run").
- Report: tiles (fastest run and gain vs baseline in %, most efficient FPS/W); a line per run vs baseline
  ("CrossOver D3DMetal: 54.1 fps median (−9.8 %), 1 % low 38.0, 61.2 W"); bars: median FPS with 1 % low note, mean
  power, FPS/W; What differs table with cells unlike the baseline highlighted, and a "Same in every run:" line;
  warnings. Written as `<name>.html` next to the project JSON.
- CLI: `fwbench compare NAME add RUN… [--as TEXT]`, `compare NAME baseline N`, `compare NAME remove N`,
  `compare NAME report [--open]`, `compare ls`.

- [ ] **Step 1: Write failing tests** — `differencesOnlyListsChanges`: two infos differing in runtime (Protium vs
  CrossOver) and graphics (DXMT vs D3DMetal), same game → exactly those two fields. `warnsOnACvsBattery`.
  `warnsOnDifferentGames`. `gainAgainstBaseline`: baseline 50 fps, other 55 → "+10.0 %". `projectRoundTrip`.
- [ ] **Step 2: Run** `swift test --filter CompareTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; build a project from two real runs and check the report.
- [ ] **Step 5: Commit** `git commit -m "Compare runs against a baseline"`

### Task 11: Real-game verification and docs

**Files:**
- Modify: `docs/hardware-baseline.md` (E8 remainder), `docs/m0-test-plan.md` (add "B1 — fwbench in a real game"),
  `CLAUDE.md` (Commands, Current state, Resume here), `README.md` (fwbench usage), create `docs/run-bundle-format.md`
  (schema 1 field list and column list, for the future website).

- [ ] **Step 1:** User runs, with a Wine game in Protium and in CrossOver: `fwbench hud on` (separate terminal), relaunch
  the launcher, `fwbench record --seconds 120 --warmup 15 --label "<settings>"`. Record in E8 whether HUD lines arrive
  from each runtime, the stack detected, and fwbench + `log` CPU %.
- [ ] **Step 2:** Try `fwbench run --seconds 120 -- <runtime's wine command for the game>`; record whether frame times
  arrive via stderr.
- [ ] **Step 3:** `fwbench compare hzd add <run1> <run2>` then `report --open`; check What differs shows runtime and
  graphics.
- [ ] **Step 4:** Write the docs above; `swift test` passes.
- [ ] **Step 5: Commit** `git commit -m "Record fwbench real-game results and document the run bundle"`
