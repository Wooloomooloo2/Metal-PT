import Testing
import Foundation
import MPTCore
@testable import MPTApp

// MARK: - Fakes

/// Each sampler returns gpuW = 1, 2, 3 … (its own count; the hub primes with the first).
private final class FakeSampler: TelemetrySource, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func sample() -> TelemetrySample {
        lock.withLock { n += 1; return TelemetrySample(gpuW: Double(n), batteryPct: 80, onAC: true) }
    }
}

private final class Samplers: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [Weak<FakeSampler>] = []
    func make() -> FakeSampler { let s = FakeSampler(); lock.withLock { made.append(Weak(s)) }; return s }
    var count: Int { lock.withLock { made.count } }
    /// Samplers still alive (the hub drops its sampler when nothing needs it).
    var live: Int { lock.withLock { made.filter { $0.value != nil }.count } }
}

private final class Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}

private final class FakeStream: HUDEventSource, @unchecked Sendable {
    struct StartFailed: Error {}
    private let lock = NSLock()
    private var handler: (@Sendable (HUDEvent) -> Void)?
    private var onDeath: (@Sendable () -> Void)?
    private var isStarted = false
    private var isStopped = false
    private var isDead = false
    private let failStart: Bool
    init(failStart: Bool = false) { self.failStart = failStart }
    var started: Bool { lock.withLock { isStarted } }
    var stopped: Bool { lock.withLock { isStopped } }
    func start(onEvent: @escaping @Sendable (HUDEvent) -> Void) throws {
        if failStart { throw StartFailed() }
        lock.withLock { guard !isStopped else { return }; isStarted = true; handler = onEvent }
    }
    func stop() { lock.withLock { isStopped = true; handler = nil } }
    func setOnUnexpectedStop(_ handler: @escaping @Sendable () -> Void) { lock.withLock { onDeath = handler } }
    var isRunning: Bool { lock.withLock { isStarted && !isStopped && !isDead } }
    func send(_ e: HUDEvent) { lock.withLock { handler }?(e) }
    /// `log` exits on its own.
    func die() {
        let h: (@Sendable () -> Void)? = lock.withLock { isDead = true; handler = nil; return onDeath }
        h?()
    }
}

private final class Streams: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FakeStream] = []
    private var failing = 0
    /// The next `n` streams throw from `start`.
    func failNext(_ n: Int) { lock.withLock { failing = n } }
    func make() -> FakeStream {
        lock.withLock {
            let s = FakeStream(failStart: failing > 0)
            failing = max(0, failing - 1)
            all.append(s)
            return s
        }
    }
    var count: Int { lock.withLock { all.count } }
    var last: FakeStream? { lock.withLock { all.last } }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double
    init(_ t: Double) { self.t = t }
    var now: Double { lock.withLock { t } }
    func set(_ v: Double) { lock.withLock { t = v } }
}

/// Runs timers only when told to (`tick`, `fireOnce`), on the calling thread.
private final class ManualScheduler: HubScheduler, @unchecked Sendable {
    private final class Handle: HubTimer, @unchecked Sendable {
        let cancelled: @Sendable () -> Void
        init(_ c: @escaping @Sendable () -> Void) { cancelled = c }
        func cancel() { cancelled() }
    }
    private let lock = NSLock()
    private var repeating: [UUID: @Sendable () -> Void] = [:]
    private var once: [UUID: @Sendable () -> Void] = [:]
    private(set) var repeatingIntervals: [Double] = []
    private var onceDelaysStore: [Double] = []
    var onceDelays: [Double] { lock.withLock { onceDelaysStore } }

