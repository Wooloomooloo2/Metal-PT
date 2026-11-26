# Metal-PT

**Metal Performance Telemetry** for Apple Silicon Macs: a free, open-source (GPL-3.0) app for people playing Windows
games on a Mac through CrossOver, Protium, Whisky and friends (with DXMT, D3DMetal, DXVK...).

- **Live**: FPS, frame times, CPU/GPU load, power, temperatures and fans for the game you are playing, in the window,
  the menu bar or a small in-game overlay. Metal-PT also shows which stack the game runs on (runtime, translator,
  graphics layer).
- **Record** a run with a hotkey, then get a summary (average FPS, lows, FPS per watt, steady-state power and
  temperatures).
- **Compare** runs: CrossOver vs Protium, DXMT vs D3DMetal, one in-game setting vs another.
- **Export** a run as one file for a future public performance database. You see exactly what it contains first.

Metal-PT runs as you. It never needs administrator rights or a helper, and it never changes fan or battery settings.
Repo: https://github.com/Wooloomooloo2/Metal-PT. Needs macOS 15 or later on an Apple Silicon Mac. Built and tested on
a MacBook Pro 16" M4 Max (Mac16,5), macOS 26.

## Install

1. Download `Metal-PT-<version>.zip` from the repo's
   [GitHub Releases](https://github.com/Wooloomooloo2/Metal-PT/releases) page.
2. Unzip it (double-click) and move **Metal-PT.app** to your **Applications** folder.
3. Open it. The first time, macOS refuses ("Apple could not verify Metal-PT..."). Click **Done**, then open
   **System Settings → Privacy & Security**, scroll to the message about Metal-PT and click **Open Anyway**, then
   confirm. You only do this once per version.

Why: Metal-PT is signed ad hoc, not with an Apple Developer ID, because the author has no Apple Developer Program
membership. macOS therefore cannot check who made it and asks you to approve it yourself. The source is all here;
you can build it yourself instead (below).

Because each ad-hoc build is a new signature, macOS may treat an update as a new app: after updating you may be asked
again to allow notifications (System Settings → Notifications → Metal-PT), and to turn "Open at login" back on.

## Using it

- **FPS logging** (Settings, or the menu bar): FPS comes from Apple's Metal HUD. Turning FPS logging on sets the
  HUD variables for apps you launch from now on. Then **quit and relaunch the game, and its launcher** (CrossOver,
  Protium...) so they pick the variables up. The HUD is drawn in the game while FPS logging is on. Turning it off,
  or quitting Metal-PT, removes the variables again; games already running keep the HUD until they restart.
- **⌃⇧F6** starts and stops a recording. It works without a game detected (telemetry only); FPS fills in once a
  game with FPS logging appears. A notification says when the run is saved.
- **⌃⇧F7** shows or hides the in-game overlay. Its style, corner and opacity are in Settings. Both hotkeys can
  be changed in Settings; Metal-PT needs no Accessibility permission.
- On MacBook keyboards you may need **Fn** for F6/F7. Menu-bar managers (Bartender etc.) may hide the Metal-PT
  item. After turning FPS logging on, restart the game's launcher (e.g. Steam) so games inherit the variables.
- If FPS logging is on and a game keeps the GPU busy but logs no frames, Metal-PT warns that the game is not
  reporting frames (restart the launcher and the game). The check runs only while Metal-PT is sampling (recording,
  the overlay on, or the Live page visible). Settings has a sound option for recording start and stop;
  the menu-bar label turns red while recording.
- **What held it back** (run summary, Compare, Live page) classifies each steady second as memory (pressure or
  paging), a frame cap (FPS at 30/40/45/60/90/120/144 or the display's refresh rate or half of it, with the GPU not
  busy), GPU (thermal), GPU, CPU (one thread) or CPU, then gives a verdict (a class with at least 60 % of seconds,
  else "Mixed", or "Partly GPU (otherwise no single limit)") with the evidence and one suggestion.
  A busy GPU well below its top clock is not counted as GPU-bound (the clock reading is not yet verified against a
  heavy game); in low power mode or on battery the GPU is judged on busy % only. It is a guide, not proof; each
  report shows the thresholds it used ("how this is decided").
- **FPS per watt** (run summary, Compare, Runs, Live and the overlay): median FPS over mean system power for a run
  (mean FPS over the last 10 s live), so two runs at 60 fps drawing 34 W and 50 W tell apart. System power includes
  the display: compare FPS/W on the same Mac, brightness and power source. Runs with GPU-only power (no system power
  key) get no FPS/W (not comparable in the summary, Runs list and Live; Compare only sets GPU-only runs against other
  GPU-only runs), and a run held at a frame cap says its figure is efficiency at that cap.
- **Naming the game**: a Wine or launcher run is recorded under the app that ran it (the exe). In Edit, the
  "Game" field gives it the real title; the recorded app is kept so runs of the same game still compare.
- **Runs**: every recording, newest first, with its summary. Add in-game settings and notes, show it in Finder,
  or move it to the Trash.
- **Compare**: tick runs in Runs and choose "Compare selected…", or add runs to a project in Compare. Pick a
  baseline; the report shows each run against it. "Add Runs…" has a search (game, app, stack, settings, label), so an
  old run is easy to find; right-click it and choose "Add as baseline" (or tick one run and "Make it the
  baseline"). The Baseline menu shows each run's date.
- **Export**: on a run, "Submit…" shows exactly what would be sent, then "Export file…" writes one
  `<run>.mptrun.zip` to the `exports` folder. Publishing the same file to metal-pt.com is described below.
- Files live in `~/Documents/Metal-PT/` (`runs/`, `projects/`, `exports/`); Settings can move the data folder.
- Metal-PT can open at login (Settings). This needs Metal-PT.app in your **Applications** folder. Opened at login
  it starts in the menu bar only; opened yourself it shows its window.

## Privacy

Nothing leaves your Mac unless you press Publish (or export a file yourself); there is no analytics. An export contains the run's
`run.json` (game executable and title, the stack, your Mac's model, chip, memory and macOS version, power mode,
display, the run's settings and label, warnings), `samples.csv` (one row per second of telemetry), `frames.csv` when
per-frame times were recorded, and a `manifest.json` listing those files with their sizes and checksums. Your notes
are left out unless you tick "Also send my notes". Before export Metal-PT scrubs again: home folder paths
(`/Users/<name>`, Wine's `C:\Users\<name>` and `drive_c/users/<name>`) become `~`, and this Mac's names (its
computer name and host name) become `<host>`. The summary page is not exported. No user name, home folder, computer
name or serial number is included.

## Publishing to metal-pt.com

Publish sends one finished run to the Metal-PT website, where it gets a public page with its numbers, a chart and a
download link, and counts towards the typical figure for that game on that Mac. It is always your choice: nothing is
sent until you press Publish on a run ("Submit..." on the run, then "Publish this run"). The website is not live
yet; until it is, Publish says it can't reach metal-pt.com.

- **Four graphics settings are required**: preset, resolution, upscaler and frame generation. Publish stays off,
  with the missing ones outlined, until all four are set.
- **A YouTube link is optional.** Only an https link to youtube.com (watch, shorts or live) or youtu.be counts. The
  site keeps the video's ID, title and channel, not the text you typed, and the page links out to YouTube; nothing
  from YouTube is loaded into the page.
- **Public**: your Mac's model, chip, GPU cores, memory and macOS version; the setup (native, or the Wine runtime
  with its graphics layers); the game's title and settings; the per-second numbers; your run label and settings
  text; your notes only if you tick the box; the YouTube link's ID, title and channel. The run page also offers the
  same `.mptrun.zip` that was uploaded.
- **Never public**: the key that signs your runs (made on your Mac, used so only you can change or remove your
  runs and so each Mac counts once); your user name, Mac name and home folder paths (removed before sending and
  checked again by the site). The site stores no IP addresses, user agents or cookies, and runs no analytics. The
  site's /privacy page says the same.
- **Removing a run**: right-click it in Runs and choose "Remove from metal-pt.com...". The page, the file and its
  part in every typical figure are deleted (pages can take a minute to catch up). Only the Mac that published a run
  can remove it; if that key was lost, Metal-PT offers "Forget on this Mac".
- **Offer to publish after each run** (Settings, Recording feedback, off by default): the "Run saved" notification
  then has a "Publish..." button that opens that run's Publish sheet. Nothing is sent without pressing Publish.
- From the terminal: `mpt publish RUN` and `mpt unpublish RUN`, using the same key.

## Build from source

Needs Xcode 16 or later (Swift 6).

    swift build
    swift test
    scripts/make-app.sh metal-pt        # build/Metal-PT.app and build/Metal-PT-<version>.zip (signed ad hoc)

`make-app.sh metal-pt --sign "IDENTITY"` signs with a certificate of yours instead. The version comes from the
`VERSION` file, which must equal `MetalPTVersion.current` (the script and `swift test` check this). The icon is
drawn by `scripts/make-icon.swift`. `.build/debug/MetalPT` runs the app unbundled for development (no
notifications or login item).

## What Apple Silicon does not allow

There is no TDP / power-limit interface and no undervolting on Apple Silicon. Metal-PT will not pretend otherwise.
Performance modes are macOS's Low Power / Automatic / High Power modes.

## Metal-PT Helper (coming later)

A second app, **Metal-PT Helper**, will add battery charge limiting and fan control through a root helper. It is not
built yet. `mptprobe` (`.build/debug/mptprobe`) is the developer tool used to measure what this hardware exposes;
see `docs/hardware-baseline.md`.

## Command-line recorder (mpt)

`mpt` (`.build/debug/mpt` after `swift build`) records and compares runs from Terminal, writing the same run folders
as the app. It runs as you and needs no helper. Details: `docs/adr/0002-unprivileged-benchmark-recording.md`.

    F=.build/debug/mpt
    $F hud on                      # terminal 1: leave running; Ctrl-C unsets the HUD variables
    # relaunch the launcher / game, get to a repeatable scene, then in terminal 2:
    $F record --warmup 15 --seconds 120 --label "CrossOver DXMT" --settings "High, 1440p"
    $F ls                          # run names
    $F summary <run> --open
    $F compare hzd add <run1> <run2>
    $F compare hzd report --open

`$F run --seconds 120 -- <command…>` launches the game itself with the HUD variables set and also captures
per-frame times (1 % / 0.1 % lows). `$F` alone prints every command. Runs go to `$MPT_DATA_ROOT` (default
`~/Documents/Metal-PT`) `/runs/`; format: `docs/run-bundle-format.md`. Recording costs about 2.6 % of one core
(`docs/hardware-baseline.md`).

## Licence

GPL-3.0. See `LICENSE`.
