# M0 Hardware Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `fwprobe`, a probe CLI on top of a tested `FWCore` read layer, and use it to measure — on this MacBook Pro 16" M4 Max, macOS 26.6 — which SMC keys control charging and fans, which sensors and IOReport channels exist, and whether Metal HUD logging can supply live FPS. Record the results so M1–M7 can be planned from facts.

**Architecture:** A SwiftPM package. `CMacPrivate` (C target) declares the AppleSMC parameter struct and the private IOReport / IOHIDEvent functions. `FWCore` (Swift library) wraps them: FourCC and SMC value decoding, SMC connection, battery snapshot, IOReport sampler, HID temperatures, and a `Lease` that guarantees restore-on-exit. `fwprobe` (executable) exposes read commands unprivileged and write experiments under `sudo`, every write inside a `Lease`. Pure logic is unit-tested with Swift Testing; hardware behaviour is measured by the human-assisted experiments in Task 10.

**Tech Stack:** Swift 6.3 (Xcode 26.5), SwiftPM, Swift Testing, IOKit, CoreFoundation, private `libIOReport`, private IOHIDEvent API, bash scripts, macOS `log stream`.

**Spec:** `docs/superpowers/specs/2026-10-05-fw-helper-mac-design.md` (§4 M0 is what this plan implements; §1 platform table and success criteria; §2 fan lease).

**Scope note:** This plan is M0 only. M1–M7 each get their own plan, written after Task 10 records the measured facts, because the charge key, fan unlock sequence, sensor names and FPS source are unknown until then.

## Global Constraints

- swift-tools-version 6.0, Swift 6 language mode, `platforms: [.macOS(.v15)]`; built with Xcode 26.5, tested on macOS 26.6.
- No third-party dependencies.
- License GPL-3.0 (same as the sibling repos).
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), run with `swift test`. No test touches real hardware.
- **Every SMC write in `fwprobe` is made inside a `Lease` that restores the previous value** on normal exit, error, SIGINT, SIGTERM and SIGHUP. The one exception is `fwprobe smc write`, a manual tool that prints the restore command.
- **Read-back is not efficacy.** A key that reads back what was written proves nothing; record the effect (battery current, RPM).
- Hardware facts go in `docs/hardware-baseline.md` tagged `[M]` (measured on this machine, with date) or `[?]` (from external sources, unverified).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Probe interrupted mid-experiment** (Ctrl-C, terminal closed, `kill`): the SMC key or fan mode is restored before exit. Pinned by `LeaseTests` (Task 5) and the interrupt steps in Task 10 E2/E4.
2. **Write attempted without `sudo`:** a clear "needs sudo" error before anything is written. Pinned by Task 5 Step 7 and Task 6 Step 4.
3. **IORegistry reports a negative battery current as a huge unsigned number** (−1550 mA appears as 18446744073709550066): shown as −1550. Pinned by `BatterySnapshotTests` (Task 4).
4. **An SMC key exists but has a different size than the experiment assumed** (e.g. `CHTE` is not 4 bytes on this firmware): the write is refused with `sizeMismatch`, nothing is written. Pinned by `SMCKeyInfoTests` (Task 2).
5. **Zero-length sample interval or all-zero state residency:** no NaN/inf, nothing printed for that channel. Pinned by `PowerMathTests` (Task 7).

---

## File Structure

```
Package.swift
.gitignore
LICENSE                                   GPL-3.0 text
README.md                                 what the project is, status
CLAUDE.md                                 living context: hard rules, traps, resume here
Sources/CMacPrivate/include/CMacPrivate.h umbrella header
Sources/CMacPrivate/include/smc.h         AppleSMC param struct + csmc_open/csmc_call
Sources/CMacPrivate/include/ioreport.h    private libIOReport declarations
Sources/CMacPrivate/include/hid_private.h private IOHIDEvent declarations
Sources/CMacPrivate/smc.c                 csmc_open, csmc_call
Sources/FWCore/SMC/FourCC.swift           four-character codes
Sources/FWCore/SMC/Hex.swift              hex encode/decode
Sources/FWCore/SMC/SMCValue.swift         typed decoding of SMC bytes, float encoding
Sources/FWCore/SMC/SMCTypes.swift         SMCError, SMCKeyInfo (+ write size check)
Sources/FWCore/SMC/SMCConnection.swift    IOKit connection: keyInfo/read/write/enumerate
Sources/FWCore/Battery/BatterySnapshot.swift      pure parse of AppleSmartBattery properties
Sources/FWCore/Battery/SmartBatteryReader.swift   IORegistry read
Sources/FWCore/Support/Lease.swift        restore-exactly-once, signal-safe
Sources/FWCore/Power/PowerMath.swift      energy units → watts, residency shares (pure)
Sources/FWCore/Power/IOReportSampler.swift        subscription, samples, deltas
Sources/FWCore/Sensors/HIDTemperatureReader.swift temperature sensors via IOHIDEvent
Sources/fwprobe/main.swift                command dispatch
Sources/fwprobe/Support.swift             ProbeError, option parsing, root check
Sources/fwprobe/SMCCommands.swift         smc list/read/watch/write
Sources/fwprobe/BatteryCommands.swift     battery, charge-test
Sources/fwprobe/FanCommands.swift         fan-test, fan-release
Sources/fwprobe/PowerCommands.swift       ioreport list/sample, temps
Tests/FWCoreTests/FourCCTests.swift
Tests/FWCoreTests/SMCValueTests.swift
Tests/FWCoreTests/SMCKeyInfoTests.swift
Tests/FWCoreTests/BatterySnapshotTests.swift
Tests/FWCoreTests/LeaseTests.swift
Tests/FWCoreTests/PowerMathTests.swift
scripts/aldente-ids.sh
scripts/fps-spike.sh
docs/m0-test-plan.md                      the experiments, step by step
docs/hardware-baseline.md                 measured facts (written in Task 10)
docs/adr/0001-native-swift-with-root-helper.md
docs/adr/0002..0004                        written in Task 10 from results
```

---

### Task 1: Repository scaffold and FourCC

**Files:**
- Create: `Package.swift`, `.gitignore`, `LICENSE`, `README.md`, `CLAUDE.md`, `docs/adr/0001-native-swift-with-root-helper.md`
- Create: `Sources/FWCore/SMC/FourCC.swift`
- Test: `Tests/FWCoreTests/FourCCTests.swift`

**Interfaces:**
- Produces: `public struct FourCC: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral` with `rawValue: UInt32`, `init(rawValue: UInt32)`, `init?(string: String)`, `init(stringLiteral:)` (traps on invalid), `description: String`.

- [ ] **Step 1: Write Package.swift (library + tests only for now)**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fw-helper-mac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FWCore", targets: ["FWCore"]),
    ],
    targets: [
        .target(name: "FWCore"),
        .testTarget(name: "FWCoreTests", dependencies: ["FWCore"]),
    ]
)
```

- [ ] **Step 2: Write .gitignore, LICENSE, README.md, CLAUDE.md, ADR 0001**

`.gitignore`:
```
.build/
.swiftpm/
DerivedData/
xcuserdata/
.DS_Store
```

`LICENSE`: copy the GPL-3.0 text from the sibling repo:
```bash
curl -fsSL https://raw.githubusercontent.com/Wooloomooloo2/fw-helper/main/LICENSE -o LICENSE
head -2 LICENSE   # expect: GNU GENERAL PUBLIC LICENSE / Version 3, 29 June 2007
```

`README.md`:
```markdown
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
```

`CLAUDE.md`:
```markdown
# CLAUDE.md

Living context for this repository. **Update "Current state" and "Resume here" at the end of every session.**

## What this is

macOS (Apple Silicon) sibling of fw-helper / fw-helper-windows. Design: `docs/superpowers/specs/2026-10-05-fw-helper-mac-design.md`.
Plans: `docs/superpowers/plans/`. Measured hardware facts: `docs/hardware-baseline.md`.
**Do not re-derive hardware facts — they are measured and recorded.**

## Commands

    swift build
    swift test                      # unit tests, no hardware
    .build/debug/fwprobe ...        # read commands work unprivileged
    sudo .build/debug/fwprobe ...   # write experiments (charge-test, fan-test, fan-release, smc write)

## Hard rules

1. **Fan control is a lease.** Every path that takes the fans must have a matching hand-back to system control.
2. **Recovery reads hardware, not flags.** Release writes "auto" even if we believe we never took the fans.
3. **Read-back is not efficacy.** Verify the effect (battery current 0, RPM change), and record the evidence.
4. **SMC keys and byte layouts come from measurement on this machine** (`docs/hardware-baseline.md`), never from forum posts alone.
5. **No TDP, power-limit or undervolt features.** Apple Silicon has no such interface.
6. The app never runs as root. Only the helper (`fwhelperd`, from M2) writes the SMC. `fwprobe` is a dev tool.
7. Record decisions as ADRs in `docs/adr/`; hardware facts in `docs/hardware-baseline.md` tagged `[M]` or `[?]`.

## Traps

- SMC integer types (`ui16`, `ui32`) are big-endian, but `flt ` is little-endian on Apple Silicon. Some keys
  (`CHTE`) are written by other tools as `01 00 00 00`, which does not fit a big-endian reading. Write raw bytes,
  and record exactly which bytes worked.
- IORegistry stores signed battery values as unsigned 64-bit: −1550 mA reads as 18446744073709550066.
- AlDente writes the same charge keys. Quit it (and confirm its helper is not rewriting them) before any charge experiment.

## Current state

M0 in progress — see `docs/superpowers/plans/2026-10-07-m0-hardware-baseline.md`.

## Resume here

Continue the M0 plan at the first unchecked task.
```

`docs/adr/0001-native-swift-with-root-helper.md`:
```markdown
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
```

- [ ] **Step 3: Write the failing test**

`Tests/FWCoreTests/FourCCTests.swift`:
```swift
import Testing
@testable import FWCore

