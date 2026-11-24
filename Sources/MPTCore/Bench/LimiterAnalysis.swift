import Foundation

/// What held a second of a run back. Cases are listed in classification order (first match wins).
public enum Limiter: String, Codable, Sendable, CaseIterable {
    case memory, frameCap, gpuThermal, gpu, cpuOneThread, cpu, unclear

    /// The name used in verdicts ("Mostly GPU", "Mixed: GPU and CPU (one thread)").
    public var displayName: String {
        switch self {
        case .memory: "memory"
        case .frameCap: "a frame cap"
        case .gpuThermal: "GPU (thermal)"
        case .gpu: "GPU"
        case .cpuOneThread: "CPU (one thread)"
        case .cpu: "CPU"
        case .unclear: "no single limit"
        }
    }
}

/// "What held it back": classifies each steady second of a run (the same steady seconds as `RunSummary`) and
/// gives a verdict, the evidence for it and one suggestion. Pure: reads only the bundle and the summary.
///
/// Rules, first match wins (spec §E, with ruling L1 on the GPU clock):
/// 1. memory — `mem_pressure` warn/critical, or `pageouts_per_s` > 50.
/// 2. frameCap — FPS within ±2 % of a common cap and GPU busy < 90 %; or busy ≥ 90 % while the clock is below
///    85 % of the top clock (a capped game keeps the GPU busy at a low clock: measured 82–95 % busy at ~35 % clock).
/// 3. gpuThermal — busy ≥ 95 % and (thermal ≥ serious, or clock < 85 % of the reference clock while thermal ≥ fair).
///    Reference = min(top clock, 95th percentile of the steady seconds' clocks), so one warm-up spike does not count.
/// 4. gpu — busy ≥ 95 % and clock ≥ 85 % of the top clock. Without a clock (or top clock), busy alone.
/// 5. cpuOneThread — busy < 85 % and busiest core ≥ 90 %.
/// 6. cpu — busy < 85 % and P-cores ≥ 80 %.
/// 7. unclear — otherwise (including busy ≥ 95 % at a low clock without heat: the game isn't pushing the GPU).
public struct LimiterAnalysis: Sendable {
    /// Every number the rules use, in one table. Defaults are spec §E plus ruling L1.
    public struct Thresholds: Sendable {
        /// Memory pressure levels that count as memory-limited.
        public var memoryPressureLevels: Set<String> = ["warn", "critical"]
        /// Pageouts per second above which a second is memory-limited.
        public var pageoutsPerSecond: Double = 50
        /// FPS values treated as caps.
        public var frameCaps: [Double] = [30, 40, 45, 60, 90, 120, 144]
        /// How close FPS must be to a cap, as a fraction of the cap.
        public var frameCapTolerance: Double = 0.02
        /// A capped second needs GPU busy below this (unless the clock is low, see `gpuClockFraction`).
        public var frameCapMaxGPUBusyPct: Double = 90
        /// GPU busy at or above this is GPU-bound (subject to the clock).
        public var gpuBusyPct: Double = 95
        /// Clock at or above this fraction of the top clock counts as "pushing the GPU"; below it while hot is thermal.
        public var gpuClockFraction: Double = 0.85
        /// CPU rules need GPU busy below this.
        public var cpuMaxGPUBusyPct: Double = 85
        /// Busiest core at or above this is one-thread-bound.
        public var coreMaxPct: Double = 90
        /// P-cores at or above this is CPU-bound.
        public var pCoresPct: Double = 80
        /// The largest class needs this share of steady seconds for "Mostly …"; otherwise "Mixed".
        public var mostlyShare: Double = 0.6

        public init() {}
    }

    public static let thresholds = Thresholds()

    /// The rules in plain words, for the report's "How this is decided".
    public static func describeThresholds(_ t: Thresholds = thresholds) -> [String] {
        let caps = t.frameCaps.map { pct($0) }.joined(separator: ", ")
        return [
            "Memory: memory pressure \(t.memoryPressureLevels.sorted().joined(separator: " or ")), or more than "
                + "\(pct(t.pageoutsPerSecond)) pageouts per second.",
            "Frame cap: FPS within ±\(pct(t.frameCapTolerance * 100)) % of \(caps) and GPU busy below "
                + "\(pct(t.frameCapMaxGPUBusyPct)) % (or above it while the GPU clock is under "
                + "\(pct(t.gpuClockFraction * 100)) % of its top clock).",
            "GPU (thermal): GPU busy at least \(pct(t.gpuBusyPct)) % and thermal state serious, or the clock under "
                + "\(pct(t.gpuClockFraction * 100)) % of its steady peak (95th percentile, capped at the top clock) while "
                + "thermal state is fair or worse.",
            "GPU: GPU busy at least \(pct(t.gpuBusyPct)) % with the clock at least \(pct(t.gpuClockFraction * 100)) % "
                + "of its top clock (busy alone when no clock was recorded).",
            "CPU (one thread): GPU busy under \(pct(t.cpuMaxGPUBusyPct)) % and the busiest core at least "
                + "\(pct(t.coreMaxPct)) %.",
            "CPU: GPU busy under \(pct(t.cpuMaxGPUBusyPct)) % and the P-cores at least \(pct(t.pCoresPct)) %.",
            "Each steady second takes the first rule that matches (otherwise unclear); the verdict is \"Mostly\" the "
                + "largest class when it holds at least \(pct(t.mostlyShare * 100)) % of steady seconds, else \"Mixed\".",
        ]
    }

