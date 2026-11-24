import MPTCore

/// The Live page's "Limited by: GPU": the run analysis's per-second rules (`LimiterAnalysis.classify`) over the
/// last 30 s of hub snapshots. Pure; the page calls it on each update while following or recording.
public enum LiveLimiter {
    public enum Reading: Equatable, Sendable {
        /// One class holds at least `LimiterAnalysis.thresholds.mostlyShare` of the seconds (`.unclear` included:
        /// the page shows "No single limit", never "Limited by: no single limit").
        case limiter(Limiter)
        case mixed
    }

    /// Seconds of history looked at.
    public static let window = 30.0
    /// Fewer seconds with GPU busy than this → no reading (the chip hides).
    public static let minSeconds = 10

    /// The signals of one snapshot, as a run row would give them.
    public static func second(_ s: HubSnapshot) -> LimiterAnalysis.Second {
        let x = s.sample
        return LimiterAnalysis.Second(fps: s.fps, gpuBusyPct: x.gpuBusyPct, gpuMHz: x.gpuMHz, memPressure: x.memPressure,
                                      pageoutsPerSecond: x.pageoutsPerS, thermalState: x.thermalState,
                                      coreMaxPct: x.cpuCoreMaxPct, pCoresPct: x.cpuPUtilPct)
    }

    /// The reading over the snapshots of the last `window` seconds (by the newest snapshot's time) that have GPU
    /// busy; nil with fewer than `minSeconds` of them. `topMHz` is this Mac's top GPU clock, if known; the
    /// heat reference clock comes from the same seconds, as the run analysis takes it from the steady seconds.
    public static func current(_ history: [HubSnapshot], topMHz: Double?) -> Reading? {
        guard let newest = history.last?.time else { return nil }
        let seconds = history.reversed()
            .prefix { newest - $0.time < window }
            .map(second)
            .filter { $0.gpuBusyPct != nil }
        guard seconds.count >= minSeconds else { return nil }
        let clocks = LimiterAnalysis.Clocks(topMHz: topMHz, steady: seconds)
        var counts: [Limiter: Int] = [:]
        for s in seconds { counts[LimiterAnalysis.classify(s, clocks: clocks), default: 0] += 1 }
        let order = Limiter.allCases
        guard let top = counts.max(by: { a, b in
            a.value != b.value ? a.value < b.value : order.firstIndex(of: a.key)! > order.firstIndex(of: b.key)!
        }) else { return nil }
        let share = Double(top.value) / Double(seconds.count)
        return share >= LimiterAnalysis.thresholds.mostlyShare ? .limiter(top.key) : .mixed
    }

    /// "Limited by: GPU", "Limited by: mixed", "No single limit".
    public static func label(_ r: Reading) -> String {
        switch r {
        case .mixed: "Limited by: mixed"
        case .limiter(.unclear): "No single limit"
        case .limiter(let l): "Limited by: \(l.displayName)"
        }
    }
}