@Suite struct FourCCTests {
    @Test func encodesBigEndian() {
        #expect(FourCC("#KEY").rawValue == 0x234B_4559)
    }

    @Test func keepsTrailingSpace() {
        #expect(FourCC("flt ").description == "flt ")
    }

    @Test func decodesRawValue() {
        #expect(FourCC(rawValue: 0x4630_4163).description == "F0Ac")
    }

    @Test func rejectsWrongLength() {
        #expect(FourCC(string: "F0A") == nil)
        #expect(FourCC(string: "F0Acc") == nil)
    }

    @Test func rejectsNonASCII() {
        #expect(FourCC(string: "F0é") == nil)   // 4 UTF-8 bytes, but not printable ASCII
    }

    @Test func buildsFromInterpolatedString() {
        let index = 1
        #expect(FourCC(string: "F\(index)Md") == FourCC("F1Md"))
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `swift test`
Expected: compile error — `cannot find 'FourCC' in scope`.

- [ ] **Step 5: Write the implementation**

`Sources/FWCore/SMC/FourCC.swift`:
```swift
/// A four-character code such as an SMC key (`F0Ac`) or SMC data type (`flt `), packed big-endian.
public struct FourCC: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// nil unless `string` is exactly four printable ASCII characters.
    public init?(string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public init(stringLiteral value: String) {
        guard let code = FourCC(string: value) else { preconditionFailure("not a four-character code: \(value)") }
        self = code
    }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((rawValue >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test`
Expected: `Test run with 6 tests passed`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift .gitignore LICENSE README.md CLAUDE.md docs/adr Sources Tests
git commit -m "Scaffold package with FourCC, license, README, CLAUDE.md, ADR 0001

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: SMC value decoding, hex, key info

**Files:**
- Create: `Sources/FWCore/SMC/Hex.swift`, `Sources/FWCore/SMC/SMCValue.swift`, `Sources/FWCore/SMC/SMCTypes.swift`
- Test: `Tests/FWCoreTests/SMCValueTests.swift`, `Tests/FWCoreTests/SMCKeyInfoTests.swift`

**Interfaces:**
- Consumes: `FourCC` (Task 1).
- Produces:
  - `public enum Hex { static func encode(_ bytes: [UInt8]) -> String; static func decode(_ text: String) -> [UInt8]? }` — encode gives `"01 00 00 00"`; decode accepts `"01000000"` or `"01 00 00 00"`, nil on empty/odd/non-hex.
  - `public struct SMCValue: Equatable, Sendable { key: FourCC; type: FourCC; bytes: [UInt8]; var number: Double?; var hex: String; static func encodeFloat(_ value: Float) -> [UInt8] }`
  - `public enum SMCError: Error, Equatable { case serviceNotFound, openFailed(Int32), callFailed(Int32), notPrivileged, keyNotFound(FourCC), smcResult(UInt8), sizeMismatch(key: FourCC, expected: Int, got: Int) }`
  - `public struct SMCKeyInfo: Equatable, Sendable { size: Int; type: FourCC; func checkWrite(key: FourCC, bytes: [UInt8]) throws }`

- [ ] **Step 1: Write the failing tests**

`Tests/FWCoreTests/SMCValueTests.swift`:
```swift
import Testing
@testable import FWCore

@Suite struct SMCValueTests {
    func value(_ type: FourCC, _ bytes: [UInt8]) -> SMCValue {
        SMCValue(key: "TEST", type: type, bytes: bytes)
    }

    @Test func floatIsLittleEndian() {
        // 42.5 = 0x422A0000
        #expect(value("flt ", [0x00, 0x00, 0x2A, 0x42]).number == 42.5)
    }

    @Test func unsignedIntegersAreBigEndian() {
        #expect(value("ui8 ", [0x02]).number == 2)
        #expect(value("ui16", [0x01, 0x02]).number == 258)
        #expect(value("ui32", [0x00, 0x00, 0x01, 0x2C]).number == 300)
    }

    @Test func signedFixedPoint() {
        #expect(value("sp78", [0x1E, 0x80]).number == 30.5)
        #expect(value("sp78", [0xFF, 0x00]).number == -1.0)
        #expect(value("fpe2", [0x1F, 0x40]).number == 2000)
    }

    @Test func signedIntegers() {
        #expect(value("si8 ", [0xFF]).number == -1)
        #expect(value("si16", [0xFF, 0xFE]).number == -2)
    }

    @Test func flag() {
        #expect(value("flag", [0x01]).number == 1)
    }

    @Test func unknownTypeHasNoNumber() {
        #expect(value("hex_", [0x01]).number == nil)
    }

    @Test func wrongByteCountHasNoNumber() {
        #expect(value("ui16", [0x01]).number == nil)
        #expect(value("flt ", [0x00, 0x00]).number == nil)
    }

    @Test func encodeFloatRoundTrips() {
        let bytes = SMCValue.encodeFloat(2500)
        #expect(bytes.count == 4)
        #expect(value("flt ", bytes).number == 2500)
    }

    @Test func hexEncodes() {
        #expect(value("ui32", [0x01, 0x00, 0x00, 0x00]).hex == "01 00 00 00")
    }

    @Test func hexDecodes() {
        #expect(Hex.decode("01000000") == [0x01, 0x00, 0x00, 0x00])
        #expect(Hex.decode("01 0a FF") == [0x01, 0x0A, 0xFF])
    }

    @Test func hexRejectsBadInput() {
        #expect(Hex.decode("") == nil)
        #expect(Hex.decode("010") == nil)
        #expect(Hex.decode("zz") == nil)
    }
}
```

`Tests/FWCoreTests/SMCKeyInfoTests.swift`:
```swift
import Testing
@testable import FWCore

@Suite struct SMCKeyInfoTests {
    @Test func acceptsMatchingSize() throws {
        try SMCKeyInfo(size: 4, type: "ui32").checkWrite(key: "CHTE", bytes: [1, 0, 0, 0])
    }

    @Test func refusesSizeMismatch() {
        #expect(throws: SMCError.sizeMismatch(key: "CHTE", expected: 1, got: 4)) {
            try SMCKeyInfo(size: 1, type: "ui8 ").checkWrite(key: "CHTE", bytes: [1, 0, 0, 0])
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile errors — `cannot find 'SMCValue'`, `'Hex'`, `'SMCKeyInfo'` in scope.

- [ ] **Step 3: Write the implementation**

`Sources/FWCore/SMC/Hex.swift`:
```swift
import Foundation

public enum Hex {
    /// `[0x01, 0x00]` → `"01 00"`.
    public static func encode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Accepts `"0100"` or `"01 00"`; nil if empty, odd-length or not hex.
    public static func decode(_ text: String) -> [UInt8]? {
        let digits = Array(text.filter { !$0.isWhitespace })
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}
```

`Sources/FWCore/SMC/SMCValue.swift`:
```swift
/// Raw bytes of one SMC key plus a best-effort numeric reading.
///
/// Integer and fixed-point types are big-endian; `flt ` is little-endian on Apple Silicon.
public struct SMCValue: Equatable, Sendable {
    public let key: FourCC
    public let type: FourCC
    public let bytes: [UInt8]

    public init(key: FourCC, type: FourCC, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.bytes = bytes
    }

    public var number: Double? {
        switch type.description {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: littleEndian(bytes))))
        case "ui8 ", "flag":
            guard bytes.count == 1 else { return nil }
            return Double(bytes[0])
        case "ui16":
            guard bytes.count == 2 else { return nil }
            return Double(bigEndian(bytes))
        case "ui32":
            guard bytes.count == 4 else { return nil }
            return Double(bigEndian(bytes))
        case "ui64":
            guard bytes.count == 8 else { return nil }
            return Double(bigEndian(bytes))
        case "si8 ":
            guard bytes.count == 1 else { return nil }
            return Double(Int8(bitPattern: bytes[0]))
        case "si16":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bigEndian(bytes))))
        case "sp78":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bigEndian(bytes)))) / 256
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            return Double(bigEndian(bytes)) / 4
        default:
            return nil
        }
    }

    public var hex: String { Hex.encode(bytes) }

    /// Bytes for writing a `flt ` key (e.g. a fan target RPM).
    public static func encodeFloat(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }
}

private func bigEndian(_ bytes: [UInt8]) -> UInt64 {
    bytes.reduce(0) { ($0 << 8) | UInt64($1) }
}

private func littleEndian(_ bytes: [UInt8]) -> UInt64 {
    bytes.reversed().reduce(0) { ($0 << 8) | UInt64($1) }
}
```

`Sources/FWCore/SMC/SMCTypes.swift`:
```swift
public enum SMCError: Error, Equatable {
    case serviceNotFound
    case openFailed(Int32)
    case callFailed(Int32)
    case notPrivileged
    case keyNotFound(FourCC)
    case smcResult(UInt8)
    case sizeMismatch(key: FourCC, expected: Int, got: Int)
}

public struct SMCKeyInfo: Equatable, Sendable {
    public let size: Int
    public let type: FourCC

    public init(size: Int, type: FourCC) {
        self.size = size
        self.type = type
    }

