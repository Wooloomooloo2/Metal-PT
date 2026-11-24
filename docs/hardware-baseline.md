# Hardware baseline — MacBook Pro 16" M4 Max (Mac16,5), macOS 26.6

Tags: **[M]** measured on this machine (experiment ID, date). **[?]** external source, unverified.
Raw outputs are in `docs/data/`. Procedure: `docs/m0-test-plan.md`.

## AlDente (E0)

## SMC inventory (E1)

- [M] E1 2026-10-07: 3386 keys (`docs/data/smc-keys-m4max.txt`). All reads unprivileged except a few keys
  (e.g. `CH0J`, `CHLS`) that return `notPrivileged` without root.
- [M] **Byte order: SMC integers are little-endian on this machine**, not big-endian. Evidence: `B0AC [si16] 27 FD`
  = 0xFD27 = −729 mA against `fwprobe battery` −741 mA; `B0AV 5E 2C` = 11358 mV against 11374 mV; `B0AT DF 0B` =
  3039 = 30.39 °C against 30.39 °C; `B0CT 90 00` = 144 cycles. Exception: `#KEY [ui32] 00 00 0D 3A` is big-endian
  (3386). `flt ` is little-endian. `SMCValue.number` currently decodes ui16/ui32/si16 as big-endian — wrong for
  these keys; fix in M1. Writes are raw bytes and unaffected.
- [M] Charge control candidates: `CHTE [ui32] 4B 00 00 00 00`; `CHIE [hex_] 1B 00`; `CH0B`, `CH0C` absent;
  `CH0J` exists (needs root to read). `ACLC [ui8] 04` (MagSafe LED candidate, not in scope). `BCLM`, `CHWA` absent.
- [M] Fans: `FNum` 2; `F0Md`/`F1Md [ui8] 03` at rest; `Ftst [ui8] 00`; `F0Tg`/`F1Tg [flt ] 0.0`;
  `F0Mn`/`F1Mn` 1350 RPM; `F0Mx`/`F1Mx` 5777 RPM; `F0Ac`/`F1Ac` 0.0 at idle (fans stopped).
- [M] Battery temperature keys: `TB0T`, `TB1T`, `TB2T [flt ]` ≈ 30.6–30.7 °C, matching AppleSmartBattery 30.39 °C.

## Charge inhibit (E2)
## Adapter inhibit (E3)
## Fans (E4)
## Temperatures (E5)
## IOReport power and clocks (E6)

- [M] E6 (partial) 2026-11-24: 11 817 channels (`docs/data/ioreport-channels-m4max.txt`). **Not an idle baseline**: a game
  (Horizon Zero Dawn Remastered under Protium) and MTLCompilerService (~1200 % CPU) were running. Repeat on an idle machine.
- [M] **"Energy Model": only `GPU Energy [nJ]` is non-zero** (~0.26–0.33 W per 1 s delta). `CPU Energy`, `EACC_CPU`,
  `PACC0_CPU`, `PACC1_CPU`, `ANE`, `DRAM`, `GPU [mJ]` all read 0, alone (`--group "Energy Model"`) or merged, idle or with
  12 P-cores loaded. CPU power must come from elsewhere (SMC `P***`, or `PMP / Energy` in events — unexplored).
- [M] CPU residency: `CPU Stats / CPU Core Performance States / PCPU000…PCPU150` (12 P-cores, 2 clusters) and
  `ECPU000…ECPU030` (4 E-cores); state names `IDLE`, `DOWN`, `V<n>P<m>` (P-cores V0P19…V19P0, E-cores V0P6…V6P0).
  Units 24 Mticks (≈ 24.2 M per second). Under the load above every P-core was 100 % `V19P0`, IDLE 0.
- [M] GPU: `GPU Stats / GPU Performance States / GPUPH` states `OFF`, `P1`…`P15`. Busy = 1 − OFF share.
- [M] Cost: sample + delta of the three default groups ≈ 8–13 ms per sample (under load).
- [M] SMC power keys (`flt`, watts) are unprivileged and track load: at E1 (idle) `PSTR` 8.1, `PHPC` 7.4, `PDTR` 0.0001;
  under the load above `PSTR` 83.2, `PDTR` 87.4, `PHPC` 60.1, `PHPS` 52.8, `PSVR` 56.3, `PZC0` 52.8, `PZC1` 51.7,
  `PMVC` 15.5, `PPMC` 6.7, `PPSC` 5.3. [?] Meanings (likely `PSTR` system total, `PDTR` DC-in, `PHPC` SoC/CPU) to be
  pinned by a controlled CPU-only / GPU-only load.
