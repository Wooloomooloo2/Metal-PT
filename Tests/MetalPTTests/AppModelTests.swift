import Foundation
import Testing
@testable import MetalPT
@testable import MPTApp
@testable import MPTCore

// MARK: - Fakes

private final class FakeLaunchctl: LaunchctlRunning, @unchecked Sendable {
    var env: [String: String] = [:]
    var calls: [String] = []
    /// Throws a non-`FPSLoggingError` from setenv (an unexpected failure).
    var setError: Error?
    /// Runs at each unsetenv, before the variable is removed (to observe the app's state at that moment).
    var onUnset: (() -> Void)?
    func getenv(_ name: String) -> String? { env[name] }
    func setenv(_ name: String, _ value: String) throws {
        calls.append("set \(name)")
        if let setError { throw setError }
        env[name] = value
    }
    func unsetenv(_ name: String) throws {
        onUnset?()
        calls.append("unset \(name)")
        env[name] = nil
    }
}

private final class CountingSampler: TelemetrySource, @unchecked Sendable {
    func sample() -> TelemetrySample {
        var s = TelemetrySample()
        s.gpuW = 1
        return s
    }
}

private final class QuietStream: HUDEventSource, @unchecked Sendable {
    func start(onEvent: @escaping @Sendable (HUDEvent) -> Void) throws {}
    func stop() {}
}

private struct NoTimer: HubTimer { func cancel() {} }

private struct NoScheduler: HubScheduler {
    func repeating(every interval: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer { NoTimer() }
    func once(after delay: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer { NoTimer() }
}

@MainActor
private final class FakeNotifier: RecordingNotifying {
    var onOpenRun: ((URL) -> Void)?
    var authorizationRequests = 0
    var posted: [RecordingNotice] = []
    func requestAuthorizationIfNeeded() { authorizationRequests += 1 }
    func post(_ notice: RecordingNotice) { posted.append(notice) }
}

/// A hub whose recordings are real sessions on fake sources (fast ticks), writing under a temp root.
@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mptapp-\(UUID().uuidString)")
    let launchctl = FakeLaunchctl()
    let notifier = FakeNotifier()
    let defaults: UserDefaults = MemoryDefaults()   // in memory: no plist in ~/Library/Preferences
    let hub: TelemetryHub
    let model: AppModel

    init(fpsLogging: Bool = false) {
        defaults.set(fpsLogging, forKey: SettingsKey.fpsLogging)
        let deps = TelemetryHub.Dependencies(
            makeSampler: { CountingSampler() },
            makeStream: { QuietStream() },
            clock: { Date().timeIntervalSince1970 },
            scheduler: NoScheduler(),
            argv0: { _ in nil },
            detectStack: { _ in Stack(runtime: "native") },
            selfPID: getpid(),
            makeSession: { options, parts in
                try RecordingSession(
                    options: options, telemetry: parts.telemetry, hud: parts.hud, clock: parts.clock,
                    tickInterval: 0.02,
                    machine: { (RunInfo.Machine(modelID: "Mac16,5", chip: "Apple M4 Max", memoryGB: 64,
                                                osVersion: "26.0", osBuild: "x"), RunInfo.Settings()) },
                    stackDetector: parts.stackDetector, argv0: parts.argv0, stackOf: parts.stackOf)
            })
        hub = TelemetryHub(dependencies: deps)
        model = AppModel(hub: hub, fpsLogging: FPSLogging(launchctl: launchctl), live: true, usesAppKit: false,
                         defaults: defaults, env: ["MPT_DATA_ROOT": root.path], notifier: notifier)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var hudHolds: Int { hub.holdCountForTesting(.hud) }
}

private let both = FPSLogging.variables

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition(), "timed out waiting for \(what)")
}

// MARK: - Tests

@MainActor
@Suite struct AppModelTests {
    /// The `.hud` token (the log stream) is held exactly while FPS logging is on.
    @Test func hudTokenOnlyWhileFPSLoggingOn() {
        let f = Fixture(fpsLogging: false)
        f.model.launch()
        #expect(f.hudHolds == 0)
        f.model.setFPSLogging(true)
        #expect(f.model.fpsLoggingOn)
        #expect(f.hudHolds == 1)
        f.model.setFPSLogging(true)
        #expect(f.hudHolds == 1)
        f.model.setFPSLogging(false)
        #expect(f.hudHolds == 0)
        #expect(f.defaults.bool(forKey: SettingsKey.fpsLogging) == false)
        f.model.setFPSLogging(true)
        f.model.quit()
        #expect(f.hudHolds == 0)
    }

