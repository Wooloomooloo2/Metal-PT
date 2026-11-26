import AppKit
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

private final class FakeActivities: ActivityProviding, @unchecked Sendable {
    final class Token: ActivityToken, @unchecked Sendable {
        let options: ProcessInfo.ActivityOptions
        private let lock = NSLock()
        private var isEnded = false
        init(_ options: ProcessInfo.ActivityOptions) { self.options = options }
        var ended: Bool { lock.withLock { isEnded } }
        func end() { lock.withLock { isEnded = true } }
    }
    private let lock = NSLock()
    private var all: [Token] = []
    func begin(_ options: ProcessInfo.ActivityOptions, reason: String) -> ActivityToken {
        let t = Token(options)
        lock.withLock { all.append(t) }
        return t
    }
    var active: [ProcessInfo.ActivityOptions] { lock.withLock { all }.filter { !$0.ended }.map(\.options) }
}

@MainActor
private final class FakeNotifier: RecordingNotifying {
    var onOpenRun: ((URL) -> Void)?
    var onPublishRun: ((URL) -> Void)?
    var authorizationRequests = 0
    var posted: [RecordingNotice] = []
    func requestAuthorizationIfNeeded() { authorizationRequests += 1 }
    func post(_ notice: RecordingNotice) { posted.append(notice) }
}

@MainActor
private final class FakeSounds: SoundPlaying {
    var played: [RecordSound] = []
    func play(_ sound: RecordSound) { played.append(sound) }
}

/// The model's clock: each read advances by `step` (2 s by default, so ordinary tests are never debounced); a test
/// that sets `step = 0` moves `now` itself.
@MainActor
private final class StepClock {
    var now = 1000.0
    var step = 2.0
    func read() -> Double {
        defer { now += step }
        return now
    }
}

private struct FakeNotificationStatus: NotificationStatusProviding {
    let value: NotificationStatus
    func status() async -> NotificationStatus { value }
}

/// A hub whose recordings are real sessions on fake sources (fast ticks), writing under a temp root.
@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mptapp-\(UUID().uuidString)")
    let launchctl = FakeLaunchctl()
    let notifier = FakeNotifier()
    let activities = FakeActivities()
    let sounds = FakeSounds()
    let clock = StepClock()
    let defaults: UserDefaults = MemoryDefaults()   // in memory: no plist in ~/Library/Preferences
    let hub: TelemetryHub
    let model: AppModel

    /// `dataRoot`: the data root instead of `root` (a file there makes every recording start fail). `env`: extra
    /// environment.
    init(fpsLogging: Bool = false, dataRoot: URL? = nil, env: [String: String] = [:],
         frontmost: (@MainActor () -> (pid: Int32, name: String?)?)? = nil,
         frameCheck: FrameReportingCheck? = nil) {
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
            },
            activities: activities)
        hub = TelemetryHub(dependencies: deps)
        let clock = clock
        model = AppModel(hub: hub, fpsLogging: FPSLogging(launchctl: launchctl), live: true, usesAppKit: false,
                         defaults: defaults,
                         env: env.merging(["MPT_DATA_ROOT": (dataRoot ?? root).path]) { a, _ in a },
                         notifier: notifier,
                         sounds: sounds, clock: { clock.read() },
                         notificationStatus: FakeNotificationStatus(value: .denied),
                         frontmost: frontmost, frameCheck: frameCheck)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var hudHolds: Int { hub.holdCountForTesting(.hud) }
}

