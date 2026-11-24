# Metal-PT: limiter analysis and recording feedback — design

Date: 2026-11-24. Status: agreed with the user ("yes, do all of it in the next round") after the first real test
(Cyberpunk 2077, native). Extends `2026-11-24-metal-pt-design.md`.

## Why
The first real test showed three usability gaps and one missing feature:
1. The record hotkey gave no visible feedback (overlay off, notifications not delivered), so the user could not tell
   whether recording had started; three presses produced start/stop/start.
2. A game launched from a launcher started before FPS logging was on (Steam) silently gave no FPS.
3. Notifications may be disabled for the ad-hoc app with no indication.
4. The user wants the summary to say what held performance back (GPU, CPU, memory). The Cyberpunk run was clearly
   GPU-bound (GPU busy 100 % every steady second, busiest CPU core median 55 %), but the app does not say so, and two
   signals are missing to make the call trustworthy: GPU clock and memory pressure.

## What gets built
### A. Recording feedback
- Menu-bar label while recording: a red ● and elapsed time (e.g. "● 02:31 · 35 fps"), visible even with the window and
  overlay closed. While starting/saving: "● starting…" / "saving…".
- A short system sound on start and on stop (Settings → "Play a sound when recording starts and stops", default on).
- A double press within 1 s is ignored (debounce), so a start can't be cancelled by an accidental second press.

### B. "Game not reporting frames" warning
- When FPS logging is on, the frontmost app (not Metal-PT) has been GPU-heavy (GPU busy ≥ 50 %) for 10 s, and no HUD
  lines come from it, read its environment (same-user `KERN_PROCARGS2` includes env) — if `MTL_HUD_LOG_ENABLED` is
  absent, show in Live and the menu: "<App> started before FPS logging was on — quit it and its launcher (<parent
  app name, e.g. Steam>) and open them again." Parent = the process's responsible/parent app found via ppid chain
  (first ancestor that is an .app other than launchd).
- Clears when HUD lines arrive or the app quits.

### C. Notifications status
- Settings shows the notification authorization (allowed / not allowed / not asked) with "Open Notification Settings"
  (deep link to the Notifications pane for the bundle id). Live/menu say nothing about it; the sound (A) covers
  feedback.

### D. New recorded columns (append-only, schema stays 1)
- `gpu_mhz`: residency-weighted mean clock over the non-OFF residency of `GPUPH` in that second, from the `pmgr`
  frequency table (hardware-baseline: `voltage-states9`, OFF + 15 steps). Table found at runtime per Mac: the first
  `voltage-states*` property whose entry count equals the GPUPH state count; if none, the column stays empty.
  `run.json` machine gains `gpuMaxMHz` (optional).
- `mem_pressure`: `kern.memorystatus_vm_pressure_level` as `normal` / `warn` / `critical`.
- `swap_used_gb`, `compressed_gb`, `pageouts_per_s` (delta of the pageout counter).

### E. "What held it back" (limiter analysis)
- Pure `LimiterAnalysis` in MPTCore over a run's steady seconds (same steady window as RunSummary). Each second is
  classified, first match wins:
  1. **Memory** — `mem_pressure` ≥ warn, or `pageouts_per_s` > 50 (pages) in that second.
  2. **Frame cap** — FPS within ±2 % of 30, 40, 45, 60, 90, 120 or 144 and GPU busy < 90 %.
  3. **GPU, thermal** — GPU busy ≥ 95 % and (thermal_state ≥ serious, or `gpu_mhz` < 85 % of the run's highest
     `gpu_mhz` while thermal ≥ fair).
  4. **GPU** — GPU busy ≥ 95 %.
  5. **CPU, one thread** — GPU busy < 85 % and busiest core ≥ 90 %.
  6. **CPU** — GPU busy < 85 % and CPU P-cores ≥ 80 %.
  7. **Unclear** — otherwise.
- Verdict: the class with the largest share if ≥ 60 % of steady seconds, else "Mixed: <top two>". Each class carries
  evidence (the medians that triggered it) and one suggestion (GPU: lower resolution/GPU settings, MetalFX/frame
  generation; CPU one-thread: higher-clock settings won't help GPU-side; lower CPU-heavy settings (crowds, ray-traced
  shadows); memory: close other apps / lower textures; frame cap: the game is capped — remove the cap or accept it;
  thermal: cooler surface, higher fan curve later with Metal-PT Helper).
- Thresholds live in one table in code with a comment; the report states them ("how this is decided").
- Summary HTML: a "What held it back" section near the top: verdict sentence, share bars per class, evidence lines,
  the suggestion, and the thresholds note. Runs without the new columns (older runs) still get an analysis from what
  exists; missing inputs are named ("no GPU clock recorded").
- Compare: each run line gains its verdict; "what differs" gains a "Limited by" row.
- Live page: a small "Limited by: GPU" line under the numbers while recording or following (last 30 s).

## Non-goals
- No automatic setting changes. No per-game profiles. No CPU frequency column (P-cluster residency already shows load;
  can come later).

## Constraints
Hard rules unchanged: no root, no SMC writes, background cost rule (nothing new runs when nothing is shown/recorded —
the frontmost-app check runs only while FPS logging is on and the hub is sampling), privacy (new columns are numbers;
app names in the warning are never written to bundles).
