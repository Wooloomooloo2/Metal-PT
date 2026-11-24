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
    /// For the app: among live HUD processes minus `exclude` (Metal-PT itself), a live `pinned` PID wins; else the
    /// busiest whose stack is known and not "native" (Wine, CrossOver, Protium ...); else the busiest candidate.
    /// A pinned PID that has gone stale is ignored, so the rule falls back; the owner clears its pin when the PID
    /// disappears from its candidates.
    case preferTranslated(exclude: Set<Int32>, pinned: Int32?)
}

/// Per-PID stack cache whose detection (lsof, up to 5 s) runs on a background queue: `stack(for:)` never blocks and
/// returns nil (unknown) until the detection finishes. Each PID is detected once, except that a result of nil or
/// "native" is re-detected once more after `retryAfter` seconds (Wine libraries may not have been loaded yet).
/// `detectNow(pid:)` is the blocking lookup for callers already off the main thread: it shares a detection under way
/// instead of starting a second lsof.
public final class AsyncStackCache: @unchecked Sendable {
    public static let retryAfter = 5.0
    private let detect: @Sendable (Int32) -> Stack
    private let now: @Sendable () -> Double
    /// Guards the state below; signalled when a detection finishes.
    private let condition = NSCondition()
    private var known: [Int32: (stack: Stack, at: Double)] = [:]
    private var pending: Set<Int32> = []
    private var retried: Set<Int32> = []
    private let queue = DispatchQueue(label: "metalpt.stackcache", qos: .utility, attributes: .concurrent)

    public init(now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                detect: @escaping @Sendable (Int32) -> Stack = { StackDetector.detect(pid: $0) }) {
        self.detect = detect
        self.now = now
    }

    var pendingCount: Int { condition.withLock { pending.count } }

    public func stack(for pid: Int32) -> Stack? {
        condition.lock(); defer { condition.unlock() }
        let entry = known[pid]
        var start = false
        if let entry {
            let runtime = entry.stack.runtime
            if (runtime == nil || runtime == "native"), !retried.contains(pid), !pending.contains(pid),
               now() - entry.at >= Self.retryAfter {
                retried.insert(pid)
                start = true
            }
        } else {
            start = pending.insert(pid).inserted
        }
        if start {
            pending.insert(pid)
            queue.async { [self] in finish(pid, detect(pid)) }
        }
        return entry?.stack
    }

    /// Blocking: waits for a detection (or re-detection) under way; else the known stack; else detects now (and
    /// caches the result).
    public func detectNow(pid: Int32) -> Stack {
        condition.lock()
        while pending.contains(pid) { condition.wait() }
        if let entry = known[pid] {
            condition.unlock()
            return entry.stack
        }
        pending.insert(pid)
        condition.unlock()
        let s = detect(pid)
        finish(pid, s)
        return s
    }

    private func finish(_ pid: Int32, _ s: Stack) {
        condition.withLock {
            known[pid] = (s, now())
            pending.remove(pid)
            condition.broadcast()
        }
    }
}

/// What one `tick` wrote, for the CLI status line.
public struct RecorderStatus: Sendable {
    public let elapsedS: Double
    public let fps: Double?
    public let app: String?
    public let gpuW: Double?
    /// Any HUD line or stderr frame received so far (from any process).
    public let sawFPSSource: Bool
    /// The followed PID (nil until one is known) and its stack, once detected.
    public let pid: Int32?
    public let stack: Stack?
    /// The telemetry this row was written from.
    public let sample: TelemetrySample
}

/// Turns HUD events, stderr frame times and telemetry into a `.mptrun` bundle.
///
/// Every time is epoch seconds. `hud` and `frames` may arrive on any queue; `tick` is called once per second from a
/// timer. All of them are ignored after `finish`, which is idempotent.
public final class RunRecorder: @unchecked Sendable {
    /// Added to run.json when stderr frames look like they come from more than the followed process.
    public static let mixedFramesWarning = "frame times may include more than one process"
    /// Stderr frames per second above the followed process's log FPS by more than this fraction …
    static let mixedExcess = 0.15
    /// … for this many consecutive steady ticks flags mixed frame times (as does more than one launched-group
    /// process gaining frames for this many).
    static let mixedSeconds = 3
    /// Added to run.json when two ticks are more than `sleepGapS` apart (the Mac slept): the steady window ends at
    /// the tick before the gap.
    public static let sleepWarning = "recording spanned a sleep"
    static let sleepGapS = 5.0
    private let writer: RunBundleWriter
    private let telemetry: TelemetrySource
    private let startTime: Double
    private let follow: FollowRule
    private let warmup: Double
    private let argv0: @Sendable (Int32) -> String?
    private let inLaunchedGroup: @Sendable (Int32) -> Bool
    private let stackOf: @Sendable (Int32) -> Stack?
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
    // Mixed-frames detection (touched under `lock` from `tick`).
    private var lastTickTime: Double?
    private var lastTickTotals: [Int32: Int] = [:]
    private var excessTicks = 0
    private var multiTicks = 0
    private var framesMixed = false
    /// Time of the last tick before the first sleep gap.
    private var sleepStart: Double?

