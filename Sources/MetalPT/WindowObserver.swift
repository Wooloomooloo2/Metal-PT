import AppKit
import MPTApp
import SwiftUI

/// Placed in the main window's content: finds its own `NSWindow` (the one this view is in, so no title or
/// identifier matching) and feeds `MainWindowState` from that window's notifications — appear, key, occlusion,
/// minimise, close. The SwiftUI `Window` scene keeps its views alive after the window closes, so `onDisappear`
/// cannot be relied on to release what the window holds.
struct WindowObserver: NSViewRepresentable {
    let state: MainWindowState

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(state: state)
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        private let state: MainWindowState
        private var observed: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        init(state: MainWindowState) {
            self.state = state
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observed else { return }
            stopObserving()
            guard let window else { return }
            observed = window
            let center = NotificationCenter.default
            let refresh: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            ]
            for name in refresh {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                             queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.closed() }
            })
            report()
        }

        private func report() {
            guard let w = observed else { return }
            state.update(windowVisible: w.isVisible, onScreen: w.occlusionState.contains(.visible),
                         miniaturized: w.isMiniaturized)
        }

        private func stopObserving() {
            for t in tokens { NotificationCenter.default.removeObserver(t) }
            tokens = []
            observed = nil
        }

        isolated deinit { stopObserving() }
    }
}
