# M0 test plan — hardware baseline

Machine: MacBook Pro 16" M4 Max (Mac16,5), macOS 26.6. Build first: `swift build`.
`P=.build/debug/fwprobe`. Every write experiment restores on exit; if a restore ever reports
`RESTORE FAILED`, run the printed command before doing anything else.
Record every result in `docs/hardware-baseline.md` with the experiment ID and date.

## E0 — AlDente (do first, AlDente still running)
1. `mkdir -p docs/data && scripts/aldente-ids.sh > docs/data/aldente-ids.txt` — bundle id, helper label, process names.
2. Note AlDente's current limit. Set it to 100%, then quit AlDente from its menu.
3. `$P smc watch --interval 10 CHTE CH0B CH0C CHIE` for 2 minutes. If any value changes, AlDente's
   helper is still enforcing: stop here and unload it before E2.

## E1 — SMC inventory
1. `$P smc list > docs/data/smc-keys-m4max.txt`
2. Read the candidates: `$P smc read CHTE CH0B CH0C CHIE CH0J ACLC Ftst FNum F0Md F0Tg F0Mn F0Mx F0Ac F1Md F1Tg F1Mn F1Mx F1Ac TB0T TB1T TB2T`
3. Record which exist, with type, size and current bytes.

## E2 — Charge inhibit (on AC, battery below 90%)
1. Baseline: `$P battery` twice, 10 s apart. Expect positive mA (charging).
2. `sudo $P charge-test CHTE 01000000 --seconds 120`
   - Efficacy = amperage falls to about 0 (or slightly negative) while AC=true, within the run.
   - After the restore line, `$P battery` again: amperage positive again within ~30 s.
3. If CHTE is missing or has no effect: try `sudo $P charge-test CH0B 02 --seconds 120`, then the same with
   `CH0C`. Record the byte pattern that worked and the one(s) that did not.
4. **Interrupt check:** repeat the working command and press Ctrl-C at ~30 s. Expect the `restored` line, and
   `$P smc read <KEY>` shows the original bytes. This checks that an interrupted experiment restores the key.

## E3 — Adapter inhibit (for calibration; on AC)
1. `$P smc read CHIE CH0J` and record.
2. `sudo $P charge-test CHIE 08 --seconds 60` (or `CH0J 20` if CHIE is missing).
   - Efficacy = amperage clearly negative (discharging) while AC is still physically connected.
   - Note whether `ExternalConnected` changes.

## E4 — Fan control (on AC, idle)
1. Baseline: `$P smc read F0Md F1Md Ftst F0Tg F1Tg F0Ac F1Ac`. At rest on this machine F0Md = F1Md = `03` (measured 2026-10-07). `fan-test` restores each fan's original Md and Ftst bytes on exit; `fan-release` writes `00` unconditionally.
2. `sudo $P fan-test --rpm 4000 --seconds 30` — without unlock. Record success or the exact error.
3. `sudo $P fan-test --rpm 4000 --seconds 30 --unlock`. Record whether Ac follows Tg, how fast, and whether
   Md/Tg are rewritten by the system during the run.
4. After the release, watch `$P smc watch --interval 2 F0Md F0Tg F0Ac F1Ac Ftst` for 60 s: RPM returns to idle.
5. **Interrupt check:** repeat step 3 and press Ctrl-C at ~10 s; expect the release lines.
6. **Crash check:** repeat step 3, then from another terminal `sudo kill -9 $(pgrep fwprobe)`. Watch for 2
   minutes: does macOS reclaim the fans on its own? Then `sudo $P fan-release` and confirm. This decides
   how hard the helper's startup release has to work.