    func repeating(every interval: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer {
        let id = UUID()
        lock.withLock { repeating[id] = work; repeatingIntervals.append(interval) }
        return Handle { [weak self] in self?.lock.withLock { _ = self?.repeating.removeValue(forKey: id) } }
    }
    func once(after delay: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer {
        let id = UUID()
        lock.withLock { once[id] = work; onceDelaysStore.append(delay) }
        return Handle { [weak self] in self?.lock.withLock { _ = self?.once.removeValue(forKey: id) } }
    }
    var activeRepeating: Int { lock.withLock { repeating.count } }
    var activeOnce: Int { lock.withLock { once.count } }
    func tick() { lock.withLock { Array(repeating.values) }.forEach { $0() } }
    func fireOnce() {
        let works: [@Sendable () -> Void] = lock.withLock { defer { once = [:] }; return Array(once.values) }
        works.forEach { $0() }
    }
}

/// Open by default; `close()` makes stack detections wait until `open()` (or the session's 2 s detection wait).
private final class Gate: @unchecked Sendable {
    private let cond = NSCondition()
    private var isOpen = true
    func close() { cond.withLock { isOpen = false } }
    func open() { cond.withLock { isOpen = true; cond.broadcast() } }
    /// Waits until open, at most 5 s in all (looping over spurious wakeups).
    func pass() {
        let deadline = Date() + 5
        cond.withLock { while !isOpen && cond.wait(until: deadline) {} }
    }
}

/// Records each activity begun and whether it has ended.
private final class FakeActivities: ActivityProviding, @unchecked Sendable {
    final class Token: ActivityToken, @unchecked Sendable {
        let options: ProcessInfo.ActivityOptions
        let reason: String
        private let lock = NSLock()
        private var isEnded = false
        init(_ options: ProcessInfo.ActivityOptions, _ reason: String) { self.options = options; self.reason = reason }
        var ended: Bool { lock.withLock { isEnded } }
        func end() { lock.withLock { isEnded = true } }
    }
    private let lock = NSLock()
    private var all: [Token] = []
    func begin(_ options: ProcessInfo.ActivityOptions, reason: String) -> ActivityToken {
        let t = Token(options, reason)
        lock.withLock { all.append(t) }
        return t
    }
    var begun: [Token] { lock.withLock { all } }
    var active: [Token] { begun.filter { !$0.ended } }
}

private let t0 = 1_700_000_000.0
private let selfPID: Int32 = 777

@MainActor
private final class Fixture {
    let samplers = Samplers()
    let streams = Streams()
    let clock = FakeClock(t0)
    let scheduler = ManualScheduler()
    let activities = FakeActivities()
    let detection = Gate()
    /// Holds `makeSession` (before the session exists).
    let creation = Gate()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpthub-\(UUID().uuidString)")
    let hub: TelemetryHub

    init() {
        let samplers = samplers, streams = streams, clock = clock, detection = detection, creation = creation
        var deps = TelemetryHub.Dependencies(
            makeSampler: { samplers.make() },
            makeStream: { streams.make() },
            clock: { clock.now },
            scheduler: scheduler,
            argv0: { "/Games/Game\($0).exe" },
            detectStack: { _ in detection.pass(); return Stack(runtime: "native") },
            selfPID: selfPID,
            makeSession: { options, parts in
                creation.pass()
                return try RecordingSession(
                    options: options, telemetry: parts.telemetry, hud: parts.hud, clock: parts.clock,
                    tickInterval: 0.01,
                    machine: { (RunInfo.Machine(modelID: "Mac16,5", chip: "Apple M4 Max", memoryGB: 64,
                                                osVersion: "26.0", osBuild: "x"), RunInfo.Settings()) },
                    stackDetector: parts.stackDetector, argv0: parts.argv0, stackOf: parts.stackOf)
            })
        deps.activities = activities
        hub = TelemetryHub(dependencies: deps)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func options(seconds: Double? = nil) -> RecordingSession.Options {
        RecordingSession.Options(seconds: seconds, runsRoot: root, appVersion: "test")
    }

    /// Run folders created under the runs root.
    var bundles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mptrun" }
    }

    /// Two lines `frames` apart, ending at `at` (1 s apart).
    func play(_ pid: Int32, frames: Int, at time: Double, from start: Int = 0) {
        let stream = streams.last!
        for (t, f) in [(time - 1, start), (time, start + frames)] {
            stream.send(HUDEvent(pid: pid, imagePath: "/Games/Game\(pid).exe", time: t,
                                 line: MetalHUDLine(frames: f, a: 0, b: 0, frameTimes: [])))
        }
    }
}

/// Lets main-queue deliveries made so far run.
@MainActor
private func settle() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition(), "timed out waiting for \(what)")
}

// MARK: - Tests

@MainActor
@Suite struct TelemetryHubTests {
    @Test func nothingRunsWithoutTokens() async {
        let f = Fixture()
        f.hub.menuBarWantsSamplesWhenFollowing = true
        await settle()
        #expect(f.samplers.count == 0)
        #expect(f.streams.count == 0)
        #expect(f.scheduler.activeRepeating == 0 && f.scheduler.activeOnce == 0)
        #expect(f.hub.latest == nil)
        #expect(f.hub.history.isEmpty)
    }

