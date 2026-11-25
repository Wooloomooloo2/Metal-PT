# Metal-PT: search in Add Runs and choosing the baseline — design (short)

Date: 2026-11-25. Status: agreed with the user ("yes, build it").

**Why:** testing a new driver months after the last test, the user wants to find the old run quickly and make it the
baseline. Today the baseline is the oldest run (changeable from the "Baseline:" menu over the report), but Add Runs
has no search and lists every same-game run newest first.

**Approaches:** (a) reuse `RunEntry.matches` (game, stack, settings, label, recorded app) for a search field in Add
Runs — chosen, same behaviour as the Runs page; (b) a separate advanced filter (date range, stack pickers) — rejected
for now, more UI than the need.

**Design:**
- Add Runs gets a search field above the list (same matching as the Runs page; same-game default and "Show other
  games" unchanged; ticked runs that the search hides stay ticked and are counted in the Add button, e.g. "Add 2").
- Run dates in Add Runs and in the Baseline menu: "Today 9:50", "12 Aug" this year, "12 Aug 2025" in earlier years.
- "Make baseline": a context-menu item on a row ("Add as baseline") and, when exactly one run is ticked, a checkbox
  "Make it the baseline" under the list. Adding then sets that run as the project's baseline in the same step.
- The Baseline menu shows each run's date next to its name.
- Default unchanged: a new comparison's baseline is its oldest run.

**Non-goals:** date-range filters; baseline across projects.
