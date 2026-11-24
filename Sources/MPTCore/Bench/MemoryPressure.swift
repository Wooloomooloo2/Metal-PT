import Darwin
import Foundation

/// Memory pressure, swap and compressor (unprivileged; measured 2026-11-24, hardware-baseline): sysctl
/// `kern.memorystatus_vm_pressure_level` (1 normal, 2 warn, 4 critical), `vm.swapusage`, and `host_statistics64`
/// compressor pages and the cumulative pageout count. A nil field means "could not read".
public struct MemoryPressureReading: Sendable, Equatable {
    /// "normal", "warn" or "critical".
    public var level: String?
    public var swapUsedGB: Double?
    /// Physical memory held by the compressor, GiB.
    public var compressedGB: Double?
    /// Cumulative pageouts since boot (the sampler turns two readings into a rate).
    public var pageouts: UInt64?

    public init(level: String? = nil, swapUsedGB: Double? = nil, compressedGB: Double? = nil, pageouts: UInt64? = nil) {
        self.level = level; self.swapUsedGB = swapUsedGB; self.compressedGB = compressedGB; self.pageouts = pageouts
    }

    static func levelName(_ raw: Int?) -> String? {
        switch raw {
        case 1: "normal"
        case 2: "warn"
        case 4: "critical"
        default: nil
        }
    }

    /// Pageouts per second between two (count, uptime seconds) readings; nil if the counter went back or no time passed.
    static func pageoutsPerSecond(from a: (UInt64, Double), to b: (UInt64, Double)) -> Double? {
        let dt = b.1 - a.1
        guard dt > 0, b.0 >= a.0 else { return nil }
        return Double(b.0 - a.0) / dt
    }

    public static func read() -> MemoryPressureReading {
        var r = MemoryPressureReading()
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            r.level = levelName(Int(level))
        }
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            r.swapUsedGB = Double(swap.xsu_used) / gib
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            r.compressedGB = Double(stats.compressor_page_count) * Double(TelemetrySampler.kernelPageSize) / gib
            r.pageouts = stats.pageouts
        }
        return r
    }

    private static let gib = 1024.0 * 1024 * 1024
}