7. What does `00` mean? Run this in three terminals:
   - Terminal 1 (main): `sudo $P fan-release` (writes Md=00), then watch `$P smc watch --interval 2 F0Md F1Md F0Ac F1Ac` for 2 minutes.
   - Terminal 2 (load): `for i in $(seq 16); do yes > /dev/null & done; sleep 120; killall yes`
   - Terminal 3 (monitor temps): `$P temps --watch 5`

   Abort immediately if any `PMU tdie` sensor exceeds 95 °C, or if F0Ac/F1Ac read 0 while any tdie > 70 °C: run `sudo $P smc write F0Md 03` and `sudo $P smc write F1Md 03` and `killall yes`.

   Questions: does the system put Md back to `03` by itself, and do the fans respond to temperature rise? If Md stays `00` and the fans do not respond, record that. This determines ADR 0003 (which value means system control).
8. Record min/max RPM per fan, and the lowest RPM that actually spins (try `--rpm` at the reported minimum).

## E5 — Temperatures
1. `$P temps > docs/data/hid-temps-idle.txt` and `$P smc list T > docs/data/smc-temps-idle.txt`. Several HID services share a Product name (e.g. two `PMU tdie1`, six `gas gauge battery`); record every row, do not assume names are unique.
2. Load the CPU for 60 s in a second terminal (`for i in $(seq 16); do yes > /dev/null & done; sleep 60; killall yes`)
   while running `$P temps --watch 5` in the first terminal. Identify the sensors that rise fastest: CPU die candidates.
3. Run a game (or a GPU benchmark) with `$P temps --watch 5`: GPU die candidates.
4. Battery temperature: compare `$P battery` against `TB0T`/`TB1T`/`TB2T` and the HID battery sensors.

## E6 — IOReport power, clocks and sampling cost
1. `$P ioreport list > docs/data/ioreport-channels-m4max.txt`
2. `$P ioreport sample --seconds 10` idle, then again during a game. Record CPU/GPU/ANE/DRAM energy channel
   names, typical watts, and the performance-state channel names.
3. Clock tables (M1 maps performance states to MHz with these): `ioreg -rn pmgr -l | grep -E '"voltage-states[0-9]+(-sram)?"' > docs/data/pmgr-voltage-states.txt`
4. Cost: `$P ioreport sample --seconds 120 > /dev/null & sleep 60; ps -o %cpu,time -p $!` — record %CPU.
   The spec target for 1 Hz telemetry is < 1% CPU.

## E7 — Power modes
1. Record originals: `pmset -g custom > docs/data/pmset-custom-before.txt`
2. Query current mode: `pmset -g | grep powermode`
3. Switch to powermode 1: `sudo pmset -c powermode 1` (AC), check with `pmset -g`, then `sudo pmset -b powermode 1` (battery).
4. Switch to powermode 2: `sudo pmset -c powermode 2` (AC), check with `pmset -g`, then `sudo pmset -b powermode 2` (battery).
5. Restore originals: extract the powermode values from `docs/data/pmset-custom-before.txt` and restore with separate
   `sudo pmset -c powermode <value>` and `sudo pmset -b powermode <value>` commands.
6. Confirm: `pmset -g custom` should match the before snapshot. Record whether both modes switch, and whether AC/battery variants are distinct.

## E8 — FPS spike
1. `scripts/fps-spike.sh` then follow its prompt with a Metal game (and ARMSX2 if convenient).
2. Analyse `~/fps-spike-<timestamp>/metal.ndjson`: `grep -c . metal.ndjson`; inspect a few `eventMessage` values. Questions:
   - Are there periodic entries carrying FPS or frame time? How often (per frame, per second)?
   - Do they identify the process (`processImagePath`, `processID`)?
   - What does `~/fps-spike-<timestamp>/logstream-cpu.txt` show for the cost of `log stream`?
3. If nothing useful is logged: retry with `defaults write -g MetalForceHudEnabled -bool YES` (always run
   `defaults delete -g MetalForceHudEnabled` afterwards to undo) and with a capture from only the game's process:
   `log stream --process <pid> --level debug`. Record what was tried even if it failed.
