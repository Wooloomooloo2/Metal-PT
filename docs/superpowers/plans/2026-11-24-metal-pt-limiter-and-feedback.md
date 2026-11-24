# Metal-PT limiter analysis and recording feedback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tell the user what held a run back (GPU, CPU, memory, thermal, frame cap), record the two missing signals
(GPU clock, memory pressure), and make recording state and FPS-logging problems visible.

**Architecture:** New sampler readers and columns in MPTCore; a pure `LimiterAnalysis` beside `RunSummary`; report,
Compare and Live consume it. App-side feedback (menu label, sound, debounce), a notifications status in Settings, and
a frontmost-app environment check in MPTApp/MetalPT.

**Tech Stack:** Swift 6, IOKit (IORegistry `pmgr`), sysctl, `host_statistics64`, `KERN_PROCARGS2`, SwiftUI/AppKit,
`NSSound`, `UNUserNotificationCenter`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-24-metal-pt-limiter-and-feedback-design.md` (read with
`docs/hardware-baseline.md` — GPU table and memory-pressure lines dated 2026-11-24 — and `docs/run-bundle-format.md`).

## Global Constraints
- macOS 15+, Apple Silicon; warning-free debug and release builds; `swift test` green after every task.
- No root, no SMC writes. Background-cost rule: nothing new runs when nothing is shown or recorded.
- CSV columns append-only; `schema` stays 1; new `run.json` fields optional (old runs load unchanged).
- Thresholds exactly as the spec's §E list; kept in one table in code.
- App names in warnings are never written to run bundles.
- Commits with explicit pathspecs only; never commit `docs/data/aldente-ids.txt`; never `git reset`.

## Review Focus
1. A Mac whose `pmgr` has no table matching the GPUPH state count → `gpu_mhz` empty, analysis says "no GPU clock
   recorded", nothing crashes (Task 1 test `noMatchingTableLeavesClockEmpty`).
2. Old runs without the new columns → analysis still runs on what exists and names the missing inputs (Task 2 test
   `oldRunWithoutNewColumns`).
3. A frame-capped game at 60 fps with GPU at 70 % must not be called GPU- or CPU-bound (Task 2 test
   `frameCapDetected`).
4. Quick double press of the record hotkey (< 1 s) → no stop/start churn (Task 4 test `debounceIgnoresSecondPress`).
5. The not-reporting warning must not fire for Metal-PT itself, for apps that do have the HUD variables, or when FPS
   logging is off (Task 5 tests).

---

### Task 1: GPU clock and memory-pressure columns
**Files:** `Sources/MPTCore/Bench/GPUClock.swift` (table read + pure residency→MHz), `MemoryPressure.swift`,
`TelemetrySample.swift`, `TelemetrySampler.swift`, `CSV.swift` (SampleColumns append `gpu_mhz`, `mem_pressure`,
`swap_used_gb`, `compressed_gb`, `pageouts_per_s`; digits: mhz 0, gb 2, per_s 0), `RunInfo.swift`
(`machine.gpuMaxMHz: Int?`), `MachineInfo.swift`, `docs/run-bundle-format.md`; tests.
**Interfaces:** `public enum GPUClock { static func table(fromPMGR entries: [[UInt8]]) -> [Double]?` (pure: pick the
first table whose entry count == stateCount, return MHz per state with OFF = 0); `static func meanMHz(states:
[IOReportState], table: [Double]) -> Double?` (residency-weighted over non-OFF states; nil if no active residency);
`static func loadTable(stateCount: Int) -> [Double]?` (IORegistry). `public struct MemoryPressureReading { level:
String; swapUsedGB, compressedGB: Double?; pageouts: UInt64? }` + `read()`; per-second rate computed in the sampler.
- [ ] Tests first (RED): table selection with the measured M4 Max bytes (entry 0 = 0, 15 = 1578 MHz); meanMHz on
  fixtures (all OFF → nil; 50 % P1 + 50 % P15 → 958); `noMatchingTableLeavesClockEmpty`; pressure level mapping 1/2/4
  → normal/warn/critical, unknown → nil; pageouts rate from two readings; CSV round-trip of the new columns.
- [ ] Implement; sampler fills the fields; `mpt run --seconds 6` on the spin test app writes the columns (check by
  eye); hardware: during a 20 s GPU load (scratchpad hud/gpuload) gpu_mhz is non-empty and plausible (≤ 1578).
- [ ] Commit `Record GPU clock and memory pressure`.

### Task 2: LimiterAnalysis (pure)
**Files:** `Sources/MPTCore/Bench/LimiterAnalysis.swift`, tests.
**Interfaces:** `public enum Limiter: String, Codable { memory, frameCap, gpuThermal, gpu, cpuOneThread, cpu,
unclear }`; `public struct LimiterAnalysis { public let shares: [(Limiter, Double)]; public let verdict: String;
public let primary: Limiter?; public let evidence: [String]; public let suggestion: String?; public let missing:
[String]; public static let thresholds: Thresholds; public init(_ bundle: RunBundle, summary: RunSummary) }`.
Classification per steady second exactly per spec §E (first match wins); verdict "Mostly <class>" when share ≥ 60 %,
else "Mixed: <a> and <b>"; evidence = medians of the triggering signals over the seconds in that class; missing names
absent inputs ("no GPU clock recorded", "no memory pressure recorded").
- [ ] Tests first (RED): Cyberpunk-like fixture (gpu busy 100, core max ~55, P 20 %) → primary gpu 100 %;
  `frameCapDetected` (fps 60.0 ± 0.5, gpu 70) → frameCap; one-thread fixture (gpu 60, core max 97) → cpuOneThread;
  thermal fixture (gpu 99, thermal serious) → gpuThermal; memory (pressure warn) → memory; mixed 50/50 → "Mixed";
  `oldRunWithoutNewColumns` (no gpu_mhz/mem columns) → still classifies GPU and lists the two missing inputs; no FPS
  source → analysis still runs on steady rows.
- [ ] Implement; also run it over the user's real run (read-only: `~/Documents/Metal-PT/runs/*cyberpunk*`) in a
  throwaway check and report the verdict (expected: Mostly GPU).
- [ ] Commit `Analyse what held a run back`.

### Task 3: Show it — summary, Compare, Live
**Files:** `SummaryReport.swift` (section "What held it back" near the top: verdict, share bars via HTML.bars, evidence,
suggestion, "How this is decided" thresholds note, missing inputs), `CompareReport.swift` (verdict per run line;
"Limited by" what-differs row), `Sources/MetalPT/LivePage.swift` (+ hub helper) "Limited by: GPU" from the last 30 s of
history while following/recording (reuse the per-second classifier on HubSnapshot fields), snapshots; tests.
- [ ] Tests first: report contains the section and the verdict for fixtures; compare row; Live classifier on snapshot
  history.
- [ ] Implement; render summary for the real Cyberpunk run into a temp copy (don't modify the user's run) and Read it;
  snapshots for Live; Read them.
- [ ] Commit `Show what held a run back`.

### Task 4: Recording feedback and notifications status
**Files:** `Sources/MetalPT/MenuBarView.swift` / `MetalPTApp.swift` (label "● 02:31 · 35 fps" red while recording;
"● starting…" / "saving…"), `AppModel.swift` (sound via `NSSound(named: "Tink")` start / `"Pop"` stop, setting
`soundOnRecord` default true; debounce: ignore a toggle < 1 s after the previous one), `SettingsPage.swift`
(sound toggle; Notifications row: status from `UNUserNotificationCenter.getNotificationSettings` — allowed / not allowed
/ not asked — with "Open Notification Settings" opening
`x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.wooloomooloo2.metal-pt`; unbundled:
"Available in the installed app"); tests (`debounceIgnoresSecondPress`, label text, sound injectable).
- [ ] Tests first, implement, snapshots (menu-bar label while recording), commit `Show recording state and play a sound`.

### Task 5: "Game not reporting frames" warning
**Files:** `Sources/MPTCore/Bench/ProcessNames.swift` (+ `environment(pid:) -> [String: String]?` from
`KERN_PROCARGS2`, pure parser tested on fixture bytes), `ProcessTree` helper (ppid chain via `proc_pidinfo` →
first ancestor whose path contains `.app/` and isn't launchd → app name), `Sources/MPTApp/` checker
(`FrameReportingCheck`: inputs frontmost pid, gpu busy history, HUD-following state, FPS-logging on; output
`warning: String?`), `AppModel`/`LivePage`/`MenuBarView` display; tests.
**Rules:** only while FPS logging is on and the hub is sampling; frontmost app (NSWorkspace) ≠ Metal-PT; GPU busy ≥ 50 %
for ≥ 10 consecutive samples; no HUD lines from that pid in that time; its env lacks `MTL_HUD_LOG_ENABLED` → warning
"<App> started before FPS logging was on — quit it and <Launcher> and open them again." (launcher sentence omitted if
none). Clears when HUD lines arrive, frontmost changes, or FPS logging goes off. Never written to bundles.
- [ ] Tests first (env parser fixtures incl. no env, ancestry fixture, checker rules incl. Review Focus 5), implement,
  manual check: with FPS logging on, start the spin test app WITHOUT the HUD variables in front and confirm the warning
  appears in Live within ~12 s (log line), then with the variables → no warning. Commit
  `Warn when a game isn't reporting frames`.

### Task 6: Docs
- [ ] README (what the summary's "What held it back" means; the warning; sound setting), run-bundle-format (new
  columns, gpuMaxMHz), CLAUDE.md state; rebuild `scripts/make-app.sh metal-pt`. Commit `Document limiter analysis and
  feedback`.
