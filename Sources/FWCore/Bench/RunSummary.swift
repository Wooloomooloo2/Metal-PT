import Foundation

public struct ColumnStats: Sendable, Equatable {
    public let min: Double
    public let mean: Double
    public let median: Double
    public let p5: Double
    public let max: Double
    public let count: Int
}

/// The numbers a run report shows, computed from the steady part of a run.
public struct RunSummary: Sendable {
    /// Indices into `bundle.rows` of the steady seconds.
    public let steadySeconds: [Int]
    public let stats: [String: ColumnStats]
    public let medianFPS: Double?
    public let p5FPS: Double?
    public let low1: Double?
    public let low01: Double?
    public let fpsPerWatt: Double?
    public let powerColumn: String?
    public let notes: [String]

    private static let skipColumns: Set<String> = ["t", "fps_app", "thermal_state", "fps_pid", "on_ac"]

    /// Ascending sort, index ceil(p*n)-1 clamped to >= 0.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let idx = Swift.min(sorted.count - 1, Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[idx]
    }

    static func median(_ sorted: [Double]) -> Double {
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    public init(_ bundle: RunBundle) {
        let rows = bundle.rows
        func elapsed(_ i: Int) -> Double? { rows[i]["elapsed_s"].flatMap(Double.init) }
        func fps(_ i: Int) -> Double? {
            guard let s = rows[i]["fps"], !s.isEmpty else { return nil }
            return Double(s)
        }

        var steady: [Int]
        if let start = bundle.info.steadyStartS, start > 0 {
            let end = bundle.info.steadyEndS ?? .infinity
            steady = rows.indices.filter { i in elapsed(i).map { $0 >= start && $0 <= end } ?? false }
        } else {
            let withFPS = rows.indices.filter { fps($0) != nil }
            if withFPS.isEmpty {
                steady = Array(rows.indices)
            } else {
                var counts: [String: Int] = [:]
                for i in withFPS { let a = rows[i]["fps_app"] ?? ""; if !a.isEmpty { counts[a, default: 0] += 1 } }
                // Most common app; ties broken by name so the result is deterministic.
                let followed = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
                let candidates = withFPS.filter { followed == nil || rows[$0]["fps_app"] == followed }
                if let t0 = candidates.compactMap(elapsed).first {
                    let trimmed = candidates.filter { (elapsed($0) ?? 0) >= t0 + 10 }
                    let med = Self.median(trimmed.compactMap(fps).sorted())
                    steady = trimmed.isEmpty ? [] : trimmed.filter { (fps($0) ?? 0) <= 2 * med }
                } else {
                    steady = candidates
                }
            }
        }
        steadySeconds = steady

        // Per-column stats over steady rows.
        var stats: [String: ColumnStats] = [:]
        for col in SampleColumns.all where !Self.skipColumns.contains(col) {
            let vals = steady.compactMap { rows[$0][col].flatMap { $0.isEmpty ? nil : Double($0) } }
                .filter { $0.isFinite }.sorted()
            guard !vals.isEmpty else { continue }
            stats[col] = ColumnStats(min: vals[0], mean: vals.reduce(0, +) / Double(vals.count),
                                     median: Self.median(vals), p5: Self.percentile(vals, 0.05),
                                     max: vals[vals.count - 1], count: vals.count)
        }
        self.stats = stats
        medianFPS = stats["fps"]?.median
        p5FPS = stats["fps"]?.p5

        // Lows from frames in the steady window.
        var low1: Double?, low01: Double?
        let times = steady.compactMap(elapsed)
        if let frames = bundle.frames, let first = times.min(), let last = times.max() {
            let lo = first, hi = last + 1
            let intervals = frames.filter { $0.tMs / 1000 >= lo && $0.tMs / 1000 < hi }
                .map(\.intervalMs).sorted()
            if !intervals.isEmpty {
                let a = Self.percentile(intervals, 0.99), b = Self.percentile(intervals, 0.999)
                low1 = a > 0 ? 1000 / a : nil
                low01 = b > 0 ? 1000 / b : nil
            }
        }
        self.low1 = low1
        self.low01 = low01

        let power = stats["smc_PSTR_w"] != nil ? "smc_PSTR_w" : (stats["gpu_w"] != nil ? "gpu_w" : nil)
        powerColumn = power
        if let m = medianFPS, let p = power, let mean = stats[p]?.mean, mean > 0 {
            fpsPerWatt = m / mean
        } else {
            fpsPerWatt = nil
        }

        var notes: [String] = []
        if medianFPS == nil { notes.append("no FPS source") }
        let steadyCount = steady.count
        if steadyCount < 60 { notes.append("short run (\(steadyCount) s steady)") }
        if steady.contains(where: { rows[$0]["on_ac"] == "0" }) { notes.append("on battery") }
        for state in ["fair", "serious", "critical"] {
            let n = steady.filter { rows[$0]["thermal_state"] == state }.count
            if n > 0 { notes.append("thermal pressure: \(state) for \(n) s") }
        }
        self.notes = notes
    }
}
