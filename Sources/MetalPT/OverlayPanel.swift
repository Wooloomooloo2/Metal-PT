import AppKit
import Combine
import MPTApp
import SwiftUI

/// The overlay's window: borderless, transparent, click-through, never key or main, above fullscreen apps on every
/// Space (`.screenSaver` level with `.fullScreenAuxiliary`).
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        // NSPanel hides on deactivation by default; the game is the active app.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows and hides the overlay panel, keeps it in its corner of the screen with the mouse (or the main screen):
/// on screen changes, settings changes and content size changes (compact ↔ detailed).
@MainActor
final class OverlayController {
    private let model: AppModel
    private let defaults: UserDefaults
    private var panel: OverlayPanel?
    private var hosting: NSHostingView<AnyView>?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    /// Chosen when shown and on screen changes (not on every tick, so the overlay does not follow the mouse around).
    private var screen: NSScreen?
    private var shown = false
    /// The debug log: called after each move or resize and on Space changes, with `describe()`.
    var onDebugEvent: ((String) -> Void)?

    init(model: AppModel, defaults: UserDefaults) {
        self.model = model
        self.defaults = defaults
    }

    var isShown: Bool { panel?.isVisible == true }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        shown = true
        screen = Self.targetScreen()
        reposition()
        panel.orderFrontRegardless()
        startObserving()
    }

    func hide() {
        shown = false
        stopObserving()
        panel?.orderOut(nil)
    }

    /// One line for the log: frame, level, visibility, click-through, Space and occlusion.
    func describe() -> String {
        guard let p = panel else { return "overlay panel: none" }
        let f = p.frame
        return "overlay panel: frame (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))) "
            + "level \(p.level.rawValue) visible \(p.isVisible) ignoresMouseEvents \(p.ignoresMouseEvents) "
            + "onActiveSpace \(p.isOnActiveSpace) occlusionVisible \(p.occlusionState.contains(.visible)) "
            + "key \(p.isKeyWindow) canBecomeKey \(p.canBecomeKey) screen \(p.screen?.localizedName ?? "none")"
    }

    // MARK: - Private

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel()
        let view = AnyView(OverlayView(model: model, hub: model.hub).defaultAppStorage(defaults))
        let hosting = NSHostingView(rootView: view)
        // The controller sizes the panel (from `fittingSize`, anchored at the corner). The hosting view sits in a
        // plain container with autoresizing, so its intrinsic size cannot resize the window itself (it would grow
        // from the bottom-left and drift between ticks).
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: panel.contentLayoutRect)
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container
        self.hosting = hosting
        return panel
    }

    private func startObserving() {
        guard cancellables.isEmpty else { return }
        // Content size follows the hub (numbers) and the record state (compact ↔ detailed); settle after SwiftUI
        // has laid out the change.
        model.hub.objectWillChange
            .merge(with: model.objectWillChange)
            .sink { [weak self] _ in self?.repositionSoon() }
            .store(in: &cancellables)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screen = Self.targetScreen()
                self?.reposition()
            }
        })
        // Any defaults write posts this; re-lay out only when one of the overlay's own keys changed.
        overlaySettings = currentOverlaySettings()
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.currentOverlaySettings()
                guard now != self.overlaySettings else { return }
                self.overlaySettings = now
                self.repositionSoon()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reposition()
                    if let log = self.onDebugEvent {
                        // After the Space switch animation has settled.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            MainActor.assumeIsolated {
                                if let self { log("space changed: \(self.describe())") }
                            }
                        }
                    }
                }
            })
    }

    /// The overlay's settings as last seen (style, corner, opacity), to filter defaults notifications.
    private var overlaySettings: [String] = []

    private func currentOverlaySettings() -> [String] {
        SettingsKey.overlayKeys.map { defaults.object(forKey: $0).map { "\($0)" } ?? "" }
    }

    private func stopObserving() {
        cancellables.removeAll()
        for o in observers {
            NotificationCenter.default.removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers.removeAll()
    }

    private func repositionSoon() {
        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.reposition() } }
    }

    /// The screen with the mouse (where the game usually is), else the main screen.
    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func reposition() {
        if screen.map({ s in !NSScreen.screens.contains { $0 === s } }) ?? true { screen = Self.targetScreen() }
        guard shown, let panel, let hosting, let screen else { return }
        hosting.layoutSubtreeIfNeeded()
        // Whole points: sub-point text width changes would otherwise resize the panel every tick.
        let fitting = hosting.fittingSize
        let size = CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
        guard size.width > 0, size.height > 0 else { return }
        let corner = OverlayCorner(setting: defaults.string(forKey: SettingsKey.overlayCorner))
        let frame = corner.frame(size: size, in: screen.visibleFrame)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
        onDebugEvent?("moved/resized: \(describe())")
    }
}
