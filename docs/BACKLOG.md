# Backlog

Deferred work, newest first under each heading.

## Website (separate project, Cloudflare; see metal-pt-design.md §6)

- **Compare runs on the website (2026-11-25).** A visitor picks two or more submitted runs of the same game
  (theirs or anyone's) and gets the same report as the app's Compare page: runs named by what differs, a colour
  per run, median FPS / power / FPS-per-watt bars, the "What differs" table and the "Read with care" warnings
  (different machines, macOS builds, AC/battery, FPS sources). The owner liked the look of the local report
  (`hzd-gptk-3-vs-4.html`, 2026-11-25), so reuse it: either render `CompareReport.html` server-side from the
  uploaded `run.json` + `samples.csv`, or port it to the site with the same layout and tokens. Same game by
  default, as in the app's Add Runs. Shareable link per comparison. Design question for then: compare across
  machines (useful: M1 vs M4) and how prominently to warn when the runs differ in more than one thing.

## Metal-PT

- **Game memory: app and Metal (2026-11-25).** Owners of 8/16 GB Macs want to know how much memory a game asks
  for and how much it really uses, before buying or tuning settings. Today a run has only system-wide figures
  (`mem_used_gb`, `mem_pressure`, `swap_used_gb`, `compressed_gb`, `pageouts_per_s`), which mix in everything
  else on the Mac. Wanted, per game:
  - **App memory:** the game's footprint (what Activity Monitor's Memory column shows: `phys_footprint` from
    `proc_pid_rusage`, readable unprivileged for the user's own processes `[?]`), peak and steady median. For
    Wine games, sum the game's process tree (the `.exe`'s process plus wineserver and helpers? decide).
  - **Metal memory:** what the game has allocated on the GPU (on Apple Silicon this is the same unified
    memory, so it counts against the same RAM). Source to find `[?]`: per-process IOAccelerator / AGX
    statistics in the IORegistry, or what the Metal HUD reports; `MTLDevice.currentAllocatedSize` only works
    inside the game.
  - "Asks for" vs "uses": e.g. a reserved/allocated figure against resident, if the sources give both.
  Show it in the run summary, Live page and overlay, and in Compare (a "Peak memory" bar chart, so High vs
  Medium shows the memory cost too). In the website comparison as well. A note per run: "fits in 16 GB" / "would
  swap on 8 GB" is tempting but needs care (macOS compresses and swaps before failing).

- **Compare: colour key in the app's baseline picker (2026-11-25).** The report colours each run (`--s1`…`--s6`,
  run list, bars, table header); the SwiftUI baseline menu still shows names only. More than six runs reuse
  `--s6` (`HTML.seriesColor` clamps).
- **Game settings field at save time (2026-11-25).** Run names come from what differs, so the preset only shows
  when the user types it (settings or label). Consider a preset picker (Low/Medium/High/Ultra + free text).

## Done 2026-11-25 (not yet committed)

- Compare hang: a long game name made every "… 2", "… 3" cut to one taken file name (40-character slug), so
  `CompareProjects.create` spun the main thread forever. Project file names now keep their end
  (`CompareProject.fileName`), the search stops after `maxNameTries`, `mpt compare NAME` still finds the old names.
- Add Runs offers the comparison's own game(s); "Show other games (N)" shows the rest.
- Runs are named by what differs (`CompareReport.labels`: settings, label, graphics, runtime version, …) and
  coloured per run in the report.
- D3DMetal version recorded (`Stack.graphicsVersions`, from the mapped framework's Info.plist); GPTK 4's own
  `d3d12core.dll` no longer reads as vkd3d.
- "1 % low —" now says why: per-second FPS from the system log has no frame times ("needs mpt run").