    /// Share of steady seconds per class, largest first; classes with no seconds are left out.
    public let shares: [(Limiter, Double)]
    public let verdict: String
    /// The class of a "Mostly" verdict; nil when mixed or when there are no steady seconds.
    public let primary: Limiter?
    /// Medians of the signals that triggered the verdict's class (or both classes of a mixed verdict).
    public let evidence: [String]
    public let suggestion: String?
    /// Inputs this run lacks ("no GPU clock recorded", "no memory pressure recorded", …).
    public let missing: [String]
    /// The class of each steady second, in `summary.steadySeconds` order.
    public let perSecond: [Limiter]

    /// The signals of one second the rules use. nil = not recorded.
    public struct Second: Sendable {
        public var fps: Double?
        public var gpuBusyPct: Double?
        public var gpuMHz: Double?
        public var memPressure: String?
        public var pageoutsPerSecond: Double?
        /// 0 nominal, 1 fair, 2 serious, 3 critical.
        public var thermalLevel: Int
        public var coreMaxPct: Double?
        public var pCoresPct: Double?

        public init(row: [String: String]) {
            func num(_ k: String) -> Double? {
                guard let s = row[k], !s.isEmpty, let v = Double(s), v.isFinite else { return nil }
                return v
            }
            fps = num("fps"); gpuBusyPct = num("gpu_busy_pct"); gpuMHz = num("gpu_mhz")
            memPressure = row["mem_pressure"].flatMap { $0.isEmpty ? nil : $0 }
            pageoutsPerSecond = num("pageouts_per_s")
            thermalLevel = ["fair": 1, "serious": 2, "critical": 3][row["thermal_state"] ?? ""] ?? 0
            coreMaxPct = num("cpu_core_max_pct"); pCoresPct = num("cpu_p_util_pct")
        }
    }

    /// The clock references a second is judged against.
    public struct Clocks: Sendable {
        /// Top clock of the GPU (run.json `machine.gpuMaxMHz`).
        public var topMHz: Double?
        /// The clock a heat-driven drop is measured against: min(top clock, 95th percentile of steady `gpu_mhz`).
        public var referenceMHz: Double?
        public init(topMHz: Double?, referenceMHz: Double?) { self.topMHz = topMHz; self.referenceMHz = referenceMHz }

        /// Builds the clocks for the steady seconds `steady` of a GPU whose top clock is `topMHz`.
        public init(topMHz: Double?, steady: [Second]) {
            let sorted = steady.compactMap(\.gpuMHz).sorted()
            let p95 = sorted.isEmpty ? nil : RunSummary.percentile(sorted, 0.95)
            self.topMHz = topMHz
            switch (topMHz, p95) {
            case let (t?, p?): referenceMHz = Swift.min(t, p)
            case let (t, p): referenceMHz = t ?? p
            }
        }
    }

    /// The cap `fps` sits at, if any.
    static func cap(_ fps: Double?, _ t: Thresholds) -> Double? {
        guard let fps else { return nil }
        return t.frameCaps.first { abs(fps - $0) <= $0 * t.frameCapTolerance }
    }

    /// Clock as a fraction of the top clock, when both are known.
    static func clockFraction(_ s: Second, _ c: Clocks) -> Double? {
        guard let mhz = s.gpuMHz, let top = c.topMHz, top > 0 else { return nil }
        return mhz / top
    }

    /// Busy ≥ 95 % at a clock under 85 % of the top clock: the GPU is not being pushed.
    static func busyAtLowClock(_ s: Second, _ c: Clocks, _ t: Thresholds) -> Bool {
        guard let busy = s.gpuBusyPct, busy >= t.gpuBusyPct, let f = clockFraction(s, c) else { return false }
        return f < t.gpuClockFraction
    }