    @Test func hudTokenStartsStreamOnly() {
        let f = Fixture()
        let a = f.hub.acquire(.hud)
        let b = f.hub.acquire(.hud)
        #expect(f.streams.count == 1)
        #expect(f.streams.last?.started == true && f.streams.last?.stopped == false)
        #expect(f.samplers.count == 0)
        #expect(f.scheduler.activeRepeating == 0)
        withExtendedLifetime((a, b)) {}
    }

    @Test func samplesTokenStartsSampler() async {
        let f = Fixture()
        let t = f.hub.acquire(.samples)
        f.hub.waitForSamplerWork()
        #expect(f.samplers.live == 1)
        #expect(f.scheduler.activeRepeating == 1)
        #expect(f.scheduler.repeatingIntervals == [1])
        #expect(f.streams.count == 0)
        f.scheduler.tick()
        await settle()
        #expect(f.hub.latest?.sample.gpuW == 2)   // 1 was the priming sample
        #expect(f.hub.latest?.followedPID == nil)
        #expect(f.hub.history.count == 1)
        withExtendedLifetime(t) {}
    }

    @Test func releasingLastTokenStops() {
        let f = Fixture()
        var a: TelemetryHub.Token? = f.hub.acquire(.samples)
        let b = f.hub.acquire(.samples)
        let h = f.hub.acquire(.hud)
        b.release()
        b.release()   // idempotent: must not drop `a`'s hold
        f.hub.waitForSamplerWork()
        #expect(f.scheduler.activeRepeating == 1 && f.samplers.live == 1)
        #expect(a != nil)
        a = nil       // deinit releases
        #expect(f.scheduler.activeRepeating == 0)
        #expect(f.samplers.live == 0)
        #expect(f.streams.last?.stopped == false)
        h.release()
        #expect(f.streams.last?.stopped == true)
    }

    /// followedPID comes from the stream, so the menu bar's sampler starts without samples to begin with.
    @Test func menuBarSamplesOnlyWhileGameFollowed() async {
        let f = Fixture()
        f.hub.menuBarWantsSamplesWhenFollowing = true
        let h = f.hub.acquire(.hud)
        // Metal-PT's own HUD lines are never followed.
        f.clock.set(t0 + 1)
        f.play(selfPID, frames: 60, at: t0 + 1)
        await settle()
        #expect(f.hub.latest?.followedPID == nil)
        #expect(f.samplers.count == 0)

        f.clock.set(t0 + 2)
        f.play(4242, frames: 60, at: t0 + 2)
        await settle()
        #expect(f.hub.latest?.followedPID == 4242)
        f.hub.waitForSamplerWork()
        #expect(f.samplers.live == 1 && f.scheduler.activeRepeating == 1)
        f.scheduler.tick()
        await settle()
        #expect(f.hub.latest?.fps == 60)
        #expect(f.hub.latest?.followedApp == "Game4242.exe")
        #expect(f.hub.latest?.sample.gpuW != nil)

        // The game quits: no line for 3 s.
        f.clock.set(t0 + 5)
        f.scheduler.tick()
        await settle()
        await settle()
        #expect(f.hub.latest?.followedPID == nil)
        #expect(f.samplers.live == 0 && f.scheduler.activeRepeating == 0)
        withExtendedLifetime(h) {}
    }

    @Test func followClearsWhenGameGoesQuietWithoutSamples() async {
        let f = Fixture()
        let h = f.hub.acquire(.hud)
        f.clock.set(t0 + 1)
        f.play(4242, frames: 60, at: t0 + 1)
        await settle()
        #expect(f.hub.latest?.followedPID == 4242)
        #expect(f.scheduler.activeRepeating == 0)
        #expect(f.scheduler.activeOnce == 1)   // the quiet check
        f.clock.set(t0 + 4)
        f.scheduler.fireOnce()
        await settle()
        #expect(f.hub.latest?.followedPID == nil)
        withExtendedLifetime(h) {}
    }

    @Test func pinStickyUntilStale() async {
        let f = Fixture()
        let h = f.hub.acquire(.hud)
        f.clock.set(t0 + 1)
        f.play(100, frames: 10, at: t0 + 1)
        f.play(200, frames: 500, at: t0 + 1)
        await settle()
        #expect(f.hub.latest?.followedPID == 200)
        #expect(f.hub.followCandidates.map(\.pid) == [200, 100])
        #expect(f.hub.followCandidates.map(\.app) == ["Game200.exe", "Game100.exe"])
        f.hub.pinned = 100
        f.clock.set(t0 + 2)
        f.play(100, frames: 10, at: t0 + 2, from: 10)
        await settle()
        #expect(f.hub.latest?.followedPID == 100)
        // 100 exits; 200 keeps running.
        f.clock.set(t0 + 5)
        f.play(200, frames: 60, at: t0 + 5, from: 500)
        await settle()
        #expect(f.hub.pinned == nil)
        #expect(f.hub.latest?.followedPID == 200)
        withExtendedLifetime(h) {}
    }