    /// Adopted at launch when the setting is on: the token is taken then.
    @Test func launchWithFPSLoggingOnHoldsToken() {
        let f = Fixture(fpsLogging: true)
        f.model.launch()
        #expect(f.model.fpsLoggingOn)
        #expect(f.hudHolds == 1)
        for n in both { #expect(f.launchctl.env[n] == "1") }
        f.model.quit()
        for n in both { #expect(f.launchctl.env[n] == nil) }
    }

    /// Quit hands the variables back even when we believe FPS logging is off (recovery reads state).
    @Test func quitReleasesLaunchctlEvenWhenOff() {
        let f = Fixture(fpsLogging: false)
        f.model.launch()
        for n in both { f.launchctl.env[n] = "1" }   // set behind our back after launch
        f.model.quit()
        for n in both { #expect(f.launchctl.env[n] == nil) }
    }

    /// Quit unsets the variables before the blocking stop, finishes the recording, then releases the stream.
    @Test func quitReleasesBeforeStoppingRecording() async throws {
        let f = Fixture(fpsLogging: true)
        f.model.launch()
        f.model.toggleRecording()
        try await waitUntil("recording") { f.model.recordState == .recording }
        var recordingAtUnset: [Bool] = []
        var hudHoldsAtUnset: [Int] = []
        let hub = f.hub
        f.launchctl.onUnset = {
            MainActor.assumeIsolated {
                recordingAtUnset.append(hub.isRecording)
                hudHoldsAtUnset.append(hub.holdCountForTesting(.hud))
            }
        }
        f.model.quit()
        #expect(recordingAtUnset == [true, true])
        #expect(hudHoldsAtUnset == [1, 1])
        for n in both { #expect(f.launchctl.env[n] == nil) }
        #expect(!f.hub.isRecording)
        #expect(f.hudHolds == 0)
        let run = try #require(f.hub.lastRun)
        #expect(try RunBundle.load(run.directory).info.end != nil)
        #expect(run.directory.path.hasPrefix(f.root.appendingPathComponent("runs").path))
    }

    /// A second press while the first is still starting stops the recording (no "already running", no lost stop).
    @Test func doubleToggleDuringStartingStops() async throws {
        let f = Fixture()
        f.model.launch()
        f.model.toggleRecording()
        #expect(f.model.recordState == .starting)
        f.model.toggleRecording()
        #expect(f.model.recordingProblem == nil)
        #expect(f.model.recordState == .saving)
        try await waitUntil("the run to be saved") { f.model.recordState == .idle && f.hub.lastRun != nil }
        #expect(f.model.recordingProblem == nil)
        #expect(!f.hub.isRecording)
        let run = try #require(f.hub.lastRun)
        #expect(try RunBundle.load(run.directory).info.end != nil)
        #expect(f.model.recentRuns.count == 1)
    }

    /// The state never drops back to idle between the press and the hub's start.
    @Test func startingDoesNotFlickerToIdle() async throws {
        let f = Fixture()
        f.model.launch()
        var states: [AppModel.RecordState] = []
        let c = f.model.$recordState.sink { states.append($0) }
        f.model.toggleRecording()
        try await waitUntil("recording") { f.model.recordState == .recording }
        f.model.toggleRecording()
        try await waitUntil("idle") { f.model.recordState == .idle }
        c.cancel()
        var deduped: [AppModel.RecordState] = []
        for s in states where deduped.last != s { deduped.append(s) }
        #expect(deduped == [.idle, .starting, .recording, .saving, .idle])
    }

    /// "still being saved" is shown while the save runs and cleared once it completes.
    @Test func recordingProblemClearedAfterSave() async throws {
        let f = Fixture()
        f.model.launch()
        f.model.toggleRecording()
        try await waitUntil("recording") { f.model.recordState == .recording }
        f.model.toggleRecording()
        #expect(f.model.recordState == .saving)
        f.model.toggleRecording()
        #expect(f.model.recordingProblem == "\(TelemetryHub.RecordingError.stillFinishing)")
        try await waitUntil("the save") { f.model.recordState == .idle }
        #expect(f.model.recordingProblem == nil)
        #expect(!f.hub.isRecording)
    }

    /// Start asks for permission and posts "no game detected yet"; stop posts "Run saved" that opens the run.
    @Test func notificationsAndOpenRun() async throws {
        let f = Fixture()
        f.model.launch()
        f.model.toggleRecording()
        try await waitUntil("recording") { f.model.recordState == .recording }
        #expect(f.notifier.authorizationRequests == 1)
        #expect(f.notifier.posted.first?.title == "Recording — no game detected yet")
        f.model.toggleRecording()
        try await waitUntil("idle") { f.model.recordState == .idle }
        let run = try #require(f.hub.lastRun)
        let saved = try #require(f.notifier.posted.last)
        #expect(f.notifier.posted.count == 2)
        #expect(saved.title == "Run saved — add settings")
        #expect(saved.run == run.directory)
        #expect(!saved.body.isEmpty)
        f.notifier.onOpenRun?(run.directory)
        #expect(f.model.page == .runs)
        #expect(f.model.selectedRun == run.directory)
    }

    /// Session messages reach the app: warnings and errors are shown, and a run with an error is announced as
    /// "saved with problems" (still opening the run). The next clean run is a plain "Run saved".
    @Test func sessionProblemsAreShownAndMarkTheSavedRun() async throws {
        let f = Fixture()
        f.model.launch()
        f.model.toggleRecording()
        try await waitUntil("recording") { f.model.recordState == .recording }
        let send = try #require(f.hub.onRecordingMessage, "the app must listen to session messages")
        send(SessionMessage(level: .info, text: "launched x"))
        #expect(f.model.recordingProblem == nil)
        send(SessionMessage(level: .warning, text: "log stream stopped unexpectedly; still recording telemetry"))
        #expect(f.model.recordingProblem?.contains("log stream stopped unexpectedly") == true)
        send(SessionMessage(level: .error, text: "error writing sample: disk full"))
        #expect(f.model.recordingProblem?.contains("error writing sample: disk full") == true)
        f.model.toggleRecording()
        try await waitUntil("idle") { f.model.recordState == .idle }
        let run = try #require(f.hub.lastRun)
        let saved = try #require(f.notifier.posted.last)
        #expect(saved.title == "Run saved with problems — see the run")
        #expect(saved.run == run.directory)
        // The problem stays visible after the save.
        #expect(f.model.recordingProblem?.contains("disk full") == true)

        f.model.toggleRecording()
        try await waitUntil("recording again") { f.model.recordState == .recording }
        #expect(f.model.recordingProblem == nil)
        f.model.toggleRecording()
        try await waitUntil("idle again") { f.model.recordState == .idle && f.notifier.posted.count == 4 }
        #expect(f.notifier.posted.last?.title == "Run saved — add settings")
    }

    @Test func startNoticeNamesGameAndStack() {
        let n = RecordingNotice.started(app: "Cyberpunk2077.exe",
                                        stack: Stack(runtime: "CrossOver", translator: "Rosetta",
                                                     graphics: ["D3DMetal"]))
        #expect(n.title == "Recording Cyberpunk2077.exe · CrossOver · Rosetta · D3DMetal")
        #expect(RecordingNotice.started(app: nil, stack: nil).title == "Recording — no game detected yet")
    }

    /// An unexpected (non-`FPSLoggingError`) failure is shown, not dropped; the preference is saved first.
    @Test func setFPSLoggingSurfacesUnexpectedErrors() {
        let f = Fixture()
        f.model.launch()
        f.launchctl.setError = CocoaError(.fileWriteNoPermission)
        f.model.setFPSLogging(true)
        #expect(f.defaults.bool(forKey: SettingsKey.fpsLogging))
        #expect(!f.model.fpsLoggingOn)
        #expect(f.model.fpsLoggingError != nil)
        #expect(f.hudHolds == 0)
    }
}
