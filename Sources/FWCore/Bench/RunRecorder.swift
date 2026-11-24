import Foundation

/// Where telemetry rows come from (the real `TelemetrySampler`, or a fake in tests).
public protocol TelemetrySource {
    func sample() -> TelemetrySample
}

extension TelemetrySampler: TelemetrySource {}

/// Which Metal process the FPS columns follow.
public enum FollowRule: Sendable {
    /// The process with the most frames so far.
    case busiest
    case pid(Int32)
    /// The busiest process whose name or image path contains the text (case-insensitive).
    case nameContains(String)
}

/// What one `tick` wrote, for the CLI status line.
public struct RecorderStatus: Sendable {
    public let elapsedS: Double
    public let fps: Double?
    public let app: String?
    public let gpuW: Double?
    /// Any HUD line or stderr frame received so far (from any process).
    public let sawFPSSource: Bool
}

/// Turns HUD events, stderr frame times and telemetry into a `.fwrun` bundle.
///
/// Every time is epoch seconds. `hud` and `frames` may arrive on any queue; `tick` is called once per second from a
/// timer. All of them are ignored after `finish`, which is idempotent.
public final class RunRecorder: @unchecked Sendable {
    private let writer: RunBundleWriter
    private let telemetry: TelemetrySource
    private let startTime: Double
    private let follow: FollowRule
    private let warmup: Double
    private let argv0: @Sendable (Int32) -> String?
    private let lock = NSLock()
    /// Serialises `tick` so `telemetry` is used from one thread at a time.
    private let tickLock = NSLock()

    private var counter = FrameCounter()
    private var imagePaths: [Int32: String] = [:]
    private var names: [Int32: String] = [:]
    private var pendingFrameTimes: [Double] = []
    private var sawHUD = false
    private var sawFrames = false
    private var stacks: [Int32: Stack] = [:]
    private var finished = false
    private var writeWarnings: [String] = []
    private var identifiedExe: String?

    /// `argv0` looks up a live process's argv[0] (injectable for tests); the exe name is taken from it.
    public init(writer: RunBundleWriter, telemetry: TelemetrySource, startTime: Double, follow: FollowRule,
                warmup: Double = 0,
                argv0: @escaping @Sendable (Int32) -> String? = { ProcessNames.displayName(pid: $0) }) {
        self.writer = writer
        self.telemetry = telemetry
        self.startTime = startTime
        self.follow = follow
        self.warmup = max(0, warmup)
        self.argv0 = argv0
    }

    /// Exe name of the process followed at `finish`, or nil if it was never identified.
    public var gameExe: String? {
        lock.lock(); defer { lock.unlock() }
        return identifiedExe
    }

