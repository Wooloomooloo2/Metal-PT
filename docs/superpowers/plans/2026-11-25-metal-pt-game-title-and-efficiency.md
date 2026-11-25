# Metal-PT editable game title and FPS per watt — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user name the real game behind an emulator/launcher (keeping the recorded app as the ID) and make
FPS per watt a headline metric.

**Architecture:** `game.title` becomes editable through `RunIndex.update`; `RunEntry` carries the recorded app and
FPS/W; reports and pages read them. FPS/W is the existing `RunSummary.fpsPerWatt`; Live computes a 10 s figure from
hub history.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-25-metal-pt-game-title-and-efficiency-design.md`.

## Global Constraints
- Warning-free debug and release builds; `swift test` green after every task; schema stays 1; old runs load.
- `game.exe` is never modified by edits. Title trimmed, ≤ 120 characters, privacy-scrubbed on save.
- RunIndex `cacheVersion` bumped (2 → 3) because `RunEntry` gains fields.
- Commits with explicit pathspecs only; never commit `docs/data/aldente-ids.txt`; never `git reset`.
- Don't launch the real app (the user's installed Metal-PT may be running); snapshots via `--render-snapshots`.

## Review Focus
1. Clearing the Game field (empty, or equal to the app name) removes the title; the run shows the app name again.
2. A run whose exe is empty ("Unknown game") can be given a title; suggestions are empty for it.
3. Two runs with different titles but the same app do not group as the same game in Compare's run picker.
4. FPS/W tile for a run with no power, GPU-only power, and a frame-capped run (three distinct texts).
5. Live FPS/W shows "—" when FPS or system power is missing in the 10 s window (no division by ~0 W).

---

### Task 1: Editable game title
**Files:** `Sources/MPTApp/RunIndex.swift` (`RunEntry.app: String` = exe display name; `update(dir:settings:notes:
label:title:)` with `title: String?` — nil = leave, "" or equal to the exe display name = clear; cacheVersion 3;
`matches` includes app), `Sources/MetalPT/RunsStore.swift` (`update(..., title:)`; `titleSuggestions(forApp:) ->
[String]` from entries, distinct, most recent first, excluding the app name), `EditNotesSheet.swift` (Game field
first + suggestions menu + "Recorded app: X — kept for comparisons"), `RunDetailView.swift` (header "Title · App" when
they differ), `RunsPage.swift` (secondary app text), `SummaryReport.swift` ("Executable" → "Recorded app"),
`CompareReport.swift` ("Recorded app" what-differs row when runs differ), `Snapshots.swift`; tests.
- [ ] Tests first (RED): update sets/clears title and never touches exe; Review Focus 1–3; suggestions order and
  exclusion; cache version rebuild; summary row label; compare row present only when apps differ.
- [ ] Implement; snapshots of the edit sheet and run header (light/dark); Read them.
- [ ] Commit `Let the user name the game behind an emulator or launcher`.

### Task 2: FPS per watt as a headline metric
**Files:** `SummaryReport.swift` (tile "FPS per watt" second; texts per spec §B incl. frame-cap sub-line using
`LimiterAnalysis` primary == .frameCap and the cap value; caption caveat), `CompareReport.swift` (FPS/W on each run
line; "what differs" efficiency sentence vs baseline when power columns match), `RunIndex.swift` (`RunEntry.fpsPerWatt:
Double?`, only when power is system power), `RunsPage.swift` (FPS/W shown; sortable if the list sorts),
`Sources/MPTApp/` pure `LiveEfficiency.fpsPerWatt(history:window:)` (mean FPS / mean system W over last 10 s; nil when
either missing or mean W < 1), `LivePage.swift` (BigNumber "FPS/W"), `OverlayView.swift` (line), README caveat; tests.
- [ ] Tests first (RED): Review Focus 4–5; compare sentence "31 % more frames per watt" from fixtures; entry value
  nil for GPU-only power.
- [ ] Implement; snapshots of summary, Live, overlay, Runs list; Read them; render the user's ARMSX2 run summary into
  a temp copy (read-only: `~/Documents/Metal-PT/runs/*armsx2*`) and Read it.
- [ ] Commit `Make FPS per watt a headline metric`.

### Task 3: Docs and rebuild
- [ ] README (naming the game; FPS/W and its caveat), run-bundle-format (`game.title` is user-editable; `game.exe`
  is the recorded app), CLAUDE.md state; `scripts/make-app.sh metal-pt`. Commit `Document game title and FPS per watt`.
