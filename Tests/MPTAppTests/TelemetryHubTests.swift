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
    private let lock = NSLock()
    private var handler: (@Sendable (HUDEvent) -> Void)?
    private var isStarted = false
    private var isStopped = false
    var started: Bool { lock.withLock { isStarted } }
    var stopped: Bool { lock.withLock { isStopped } }
    func start(onEvent: @escaping @Sendable (HUDEvent) -> Void) throws {
        lock.withLock { guard !isStopped else { return }; isStarted = true; handler = onEvent }
    }
    func stop() { lock.withLock { isStopped = true; handler = nil } }
    func send(_ e: HUDEvent) { lock.withLock { handler }?(e) }
}

private final class Streams: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FakeStream] = []
    func make() -> FakeStream { let s = FakeStream(); lock.withLock { all.append(s) }; return s }
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

    func repeating(every interval: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer {
        let id = UUID()
        lock.withLock { repeating[id] = work; repeatingIntervals.append(interval) }
        return Handle { [weak self] in self?.lock.withLock { _ = self?.repeating.removeValue(forKey: id) } }
    }
    func once(after delay: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer {
        let id = UUID()
        lock.withLock { once[id] = work }
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

private let t0 = 1_700_000_000.0
private let selfPID: Int32 = 777

@MainActor
private final class Fixture {
    let samplers = Samplers()
    let streams = Streams()
    let clock = FakeClock(t0)
    let scheduler = ManualScheduler()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpthub-\(UUID().uuidString)")
    let hub: TelemetryHub

    init() {
        let samplers = samplers, streams = streams, clock = clock
        let deps = TelemetryHub.Dependencies(
            makeSampler: { samplers.make() },
            makeStream: { streams.make() },
            clock: { clock.now },
            scheduler: scheduler,
            argv0: { "/Games/Game\($0).exe" },
            detectStack: { _ in Stack(runtime: "native") },
            selfPID: selfPID,
            makeSession: { options, parts in
                try RecordingSession(
                    options: options, telemetry: parts.telemetry, hud: parts.hud, clock: parts.clock,
                    tickInterval: 0.01,
                    machine: { (RunInfo.Machine(modelID: "Mac16,5", chip: "Apple M4 Max", memoryGB: 64,
                                                osVersion: "26.0", osBuild: "x"), RunInfo.Settings()) },
                    stackDetector: parts.stackDetector, argv0: parts.argv0, stackOf: parts.stackOf)
            })
        hub = TelemetryHub(dependencies: deps)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func options(seconds: Double? = nil) -> RecordingSession.Options {
        RecordingSession.Options(seconds: seconds, runsRoot: root, appVersion: "test")
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
        try f.hub.startRecording(options: f.options())
        #expect(f.samplers.live == 1)
        #expect(f.scheduler.activeRepeating == 0)   // the session's ticks drive sampling
        #expect(f.streams.count == 0)               // a recording does not turn FPS logging on
        try await waitUntil("a recording tick") { f.hub.recording != nil }
        let t = f.hub.acquire(.samples)
        t.release()
        #expect(f.samplers.live == 1)
        #expect(f.hub.history.count > 0)
        let result = try #require(f.hub.stopRecording())
        #expect(f.samplers.live == 0)
        #expect(f.hub.recording == nil)
        #expect(f.hub.lastRun == result)
        #expect(f.hub.stopRecording() == nil)
        #expect(FileManager.default.fileExists(atPath: result.directory.path))
    }

    @Test func startWithoutGameRecordsTelemetry() async throws {
        let f = Fixture()
        try f.hub.startRecording(options: f.options(seconds: 2))
        #expect(throws: RecordingSession.StateError.self) { try f.hub.startRecording(options: f.options()) }
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
        try f.hub.startRecording(options: f.options())
        f.clock.set(t0 + 1)
        f.play(4242, frames: 60, at: t0 + 1)
        try await waitUntil("the recording to follow the game") { f.hub.recording?.followedPID == 4242 }
        #expect(f.hub.latest?.followedPID == 4242)
        let result = try #require(f.hub.stopRecording())
        #expect(f.streams.count == 1)
        #expect(f.streams.last?.stopped == false)
        #expect(try RunBundle.load(result.directory).info.game.exe == "Game4242.exe")
        withExtendedLifetime(h) {}
    }
}
