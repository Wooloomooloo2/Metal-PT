import AppKit
import Combine
import Foundation
import MPTApp
import MPTCore

/// `UserDefaults` keys (Settings, T14, binds the same keys with `@AppStorage`).
enum SettingsKey {
    /// Bool, default false: FPS logging (the Metal HUD variables) on.
    static let fpsLogging = "fpsLogging"
    /// String: the data folder chosen in Settings (unset = `~/Documents/Metal-PT`).
    static let dataFolder = "dataFolder"
    /// String, `HotkeyCombo.display` form ("⌃⇧F6").
    static let hotkeyRecord = "hotkeyRecord"
    static let hotkeyOverlay = "hotkeyOverlay"
}

/// The app's state and its wiring to `MPTApp`: the telemetry hub, the FPS-logging lease, hotkeys, recording control.
/// `live == false` (snapshots) never touches launchctl, hotkeys or `NSApp`.
@MainActor
final class AppModel: ObservableObject {
    static let appVersion = "0.2.0-dev"

    enum RecordState: Equatable {
        case idle
        /// Started, no tick yet.
        case starting
        case recording
        /// Stopped; the run is being finished (summary, rename).
        case saving
    }

    let hub: TelemetryHub
    let fpsLogging: FPSLogging
    /// The main window's open/visible state, from its own notifications (`WindowObserver`).
    let windowState = MainWindowState()
    let live: Bool
    private let defaults: UserDefaults
    private let env: [String: String]

    /// Placeholder until the overlay arrives (T10).
    @Published var overlayOn = false
    @Published private(set) var recordState: RecordState = .idle
    /// Hotkeys that could not be registered (shown as warnings).
    @Published private(set) var hotkeyProblems: [String] = []
    /// `FPSLogging.lastError`, copied after each lease operation.
    @Published private(set) var fpsLoggingError: String?
    @Published private(set) var fpsLoggingOn = false
    /// The last refused or failed recording start.
    @Published private(set) var recordingProblem: String?
    /// Placeholder until the Runs index (T11): display names of runs finished in this session, newest first.
    @Published private(set) var recentRuns: [String] = []

    private var hudToken: TelemetryHub.Token?
    private var hotkeys: GlobalHotkeys?
    private var cancellables: Set<AnyCancellable> = []
    private var quitDone = false

