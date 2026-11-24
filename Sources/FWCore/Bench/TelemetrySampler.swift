import Darwin
import Foundation

/// Reads power, utilisation, temperature, fans, memory and battery for the benchmark recorder.
///
/// `init()` never throws: each source (IOReport, SMC) that fails to open is simply absent and its fields stay
/// nil / empty; a single key that fails to read is omitted. Use from one thread only.
/// The first `sample()` primes IOReport and returns nil power/utilisation fields.
public final class TelemetrySampler {
    static let smcPowerKeys = ["PSTR", "PDTR", "PHPC", "PHPS", "PSVR", "PZC0", "PZC1", "PMVC", "PPMC", "PPSC"]

    private let ioreport: IOReportSampler?
    private let smc: SMCConnection?
    /// Die sensors only (R13); if the machine has none, every sensor except the constant "PMU tcal".
    private let temperatures: HIDTemperatureSource = {
        let die = HIDTemperatureSource(include: TelemetrySampler.isDieSensor)
        return die.sensorCount > 0 ? die : HIDTemperatureSource(include: { $0 != TelemetrySampler.calibrationSensor })
    }()
    private var previous: (sample: CFDictionary, uptime: TimeInterval)?

    public init() {
        ioreport = try? IOReportSampler(groups: ["Energy Model", "CPU Stats", "GPU Stats"])
        smc = try? SMCConnection()
    }

    public func sample() -> TelemetrySample {
        var result = TelemetrySample()
        result.thermalState = Self.thermalName(ProcessInfo.processInfo.thermalState)
        sampleIOReport(into: &result)
        sampleSMC(into: &result)
        let temps = temperatures.read()
        result.tempMaxC = Self.maxTemperature(temps)
        result.memUsedGB = Self.memoryUsedGB()
        if let battery = try? SmartBatteryReader.read() {
            result.batteryPct = battery.percent
            result.onAC = battery.externalConnected
            if let mV = battery.voltageMillivolts, let mA = battery.amperageMilliamps {
                result.batteryW = Double(mV) * Double(mA) / 1e6
            }
        }
        return result
    }

    private func sampleIOReport(into result: inout TelemetrySample) {
        guard let ioreport, let current = ioreport.sample() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = (current, now) }
        guard let previous else { return }
        let seconds = now - previous.uptime
        let channels = ioreport.delta(from: previous.sample, to: current)

        if let gpu = channels.first(where: { $0.group == "Energy Model" && $0.name == "GPU Energy" }),
           case .simple(let value) = gpu.value,
           let joules = PowerMath.joules(value, unit: gpu.unit) {
            result.gpuW = PowerMath.watts(joules: joules, seconds: seconds)
        }

        let aggregate = Utilisation.aggregate(channels)
        result.cpuPUtilPct = aggregate.pUtil
        result.cpuEUtilPct = aggregate.eUtil
        result.cpuCoreMaxPct = aggregate.coreMax
        result.gpuBusyPct = aggregate.gpuBusy
    }

    private func sampleSMC(into result: inout TelemetrySample) {
        guard let smc else { return }
        for key in Self.smcPowerKeys {
            if let value = try? smc.read(FourCC(string: key)!).number { result.smcPower[key] = value }
        }
        // Key names are "F<digit>Ac", so at most 10 fans.
        if let count = (try? smc.read("FNum"))?.number, count >= 0 {
            for index in 0..<min(Int(count), 10) {
                if let key = FourCC(string: "F\(index)Ac"), let rpm = (try? smc.read(key))?.number {
                    result.fanRPM.append(rpm)
                }
            }
        }
        result.tempBatteryC = (try? smc.read("TB0T"))?.number
    }

    static let calibrationSensor = "PMU tcal"
    static func isDieSensor(_ name: String) -> Bool { name.hasPrefix("PMU tdie") }

    /// Hottest "PMU tdie*" sensor; without any, the hottest of the rest except "PMU tcal" (a calibration value that
    /// reads a constant 51.9 at idle and under load on M4 Max, measured 2026-11-24).
    static func maxTemperature(_ readings: [TemperatureReading]) -> Double? {
        let die = readings.filter { isDieSensor($0.name) }
        let pool = die.isEmpty ? readings.filter { $0.name != calibrationSensor } : die
        return pool.map(\.celsius).max()
    }

    /// (active + wired + compressor pages) × kernel page size, in GiB (1024³ bytes).
    static func memoryUsedGB() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let pages = Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)
        return pages * Double(Self.kernelPageSize) / (1024 * 1024 * 1024)
    }

    /// `vm_kernel_page_size` is a mutable C global (rejected by Swift 6); ask the kernel via sysctl instead.
    private static var kernelPageSize: Int {
        var size = 0
        var length = MemoryLayout<Int>.size
        return sysctlbyname("vm.pagesize", &size, &length, nil, 0) == 0 && size > 0 ? size : 16384
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
    }
}