private let both = FPSLogging.variables
private let opacity = "MTL_HUD_OPACITY"

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
        #expect(f.launchctl.env[opacity] == "0")   // Apple's HUD hidden by default
        f.model.quit()
        for n in both { #expect(f.launchctl.env[n] == nil) }
        #expect(f.launchctl.env[opacity] == nil)
    }

    /// "Show Apple's Metal HUD in games": saved, applied at once while FPS logging is on, and used at the next turn-on.
    @Test func showMetalHUDSettingDrivesOpacity() {
        let f = Fixture(fpsLogging: false)
        f.model.launch()
        f.model.setShowMetalHUD(true)
        #expect(f.defaults.bool(forKey: SettingsKey.showMetalHUD))
        #expect(f.model.showMetalHUD)
        #expect(f.launchctl.env[opacity] == nil)
        f.model.setFPSLogging(true)
        for n in both { #expect(f.launchctl.env[n] == "1") }
        #expect(f.launchctl.env[opacity] == nil)
        f.model.setShowMetalHUD(false)
        #expect(f.launchctl.env[opacity] == "0")
        #expect(f.model.fpsLoggingOn)
        #expect(f.hudHolds == 1)
        f.model.quit()
        #expect(f.launchctl.env[opacity] == nil)
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
        #expect(recordingAtUnset == [true, true, true])
        #expect(hudHoldsAtUnset == [1, 1, 1])
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
        // The start notice is posted when the start task resumes, which can be after the first tick shows
        // `.recording` (the main actor is shared with other tests).
        try await waitUntil("recording") { f.model.recordState == .recording && f.notifier.posted.count == 1 }
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
        #expect(!saved.offersPublish)
        f.notifier.onOpenRun?(run.directory)
        #expect(f.model.page == .runs)
        #expect(f.model.selectedRun == run.directory)
        #expect(f.model.submitRun == nil)
    }

    /// Settings → "Offer to publish after each run" (off by default): the "Run saved" notification offers
    /// "Publish…", which opens the run's Submit sheet in Runs.
    @Test func offerToPublishAfterARun() async throws {
        let f = Fixture()
        #expect(!f.model.offerPublish)
        f.defaults.set(true, forKey: SettingsKey.offerPublish)
        f.model.launch()
        f.model.toggleRecording()
        try await waitUntil("recording") { f.model.recordState == .recording && f.notifier.posted.count == 1 }
        f.model.toggleRecording()
        try await waitUntil("idle") { f.model.recordState == .idle && f.notifier.posted.count == 2 }
        let run = try #require(f.hub.lastRun)
        let saved = try #require(f.notifier.posted.last)
        #expect(saved.offersPublish)
        #expect(saved.body.hasSuffix("Publish it to metal-pt.com?"))
        f.notifier.onPublishRun?(run.directory)
        #expect(f.model.page == .runs)
        #expect(f.model.selectedRun == run.directory)
        #expect(f.model.submitRun == run.directory)
    }

    /// Session messages reach the app: warnings and errors are shown, and a run with an error is announced as
    /// "saved with problems" (still opening the run). The next clean run is a plain "Run saved".
    @Test func sessionProblemsAreShownAndMarkTheSavedRun() async throws {
        let f = Fixture()
        f.model.launch()
        f.model.toggleRecording()
        try await waitUntil("recording") { f.model.recordState == .recording && f.notifier.posted.count == 1 }
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
        try await waitUntil("recording again") { f.model.recordState == .recording && f.notifier.posted.count == 3 }
        #expect(f.model.recordingProblem == nil)
        f.model.toggleRecording()
        try await waitUntil("idle again") { f.model.recordState == .idle && f.notifier.posted.count == 4 }
        #expect(f.notifier.posted.last?.title == "Run saved — add settings")
    }

    /// The overlay holds the lighter activity (no App Nap, idle sleep allowed) exactly while shown, and quit ends it.
    @Test func overlayHoldsActivityWhileShown() {
        let f = Fixture()
        f.model.launch()
        #expect(f.activities.active.isEmpty)
        f.model.toggleOverlay()
        #expect(f.activities.active == [AppActivity.overlay])
        #expect(!AppActivity.overlay.contains(.idleSystemSleepDisabled))
        f.model.toggleOverlay()
        #expect(f.activities.active.isEmpty)
        f.model.toggleOverlay()
        #expect(f.activities.active.count == 1)
        f.model.quit()
        #expect(f.activities.active.isEmpty)
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

    // MARK: Recording feedback (spec §A)

    /// A second press within 1 s of the accepted one is ignored (no start/stop churn); a press 1.1 s after it is
    /// accepted and stops the run.
    @Test func debounceIgnoresSecondPress() async throws {
        let f = Fixture()
        f.clock.step = 0
        f.model.launch()
        f.model.toggleRecording()
        #expect(f.model.recordState == .starting)
        f.clock.now += 0.5
        f.model.toggleRecording()
        #expect(f.model.recordState == .starting)
        try await waitUntil("recording") { f.model.recordState == .recording }
        f.clock.now += 0.4   // 0.9 s after the accepted press: still ignored
        f.model.toggleRecording()
        #expect(f.model.recordState == .recording)
        f.clock.now += 0.2   // 1.1 s after the accepted press
        f.model.toggleRecording()
        #expect(f.model.recordState == .saving)
        try await waitUntil("idle") { f.model.recordState == .idle }
        #expect(f.sounds.played == [.start, .stop])
        #expect(f.model.recentRuns.count == 1)
    }

    /// A start that fails plays no Tink (the sound means "recording").
    @Test func failedStartPlaysNoSound() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("mpt-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let f = Fixture(dataRoot: blocker)   // runs/ cannot be created under a file
        f.model.launch()
        f.model.toggleRecording()
        try await waitUntil("the refused start") { f.model.recordState == .idle && f.model.recordingProblem != nil }
        #expect(f.model.recordingProblem?.hasPrefix("Could not start recording") == true)
        #expect(f.sounds.played.isEmpty)
    }

    /// `MPT_ALLOW_SECOND_INSTANCE=1` (debug): this instance never changes the launchctl variables — not at launch,
    /// not from Settings, not at quit — so it cannot pull them from under the first instance.
    @Test func secondInstanceNeverTouchesLaunchctl() {
        let f = Fixture(fpsLogging: false, env: ["MPT_ALLOW_SECOND_INSTANCE": "1"])
        for n in both { f.launchctl.env[n] = "1" }   // held by the first instance
        f.model.launch()
        f.model.setFPSLogging(true)
        f.model.setFPSLogging(false)
        f.model.quit()
        #expect(f.launchctl.calls.isEmpty)
        for n in both { #expect(f.launchctl.env[n] == "1") }
        #expect(f.model.fpsLoggingError?.contains("another Metal-PT") == true)
    }

    /// Tink on start, Pop on stop; none when the setting is off; none on a quit-driven stop.
    @Test func soundsFollowTheSettingAndNotQuit() async throws {
        let f = Fixture()
        f.model.launch()
        #expect(f.model.soundOnRecord)   // default on
        f.model.toggleRecording()
        #expect(f.sounds.played.isEmpty)   // Tink once the start has succeeded, not at the press
        try await waitUntil("recording") { f.model.recordState == .recording && f.sounds.played == [.start] }
        f.model.toggleRecording()
        #expect(f.sounds.played == [.start, .stop])   // Pop at the press
        try await waitUntil("idle") { f.model.recordState == .idle }
        #expect(f.sounds.played == [.start, .stop])
        #expect(RecordSound.start.name == "Tink" && RecordSound.stop.name == "Pop")

        f.defaults.set(false, forKey: SettingsKey.soundOnRecord)
        #expect(!f.model.soundOnRecord)
        f.model.toggleRecording()
        try await waitUntil("recording again") { f.model.recordState == .recording }
        f.model.toggleRecording()
        try await waitUntil("idle again") { f.model.recordState == .idle }
        #expect(f.sounds.played.count == 2)

        f.defaults.set(true, forKey: SettingsKey.soundOnRecord)
        f.model.toggleRecording()
        try await waitUntil("recording a third time") {
            f.model.recordState == .recording && f.sounds.played.count == 3
        }
        #expect(f.sounds.played == [.start, .stop, .start])
        f.model.quit()
        #expect(f.sounds.played == [.start, .stop, .start])
    }

    /// The menu-bar label: red "● 02:31 · 35 fps" while recording (FPS only when known), "● starting…",
    /// "saving…", else the followed game's numbers (not red) or the icon.
    @Test func menuBarLabelShowsRecordingState() {
        func status(_ elapsed: Double, fps: Double?) -> SessionStatus {
            SessionStatus(elapsed: elapsed, fps: fps, followedPID: nil, followedApp: nil, stack: nil,
                          sample: TelemetrySample(), sawFPSSource: false)
        }
        let rec = MenuBarLabel.title(state: .recording, status: status(151, fps: 35.2), snapshot: nil)
        #expect(rec == MenuBarLabel.Title(text: "● 02:31 · 35 fps", recording: true))
        let noFPS = MenuBarLabel.title(state: .recording, status: status(151, fps: nil), snapshot: nil)
        #expect(noFPS == MenuBarLabel.Title(text: "● 02:31", recording: true))
        // Recording before the first tick: elapsed 0.
        #expect(MenuBarLabel.title(state: .recording, status: nil, snapshot: nil)?.text == "● 00:00")
        #expect(MenuBarLabel.title(state: .starting, status: nil, snapshot: nil)
                == MenuBarLabel.Title(text: "● starting…", recording: true))
        #expect(MenuBarLabel.title(state: .saving, status: status(151, fps: 35), snapshot: nil)
                == MenuBarLabel.Title(text: "saving…", recording: true))
        #expect(MenuBarLabel.title(state: .idle, status: nil, snapshot: nil) == nil)
        // VoiceOver: the status button's title comes from the image's accessibility description.
        #expect(rec?.spoken == "Recording 02:31 · 35 fps")
        #expect(MenuBarLabel.title(state: .saving, status: nil, snapshot: nil)?.spoken == "Saving the recording…")
        let image = MenuBarLabel.redImage("● 02:31", spoken: "Recording 02:31", scale: 2)
        #expect(image.accessibilityDescription == "Recording 02:31")
        #expect(!image.isTemplate)
        #expect(image.representations.first?.pixelsWide == Int(image.size.width * 2))
        let snap = HubSnapshot(time: 0, sample: TelemetrySample(), fps: 58, followedPID: 1, followedApp: "x",
                               stack: nil)
        #expect(MenuBarLabel.title(state: .idle, status: nil, snapshot: snap)
                == MenuBarLabel.Title(text: "◉ 58 fps", recording: false))
    }

    /// Settings' notification row: the provider's status is published on refresh, with its text.
    @Test func notificationStatusIsRefreshed() async throws {
        let f = Fixture()
        #expect(f.model.notificationStatus == nil)
        f.model.refreshNotificationStatus()
        try await waitUntil("status") { f.model.notificationStatus != nil }
        #expect(f.model.notificationStatus == .denied)
        #expect(NotificationStatus.allowed.text == "Allowed")
        #expect(NotificationStatus.denied.text == "Not allowed — turn on in System Settings")
        #expect(NotificationStatus.notAsked.text == "Not asked yet")
        #expect(NotificationStatus.unavailable.text == "Available in the installed app")
        #expect(NotificationStatus.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.wooloomooloo2.metal-pt")
    }

    /// The not-reporting warning: shown after 10 busy samples of a frontmost app without HUD lines or variables,
    /// cleared when FPS logging goes off; never for Metal-PT itself.
    @Test func frameReportingWarningFollowsTheHub() async throws {
        final class Front { var value: (pid: Int32, name: String?)? = (pid: 31337, name: "Cyberpunk2077") }
        let front = Front()
        let check = FrameReportingCheck(environment: { _ in ["HOME": "/"] },
                                        launcher: { _ in (name: "Steam", pid: 500) })
        let f = Fixture(fpsLogging: true, frontmost: { front.value }, frameCheck: check)
        f.model.launch()
        let samples = f.hub.acquire(.samples)
        var seq: UInt64 = 0
        func push(_ n: Int) {
            for _ in 0..<n {
                seq += 1
                var s = TelemetrySample()
                s.gpuBusyPct = 97
                f.hub.applyForTesting(HubEngine.Update(
                    snapshot: HubSnapshot(time: Double(seq), sample: s, fps: nil, followedPID: nil, followedApp: nil,
                                          stack: nil),
                    addToHistory: true, seq: seq))
            }
        }
        push(9)
        try await Task.sleep(for: .milliseconds(50))   // the checks run on the main queue after each sample
        #expect(f.model.frameReportingWarning == nil)
        push(1)
        try await waitUntil("the warning") { f.model.frameReportingWarning != nil }
        #expect(f.model.frameReportingWarning
                == "Cyberpunk2077 started before FPS logging was on — quit it and Steam and open them again.")
        f.model.setFPSLogging(false)
        #expect(f.model.frameReportingWarning == nil)
        f.model.setFPSLogging(true)
        front.value = (pid: getpid(), name: "Metal-PT")
        push(20)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.model.frameReportingWarning == nil)
        samples.release()
        f.model.quit()
    }
}

