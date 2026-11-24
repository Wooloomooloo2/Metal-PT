import Foundation
import IOKit
import CoreGraphics

/// Small readers for the `machine` and `settings` parts of run.json. No serial number, hostname or user name.
public enum MachineInfo {
    public static func current() -> RunInfo.Machine {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
                                    : "\(v.majorVersion).\(v.minorVersion)"
        let bytes = sysctlInt("hw.memsize") ?? 0
        return RunInfo.Machine(
            modelID: sysctlString("hw.model") ?? "",
            chip: sysctlString("machdep.cpu.brand_string") ?? "",
            gpuCores: gpuCoreCount(),
            memoryGB: Int((Double(bytes) / 1_073_741_824).rounded()),
            osVersion: os,
            osBuild: sysctlString("kern.osversion") ?? "",
            gpuMaxMHz: GPUClock.currentMaxMHz())
    }

    /// `base` with the main display's size (CGDisplayPixelsWide/High) and refresh rate (its current mode).
    public static func withMainDisplay(_ base: RunInfo.Settings) -> RunInfo.Settings {
        let id = CGMainDisplayID()
        let refresh = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        return displaySettings(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id), refreshHz: refresh,
                               base: base)
    }

    /// `base` with the display fields set; 0 (what CoreGraphics reports when it does not know) becomes nil.
    public static func displaySettings(width: Int, height: Int, refreshHz: Double,
                                       base: RunInfo.Settings) -> RunInfo.Settings {
        var s = base
        s.displayWidth = width > 0 ? width : nil
        s.displayHeight = height > 0 ? height : nil
        s.refreshHz = refreshHz > 0 && refreshHz.isFinite ? refreshHz : nil
        return s
    }

    /// `pmset -g` "powermode" (0 automatic, 1 low, 2 high); nil if absent or unreadable.
    public static func powerMode() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return powerMode(fromPMSet: String(decoding: data, as: UTF8.self))
    }

    static func powerMode(fromPMSet text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "powermode" else { continue }
            switch parts[1] {
            case "0": return "automatic"
            case "1": return "low"
            case "2": return "high"
            default: return String(parts[1])
            }
        }
        return nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    /// `gpu-core-count` of the AGXAccelerator IORegistry entry.
    static func gpuCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Int
    }
}
