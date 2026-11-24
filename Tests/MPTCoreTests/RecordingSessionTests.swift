import Testing
import Foundation
@testable import MPTCore

private final class FakeTelemetry: TelemetrySource, @unchecked Sendable {
    func sample() -> TelemetrySample { TelemetrySample(gpuW: 10, batteryPct: 90, onAC: true) }
}

/// Events sent before `start` are buffered and replayed (in order) when it starts; nothing after `stop`.
private final class FakeHUD: HUDEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (HUDEvent) -> Void)?
    private var pending: [HUDEvent] = []
    private var isStopped = false
    var stopped: Bool { lock.withLock { isStopped } }
    func start(onEvent: @escaping @Sendable (HUDEvent) -> Void) throws {
        let replay: [HUDEvent] = lock.withLock {
            guard !isStopped else { return [] }
            handler = onEvent
            defer { pending = [] }
            return pending
        }
        replay.forEach(onEvent)
    }
    func stop() { lock.withLock { isStopped = true; handler = nil } }
    func send(_ e: HUDEvent) {
        let h: (@Sendable (HUDEvent) -> Void)? = lock.withLock {
            if handler == nil && !isStopped { pending.append(e) }
            return handler
        }
        h?(e)
    }
}

/// Returns `values` in order, then keeps returning the last one.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]
    init(_ values: [Double]) { self.values = values }
    func now() -> Double {
        lock.withLock { values.count > 1 ? values.removeFirst() : values[0] }
    }
}

private let t0 = 1_700_000_000.0