@Suite struct SingleInstanceTests {
    private typealias R = SingleInstance.Running

    @Test func handsOffToAnotherInstance() {
        let me = R(pid: 10, bundleID: nil, executablePath: "/x/.build/debug/MetalPT")
        let installed = R(pid: 20, bundleID: SingleInstance.bundleID,
                          executablePath: "/Applications/Metal-PT.app/Contents/MacOS/Metal-PT")
        let devRun = R(pid: 30, bundleID: nil, executablePath: "/y/.build/release/MetalPT")
        let other = R(pid: 40, bundleID: "com.example.other", executablePath: "/Applications/Other.app/Contents/MacOS/Other")
        let lookalike = R(pid: 50, bundleID: nil, executablePath: "/bin/NotMetalPT")
        // Alone (only itself and unrelated apps): run normally.
        #expect(SingleInstance.decide(selfPID: 10, running: [me, other, lookalike], allowSecond: false) == .run)
        #expect(SingleInstance.decide(selfPID: 10, running: [me, installed], allowSecond: false) == .handOff(to: 20))
        #expect(SingleInstance.decide(selfPID: 10, running: [me, devRun], allowSecond: false) == .handOff(to: 30))
        // A bundled copy whose executable was renamed is still found by bundle id.
        let renamed = R(pid: 60, bundleID: SingleInstance.bundleID, executablePath: "/tmp/x")
        #expect(SingleInstance.decide(selfPID: 10, running: [renamed], allowSecond: false) == .handOff(to: 60))
        // The debug override: runs, but without launchctl changes (also when alone).
        #expect(SingleInstance.decide(selfPID: 10, running: [me, installed], allowSecond: true) == .runWithoutLaunchctl)
        #expect(SingleInstance.decide(selfPID: 10, running: [me], allowSecond: true) == .runWithoutLaunchctl)
    }