- [M] E6 controlled loads 2026-11-24 (machine otherwise idle, on AC, battery 80 % not charging), SMC watts:

  | key | idle | 16× `yes` (CPU) | GPU-only (Metal clears, 3840×2400, GPUPH P1/P2 ~87 %) |
  |---|---|---|---|
  | `PSTR` | 16.8–17.2 | 41.5–44.3 | 32.3–32.4 |
  | `PDTR` | 15.9–18.0 | 41.1–42.4 | 31.9–32.5 |
  | `PHPC` | 2.8–4.8 | 24.3–25.4 | 16.0–16.4 |
  | `PSVR` | 1.5–3.0 | 23.7–24.6 | 14.0–14.3 |
  | `PZC0`/`PZC1`/`PHPS` | 1.5–3.5 | 19.2–20.0 | 13.1–13.8 |
  | `PMVC` | 4.6–5.2 | 6.9–7.4 | 7.4–7.6 |
  | `PPMC`/`PPSC` | 0.7–1.2 | 1.7–2.6 | 2.1 |

  **`PSTR` = system total** (equals `PDTR`, DC-in, on AC). `PHPC`/`PSVR`/`PZC*` rise with CPU *and* GPU load: SoC rails,
  not a CPU-only figure. IOReport `GPU Energy` read only 1.15–1.31 W under the GPU load while the SoC keys rose ~12 W —
  [?] it may under-report or cover only part of the GPU; don't use it as the GPU's power until checked with a heavy game.
- [M] At idle, P-core residency is mostly `IDLE` (PCPU000 IDLE ≈ 99 %), so busy = 1 − (IDLE+DOWN) share works; the
  100 % `V19P0` seen earlier was the game load.
## Power modes (E7)
## FPS (E8)

- [M] E8 (partial) 2026-11-24, with a minimal CAMetalLayer test app at 60 Hz (not yet a real game):
  - `MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1` in the process environment makes `libMTLHud.dylib` log about once per
    second (≈ 1.016 s): `metal-HUD: <frames>,<a>,<b>,<interval ms>,<present-delay ms>,…` where `<frames>` is
    **cumulative** (63, 124, 185 …) and the pairs are **every frame** since the last line. [?] `<a>`/`<b>` unknown
    (10.61/468.19, then 6.72/285.24). The library registers metrics `hud-stat.fps`, `hud-stat.frame-interval`,
    `hud-stat.present-delay`, which fits interval/present-delay for the pairs.
  - Goes to the process's **stderr in full** and to the **unified log** (format `metal-HUD: %zu,%.2f,%.2f%s`,
    sender `libMTLHud.dylib`, empty subsystem). In the unified log the `%s` (per-frame list) is **`<private>`**; the
    frame count, timestamp, `processID` and `processImagePath` are public. Readable unprivileged, cross-process:
    `/usr/bin/log stream --style ndjson --predicate 'eventMessage BEGINSWITH "metal-HUD"'` (in zsh, `log` is a builtin).
  - So: **per-second FPS for any Metal process with no root**; **per-frame times** only from stderr (when we launch the
    process) or with private log data enabled (root, untested).
  - `MTL_HUD_HIDDEN=1` stops the logging too. `MTL_HUD_REPORT_URL=file://…` wrote nothing.
    `MTL_HUD_LOG_METRICS_ENABLED=1` added nothing visible. Other variables are listed by `strings libMTLHud.dylib`.
  - Still to test: a real Wine/CrossOver/Protium game (DXMT and D3DMetal), whether the HUD env reaches it, stderr
    capture through `wine`, and `log stream` CPU cost.
- [M] E8 2026-11-24: **each HUD line appears twice in the unified log**: first with empty subsystem, then a copy with
  subsystem `com.apple.metal.hud`, category `Logging`, same thread and message, ~50–130 µs later. A naive per-event
  frame delta then gives 0 fps on the copy; `FrameCounter` ignores an unchanged count < 0.25 s after the previous line.
  [?] Whether the copy is always present: an earlier run that day read a steady 60 fps before the fix.
- [M] E8 2026-11-24: the HUD message is **Default level**: the same predicate with `--level debug`, `--level info` or
  no `--level` received the same lines (10 s side by side, test app running).
- [M] E8 2026-11-24, recording cost (`fwbench record`, 1 Hz, 20 s windows, cumulative CPU from `ps -o time`):
  - before: `/usr/bin/log stream --level debug` 2.66–2.87 s / 20 s ≈ 13–15 % (side by side over 10 s: `--level debug`
    1.53 s, `--level info` 0.35 s, no `--level` 0.18 s); fwbench 0.37 s / 20 s ≈ 1.9 % (release), ≈ 2.0 % (debug).
  - after dropping `--level debug` and keeping one HID event-system client: `log` 0.40–0.43 s / 20 s ≈ 2.0–2.2 %;
    fwbench 0.35 s / 20 s ≈ 1.75 % (release), 0.42 s ≈ 2.1 % (debug). Combined ≈ 4 %, still over the 1 % target.
  - Most of fwbench's tick is `IOHIDServiceClientCopyEvent` for the ~45 HID temperature sensors (IPC to the HID event
    system; 187 of 227 tick samples in a `sample` profile); reusing the client did not change that much.
- [M] E5/E8 2026-11-24: HID sensor "PMU tcal" reads a constant 51.9 at idle and under 8 s of 12× `yes` (a
  calibration value, not a temperature); it was always the max. `temp_max_c` now skips it (die sensors ~40–43 °C).
## Open questions
