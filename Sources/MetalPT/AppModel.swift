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
    /// Double 0…1, default 0.6: the overlay background's alpha ("Background opacity").
    static let overlayOpacity = "overlayOpacity"
    /// Bool, default true: a short sound when recording starts and stops.
    static let soundOnRecord = "soundOnRecord"
    /// Bool, default false: the "Run saved" notification offers "Publish…" (opens the run's Submit sheet).
    static let offerPublish = "offerPublish"
    /// The overlay's own keys: the panel re-lays itself out only when one of these changes.
    static let overlayKeys = [overlayStyle, overlayCorner, overlayOpacity]
}

/// The app's state and its wiring to `MPTApp`: the telemetry hub, the FPS-logging lease, hotkeys, recording control.
/// `live == false` (snapshots) never touches launchctl, hotkeys or `NSApp`. `usesAppKit == false` (unit tests) keeps
/// the live recording and lease logic but never touches hotkeys, `NSApp` or windows.
@MainActor
final class AppModel: ObservableObject {
    static let appVersion = MetalPTVersion.current
    #if DEBUG
    // Debug builds only (compiled out of release builds), and only with `MPT_DEBUG=1`.
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
    /// Dev/test only, as `debugToggleRecording`: turns FPS logging on (object "1") or off (anything else) through
    /// the same path as the Settings toggle. `MPT_DEBUG_PAGE=settings` opens Settings at launch.
    static let debugSetFPSLogging = "io.github.wooloomooloo2.metal-pt.debug.setFPSLogging"
    #endif

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
    /// Settings' store (`.standard` in the app; a suite in tests and snapshots).
    let defaults: UserDefaults
    private let env: [String: String]
    private let notifier: RecordingNotifying?
    private let sounds: SoundPlaying?
    /// Seconds on a monotonic clock (the debounce).
    private let clock: @MainActor () -> Double
    private let notificationStatusProvider: NotificationStatusProviding
    /// A record toggle within this many seconds of the previous accepted one is ignored (an accidental double press
    /// must not cancel a start).
    static let toggleDebounce = 1.0
    /// When the last record toggle was accepted (`clock`).
    private var lastAcceptedToggle: Double?

    /// The in-game overlay is shown. Not persisted: off at every launch, so it never appears unexpectedly.
    /// While on it holds `.samples`; off, it holds nothing.
    @Published var overlayOn = false {
        didSet { if overlayOn != oldValue { overlayChanged() } }
    }
    /// The sidebar selection (a "Run saved" notification switches it to Runs).
    @Published var page: Page? = .live
    /// The run to show in Runs (set by a "Run saved" notification; the Runs page selects it).
    @Published var selectedRun: URL?
    /// The run whose Submit sheet to open (a "Run saved" notification's "Publish…"; the Runs page opens it).
    @Published var submitRun: URL?
    /// The compare project to show in Compare (set by Runs → "Compare selected…"; the Compare page selects it).
    @Published var selectedProject: URL?
    /// The runs folder's index, for the Runs page.
    let runs = RunsStore()
    /// The compare projects, for the Compare page.
    let projects = ProjectsStore()
    @Published private(set) var recordState: RecordState = .idle
    /// Why each hotkey could not be registered (shown inline in Settings and as warnings elsewhere).
    @Published private(set) var hotkeyRegistration: [GlobalHotkeys.Action: String] = [:]
    /// `hotkeyRegistration` as warning lines.
    var hotkeyProblems: [String] {
        GlobalHotkeys.Action.allCases.compactMap { a in hotkeyRegistration[a].map { "\(a.title) hotkey: \($0)" } }
    }
    /// `FPSLogging.lastError` (or an unexpected error), copied after each lease operation.
    @Published private(set) var fpsLoggingError: String?
    @Published private(set) var fpsLoggingOn = false
    /// The last refused or failed recording start, or the last warning/error of the recording (cleared at the next
    /// start); "still being saved" is cleared once the save completes.
    @Published private(set) var recordingProblem: String?
    /// Display names of runs finished in this session, newest first (the menu bar's recent runs).
    @Published private(set) var recentRuns: [String] = []
    /// "<App> started before FPS logging was on — …" (`FrameReportingCheck`); shown in Live and the menu, never
    /// written to run bundles.
    @Published private(set) var frameReportingWarning: String?
    /// Settings' notification permission row; nil until first refreshed.
    @Published private(set) var notificationStatus: NotificationStatus?
    /// Opens (or brings forward) the main window; set by the SwiftUI scene (it owns `openWindow`): by the menu-bar
    /// label at launch (`OpenWindowRegistrar`) and by the main window when it appears. A `showMainWindow` that came
    /// before it was set runs once it is.
    var openMainWindow: (() -> Void)? {
        didSet {
            guard pendingWindowOpen, let open = openMainWindow else { return }
            pendingWindowOpen = false
            open()
        }
    }
    private var pendingWindowOpen = false

