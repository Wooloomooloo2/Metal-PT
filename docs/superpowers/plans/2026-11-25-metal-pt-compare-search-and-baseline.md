# Metal-PT search in Add Runs and baseline choice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find an old run in Compare's Add Runs by search and make it the baseline while adding it.

**Architecture:** SwiftUI changes in `CompareSheets.swift` / `ComparePage.swift`; a pure date formatter; the add
path gains an optional baseline (store → `CompareLibrary`).

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-25-metal-pt-compare-search-and-baseline-design.md`.

## Global Constraints
- Warning-free debug and release builds; `swift test` green; commits with explicit pathspecs only; never commit
  `docs/data/aldente-ids.txt`; never `git reset`; don't launch the real app.

## Review Focus
1. A ticked run hidden by a new search stays ticked and is added.
2. "Add as baseline" on a run of another game (Show other games on) works and the report's warnings still appear.
3. Adding with "Make it the baseline" when the project file fails to save leaves the baseline unchanged (error shown).
4. Date text at year boundaries (31 Dec last year vs 1 Jan this year) with an injected clock/calendar.

---

### Task 1: Search, dates and baseline-on-add
**Files:** `Sources/MetalPT/CompareSheets.swift` (search field; `RunFormat`-style `shortDate(_:now:calendar:)`; row
context menu "Add as baseline"; "Make it the baseline" checkbox when one run is ticked; Add button counts ticked),
`Sources/MetalPT/ComparePage.swift` (Baseline menu items with date), `Sources/MetalPT/ProjectsStore.swift` +
`Sources/MPTApp/CompareLibrary.swift` (`add(_:runs:baseline:)` — baseline = bundle id among the added runs, applied in
the same edit), `Snapshots.swift` (Add Runs with a search and the checkbox); tests.
- [ ] Tests first (RED): Review Focus 1–4; add-with-baseline sets the index of that run after appending; date strings
  ("Today 9:50", "12 Aug", "12 Aug 2025").
- [ ] Implement; snapshots light/dark; Read them; README Compare paragraph: search and "Add as baseline".
- [ ] Commit `Search runs in Add Runs and pick the baseline while adding`; rebuild `scripts/make-app.sh metal-pt`.