    @Test func historyCapsAt300() async {
        let f = Fixture()
        let t = f.hub.acquire(.samples)
        for _ in 0..<305 { f.scheduler.tick() }
        await settle()
        #expect(f.hub.history.count == 300)
        #expect(f.hub.history.first?.sample.gpuW == 7)   // ticks 1…5 (gpuW 2…6) dropped
        #expect(f.hub.history.last?.sample.gpuW == 306)
        withExtendedLifetime(t) {}
    }

    @Test func recordingKeepsSamplerUntilStopped() async throws {
        let f = Fixture()
        try await f.hub.startRecording(options: f.options())
        f.hub.waitForSamplerWork()
        #expect(f.samplers.live == 1)
        #expect(f.scheduler.activeRepeating == 0)   // the session's ticks drive sampling
        #expect(f.streams.count == 0)               // a recording does not turn FPS logging on
        try await waitUntil("a recording tick") { f.hub.recording != nil }
        let t = f.hub.acquire(.samples)
        t.release()
        #expect(f.samplers.live == 1)
        #expect(f.hub.history.count > 0)
        let result = try #require(await f.hub.stopRecording())
        #expect(f.samplers.live == 0)
        #expect(f.hub.recording == nil)
        #expect(f.hub.lastRun == result)
        #expect(await f.hub.stopRecording() == nil)
        #expect(FileManager.default.fileExists(atPath: result.directory.path))
    }

