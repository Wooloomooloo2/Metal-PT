import Foundation

/// What one tick of a `RecordingSession` recorded.
public struct SessionStatus: Sendable {
    /// Seconds since the run started.
    public let elapsed: Double
    public let fps: Double?
    public let followedPID: Int32?
    public let followedApp: String?
    /// Stack of the followed process, once detected.
    public let stack: Stack?
    public let sample: TelemetrySample
    /// Any HUD line or stderr frame received so far (from any process).
    public let sawFPSSource: Bool
}

/// A process the session launched (`Options.launch`).
public struct LaunchedChild: Sendable, Equatable {
    public let name: String
    public let pid: Int32
}

/// The finished run.
public struct RunResult: Sendable, Equatable {
    /// The bundle, after any rename to the identified game.
    public let directory: URL
    /// summary.html, nil if it could not be written.
    public let summary: URL?
    /// The launched child, if it was still running when the session stopped.
    public let runningChild: LaunchedChild?
}

/// Something the owner may show: progress (`info`) or a problem.
public struct SessionMessage: Sendable, Equatable {
    public enum Level: Sendable { case info, warning, error }
    public let level: Level
    public let text: String
}

/// Why a session wants to end. The owner then calls `stop()`.
public enum SessionEnd: Sendable, Equatable {
    case durationReached
    case childExited
    case writeFailed
}

/// One recording: telemetry every tick, Metal HUD events, an optional launched child (whose stderr carries per-frame
/// times), and at `stop` the finished bundle (end time, rename to the game, summary.html).
///
/// The session owns no signals and no lease: its owner calls `stop()` (the CLI from its lease, the app on quit).
///
/// Callbacks: `onTick` runs on the session's tick queue once per tick, serially. `onEnd` runs once, on the tick queue
/// or the child's wait thread. `onMessage` runs on any of those or on the thread calling `start`/`stop`. Set them
/// before `start`.
///
/// `stop()` may be called from any thread, any number of times, and from inside `onTick` or `onEnd`. When it
/// returns, no further `onTick` is delivered. A callback must not block waiting for a thread that is inside `stop()`
/// (e.g. `DispatchQueue.main.sync` while the main thread stops), and `onMessage` must not call `stop()`.
public final class RecordingSession: @unchecked Sendable {
    public struct Options: Sendable {
        /// Ends the run (`onEnd(.durationReached)`) after this many ticks (rounded up); nil = until `stop`.
        public var seconds: Double?
        /// Seconds at the start left out of the steady window.
        public var warmup: Double
        public var label: String
        public var settings: String
        public var notes: String
        /// The folder the run bundle is created in (created if missing).
        public var runsRoot: URL
        public var follow: FollowRule
        /// A command to launch with the HUD variables set (`mpt run`); its stderr frame times are recorded.
        /// The child inherits the owner's SIGPIPE disposition: the owner must ignore SIGPIPE (the CLI does), or the
        /// child may die writing to its stderr pipe after the owner exits.
        public var launch: [String]?
        /// Written to run.json.
        public var appVersion: String

        public init(seconds: Double? = nil, warmup: Double = 0, label: String = "", settings: String = "",
                    notes: String = "", runsRoot: URL, follow: FollowRule = .busiest, launch: [String]? = nil,
                    appVersion: String) {
            self.seconds = seconds
            self.warmup = warmup
            self.label = label
            self.settings = settings
            self.notes = notes
            self.runsRoot = runsRoot
            self.follow = follow
            self.launch = launch
            self.appVersion = appVersion
        }
    }

    public struct OptionsError: Error, CustomStringConvertible {
        public let description: String
    }

    public enum StateError: Error, CustomStringConvertible {
        case alreadyStarted
        case stopped
        public var description: String {
            switch self {
            case .alreadyStarted: "the recording has already started"
            case .stopped: "the recording was stopped before it started"
            }
        }
    }

    /// Environment added to a launched child.
    public static let hudEnvironment = ["MTL_HUD_ENABLED": "1", "MTL_HUD_LOG_ENABLED": "1"]
    /// How long `stop` waits for a stack detection under way (lsof is bounded at 5 s).
    static let detectionWait: DispatchTimeInterval = .seconds(2)

    private let options: Options
    private let telemetry: TelemetrySource
    private let hud: HUDEventSource
    private let clock: @Sendable () -> Double
    private let tickInterval: Double
    private let stackDetector: @Sendable (Int32) -> Stack
    private let argv0: @Sendable (Int32) -> String?
    /// Directory-name seed; nil means the placeholder "run" (renamed at finish once the game is known).
    private let game: String?
    /// The seed is only a guess (the launched command[0], often a launcher or wine): rename at finish to the
    /// identified exe as with the placeholder.
    private let seedIsGuess: Bool
    private let machine: RunInfo.Machine
    private let settings: RunInfo.Settings

