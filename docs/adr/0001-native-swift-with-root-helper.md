# ADR 0001: Native Swift with a root helper

Date: 2026-10-05. Status: accepted.

## Context
Charge limiting and fan control need SMC writes, which need root. Telemetry (IOReport, SMC reads,
IOHID temperatures) does not. AlDente's CPU cost is the main reason for this project.

## Decision
One Swift codebase: `FWCore` library, `fwhelperd` root LaunchDaemon registered with `SMAppService`,
an unprivileged SwiftUI menu-bar app, and `fwhelperctl`. The helper owns every SMC write and persists
without the app; the app reads telemetry itself. XPC clients must match the author's Team ID.

## Alternatives rejected
- Rust core + Swift UI (reuse fw-helper idioms): FFI and two toolchains for little shared code.
- Helper installed by a sudo script: no supported update/uninstall path.

## Consequences
Telemetry works without the helper. A helper crash must leave hardware safe: it releases fans on start.