    /// Refuses a write whose length does not match the key's declared size.
    public func checkWrite(key: FourCC, bytes: [UInt8]) throws {
        guard bytes.count == size else {
            throw SMCError.sizeMismatch(key: key, expected: size, got: bytes.count)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (6 FourCC + 11 SMCValue + 2 SMCKeyInfo = 19).

- [ ] **Step 5: Commit**

```bash
git add Sources/FWCore/SMC Tests/FWCoreTests
git commit -m "Add SMC value decoding, hex helpers and write size check

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: SMC connection and `fwprobe smc list/read`

**Files:**
- Create: `Sources/CMacPrivate/include/CMacPrivate.h`, `Sources/CMacPrivate/include/smc.h`, `Sources/CMacPrivate/smc.c`
- Create: `Sources/FWCore/SMC/SMCConnection.swift`
- Create: `Sources/fwprobe/main.swift`, `Sources/fwprobe/Support.swift`, `Sources/fwprobe/SMCCommands.swift`
- Modify: `Package.swift` (full replacement below)

**Interfaces:**
- Consumes: `FourCC`, `SMCValue`, `SMCKeyInfo`, `SMCError` (Tasks 1–2).
- Produces:
  - C: `CSMCParam` (80-byte struct), `kern_return_t csmc_open(io_connect_t *connection)`, `kern_return_t csmc_call(io_connect_t, const CSMCParam *, CSMCParam *)`, constants `kCSMCCmdReadBytes`, `kCSMCCmdWriteBytes`, `kCSMCCmdReadIndex`, `kCSMCCmdReadKeyInfo`, `kCSMCNotPrivileged`, `kCSMCNotFound`.
  - `public final class SMCConnection { init() throws; func keyInfo(_ key: FourCC) throws -> SMCKeyInfo; func read(_ key: FourCC) throws -> SMCValue; func write(_ key: FourCC, bytes: [UInt8]) throws; func keyCount() throws -> Int; func key(at index: Int) throws -> FourCC }`
  - fwprobe: `struct ProbeError: Error, CustomStringConvertible { init(_ description: String) }`, `func option(_ name: String, in args: [String]) -> String?`, `func positional(_ args: [String]) -> [String]`, `func requireRoot() throws`, `enum SMCCommands { static func run(_ args: [String]) throws; static func smcKey(_ text: String) throws -> FourCC; static func line(_ value: SMCValue) -> String }`.

This task talks to hardware, so it is verified by running the probe rather than by unit tests.

- [ ] **Step 1: Replace Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fw-helper-mac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FWCore", targets: ["FWCore"]),
        .executable(name: "fwprobe", targets: ["fwprobe"]),
    ],
    targets: [
        .target(
            name: "CMacPrivate",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("IOReport"),
            ]
        ),
        .target(name: "FWCore", dependencies: ["CMacPrivate"]),
        .executableTarget(name: "fwprobe", dependencies: ["FWCore"]),
        .testTarget(name: "FWCoreTests", dependencies: ["FWCore"]),
    ]
)
```

- [ ] **Step 2: Write the C bridge**

`Sources/CMacPrivate/include/CMacPrivate.h`:
```c
#ifndef CMACPRIVATE_H
#define CMACPRIVATE_H
#include "smc.h"
#endif
```

`Sources/CMacPrivate/include/smc.h`:
```c
#ifndef CMACPRIVATE_SMC_H
#define CMACPRIVATE_SMC_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

// AppleSMC user client. Layout matches the kernel's SMCParamStruct (80 bytes).
static const uint32_t kCSMCHandleYPCEvent = 2;
static const uint8_t kCSMCCmdReadBytes = 5;
static const uint8_t kCSMCCmdWriteBytes = 6;
static const uint8_t kCSMCCmdReadIndex = 8;
static const uint8_t kCSMCCmdReadKeyInfo = 9;
static const kern_return_t kCSMCNotPrivileged = (kern_return_t)0xE00002C1; // kIOReturnNotPrivileged
static const kern_return_t kCSMCNotFound = (kern_return_t)0xE00002F0;      // kIOReturnNotFound

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} CSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} CSMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} CSMCKeyInfo;

typedef struct {
    uint32_t key;
    CSMCVersion vers;
    CSMCPLimitData pLimitData;
    CSMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} CSMCParam;

_Static_assert(sizeof(CSMCParam) == 80, "AppleSMC expects an 80-byte parameter struct");

/// Opens the AppleSMC user client. Returns kCSMCNotFound if there is no AppleSMC service.
kern_return_t csmc_open(io_connect_t *connection);

/// One SMC command round trip.
kern_return_t csmc_call(io_connect_t connection, const CSMCParam *input, CSMCParam *output);

#endif
```

`Sources/CMacPrivate/smc.c`:
```c
#include "smc.h"

kern_return_t csmc_open(io_connect_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) {
        return kCSMCNotFound;
    }
    // mach_task_self() is a macro over a global Swift 6 rejects, so the open lives in C.
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}

kern_return_t csmc_call(io_connect_t connection, const CSMCParam *input, CSMCParam *output) {
    size_t outputSize = sizeof(CSMCParam);
    return IOConnectCallStructMethod(connection, kCSMCHandleYPCEvent,
                                     input, sizeof(CSMCParam), output, &outputSize);
}
```

- [ ] **Step 3: Write SMCConnection**

`Sources/FWCore/SMC/SMCConnection.swift`:
```swift
import CMacPrivate
import IOKit

/// A connection to the AppleSMC user client. Reads work unprivileged; writes need root.
/// Not thread-safe: use one connection per thread.
public final class SMCConnection {
    private var connection: io_connect_t = 0

    public init() throws {
        let result = csmc_open(&connection)
        if result == kCSMCNotFound { throw SMCError.serviceNotFound }
        guard result == KERN_SUCCESS else { throw SMCError.openFailed(result) }
    }

    deinit {
        IOServiceClose(connection)
    }

    public func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        var input = CSMCParam()
        input.key = key.rawValue
        input.data8 = kCSMCCmdReadKeyInfo
        let output = try call(&input, key: key)
        return SMCKeyInfo(size: Int(output.keyInfo.dataSize), type: FourCC(rawValue: output.keyInfo.dataType))
    }

    public func read(_ key: FourCC) throws -> SMCValue {
        let info = try keyInfo(key)
        var input = CSMCParam()
        input.key = key.rawValue
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = kCSMCCmdReadBytes
        let output = try call(&input, key: key)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(info.size)) }
        return SMCValue(key: key, type: info.type, bytes: bytes)
    }

    public func write(_ key: FourCC, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        try info.checkWrite(key: key, bytes: bytes)
        var input = CSMCParam()
        input.key = key.rawValue
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = kCSMCCmdWriteBytes
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        _ = try call(&input, key: key)
    }

    public func keyCount() throws -> Int {
        Int(try read("#KEY").number ?? 0)
    }

    public func key(at index: Int) throws -> FourCC {
        var input = CSMCParam()
        input.data8 = kCSMCCmdReadIndex
        input.data32 = UInt32(index)
        return FourCC(rawValue: try call(&input, key: nil).key)
    }

    private func call(_ input: inout CSMCParam, key: FourCC?) throws -> CSMCParam {
        var output = CSMCParam()
        let result = csmc_call(connection, &input, &output)
        if result == kCSMCNotPrivileged { throw SMCError.notPrivileged }
        guard result == KERN_SUCCESS else { throw SMCError.callFailed(result) }
        switch output.result {
        case 0: return output
        case 0x84: throw key.map { SMCError.keyNotFound($0) } ?? SMCError.smcResult(0x84)
        default: throw SMCError.smcResult(output.result)
        }
    }
}
```

- [ ] **Step 4: Write fwprobe support, smc commands and main**

`Sources/fwprobe/Support.swift`:
```swift
import Foundation

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Value following `name` (e.g. `--seconds 60`), or nil.
func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

/// Arguments that are neither `--flags` nor the value of a `--flag value` pair.
/// Flags that take no value (`--unlock`) must not be followed by a positional.
func positional(_ args: [String]) -> [String] {
    var result: [String] = []
    var skipNext = false
    for (index, arg) in args.enumerated() {
        if skipNext { skipNext = false; continue }
        if arg.hasPrefix("--") {
            let next = index + 1 < args.count ? args[index + 1] : nil
            skipNext = next.map { !$0.hasPrefix("--") && Double($0) != nil } ?? false
            continue
        }
        result.append(arg)
    }
    return result
}

func requireRoot() throws {
    guard getuid() == 0 else { throw ProbeError("this command writes the SMC: run it with sudo") }
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}
```

`Sources/fwprobe/SMCCommands.swift`:
```swift
import Foundation
import FWCore

enum SMCCommands {
    static let usage = """
        fwprobe smc list [PREFIX]                 every key (or keys starting with PREFIX): type, size, bytes, value
        fwprobe smc read KEY...                   read keys
        fwprobe smc watch [--interval S] KEY...   print keys and battery state every S seconds (default 5)
        """

    static func run(_ args: [String]) throws {
        let smc = try SMCConnection()
        let rest = Array(args.dropFirst())
        switch args.first {
        case "list":
            try list(smc, prefix: rest.first)
        case "read":
            guard !rest.isEmpty else { throw ProbeError(usage) }
            for name in rest { print(describe(smc, try smcKey(name))) }
        default:
            throw ProbeError(usage)
        }
    }

    static func smcKey(_ text: String) throws -> FourCC {
        guard let key = FourCC(string: text) else { throw ProbeError("not a four-character SMC key: '\(text)'") }
        return key
    }

    static func line(_ value: SMCValue) -> String {
        let number = value.number.map { "  = \($0)" } ?? ""
        return "\(value.key)  [\(value.type)] \(value.bytes.count)B  \(value.hex)\(number)"
    }

    static func describe(_ smc: SMCConnection, _ key: FourCC) -> String {
        do { return line(try smc.read(key)) } catch { return "\(key)  <\(error)>" }
    }

    private static func list(_ smc: SMCConnection, prefix: String?) throws {
        let count = try smc.keyCount()
        print("# \(count) keys")
        for index in 0..<count {
            let key = try smc.key(at: index)
            if let prefix, !key.description.hasPrefix(prefix) { continue }
            print(describe(smc, key))
        }
    }
}
```

`Sources/fwprobe/main.swift`:
```swift
import Foundation
import FWCore

let usage = """
    fwprobe — M0 hardware probe for fw-helper-mac. Write commands need sudo.

    \(SMCCommands.usage)
    """

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "smc":
        try SMCCommands.run(Array(args.dropFirst()))
    default:
        print(usage)
        exit(args.isEmpty ? 0 : 64)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
```

- [ ] **Step 5: Build and run unit tests**

Run: `swift build && swift test`
Expected: build succeeds (the `_Static_assert` passes); 19 tests pass.

- [ ] **Step 6: Verify against the hardware (unprivileged)**

Run: `.build/debug/fwprobe smc read '#KEY' FNum F0Ac F0Mn F0Mx`
Expected: `#KEY [ui32] 4B ... = <a few thousand>`, `FNum ... = 2` (two fans on the 16"), `F0Ac [flt ] ... = <RPM>`. If `F0Ac` reports `keyNotFound`, record that; do not guess another key here.

Run: `.build/debug/fwprobe smc read ZZZZ`
Expected: `ZZZZ  <keyNotFound(ZZZZ)>`, exit 0.

Run: `.build/debug/fwprobe smc list F | head -40`
Expected: `# N keys` then F-keys with types and values.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources
git commit -m "Add AppleSMC bridge, SMCConnection and fwprobe smc list/read

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Battery snapshot, `fwprobe battery` and `smc watch`

**Files:**
- Create: `Sources/FWCore/Battery/BatterySnapshot.swift`, `Sources/FWCore/Battery/SmartBatteryReader.swift`
- Create: `Sources/fwprobe/BatteryCommands.swift`
- Modify: `Sources/fwprobe/SMCCommands.swift` (add `watch`), `Sources/fwprobe/main.swift` (add `battery`)
- Test: `Tests/FWCoreTests/BatterySnapshotTests.swift`

**Interfaces:**
- Consumes: `SMCConnection`, `SMCCommands.describe` (Task 3), `option`, `positional`, `timestamp` (Task 3).
- Produces:
  - `public struct BatterySnapshot: Equatable, Sendable { percent: Int?; isCharging: Bool?; externalConnected: Bool?; fullyCharged: Bool?; amperageMilliamps: Int64?; voltageMillivolts: Int64?; temperatureCelsius: Double?; init(properties: [String: Any]); var summary: String }`
  - `public enum SmartBatteryReader { static func read() throws -> BatterySnapshot }`, `public enum BatteryReadError: Error { case serviceNotFound, readFailed(Int32) }`
  - `enum BatteryCommands { static func run(_ args: [String]) throws }` (Task 5 extends it with `chargeTest`).

- [ ] **Step 1: Write the failing test**

`Tests/FWCoreTests/BatterySnapshotTests.swift`:
```swift
import Foundation
import Testing
@testable import FWCore

@Suite struct BatterySnapshotTests {
    @Test func parsesDischargingBattery() {
        // As IORegistry reports it: signed values stored as unsigned 64-bit.
        let snapshot = BatterySnapshot(properties: [
            "CurrentCapacity": 56,
            "IsCharging": false,
            "ExternalConnected": false,
            "FullyCharged": false,
            "InstantAmperage": UInt64(18_446_744_073_709_550_066),
            "Amperage": UInt64(18_446_744_073_709_550_066),
            "Voltage": 12_600,
            "Temperature": 2954,
        ])
        #expect(snapshot.percent == 56)
        #expect(snapshot.isCharging == false)
        #expect(snapshot.externalConnected == false)
        #expect(snapshot.amperageMilliamps == -1550)
        #expect(snapshot.voltageMillivolts == 12_600)
        #expect(snapshot.temperatureCelsius == 29.54)
    }

    @Test func acceptsSignedAmperage() {
        let snapshot = BatterySnapshot(properties: ["InstantAmperage": Int64(-1550)])
        #expect(snapshot.amperageMilliamps == -1550)
    }

    @Test func fallsBackToAmperage() {
        let snapshot = BatterySnapshot(properties: ["Amperage": 2100])
        #expect(snapshot.amperageMilliamps == 2100)
    }

    @Test func missingKeysAreNil() {
        let snapshot = BatterySnapshot(properties: [:])
        #expect(snapshot.percent == nil)
        #expect(snapshot.amperageMilliamps == nil)
        #expect(snapshot.temperatureCelsius == nil)
        #expect(!snapshot.summary.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: compile error — `cannot find 'BatterySnapshot' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/FWCore/Battery/BatterySnapshot.swift`:
```swift
import Foundation

/// The AppleSmartBattery fields that matter for charge control, parsed from IORegistry properties.
public struct BatterySnapshot: Equatable, Sendable {
    public let percent: Int?
    public let isCharging: Bool?
    public let externalConnected: Bool?
    public let fullyCharged: Bool?
    /// Positive while charging, negative while discharging.
    public let amperageMilliamps: Int64?
    public let voltageMillivolts: Int64?
    public let temperatureCelsius: Double?

    public init(properties: [String: Any]) {
        percent = Self.integer(properties["CurrentCapacity"]).map { Int($0) }
        isCharging = properties["IsCharging"] as? Bool
        externalConnected = properties["ExternalConnected"] as? Bool
        fullyCharged = properties["FullyCharged"] as? Bool
        amperageMilliamps = Self.integer(properties["InstantAmperage"]) ?? Self.integer(properties["Amperage"])
        voltageMillivolts = Self.integer(properties["Voltage"])
        temperatureCelsius = Self.integer(properties["Temperature"]).map { Double($0) / 100 }
    }

    /// IORegistry stores signed values as unsigned 64-bit; reinterpret the bits.
    static func integer(_ value: Any?) -> Int64? {
        (value as? NSNumber).map { Int64(bitPattern: $0.uint64Value) }
    }

    public var summary: String {
        func text<T>(_ value: T?, _ suffix: String = "") -> String { value.map { "\($0)\(suffix)" } ?? "?" }
        return "\(text(percent, "%"))  \(text(amperageMilliamps, " mA"))  \(text(voltageMillivolts, " mV"))  "
            + "\(text(temperatureCelsius, " °C"))  AC=\(text(externalConnected))  charging=\(text(isCharging))  "
            + "full=\(text(fullyCharged))"
    }
}
```

`Sources/FWCore/Battery/SmartBatteryReader.swift`:
```swift
import Foundation
import IOKit

public enum BatteryReadError: Error {
    case serviceNotFound
    case readFailed(Int32)
}

public enum SmartBatteryReader {
    public static func read() throws -> BatterySnapshot {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { throw BatteryReadError.serviceNotFound }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            throw BatteryReadError.readFailed(result)
        }
        return BatterySnapshot(properties: dictionary)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: 23 tests pass.

- [ ] **Step 5: Add `fwprobe battery` and `smc watch`**

`Sources/fwprobe/BatteryCommands.swift`:
```swift
import Foundation
import FWCore

enum BatteryCommands {
    static let usage = """
        fwprobe battery                           battery state from AppleSmartBattery
        """

    static func run(_ args: [String]) throws {
        print(try SmartBatteryReader.read().summary)
    }
}
```

In `Sources/fwprobe/SMCCommands.swift`, add this case to the `switch args.first` in `run`, before `default:`:
```swift
        case "watch":
            let keys = try positional(rest).map(smcKey)
            let interval = Double(option("--interval", in: rest) ?? "5") ?? 5
            guard !keys.isEmpty else { throw ProbeError(usage) }
            while true {
                let battery = (try? SmartBatteryReader.read().summary) ?? "battery unreadable"
                let values = keys.map { describe(smc, $0) }.joined(separator: " | ")
                print("\(timestamp())  \(values)  ||  \(battery)")
                Thread.sleep(forTimeInterval: interval)
            }
```

In `Sources/fwprobe/main.swift`, add `\(BatteryCommands.usage)` on a new line after `\(SMCCommands.usage)` in `usage`, and add this case before `default:`:
```swift
    case "battery":
        try BatteryCommands.run(Array(args.dropFirst()))
```

- [ ] **Step 6: Verify against the hardware**

Run: `.build/debug/fwprobe battery`
Expected: one line, e.g. `56%  -1550 mA  12600 mV  29.54 °C  AC=false  charging=false  full=false` — amperage negative on battery, positive while charging. Compare with `ioreg -rn AppleSmartBattery | grep -E '"(InstantAmperage|CurrentCapacity)"'`.

Run: `.build/debug/fwprobe smc watch --interval 2 F0Ac F1Ac` and stop with Ctrl-C after three lines.
Expected: three timestamped lines with both fans' RPM and the battery summary.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "Add battery snapshot, fwprobe battery and smc watch

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Lease, `smc write` and `charge-test`

**Files:**
- Create: `Sources/FWCore/Support/Lease.swift`
- Modify: `Sources/fwprobe/SMCCommands.swift` (add `write`), `Sources/fwprobe/BatteryCommands.swift` (add `chargeTest`), `Sources/fwprobe/main.swift` (add `charge-test`)
- Test: `Tests/FWCoreTests/LeaseTests.swift`

**Interfaces:**
- Consumes: `SMCConnection`, `Hex`, `SmartBatteryReader`, `requireRoot`, `option`, `positional`, `SMCCommands.smcKey`, `SMCCommands.line`.
- Produces: `public final class Lease: @unchecked Sendable { init(restore: @escaping @Sendable () -> Void); func releaseOnSignals(); func release(); var isReleased: Bool }` — `release()` runs `restore` exactly once across threads; `releaseOnSignals()` makes SIGINT/SIGTERM/SIGHUP call `release()` then `exit(128 + signal)`. The M2 helper reuses this type.

- [ ] **Step 1: Write the failing test**

`Tests/FWCoreTests/LeaseTests.swift`:
```swift
import Foundation
import Testing
@testable import FWCore

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite struct LeaseTests {
    @Test func restoresExactlyOnce() {
        let counter = Counter()
        let lease = Lease { counter.increment() }
        #expect(!lease.isReleased)
        lease.release()
        lease.release()
        #expect(counter.value == 1)
        #expect(lease.isReleased)
    }

    @Test func restoresExactlyOnceAcrossThreads() {
        let counter = Counter()
        let lease = Lease { counter.increment() }
        DispatchQueue.concurrentPerform(iterations: 200) { _ in lease.release() }
        #expect(counter.value == 1)
    }

    @Test func doesNotRestoreUntilReleased() {
        let counter = Counter()
        _ = Lease { counter.increment() }
        #expect(counter.value == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: compile error — `cannot find 'Lease' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/FWCore/Support/Lease.swift`:
```swift
import Foundation

/// Something borrowed from the hardware (a charge key, the fans) with a guaranteed hand-back.
/// `restore` runs exactly once: on `release()`, or on SIGINT/SIGTERM/SIGHUP after `releaseOnSignals()`.
/// SIGKILL cannot be caught; recovery from that is the next start's job (spec §2, fan lease).
public final class Lease: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let restore: @Sendable () -> Void
    private var signalSources: [DispatchSourceSignal] = []

    public init(restore: @escaping @Sendable () -> Void) {
        self.restore = restore
    }

    public func releaseOnSignals() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [self] in
                release()
                exit(128 + signalNumber)
            }
            source.resume()
            lock.withLock { signalSources.append(source) }
        }
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        restore()
    }

    public var isReleased: Bool {
        lock.withLock { released }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: 26 tests pass.

- [ ] **Step 5: Add `smc write` (manual tool, no lease)**

In `Sources/fwprobe/SMCCommands.swift`, append to `usage`:
```
        fwprobe smc write KEY HEX                 (sudo) write raw bytes; prints the command to undo it
```
and add this case before `default:` in `run`:
```swift
        case "write":
            try requireRoot()
            guard rest.count == 2, let bytes = Hex.decode(rest[1]) else { throw ProbeError(usage) }
            let key = try smcKey(rest[0])
            let before = try smc.read(key)
            try smc.write(key, bytes: bytes)
            print("before: \(line(before))")
            print("after:  \(line(try smc.read(key)))")
            print("undo:   sudo fwprobe smc write \(key) \(before.bytes.map { String(format: "%02X", $0) }.joined())")
```

- [ ] **Step 6: Add `charge-test`**

In `Sources/fwprobe/BatteryCommands.swift`, append to `usage`:
```
        fwprobe charge-test KEY HEX [--seconds N] (sudo) write HEX to KEY, log battery current every 5 s for N s
                                                  (default 120), then restore the original bytes
```
and add:
```swift
    /// Writes `hex` to `key`, logs battery state, restores the original bytes on exit, error or signal.
    static func chargeTest(_ args: [String]) throws {
        try requireRoot()
        let values = positional(args)
        guard values.count == 2, let inhibit = Hex.decode(values[1]) else { throw ProbeError(usage) }
        let key = try SMCCommands.smcKey(values[0])
        let seconds = Int(option("--seconds", in: args) ?? "120") ?? 120

        let smc = try SMCConnection()
        let original = try smc.read(key).bytes
        print("\(timestamp())  before: \(SMCCommands.line(try smc.read(key)))")
        print("\(timestamp())  battery: \(try SmartBatteryReader.read().summary)")

        let lease = Lease {
            do {
                try SMCConnection().write(key, bytes: original)
                print("\(timestamp())  restored \(key) = \(Hex.encode(original))")
            } catch {
                let undo = Hex.encode(original).replacingOccurrences(of: " ", with: "")
                print("RESTORE FAILED for \(key): \(error). Run: sudo fwprobe smc write \(key) \(undo)")
            }
        }
        lease.releaseOnSignals()
        defer { lease.release() }

        try smc.write(key, bytes: inhibit)
        print("\(timestamp())  wrote \(Hex.encode(inhibit)); read-back: \(SMCCommands.line(try smc.read(key)))")
        for elapsed in stride(from: 0, through: seconds, by: 5) {
            let value = SMCCommands.describe(smc, key)
            print("\(timestamp())  t=\(elapsed)s  \(try SmartBatteryReader.read().summary)  |  \(value)")
            if elapsed < seconds { Thread.sleep(forTimeInterval: 5) }
        }
    }
```

In `Sources/fwprobe/main.swift`, add before `default:`:
```swift
    case "charge-test":
        try BatteryCommands.chargeTest(Array(args.dropFirst()))
```

- [ ] **Step 7: Verify the refusal paths (no sudo, nothing written)**

Run: `swift build && .build/debug/fwprobe charge-test CHTE 01000000 --seconds 10`
Expected: `error: this command writes the SMC: run it with sudo`, exit 1.

Run: `.build/debug/fwprobe smc write CHTE 01000000`
Expected: the same error.

Run: `.build/debug/fwprobe smc read CHTE`
Expected: unchanged from before (record the value in the commit message body if the key exists).

The real charge experiment runs in Task 10 (E2), with the human, after AlDente is quit.

- [ ] **Step 8: Commit**

```bash
git add Sources Tests
git commit -m "Add Lease, fwprobe smc write and charge-test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `fan-test` and `fan-release`

**Files:**
- Create: `Sources/fwprobe/FanCommands.swift`
- Modify: `Sources/fwprobe/main.swift` (add `fan-test`, `fan-release`)

**Interfaces:**
- Consumes: `SMCConnection`, `SMCValue.encodeFloat`, `FourCC(string:)`, `Lease`, `requireRoot`, `option`, `timestamp`, `SMCCommands.describe`.
- Produces: `enum FanCommands { static func fanTest(_ args: [String]) throws; static func releaseFans(fanCount: Int) }` — `releaseFans` writes `F<i>Md = 00` for every fan and `Ftst = 00` if `Ftst` exists, unconditionally (hard rule 2), and reports each failure without stopping.

- [ ] **Step 1: Write FanCommands**

`Sources/fwprobe/FanCommands.swift`:
```swift
import Foundation
import FWCore

enum FanCommands {
    static let usage = """
        fwprobe fan-test --rpm N [--seconds S] [--unlock]
                                                  (sudo) force every fan to N RPM for S s (default 30), log RPM
                                                  every 2 s, then hand the fans back. --unlock writes Ftst=1 first
        fwprobe fan-release                       (sudo) hand every fan back to macOS, unconditionally
        """

    static func fanTest(_ args: [String]) throws {
        try requireRoot()
        guard let rpm = option("--rpm", in: args).flatMap(Float.init) else { throw ProbeError(usage) }
        let seconds = Int(option("--seconds", in: args) ?? "30") ?? 30
        let unlock = args.contains("--unlock")

        let smc = try SMCConnection()
        let fanCount = Int(try smc.read("FNum").number ?? 0)
        guard fanCount > 0 else { throw ProbeError("FNum reports no fans") }
        for fan in 0..<fanCount {
            let minimum = try smc.read(fanKey(fan, "Mn")).number ?? .nan
            let maximum = try smc.read(fanKey(fan, "Mx")).number ?? .nan
            print("fan \(fan): min \(minimum)  max \(maximum)  now \(describe(smc, fan, "Ac"))  mode \(describe(smc, fan, "Md"))")
            guard Double(rpm) >= minimum, Double(rpm) <= maximum else {
                throw ProbeError("\(rpm) RPM is outside fan \(fan)'s range \(minimum)–\(maximum)")
            }
        }

        let lease = Lease { releaseFans(fanCount: fanCount) }
        lease.releaseOnSignals()
        defer { lease.release() }

        if unlock {
            try smc.write("Ftst", bytes: [1])
            print("\(timestamp())  wrote Ftst=01")
            Thread.sleep(forTimeInterval: 1)
        }
        for fan in 0..<fanCount {
            try smc.write(fanKey(fan, "Md"), bytes: [1])
            try smc.write(fanKey(fan, "Tg"), bytes: SMCValue.encodeFloat(rpm))
            print("\(timestamp())  fan \(fan): wrote Md=01, Tg=\(rpm)")
        }
        for elapsed in stride(from: 0, through: seconds, by: 2) {
            let fans = (0..<fanCount).map { fan in
                "fan\(fan) Md \(describe(smc, fan, "Md")) Tg \(describe(smc, fan, "Tg")) Ac \(describe(smc, fan, "Ac"))"
            }
            print("\(timestamp())  t=\(elapsed)s  " + fans.joined(separator: "  |  "))
            if elapsed < seconds { Thread.sleep(forTimeInterval: 2) }
        }
    }

    /// Hands every fan back to macOS. Writes even if we think we never took them (hard rule 2).
    static func releaseFans(fanCount: Int) {
        guard let smc = try? SMCConnection() else {
            print("RELEASE FAILED: cannot open the SMC. Run: sudo fwprobe fan-release")
            return
        }
        for fan in 0..<fanCount {
            do {
                try smc.write(fanKey(fan, "Md"), bytes: [0])
                print("\(timestamp())  fan \(fan): Md=00 (system control)")
            } catch {
                print("RELEASE FAILED for fan \(fan): \(error)")
            }
        }
        if (try? smc.keyInfo("Ftst")) != nil {
            do {
                try smc.write("Ftst", bytes: [0])
                print("\(timestamp())  Ftst=00")
            } catch {
                print("RELEASE FAILED for Ftst: \(error)")
            }
        }
    }

    static func fanRelease() throws {
        try requireRoot()
        let fanCount = (try? SMCConnection().read("FNum").number).map { Int($0) } ?? 2
        releaseFans(fanCount: max(fanCount, 1))
    }

    private static func fanKey(_ fan: Int, _ suffix: String) -> FourCC {
        FourCC(string: "F\(fan)\(suffix)")!
    }

    private static func describe(_ smc: SMCConnection, _ fan: Int, _ suffix: String) -> String {
        guard let value = try? smc.read(fanKey(fan, suffix)) else { return "?" }
        return value.number.map { String(format: "%.0f", $0) } ?? value.hex
    }
}
```

- [ ] **Step 2: Wire into main**

In `Sources/fwprobe/main.swift`, add `\(FanCommands.usage)` on a new line in `usage`, and these cases before `default:`:
```swift
    case "fan-test":
        try FanCommands.fanTest(Array(args.dropFirst()))
    case "fan-release":
        try FanCommands.fanRelease()
```

- [ ] **Step 3: Build and run tests**

Run: `swift build && swift test`
Expected: build succeeds; 26 tests pass.

- [ ] **Step 4: Verify the refusal paths (no sudo)**

Run: `.build/debug/fwprobe fan-test --rpm 3000`
Expected: `error: this command writes the SMC: run it with sudo`.

Run: `.build/debug/fwprobe fan-release`
Expected: the same error.

Run: `.build/debug/fwprobe` (no args)
Expected: usage lists smc, battery, charge-test, fan-test, fan-release.

The real fan experiment runs in Task 10 (E4).

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "Add fwprobe fan-test and fan-release with lease hand-back

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Power math, IOReport sampler, `fwprobe ioreport`

**Files:**
- Create: `Sources/FWCore/Power/PowerMath.swift`, `Sources/FWCore/Power/IOReportSampler.swift`
- Create: `Sources/CMacPrivate/include/ioreport.h`
- Modify: `Sources/CMacPrivate/include/CMacPrivate.h` (include ioreport.h)
- Create: `Sources/fwprobe/PowerCommands.swift`
- Modify: `Sources/fwprobe/main.swift` (add `ioreport`)
- Test: `Tests/FWCoreTests/PowerMathTests.swift`

**Interfaces:**
- Consumes: `option`, `timestamp` (Task 3).
- Produces:
  - `public enum PowerMath { static func joules(_ value: Int64, unit: String) -> Double?; static func watts(joules: Double, seconds: Double) -> Double?; static func residencyShares(_ states: [IOReportState]) -> [(name: String, share: Double)] }`
  - `public struct IOReportState: Sendable { name: String; residency: Int64 }`
  - `public struct IOReportChannel: Sendable { group, subgroup, name, unit: String; value: Value }` with `enum Value: Sendable { case simple(Int64), states([IOReportState]), other(UInt8) }`
  - `public final class IOReportSampler { init(groups: [String]) throws; func sample() -> CFDictionary?; func delta(from: CFDictionary, to: CFDictionary) -> [IOReportChannel]; static func allChannels() -> [IOReportChannel] }`, `public enum IOReportError: Error { case noChannels, subscriptionFailed }`

- [ ] **Step 1: Write the failing test**

`Tests/FWCoreTests/PowerMathTests.swift`:
```swift
import Testing
@testable import FWCore

@Suite struct PowerMathTests {
    @Test func convertsEnergyUnits() {
        #expect(PowerMath.joules(1500, unit: "mJ") == 1.5)
        #expect(PowerMath.joules(2_000_000, unit: "uJ") == 2.0)
        #expect(PowerMath.joules(3_000_000_000, unit: "nJ") == 3.0)
        #expect(PowerMath.joules(5, unit: " mJ ") == 0.005)
    }

    @Test func unknownUnitIsNil() {
        #expect(PowerMath.joules(1, unit: "W") == nil)
        #expect(PowerMath.joules(1, unit: "") == nil)
    }

    @Test func wattsNeedAPositiveInterval() {
        #expect(PowerMath.watts(joules: 10, seconds: 2) == 5)
        #expect(PowerMath.watts(joules: 10, seconds: 0) == nil)
        #expect(PowerMath.watts(joules: 10, seconds: -1) == nil)
    }

    @Test func residencySharesSumToOne() {
        let shares = PowerMath.residencyShares([
            IOReportState(name: "IDLE", residency: 300),
            IOReportState(name: "P1", residency: 100),
        ])
        #expect(shares.map(\.name) == ["IDLE", "P1"])
        #expect(shares.map(\.share) == [0.75, 0.25])
    }

    @Test func zeroResidencyGivesNoShares() {
        #expect(PowerMath.residencyShares([IOReportState(name: "IDLE", residency: 0)]).isEmpty)
        #expect(PowerMath.residencyShares([]).isEmpty)
    }

    @Test func negativeResidencyCountsAsZero() {
        let shares = PowerMath.residencyShares([
            IOReportState(name: "A", residency: -5),
            IOReportState(name: "B", residency: 10),
        ])
        #expect(shares.map(\.share) == [0, 1])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: compile error — `cannot find 'PowerMath' in scope`.

- [ ] **Step 3: Write PowerMath and IOReportState**

`Sources/FWCore/Power/PowerMath.swift`:
```swift
import Foundation

public struct IOReportState: Sendable {
    public let name: String
    public let residency: Int64

    public init(name: String, residency: Int64) {
        self.name = name
        self.residency = residency
    }
}

public enum PowerMath {
    /// IOReport "Energy Model" channels count in mJ, uJ or nJ.
    public static func joules(_ value: Int64, unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": Double(value) / 1e3
        case "uJ", "µJ": Double(value) / 1e6
        case "nJ": Double(value) / 1e9
        default: nil
        }
    }

    public static func watts(joules: Double, seconds: Double) -> Double? {
        seconds > 0 ? joules / seconds : nil
    }

    /// Each state's share of the total residency; empty if nothing was resident (e.g. a zero-length interval).
    public static func residencyShares(_ states: [IOReportState]) -> [(name: String, share: Double)] {
        let total = states.reduce(Int64(0)) { $0 + max(0, $1.residency) }
        guard total > 0 else { return [] }
        return states.map { ($0.name, Double(max(0, $0.residency)) / Double(total)) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: 32 tests pass.

- [ ] **Step 5: Write the IOReport declarations**

`Sources/CMacPrivate/include/ioreport.h`:
```c
#ifndef CMACPRIVATE_IOREPORT_H
#define CMACPRIVATE_IOREPORT_H

#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

// Private API in /usr/lib/libIOReport.dylib. Not documented by Apple; signatures follow the
// open-source tools that use it (macmon, asitop). Channel formats: 1 = simple, 2 = state.

CF_ASSUME_NONNULL_BEGIN

typedef struct CF_BRIDGED_TYPE(id) __IOReportSubscription *IOReportSubscriptionRef;

CFDictionaryRef _Nullable IOReportCopyAllChannels(uint64_t a, uint64_t b) CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCopyChannelsInGroup(CFStringRef _Nullable group, CFStringRef _Nullable subgroup,
                                                      uint64_t a, uint64_t b, uint64_t c) CF_RETURNS_RETAINED;
void IOReportMergeChannels(CFMutableDictionaryRef into, CFDictionaryRef from, CFTypeRef _Nullable unused);
IOReportSubscriptionRef _Nullable IOReportCreateSubscription(void * _Nullable unused, CFMutableDictionaryRef channels,
                                                             CFMutableDictionaryRef _Nullable * _Nonnull subscribed,
                                                             uint64_t channelID, CFTypeRef _Nullable unused2)
    CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCreateSamples(IOReportSubscriptionRef subscription, CFMutableDictionaryRef subscribed,
                                                CFTypeRef _Nullable unused) CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCreateSamplesDelta(CFDictionaryRef previous, CFDictionaryRef current,
                                                     CFTypeRef _Nullable unused) CF_RETURNS_RETAINED;

CFStringRef _Nullable IOReportChannelGetGroup(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetSubGroup(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetChannelName(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetUnitLabel(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
uint8_t IOReportChannelGetFormat(CFDictionaryRef channel);

int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index);
int32_t IOReportStateGetCount(CFDictionaryRef channel);
CFStringRef _Nullable IOReportStateGetNameForIndex(CFDictionaryRef channel, int32_t index) CF_RETURNS_NOT_RETAINED;
int64_t IOReportStateGetResidency(CFDictionaryRef channel, int32_t index);

CF_ASSUME_NONNULL_END

#endif
```

Replace `Sources/CMacPrivate/include/CMacPrivate.h` with:
```c
#ifndef CMACPRIVATE_H
#define CMACPRIVATE_H
#include "smc.h"
#include "ioreport.h"
#endif
```

- [ ] **Step 6: Write IOReportSampler**

`Sources/FWCore/Power/IOReportSampler.swift`:
```swift
import CMacPrivate
import Foundation

public enum IOReportError: Error {
    case noChannels
    case subscriptionFailed
}

public struct IOReportChannel: Sendable {
    public enum Value: Sendable {
        case simple(Int64)
        case states([IOReportState])
        case other(UInt8)
    }

    public let group: String
    public let subgroup: String
    public let name: String
    public let unit: String
    public let value: Value
}

/// A subscription to IOReport channel groups (e.g. "Energy Model", "CPU Stats", "GPU Stats").
/// Unprivileged. Take two samples and diff them: energy channels give joules over the interval,
/// state channels give residency over the interval.
public final class IOReportSampler {
    private let subscription: IOReportSubscriptionRef
    private let subscribed: CFMutableDictionary

    public init(groups: [String]) throws {
        var merged: CFMutableDictionary?
        for group in groups {
            guard let channels = IOReportCopyChannelsInGroup(group as CFString, nil, 0, 0, 0) else { continue }
            if let merged {
                IOReportMergeChannels(merged, channels, nil)
            } else {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels)
            }
        }
        guard let merged else { throw IOReportError.noChannels }
        var subscribedOut: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, merged, &subscribedOut, 0, nil),
              let subscribedOut else { throw IOReportError.subscriptionFailed }
        self.subscription = subscription
        self.subscribed = subscribedOut.takeRetainedValue()
    }

    public func sample() -> CFDictionary? {
        IOReportCreateSamples(subscription, subscribed, nil)
    }

    public func delta(from previous: CFDictionary, to current: CFDictionary) -> [IOReportChannel] {
        guard let delta = IOReportCreateSamplesDelta(previous, current, nil) else { return [] }
        return Self.channels(in: delta, readValues: true)
    }

    /// Every channel the system publishes, names only.
    public static func allChannels() -> [IOReportChannel] {
        guard let all = IOReportCopyAllChannels(0, 0) else { return [] }
        return channels(in: all, readValues: false)
    }

    static func channels(in dictionary: CFDictionary, readValues: Bool) -> [IOReportChannel] {
        guard let items = (dictionary as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return [] }
        return items.map { item in
            let channel = item as CFDictionary
            let format = IOReportChannelGetFormat(channel)
            var value = IOReportChannel.Value.other(format)
            if readValues {
                switch format {
                case 1:
                    value = .simple(IOReportSimpleGetIntegerValue(channel, 0))
                case 2:
                    let count = IOReportStateGetCount(channel)
                    value = .states((0..<max(count, 0)).map { index in
                        IOReportState(
                            name: (IOReportStateGetNameForIndex(channel, index) as String?) ?? "?",
                            residency: IOReportStateGetResidency(channel, index)
                        )
                    })
                default:
                    break
                }
            }
            return IOReportChannel(
                group: (IOReportChannelGetGroup(channel) as String?) ?? "",
                subgroup: (IOReportChannelGetSubGroup(channel) as String?) ?? "",
                name: (IOReportChannelGetChannelName(channel) as String?) ?? "",
                unit: (IOReportChannelGetUnitLabel(channel) as String?) ?? "",
                value: value
            )
        }
    }
}
```

- [ ] **Step 7: Write `fwprobe ioreport`**

`Sources/fwprobe/PowerCommands.swift`:
```swift
import Foundation
import FWCore

enum PowerCommands {
    static let usage = """
        fwprobe ioreport list [GROUP-PREFIX]      every IOReport channel: group / subgroup / name [unit]
        fwprobe ioreport sample [--seconds N] [--group G]...
                                                  1 s deltas for N s (default 10): watts for energy channels,
                                                  residency for performance-state channels, and sampling cost.
                                                  Default groups: Energy Model, CPU Stats, GPU Stats
        """

    static func ioreport(_ args: [String]) throws {
        let rest = Array(args.dropFirst())
        switch args.first {
        case "list":
            let prefix = rest.first ?? ""
            let lines = Set(IOReportSampler.allChannels()
                .filter { $0.group.hasPrefix(prefix) }
                .map { "\($0.group) / \($0.subgroup) / \($0.name) [\($0.unit)]" })
            lines.sorted().forEach { print($0) }
            print("# \(lines.count) channels")
        case "sample":
            try sample(rest)
        default:
            throw ProbeError(usage)
        }
    }

    private static func sample(_ args: [String]) throws {
        let seconds = Int(option("--seconds", in: args) ?? "10") ?? 10
        var groups: [String] = []
        for (index, arg) in args.enumerated() where arg == "--group" && index + 1 < args.count {
            groups.append(args[index + 1])
        }
        let sampler = try IOReportSampler(groups: groups.isEmpty ? ["Energy Model", "CPU Stats", "GPU Stats"] : groups)
        guard var previous = sampler.sample() else { throw ProbeError("IOReportCreateSamples returned nothing") }
        var previousTime = ProcessInfo.processInfo.systemUptime

        for _ in 0..<seconds {
            Thread.sleep(forTimeInterval: 1)
            let start = ProcessInfo.processInfo.systemUptime
            guard let current = sampler.sample() else { continue }
            let channels = sampler.delta(from: previous, to: current)
            let cost = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let interval = start - previousTime
            previous = current
            previousTime = start

            print("── \(timestamp())  interval \(String(format: "%.3f", interval)) s  sample+delta \(String(format: "%.2f", cost)) ms")
            for channel in channels {
                switch channel.value {
                case .simple(let raw):
                    guard let joules = PowerMath.joules(raw, unit: channel.unit),
                          let watts = PowerMath.watts(joules: joules, seconds: interval),
                          watts >= 0.005 else { continue }
                    print("   \(channel.group) / \(channel.name): \(String(format: "%.3f", watts)) W")
                case .states(let states):
                    guard channel.subgroup.contains("Performance States") else { continue }
                    let shares = PowerMath.residencyShares(states).filter { $0.share >= 0.01 }
                    guard !shares.isEmpty else { continue }
                    let text = shares.map { "\($0.name) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " ")
                    print("   \(channel.subgroup) / \(channel.name): \(text)")
                case .other:
                    continue
                }
            }
        }
    }
}
```

In `Sources/fwprobe/main.swift`, add `\(PowerCommands.usage)` on a new line in `usage`, and before `default:`:
```swift
    case "ioreport":
        try PowerCommands.ioreport(Array(args.dropFirst()))
```

- [ ] **Step 8: Build, test, verify against the hardware**

Run: `swift build && swift test`
Expected: 32 tests pass.

Run: `.build/debug/fwprobe ioreport list "Energy Model"`
Expected: channels such as `Energy Model / ... / CPU Energy [mJ]`, `GPU Energy [...]`, `ANE ...`, `DRAM ...` and a count. Exact names are recorded in Task 10, not assumed here.

Run: `.build/debug/fwprobe ioreport sample --seconds 3`
Expected: three blocks, each with an interval near 1.000 s, a sample+delta cost in single-digit milliseconds, non-zero CPU energy in watts, and CPU/GPU performance-state residency lines.

- [ ] **Step 9: Commit**

```bash
git add Sources Tests
git commit -m "Add IOReport sampler, power math and fwprobe ioreport

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: HID temperature sensors and `fwprobe temps`

**Files:**
- Create: `Sources/CMacPrivate/include/hid_private.h`
- Modify: `Sources/CMacPrivate/include/CMacPrivate.h` (include hid_private.h)
- Create: `Sources/FWCore/Sensors/HIDTemperatureReader.swift`
- Modify: `Sources/fwprobe/PowerCommands.swift` (add `temps`), `Sources/fwprobe/main.swift` (add `temps`)

**Interfaces:**
- Consumes: `option`, `timestamp`.
- Produces: `public struct TemperatureReading: Sendable { name: String; celsius: Double }`, `public enum HIDTemperatureReader { static func read() -> [TemperatureReading] }` (sorted by name; empty if the API returns nothing), `PowerCommands.temps(_ args: [String])`.

Hardware-only; verified by running.

- [ ] **Step 1: Write the private HID declarations**

`Sources/CMacPrivate/include/hid_private.h`:
```c
#ifndef CMACPRIVATE_HID_PRIVATE_H
#define CMACPRIVATE_HID_PRIVATE_H

#include <stdint.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

// Private IOHIDEvent API (exported by IOKit, not in the public headers). Temperature sensors are the
// services with PrimaryUsagePage 0xFF00 and PrimaryUsage 5.

CF_ASSUME_NONNULL_BEGIN

typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;

static const int64_t kCHIDEventTypeTemperature = 15;
static const int32_t kCHIDTemperatureLevelField = 15 << 16;
static const int kCHIDSensorUsagePage = 0xFF00;
static const int kCHIDTemperatureSensorUsage = 5;

IOHIDEventRef _Nullable IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options,
                                                    int64_t timestamp) CF_RETURNS_RETAINED;
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

CF_ASSUME_NONNULL_END

#endif
```

Replace `Sources/CMacPrivate/include/CMacPrivate.h` with:
```c
#ifndef CMACPRIVATE_H
#define CMACPRIVATE_H
#include "smc.h"
#include "ioreport.h"
#include "hid_private.h"
#endif
```

- [ ] **Step 2: Write HIDTemperatureReader**

`Sources/FWCore/Sensors/HIDTemperatureReader.swift`:
```swift
import CMacPrivate
import Foundation
import IOKit.hidsystem

public struct TemperatureReading: Sendable {
    public let name: String
    public let celsius: Double
}

/// Temperature sensors published through the HID event system (unprivileged).
public enum HIDTemperatureReader {
    public static func read() -> [TemperatureReading] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(client) else { return [] }
        var readings: [TemperatureReading] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = Unmanaged<IOHIDServiceClient>.fromOpaque(raw).takeUnretainedValue()
            guard intProperty(service, "PrimaryUsagePage") == Int(kCHIDSensorUsagePage),
                  intProperty(service, "PrimaryUsage") == Int(kCHIDTemperatureSensorUsage),
                  let event = IOHIDServiceClientCopyEvent(service, kCHIDEventTypeTemperature, 0, 0) else { continue }
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? "?"
            readings.append(TemperatureReading(name: name, celsius: IOHIDEventGetFloatValue(event, kCHIDTemperatureLevelField)))
        }
        return readings.sorted { $0.name < $1.name }
    }

    private static func intProperty(_ service: IOHIDServiceClient, _ key: String) -> Int? {
        (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue
    }
}
```

- [ ] **Step 3: Add `fwprobe temps`**

In `Sources/fwprobe/PowerCommands.swift`, append to `usage`:
```
        fwprobe temps [--watch S]                 HID temperature sensors (repeat every S s with --watch)
```
and add:
```swift
    static func temps(_ args: [String]) throws {
        let interval = option("--watch", in: args).flatMap(Double.init)
        repeat {
            let readings = HIDTemperatureReader.read()
            guard !readings.isEmpty else { throw ProbeError("no HID temperature sensors returned") }
            print("── \(timestamp())  \(readings.count) sensors")
            for reading in readings {
                print("   \(reading.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(String(format: "%6.1f", reading.celsius)) °C")
            }
            if let interval { Thread.sleep(forTimeInterval: interval) }
        } while interval != nil
    }
```

In `Sources/fwprobe/main.swift`, before `default:`:
```swift
    case "temps":
        try PowerCommands.temps(Array(args.dropFirst()))
```

- [ ] **Step 4: Build, test, verify against the hardware**

Run: `swift build && swift test`
Expected: 32 tests pass.

Run: `.build/debug/fwprobe temps`
Expected: a list of sensors with plausible values (20–100 °C). On Apple Silicon expect names like `PMU tdie…`, `PMU tdev…`, `gas gauge battery`, `NAND CH0 temp`. Record the real names in Task 10, do not assume these.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "Add HID temperature reader and fwprobe temps

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Spike scripts and the M0 test plan

**Files:**
- Create: `scripts/aldente-ids.sh`, `scripts/fps-spike.sh`, `docs/m0-test-plan.md`

**Interfaces:**
- Consumes: the `fwprobe` commands from Tasks 3–8.
- Produces: the procedure Task 10 follows; experiment IDs E1–E8 that `docs/hardware-baseline.md` cites.

- [ ] **Step 1: Write the AlDente identification script**

`scripts/aldente-ids.sh`:
```bash
#!/bin/bash
# Lists AlDente's processes, launchd jobs and helper files, so fwhelperd can detect it (spec §2).
# Run with AlDente running. Uses sudo for the system launchd domain.
echo "== processes";          pgrep -fil aldente || echo "(none)"
echo "== launchd (system)";   sudo launchctl print system | grep -i dente || echo "(none)"
echo "== launchd (user)";     launchctl print "gui/$(id -u)" | grep -i dente || echo "(none)"
echo "== helper files";       ls -l /Library/PrivilegedHelperTools /Library/LaunchDaemons 2>/dev/null | grep -i dente || echo "(none)"
echo "== app bundle id";      mdls -name kMDItemCFBundleIdentifier /Applications/AlDente.app
```

- [ ] **Step 2: Write the FPS spike script**

`scripts/fps-spike.sh`:
```bash
#!/bin/bash
# M0 FPS spike (spec §3 Overlay): can Metal HUD logging give us another process's FPS, live and cheaply?
# Sets the Metal HUD environment for GUI apps launched from now on, captures Metal log lines,
# samples the CPU cost of `log stream`, and clears the environment on exit (Ctrl-C).
set -uo pipefail
OUT="${1:-$HOME/fps-spike-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

launchctl setenv MTL_HUD_ENABLED 1
launchctl setenv MTL_HUD_LOG_ENABLED 1
cleanup() {
    launchctl unsetenv MTL_HUD_ENABLED
    launchctl unsetenv MTL_HUD_LOG_ENABLED
    kill "$LOGPID" "$CPUPID" 2>/dev/null
    echo "Metal HUD environment cleared. Output in $OUT"
}
trap cleanup EXIT

log stream --style ndjson --level debug \
    --predicate 'subsystem BEGINSWITH "com.apple.Metal" OR category CONTAINS[c] "hud"' \
    > "$OUT/metal.ndjson" &
LOGPID=$!
( while kill -0 "$LOGPID" 2>/dev/null; do
      echo "$(date +%T) $(ps -o %cpu= -p "$LOGPID")" >> "$OUT/logstream-cpu.txt"
      sleep 10
  done ) &
CPUPID=$!

echo "Capturing to $OUT. Now quit Steam completely and relaunch it (or launch the game/emulator) so it"
echo "inherits the environment. Play for about 60 s with the Metal HUD visible, then press Ctrl-C here."
wait "$LOGPID"
```

- [ ] **Step 3: Make both executable and syntax-check**

Run: `chmod +x scripts/*.sh && bash -n scripts/aldente-ids.sh && bash -n scripts/fps-spike.sh && echo ok`
Expected: `ok`.

- [ ] **Step 4: Write the test plan**

`docs/m0-test-plan.md`:
````markdown
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
4. **Interrupt check (Review Focus 1):** repeat the working command and press Ctrl-C at ~30 s. Expect the
   `restored` line, and `$P smc read <KEY>` shows the original bytes.

## E3 — Adapter inhibit (for calibration; on AC)
1. `$P smc read CHIE CH0J` and record.
2. `sudo $P charge-test CHIE 08 --seconds 60` (or `CH0J 20` if CHIE is missing).
   - Efficacy = amperage clearly negative (discharging) while AC is still physically connected.
   - Note whether `ExternalConnected` changes.

## E4 — Fan control (on AC, idle)
1. `sudo $P fan-test --rpm 4000 --seconds 30` — without unlock. Record success or the exact error.
2. `sudo $P fan-test --rpm 4000 --seconds 30 --unlock`. Record whether Ac follows Tg, how fast, and whether
   Md/Tg are rewritten by the system during the run.
3. After the release, watch `$P smc watch --interval 2 F0Md F0Tg F0Ac F1Ac Ftst` for 60 s: RPM returns to idle.
4. **Interrupt check:** repeat step 2 and press Ctrl-C at ~10 s; expect the release lines.
5. **Crash check:** repeat step 2, then from another terminal `sudo kill -9 $(pgrep fwprobe)`. Watch for 2
   minutes: does macOS reclaim the fans on its own? Then `sudo $P fan-release` and confirm. This decides
   how hard the helper's startup release has to work.
6. Record min/max RPM per fan, and the lowest RPM that actually spins (try `--rpm` at the reported minimum).

## E5 — Temperatures
1. `$P temps > docs/data/hid-temps-idle.txt` and `$P smc list T > docs/data/smc-temps-idle.txt`.
2. Load the CPU for 60 s (`for i in $(seq 16); do yes > /dev/null & done; sleep 60; killall yes`) while running
   `$P temps --watch 5`. Identify the sensors that rise fastest: CPU die candidates.
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
1. `pmset -g | grep powermode`; `sudo pmset -a powermode 1`, check with `pmset -g`, then `sudo pmset -a powermode 2`
   (restore the original value). Record that both switch, and whether `-c`/`-b` (AC/battery) variants are distinct.

## E8 — FPS spike
1. `scripts/fps-spike.sh` then follow its prompt with a Metal game (and ARMSX2 if convenient).
2. Analyse `metal.ndjson`: `grep -c . metal.ndjson`; inspect a few `eventMessage` values. Questions:
   - Are there periodic entries carrying FPS or frame time? How often (per frame, per second)?
   - Do they identify the process (`processImagePath`, `processID`)?
   - What does `logstream-cpu.txt` show for the cost of `log stream`?
3. If nothing useful is logged: retry with `defaults write -g MetalForceHudEnabled -bool YES` (undo with
   `defaults delete -g MetalForceHudEnabled`) and with the predicate removed for the game's PID only
   (`log stream --process <pid> --level debug`). Record what was tried even if it failed.
````

- [ ] **Step 5: Commit**

```bash
git add scripts docs/m0-test-plan.md
git commit -m "Add AlDente and FPS spike scripts and the M0 test plan

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Run the experiments with the human and record the baseline

This task is interactive. The engineer runs read-only steps; the human runs every `sudo` step, plugs and
unplugs the charger, and plays the game. Do not run `sudo` commands on the human's behalf without asking.

**Files:**
- Create: `docs/hardware-baseline.md`, `docs/data/*` (raw outputs)
- Create: `docs/adr/0002-charge-control-mechanism.md`, `docs/adr/0003-fan-control-sequence.md`, `docs/adr/0004-fps-source.md`
- Modify: `CLAUDE.md` (Current state, Resume here, Traps), `README.md` (status line)

**Interfaces:**
- Consumes: `docs/m0-test-plan.md` E0–E8.
- Produces: the facts the M1–M7 plans are written from: charge key + bytes, adapter key + bytes, fan unlock/release sequence and RPM limits, CPU/GPU/battery sensor names, IOReport channel names, sampling cost, power mode behaviour, FPS source decision.

- [ ] **Step 1: Create the baseline document skeleton**

`docs/hardware-baseline.md`:
```markdown
# Hardware baseline — MacBook Pro 16" M4 Max (Mac16,5), macOS 26.6

Tags: **[M]** measured on this machine (experiment ID, date). **[?]** external source, unverified.
Raw outputs are in `docs/data/`. Procedure: `docs/m0-test-plan.md`.

## AlDente (E0)
## SMC inventory (E1)
## Charge inhibit (E2)
## Adapter inhibit (E3)
## Fans (E4)
## Temperatures (E5)
## IOReport power and clocks (E6)
## Power modes (E7)
## FPS (E8)
## Open questions
```

- [ ] **Step 2: E0 and E1** — run, save outputs under `docs/data/`, fill both sections. Commit:

```bash
git add docs && git commit -m "Record M0 E0-E1: AlDente identifiers and SMC inventory

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: E2 and E3** — human runs them; paste the full logs into `docs/data/e2-charge.txt`, `docs/data/e3-adapter.txt`; fill sections with key, bytes, effect, time to effect, and the interrupt check result. Write `docs/adr/0002-charge-control-mechanism.md` (context, the measured mechanism, rejected candidates and why). Commit.

- [ ] **Step 4: E4** — human runs it; logs to `docs/data/e4-fans.txt`; fill the Fans section including the kill -9 result; write `docs/adr/0003-fan-control-sequence.md` (exact take and release sequence, minimum spinning RPM, what happens if the process dies). Commit.

- [ ] **Step 5: E5, E6, E7** — fill the sections: chosen CPU die, GPU die and battery sensors (name + source), energy and performance-state channel names, sampling cost %, power mode behaviour. Commit.

- [ ] **Step 6: E8** — fill the FPS section; write `docs/adr/0004-fps-source.md` choosing Metal HUD log streaming **or** the fallback (toggle Apple's HUD, no FPS in our overlay), with the measured evidence and cost. Commit.

- [ ] **Step 7: Close M0**

Update `CLAUDE.md`: Current state = "M0 complete (date)"; Resume here = "write the M1+M2 plan from `docs/hardware-baseline.md`"; add any new traps found. Update the README status line. Run `swift test` (expect 32 passing). Commit:

```bash
git add CLAUDE.md README.md docs && git commit -m "Close M0: hardware baseline recorded

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 8: Hand off**

Summarise the measured facts for the human, flag any spec assumption M0 disproved (e.g. no working charge key, fans not controllable, no FPS source), and propose amending the spec if needed before writing the next plan.