    /// The running instance is told to reopen (LaunchServices' reopen event, which shows its window) when it is a
    /// bundled app; an unbundled one can only be activated.
    @Test func handOffReopensABundledInstance() {
        let app = URL(fileURLWithPath: "/Applications/Metal-PT.app")
        let bundled = R(pid: 20, bundleID: SingleInstance.bundleID,
                        executablePath: "/Applications/Metal-PT.app/Contents/MacOS/Metal-PT", bundleURL: app)
        let dev = R(pid: 30, bundleID: nil, executablePath: "/y/.build/debug/MetalPT")
        #expect(SingleInstance.handOff(to: bundled) == .reopen(app))
        #expect(SingleInstance.handOff(to: dev) == .activate(30))
    }

    @Test func overrideIsDebugOnlyEnv() {
        #if DEBUG
        #expect(SingleInstance.allowSecond(env: ["MPT_ALLOW_SECOND_INSTANCE": "1"]))
        #endif
        #expect(!SingleInstance.allowSecond(env: [:]))
        #expect(!SingleInstance.allowSecond(env: ["MPT_ALLOW_SECOND_INSTANCE": "0"]))
    }
}

@MainActor
@Suite struct LaunchAndWindowTests {
    private func oapp(prop: UInt32?) -> NSAppleEventDescriptor {
        let e = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                       targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                       transactionID: AETransactionID(kAnyTransactionID))
        if let prop { e.setParam(NSAppleEventDescriptor(enumCode: prop), forKeyword: AEKeyword(keyAEPropData)) }
        return e
    }

    @Test func loginItemLaunchIsDetectedFromTheOpenEvent() {
        #expect(LaunchKind.isLoginItemLaunch(oapp(prop: keyAELaunchedAsLogInItem)))
        #expect(!LaunchKind.isLoginItemLaunch(oapp(prop: nil)))
        #expect(!LaunchKind.isLoginItemLaunch(oapp(prop: keyAELaunchedAsServiceItem)))
        #expect(!LaunchKind.isLoginItemLaunch(nil))
        #expect(LaunchKind.describe(oapp(prop: keyAELaunchedAsLogInItem)) == "event aevt/oapp prop lgit")
    }

    /// Opening the running app again (Finder, Dock, Spotlight): its window is shown unless it is already visible.
    @Test func reopenShowsTheMainWindowUnlessVisible() {
        let model = AppModel(hub: TelemetryHub(dependencies: .inert), fpsLogging: FPSLogging(), live: false)
        var opened = 0
        model.openMainWindow = { opened += 1 }
        #expect(model.handleReopen())
        #expect(opened == 1)
        model.windowState.update(windowVisible: true, onScreen: true)
        #expect(model.handleReopen())
        #expect(opened == 1)
        model.windowState.update(windowVisible: false, onScreen: false, miniaturized: true)
        #expect(model.handleReopen())
        #expect(opened == 2)
    }

    /// A notification click before the window ever appeared: the open is kept until the scene can open windows.
    @Test func openRunBeforeTheWindowExistsOpensItOnceAvailable() {
        let model = AppModel(hub: TelemetryHub(dependencies: .inert), fpsLogging: FPSLogging(), live: false)
        let url = URL(fileURLWithPath: "/tmp/x.mptrun")
        model.openRun(url)
        #expect(model.page == .runs && model.selectedRun == url)
        var opened = 0
        model.openMainWindow = { opened += 1 }
        #expect(opened == 1)
        model.openMainWindow = { opened += 1 }   // re-registered (window appeared): no second open
        #expect(opened == 1)
        model.showMainWindow()
        #expect(opened == 2)
    }
}
