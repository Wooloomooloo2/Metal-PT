# fw-helper-mac

Battery charge limit, fan control, performance profiles, monitoring and an in-game overlay for
**Apple Silicon MacBooks**. The macOS sibling of [fw-helper](https://github.com/Wooloomooloo2/fw-helper)
(Linux) and [fw-helper-windows](https://github.com/Wooloomooloo2/fw-helper-windows).

> **Status: M0 — hardware baseline.** Nothing user-facing yet. `fwprobe` is a developer tool for
> measuring what this hardware exposes. See `docs/superpowers/specs/` for the design.

Built and tested on a MacBook Pro 16" M4 Max (Mac16,5), macOS 26.6.

## What Apple Silicon does not allow

There is no TDP / power-limit interface and no undervolting on Apple Silicon. fw-helper-mac will not
pretend otherwise. Performance modes are macOS's Low Power / Automatic / High Power modes.

## Build

    swift build
    swift test
    .build/debug/fwprobe            # usage

## License

GPL-3.0.
