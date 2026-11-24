# ADR 0003: Rename to Metal-PT and split into two apps

Date: 2026-11-24. Status: accepted.

## Context
The project began as fw-helper-mac, a sibling of fw-helper (Linux) and fw-helper-windows, centred on battery and fan
control through a root helper. The benchmarking work (ADR 0002) turned out to be the part other people want: comparing
game performance across Mac translation stacks. The author cannot obtain an Apple Developer Program membership (the
address check rejects a house name with no number), so there is no Developer ID. An unsigned or ad-hoc app can still
be shipped and approved once via System Settings, but a root helper cannot be trusted or distributed sensibly that way.

## Decision
- Rename the project **Metal-PT** (Metal Performance Telemetry). Package `metal-pt`; library `MPTCore`; CLI `mpt`;
  dev tool `mptprobe`; run folders `*.mptrun`; data root `~/Documents/Metal-PT/`; HTML meta `mpt-run`.
- Two apps from one repo: **Metal-PT** (telemetry, recording, compare, export; no root, no helper) and
  **Metal-PT Helper** (charge limit and fans via a root helper; built later, runs on the author's Mac first).
- Licence: GPL-3.0. Repo: https://github.com/Wooloomooloo2/Metal-PT.
- Run bundle `schema` stays 1; there is no migration of `.fwrun` folders (none exist outside development).
- Historical specs, plans and ADRs keep the old names; they are records.

## Consequences
Metal-PT can be shared without Developer ID and never needs privilege. The Helper's safety rules (fan lease,
recovery reads hardware, battery policy) still apply to it unchanged. Anything using the old names (`fwbench`,
`.fwrun`, `FWCore`) must be updated by hand; the CLI's default data root changed from `~/Documents/FW Benchmark`.