    init(hub: TelemetryHub, fpsLogging: FPSLogging, live: Bool, defaults: UserDefaults = .standard,
         env: [String: String] = ProcessInfo.processInfo.environment) {
        self.hub = hub
        self.fpsLogging = fpsLogging
        self.live = live
        self.defaults = defaults
        self.env = env
        hub.objectWillChange
            .sink { [weak self] _ in
                // After the change lands (objectWillChange fires before it).
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.hubChanged() } }
            }
            .store(in: &cancellables)
        windowState.$isOpen
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] open in
                if open { self?.mainWindowOpened() } else { self?.mainWindowClosed() }
            }
            .store(in: &cancellables)
        windowState.$isVisible
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] visible in
                guard self?.live == true else { return }
                FileHandle.standardError.write(Data("Metal-PT: main window \(visible ? "visible" : "hidden")\n".utf8))
            }
            .store(in: &cancellables)
    }

    // MARK: - Settings

    var recordCombo: HotkeyCombo {
        defaults.string(forKey: SettingsKey.hotkeyRecord).flatMap(HotkeyCombo.init(display:)) ?? .record
    }

    var overlayCombo: HotkeyCombo {
        defaults.string(forKey: SettingsKey.hotkeyOverlay).flatMap(HotkeyCombo.init(display:)) ?? .overlay
    }

    /// `runs`, `projects` or `exports` under the data root (R1: `$MPT_DATA_ROOT` ?? Settings ?? default).
    func folder(_ name: String) -> URL {
        AppFolders.url(name, setting: defaults.string(forKey: SettingsKey.dataFolder), env: env)
    }

    // MARK: - Lifecycle

    /// At launch: reconcile the FPS-logging lease with the saved setting, hold the log stream while it is on,
    /// register hotkeys, and let the menu bar sample while a game is followed.
    func launch() {
        guard live else { return }
        hub.onSamplingChange = { on in
            FileHandle.standardError.write(Data("Metal-PT: sampler \(on ? "on" : "off")\n".utf8))
        }
        fpsLogging.reconcileAtLaunch(enabled: defaults.bool(forKey: SettingsKey.fpsLogging))
        syncFPSLogging()
        hub.menuBarWantsSamplesWhenFollowing = true
        registerHotkeys()
    }

    /// At quit: finish a running recording, stop the log stream, hand the HUD variables back. Once only.
    func quit() {
        guard !quitDone else { return }
        quitDone = true
        let run = hub.stopRecordingNow()
        hudToken?.release()
        hudToken = nil
        hub.menuBarWantsSamplesWhenFollowing = false
        hotkeys = nil
        if live { fpsLogging.releaseAtQuit() }
        let saved = run.map { " (saved \($0.directory.lastPathComponent))" } ?? ""
        FileHandle.standardError.write(Data(
            "Metal-PT: quit: recording stopped\(saved), FPS logging released (on: \(fpsLogging.isOn))\n".utf8))
    }

    /// Turns FPS logging on or off and saves the setting (Settings, T14, calls this).
    func setFPSLogging(_ on: Bool) {
        defaults.set(on, forKey: SettingsKey.fpsLogging)
        guard live else { return }
        try? fpsLogging.setEnabled(on)   // the error is kept in `lastError`
        syncFPSLogging()
    }

    func registerHotkeys() {
        guard live else { return }
        let keys = hotkeys ?? GlobalHotkeys()
        hotkeys = keys
        var problems: [String] = []
        if let p = keys.register(recordCombo, for: .record, handler: { [weak self] in self?.toggleRecording() }) {
            problems.append("Record hotkey: \(p)")
        }
        if let p = keys.register(overlayCombo, for: .overlay, handler: { [weak self] in self?.toggleOverlay() }) {
            problems.append("Overlay hotkey: \(p)")
        }
        hotkeyProblems = problems
        for p in problems { FileHandle.standardError.write(Data("Metal-PT: \(p)\n".utf8)) }
    }

    // MARK: - Window and Dock icon

    /// Dock icon only while the main window is open (driven by `windowState.isOpen`).
    func mainWindowOpened() {
        guard live else { return }
        NSApp.setActivationPolicy(.regular)
    }

    func mainWindowClosed() {
        guard live else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Actions

    func toggleOverlay() { overlayOn.toggle() }

    func toggleRecording() {
        if hub.isRecording {
            recordState = .saving
            Task {
                await hub.stopRecording()   // sets `hub.lastRun`, picked up by `hubChanged`
                hubChanged()
            }
        } else {
            guard !hub.isFinishingRecording else {
                recordingProblem = "\(TelemetryHub.RecordingError.stillFinishing)"
                return
            }
            recordingProblem = nil
            recordState = .starting
            let options = RecordingSession.Options(runsRoot: folder("runs"), appVersion: Self.appVersion)
            Task {
                do {
                    try await hub.startRecording(options: options)
                } catch TelemetryHub.RecordingError.stoppedWhileStarting {
                    // Quit (or a stop) won the race: nothing to report.
                } catch {
                    recordingProblem = "Could not start recording: \(error)"
                }
                hubChanged()
            }
        }
    }

    // MARK: - Private

    private func syncFPSLogging() {
        fpsLoggingOn = fpsLogging.isOn
        fpsLoggingError = fpsLogging.lastError.map { "\($0)" }
        if fpsLogging.isOn, hudToken == nil {
            hudToken = hub.acquire(.hud)
        } else if !fpsLogging.isOn, let t = hudToken {
            hudToken = nil
            t.release()
        }
    }

    private func noteRun(_ run: RunResult) {
        let name = run.directory.deletingPathExtension().lastPathComponent
        recentRuns.removeAll { $0 == name }
        recentRuns.insert(name, at: 0)
        if recentRuns.count > 5 { recentRuns.removeLast(recentRuns.count - 5) }
    }

    private var lastSeenRun: RunResult?

    private func hubChanged() {
        guard live else { return }   // snapshots set their state directly
        if let run = hub.lastRun, run != lastSeenRun {
            lastSeenRun = run
            noteRun(run)
        }
        let state: RecordState
        if hub.isFinishingRecording {
            state = .saving
        } else if hub.isRecording {
            state = hub.recording == nil ? .starting : .recording
        } else {
            state = .idle
        }
        if state != recordState { recordState = state }
    }

    /// Snapshots only: fixed values for the published state.
    func showFixture(recordState: RecordState, fpsLoggingOn: Bool, recentRuns: [String],
                     problems: [String] = []) {
        self.recordState = recordState
        self.fpsLoggingOn = fpsLoggingOn
        self.recentRuns = recentRuns
        self.hotkeyProblems = problems
    }
}
