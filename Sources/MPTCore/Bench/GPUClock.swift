import Foundation
import IOKit

/// The GPU clock from IOReport `GPUPH` state residency and the `pmgr` frequency table.
///
/// Measured on M4 Max, macOS 27.0.1 (hardware-baseline 2026-11-24): IORegistry `pmgr` property `voltage-states9`
/// is 16 × (frequency Hz u32 LE, voltage u32 LE), entry 0 = 0 Hz (OFF), entries 1…15 = 338…1578 MHz; `GPUPH` has
/// states OFF, P1…P15. `[?]` P*n* ↔ entry *n*. A Mac whose `pmgr` has no table that fits gets no clock (nil).
public enum GPUClock {
    /// MHz per GPUPH state (index 0 = OFF = 0) from the first `pmgr` table with `stateCount` entries whose first
    /// entry is 0 Hz and whose other entries are not. nil when none fits.
    public static func table(fromPMGR entries: [[UInt8]], stateCount: Int) -> [Double]? {
        guard stateCount > 1 else { return nil }
        for bytes in entries where bytes.count == stateCount * 8 {
            let hz = (0..<stateCount).map { i -> UInt32 in
                let o = i * 8
                return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16
                    | UInt32(bytes[o + 3]) << 24
            }
            guard hz[0] == 0, hz.dropFirst().allSatisfy({ $0 > 0 }) else { continue }
            return hz.map { Double($0) / 1_000_000 }
        }
        return nil
    }

    /// Residency-weighted mean MHz over the non-OFF states ("P*n*" → `table[n]`). nil when nothing was active, or
    /// when an active state has no table entry (better empty than wrong).
    public static func meanMHz(states: [IOReportState], table: [Double]) -> Double? {
        var weighted = 0.0, total = 0.0
        for state in states where state.name != "OFF" && state.residency > 0 {
            guard state.name.hasPrefix("P"), let n = Int(state.name.dropFirst()), n > 0, n < table.count else {
                return nil
            }
            weighted += table[n] * Double(state.residency)
            total += Double(state.residency)
        }
        return total > 0 ? weighted / total : nil
    }

    /// The `pmgr` `voltage-states<N>` tables (raw bytes), in ascending N. One IORegistry read; unprivileged.
    public static func pmgrTables() -> [[UInt8]] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return [] }
        let prefix = "voltage-states"
        return dict.compactMap { key, value -> (Int, [UInt8])? in
            guard key.hasPrefix(prefix), let n = Int(key.dropFirst(prefix.count)), let data = value as? Data else {
                return nil
            }
            return (n, [UInt8](data))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    /// The table for a GPUPH channel with `stateCount` states, read from the IORegistry.
    public static func loadTable(stateCount: Int) -> [Double]? {
        table(fromPMGR: pmgrTables(), stateCount: stateCount)
    }

    /// The number of `GPU Stats / GPU Performance States / GPUPH` states in one IOReport sample; nil if absent.
    static func gpuphStateCount(in channels: [IOReportChannel]) -> Int? {
        guard let gpu = channels.first(where: { $0.subgroup == "GPU Performance States" && $0.name == "GPUPH" }),
              case .states(let states) = gpu.value, !states.isEmpty else { return nil }
        return states.count
    }

    /// This Mac's top GPU clock (MHz, rounded) for run.json; nil when there is no fitting table. Slow-ish (one
    /// IOReport sample and one IORegistry read): call once per run.
    public static func currentMaxMHz() -> Int? {
        guard let sampler = try? IOReportSampler(groups: ["GPU Stats"]), let sample = sampler.sample(),
              let count = gpuphStateCount(in: IOReportSampler.channels(in: sample, readValues: true)),
              let max = loadTable(stateCount: count)?.max(), max > 0 else { return nil }
        return Int(max.rounded())
    }
}
