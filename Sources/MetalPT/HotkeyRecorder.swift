import AppKit
import MPTApp

/// What a hotkey field suspends while it records (the app's global hotkeys: pressing the current combo must be
/// recorded, not fire).
@MainActor
protocol HotkeySuspending: AnyObject {
    func suspendHotkeys()
    func resumeHotkeys()
}

extension AppModel: HotkeySuspending {}

/// The key and mouse-down monitors a recording field installs (`NSEvent` local monitors in the app; fakes in tests).
@MainActor
protocol KeyEventMonitoring {
    /// `onKey(keyCode, modifierFlags.rawValue)` for each key down (swallowed); `onMouseDown` for each click anywhere
    /// in the app (passed on). Returns a token for `removeMonitors`.
    func addMonitors(onKey: @escaping (UInt16, UInt) -> Void, onMouseDown: @escaping () -> Void) -> AnyObject
    func removeMonitors(_ token: AnyObject)
}

struct AppKitEventMonitors: KeyEventMonitoring {
    private final class Token {
        let monitors: [Any]
        init(_ monitors: [Any]) { self.monitors = monitors }
    }

    func addMonitors(onKey: @escaping (UInt16, UInt) -> Void, onMouseDown: @escaping () -> Void) -> AnyObject {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode, flags = event.modifierFlags.rawValue
            MainActor.assumeIsolated { onKey(code, flags) }
            return nil
        }
        let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            event in
            MainActor.assumeIsolated { onMouseDown() }
            return event
        }
        return Token([keys, mouse].compactMap { $0 })
    }

    func removeMonitors(_ token: AnyObject) {
        for m in (token as? Token)?.monitors ?? [] { NSEvent.removeMonitor(m) }
    }
}

/// The hotkey field being recorded. While recording it holds the key monitor and the hotkey suspension; every way
/// out — a key, a click anywhere (including another control or the field itself), the app or the window losing
/// focus, the page going away, deinit — goes through `stop()`, which removes the monitor and resumes the hotkeys
/// exactly once.
@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published private(set) var recording: GlobalHotkeys.Action?
    private let monitors: KeyEventMonitoring
    private let center: NotificationCenter
    private var token: AnyObject?
    private weak var hotkeys: HotkeySuspending?
    private var observers: [NSObjectProtocol] = []
    private var onOutcome: ((HotkeyCapture.Outcome) -> Void)?
    /// The field whose recording a click just stopped, and when (so that click's own button action does not
    /// restart it).
    private var clickStop: (action: GlobalHotkeys.Action, at: TimeInterval)?

    /// `recording` given: snapshots (nothing installed or suspended).
    init(recording: GlobalHotkeys.Action? = nil, monitors: KeyEventMonitoring = AppKitEventMonitors(),
         center: NotificationCenter = .default) {
        self.recording = recording
        self.monitors = monitors
        self.center = center
    }

    func start(_ action: GlobalHotkeys.Action, hotkeys: HotkeySuspending,
               onOutcome: @escaping (HotkeyCapture.Outcome) -> Void) {
        recording = action
        self.onOutcome = onOutcome
        guard token == nil else { return }   // another field: same monitor and suspension
        self.hotkeys = hotkeys
        hotkeys.suspendHotkeys()
        token = monitors.addMonitors(
            onKey: { [weak self] code, flags in
                guard let self, let handler = self.onOutcome else { return }
                let outcome = HotkeyCapture.outcome(keyCode: code, cocoaFlags: flags)
                self.stop()
                handler(outcome)
            },
            onMouseDown: { [weak self] in
                guard let self, let current = self.recording else { return }
                self.clickStop = (current, ProcessInfo.processInfo.systemUptime)
                self.stop()
            })
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
    }

    /// Idempotent: removes the monitors and observers, and resumes the hotkeys if this recorder suspended them.
    func stop() {
        recording = nil
        onOutcome = nil
        for o in observers { center.removeObserver(o) }
        observers.removeAll()
        guard let token else { return }
        self.token = nil
        monitors.removeMonitors(token)
        hotkeys?.resumeHotkeys()
        hotkeys = nil
    }

    /// True once if a click on `action`'s field just stopped its recording (that click must not restart it).
    func consumeClickStop(_ action: GlobalHotkeys.Action) -> Bool {
        defer { clickStop = nil }
        guard let c = clickStop, c.action == action else { return false }
        return ProcessInfo.processInfo.systemUptime - c.at < 1
    }

    isolated deinit { stop() }
}
