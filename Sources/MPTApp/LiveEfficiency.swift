import Foundation
import MPTCore

/// The Live page's and overlay's "FPS/W": mean FPS / mean system power (SMC `PSTR`) over the last `window` seconds
/// of hub snapshots, the live counterpart of a run's `RunSummary.fpsPerWatt`. Pure; it reads the history the hub
/// already keeps (nothing new is sampled).
public enum LiveEfficiency {
    /// Seconds of history looked at (by the newest snapshot's time).
    public static let window = 10.0
    /// Below this mean system power there is no figure (no division by ~0 W).
    public static let minWatts = 1.0

    /// nil when the window has no FPS or no system power, or the mean power is under `minWatts`.
    public static func fpsPerWatt(history: [HubSnapshot], window: Double = LiveEfficiency.window) -> Double? {
        guard let newest = history.last?.time else { return nil }
        let recent = history.reversed().prefix { newest - $0.time < window }
        let fps = recent.compactMap(\.fps).filter { $0.isFinite && $0 >= 0 }
        let watts = recent.compactMap { $0.sample.smcPower["PSTR"] }.filter(\.isFinite)
        guard !fps.isEmpty, !watts.isEmpty else { return nil }
        let meanW = watts.reduce(0, +) / Double(watts.count)
        guard meanW >= minWatts else { return nil }
        return (fps.reduce(0, +) / Double(fps.count)) / meanW
    }

    /// "1.76"; "–" when unknown (as the Live page's other numbers).
    public static func text(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