    /// `argv0` looks up a live process's argv[0] (injectable for tests); the exe name is taken from it.
    /// `stackOf` gives a PID's stack or nil while unknown; non-blocking (default: `AsyncStackCache`).
    /// `inLaunchedGroup` says whether a PID belongs to the process group `mpt run` launched; only those count
    /// for the mixed-frames check (`record` has no launched group: every PID counts, and there are no stderr frames).
    public init(writer: RunBundleWriter, telemetry: TelemetrySource, startTime: Double, follow: FollowRule,
                warmup: Double = 0,
                argv0: @escaping @Sendable (Int32) -> String? = { ProcessNames.displayName(pid: $0) },
                inLaunchedGroup: @escaping @Sendable (Int32) -> Bool = { _ in true },
                stackOf: (@Sendable (Int32) -> Stack?)? = nil) {
        // Only the `preferTranslated` rule consults it; it must not block (called with the lock held).
        if let stackOf {
            self.stackOf = stackOf
        } else if case .preferTranslated = follow {
            let cache = AsyncStackCache()
            self.stackOf = { cache.stack(for: $0) }
        } else {
            self.stackOf = { _ in nil }
        }
        self.writer = writer
        self.telemetry = telemetry
        self.startTime = startTime
        self.follow = follow
        self.warmup = max(0, warmup)
        self.argv0 = argv0
        self.inLaunchedGroup = inLaunchedGroup
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
        let stack = pid.flatMap { stacks[$0] }
        let previousTick = lastTickTime ?? startTime
        if sleepStart == nil, time - previousTick > Self.sleepGapS { sleepStart = previousTick }
        checkMixedFrames(stderrCount: frameTimes.count, logFPS: fps, followed: pid, at: time)
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
        return RecorderStatus(elapsedS: time - startTime, fps: fps, app: app, gpuW: s.gpuW, sawFPSSource: saw,
                              pid: pid, stack: stack, sample: s)
    }

    /// Writes end time, steady window (warm-up … end, or … the last tick before a sleep), FPS source, game exe and stack into run.json and closes the
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
        if framesMixed { warnings.append(Self.mixedFramesWarning) }
        if sleepStart != nil { warnings.append(Self.sleepWarning) }
        let sleepStart = sleepStart
        lock.unlock()

        let duration = max(0, time - startTime)
        let steadyEnd = sleepStart.map { min(duration, max(0, $0 - startTime)) } ?? duration
        let steadyStart = min(warmup, steadyEnd)
        try writer.finish { info in
            info.end = Date(timeIntervalSince1970: time)
            info.steadyStartS = steadyStart
            info.steadyEndS = steadyEnd
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

    /// Stderr frames carry no PID, so several Metal processes under a launched command can interleave in
    /// frames.csv. Only ticks in the steady window count (the lows use only those frames); either rule must hold for
    /// `mixedSeconds` consecutive ticks: stderr frame rate more than `mixedExcess` above the followed process's log
    /// FPS, or more than one process of the launched group gaining frames in the log while stderr frames arrive.
    /// The excess rule applies only when `followed` is in the launched group: otherwise its log FPS is some other
    /// app's (e.g. one with `hud on`) and says nothing about the launched command's stderr frames.
    private func checkMixedFrames(stderrCount: Int, logFPS: Double?, followed: Int32?, at time: Double) {
        let previous = lastTickTime ?? startTime
        lastTickTime = time
        var gaining = 0
        for pid in imagePaths.keys {
            let total = counter.totalFrames(pid: pid)
            if total > (lastTickTotals[pid] ?? 0), inLaunchedGroup(pid) { gaining += 1 }
            lastTickTotals[pid] = total
        }
        guard !framesMixed else { return }
        guard time - startTime > warmup, stderrCount > 0 else { excessTicks = 0; multiTicks = 0; return }
        multiTicks = gaining > 1 ? multiTicks + 1 : 0
        let dt = time - previous
        if dt > 0, let logFPS, logFPS > 0, let followed, inLaunchedGroup(followed),
           Double(stderrCount) / dt > logFPS * (1 + Self.mixedExcess) {
            excessTicks += 1
        } else {
            excessTicks = 0
        }
        if excessTicks >= Self.mixedSeconds || multiTicks >= Self.mixedSeconds { framesMixed = true }
    }

    private func resolveFollowed() -> Int32? {
        switch follow {
        case .pid(let pid):
            return pid
        case .busiest:
            return counter.followedPID
        case .preferTranslated(let exclude, let pinned):
            guard let now = counter.latestTime else { return nil }
            return FollowResolver.preferTranslated(counter: counter, pids: imagePaths.keys, exclude: exclude,
                                                   pinned: pinned, at: now, stack: { stacks[$0] ?? stackOf($0) })
        case .nameContains(let text):
            let needle = text.lowercased()
            let matches = imagePaths.keys.filter { pid in
                (name(of: pid)?.lowercased().contains(needle) ?? false)
                    || (imagePaths[pid]?.lowercased().contains(needle) ?? false)
            }
            // Among the live matches (a restarted game has a new PID); all matches when none is live.
            if let now = counter.latestTime, let live = counter.busiestLive(at: now, among: Array(matches)) {
                return live
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
