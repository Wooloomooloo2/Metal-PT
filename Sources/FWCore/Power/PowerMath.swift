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