    /// Classifies one second (first match wins).
    public static func classify(_ s: Second, clocks c: Clocks, thresholds t: Thresholds = thresholds) -> Limiter {
        if let p = s.memPressure, t.memoryPressureLevels.contains(p) { return .memory }
        if let po = s.pageoutsPerSecond, po > t.pageoutsPerSecond { return .memory }
        guard let busy = s.gpuBusyPct else { return .unclear }
        let fraction = clockFraction(s, c)
        if cap(s.fps, t) != nil {
            if busy < t.frameCapMaxGPUBusyPct { return .frameCap }
            if let f = fraction, f < t.gpuClockFraction { return .frameCap }
        }
        if busy >= t.gpuBusyPct {
            if s.thermalLevel >= 2 { return .gpuThermal }
            if s.thermalLevel >= 1, let mhz = s.gpuMHz, let ref = c.referenceMHz, ref > 0,
               mhz < ref * t.gpuClockFraction { return .gpuThermal }
            if let f = fraction, f < t.gpuClockFraction { return .unclear }
            return .gpu
        }
        if busy < t.cpuMaxGPUBusyPct {
            if let m = s.coreMaxPct, m >= t.coreMaxPct { return .cpuOneThread }
            if let p = s.pCoresPct, p >= t.pCoresPct { return .cpu }
        }
        return .unclear
    }

    public init(_ bundle: RunBundle, summary: RunSummary) {
        let t = Self.thresholds
        let rows = bundle.rows
        let seconds = summary.steadySeconds.map { Second(row: rows[$0]) }
        let clocks = Clocks(topMHz: bundle.info.machine.gpuMaxMHz.map(Double.init), steady: seconds)

        var missing: [String] = []
        if !seconds.contains(where: { $0.fps != nil }) { missing.append("no FPS recorded") }
        if !seconds.contains(where: { $0.gpuBusyPct != nil }) { missing.append("no GPU busy recorded") }
        if !seconds.contains(where: { $0.gpuMHz != nil }) {
            missing.append("no GPU clock recorded")
        } else if clocks.topMHz == nil {
            missing.append("no GPU top clock recorded")
        }
        if !seconds.contains(where: { $0.memPressure != nil || $0.pageoutsPerSecond != nil }) {
            missing.append("no memory pressure recorded")
        }
        self.missing = missing

        let classes = seconds.map { Self.classify($0, clocks: clocks, thresholds: t) }
        perSecond = classes
        let n = Double(classes.count)
        let order = Limiter.allCases
        let shares: [(Limiter, Double)] = order.compactMap { l in
            let k = classes.filter { $0 == l }.count
            return k > 0 ? (l, Double(k) / n) : nil
        }.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : order.firstIndex(of: a.0)! < order.firstIndex(of: b.0)! }
        self.shares = shares