    @Test func startWithoutGameRecordsTelemetry() async throws {
        let f = Fixture()
        try await f.hub.startRecording(options: f.options(seconds: 2))
        await #expect(throws: TelemetryHub.RecordingError.alreadyRecording) {
            try await f.hub.startRecording(options: f.options())
        }
        // The session ends itself after 2 ticks; the hub finishes it.
        try await waitUntil("the run to finish") { f.hub.lastRun != nil && f.hub.recording == nil }
        let run = try #require(f.hub.lastRun)
        let b = try RunBundle.load(run.directory)
        #expect(b.rows.count == 2)
        #expect(b.rows.allSatisfy { $0["fps"] == "" && $0["gpu_w"] != "" })
        #expect(b.info.warnings.contains("game process never identified"))
        #expect(f.samplers.live == 0)
        #expect(f.streams.count == 0)
    }

    /// The session gets the hub's stream (events fanned out); finishing the run leaves the stream running.
    @Test func recordingSharesHubStream() async throws {
        let f = Fixture()
        let h = f.hub.acquire(.hud)
        try await f.hub.startRecording(options: f.options())
        f.clock.set(t0 + 1)
        f.play(4242, frames: 60, at: t0 + 1)
        try await waitUntil("the recording to follow the game") { f.hub.recording?.followedPID == 4242 }
        #expect(f.hub.latest?.followedPID == 4242)
        let result = try #require(await f.hub.stopRecording())
        #expect(f.streams.count == 1)
        #expect(f.streams.last?.stopped == false)
        #expect(try RunBundle.load(result.directory).info.game.exe == "Game4242.exe")
        withExtendedLifetime(h) {}
    }

    @Test func stopFinishesBundle() async throws {
        let f = Fixture()
        try await f.hub.startRecording(options: f.options())
        try await waitUntil("a recording tick") { f.hub.recording != nil }
        let result = try #require(await f.hub.stopRecording())
        let summary = try #require(result.summary)
        #expect(FileManager.default.fileExists(atPath: summary.path))
        #expect(try RunBundle.load(result.directory).info.end != nil)
        #expect(f.hub.lastRun == result)
        #expect(!f.hub.isRecording)
    }

    /// The finish runs off the main actor; while it runs a second start (double hotkey press) is refused.
    @Test func stopRunsOffMainAndRefusesStartWhileFinishing() async throws {
        let f = Fixture()
        let h = f.hub.acquire(.hud)
        try await f.hub.startRecording(options: f.options())
        f.detection.close()   // the session's stack detection of the game now hangs, so `stop` waits for it
        f.clock.set(t0 + 1)
        f.play(4242, frames: 60, at: t0 + 1)
        try await waitUntil("the recording to follow the game") { f.hub.recording?.followedPID == 4242 }
        let stopping = Task { await f.hub.stopRecording() }
        try await waitUntil("the stop to begin") { f.hub.isFinishingRecording }
        // The main actor is free while the session finishes.
        #expect(!f.hub.isRecording)
        await #expect(throws: TelemetryHub.RecordingError.stillFinishing) {
            try await f.hub.startRecording(options: f.options())
        }
        f.detection.open()
        let result = try #require(await stopping.value)
        #expect(!f.hub.isFinishingRecording)
        #expect(f.hub.lastRun == result)
        try await f.hub.startRecording(options: f.options())   // allowed again
        #expect(f.hub.stopRecordingNow() != nil)
        withExtendedLifetime(h) {}
    }

    /// A recording holds the App-Nap/idle-sleep activity from its start until it is finished, on every exit path:
    /// stop, quit (`stopRecordingNow`) and a start that fails. Nothing else holds it.
    @Test func recordingHoldsActivityUntilFinished() async throws {
        let f = Fixture()
        let samples = f.hub.acquire(.samples)
        let hud = f.hub.acquire(.hud)
        #expect(f.activities.begun.isEmpty)
        try await f.hub.startRecording(options: f.options())
        let a = try #require(f.activities.active.first)
        #expect(f.activities.active.count == 1)
        #expect(a.options == AppActivity.recording)
        #expect(a.options.contains(.idleSystemSleepDisabled) && a.options.contains(.userInitiated))
        #expect(a.reason == "Recording a game run")
        try await waitUntil("a recording tick") { f.hub.recording != nil }
        _ = await f.hub.stopRecording()
        #expect(f.activities.active.isEmpty)

        try await f.hub.startRecording(options: f.options())
        #expect(f.activities.active.count == 1)
        _ = f.hub.stopRecordingNow()
        #expect(f.activities.active.isEmpty)

        // A start that fails (the runs root is under a file) ends it too.
        let file = f.root.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try Data().write(to: file)
        await #expect(throws: (any Error).self) {
            try await f.hub.startRecording(options: RecordingSession.Options(
                runsRoot: file.appendingPathComponent("runs"), appVersion: "test"))
        }
        #expect(f.activities.begun.count == 3)
        #expect(f.activities.active.isEmpty)
        withExtendedLifetime((samples, hud)) {}
    }

    /// `log` dying after it started is noticed: the follow clears, `streamError` says so, and the stream is restarted
    /// after 1 s, 2 s, 5 s, then every 30 s while a `.hud` hold exists. A failed start is retried the same way.
    /// Releasing the hold stops retrying.
    @Test func deadStreamRestartsWithBackoff() async throws {
        let f = Fixture()
        let hud = f.hub.acquire(.hud)
        f.clock.set(t0 + 1)
        f.play(4242, frames: 60, at: t0 + 1)
        try await waitUntil("the game to be followed") { f.hub.latest?.followedPID == 4242 }
        f.scheduler.fireOnce()   // drop the quiet timer (the game is still live at t0 + 1)
        let before = f.scheduler.onceDelays.count

        f.streams.last?.die()
        try await waitUntil("the death to be noticed") { f.hub.streamError != nil }
        #expect(f.hub.latest?.followedPID == nil)
        #expect(f.scheduler.onceDelays.dropFirst(before) == [1])
        #expect(f.streams.count == 1)
        f.scheduler.fireOnce()
        try await waitUntil("the restart") { f.streams.count == 2 }
        #expect(f.streams.last?.started == true)
        #expect(f.hub.streamError == nil)

        // Dies again at once (and again): the delays grow, then stay at 30 s. A start that fails counts too.
        for _ in 0..<3 {
            f.streams.last?.die()
            try await waitUntil("the death") { f.hub.streamError != nil }
            f.scheduler.fireOnce()
            try await waitUntil("the restart") { f.hub.streamError == nil }
        }
        f.streams.failNext(1)
        f.streams.last?.die()
        try await waitUntil("the death") { f.hub.streamError != nil }
        f.scheduler.fireOnce()                     // this start fails
        try await waitUntil("the failed start") { f.scheduler.activeOnce == 1 }
        #expect(f.hub.streamError != nil)
        f.scheduler.fireOnce()
        try await waitUntil("the restart") { f.hub.streamError == nil }
        #expect(f.scheduler.onceDelays.dropFirst(before) == [1, 2, 5, 30, 30, 30])

        // Dies; the hold is released before the retry: no retry, no error.
        let count = f.streams.count
        f.streams.last?.die()
        try await waitUntil("the death") { f.hub.streamError != nil }
        hud.release()
        await settle()
        #expect(f.scheduler.activeOnce == 0)
        #expect(f.hub.streamError == nil)
        f.scheduler.fireOnce()
        await settle()
        #expect(f.streams.count == count)
    }

    /// Quit path: finishes synchronously.
    @Test func stopRecordingNowFinishesSynchronously() async throws {
        let f = Fixture()
        try await f.hub.startRecording(options: f.options())
        let result = try #require(f.hub.stopRecordingNow())
        #expect(try RunBundle.load(result.directory).info.end != nil)
        #expect(!f.hub.isRecording && f.hub.recording == nil)
        f.hub.waitForSamplerWork()
        #expect(f.samplers.live == 0)
        #expect(await f.hub.stopRecording() == nil)
    }

    /// An update produced before the stream stopped but delivered after it must not bring the game back.
    @Test func staleUpdateCannotResurrectFollow() async {
        let f = Fixture()
        let h = f.hub.acquire(.hud)
        f.clock.set(t0 + 1)
        f.play(4242, frames: 60, at: t0 + 1)
        await settle()
        let stale = f.hub.latestUpdateForTesting
        #expect(stale?.snapshot.followedPID == 4242)
        h.release()
        await settle()
        #expect(f.hub.latest?.followedPID == nil)
        if let stale { f.hub.applyForTesting(stale) }
        #expect(f.hub.latest?.followedPID == nil)
    }

    @Test func tokenReleasedOffMainReleasesOnMain() async throws {
        let f = Fixture()
        let t = f.hub.acquire(.samples)
        #expect(f.scheduler.activeRepeating == 1)
        DispatchQueue.global().async { t.release() }
        try await waitUntil("the hold to drop") { f.scheduler.activeRepeating == 0 }
        f.hub.waitForSamplerWork()
        #expect(f.samplers.live == 0)
    }

    /// Quit while the session is still being created: the start is aborted, nothing is left running or half-written.
    @Test func stopNowWhileCreatingAbortsStart() async throws {
        let f = Fixture()
        f.creation.close()
        let start = Task { try await f.hub.startRecording(options: f.options()) }
        try await waitUntil("the start to begin") { f.hub.isRecording }
        #expect(f.hub.stopRecordingNow() == nil)
        #expect(!f.hub.isRecording)
        f.creation.open()
        await #expect(throws: TelemetryHub.RecordingError.stoppedWhileStarting) { try await start.value }
        #expect(f.bundles.isEmpty)
        #expect(!f.hub.isRecording && f.hub.recording == nil)
        f.hub.waitForSamplerWork()
        #expect(f.samplers.live == 0)
        try await f.hub.startRecording(options: f.options())   // the hub is usable again
        #expect(f.hub.stopRecordingNow() != nil)
    }

    /// Quit after the session exists but before it starts: the session itself is stopped, so it never starts.
    @Test func stopNowBeforeSessionStartStopsIt() async throws {
        let f = Fixture()
        let gate = Gate()
        gate.close()
        f.hub.beforeSessionStartForTesting = { gate.pass() }
        let start = Task { try await f.hub.startRecording(options: f.options()) }
        try await waitUntil("the session to exist") { f.hub.startingSessionForTesting != nil }
        _ = f.hub.stopRecordingNow()
        gate.open()
        await #expect(throws: (any Error).self) { try await start.value }
        #expect(f.bundles.isEmpty)
        #expect(!f.hub.isRecording && !f.hub.isFinishingRecording)
        // A stopped-before-start session refuses to start; nothing ticks.
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.hub.recording == nil && f.hub.history.isEmpty)
    }

    /// An expired pin is honoured even from an update too old to apply otherwise.
    @Test func staleUpdateStillClearsDeadPin() async {
        let f = Fixture()
        let h = f.hub.acquire(.hud)
        f.clock.set(t0 + 1)
        f.play(4242, frames: 60, at: t0 + 1)
        await settle()
        f.hub.pinned = 100
        let stale = HubEngine.Update(snapshot: HubSnapshot(time: t0, sample: TelemetrySample(), fps: nil,
                                                           followedPID: nil, followedApp: nil, stack: nil),
                                     addToHistory: false, expiredPin: 100, seq: 0)
        f.hub.applyForTesting(stale)
        #expect(f.hub.pinned == nil)
        #expect(f.hub.latest?.followedPID == 4242)   // the rest of the stale update is still dropped
        withExtendedLifetime(h) {}
    }
}