    public func hud(_ event: HUDEvent) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        counter.add(event)
        imagePaths[event.pid] = event.imagePath
        sawHUD = true
    }

    /// Per-frame times (from the launched process's stderr) that arrived at `time`.
    public func frames(_ times: [FrameTime], pid: Int32?, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !times.isEmpty else { return }
        sawFrames = true
        pendingFrameTimes.append(contentsOf: times.map(\.intervalMs))
        do {
            try writer.append(frames: times, endingAtMs: (time - startTime) * 1000)
        } catch {
            noteWriteFailure("frames.csv write failed: \(error)")
        }
    }

    /// The PID the FPS columns currently follow, or nil if none is known yet.
    public var followedPID: Int32? {
        lock.lock(); defer { lock.unlock() }
        return resolveFollowed()
    }

    /// Stack of `pid` (from `StackDetector`, run by the caller off the timer queue). Kept per PID; the one of the
    /// PID followed at `finish` goes into run.json.
    public func setStack(_ stack: Stack, for pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        stacks[pid] = stack
    }

    /// Writes one samples.csv row. Returns nil (and writes nothing) after `finish`.
    @discardableResult
    public func tick(at time: Double) throws -> RecorderStatus? {
        tickLock.lock(); defer { tickLock.unlock() }
        if lock.withLock({ finished }) { return nil }
        let s = telemetry.sample()

        lock.lock()
        let pid = resolveFollowed()
        let fps = pid.flatMap { counter.fps(pid: $0, at: time) }
        let app = pid.flatMap { name(of: $0) }
        let frameTimes = pendingFrameTimes
        pendingFrameTimes.removeAll(keepingCapacity: true)
        let saw = sawHUD || sawFrames
        lock.unlock()

        var row: [String: String] = [
            "t": SampleColumns.timestamp(Date(timeIntervalSince1970: time)),
            "elapsed_s": SampleColumns.format(time - startTime, column: "elapsed_s"),
            "fps": SampleColumns.format(fps, column: "fps"),
            "fps_pid": SampleColumns.format(pid.map(Double.init), column: "fps_pid"),
            "fps_app": app ?? "",
            "ft_p99_ms": SampleColumns.format(Self.p99(frameTimes), column: "ft_p99_ms"),
            "ft_max_ms": SampleColumns.format(frameTimes.max(), column: "ft_max_ms"),
            "on_ac": SampleColumns.format(onAC: s.onAC),
            "thermal_state": s.thermalState,
        ]
        let numbers: [(String, Double?)] = [
            ("gpu_w", s.gpuW), ("cpu_p_util_pct", s.cpuPUtilPct), ("cpu_e_util_pct", s.cpuEUtilPct),
            ("cpu_core_max_pct", s.cpuCoreMaxPct), ("gpu_busy_pct", s.gpuBusyPct),
            ("temp_max_c", s.tempMaxC), ("temp_battery_c", s.tempBatteryC),
            ("fan0_rpm", s.fanRPM.count > 0 ? s.fanRPM[0] : nil), ("fan1_rpm", s.fanRPM.count > 1 ? s.fanRPM[1] : nil),
            ("mem_used_gb", s.memUsedGB), ("battery_pct", s.batteryPct.map(Double.init)), ("battery_w", s.batteryW),
        ]
        for (column, value) in numbers { row[column] = SampleColumns.format(value, column: column) }
        for (key, watts) in s.smcPower { row["smc_\(key)_w"] = SampleColumns.format(watts, column: "smc_\(key)_w") }

        // The writer ignores rows after its own finish, so a tick racing `finish` cannot write late.
        do {
            try writer.append(sample: row)
        } catch {
            lock.withLock { noteWriteFailure("samples.csv write failed: \(error)") }
            throw error
        }
        return RecorderStatus(elapsedS: time - startTime, fps: fps, app: app, gpuW: s.gpuW, sawFPSSource: saw)
    }

    /// Writes end time, steady window (warm-up … end), FPS source, game exe and stack into run.json and closes the
    /// files. Idempotent.
    public func finish(at time: Double = Date().timeIntervalSince1970) throws {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pid = resolveFollowed()
        let exe = pid.flatMap { name(of: $0) }
        let stack = pid.flatMap { stacks[$0] }
        let source = sawFrames ? "stderr" : (sawHUD ? "log" : "none")
        identifiedExe = exe
        var warnings = writeWarnings
        if exe == nil { warnings.append("game process never identified") }
        lock.unlock()

        let duration = max(0, time - startTime)
        let steadyStart = min(warmup, duration)
        try writer.finish { info in
            info.end = Date(timeIntervalSince1970: time)
            info.steadyStartS = steadyStart
            info.steadyEndS = duration
            info.fpsSource = source
            info.game.exe = exe ?? ""
            if let stack { info.stack = stack }
            info.warnings += warnings
        }
    }

    // MARK: - Private (call with `lock` held)

    /// Keeps the first failure per file (a failing disk would otherwise add one per second).
    private func noteWriteFailure(_ message: String) {
        let file = message.prefix { $0 != " " }
        if !writeWarnings.contains(where: { $0.hasPrefix(file) }) { writeWarnings.append(message) }
    }

    private func resolveFollowed() -> Int32? {
        switch follow {
        case .pid(let pid):
            return pid
        case .busiest:
            return counter.followedPID
        case .nameContains(let text):
            let needle = text.lowercased()
            let matches = imagePaths.keys.filter { pid in
                (name(of: pid)?.lowercased().contains(needle) ?? false)
                    || (imagePaths[pid]?.lowercased().contains(needle) ?? false)
            }
            return matches.max { a, b in
                let (fa, fb) = (counter.totalFrames(pid: a), counter.totalFrames(pid: b))
                return fa != fb ? fa < fb : a > b
            }
        }
    }

    /// Exe name of `pid`: from its argv[0] (Wine reports the Windows exe there), else from the HUD image path.
    /// Cached once found, so a name survives the process exiting.
    private func name(of pid: Int32) -> String? {
        if let cached = names[pid] { return cached }
        let found = argv0(pid).map(ProcessNames.exeName(fromArgv0:))
            ?? imagePaths[pid].map(ProcessNames.exeName(fromArgv0:))
        if let found, !found.isEmpty { names[pid] = found; return found }
        return nil
    }

    /// Value at index ⌈0.99·n⌉−1 of the sorted list.
    static func p99(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((0.99 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, index))]
    }
}
