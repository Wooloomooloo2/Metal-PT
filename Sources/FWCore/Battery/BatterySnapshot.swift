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