    private let queue = DispatchQueue(label: "mpt.session.tick", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let detections = DispatchGroup()
    /// Serialises `stop` (recursive so that a nested call on the same thread, e.g. from `onMessage` during `stop`,
    /// gets past it and returns early via `stopping` instead of deadlocking).
    private let stopLock = NSRecursiveLock()

    // Under `lock`.
    private let lock = NSLock()
    private var tickHandler: (@Sendable (SessionStatus) -> Void)?
    private var endHandler: (@Sendable (SessionEnd) -> Void)?
    private var messageHandler: (@Sendable (SessionMessage) -> Void)?
    private var started = false
    private var stopRequested = false
    private var ended = false
    private var stopping = false
    private var stopDone = false
    private var result: RunResult?
    private var timer: DispatchSourceTimer?
    private var startDate = Date()
    private var bundleDirectory: URL?
    private var recorder: RunRecorder?
    private var childPID: pid_t?
    private var childExited = false
    private var childName = ""
    /// Kept alive for the whole run: a deallocated handle closes the pipe.
    private var childStderr: FileHandle?

    /// The launched child's process group, read by the recorder's mixed-frames check (its own lock, so the recorder
    /// never takes `lock`).
    private let launchedGroup = LaunchedGroup()
    private let stderrEOF = DispatchSemaphore(value: 0)

    // Touched only on `queue`.
    private var ticks = 0
    private var warnedStream = false
    private var detected: Set<Int32> = []

    /// Called on the tick queue with each tick's status.
    public var onTick: (@Sendable (SessionStatus) -> Void)? {
        get { lock.withLock { tickHandler } }
        set { lock.withLock { tickHandler = newValue } }
    }

    /// Called once when the run wants to end (duration reached, launched child exited, a sample write failed).
    public var onEnd: (@Sendable (SessionEnd) -> Void)? {
        get { lock.withLock { endHandler } }
        set { lock.withLock { endHandler = newValue } }
    }

    public var onMessage: (@Sendable (SessionMessage) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }

    /// The bundle being written (nil before `start`); after `stop`, its final location.
    public var directory: URL? { lock.withLock { result?.directory ?? bundleDirectory } }

    /// Validates `options` and does the slow reads (machine, power mode, battery) and primes `telemetry`, so the
    /// first row has power and utilisation. `machine`, `stackDetector`, `argv0` and `tickInterval` are for tests.
    public init(options: Options, telemetry: TelemetrySource, hud: HUDEventSource,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                tickInterval: Double = 1,
                machine: @Sendable () -> (RunInfo.Machine, RunInfo.Settings) = RecordingSession.currentMachine,
                stackDetector: @escaping @Sendable (Int32) -> Stack = { StackDetector.detect(pid: $0) },
                argv0: @escaping @Sendable (Int32) -> String? = { ProcessNames.displayName(pid: $0) }) throws {
        if let seconds = options.seconds, !(seconds > 0 && seconds.isFinite) {
            throw OptionsError(description: "the duration must be more than 0 s")
        }
        guard options.warmup >= 0, options.warmup.isFinite else {
            throw OptionsError(description: "the warm-up must be 0 s or more")
        }
        if let seconds = options.seconds, options.warmup >= seconds {
            throw OptionsError(description: "the warm-up (\(CSV.number(options.warmup, digits: 1)) s) must be "
                               + "shorter than the duration (\(CSV.number(seconds, digits: 1)) s)")
        }
        if let launch = options.launch, launch.first?.isEmpty ?? true {
            throw OptionsError(description: "nothing to launch")
        }
        self.options = options
        self.telemetry = telemetry
        self.hud = hud
        self.clock = clock
        self.tickInterval = tickInterval
        self.stackDetector = stackDetector
        self.argv0 = argv0

        if let launch = options.launch {
            game = ProcessNames.exeName(fromArgv0: launch[0])
            seedIsGuess = true
        } else {
            switch options.follow {
            case .pid(let pid): game = argv0(pid).map(ProcessNames.exeName(fromArgv0:))
            case .nameContains(let name): game = name
            case .busiest, .preferTranslated: game = nil
            }
            seedIsGuess = false
        }

        _ = telemetry.sample()
        (self.machine, self.settings) = machine()
        queue.setSpecific(key: queueKey, value: true)
    }

    /// This Mac, its main display, power mode and whether it is on AC.
    public static func currentMachine() -> (RunInfo.Machine, RunInfo.Settings) {
        (MachineInfo.current(),
         MachineInfo.withMainDisplay(.init(powerMode: MachineInfo.powerMode(),
                                           onACAtStart: (try? SmartBatteryReader.read())?.externalConnected)))
    }

    /// Creates the bundle, launches the child (if any), starts the HUD source and the tick timer. If it throws after
    /// the bundle exists (launch or HUD source failed), `stop()` still finishes that bundle.
    public func start() throws {
        let recorder: RunRecorder
        do {
            lock.lock(); defer { lock.unlock() }
            guard !stopRequested else { throw StateError.stopped }
            guard !started else { throw StateError.alreadyStarted }
            started = true
            try FileManager.default.createDirectory(at: options.runsRoot, withIntermediateDirectories: true)
            let startTime = clock()
            let date = Date(timeIntervalSince1970: startTime)
            var info = RunInfo(appVersion: options.appVersion, machine: machine, game: .init(exe: ""),
                               settings: settings, start: date)
            info.user.label = options.label
            info.user.gameSettings = options.settings
            info.user.notes = options.notes
            let dir = RunBundle.availableDirectory(in: options.runsRoot, start: date, game: game ?? "run")
            let writer = try RunBundleWriter(directory: dir, info: info)
            let launched = launchedGroup
            recorder = RunRecorder(writer: writer, telemetry: telemetry, startTime: startTime, follow: options.follow,
                                   warmup: options.warmup, argv0: argv0,
                                   inLaunchedGroup: { pid in
                                       // Nothing launched: every process counts.
                                       guard launched.isLaunching else { return true }
                                       // The child is spawned with POSIX_SPAWN_SETPGROUP 0: its group id is its
                                       // PID, and the processes it starts stay in that group even after a
                                       // launcher exits (reparenting does not change the group).
                                       guard let group = launched.value else { return false }
                                       return getpgid(pid) == group
                                   })
            startDate = date
            bundleDirectory = dir
            self.recorder = recorder
        }

        if let launch = options.launch, !lock.withLock({ stopRequested }) {
            launchedGroup.expectLaunch()
            try spawn(launch, recorder: recorder)
        }
        try hud.start(onEvent: { recorder.hud($0) })
        // A `stop` that ran while the source was starting may have stopped it before it started.
        if lock.withLock({ stopRequested }) { hud.stop() }

        lock.withLock {
            guard !stopRequested else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    /// Stops ticking and the HUD source, waits briefly for a stack detection, finishes the bundle, renames it to the
    /// identified game and writes summary.html. Idempotent: later calls return the same result. nil if the session
    /// never created a bundle (not started, or `start` failed before it). A nested call made from a callback while
    /// the stop sequence runs returns immediately with nil.
    @discardableResult
    public func stop() -> RunResult? {
        let t: DispatchSourceTimer? = lock.withLock {
            stopRequested = true
            defer { timer = nil }
            return timer
        }
        t?.cancel()
        // Let a tick in flight finish, so no `onTick` follows our return (not when called from inside one).
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }

        stopLock.lock(); defer { stopLock.unlock() }
        // Done, or a nested call (same thread) while the stop sequence runs: return what there is.
        let early: Bool = lock.withLock {
            if stopDone || stopping { return true }
            stopping = true
            return false
        }
        if early { return lock.withLock { result } }
        defer { lock.withLock { stopDone = true; stopping = false } }

        hud.stop()
        let (recorder, dir0, start) = lock.withLock { (self.recorder, bundleDirectory, startDate) }
        guard let recorder, var dir = dir0 else { return nil }
        _ = detections.wait(timeout: .now() + Self.detectionWait)
        do { try recorder.finish(at: clock()) } catch { message(.error, "error finishing run: \(error)") }
        if game == nil || seedIsGuess, let exe = recorder.gameExe {
            do { dir = try RunBundle.rename(dir, start: start, game: exe) } catch {
                message(.error, "could not rename the run folder: \(error)")
            }
        }
        var summary: URL?
        do { summary = try SummaryReport.write(bundleAt: dir) } catch {
            message(.error, "could not write the summary: \(error)")
        }
        let child: LaunchedChild? = lock.withLock {
            guard let pid = childPID, !childExited else { return nil }
            return LaunchedChild(name: childName, pid: pid)
        }
        let r = RunResult(directory: dir, summary: summary, runningChild: child)
        lock.withLock { result = r }
        return r
    }

    // MARK: - Private

    private func message(_ level: SessionMessage.Level, _ text: String) {
        lock.withLock { messageHandler }?(SessionMessage(level: level, text: text))
    }

    private func end(_ reason: SessionEnd) {
        let handler: (@Sendable (SessionEnd) -> Void)? = lock.withLock {
            guard !ended, !stopRequested else { return nil }
            ended = true
            return endHandler
        }
        handler?(reason)
    }

    /// On `queue`.
    private func tick() {
        guard let recorder = lock.withLock({ stopRequested || ended ? nil : self.recorder }) else { return }
        let status: RecorderStatus?
        do { status = try recorder.tick(at: clock()) } catch {
            message(.error, "error writing sample: \(error)")
            end(.writeFailed)
            return
        }
        guard let status else { return }
        ticks += 1

        if !warnedStream && !hud.isRunning {
            warnedStream = true
            message(.warning, "log stream stopped unexpectedly; still recording telemetry")
        }
        if let pid = status.pid, !detected.contains(pid) {
            detected.insert(pid)
            let detect = stackDetector
            DispatchQueue.global(qos: .utility).async(group: detections) {
                recorder.setStack(detect(pid), for: pid)
            }
        }
        let s = SessionStatus(elapsed: status.elapsedS, fps: status.fps, followedPID: status.pid,
                              followedApp: status.app, stack: status.stack, sample: status.sample,
                              sawFPSSource: status.sawFPSSource)
        lock.withLock { stopRequested ? nil : tickHandler }?(s)
        if let seconds = options.seconds, Double(ticks) >= seconds.rounded(.up) { end(.durationReached) }
    }

    // MARK: - Launched child

    /// posix_spawn so the child gets its own process group (terminal Ctrl-C reaches only the CLI) and default
    /// handlers for SIGINT/SIGTERM/SIGHUP/SIGQUIT.
    private func spawn(_ command: [String], recorder: RunRecorder) throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw LaunchError(description: "pipe failed: errno \(errno)") }
        let (readFD, writeFD) = (fds[0], fds[1])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                              | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        // SIGPIPE is deliberately NOT reset: the child inherits the owner's disposition. The CLI's lease ignores it,
        // so the game survives writing to its stderr pipe after mpt has exited (Ctrl-C or --seconds leave it
        // running). Any other owner must ignore SIGPIPE too, or the child may die once the owner is gone.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)

        var env = ProcessInfo.processInfo.environment
        for (k, v) in Self.hudEnvironment { env[k] = v }
        let argv = command.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var spawned: pid_t = 0
        let rc = posix_spawnp(&spawned, command[0], &actions, &attr, argv, envp)
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            throw LaunchError(description: "cannot launch \(command[0]): \(String(cString: strerror(rc)))")
        }
        let name = ProcessNames.exeName(fromArgv0: command[0])
        let pid = spawned
        lock.withLock { childPID = pid; childName = name }
        launchedGroup.set(pid)
        message(.info, "launched \(name) (pid \(pid))")

