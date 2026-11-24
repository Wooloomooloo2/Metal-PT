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
    /// String `OverlayStyle`: "auto" (default; compact, detailed while recording), "compact", "detailed".
    static let overlayStyle = "overlayStyle"
    /// String `OverlayCorner`: "topLeft" (default), "topRight", "bottomLeft", "bottomRight".
    static let overlayCorner = "overlayCorner"
    /// Double, default 0.85.
    static let overlayOpacity = "overlayOpacity"
}

/// The app's state and its wiring to `MPTApp`: the telemetry hub, the FPS-logging lease, hotkeys, recording control.
/// `live == false` (snapshots) never touches launchctl, hotkeys or `NSApp`. `usesAppKit == false` (unit tests) keeps
/// the live recording and lease logic but never touches hotkeys, `NSApp` or windows.
@MainActor
final class AppModel: ObservableObject {
    static let appVersion = "0.2.0-dev"
    /// Dev/test only, honoured when `MPT_DEBUG=1`: a distributed notification with this name toggles recording
    /// (the Carbon hotkey cannot be pressed from a script).
    static let debugToggleRecording = "io.github.wooloomooloo2.metal-pt.debug.toggleRecording"
    /// Dev/test only, as `debugToggleRecording`: toggles the overlay and logs the panel's state.
    static let debugToggleOverlay = "io.github.wooloomooloo2.metal-pt.debug.toggleOverlay"
    /// Dev/test only, as `debugToggleRecording`: sets the notes of the newest run to the notification's object
    /// string (the Runs edit path without the sheet). `MPT_DEBUG_PAGE=runs` opens that page at launch.
    static let debugEditRun = "io.github.wooloomooloo2.metal-pt.debug.editRun"
    /// Dev/test only, as `debugToggleRecording`: sets the baseline of the most recently modified compare project to
    /// the run number in the notification's object string (the Compare edit path without the menu).
    /// `MPT_DEBUG_PAGE=compare` opens that page at launch.
    static let debugCompareBaseline = "io.github.wooloomooloo2.metal-pt.debug.compareBaseline"

    enum RecordState: Equatable {
        case idle
        /// Pressed or started, no tick yet.
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
    let usesAppKit: Bool
    private let defaults: UserDefaults
    private let env: [String: String]
    private let notifier: RecordingNotifying?

    /// The in-game overlay is shown. Not persisted: off at every launch, so it never appears unexpectedly.
    /// While on it holds `.samples`; off, it holds nothing.
    @Published var overlayOn = false {
        didSet { if overlayOn != oldValue { overlayChanged() } }
    }
    /// The sidebar selection (a "Run saved" notification switches it to Runs).
    @Published var page: Page? = .live
    /// The run to show in Runs (set by a "Run saved" notification; the Runs page selects it).
    @Published var selectedRun: URL?
    /// The compare project to show in Compare (set by Runs → "Compare selected…"; the Compare page selects it).
    @Published var selectedProject: URL?
    /// The runs folder's index, for the Runs page.
    let runs = RunsStore()
    /// The compare projects, for the Compare page.
    let projects = ProjectsStore()
    @Published private(set) var recordState: RecordState = .idle
    /// Hotkeys that could not be registered (shown as warnings).
    @Published private(set) var hotkeyProblems: [String] = []
    /// `FPSLogging.lastError` (or an unexpected error), copied after each lease operation.
    @Published private(set) var fpsLoggingError: String?
    @Published private(set) var fpsLoggingOn = false
    /// The last refused or failed recording start; "still being saved" is cleared once the save completes.
    @Published private(set) var recordingProblem: String?
    /// Placeholder until the Runs index (T11): display names of runs finished in this session, newest first.
    @Published private(set) var recentRuns: [String] = []
    /// Opens (or brings forward) the main window; set by the SwiftUI scene (it owns `openWindow`).
    var openMainWindow: (() -> Void)?

    private var hudToken: TelemetryHub.Token?
    private var hotkeys: GlobalHotkeys?
    private var cancellables: Set<AnyCancellable> = []
    private var debugObservers: [NSObjectProtocol] = []
    private let overlayLease = HubLease()
    private var overlay: OverlayController?
    private var quitDone = false
    /// The press-to-start task, from the press until the hub has started (or refused) the recording. While it is
    /// set the state is `.starting` even though the hub does not know about the recording yet.
    private var startTask: Task<Void, Never>?
    /// From a stop press until the run is saved: the state stays `.saving`.
    private var stopping = false
    private var lastSeenRun: RunResult?
    private var lastIndexedRun: RunResult?

    init(hub: TelemetryHub, fpsLogging: FPSLogging, live: Bool, usesAppKit: Bool? = nil,
         defaults: UserDefaults = .standard, env: [String: String] = ProcessInfo.processInfo.environment,
         notifier: RecordingNotifying? = nil) {
        self.hub = hub
        self.fpsLogging = fpsLogging
        self.live = live
        self.usesAppKit = usesAppKit ?? live
        self.defaults = defaults
        self.env = env
        self.notifier = notifier ?? (live && (usesAppKit ?? live) ? Notifications() : nil)
        self.notifier?.onOpenRun = { [weak self] url in self?.openRun(url) }
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
                guard self?.usesAppKit == true else { return }
                Self.log("main window \(visible ? "visible" : "hidden")")
            }
            .store(in: &cancellables)
    }

