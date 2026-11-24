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
/// Rules, first match wins (spec §E, with rulings L1 and L3 on the GPU clock):
/// 1. memory — `mem_pressure` warn/critical, or `pageouts_per_s` > 50.
/// 2. frameCap — FPS within ±2 % of a common cap (or the display's refresh rate or half of it) and GPU busy < 90 %;
///    or busy ≥ 90 % at a low clock (a capped game keeps the GPU busy at a low clock: measured 82–95 % busy at ~35 %).
/// 3. gpuThermal — busy ≥ 95 % and (thermal ≥ serious, or clock < 85 % of the reference clock while thermal ≥ fair).
///    Reference = min(top clock, 95th percentile of the steady seconds' clocks), so one warm-up spike does not count.
/// 4. gpu — busy ≥ 95 % and the clock not low. "Low" = under `gpuBoundMHz` (85 % of the top clock, lowered to the
///    table's top steps — ruling L3, the P*n* ↔ MHz mapping is [?]). Busy alone without a clock (or top clock), and
///    when the clock is power-managed (low power mode, or most steady seconds on battery).
/// 5. cpuOneThread — busy < 85 % and busiest core ≥ 90 %.
/// 6. cpu — busy < 85 % and P-cores ≥ 80 %.
/// 7. unclear — otherwise (including busy ≥ 95 % at a low clock without heat).
///
/// Only seconds with GPU busy (or a memory signal that classifies them as memory) are judged (`isJudged`); the Live
/// chip filters the same way.
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
            "Frame cap: FPS within ±\(pct(t.frameCapTolerance * 100)) % of \(caps) (or the display's refresh rate or "
                + "half of it) and GPU busy below \(pct(t.frameCapMaxGPUBusyPct)) % (or above it while the GPU clock is "
                + "low, as below).",
            "GPU (thermal): GPU busy at least \(pct(t.gpuBusyPct)) % and thermal state serious, or the clock under "
                + "\(pct(t.gpuClockFraction * 100)) % of its steady peak (95th percentile, capped at the top clock) while "
                + "thermal state is fair or worse.",
            "GPU: GPU busy at least \(pct(t.gpuBusyPct)) % with the clock at least \(pct(t.gpuClockFraction * 100)) % "
                + "of its top clock or at one of the top steps of its frequency table, whichever is lower (busy alone "
                + "when no clock was recorded, or in low power mode or on battery, where macOS manages the clock). "
                + "The clock reading is not yet verified on this Mac.",
            "CPU (one thread): GPU busy under \(pct(t.cpuMaxGPUBusyPct)) % and the busiest core at least "
                + "\(pct(t.coreMaxPct)) %.",
            "CPU: GPU busy under \(pct(t.cpuMaxGPUBusyPct)) % and the P-cores at least \(pct(t.pCoresPct)) %.",
            "Each steady second takes the first rule that matches (otherwise unclear); the verdict is \"Mostly\" the "
                + "largest class when it holds at least \(pct(t.mostlyShare * 100)) % of steady seconds, else \"Mixed\".",
        ]
    }

    /// Share of judged steady seconds per class, largest first; classes with no seconds are left out.
    public let shares: [(Limiter, Double)]
    public let verdict: String
    /// The class of a "Mostly" verdict; nil when mixed or when there are no steady seconds.
    public let primary: Limiter?
    /// The limiter of a mixed verdict whose other class is `.unclear` ("Partly GPU (otherwise no single limit)").
    public let partly: Limiter?
    /// Medians of the signals that triggered the verdict's class (or both classes of a mixed verdict).
    public let evidence: [String]
    public let suggestion: String?
    /// Inputs this run lacks ("no GPU clock recorded", "no memory pressure recorded", …).
    public let missing: [String]
    /// How the rules were applied to this run ("power-managed clocks: GPU judged on busy % only").
    public let notes: [String]
    /// The class of each judged steady second (`isJudged`), in `summary.steadySeconds` order.
    public let perSecond: [Limiter]

    public static let powerManagedNote = "power-managed clocks: GPU judged on busy % only"

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
            thermalLevel = Self.thermalLevel(row["thermal_state"] ?? "")
            coreMaxPct = num("cpu_core_max_pct"); pCoresPct = num("cpu_p_util_pct")
        }

        public init(fps: Double?, gpuBusyPct: Double?, gpuMHz: Double?, memPressure: String?,
                    pageoutsPerSecond: Double?, thermalState: String, coreMaxPct: Double?, pCoresPct: Double?) {
            func finite(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
            self.fps = finite(fps); self.gpuBusyPct = finite(gpuBusyPct); self.gpuMHz = finite(gpuMHz)
            self.memPressure = memPressure.flatMap { $0.isEmpty ? nil : $0 }
            self.pageoutsPerSecond = finite(pageoutsPerSecond)
            thermalLevel = Self.thermalLevel(thermalState)
            self.coreMaxPct = finite(coreMaxPct); self.pCoresPct = finite(pCoresPct)
        }

        /// `thermal_state` text → 0 nominal (or unknown), 1 fair, 2 serious, 3 critical.
        public static func thermalLevel(_ state: String) -> Int {
            ["fair": 1, "serious": 2, "critical": 3][state] ?? 0
        }
    }

    /// The clock references a second is judged against.
    public struct Clocks: Sendable {
        /// Top clock of the GPU (run.json `machine.gpuMaxMHz`).
        public var topMHz: Double?
        /// The clock a heat-driven drop is measured against: min(top clock, 95th percentile of steady `gpu_mhz`).
        public var referenceMHz: Double?
        /// The GPU frequency table, P1…Pn (run.json `machine.gpuClockTableMHz`); nil when unknown.
        public var tableMHz: [Double]?
        /// macOS manages the clock (low power mode, on battery): the GPU rule ignores the clock.
        public var powerManaged: Bool

        public init(topMHz: Double?, referenceMHz: Double?, tableMHz: [Double]? = nil, powerManaged: Bool = false) {
            self.topMHz = topMHz; self.referenceMHz = referenceMHz
            self.tableMHz = tableMHz; self.powerManaged = powerManaged
        }

        /// Builds the clocks for the steady seconds `steady` of a GPU whose top clock is `topMHz`.
        public init(topMHz: Double?, steady: [Second], tableMHz: [Double]? = nil, powerManaged: Bool = false) {
            let sorted = steady.compactMap(\.gpuMHz).sorted()
            let p95 = sorted.isEmpty ? nil : RunSummary.percentile(sorted, 0.95)
            self.topMHz = topMHz
            self.tableMHz = tableMHz
            self.powerManaged = powerManaged
            switch (topMHz, p95) {
            case let (t?, p?): referenceMHz = Swift.min(t, p)
            case let (t, p): referenceMHz = t ?? p
            }
        }
    }

    /// The clock at or above which a fully busy GPU counts as GPU-bound (ruling L3): `fraction` of the top clock,
    /// lowered to the table's second-highest distinct value and to the lowest step at or after the first step that
    /// reaches `fraction` (the measured table is not monotonic: P12 1380 MHz = 87 %, P13 1326 MHz = 84 %). The
    /// P*n* ↔ MHz mapping is [?] until a GPU-bound game run confirms it. nil without a top clock.
    public static func gpuBoundMHz(top: Double?, table: [Double]?, fraction: Double) -> Double? {
        guard let top, top > 0 else { return nil }
        var mhz = top * fraction
        if let table = table?.filter({ $0 > 0 }), !table.isEmpty {
            let distinct = Set(table).sorted(by: >)
            if distinct.count >= 2 { mhz = Swift.min(mhz, distinct[1]) }
            if let i = table.firstIndex(where: { $0 >= top * fraction }), let low = table[i...].min() {
                mhz = Swift.min(mhz, low)
            }
        }
        return mhz
    }

    /// True when the clock is power-managed: low power mode, or most of `onAC` (one per second) is false.
    public static func powerManaged(powerMode: String?, onAC: [Bool?]) -> Bool {
        powerMode == "low" || onAC.filter { $0 == false }.count * 2 > onAC.count
    }

    /// `base` plus the display's refresh rate and half of it, when known and not already listed (within 0.5 fps).
    public static func frameCaps(_ base: [Double], refreshHz: Double?) -> [Double] {
        guard let r = refreshHz, r.isFinite, r > 0 else { return base }
        var caps = base
        for c in [r, r / 2] where !caps.contains(where: { abs($0 - c) < 0.5 }) { caps.append(c) }
        return caps
    }

    /// A memory second, by rule 1.
    static func isMemory(_ s: Second, _ t: Thresholds) -> Bool {
        if let p = s.memPressure, t.memoryPressureLevels.contains(p) { return true }
        if let po = s.pageoutsPerSecond, po > t.pageoutsPerSecond { return true }
        return false
    }

    /// A second the rules can judge: it has GPU busy, or it is a memory second. Shared by the run analysis and Live.
    public static func isJudged(_ s: Second, thresholds t: Thresholds = thresholds) -> Bool {
        s.gpuBusyPct != nil || isMemory(s, t)
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

    /// The clock is under `gpuBoundMHz` (half a MHz of slack: `gpu_mhz` is written rounded). Never when the clock is
    /// power-managed or unknown.
    static func lowClock(_ s: Second, _ c: Clocks, _ t: Thresholds) -> Bool {
        guard !c.powerManaged, let mhz = s.gpuMHz,
              let bound = gpuBoundMHz(top: c.topMHz, table: c.tableMHz, fraction: t.gpuClockFraction) else { return false }
        return mhz + 0.5 < bound
    }

    /// Busy ≥ 95 % at a low clock: the GPU may not be working flat out.
    static func busyAtLowClock(_ s: Second, _ c: Clocks, _ t: Thresholds) -> Bool {
        guard let busy = s.gpuBusyPct, busy >= t.gpuBusyPct else { return false }
        return lowClock(s, c, t)
    }

    /// Classifies one second (first match wins).
    public static func classify(_ s: Second, clocks c: Clocks, thresholds t: Thresholds = thresholds) -> Limiter {
        if isMemory(s, t) { return .memory }
        guard let busy = s.gpuBusyPct else { return .unclear }
        if cap(s.fps, t) != nil {
            if busy < t.frameCapMaxGPUBusyPct { return .frameCap }
            if lowClock(s, c, t) { return .frameCap }
        }
        if busy >= t.gpuBusyPct {
            if s.thermalLevel >= 2 { return .gpuThermal }
            if s.thermalLevel >= 1, let mhz = s.gpuMHz, let ref = c.referenceMHz, ref > 0,
               mhz < ref * t.gpuClockFraction { return .gpuThermal }
            if lowClock(s, c, t) { return .unclear }
            return .gpu
        }
        if busy < t.cpuMaxGPUBusyPct {
            if let m = s.coreMaxPct, m >= t.coreMaxPct { return .cpuOneThread }
            if let p = s.pCoresPct, p >= t.pCoresPct { return .cpu }
        }
        return .unclear
    }

    public init(_ bundle: RunBundle, summary: RunSummary) {
        var t = Self.thresholds
        t.frameCaps = Self.frameCaps(t.frameCaps, refreshHz: bundle.info.settings.refreshHz)
        let rows = summary.steadySeconds.map { bundle.rows[$0] }
        let all = rows.map(Second.init(row:))
        let seconds = all.filter { Self.isJudged($0, thresholds: t) }
        let onAC = rows.map { r -> Bool? in r["on_ac"] == "1" ? true : r["on_ac"] == "0" ? false : nil }
        let powerManaged = Self.powerManaged(powerMode: bundle.info.settings.powerMode, onAC: onAC)
        let clocks = Clocks(topMHz: bundle.info.machine.gpuMaxMHz.map(Double.init), steady: seconds,
                            tableMHz: bundle.info.machine.gpuClockTableMHz?.map(Double.init),
                            powerManaged: powerManaged)

        var missing: [String] = []
        if !all.contains(where: { $0.fps != nil }) { missing.append("no FPS recorded") }
        if !all.contains(where: { $0.gpuBusyPct != nil }) { missing.append("no GPU busy recorded") }
        if !all.contains(where: { $0.gpuMHz != nil }) {
            missing.append("no GPU clock recorded")
        } else if clocks.topMHz == nil {
            missing.append("no GPU top clock recorded")
        }
        if !all.contains(where: { $0.memPressure != nil || $0.pageoutsPerSecond != nil }) {
            missing.append("no memory pressure recorded")
        }
        self.missing = missing
        notes = powerManaged ? [Self.powerManagedNote] : []

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
            primary = nil; partly = nil; evidence = []; suggestion = nil
            return
        }
        func members(_ l: Limiter) -> [Second] { zip(seconds, classes).filter { $0.1 == l }.map(\.0) }
        func ev(_ l: Limiter) -> [String] {
            Self.evidence(for: l, seconds: members(l), all: seconds, clocks: clocks, thresholds: t)
        }
        if top.1 >= t.mostlyShare {
            verdict = top.0 == .unclear ? "No single limit stood out" : "Mostly \(top.0.displayName)"
            primary = top.0
            partly = nil
            evidence = ev(top.0)
            suggestion = Self.suggestion(for: top.0, seconds: members(top.0), clocks: clocks, thresholds: t)
        } else {
            let second = shares[1]
            if top.0 == .unclear || second.0 == .unclear {
                let l = top.0 == .unclear ? second.0 : top.0
                verdict = "Partly \(l.displayName) (otherwise no single limit)"
                partly = l
            } else {
                verdict = "Mixed: \(top.0.displayName) and \(second.0.displayName)"
                partly = nil
            }
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
                out.append("GPU busy at \(rounded(f * 100)) % of its top clock — it may not be working flat out "
                           + "(clock reading unverified on this Mac)")
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