        guard let top = shares.first else {
            verdict = "Not enough steady seconds to tell what held it back"
            primary = nil; evidence = []; suggestion = nil
            return
        }
        func members(_ l: Limiter) -> [Second] { zip(seconds, classes).filter { $0.1 == l }.map(\.0) }
        func ev(_ l: Limiter) -> [String] {
            Self.evidence(for: l, seconds: members(l), all: seconds, clocks: clocks, thresholds: t)
        }
        if top.1 >= t.mostlyShare {
            verdict = top.0 == .unclear ? "No single limit stood out" : "Mostly \(top.0.displayName)"
            primary = top.0
            evidence = ev(top.0)
            suggestion = Self.suggestion(for: top.0, seconds: members(top.0), clocks: clocks, thresholds: t)
        } else {
            let second = shares[1]
            verdict = "Mixed: \(top.0.displayName) and \(second.0.displayName)"
            primary = nil
            evidence = ev(top.0) + ev(second.0)
            suggestion = nil
        }
    }

    // MARK: - Evidence and suggestions

    private static func pct(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    private static func med(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : RunSummary.median(values.sorted())
    }

    private static func rounded(_ v: Double) -> String { String(Int(v.rounded())) }

    private static func secondsWord(_ n: Int) -> String { "\(n) s" }

    static func evidence(for l: Limiter, seconds s: [Second], all: [Second], clocks c: Clocks,
                         thresholds t: Thresholds) -> [String] {
        var out: [String] = []
        let busy = med(s.compactMap(\.gpuBusyPct))
        let busyLine = busy.map { "GPU busy median \(rounded($0)) % (\(secondsWord(s.count)))" }
        func clockLine(_ ref: Double?, _ what: String) -> String? {
            guard let mhz = med(s.compactMap(\.gpuMHz)), let ref, ref > 0 else { return nil }
            return "GPU clock median \(rounded(mhz)) MHz (\(rounded(mhz / ref * 100)) % of \(what) \(rounded(ref)) MHz)"
        }
        switch l {
        case .memory:
            let levels = Dictionary(grouping: s.compactMap(\.memPressure).filter { t.memoryPressureLevels.contains($0) },
                                    by: { $0 })
            for level in levels.keys.sorted() { out.append("Memory pressure \(level) for \(levels[level]!.count) s") }
            let high = s.compactMap(\.pageoutsPerSecond).filter { $0 > t.pageoutsPerSecond }
            if let m = med(high) { out.append("Pageouts median \(rounded(m)) per second (\(high.count) s)") }
        case .frameCap:
            if let fps = med(s.compactMap(\.fps)) {
                let capLine = mostCommonCap(s, t).map { " — at the \(pct($0)) fps cap" } ?? ""
                out.append("FPS median \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), fps))\(capLine)")
            }
            if let busyLine { out.append(busyLine) }
            if let line = clockLine(c.topMHz, "its top clock") { out.append(line) }
        case .gpuThermal:
            if let busyLine { out.append(busyLine) }
            let hot = Dictionary(grouping: s.filter { $0.thermalLevel >= 1 }, by: \.thermalLevel)
            for level in hot.keys.sorted(by: >) {
                out.append("Thermal state \(["", "fair", "serious", "critical"][level]) for \(hot[level]!.count) s")
            }
            if let line = clockLine(c.referenceMHz, "its peak") { out.append(line) }
        case .gpu:
            if let busyLine { out.append(busyLine) }
            if let line = clockLine(c.topMHz, "its top clock") { out.append(line) }
        case .cpuOneThread:
            if let m = med(s.compactMap(\.coreMaxPct)) { out.append("Busiest CPU core median \(rounded(m)) %") }
            if let busyLine { out.append(busyLine) }
        case .cpu:
            if let m = med(s.compactMap(\.pCoresPct)) { out.append("CPU P-cores median \(rounded(m)) %") }
            if let busyLine { out.append(busyLine) }
        case .unclear:
            let low = s.filter { busyAtLowClock($0, c, t) }
            if let f = med(low.compactMap { clockFraction($0, c) }) {
                out.append("GPU busy but running at \(rounded(f * 100)) % of its top clock — the game isn't pushing it")
            }
            if low.count < s.count {
                var parts: [String] = []
                if let busy { parts.append("GPU busy median \(rounded(busy)) %") }
                if let m = med(s.compactMap(\.coreMaxPct)) { parts.append("busiest core median \(rounded(m)) %") }
                if !parts.isEmpty {
                    out.append("No single limit (\(secondsWord(s.count))): " + parts.joined(separator: ", "))
                }
            }
        }
        return out
    }

    private static func mostCommonCap(_ s: [Second], _ t: Thresholds) -> Double? {
        let counts = Dictionary(grouping: s.compactMap { cap($0.fps, t) }, by: { $0 }).mapValues(\.count)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// Median clock of `s` as a fraction of the reference clock, when it dropped below the clock threshold.
    static func clockDrop(_ s: [Second], _ c: Clocks, _ t: Thresholds) -> Double? {
        guard let mhz = med(s.compactMap(\.gpuMHz)), let ref = c.referenceMHz, ref > 0,
              mhz / ref < t.gpuClockFraction else { return nil }
        return mhz / ref
    }

    /// One suggestion, worded to match what was measured.
    static func suggestion(for l: Limiter, seconds s: [Second], clocks c: Clocks, thresholds t: Thresholds) -> String? {
        switch l {
        case .gpu:
            "Lower the resolution or GPU-heavy settings, or use MetalFX upscaling / frame generation; CPU-side changes won't help."
        case .gpuThermal:
            if let f = clockDrop(s, c, t) {
                "The GPU clock dropped to \(rounded(f * 100)) % of its peak under heat: a cooler surface or (later) "
                    + "a stronger fan curve with Metal-PT Helper may help."
            } else {
                "macOS reported \(["fair", "fair", "serious", "critical"][s.map(\.thermalLevel).max() ?? 2]) thermal "
                    + "pressure while the GPU was fully busy; performance may be limited by heat."
            }
        case .cpuOneThread:
            "One CPU thread is the limit: lowering graphics settings is unlikely to help; reduce CPU-heavy settings such as "
                + "crowd density or simulation."
        case .cpu:
            "The CPU is busy across cores: reduce CPU-heavy settings."
        case .memory:
            "Memory is under pressure: close other apps or lower texture quality."
        case .frameCap:
            mostCommonCap(s, t).map {
                "Looks capped at \(pct($0)) fps (V-Sync or an in-game limit): raise or remove the cap if you want more."
            }
        case .unclear:
            nil
        }
    }
}