@Suite struct RecordingSessionTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mptsession-\(UUID().uuidString)")
    }

    private func makeSession(root: URL, seconds: Double?, clock: FakeClock, hud: FakeHUD = FakeHUD(),
                             warmup: Double = 0) throws -> RecordingSession {
        let options = RecordingSession.Options(seconds: seconds, warmup: warmup, label: "l", settings: "s",
                                               notes: "n", runsRoot: root, follow: .busiest, launch: nil,
                                               appVersion: "test")
        return try RecordingSession(
            options: options, telemetry: FakeTelemetry(), hud: hud, clock: { clock.now() },
            tickInterval: 0.01,
            machine: { (RunInfo.Machine(modelID: "Mac16,5", chip: "Apple M4 Max", memoryGB: 64, osVersion: "26.0",
                                        osBuild: "x"), RunInfo.Settings()) },
            stackDetector: { _ in Stack(runtime: "native") },
            argv0: { _ in "Game" })
    }

    /// Starts, waits for the session to end on its own (`seconds`), stops.
    private func runToEnd(_ s: RecordingSession) throws -> (RunResult?, [SessionStatus]) {
        let ended = DispatchSemaphore(value: 0)
        let statuses = Statuses()
        s.onTick = { statuses.append($0) }
        s.onEnd = { _ in ended.signal() }
        try s.start()
        #expect(ended.wait(timeout: .now() + 10) == .success)
        return (s.stop(), statuses.all)
    }

    @Test func startStopWritesBundle() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try makeSession(root: root, seconds: 3, clock: FakeClock([t0, t0 + 1, t0 + 2, t0 + 3, t0 + 4]))
        let (result, statuses) = try runToEnd(s)
        let r = try #require(result)
        let b = try RunBundle.load(r.directory)
        #expect(b.rows.count == 3)
        #expect(statuses.count == 3)
        #expect(statuses.map(\.elapsed) == [1, 2, 3])
        #expect(b.info.end == Date(timeIntervalSince1970: t0 + 4))
        #expect(b.info.user.label == "l" && b.info.user.gameSettings == "s" && b.info.user.notes == "n")
        #expect(r.summary.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func stopFinishesBundle() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hud = FakeHUD()
        let s = try makeSession(root: root, seconds: nil, clock: FakeClock([t0, t0 + 1]), hud: hud)
        try s.start()
        let first = s.stop()
        let second = s.stop()
        #expect(first != nil)
        #expect(first == second)
        #expect(hud.stopped)
        let b = try RunBundle.load(try #require(first).directory)
        #expect(b.info.end != nil)
    }

    @Test func stopFromInsideOnTick() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try makeSession(root: root, seconds: nil, clock: FakeClock([t0, t0 + 1, t0 + 2]))
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        s.onTick = { [unowned s] _ in box.set(s.stop()); done.signal() }
        try s.start()
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(box.value != nil)
        #expect(s.stop() == box.value)
    }

    @Test func startWithoutGameRecordsTelemetry() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try makeSession(root: root, seconds: 2, clock: FakeClock([t0, t0 + 1, t0 + 2, t0 + 3]))
        let (result, statuses) = try runToEnd(s)
        let b = try RunBundle.load(try #require(result).directory)
        #expect(b.rows.count == 2)
        #expect(b.rows.allSatisfy { $0["fps"] == "" && $0["gpu_w"] == "10.00" })
        #expect(b.info.warnings.contains("game process never identified"))
        #expect(statuses.allSatisfy { $0.fps == nil && $0.followedPID == nil && !$0.sawFPSSource })
    }

    @Test func followedGameNamesTheRun() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hud = FakeHUD()
        let clock = FakeClock([t0, t0 + 1, t0 + 2, t0 + 3])
        let s = try makeSession(root: root, seconds: 2, clock: clock, hud: hud)
        let ended = DispatchSemaphore(value: 0)
        s.onEnd = { _ in ended.signal() }
        // Sent before start (replayed by the fake on start), so the first tick already follows the game.
        let line = MetalHUDLine(frames: 0, a: 0, b: 0, frameTimes: [])
        hud.send(HUDEvent(pid: 4242, imagePath: "/x/Game", time: t0, line: line))
        hud.send(HUDEvent(pid: 4242, imagePath: "/x/Game", time: t0 + 0.5,
                          line: MetalHUDLine(frames: 30, a: 0, b: 0, frameTimes: [])))
        try s.start()
        #expect(ended.wait(timeout: .now() + 10) == .success)
        let r = try #require(s.stop())
        #expect(r.directory.lastPathComponent.hasSuffix("-game.mptrun"))
        let b = try RunBundle.load(r.directory)
        #expect(b.info.game.exe == "Game")
        #expect(b.info.stack.runtime == "native")
    }

    @Test func sleepGapAddsWarning() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Start at 0; ticks at 1 and 2, then a 30 s gap (sleep) to the third and last tick at 32; finish at 33.
        let s = try makeSession(root: root, seconds: 3,
                                clock: FakeClock([t0, t0 + 1, t0 + 2, t0 + 32, t0 + 33]))
        let (result, _) = try runToEnd(s)
        let b = try RunBundle.load(try #require(result).directory)
        #expect(b.info.warnings.contains("recording spanned a sleep"))
        #expect(b.info.steadyEndS == 2)
        #expect(b.rows.count == 3)
        // Rows after the gap are outside the steady window.
        #expect(RunSummary(b).steadySeconds == [0, 1])
    }

    @Test func stopFromOnMessageReturnsEarly() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try makeSession(root: root, seconds: nil, clock: FakeClock([t0, t0 + 1]))
        let messages = Messages()
        let nested = ResultBox()
        s.onMessage = { [unowned s] m in
            messages.append(m.text)
            nested.set(s.stop())
        }
        try s.start()
        // A read-only bundle folder makes finishing and the summary fail, so `stop` sends error messages.
        let dir = try #require(s.directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let outer = s.stop()
        #expect(outer?.directory == dir)
        #expect(outer?.summary == nil)
        #expect(nested.value == nil)
        let texts = messages.all
        #expect(texts.filter { $0.hasPrefix("error finishing run") }.count == 1)
        #expect(texts.filter { $0.hasPrefix("could not write the summary") }.count == 1)
        #expect(s.stop() == outer)
    }

    @Test func rejectsWarmupNotShorterThanSeconds() {
        #expect(throws: RecordingSession.OptionsError.self) {
            _ = try makeSession(root: makeRoot(), seconds: 5, clock: FakeClock([t0]), warmup: 5)
        }
        #expect(throws: RecordingSession.OptionsError.self) {
            _ = try makeSession(root: makeRoot(), seconds: 0, clock: FakeClock([t0]))
        }
    }
}

private final class Statuses: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SessionStatus] = []
    func append(_ s: SessionStatus) { lock.withLock { items.append(s) } }
    var all: [SessionStatus] { lock.withLock { items } }
}

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RunResult?
    func set(_ r: RunResult?) { lock.withLock { stored = r } }
    var value: RunResult? { lock.withLock { stored } }
}

@Suite struct DataRootTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    @Test func overrideWins() {
        let url = DataRoot.resolve(override: "~/x/out", env: ["MPT_DATA_ROOT": "/env"], name: "runs")
        #expect(url.path == home + "/x/out")
    }

    @Test func envRootGetsName() {
        #expect(DataRoot.resolve(override: nil, env: ["MPT_DATA_ROOT": "/tmp/mpt"], name: "runs").path
                == "/tmp/mpt/runs")
        #expect(DataRoot.resolve(override: nil, env: ["MPT_DATA_ROOT": "~/d"], name: "projects").path
                == home + "/d/projects")
    }

    @Test func emptyOrWhitespaceEnvFallsBackToDocuments() {
        for value in ["", "   ", "\t\n"] {
            let url = DataRoot.resolve(override: nil, env: ["MPT_DATA_ROOT": value], name: "runs")
            #expect(url.path.hasSuffix("/Documents/Metal-PT/runs"))
        }
        #expect(DataRoot.resolve(override: nil, env: [:], name: "exports").path.hasSuffix("/Documents/Metal-PT/exports"))
    }
}