        readStderr(readFD, pid: pid, recorder: recorder)
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            lock.withLock { childExited = true }
            // Its last HUD lines may still be in the pipe: wait for EOF (a grandchild can hold the pipe open, so
            // at most 1 s).
            _ = stderrEOF.wait(timeout: .now() + 1)
            message(.info, "\(name) exited")
            end(.childExited)
        }
    }

    /// HUD lines become frame times; everything else is passed through to our stderr.
    private func readStderr(_ fd: Int32, pid: pid_t, recorder: RunRecorder) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        lock.withLock { childStderr = handle }
        let splitter = LineBuffer()
        let eof = stderrEOF
        let clock = clock
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            let lines = chunk.isEmpty ? splitter.flush() : splitter.add(chunk)
            let now = clock()
            var passthrough = Data()
            for line in lines {
                let text = String(decoding: line, as: UTF8.self)
                if let hud = MetalHUDLine.parse(text) {
                    recorder.frames(hud.frameTimes, pid: pid, at: now)
                } else {
                    passthrough.append(line)
                    passthrough.append(0x0A)
                }
            }
            if !passthrough.isEmpty { FileHandle.standardError.write(passthrough) }
            if chunk.isEmpty {
                h.readabilityHandler = nil
                eof.signal()
            }
        }
    }

    public struct LaunchError: Error, CustomStringConvertible {
        public let description: String
    }
}

/// Line splitter state for one pipe (readability handlers run serially).
final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    func add(_ chunk: Data) -> [Data] { MetalHUDLogStream.splitLines(&buffer, appending: chunk) }
    func flush() -> [Data] {
        defer { buffer = Data() }
        return buffer.isEmpty ? [] : [buffer]
    }
}

/// The process group of the launched child, once spawned.
final class LaunchedGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var launching = false
    private var group: pid_t?
    /// True when a launch is expected (from just before the spawn).
    var isLaunching: Bool { lock.withLock { launching } }
    var value: pid_t? { lock.withLock { group } }
    func expectLaunch() { lock.withLock { launching = true } }
    func set(_ pgid: pid_t) { lock.withLock { group = pgid } }
}
