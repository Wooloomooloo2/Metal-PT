import Combine
import Foundation
import MPTCore

/// What the hub shows at one moment: the latest telemetry and the followed game.
public struct HubSnapshot: Sendable {
    /// Epoch seconds (the hub's clock).
    public let time: Double
    /// The latest sample; all-unknown (`TelemetrySample()`) when nothing is sampling (a follow-only update).
    public let sample: TelemetrySample
    public let fps: Double?
    /// The live followed process (never Metal-PT itself); nil when no HUD process is live.
    public let followedPID: Int32?
    public let followedApp: String?
    public let stack: Stack?

    public init(time: Double, sample: TelemetrySample, fps: Double?, followedPID: Int32?, followedApp: String?,
                stack: Stack?) {
        self.time = time
        self.sample = sample
        self.fps = fps
        self.followedPID = followedPID
        self.followedApp = followedApp
        self.stack = stack
    }
}

/// A cancellable timer from a `HubScheduler`.
public protocol HubTimer: Sendable {
    func cancel()
}

/// Where the hub's timers come from (`DispatchHubScheduler`, or a manual one in tests).
public protocol HubScheduler: Sendable {
    /// Calls `work` every `interval` seconds (first after one interval) until cancelled, off the main thread.
    func repeating(every interval: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer
    /// Calls `work` once after `delay` seconds unless cancelled first, off the main thread.
    func once(after delay: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer
}

/// Dispatch timers on one serial background queue, with leeway (the hub's ticks need not be exact).
public final class DispatchHubScheduler: HubScheduler {
    private let queue = DispatchQueue(label: "mpt.hub.tick", qos: .utility)

    public init() {}

    public func repeating(every interval: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler(handler: work)
        t.resume()
        return DispatchTimerHandle(t)
    }

    public func once(after delay: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
        t.setEventHandler(handler: work)
        t.resume()
        return DispatchTimerHandle(t)
    }

    private final class DispatchTimerHandle: HubTimer, @unchecked Sendable {
        private let timer: DispatchSourceTimer
        init(_ timer: DispatchSourceTimer) { self.timer = timer }
        func cancel() { timer.cancel() }
    }
}

/// The app's one sampler and one Metal HUD log stream, reference-counted by their consumers (Live page, menu bar,
/// overlay, recording) so that nothing runs when nothing watches (spec §11.3), and the recording control.
///
/// - The log stream runs while any `.hud` token is held (FPS logging on holds one). A recording does not turn it on:
///   with FPS logging off a recording is telemetry-only.
/// - The sampler exists while any `.samples` token is held or a recording runs. Without a recording the hub ticks it
///   at 1 Hz on a background timer (cancelled, not idled, when not needed). During a recording the session's 1 Hz
///   tick drives it instead (see "Sharing with a recording").
/// - `menuBarWantsSamplesWhenFollowing`: the hub holds a `.samples` token of its own exactly while
///   `latest?.followedPID != nil`. The followed PID comes from the stream, not the sampler: without samples, a change
///   of followed game (or the game going quiet for `FrameCounter.staleAfter`) is published as a follow-only snapshot.
///
/// Following (spec §11.4): the hub keeps its own `FrameCounter` fed by the stream and applies
/// `FollowResolver.preferTranslated` excluding its own PID, with `pinned`. A pin is cleared once that PID is no longer
/// a live candidate.
///
/// Sharing with a recording: the session gets the hub's sources, never its own. Its `TelemetrySource` takes a sample
/// from the hub's sampler (so there is one 1 Hz cadence, one sample per row, and each row's sample is also the
/// hub's `latest`; the hub's own timer pauses while a recording runs). Its `HUDEventSource` is a fan-out subscriber
/// of the hub's stream: starting and stopping it never starts or stops the stream. The hub's `AsyncStackCache` is
/// shared with the session (`stackOf` and `detectNow`), so each PID's stack is detected once.
///
/// Threads: the hub is main-actor; sampling, stream events and timers run off the main thread in `HubEngine`
/// (lock-protected) and reach the published properties via the main queue.
@MainActor
public final class TelemetryHub: ObservableObject {
    public enum Need: Sendable {
        case hud
        case samples
    }

    /// A consumer's hold on a `Need`. `release()` is idempotent and also runs on deinit (from any thread; the hold
    /// is dropped on the main thread, at once when already there).
    public final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?

        init(_ action: @escaping @Sendable () -> Void) { self.action = action }

        public func release() {
            let a: (@Sendable () -> Void)? = lock.withLock {
                defer { action = nil }
                return action
            }
            a?()
        }

        deinit { release() }
    }

    /// What the session is built from (all of them the hub's).
    /// Unchecked: the hub's own adapters, which are thread-safe.
    public struct SessionParts: @unchecked Sendable {
        public let telemetry: TelemetrySource
        public let hud: HUDEventSource
        public let clock: @Sendable () -> Double
        public let stackDetector: @Sendable (Int32) -> Stack
        public let stackOf: @Sendable (Int32) -> Stack?
        public let argv0: @Sendable (Int32) -> String?
    }

    public struct Dependencies: Sendable {
        public var makeSampler: @Sendable () -> TelemetrySource
        public var makeStream: @Sendable () -> HUDEventSource
        public var clock: @Sendable () -> Double
        public var scheduler: HubScheduler
        public var argv0: @Sendable (Int32) -> String?
        public var detectStack: @Sendable (Int32) -> Stack
        /// Never followed (Metal-PT itself logs HUD lines when FPS logging was on at its launch).
        public var selfPID: Int32
        public var makeSession: @Sendable (RecordingSession.Options, SessionParts) throws -> RecordingSession

        public init(makeSampler: @escaping @Sendable () -> TelemetrySource,
                    makeStream: @escaping @Sendable () -> HUDEventSource,
                    clock: @escaping @Sendable () -> Double,
                    scheduler: HubScheduler,
                    argv0: @escaping @Sendable (Int32) -> String?,
                    detectStack: @escaping @Sendable (Int32) -> Stack,
                    selfPID: Int32,
                    makeSession: @escaping @Sendable (RecordingSession.Options, SessionParts) throws
                        -> RecordingSession) {
            self.makeSampler = makeSampler
            self.makeStream = makeStream
            self.clock = clock
            self.scheduler = scheduler
            self.argv0 = argv0
            self.detectStack = detectStack
            self.selfPID = selfPID
            self.makeSession = makeSession
        }

        /// The real sampler, `log stream`, wall clock, Dispatch timers and lsof stack detection.
        public static var live: Dependencies {
            Dependencies(
                makeSampler: { TelemetrySampler() },
                makeStream: { MetalHUDLogStream() },
                clock: { Date().timeIntervalSince1970 },
                scheduler: DispatchHubScheduler(),
                argv0: { ProcessNames.displayName(pid: $0) },
                detectStack: { StackDetector.detect(pid: $0) },
                selfPID: getpid(),
                makeSession: { options, p in
                    try RecordingSession(options: options, telemetry: p.telemetry, hud: p.hud, clock: p.clock,
                                         stackDetector: p.stackDetector, argv0: p.argv0, stackOf: p.stackOf)
                })
        }
    }

    public nonisolated static let historyLimit = 300
    public nonisolated static let tickInterval = 1.0

    @Published public private(set) var latest: HubSnapshot?
    /// The last `historyLimit` sampled snapshots, oldest first (follow-only updates are not added).
    @Published public private(set) var history: [HubSnapshot] = []
    /// The running recording's latest tick; nil when not recording (or before its first tick).
    @Published public private(set) var recording: SessionStatus?
    /// The last finished recording (by `stopRecording` or by the session ending itself).
    @Published public private(set) var lastRun: RunResult?
    /// Why the log stream could not start, while a `.hud` token is held.
    @Published public private(set) var streamError: String?

    /// The user's pick among `followCandidates`; cleared by the hub once that PID is no longer live.
    /// Not `@Published` (the hub clears it itself), but a change is announced at once so the picker updates.
    public var pinned: Int32? {
        willSet { if newValue != pinned { objectWillChange.send() } }
        didSet { engine.setPinned(pinned) }
    }

    /// Menu-bar rule: hold samples exactly while a game is followed.
    public var menuBarWantsSamplesWhenFollowing = false {
        didSet { updateMenuBarHold() }
    }

    /// True while the sampler runs (a `.samples` hold or a recording).
    public private(set) var isSampling = false
    /// Called on the main thread when `isSampling` changes (the app logs it).
    public var onSamplingChange: ((Bool) -> Void)?

    /// Session messages (progress, problems), on the main thread.
    public var onRecordingMessage: ((SessionMessage) -> Void)?

    /// Why `startRecording` refused.
    public enum RecordingError: Error, Equatable, CustomStringConvertible {
        /// A recording is starting or running.
        case alreadyRecording
        /// The previous recording is still being finished (summary, rename); try again in a moment.
        case stillFinishing
        /// `stopRecordingNow` (quit) ran while this recording was starting.
        case stoppedWhileStarting

        public var description: String {
            switch self {
            case .alreadyRecording: "a recording is already running"
            case .stillFinishing: "the previous recording is still being saved"
            case .stoppedWhileStarting: "the recording was stopped while it was starting"
            }
        }
    }

    /// True from `startRecording` until `stopRecording` begins finishing the run.
    public var isRecording: Bool { session != nil || starting != nil }
    /// The bundle folder of the recording running or being finished (nil before the session has made it).
    public var recordingDirectory: URL? { (session ?? finishing)?.directory }
    /// True while a stopped recording is being finished off the main actor.
    public var isFinishingRecording: Bool { finishing != nil }

    /// Live HUD processes except Metal-PT, busiest first, with exe name and stack (nil while detecting).
    public var followCandidates: [(pid: Int32, app: String, stack: Stack?)] { engine.candidates() }

    private let deps: Dependencies
    private let engine: HubEngine
    private var holds: [UUID: Need] = [:]
    private var menuBarToken: Token?
    /// Set from `startRecording` until the run is finished (keeps the sampler for a tick in flight).
    private var recordingID: UUID?
    /// The session being created and started off main; completes after `session` is installed.
    private var starting: Task<RecordingSession, Error>?
    /// Shared with that start task, so `stopRecordingNow` (which cannot await it) can abort or stop it.
    private var startBox: StartBox?
    private var session: RecordingSession?
    /// The stopped session while it finishes off main, and that finish.
    private var finishing: RecordingSession?
    private var finishTask: Task<RunResult?, Never>?
    /// Sequence number of the newest update applied (older ones arriving late are dropped).
    private var appliedSeq: UInt64 = 0
    private(set) var latestUpdateForTesting: HubEngine.Update?
    /// Runs in the start task just before `RecordingSession.start` (tests).
    var beforeSessionStartForTesting: (@Sendable () -> Void)?
    var startingSessionForTesting: RecordingSession? { startBox?.session }

    public init(dependencies: Dependencies = .live) {
        deps = dependencies
        engine = HubEngine(deps: dependencies)
        engine.setSink { [weak self] update in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(update) } }
        }
    }

    isolated deinit {
        stopRecordingNow()
        engine.shutdown()
    }

    public func acquire(_ need: Need) -> Token {
        let id = UUID()
        holds[id] = need
        reconcile()
        return Token { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.release(id) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.release(id) } }
            }
        }
    }

    /// Starts a recording on the hub's sources. `options.follow` is replaced by the app's rule
    /// (`.preferTranslated` excluding Metal-PT, with the current pin; the pin is fixed for the run).
    /// Starts telemetry-only when no game is followed (or FPS logging is off); FPS fills in once one logs.
    ///
    /// The slow part (machine/power-mode/battery reads, priming, creating the bundle) runs off the main actor.
    /// Refused (`RecordingError`) while a recording is starting or running, and while the previous one is still
    /// finishing: a second hotkey press during the finish does not start a run over it.
    public func startRecording(options: RecordingSession.Options) async throws {
        if finishing != nil { throw RecordingError.stillFinishing }
        guard session == nil, starting == nil else { throw RecordingError.alreadyRecording }
        var options = options
        options.follow = .preferTranslated(exclude: [deps.selfPID], pinned: pinned)
        let id = UUID()
        recordingID = id
        let engine = engine
        let cache = engine.stackCache
        let parts = SessionParts(telemetry: HubTelemetrySource(engine: engine),
                                 hud: SharedHUDSource(engine: engine),
                                 clock: deps.clock,
                                 stackDetector: { cache.detectNow(pid: $0) },
                                 stackOf: { cache.stack(for: $0) },
                                 argv0: deps.argv0)
        // The sampler is wanted before the session primes it (and the hub's own timer pauses).
        reconcile()
        let makeSession = deps.makeSession
        let box = StartBox()
        let beforeStart = beforeSessionStartForTesting
        let task = Task.detached { [weak self] () throws -> RecordingSession in
            let s: RecordingSession
            do {
                s = try makeSession(options, parts)
            } catch {
                await self?.startFailed(id, result: nil)
                throw error
            }
            guard box.attach(s) else {
                // Aborted by `stopRecordingNow` before the session existed: never start it.
                s.stop()
                await self?.startFailed(id, result: nil)
                throw RecordingError.stoppedWhileStarting
            }
            s.onTick = { status in engine.recordingTick(status, id: id) }
            s.onEnd = { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.sessionEnded(id) } }
            }
            s.onMessage = { [weak self] m in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onRecordingMessage?(m) } }
            }
            beforeStart?()
            do {
                // A `stop` from `stopRecordingNow` may already have run (start then throws) or may run during it
                // (the session finishes whatever bundle it created).
                try s.start()
            } catch {
                // `stop` still finishes a bundle created before the failure.
                let result = s.stop()
                await self?.startFailed(id, result: result)
                throw error
            }
            guard let self else {
                s.stop()
                return s
            }
            await self.installSession(s, id: id)
            return s
        }
        starting = task
        startBox = box
        _ = try await task.value
    }

    /// Stops the recording and finishes it (end time, rename, summary) off the main actor. Returns the run, or nil
    /// when not recording. A stop pressed while the recording is still starting waits for the start, then stops.
    /// Concurrent calls share one finish.
    @discardableResult
    public func stopRecording() async -> RunResult? {
        if let t = starting { _ = try? await t.value }
        if let t = finishTask { return await t.value }
        guard let s = session, let id = recordingID else { return nil }
        session = nil
        finishing = s
        let task = Task.detached { s.stop() }
        finishTask = task
        let result = await task.value
        didFinish(id, result)
        return result
    }

    /// Synchronous stop for quit and deinit only: blocks the main thread until the run is finished (up to ~2 s for a
    /// stack detection, plus the summary). Also completes a finish already under way (`stop` is idempotent).
    /// A recording still starting is aborted: not started if its session does not exist yet, else that session is
    /// stopped here (before its `start`, which then refuses; or during it, finishing the bundle it created). The
    /// start task cannot be awaited here (it needs the main actor), so it is told through a lock-protected box.
    @discardableResult
    public func stopRecordingNow() -> RunResult? {
        if starting != nil, let box = startBox, let id = recordingID {
            let result = box.abort()?.stop()
            starting = nil
            startBox = nil
            didFinish(id, result)
            return result
        }
        guard let s = session ?? finishing, let id = recordingID else { return nil }
        session = nil
        let result = s.stop()
        didFinish(id, result)
        return result
    }

    /// Snapshots and previews only (`MetalPT --render-snapshots`): shows fixed data on a hub built with inert
    /// dependencies. `history` (oldest first, trimmed to `historyLimit`) and `latest` (default: the last of
    /// `history`) replace the published values; `recording` is shown as the running recording's tick.
    public func showFixture(history: [HubSnapshot], latest: HubSnapshot? = nil, recording: SessionStatus? = nil,
                            lastRun: RunResult? = nil) {
        self.history = Array(history.suffix(Self.historyLimit))
        self.latest = latest ?? history.last
        self.recording = recording
        if let lastRun { self.lastRun = lastRun }
    }

    // MARK: - Internal (tests)

    /// Waits for sampler creation/priming queued off main.
    func waitForSamplerWork() { engine.waitForSamplerWork() }

    func applyForTesting(_ u: HubEngine.Update) { apply(u) }

    /// Holds of `need` currently taken (tokens not yet released).
    func holdCountForTesting(_ need: Need) -> Int { holds.values.filter { $0 == need }.count }

    // MARK: - Private

    /// The start task's own id must still be current: after `stopRecordingNow` (or for a newer recording) it only
    /// makes sure its session is stopped and leaves the state alone.
    private func installSession(_ s: RecordingSession, id: UUID) {
        guard recordingID == id else { s.stop(); return }
        starting = nil
        startBox = nil
        session = s
    }

    private func startFailed(_ id: UUID, result: RunResult?) {
        guard recordingID == id else { return }
        starting = nil
        startBox = nil
        recordingID = nil
        recording = nil
        if let result { lastRun = result }
        reconcile()
    }

    private func didFinish(_ id: UUID, _ result: RunResult?) {
        guard recordingID == id else { return }   // already finished (`stopRecordingNow`)
        finishing = nil
        finishTask = nil
        recordingID = nil
        recording = nil
        if let result { lastRun = result }
        reconcile()
    }

    private func release(_ id: UUID) {
        guard holds.removeValue(forKey: id) != nil else { return }
        reconcile()
    }

    private func reconcile() {
        let wantStream = holds.values.contains(.hud)
        let wantSamples = holds.values.contains(.samples)
        let recordingActive = recordingID != nil
        do {
            try engine.setStream(wantStream)
            streamError = nil
        } catch {
            streamError = "\(error)"
        }
        engine.setSampling(active: wantSamples || recordingActive, ticking: wantSamples && !recordingActive)
        if isSampling != (wantSamples || recordingActive) {
            isSampling = wantSamples || recordingActive
            onSamplingChange?(isSampling)
        }
    }

    private func updateMenuBarHold() {
        let want = menuBarWantsSamplesWhenFollowing && latest?.followedPID != nil
        if want, menuBarToken == nil {
            menuBarToken = acquire(.samples)
        } else if !want, let t = menuBarToken {
            menuBarToken = nil
            t.release()
        }
    }

    private func sessionEnded(_ id: UUID) {
        guard id == recordingID, finishing == nil else { return }
        Task { await stopRecording() }
    }

    /// Updates are numbered when made (under the engine lock) but posted to main from several threads, so one can
    /// arrive after a newer one: it is dropped (e.g. a tick made before the stream stopped must not bring the
    /// followed game back).
    private func apply(_ u: HubEngine.Update) {
        // A pin found dead is dead even if the rest of the update is stale.
        if let p = u.expiredPin, pinned == p { pinned = nil }
        guard u.seq > appliedSeq else { return }
        appliedSeq = u.seq
        latestUpdateForTesting = u
        latest = u.snapshot
        if u.addToHistory {
            history.append(u.snapshot)
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        }
        if let r = u.recording, u.recordingID != nil, u.recordingID == recordingID { recording = r }
        updateMenuBarHold()
    }
}

/// The session a start task created, and whether `stopRecordingNow` aborted that start.
final class StartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RecordingSession?
    private var aborted = false

    var session: RecordingSession? { lock.withLock { stored } }

    /// Stores the new session; false if the start was already aborted.
    func attach(_ s: RecordingSession) -> Bool {
        lock.withLock {
            guard !aborted else { return false }
            stored = s
            return true
        }
    }

    /// Marks the start aborted; returns the session if one was attached (the caller stops it).
    func abort() -> RecordingSession? {
        lock.withLock {
            aborted = true
            return stored
        }
    }
}