    private var hudToken: TelemetryHub.Token?
    private var hotkeys: GlobalHotkeys?
    private var cancellables: Set<AnyCancellable> = []
    private var debugObservers: [NSObjectProtocol] = []
    private let overlayLease = HubLease()
    /// `AppActivity.overlay` while the overlay is shown (the panel's numbers must not be App-Napped).
    private var overlayActivity: ActivityToken?
    private var overlay: OverlayController?
    private var quitDone = false
    /// The press-to-start task, from the press until the hub has started (or refused) the recording. While it is
    /// set the state is `.starting` even though the hub does not know about the recording yet.
    private var startTask: Task<Void, Never>?
    /// From a stop press until the run is saved: the state stays `.saving`.
    private var stopping = false
    private var lastSeenRun: RunResult?
    /// An error message arrived during the current (or last) recording: its "Run saved" says "with problems".
    private var runHadErrors = false
    private var lastIndexedRun: RunResult?
    /// The frontmost app (`NSWorkspace`, main thread); read only while FPS logging is on and the hub samples.
    private let frontmost: @MainActor () -> (pid: Int32, name: String?)?
    private var frameCheck: FrameReportingCheck
    /// The hub sample time the check last ran for (one check per sample).
    private var lastFrameCheckTime: Double?

    init(hub: TelemetryHub, fpsLogging: FPSLogging, live: Bool, usesAppKit: Bool? = nil,
         defaults: UserDefaults = .standard, env: [String: String] = ProcessInfo.processInfo.environment,
         notifier: RecordingNotifying? = nil, sounds: SoundPlaying? = nil,
         clock: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
         notificationStatus: NotificationStatusProviding? = nil,
         frontmost: (@MainActor () -> (pid: Int32, name: String?)?)? = nil,
         frameCheck: FrameReportingCheck? = nil) {
        self.hub = hub
        self.fpsLogging = fpsLogging
        self.live = live
        self.usesAppKit = usesAppKit ?? live
        self.defaults = defaults
        self.env = env
        self.notifier = notifier ?? (live && (usesAppKit ?? live) ? Notifications() : nil)
        self.sounds = sounds ?? (live && (usesAppKit ?? live) ? SystemSounds() : nil)
        self.clock = clock
        self.notificationStatusProvider = notificationStatus ?? SystemNotificationStatus()
        if let frontmost {
            self.frontmost = frontmost
        } else if usesAppKit ?? live {
            self.frontmost = {
                NSWorkspace.shared.frontmostApplication.map { (pid: $0.processIdentifier, name: $0.localizedName) }
            }
        } else {
            self.frontmost = { nil }
        }
        self.frameCheck = frameCheck ?? FrameReportingCheck()
        self.notifier?.onOpenRun = { [weak self] url in self?.openRun(url) }
        self.notifier?.onPublishRun = { [weak self] url in self?.openSubmit(url) }
        if live && (usesAppKit ?? live) {
            runs.makeSiteClient = { [weak self] in
                guard let self else { throw SiteError(message: "Publishing is not available here.") }
                return try self.siteClient()
            }
        }
        hub.objectWillChange
            .sink { [weak self] _ in
                // After the change lands (objectWillChange fires before it).
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.hubChanged() } }
            }
            .store(in: &cancellables)
        if live {
            // Each sampled snapshot (history only grows while the hub samples).
            hub.$history
                .sink { [weak self] history in
                    guard let last = history.last else { return }
                    // `@Published` sends before the value is stored: run after it lands.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.frameCheckTick(last) } }
                }
                .store(in: &cancellables)
        }
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

    /// `MPT_DEBUG=1` in a debug build: extra logging (and the debug notifications). Always false in release builds.
    var debugLogging: Bool {
        #if DEBUG
        env["MPT_DEBUG"] == "1"
        #else
        false
        #endif
    }

    /// Debug only (`MPT_ALLOW_SECOND_INSTANCE=1`, see `SingleInstance`): another instance owns the launchctl
    /// variables, so this one never changes them.
    var launchctlDisabled: Bool { SingleInstance.allowSecond(env: env) }

    // MARK: - Settings

    var recordCombo: HotkeyCombo {
        defaults.string(forKey: SettingsKey.hotkeyRecord).flatMap(HotkeyCombo.init(display:)) ?? .record
    }

    var overlayCombo: HotkeyCombo {
        defaults.string(forKey: SettingsKey.hotkeyOverlay).flatMap(HotkeyCombo.init(display:)) ?? .overlay
    }

    /// Settings → "Play a sound when recording starts and stops" (default on).
    var soundOnRecord: Bool {
        defaults.object(forKey: SettingsKey.soundOnRecord) as? Bool ?? true
    }

    /// Settings → "Offer to publish after each run" (default off).
    var offerPublish: Bool { defaults.bool(forKey: SettingsKey.offerPublish) }

    /// This Mac's publishing key, loaded (or made) on the first publish, remove or link change.
    private var siteKey: SiteKey?

    /// The website client: `MPT_SITE_URL` in debug builds, else `SiteClient.defaultBase`; the key from
    /// `~/Library/Application Support/Metal-PT/site-key` (shared with `mpt publish`).
    func siteClient() throws -> SiteClient {
        let key: SiteKey
        if let siteKey {
            key = siteKey
        } else {
            do {
                key = try SiteKey.loadOrCreate(in: try AppFolders.support())
            } catch {
                throw SiteError(message: "Could not set up this Mac's publishing key: \(error.localizedDescription)")
            }
            siteKey = key
            if key.wasReplaced { runs.noteKeyReplaced() }
        }
        return SiteClient(base: SiteClient.appBase(env: env), signer: key)
    }

    /// Settings' notification row: asks macOS again (on Settings appear and app activation).
    func refreshNotificationStatus() {
        let provider = notificationStatusProvider
        Task { [weak self] in
            let status = await provider.status()
            self?.notificationStatus = status
        }
    }

    func combo(for action: GlobalHotkeys.Action) -> HotkeyCombo {
        action == .record ? recordCombo : overlayCombo
    }

    /// Settings: sets `action`'s hotkey (nil: back to the default), saves it and re-registers at once. Returns why
    /// it was refused (a bare key, the other action's combo, or taken by another app); then the previous combo
    /// stays, saved and registered.
    func setHotkey(_ combo: HotkeyCombo?, for action: GlobalHotkeys.Action) -> String? {
        let other: GlobalHotkeys.Action = action == .record ? .overlay : .record
        let new = combo ?? action.defaultCombo
        if let p = HotkeyCapture.problem(new, other: self.combo(for: other), otherName: other.title) { return p }
        let previous = defaults.string(forKey: action.settingsKey)
        objectWillChange.send()
        if combo == nil {
            defaults.removeObject(forKey: action.settingsKey)
        } else {
            defaults.set(new.display, forKey: action.settingsKey)
        }
        guard live, usesAppKit else { return nil }
        registerHotkeys()
        guard let problem = hotkeyRegistration[action] else { return nil }
        // Taken by another app: keep the combo that was there.
        defaults.set(previous, forKey: action.settingsKey)
        registerHotkeys()
        return "\(problem); kept \(self.combo(for: action).display)"
    }

    /// Settings: while a hotkey field records, the global hotkeys are off (else pressing the current combo would
    /// fire it instead of being recorded). `resumeHotkeys` registers them again.
    func suspendHotkeys() {
        guard live, usesAppKit else { return }
        for a in GlobalHotkeys.Action.allCases { hotkeys?.unregister(a) }
    }

    func resumeHotkeys() { registerHotkeys() }

    /// `runs`, `projects` or `exports` under the data root (R1: `$MPT_DATA_ROOT` ?? Settings ?? default).
    func folder(_ name: String) -> URL {
        AppFolders.url(name, setting: defaults.string(forKey: SettingsKey.dataFolder), env: env)
    }

    /// The data root Settings shows.
    var dataRoot: URL { AppFolders.root(setting: defaults.string(forKey: SettingsKey.dataFolder), env: env) }
    /// `$MPT_DATA_ROOT`, when it overrides the Settings value (Settings then cannot change it).
    var dataFolderEnvRoot: String? { AppFolders.envRoot(env) }
    var dataFolderIsDefault: Bool { defaults.string(forKey: SettingsKey.dataFolder) == nil }

    /// Settings: a new data folder (nil: back to `~/Documents/Metal-PT`). Existing files are not moved. Runs and
    /// Compare switch to the new folders at once. Refused (returns why) while `$MPT_DATA_ROOT` is set, and while a
    /// recording is starting, running or being saved (its run folder is under the current root).
    @discardableResult
    func setDataFolder(_ url: URL?) -> String? {
        if dataFolderEnvRoot != nil { return "The data folder is set by MPT_DATA_ROOT." }
        if recordState != .idle || startTask != nil || stopping {
            return "The data folder can be changed once the recording has been saved."
        }
        objectWillChange.send()
        if let url {
            defaults.set(url.standardizedFileURL.path, forKey: SettingsKey.dataFolder)
        } else {
            defaults.removeObject(forKey: SettingsKey.dataFolder)
        }
        guard live else { return nil }
        runs.refresh(root: folder("runs"))
        projects.refresh(projectsRoot: folder("projects"), runsRoot: folder("runs"))
        return nil
    }

    // MARK: - Lifecycle

    /// At launch: reconcile the FPS-logging lease with the saved setting, hold the log stream while it is on,
    /// register hotkeys, and let the menu bar sample while a game is followed.
    func launch() {
        guard live else { return }
        hub.onSamplingChange = { [weak self] on in
            Self.log("sampler \(on ? "on" : "off")")
            if !on { self?.runFrameCheck(now: nil, gpuBusyPct: nil) }
        }
        hub.onRecordingMessage = { [weak self] m in self?.recordingMessage(m) }
        if launchctlDisabled {
            Self.log("\(SingleInstance.allowSecondKey)=1: second instance; FPS logging (launchctl) is left alone")
        } else {
            fpsLogging.reconcileAtLaunch(enabled: defaults.bool(forKey: SettingsKey.fpsLogging))
        }
        syncFPSLogging()
        hub.menuBarWantsSamplesWhenFollowing = true
        registerHotkeys()
        #if DEBUG
        if usesAppKit, debugLogging {
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
            debugObservers.append(center.addObserver(
                forName: Notification.Name(Self.debugSetFPSLogging), object: nil, queue: .main) { [weak self] note in
                    let on = (note.object as? String) == "1"
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.setFPSLogging(on)
                        Self.log("debug: FPS logging \(on ? "on" : "off") -> isOn \(self.fpsLoggingOn)"
                                 + (self.fpsLoggingError.map { ", error: \($0)" } ?? ""))
                    }
                })
            if let p = env["MPT_DEBUG_PAGE"].flatMap(Page.init(rawValue:)) { page = p }
            Self.log("debug: listening for \(Self.debugToggleRecording), \(Self.debugToggleOverlay), "
                     + "\(Self.debugEditRun), \(Self.debugCompareBaseline), \(Self.debugSetFPSLogging)")
        }
        #endif
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
        if live, !launchctlDisabled { fpsLogging.releaseAtQuit() }
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
        line += launchctlDisabled ? "FPS logging left alone (second instance)"
            : "FPS logging released (on: \(fpsLogging.isOn))"
        if live { Self.log(line) }
    }

    /// Turns FPS logging on or off. The preference is saved first, whatever happens next: it is the user's choice,
    /// and the next launch reconciles to it (adopt or retry). Failures are shown via `fpsLoggingError`.
    func setFPSLogging(_ on: Bool) {
        if launchctlDisabled {
            fpsLoggingError = "FPS logging is left to another Metal-PT (\(SingleInstance.allowSecondKey)=1)."
            Self.log(fpsLoggingError ?? "")
            return
        }
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

    /// Settings' "Try again": the saved choice once more.
    func retryFPSLogging() {
        setFPSLogging(defaults.bool(forKey: SettingsKey.fpsLogging))
    }

    func registerHotkeys() {
        guard live, usesAppKit, !quitDone else { return }
        let keys = hotkeys ?? GlobalHotkeys()
        hotkeys = keys
        var problems: [GlobalHotkeys.Action: String] = [:]
        problems[.record] = keys.register(recordCombo, for: .record) { [weak self] in self?.toggleRecording() }
        problems[.overlay] = keys.register(overlayCombo, for: .overlay) { [weak self] in self?.toggleOverlay() }
        hotkeyRegistration = problems
        for p in hotkeyProblems { Self.log(p) }
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

    /// Opens the main window, or brings it forward. Before the scene has given `openMainWindow`: an existing main
    /// window is ordered front (AppKit fallback), else the open waits until `openMainWindow` is set.
    func showMainWindow() {
        if let open = openMainWindow {
            open()
        } else if !(usesAppKit && Self.orderFrontMainWindow()) {
            pendingWindowOpen = true
        }
        if usesAppKit { NSApp.activate() }
    }

    /// The app was opened again while running (the reopen event): shows the main window unless it is already
    /// visible on screen. Always handled (returns true).
    @discardableResult
    func handleReopen() -> Bool {
        if !windowState.isVisible {
            if usesAppKit { Self.log("reopen: showing the window") }
            showMainWindow()
        }
        return true
    }

    /// The SwiftUI main window, if it exists (its identifier starts with the scene id), made key and ordered front.
    private static func orderFrontMainWindow() -> Bool {
        guard let w = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(MetalPTApp.mainWindowID) == true && $0.canBecomeMain
        }) else { return false }
        w.makeKeyAndOrderFront(nil)
        return true
    }

    /// A "Run saved" notification was clicked: bring the window forward on Runs with that run selected (also when
    /// the window has never appeared, e.g. a login-item launch).
    func openRun(_ url: URL) {
        selectedRun = url
        page = .runs
        showMainWindow()
    }

    /// A "Run saved" notification's "Publish…": the run in Runs with its Submit sheet open.
    func openSubmit(_ url: URL) {
        submitRun = url
        openRun(url)
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

    /// Hotkey / menu / Live button. Starting (pressed, not yet started) counts as recording: a second press stops
    /// the run once it has started, instead of being refused as "already running". A press within
    /// `toggleDebounce` of the previous accepted one is ignored.
    func toggleRecording() {
        guard !quitDone else { return }
        let now = clock()
        if let last = lastAcceptedToggle, now - last < Self.toggleDebounce {
            if usesAppKit { Self.log("record toggle ignored (\(String(format: "%.2f", now - last)) s after the last)") }
            return
        }
        if stopping || hub.isFinishingRecording {
            recordingProblem = "\(TelemetryHub.RecordingError.stillFinishing)"
        } else if startTask != nil || hub.isRecording {
            lastAcceptedToggle = now
            if usesAppKit { Self.log("record toggle: stop") }
            playSound(.stop)
            stopRecording()
        } else {
            lastAcceptedToggle = now
            if usesAppKit { Self.log("record toggle: start") }
            startRecording()   // Tink once the start has succeeded
        }
    }

    private func playSound(_ sound: RecordSound) {
        guard soundOnRecord else { return }
        sounds?.play(sound)
    }

    // MARK: - Private

    /// A session message (main thread): every one is logged; warnings and errors are shown, and an error marks the
    /// run's "Run saved" notification.
    func recordingMessage(_ m: SessionMessage) {
        let level = switch m.level { case .info: "info"; case .warning: "warning"; case .error: "error" }
        Self.log("recording \(level): \(m.text)")
        guard m.level != .info else { return }
        recordingProblem = "Recording: \(m.text)"
        if m.level == .error { runHadErrors = true }
    }

    private func startRecording() {
        recordingProblem = nil
        runHadErrors = false
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
            if started, !self.stopping, !self.quitDone {
                self.playSound(.start)
                self.postStarted()
            }
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
        if overlayOn, overlayActivity == nil {
            overlayActivity = hub.activities.begin(AppActivity.overlay, reason: AppActivity.overlayReason)
        } else if !overlayOn, let a = overlayActivity {
            overlayActivity = nil
            a.end()
        }
        guard usesAppKit else { return }
        if overlayOn {
            let controller = overlay ?? OverlayController(model: self, defaults: defaults)
            #if DEBUG
            if overlay == nil, debugLogging {
                controller.onDebugEvent = { Self.log("debug: \($0)") }
            }
            #endif
            overlay = controller
            controller.show()
        } else {
            overlay?.hide()
        }
        Self.log("overlay \(overlayOn ? "on" : "off"); \(overlay?.describe() ?? "no panel")")
        #if DEBUG
        if overlayOn, debugLogging {
            // Once laid out and ordered in: the state a user would see.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.overlayOn else { return }
                    Self.log("debug: \(self.overlay?.describe() ?? "no panel")")
                }
            }
        }
        #endif
    }

    #if DEBUG
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
    #endif

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
        if !fpsLoggingOn, frameReportingWarning != nil { runFrameCheck(now: nil, gpuBusyPct: nil) }
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
            if !quitDone { notifier?.post(.saved(run, withProblems: runHadErrors, offerPublish: offerPublish)) }
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

    /// One check per new sampled snapshot.
    private func frameCheckTick(_ snapshot: HubSnapshot) {
        guard snapshot.time != lastFrameCheckTime else { return }
        lastFrameCheckTime = snapshot.time
        runFrameCheck(now: snapshot.time, gpuBusyPct: snapshot.sample.gpuBusyPct)
    }

    /// Runs `frameCheck`; the frontmost app is read only while FPS logging is on and the hub samples.
    private func runFrameCheck(now: Double?, gpuBusyPct: Double?) {
        let active = fpsLoggingOn && hub.isSampling
        let front = active ? frontmost() : nil
        let input = FrameReportingCheck.Input(
            now: now ?? lastFrameCheckTime ?? 0, fpsLoggingOn: fpsLoggingOn, sampling: hub.isSampling,
            frontmostPID: front?.pid, frontmostApp: front?.name, selfPID: ProcessInfo.processInfo.processIdentifier,
            gpuBusyPct: gpuBusyPct, hudLive: front.map { hub.hasLiveHUD(pid: $0.pid) } ?? false,
            otherHUDActive: front.map { hub.hasLiveHUD(excluding: $0.pid) } ?? false)
        let warning = frameCheck.tick(input)
        guard warning != frameReportingWarning else { return }
        frameReportingWarning = warning
        Self.log(warning.map { "not reporting frames: \($0)" } ?? "not-reporting-frames warning cleared")
    }

    private static func log(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data("Metal-PT: \(text)\n".utf8))
    }

    /// Snapshots only: fixed values for the published state.
    func showFixture(recordState: RecordState, fpsLoggingOn: Bool, recentRuns: [String],
                     hotkeyRegistration: [GlobalHotkeys.Action: String] = [:], fpsLoggingError: String? = nil,
                     notificationStatus: NotificationStatus? = nil, frameReportingWarning: String? = nil) {
        self.notificationStatus = notificationStatus
        self.frameReportingWarning = frameReportingWarning
        self.recordState = recordState
        self.fpsLoggingOn = fpsLoggingOn
        self.recentRuns = recentRuns
        self.hotkeyRegistration = hotkeyRegistration
        self.fpsLoggingError = fpsLoggingError
    }
}