    /// `MPT_DEBUG=1`: extra logging (and the debug notifications).
    var debugLogging: Bool { env["MPT_DEBUG"] == "1" }

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
        hub.onSamplingChange = { on in Self.log("sampler \(on ? "on" : "off")") }
        fpsLogging.reconcileAtLaunch(enabled: defaults.bool(forKey: SettingsKey.fpsLogging))
        syncFPSLogging()
        hub.menuBarWantsSamplesWhenFollowing = true
        registerHotkeys()
        if usesAppKit, env["MPT_DEBUG"] == "1" {
            let center = DistributedNotificationCenter.default()
            debugObservers.append(center.addObserver(
                forName: Notification.Name(Self.debugToggleRecording), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        Self.log("debug: toggle recording")
                        self?.toggleRecording()
                    }
                })
            debugObservers.append(center.addObserver(
                forName: Notification.Name(Self.debugToggleOverlay), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        Self.log("debug: toggle overlay")
                        self?.toggleOverlay()
                    }
                })
            debugObservers.append(center.addObserver(
                forName: Notification.Name(Self.debugEditRun), object: nil, queue: .main) { [weak self] note in
                    let notes = note.object as? String ?? "debug edit"
                    MainActor.assumeIsolated { self?.debugEditNewestRun(notes: notes) }
                })
            debugObservers.append(center.addObserver(
                forName: Notification.Name(Self.debugCompareBaseline), object: nil, queue: .main) { [weak self] note in
                    let number = (note.object as? String).flatMap { Int($0) } ?? 1
                    MainActor.assumeIsolated { self?.debugSetBaseline(number: number) }
                })
            if let p = env["MPT_DEBUG_PAGE"].flatMap(Page.init(rawValue:)) { page = p }
            Self.log("debug: listening for \(Self.debugToggleRecording), \(Self.debugToggleOverlay), "
                     + "\(Self.debugEditRun), \(Self.debugCompareBaseline)")
        }
    }

    /// At quit, once: hand the HUD variables back first (quick, and must happen even if the stop below hangs),
    /// then finish a running recording (blocking), and only then release the log stream the recording reads.
    func quit() {
        guard !quitDone else { return }
        quitDone = true
        hotkeys = nil
        for o in debugObservers { DistributedNotificationCenter.default().removeObserver(o) }
        debugObservers.removeAll()
        overlayOn = false
        if live { fpsLogging.releaseAtQuit() }
        let wasRecording = hub.isRecording || hub.isFinishingRecording || startTask != nil
        let run = hub.stopRecordingNow()
        hudToken?.release()
        hudToken = nil
        hub.menuBarWantsSamplesWhenFollowing = false
        var line = "quit: "
        if wasRecording {
            line += "recording stopped" + (run.map { " (saved \($0.directory.lastPathComponent))" } ?? " (no run saved)")
                + ", "
        }
        line += "FPS logging released (on: \(fpsLogging.isOn))"
        if live { Self.log(line) }
    }

    /// Turns FPS logging on or off. The preference is saved first, whatever happens next: it is the user's choice,
    /// and the next launch reconciles to it (adopt or retry). Failures are shown via `fpsLoggingError`.
    func setFPSLogging(_ on: Bool) {
        defaults.set(on, forKey: SettingsKey.fpsLogging)
        guard live else { return }
        var unexpected: Error?
        do {
            try fpsLogging.setEnabled(on)
        } catch is FPSLoggingError {
            // Kept in `fpsLogging.lastError`, copied by `syncFPSLogging`.
        } catch {
            unexpected = error
        }
        syncFPSLogging()
        if let unexpected {
            fpsLoggingError = "Could not turn FPS logging \(on ? "on" : "off"): \(unexpected.localizedDescription)"
            Self.log(fpsLoggingError ?? "")
        }
    }

    func registerHotkeys() {
        guard live, usesAppKit else { return }
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
        for p in problems { Self.log(p) }
    }

    // MARK: - Window and Dock icon

    /// Dock icon only while the main window is open (driven by `windowState.isOpen`).
    func mainWindowOpened() {
        guard usesAppKit else { return }
        NSApp.setActivationPolicy(.regular)
    }

    func mainWindowClosed() {
        guard usesAppKit else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// A "Run saved" notification was clicked: bring the window forward on Runs with that run selected.
    func openRun(_ url: URL) {
        selectedRun = url
        page = .runs
        guard usesAppKit else { return }
        openMainWindow?()
        NSApp.activate()
    }

    // MARK: - Actions

    /// Runs → "Compare selected…": saves a new compare project of `entries` and shows it in Compare.
    func compare(_ entries: [RunEntry]) throws {
        let url = try CompareProjects.create(from: entries, projectsRoot: folder("projects"))
        selectedProject = url
        page = .compare
    }

    /// Hotkey / menu row.
    func toggleOverlay() {
        guard !quitDone else { return }
        overlayOn.toggle()
    }

    /// Hotkey / menu / Live button. Starting (pressed, not yet started) counts as recording: a quick second press
    /// stops the run once it has started, instead of being refused as "already running".
    func toggleRecording() {
        guard !quitDone else { return }
        if stopping || hub.isFinishingRecording {
            recordingProblem = "\(TelemetryHub.RecordingError.stillFinishing)"
        } else if startTask != nil || hub.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    // MARK: - Private

    private func startRecording() {
        recordingProblem = nil
        recordState = .starting
        notifier?.requestAuthorizationIfNeeded()
        let options = RecordingSession.Options(runsRoot: folder("runs"), appVersion: Self.appVersion)
        let hub = hub
        startTask = Task { [weak self] in
            // Quit ran before this task did: the hub never saw the start, so there is nothing to stop.
            guard self?.quitDone == false else { return }
            var started = false
            do {
                try await hub.startRecording(options: options)
                started = true
            } catch TelemetryHub.RecordingError.stoppedWhileStarting {
                // Quit won the race: nothing to report.
            } catch {
                self?.recordingProblem = "Could not start recording: \(error)"
            }
            guard let self else { return }
            self.startTask = nil
            if started, !self.stopping, !self.quitDone { self.postStarted() }
            self.hubChanged()
        }
    }

    private func stopRecording() {
        stopping = true
        recordState = .saving
        let pending = startTask
        let hub = hub
        Task { [weak self] in
            // A press during `.starting`: let the start reach the hub first, then stop it.
            await pending?.value
            await hub.stopRecording()   // sets `hub.lastRun`, picked up by `hubChanged`
            guard let self else { return }
            self.stopping = false
            self.hubChanged()
        }
    }

    /// Holds `.samples` exactly while the overlay is on (live models only) and shows or hides the panel (AppKit).
    private func overlayChanged() {
        guard live else { return }   // snapshots set `overlayOn` for the menu row only
        overlayLease.set(overlayOn, .samples, on: hub)
        guard usesAppKit else { return }
        if overlayOn {
            let controller = overlay ?? OverlayController(model: self, defaults: defaults)
            if overlay == nil, env["MPT_DEBUG"] == "1" {
                controller.onDebugEvent = { Self.log("debug: \($0)") }
            }
            overlay = controller
            controller.show()
        } else {
            overlay?.hide()
        }
        Self.log("overlay \(overlayOn ? "on" : "off"); \(overlay?.describe() ?? "no panel")")
        if overlayOn, env["MPT_DEBUG"] == "1" {
            // Once laid out and ordered in: the state a user would see.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.overlayOn else { return }
                    Self.log("debug: \(self.overlay?.describe() ?? "no panel")")
                }
            }
        }
    }

    private func debugEditNewestRun(notes: String) {
        guard let run = runs.entries.first else { Self.log("debug: no run to edit"); return }
        Task {
            do {
                try await runs.update(run.id, settings: run.settings, notes: notes, label: run.label)
                Self.log("debug: edited \(run.id) (notes \(notes.count) chars)")
            } catch {
                Self.log("debug: edit failed: \(error)")
            }
        }
    }

    private func debugSetBaseline(number: Int) {
        guard let project = projects.projects.first else { Self.log("debug: no compare project"); return }
        Task {
            do {
                try await projects.setBaseline(project.id, index: number - 1)
                Self.log("debug: baseline of \(project.id) is run \(number)")
            } catch {
                Self.log("debug: baseline failed: \(error)")
            }
        }
    }

    private func postStarted() {
        let status = hub.recording
        let snap = hub.latest
        let app = status?.followedPID != nil ? status?.followedApp
            : (snap?.followedPID != nil ? snap?.followedApp : nil)
        let stack = status?.followedPID != nil ? status?.stack : snap?.stack
        notifier?.post(.started(app: app, stack: stack))
    }

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

    private func hubChanged() {
        guard live else { return }   // snapshots set their state directly
        if let run = hub.lastRun, run != lastSeenRun {
            lastSeenRun = run
            noteRun(run)
            if !quitDone { notifier?.post(.saved(run)) }
        }
        // The recording's folder is locked in Runs while it is written; rescan when it appears or is finished.
        let recordingDir = hub.recordingDirectory
        if recordingDir != runs.recordingDirectory || hub.lastRun != lastIndexedRun {
            runs.recordingDirectory = recordingDir
            lastIndexedRun = hub.lastRun
            runs.refresh(root: folder("runs"))
        }
        let state: RecordState
        if stopping || hub.isFinishingRecording {
            state = .saving
        } else if hub.isRecording {
            state = hub.recording == nil ? .starting : .recording
        } else if startTask != nil {
            state = .starting   // pressed; the hub has not seen the start yet
        } else {
            state = .idle
        }
        if state != recordState {
            // The save completed: a "still being saved" refusal no longer applies (a failed start's reason stays).
            if recordState == .saving, state == .idle,
               recordingProblem == "\(TelemetryHub.RecordingError.stillFinishing)" {
                recordingProblem = nil
            }
            recordState = state
        }
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data("Metal-PT: \(text)\n".utf8))
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
