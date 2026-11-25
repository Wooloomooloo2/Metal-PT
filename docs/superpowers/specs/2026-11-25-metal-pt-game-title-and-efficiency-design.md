# Metal-PT: editable game title and FPS per watt — design

Date: 2026-11-25. Status: agreed with the user ("yes, write it up and build both") after recording ARMSX2 (a PS2
emulator): the run was named after the emulator, not the game. Extends `2026-11-24-metal-pt-design.md`.

## Why
1. Emulators, launchers and wrappers record under their own name ("ARMSX2"). The user needs to name the actual game,
   while keeping the recorded app as a stable ID for comparisons (the same game on two emulators, or native vs
   CrossOver, is the comparison that matters).
2. FPS per watt is a key metric for comparing translation layers and emulators (two runs holding 60 fps at 34 W vs
   50 W). Today it is a sub-line under the System power tile.

## Approaches
- Game title: (a) reuse the existing optional `game.title` beside the detected `game.exe` — chosen: the schema,
  privacy scrubbing, exports and most displays already prefer it; (b) a new field — rejected, duplicates (a);
  (c) auto-detect from the emulator's window title — rejected for now: needs Screen Recording permission.
- FPS/W: promote the existing `RunSummary.fpsPerWatt` (median FPS / mean system W over steady seconds) — no new
  measurement; a live figure uses the same definition over the last 10 s.

## What gets built
### A. Game title
- "Edit Settings/Notes…" gains a **Game** field first, prefilled with the title (or the app name when none). Below it,
  read-only: "Recorded app: ARMSX2 — kept for comparisons". Saving an empty field, or the app's own name, clears the
  title. `game.exe` is never edited.
- Suggestions: titles previously used on runs with the same recorded app (most recent first), offered as a menu next
  to the field; never applied automatically.
- Display: run header "Shadow of the Colossus · ARMSX2" when a title differs from the app; summary row
  "Executable" renamed "Recorded app"; Runs list shows the title with the app as secondary text when they differ;
  the search filter matches both.
- Compare: same-game grouping uses the title (already); "what differs" gains a "Recorded app" row when runs differ.
- Title is user text: privacy-scrubbed like the other user fields (already for `game.title`); trimmed; max 120 chars.

### B. FPS per watt
- Summary: a "FPS per watt" tile second, after Median FPS: value with 2 digits; sub-line "at 34.2 W system power"; when
  the limiter verdict is mostly a frame cap: "at a 60 fps cap — efficiency at the cap". GPU-only power: the tile says
  "not comparable (GPU-only power)" as the power tile does today. The System power tile keeps the watts.
- Compare: each run line shows its FPS/W; "what differs" states the efficiency difference against the baseline
  ("31 % more frames per watt") when power was measured the same way (existing mismatch rule applies).
- Runs list: an FPS/W value per run (sortable where the list sorts).
- Live and overlay: "FPS/W" figure = mean FPS / mean system W over the last 10 s, shown only while following a game
  with FPS and system power; "—" otherwise.
- Caveat stated once in the README and the report's power caption: system power includes the display; compare FPS/W
  on the same Mac, brightness and power source.

## Non-goals
No auto-detection of the emulated game; no "emulator" stack type (follow-up); no new columns; schema stays 1.

## Constraints
Hard rules unchanged; background-cost rule (the live figure reuses hub history); run index cache bumped when its
entry shape changes; old runs load unchanged.
