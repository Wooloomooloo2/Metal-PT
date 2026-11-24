/// One once-per-second reading of the machine. A nil / missing field means "unknown", never zero.
public struct TelemetrySample: Sendable {
    public var gpuW: Double?
    public var cpuPUtilPct: Double?
    public var cpuEUtilPct: Double?
    public var cpuCoreMaxPct: Double?
    public var gpuBusyPct: Double?
    /// SMC key to watts (raw `flt` reading; meanings of most keys are unconfirmed).
    public var smcPower: [String: Double]
    public var tempMaxC: Double?
    public var tempBatteryC: Double?
    public var fanRPM: [Double]
    public var memUsedGB: Double?
    public var batteryPct: Int?
    /// Negative while discharging.
    public var batteryW: Double?
    public var onAC: Bool?
    public var thermalState: String

    public init(
        gpuW: Double? = nil, cpuPUtilPct: Double? = nil, cpuEUtilPct: Double? = nil, cpuCoreMaxPct: Double? = nil,
        gpuBusyPct: Double? = nil, smcPower: [String: Double] = [:], tempMaxC: Double? = nil,
        tempBatteryC: Double? = nil, fanRPM: [Double] = [], memUsedGB: Double? = nil, batteryPct: Int? = nil,
        batteryW: Double? = nil, onAC: Bool? = nil, thermalState: String = "nominal"
    ) {
        self.gpuW = gpuW
        self.cpuPUtilPct = cpuPUtilPct
        self.cpuEUtilPct = cpuEUtilPct
        self.cpuCoreMaxPct = cpuCoreMaxPct
        self.gpuBusyPct = gpuBusyPct
        self.smcPower = smcPower
        self.tempMaxC = tempMaxC
        self.tempBatteryC = tempBatteryC
        self.fanRPM = fanRPM
        self.memUsedGB = memUsedGB
        self.batteryPct = batteryPct
        self.batteryW = batteryW
        self.onAC = onAC
        self.thermalState = thermalState
    }
}
